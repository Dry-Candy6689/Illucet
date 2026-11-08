import Foundation
import Testing
@testable import Illucet

@Suite("architecture boundaries")
struct DownloadArchitectureTests {
    @Test
    func schedulerOrdersEligibleJobsAndKeepsNetworkDecisionsTyped()
        async
    {
        let scheduler = DownloadScheduler()
        var settings = AppSettings.defaults
        settings.wifiOnly = true
        let network = NetworkPathSnapshot(
            isSatisfied: true,
            interface: .cellular,
            isExpensive: true,
            isConstrained: false
        )
        let first = job(priority: 1, state: .queued)
        let blocked = job(priority: 2, state: .completed)
        let last = job(priority: 3, state: .waitingForRetry)

        let pending = await scheduler.pendingDownloads(
            jobs: [last, blocked, first],
            runningJobIDs: [],
            settings: settings,
            network: network
        )

        #expect(pending.map(\.jobID) == [first.id, last.id])
        #expect(
            pending.map(\.networkDecision)
                == [.waitForWiFi, .waitForWiFi]
        )
    }

    @Test
    func schedulerExcludesRunningIdentityEvenWhenPersistedStateIsQueued()
        async
    {
        let scheduler = DownloadScheduler()
        let first = job(priority: 1, state: .queued)
        let second = job(priority: 2, state: .queued)

        let pending = await scheduler.pendingDownloads(
            jobs: [first, second],
            runningJobIDs: [first.id],
            settings: .defaults,
            network: wifi
        )

        #expect(pending.map(\.jobID) == [second.id])
    }

    @Test
    func schedulerOwnsIndependentIdempotentConcurrencyBudgets()
        async throws
    {
        let scheduler = DownloadScheduler(
            transferPermits: AsyncPermitPool(limit: 2),
            processingPermits: AsyncPermitPool(limit: 1)
        )
        let jobID = UUID()

        try await scheduler.acquireTransfer(jobID: jobID)
        try await scheduler.acquireTransfer(jobID: jobID)
        try await scheduler.acquireProcessing(jobID: jobID)

        #expect(
            await scheduler.transferSnapshot()
                == AsyncPermitPoolSnapshot(
                    limit: 2,
                    activeCount: 1,
                    waitingCount: 0
                )
        )
        #expect(
            await scheduler.processingSnapshot()
                == AsyncPermitPoolSnapshot(
                    limit: 1,
                    activeCount: 1,
                    waitingCount: 0
                )
        )

        await scheduler.releaseTransfer(jobID: jobID)
        await scheduler.releaseProcessing(jobID: jobID)
        #expect((await scheduler.transferSnapshot()).activeCount == 0)
        #expect((await scheduler.processingSnapshot()).activeCount == 0)
    }

    @Test
    func concurrentAcquisitionForOneJobSharesOnePermit()
        async throws
    {
        let scheduler = DownloadScheduler(
            transferPermits: AsyncPermitPool(limit: 1),
            processingPermits: AsyncPermitPool(limit: 1)
        )
        let jobID = UUID()

        async let first: Void = scheduler.acquireTransfer(jobID: jobID)
        async let second: Void = scheduler.acquireTransfer(jobID: jobID)
        _ = try await (first, second)

        #expect(
            await scheduler.transferSnapshot()
                == AsyncPermitPoolSnapshot(
                    limit: 1,
                    activeCount: 1,
                    waitingCount: 0
                )
        )
        await scheduler.releaseTransfer(jobID: jobID)
    }

    @Test
    func schedulerProducesTransferPolicyFromTheSameAdmissionInputs() {
        var settings = AppSettings.defaults
        settings.askBeforeCellular = true
        var candidate = job(priority: 0, state: .queued)

        #expect(
            DownloadScheduler.networkDecision(
                for: candidate,
                settings: settings,
                network: cellular
            ) == .requireCellularConfirmation
        )
        #expect(
            DownloadScheduler.streamNetworkPolicy(
                for: candidate,
                settings: settings
            ) == StreamTransferNetworkPolicy(
                allowsExpensiveAccess: false,
                allowsConstrainedAccess: true
            )
        )

        candidate.networkAuthorization = .continueOnce
        #expect(
            DownloadScheduler.networkDecision(
                for: candidate,
                settings: settings,
                network: cellular
            ) == .allow
        )
        #expect(
            DownloadScheduler.streamNetworkPolicy(
                for: candidate,
                settings: settings
            ) == .unrestricted
        )
    }

    @Test
    func restorationSeparatesRecoverableCheckpointFromLegacyRunningState()
        async
    {
        let restoration = DownloadRestorationController(
            downloader: Part5ANullDownloader()
        )
        var recoverable = job(priority: 0, state: .running)
        recoverable.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .sourcesReady
        )
        let legacy = job(priority: 1, state: .running)

        let restored = await restoration.restore([recoverable, legacy])
        let byID = Dictionary(
            uniqueKeysWithValues: restored.map { ($0.id, $0) }
        )

        #expect(byID[recoverable.id]?.state == .queued)
        #expect(byID[recoverable.id]?.stage == .restoring)
        #expect(byID[legacy.id]?.state == .needsAttention)
        #expect(byID[legacy.id]?.errorCode == "app_was_terminated")
    }

    @Test
    func retryControllerOwnsClassificationCheckpointAndBackoff()
        async throws
    {
        let delays = Part5ADelayRecorder()
        let controller = DownloadRetryController(
            policy: DownloadRetryPolicy(
                initialDelaySeconds: 2,
                multiplier: 3,
                maximumDelaySeconds: 20
            ),
            sleeper: { delay in
                await delays.record(delay)
            }
        )
        let failed = job(priority: 0, state: .running)
        let disposition = controller.disposition(
            for: StreamDownloadError.forbiddenHTTPFailure(
                statusCode: 403
            ),
            job: failed
        )
        #expect(
            disposition == .retry(
                reason: .mediaAccessForbidden,
                delaySeconds: 2,
                reResolveStreams: true
            )
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let checkpoint = controller.checkpoint(
            failed,
            reason: .mediaAccessForbidden,
            delay: 2,
            now: now
        )
        #expect(checkpoint.state == .waitingForRetry)
        #expect(checkpoint.stage == .waitingToRetry)
        #expect(checkpoint.retryCount == 1)
        #expect(
            checkpoint.retryAvailableAt
                == now.addingTimeInterval(2)
        )

        try await controller.wait(delay: 2)
        #expect(await delays.values == [2])
    }

    @Test
    func exportFlowKeepsConcurrentDuplicateContinuationsIndependent()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part5AExport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(
            to: root.appending(path: "Fixture.mp4")
        )
        let events = Part5AEventRecorder()
        let flow = DownloadExportFlow(
            exporter: ExportManager(documentsRootURL: root),
            diagnostics: DiagnosticStore(
                rootURL: root.appending(path: "Diagnostics")
            ),
            notifications: UserNotificationService(),
            eventSink: { event in events.record(event) }
        )
        let firstJob = job(priority: 0, state: .running)
        let secondJob = job(priority: 1, state: .running)
        let first = Task {
            try await flow.duplicateResolution(
                job: firstJob,
                filename: "Fixture",
                fileExtension: "mp4",
                defaultHandling: .ask,
                folderBookmark: nil
            )
        }
        let second = Task {
            try await flow.duplicateResolution(
                job: secondJob,
                filename: "Fixture",
                fileExtension: "mp4",
                defaultHandling: .ask,
                folderBookmark: nil
            )
        }

        let requests = try await events.waitForDuplicateRequests(count: 2)
        #expect(Set(requests.map(\.jobID)).count == 2)
        let firstRequest = try #require(
            requests.first { $0.jobID == firstJob.id }
        )
        let secondRequest = try #require(
            requests.first { $0.jobID == secondJob.id }
        )
        await flow.resolveDuplicate(
            requestID: firstRequest.id,
            handling: .overwrite
        )
        await flow.resolveDuplicate(
            requestID: secondRequest.id,
            handling: .skip
        )

        guard case .proceed(.overwrite) = try await first.value else {
            Issue.record("First duplicate continuation received wrong result")
            return
        }
        guard case .skip = try await second.value else {
            Issue.record("Second duplicate continuation received wrong result")
            return
        }
    }

    private var wifi: NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: true,
            interface: .wifi,
            isExpensive: false,
            isConstrained: false
        )
    }

    private var cellular: NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: true,
            interface: .cellular,
            isExpensive: true,
            isConstrained: false
        )
    }

    private func job(
        priority: Int,
        state: DownloadJobState
    ) -> DownloadJob {
        let id = UUID()
        return DownloadJob(
            id: id,
            sourceURL: DeveloperFixtures.RickURL,
            videoID: "video-\(id.uuidString)",
            title: "Fixture",
            channel: "Illucet",
            thumbnailURL: nil,
            createdAt: Date(
                timeIntervalSince1970: Double(priority)
            ),
            updatedAt: .now,
            configuration: .standard,
            state: state,
            stage: .waiting,
            progress: .zero,
            priority: priority,
            retryCount: 0,
            maximumRetries: 3,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture",
            playlistItemID: nil
        )
    }
}

private actor Part5ADelayRecorder {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        values.append(value)
    }
}

private final class Part5AEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var duplicateRequests: [DuplicateConflict] = []

    func record(_ event: DownloadCoordinatorEvent) {
        guard case let .requestDuplicate(conflict) = event else {
            return
        }
        lock.withLock {
            duplicateRequests.append(conflict)
        }
    }

    func waitForDuplicateRequests(
        count: Int
    ) async throws -> [DuplicateConflict] {
        for _ in 0 ..< 1_000 {
            let requests = lock.withLock { duplicateRequests }
            if requests.count >= count {
                return Array(requests.prefix(count))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Part5ATestFailure.timeout
    }
}

private enum Part5ATestFailure: Error {
    case timeout
}

private struct Part5ANullDownloader: StreamDownloading {
    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        throw StreamDownloadError.networkFailure
    }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        control(.cancel)
    }

    func pause(jobID: UUID) async -> StreamTaskControlResult {
        control(.pause)
    }

    func resume(jobID: UUID) async -> StreamTaskControlResult {
        control(.resume)
    }

    private func control(
        _ action: StreamTaskControlAction
    ) -> StreamTaskControlResult {
        StreamTaskControlResult(
            action: action,
            matchedTaskCount: 0,
            affectedTaskCount: 0,
            acknowledgedTaskCount: 0
        )
    }
}
