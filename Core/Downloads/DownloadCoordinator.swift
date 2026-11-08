import Foundation

enum DownloadCoordinatorEvent: Sendable {
    case upsertJob(DownloadJob)
    case addHistory(HistoryRecord)
    case foregroundCompletion(jobID: UUID, at: Date)
    case removeJob(UUID)
    case requestDuplicate(DuplicateConflict)
    case requestNetworkAccess(NetworkAccessRequest)
    case cellularPromptPreferenceChanged(Bool)
    case presentShare(SharePresentationRequest)
    case updateShareLifecycle(
        jobID: UUID,
        state: ShareCompletionState,
        errorDescription: String?
    )
}

actor DownloadCoordinator {
    nonisolated let updates: AsyncStream<DownloadCoordinatorEvent>

    private let continuation: AsyncStream<DownloadCoordinatorEvent>.Continuation
    private let downloader: any StreamDownloading
    private let mediaProcessor: any MediaProcessor
    private let storage: StorageManager
    private let exportFlow: DownloadExportFlow
    private let diagnostics: DiagnosticStore
    private var publicationWriter: @Sendable (DownloadJob) async throws -> Void
    private var nativeAcknowledgementEnabled = false
    private let notifications: UserNotificationService
    private let processingContinuation: (any ContinuedProcessingControlling)?
    private let pauseGate = DownloadPauseGate()
    private struct PauseClaim {
        let token: UUID
        let restart: Bool
    }
    private struct ResumeOperation {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var pauseControls: [UUID: PauseClaim] = [:]
    private var pauseVersions: [UUID: UUID] = [:]
    private var resumeOperations: [UUID: ResumeOperation] = [:]
    private var resumeAfterPause: Set<UUID> = []
    private var nativeResumePending: Set<UUID> = []
    private var executionAttempts: [UUID: UUID] = [:]
    private var pipelineTasks: [UUID: (attempt: UUID, task: Task<Void, Error>)] = [:]
    private var executionSuspensions: Set<UUID> = []
    private var processingPermitJobs: Set<UUID> = []
    private var foregroundEligible = false
    private var sceneRevision: UInt64?
    private var foregroundActivation: UInt64 = 0
    private var foregroundResumedAt: [UUID: UInt64] = [:]
    private var expiredProcessing = Set<UUID>()
    private var intentExecution = Set<UUID>()
    private var progressEmissionStages: [UUID: DownloadStage] = [:]
    private var progressEmissionTimes: [UUID: ContinuousClock.Instant] = [:]
    private let fileManager: FileManager
    private let networkMonitor: any NetworkPathMonitoring
    private let retryController: DownloadRetryController
    private let scheduler: DownloadScheduler
    private let restoration: DownloadRestorationController
    private let pipelineRunner: DownloadPipelineRunner
    private let networkController: DownloadNetworkController

    private var jobs: [UUID: DownloadJob] = [:]
    private var pendingAdmissions: Set<UUID> = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var fragmentPauseRestarts: [UUID: FragmentPauseBarrier] = [:]
    private var speedEstimators: [UUID: RollingSpeedEstimator] = [:]
    private var currentNetwork = NetworkPathSnapshot.unavailable
    private var isConnectedToPower = false
    private var networkObservationTask: Task<Void, Never>?
    private let transferClock: @Sendable () -> Double
    private let automaticallyMonitorTransfers: Bool
    private let livenessPolicy = TransferLivenessPolicy()
    private var livenessMonitor: Task<Void, Never>?
    private var checkingLiveness = false
    private struct TransferActivity {
        let attempt: UUID
        var lastActivity: Double
        var nativeBytes: Int64 = 0
    }
    private struct TransferRecovery {
        let attempt: UUID
        let acknowledgementDeadline: Double
        let mayRetry: Bool
        var pipelineFinished = false
        var controlAcknowledged = false
        var timedOut = false
        var finalizing = false
    }
    private var transferActivity: [UUID: TransferActivity] = [:]
    private var transferRecoveries: [UUID: TransferRecovery] = [:]
    private var transferRecoveryControls: [UUID: Task<Void, Never>] = [:]
    private var settings = AppSettings.defaults
    private var folderBookmark: Data?

    init(
        runtime: any RuntimeProviding,
        downloader: any StreamDownloading,
        DASHDownloader: (any DASHFragmentDownloading)? = nil,
        DASHAssembler: (any DASHLocalStreamAssembling)? = nil,
        HLSDownloader: (any HLSResourceDownloading)? = nil,
        HLSAssembler: (any HLSLocalStreamAssembling)? = nil,
        mediaProcessor: any MediaProcessor,
        playbackVerifier: any ApplePlaybackVerifying = ApplePlaybackVerifier(requiresPlayerPlayback: false),
        storage: StorageManager,
        exporter: ExportManager,
        thumbnails: ThumbnailService,
        diagnostics: DiagnosticStore,
        sponsorBlockDiagnostics: SponsorBlockDiagnosticLogger? = nil,
        notifications: UserNotificationService,
        fileManager: FileManager = .default,
        networkMonitor: any NetworkPathMonitoring =
            NetworkPathMonitorService(),
        retryPolicy: DownloadRetryPolicy = DownloadRetryPolicy(),
        retrySleeper: @escaping DownloadRetrySleeper = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        transferPermits: AsyncPermitPool? = nil,
        processingPermits: AsyncPermitPool? = nil,
        subtitleWorkflow: SubtitleSidecarWorkflow? = nil,
        processingContinuation: (any ContinuedProcessingControlling)? = nil,
        publicationWriter: @escaping @Sendable (DownloadJob) async throws -> Void = { _ in
            throw ExportPublicationError.persistenceUnavailable
        },
        transferClock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        automaticallyMonitorTransfers: Bool = true
    ) {
        var captured: AsyncStream<DownloadCoordinatorEvent>.Continuation!
        updates = AsyncStream { captured = $0 }
        continuation = captured
        let eventContinuation = captured!
        self.downloader = downloader
        self.mediaProcessor = mediaProcessor
        self.storage = storage
        let activeExportFlow = DownloadExportFlow(
            exporter: exporter,
            diagnostics: diagnostics,
            notifications: notifications,
            eventSink: { event in
                eventContinuation.yield(event)
            }
        )
        exportFlow = activeExportFlow
        self.diagnostics = diagnostics
        self.notifications = notifications
        self.publicationWriter = publicationWriter
        self.transferClock = transferClock
        self.automaticallyMonitorTransfers = automaticallyMonitorTransfers
        self.processingContinuation = processingContinuation
        self.fileManager = fileManager
        self.networkMonitor = networkMonitor
        retryController = DownloadRetryController(
            policy: retryPolicy,
            sleeper: retrySleeper
        )
        scheduler = DownloadScheduler(
            transferPermits: transferPermits,
            processingPermits: processingPermits
        )
        restoration = DownloadRestorationController(
            downloader: downloader,
            fileManager: fileManager
        )
        networkController = DownloadNetworkController(
            downloader: downloader,
            eventSink: { event in
                eventContinuation.yield(event)
            }
        )
        pipelineRunner = DownloadPipelineRunner(
            runtime: runtime,
            downloader: downloader,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler,
            mediaProcessor: mediaProcessor,
            playbackVerifier: playbackVerifier,
            storage: storage,
            exportFlow: activeExportFlow,
            thumbnails: thumbnails,
            subtitleWorkflow: subtitleWorkflow,
            diagnostics: diagnostics,
            sponsorBlockDiagnostics: sponsorBlockDiagnostics,
            fileManager: fileManager
        )
    }

    deinit {
        networkObservationTask?.cancel()
        livenessMonitor?.cancel()
        continuation.finish()
    }

    func configure(
        settings: AppSettings,
        folderBookmark: Data?
    ) async {
        self.settings = settings
        (downloader as? StreamDownloadService)?.bandwidthLimiter.configure(global: settings.downloadSpeedLimitBytesPerSecond)
        (downloader as? StreamDownloadService)?.setExecutionGate { [weak self] id in
            guard let self else { throw CancellationError() }
            guard let attempt = await self.executionAttempt(for: id) else { throw CancellationError() }
            try await self.requireExecution(jobID: id, attempt: attempt)
        }
        (downloader as? StreamDownloadService)?.setNativeRequestGate { [weak self] id in
            guard let self else { throw CancellationError() }
            try await self.requireTransferExecution(jobID: id)
        }
        (downloader as? StreamDownloadService)?.setTaskPlanHandler { [weak self] id, descriptors in
            guard let self else { throw NativeTransferCheckpointError.persistenceUnavailable }
            try await self.persistNativeTransferPlan(id, descriptors: descriptors)
        }
        self.folderBookmark = folderBookmark
        if automaticallyMonitorTransfers, livenessMonitor == nil {
            livenessMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await self?.checkTransferLiveness()
                }
            }
        }
        await scheduler.configure(settings: settings)
        if networkObservationTask == nil {
            currentNetwork = await networkMonitor.currentSnapshot()
            networkObservationTask = Task {
                for await snapshot in networkMonitor.updates {
                    if Task.isCancelled { return }
                    await self.receiveNetworkSnapshot(snapshot)
                }
            }
        }
        schedulePendingJobs()
    }

    func setPublicationWriter(_ writer: @escaping @Sendable (DownloadJob) async throws -> Void) {
        publicationWriter = writer
        nativeAcknowledgementEnabled = true
    }

    func updateOutputReferences(jobID: UUID, references: SavedOutputReferences) {
        guard var job = jobs[jobID], job.state.isTerminal else { return }
        job.outputReferences = references
        job.updatedAt = .now
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
    }

    private func acknowledgeNativeFile(_ id: UUID, attempt: UUID?, receipt: NativeFileReceipt) async throws {
        guard nativeAcknowledgementEnabled, var job = jobs[id] else {
            throw NativeTransferCheckpointError.persistenceUnavailable
        }
        if let attempt, let current = executionAttempts[id], current != attempt { return }
        if let format = receipt.formatID, !job.selectedFormatIDs.contains(format) { return }
        var checkpoint = job.pipelineCheckpoint ?? DownloadPipelineCheckpoint(phase: .queued)
        var receipts = checkpoint.nativeFileReceipts ?? []
        receipts.removeAll { $0.identity == receipt.identity }
        receipts.append(receipt)
        checkpoint.nativeFileReceipts = Array(receipts.suffix(256))
        job.pipelineCheckpoint = checkpoint
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        do { try await publicationWriter(job) }
        catch { throw NativeTransferCheckpointError.persistenceUnavailable }
    }

    func restore(_ restoredJobs: [DownloadJob]) async {
        // Seed identity before reconciliation: a native delegate can complete
        // while allTasks or cancellation acknowledgement is being awaited.
        jobs = Dictionary(uniqueKeysWithValues: restoredJobs.map { ($0.id, $0) })
        if nativeAcknowledgementEnabled {
            (downloader as? StreamDownloadService)?.setAcknowledgementHandler { [weak self] id, attempt, receipt in
                guard let self else { throw NativeTransferCheckpointError.persistenceUnavailable }
                try await self.acknowledgeNativeFile(id, attempt: attempt, receipt: receipt)
            }
        }
        let eligible = restoredJobs.filter {
            ($0.state == .running || $0.state == .queued) && networkDecision(for: $0) == .allow
                && (!(settings.waitForCharging == true || $0.configuration.waitForCharging == true) || isConnectedToPower)
        }.sorted { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority < $1.priority }
        let continuing = Set(eligible.filter { $0.transferLimitOverride != true }
            .prefix(settings.maximumSimultaneousDownloads).map(\.id))
            .union(eligible.filter { $0.transferLimitOverride == true }.map(\.id))
        let restored = await restoration.restore(restoredJobs, continuingJobIDs: continuing)
        jobs = Dictionary(
            uniqueKeysWithValues: restored.map { restored in
                var job = restored
                if let receipts = jobs[job.id]?.pipelineCheckpoint?.nativeFileReceipts {
                    if job.pipelineCheckpoint == nil { job.pipelineCheckpoint = .init(phase: .transferring) }
                    job.pipelineCheckpoint?.nativeFileReceipts = receipts
                }
                return (job.id, job)
            }
        )
        for job in restored {
            if job.state == .paused { await pauseGate.pause(job.id) }
            else { await pauseGate.resume(job.id) }
            // Only explicit user pause holds new request admission.
            await downloader.setAdmissionPaused(job.state == .paused, jobID: job.id)
        }
        for job in jobs.values {
            continuation.yield(.upsertJob(job))
        }
        for job in restored where job.isAwaitingTransferCleanup {
            let attempt = UUID()
            transferRecoveries[job.id] = TransferRecovery(attempt: attempt,
                acknowledgementDeadline: transferClock() + livenessPolicy.acknowledgementTimeout,
                mayRetry: false, pipelineFinished: true)
            beginTransferRecoveryControl(job.id, attempt: attempt)
        }
        schedulePendingJobs()
    }

    private func persistNativeTransferPlan(_ id: UUID, descriptors: [StreamTransferDescriptor]) async throws {
        guard nativeAcknowledgementEnabled, var job = jobs[id], !job.state.isTerminal else {
            throw NativeTransferCheckpointError.persistenceUnavailable
        }
        var registered = job.activeTransferDescriptors ?? []
        for descriptor in descriptors {
            guard descriptor.jobID == id, job.selectedFormatIDs.contains(descriptor.streamID) else {
                throw NativeTransferCheckpointError.persistenceUnavailable
            }
            registered.removeAll { StreamTransferKey($0) == StreamTransferKey(descriptor) }
            registered.append(descriptor)
        }
        job.activeTransferDescriptors = registered
        jobs[id] = job
        do { try await publicationWriter(job) }
        catch { throw NativeTransferCheckpointError.persistenceUnavailable }
    }

    func rejectPendingNativeReceipts() { (downloader as? StreamDownloadService)?.rejectPendingReceipts() }

    func transferAdmissionStatus(excluding id: UUID? = nil) async -> (count: Int, limit: Int) {
        let permits = await scheduler.transferSnapshot()
        let requested = jobs.values.filter { $0.id != id && TransferAdmissionPolicy.requestsTransfer($0) }.count
        return (max(permits.activeCount, requested), permits.limit)
    }

    @discardableResult
    func enqueue(
        metadata: MediaMetadata,
        configuration: DownloadConfiguration,
        extractorVersion: String?,
        playlistItemID: String? = nil,
        batchMembership: BatchJobMembership? = nil,
        admissionID: UUID? = nil,
        transferLimitOverride: Bool = false
    ) throws -> DownloadJob {
        try Task.checkCancellation()
        if let admissionID, let existing = jobs[admissionID] {
            guard existing.sourceURL == metadata.canonicalURL else {
                throw IllucetError.internalFailure("This shared-link request belongs to a different video.")
            }
            return existing
        }
        var selected = configuration
        selected.sponsorBlock = selected.effectiveSponsorBlock
        if selected.thumbnailBehavior != .thumbnailOnly,
           !selected.isSubtitlesOnly,
           selected.selectedFormatIDs.isEmpty {
            FormatSelection.applyAutomaticSelection(
                to: &selected,
                metadata: metadata
            )
        }
        try OutputCapabilityMatrix.validate(selected, metadata: metadata)
        let sponsorPlan = try SponsorBlockPlanner.validateLaunch(
            policy: selected.sponsorBlock,
            videoID: metadata.videoID,
            analyzedDuration: metadata.durationSeconds
        )
        if sponsorPlan.entries.contains(where: { $0.action == .remove }) {
            try SponsorBlockExecutionSupport.validate(
                plan: sponsorPlan,
                policy: selected.sponsorBlock,
                configuration: selected,
                outputPlan: try OutputCapabilityMatrix.makePlan(
                    configuration: selected,
                    metadata: metadata
                )
            )
        }
        let thumbnail = metadata.thumbnails.sorted {
            ($0.width ?? 0) * ($0.height ?? 0)
                > ($1.width ?? 0) * ($1.height ?? 0)
        }.first?.url
        let highestPriority = jobs.values.map(\.priority).max() ?? 0
        var job = DownloadJob(
            id: admissionID ?? UUID(),
            sourceURL: metadata.canonicalURL,
            videoID: metadata.videoID,
            title: metadata.title,
            channel: metadata.channel ?? metadata.uploader,
            thumbnailURL: thumbnail,
            createdAt: .now,
            updatedAt: .now,
            configuration: selected,
            state: .queued,
            stage: .waiting,
            progress: .zero,
            priority: highestPriority + 1,
            retryCount: 0,
            maximumRetries: settings.automaticRetryCount,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: selected.selectedFormatIDs,
            extractorVersion: extractorVersion,
            playlistItemID: playlistItemID ?? batchMembership?.entryID
        )
        job.batchMembership = batchMembership
        job.transferLimitOverride = transferLimitOverride ? true : nil
        if selected.sponsorBlock.lookupUnavailable {
            job.sponsorBlockApplication = .fallback(
                mode: selected.sponsorBlock.removalMode,
                reason: .lookupUnavailable
            )
        } else if selected.sponsorBlock.needsSegmentReview {
            job.sponsorBlockApplication = .requested(
                plan: sponsorPlan,
                mode: selected.sponsorBlock.removalMode
            )
        }
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .queued
        )
        jobs[job.id] = job
        if admissionID != nil { pendingAdmissions.insert(job.id) }
        continuation.yield(.upsertJob(job))
        schedulePendingJobs()
        return job
    }

    /// Shortcut admission is persisted before any transport can start.
    func commitAdmission(_ id: UUID) {
        pendingAdmissions.remove(id)
        schedulePendingJobs()
    }

    func discardAdmission(_ id: UUID) {
        guard pendingAdmissions.remove(id) != nil else { return }
        jobs.removeValue(forKey: id)
        continuation.yield(.removeJob(id))
    }

    private func claimPause(_ id: UUID) -> PauseClaim? {
        guard var job = jobs[id], job.canPause, pauseControls[id] == nil else { return nil }
        let restart = runningTasks[id] != nil && (
            FragmentSourceLeases.shared.hasActiveSource(jobID: id)
            || [.analyzing, .preparing, .downloadingThumbnail, .downloadingSubtitles,
                .waitingForProcessing, .waitingForBackgroundTime].contains(job.stage)
            || (job.stage == .waitingForTransfer && job.resumableTransferStage == nil))
        if job.state == .running && [.downloadingVideo, .downloadingAudio].contains(job.stage) && !restart {
            job.resumableTransferStage = job.stage
        }
        let claim = PauseClaim(token: UUID(), restart: restart)
        pauseControls[id] = claim
        pauseVersions[id] = claim.token
        transferActivity[id]?.lastActivity = transferClock()
        expiredProcessing.remove(id)
        job.state = .paused
        job.transferLimitOverride = nil
        job.progress.smoothedBytesPerSecond = nil
        job.progress.downloadETASeconds = nil
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        return claim
    }

    func pause(_ id: UUID) async {
        guard let claim = claimPause(id) else { return }
        await performPause(id, claim: claim)
    }

    private func performPause(_ id: UUID, claim: PauseClaim) async {
        await pauseGate.pause(id)
        await stopResumeOperation(id)
        guard jobs[id]?.state == .paused else {
            await finishPauseControl(id, claim: claim)
            return
        }
        await downloader.setAdmissionPaused(true, jobID: id)
        if claim.restart, let task = runningTasks[id] {
            await pauseByRestart(id, task: task)
        } else {
            let result = await downloader.pause(jobID: id)
            if result.matchedTaskCount > 0 && !result.fullyAcknowledged, let task = runningTasks[id] {
                await pauseByRestart(id, task: task)
            } else {
                await releaseTransferPermit(jobID: id)
            }
        }
        if let attempt = executionAttempts[id] {
            await processingContinuation?.finish(jobID: id, attempt: attempt, success: false)
        }
        await finishPauseControl(id, claim: claim)
    }

    private func pauseByRestart(_ id: UUID, task: Task<Void, Never>) async {
        let barrier = FragmentPauseBarrier()
        fragmentPauseRestarts[id] = barrier
        jobs[id]?.resumableTransferStage = nil
        task.cancel()
        _ = await downloader.cancel(jobID: id)
        await acknowledgeFragmentPauseControl(jobID: id, barrierID: barrier.id)
        await task.value
    }

    private func finishPauseControl(_ id: UUID, claim: PauseClaim) async {
        guard pauseControls[id]?.token == claim.token else { return }
        if jobs[id]?.state.isTerminal == true {
            await downloader.setAdmissionPaused(false, jobID: id)
        }
        pauseControls[id] = nil
        if resumeAfterPause.remove(id) != nil, jobs[id]?.state == .paused {
            await resume(id, transferLimitOverride: jobs[id]?.transferLimitOverride == true)
        }
    }

    private func stopResumeOperation(_ id: UUID) async {
        guard let operation = resumeOperations[id] else { return }
        operation.task.cancel()
        await operation.task.value
        if resumeOperations[id]?.token == operation.token { resumeOperations[id] = nil }
    }

    func resume(_ id: UUID, transferLimitOverride: Bool = false) async {
        guard var job = jobs[id], job.state == .paused else { return }
        job.transferLimitOverride = transferLimitOverride ? true : nil
        if pauseControls[id] != nil {
            jobs[id]?.transferLimitOverride = job.transferLimitOverride
            resumeAfterPause.insert(id)
            return
        }
        guard resumeOperations[id] == nil else { return }
        if runningTasks[id] == nil || job.resumableTransferStage == nil {
            job.state = .queued
            job.stage = .restoring
            job.resumableTransferStage = nil
            job.updatedAt = .now
            jobs[id] = job
            continuation.yield(.upsertJob(job))
            await downloader.setAdmissionPaused(false, jobID: id)
            await pauseGate.resume(id)
            schedulePendingJobs()
            return
        }
        let attempt = executionAttempts[id]
        job.state = .running
        job.stage = .waitingForTransfer
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        let token = UUID()
        nativeResumePending.insert(id)
        let task = Task { await self.resumeNativeTransfer(id, attempt: attempt) }
        resumeOperations[id] = ResumeOperation(token: token, task: task)
        await task.value
        if resumeOperations[id]?.token == token { resumeOperations[id] = nil }
        schedulePendingJobs()
    }

    private func resumeNativeTransfer(_ id: UUID, attempt: UUID?) async {
        do {
            if let attempt, let job = jobs[id] {
                await processingContinuation?.begin(job: job, attempt: attempt) { [weak self] in
                    await self?.expireProcessing(jobID: id, attempt: attempt)
                }
            }
            try await acquireTransferPermit(jobID: id, resuming: true)
            try Task.checkCancellation()
            guard executionAttempts[id] == attempt, jobs[id]?.state == .running else { throw CancellationError() }
            let result = await downloader.resume(jobID: id)
            try Task.checkCancellation()
            guard executionAttempts[id] == attempt, var current = jobs[id], current.state == .running else { throw CancellationError() }
            guard result.matchedTaskCount == 0 || result.fullyAcknowledged else { throw CancellationError() }
            speedEstimators[id] = nil
            current.progress.smoothedBytesPerSecond = nil
            current.progress.instantaneousBytesPerSecond = nil
            current.progress.downloadETASeconds = nil
            current.progress.sampleCount = 0
            current.stage = current.resumableTransferStage ?? .downloadingVideo
            current.resumableTransferStage = nil
            current.updatedAt = .now
            jobs[id] = current
            continuation.yield(.upsertJob(current))
            nativeResumePending.remove(id)
            await pauseGate.resume(id)
        } catch {
            nativeResumePending.remove(id)
            if executionAttempts[id] == attempt {
                await releaseTransferPermit(jobID: id)
                if var current = jobs[id], current.state == .running {
                    current.state = .paused
                    current.updatedAt = .now
                    jobs[id] = current
                    continuation.yield(.upsertJob(current))
                }
            }
        }
    }

    private func waitForUserResume(_ id: UUID) async throws {
        while jobs[id]?.state == .paused || nativeResumePending.contains(id) {
            await pauseGate.pause(id)
            if jobs[id]?.state != .paused && !nativeResumePending.contains(id) { await pauseGate.resume(id); break }
            try await pauseGate.wait(id)
        }
        try Task.checkCancellation()
        guard let job = jobs[id], !job.state.isTerminal else { throw CancellationError() }
    }

    func cancel(_ id: UUID) async {
        if var job = jobs[id], !job.state.isTerminal {
        job.state = .cancelled
        job.stage = .cleaningUp
        job.errorCode = "user_cancelled"
        job.errorMessage = IllucetError.userCancelled.localizedDescription
        if var application = job.sponsorBlockApplication,
           application.status == .requested
            || application.status == .applied {
            application.status = .cancelled
            job.sponsorBlockApplication = application
        }
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        }
        if transferRecoveries[id] != nil { markTransferCleanupPending(id) }
        resumeAfterPause.remove(id)
        await stopResumeOperation(id)
        await pauseGate.resume(id)
        expiredProcessing.remove(id)
        let pauseBarrierID = fragmentPauseRestarts[id]?.id
        fragmentPauseRestarts[id]?.requestCancellation()
        runningTasks[id]?.cancel()
        await networkController.cancelRequests(jobID: id)
        await exportFlow.cancelDuplicateRequests(jobID: id)
        _ = await downloader.cancel(jobID: id)
        await downloader.setAdmissionPaused(false, jobID: id)
        await releaseTransferPermit(jobID: id)
        await mediaProcessor.cancel(operationID: id)
        await releaseProcessingPermit(jobID: id)
        if let pauseBarrierID {
            // The pause barrier owns cleanup even if its acquisition task has
            // already completed while this cancellation was suspended.
            await acknowledgeFragmentPauseControl(jobID: id, barrierID: pauseBarrierID)
        } else if runningTasks[id] == nil {
            cleanupFailedWorkIfConfigured(jobID: id)
        }
    }

    func resolveNetworkAccess(
        requestID: UUID,
        choice: NetworkAccessChoice
    ) async {
        await networkController.resolve(
            requestID: requestID,
            choice: choice
        )
    }

    func resolveDuplicate(
        requestID: UUID,
        handling: DuplicateHandling?
    ) async {
        await exportFlow.resolveDuplicate(
            requestID: requestID,
            handling: handling
        )
    }

    func shareDidFinish(
        jobID: UUID,
        state: ShareCompletionState,
        errorDescription: String? = nil
    ) async {
        if let existing = jobs[jobID]?.shareCompletionState,
           existing == .completed || existing == .cancelled { return }
        guard let job = exportFlow.prepareShareCompletion(job: jobs[jobID], state: state,
            errorDescription: errorDescription) else {
            continuation.yield(.updateShareLifecycle(jobID: jobID, state: state, errorDescription: errorDescription))
            return
        }
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
        continuation.yield(.addHistory(HistoryRecord(job: job)))
    }

    /// The app's single snapshot writer acknowledges the outcome before staging is removed.
    func acknowledgeSharePersistence(jobID: UUID, state: ShareCompletionState) async {
        do { try await exportFlow.exportManager.finishShare(jobID: jobID, state: state) }
        catch {
            await diagnostics.record(.warning, subsystem: "exports", event: "share_cleanup_failed", detail: "job=\(jobID)")
        }
    }

    func presentPendingShare(
        jobID: UUID,
        title: String
    ) async -> Bool {
        await exportFlow.presentPendingShare(
            jobID: jobID,
            title: title
        )
    }

    func retry(_ id: UUID, resetForegroundBudget: Bool = true, transferLimitOverride: Bool = false) {
        guard pauseControls[id] == nil, resumeOperations[id] == nil, transferRecoveries[id] == nil,
              jobs[id]?.state != .completed, jobs[id]?.hasUnknownPublication != true else { return }
        guard runningTasks[id] == nil, executionAttempts[id] == nil, var job = jobs[id], job.state.isTerminal
            || job.state == .needsAttention else { return }
        if resetForegroundBudget { foregroundResumedAt[id] = nil }
        job.retryRequestID = UUID()
        job.transferLimitOverride = transferLimitOverride ? true : nil
        job.transferRecoveryCount = nil
        job.resumableTransferStage = nil
        job.state = .queued
        job.stage = .waiting
        job.errorCode = nil
        job.errorMessage = nil
        job.progress = .zero
        job.retryCount = 0
        job.foregroundResumeReason = nil
        job.retryExhausted = nil
        job.pipelineCheckpoint?.fragmentURLRefreshCounts = nil
        job.retryAvailableAt = nil
        job.lastRetryReason = nil
        job.networkAuthorization = nil
        job.subtitleSidecars = nil
        if var application = job.sponsorBlockApplication,
           application.status == .failed
            || application.status == .cancelled {
            application.status = .requested
            job.sponsorBlockApplication = application
        }
        if job.configuration.isSubtitlesOnly {
            job.outputURL = nil
            job.outputProbe = nil
            job.exportOutcome = nil
            job.photosAssetLocalIdentifiers = nil
            job.shareCompletionState = nil
            job.shareErrorMessage = nil
        }
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        schedulePendingJobs()
    }

    func prioritize(_ id: UUID) async {
        guard var job = jobs[id] else { return }
        let lowest = jobs.values.map(\.priority).min() ?? 0
        job.priority = lowest == Int.min ? Int.min : lowest - 1
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        await scheduler.prioritizeTransfer(jobID: id, priority: job.priority)
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var ordered = jobs.values
            .filter { !$0.state.isTerminal }
            .sorted { $0.priority < $1.priority }
        let validOffsets = fromOffsets.filter { ordered.indices.contains($0) }
        let moving = validOffsets.map { ordered[$0] }
        for index in validOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.count { $0 < toOffset }
        let insertion = min(
            max(0, toOffset - removedBeforeDestination),
            ordered.count
        )
        ordered.insert(contentsOf: moving, at: insertion)
        for (index, var job) in ordered.enumerated() {
            job.priority = index
            job.updatedAt = .now
            jobs[job.id] = job
            continuation.yield(.upsertJob(job))
        }
    }

    func reorderActiveJobs(_ orderedIDs: [UUID]) {
        let active = jobs.values.filter { !$0.state.isTerminal }
        let activeIDs = Set(active.map(\.id))
        guard orderedIDs.count == active.count,
              Set(orderedIDs) == activeIDs
        else {
            return
        }
        for (priority, id) in orderedIDs.enumerated() {
            guard var job = jobs[id] else { continue }
            job.priority = priority
            job.updatedAt = .now
            jobs[id] = job
            continuation.yield(.upsertJob(job))
        }
    }

    func pauseAll() async {
        // Claim every current eligible job before the first suspension point.
        let claims = Array(jobs.keys).compactMap { id in claimPause(id).map { (id, $0) } }
        for (id, claim) in claims { await performPause(id, claim: claim) }
    }

    func resumeAll() async {
        let ids = jobs.values.filter { $0.state == .paused }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.resume(id) } }
        }
    }

    func cancelAll() async {
        for job in jobs.values where !job.state.isTerminal {
            await cancel(job.id)
        }
    }

    func clearCompleted() {
        for job in jobs.values where job.state == .completed
            || job.state == .cancelled {
            guard transferRecoveries[job.id] == nil else { continue }
            try? (downloader as? any FragmentCheckpointManaging)?
                .discardFragmentCheckpoints(jobID: job.id, formatID: nil)
            jobs[job.id] = nil
            continuation.yield(.removeJob(job.id))
        }
    }

    func removeTerminalJobs(_ jobIDs: Set<UUID>) {
        for jobID in jobIDs {
            guard let job = jobs[jobID], job.state.isTerminal else {
                continue
            }
            guard transferRecoveries[jobID] == nil else { continue }
            try? (downloader as? any FragmentCheckpointManaging)?
                .discardFragmentCheckpoints(jobID: jobID, formatID: nil)
            jobs[jobID] = nil
            continuation.yield(.removeJob(jobID))
        }
    }

    func currentJob(_ id: UUID) -> DownloadJob? { jobs[id] }

    func currentJobs() -> [DownloadJob] {
        Array(jobs.values)
    }

    func updatePowerState(connected: Bool) {
        isConnectedToPower = connected
        schedulePendingJobs()
    }

    private func schedulePendingJobs() {
        let currentJobs = jobs.values.filter { !pendingAdmissions.contains($0.id) }
        let runningJobIDs = Set(runningTasks.keys).union(executionAttempts.keys).union(resumeOperations.keys).union(pauseControls.keys).union(transferRecoveries.keys)
        let currentSettings = settings
        let network = currentNetwork
        Task {
            let pending = await scheduler.pendingDownloads(
                jobs: currentJobs,
                runningJobIDs: runningJobIDs,
                settings: currentSettings,
                network: network
            )
            schedule(pending)
        }
    }

    private func schedule(_ pending: [ScheduledDownload]) {
        for candidate in pending {
            guard let job = jobs[candidate.jobID],
                  !pendingAdmissions.contains(job.id),
                  runningTasks[job.id] == nil,
                  executionAttempts[job.id] == nil,
                  transferRecoveries[job.id] == nil,
                  resumeOperations[job.id] == nil, pauseControls[job.id] == nil,
                  [
                      DownloadJobState.queued,
                      .waitingForNetwork,
                      .waitingForWiFi,
                      .waitingForCellularApproval,
                      .waitingForRetry,
                      .waitingForPower,
                  ].contains(job.state),
                  networkDecision(for: job)
                    == candidate.networkDecision
            else {
                continue
            }
            if (settings.waitForCharging == true || job.configuration.waitForCharging == true) && !isConnectedToPower {
                setWaitingState(jobID: job.id, state: .waitingForPower, message: nil)
                continue
            }
            switch candidate.networkDecision {
            case .allow, .requireCellularConfirmation:
                runningTasks[job.id] = Task { [weak self] in
                    await self?.run(jobID: job.id)
                }
            case .waitForWiFi, .waitForUnmeteredNetwork:
                setWaitingState(
                    jobID: job.id,
                    state: .waitingForWiFi,
                    message: nil
                )
            case .waitForConnectivity, .waitForUnconstrainedNetwork:
                setWaitingState(
                    jobID: job.id,
                    state: .waitingForNetwork,
                    message: nil
                )
            }
        }
    }

    private func run(jobID: UUID) async {
        let attempt = UUID()
        executionAttempts[jobID] = attempt
        (downloader as? StreamDownloadService)?.bindAttempt(jobID: jobID, attempt: attempt)
        if nativeAcknowledgementEnabled, let job = jobs[jobID] {
            do { try await publicationWriter(job) }
            catch {
                await finishExecutionDeferral(jobID, status: .init(state: .denied), persistenceFailure: true)
                executionAttempts[jobID] = nil
                schedulePendingJobs()
                return
            }
        }
        guard jobs[jobID]?.state.isTerminal == false, jobs[jobID]?.state != .paused, !Task.isCancelled else {
            executionAttempts[jobID] = nil
            runningTasks[jobID] = nil
            schedulePendingJobs()
            return
        }
        if let job = jobs[jobID] {
            await processingContinuation?.begin(job: job, attempt: attempt) { [weak self] in
                await self?.expireProcessing(jobID: jobID, attempt: attempt)
            }
        }
        await runPipeline(jobID: jobID, attempt: attempt)
        await processingContinuation?.finish(jobID: jobID, attempt: attempt, success: jobs[jobID]?.state == .completed)
        if executionAttempts[jobID] == attempt {
            executionAttempts.removeValue(forKey: jobID)
            progressEmissionTimes.removeValue(forKey: jobID)
            progressEmissionStages.removeValue(forKey: jobID)
        }
        transferActivity[jobID] = nil
        await finalizeTransferRecovery(jobID)
        resumeEligibleForegroundJobs()
        schedulePendingJobs()
    }

    private func runPipeline(jobID: UUID, attempt: UUID) async {
        do {
            let admitted = jobs[jobID]?.pipelineCheckpoint?.publicationPlan != nil
                ? true : try await authorizeCurrentNetwork(jobID: jobID)
            guard admitted else {
                runningTasks[jobID] = nil
                schedulePendingJobs()
                return
            }
            guard jobs[jobID]?.state != .paused else {
                runningTasks[jobID] = nil
                schedulePendingJobs()
                return
            }
            while true {
                do {
                    try await runPipelineAttempt(jobID: jobID, attempt: attempt)
                    break
                } catch DownloadPipelineControl.restartAfterExecutionGrant {
                    continue
                } catch let unavailable as BackgroundExecutionUnavailable {
                    throw unavailable
                } catch is NativeTransferCheckpointError {
                    throw NativeTransferCheckpointError.persistenceUnavailable
                } catch ApplePlaybackVerifierError.requiresForeground {
                    if Task.isCancelled { throw CancellationError() }
                    if var job = jobs[jobID], !job.state.isTerminal {
                        job.state = .needsAttention
                        job.stage = .waiting
                        job.foregroundResumeReason = .legacyPlayback
                        job.errorCode = "playback_requires_foreground"
                        job.errorMessage = ApplePlaybackVerifierError.requiresForeground.localizedDescription
                        job.updatedAt = .now
                        jobs[jobID] = job
                        continuation.yield(.upsertJob(job))
                    }
                    break
                } catch DownloadPipelineControl.deferredForNetwork {
                    runningTasks[jobID] = nil
                    speedEstimators[jobID] = nil
                    schedulePendingJobs()
                    return
                } catch let error as StreamDownloadError
                    where error == .cancelled {
                    if await networkController.consumeRestart(
                        jobID: jobID
                    ) {
                        continue
                    }
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled || retryController.isCancellation(error) {
                        throw CancellationError()
                    }
                    try await waitForUserResume(jobID)
                    guard let job = jobs[jobID] else { break }
                    switch retryController.disposition(
                        for: error,
                        job: job
                    ) {
                    case .doNotRetry:
                        await finishFailure(jobID, error: error)
                        cleanupFailedWorkIfConfigured(jobID: jobID,
                            preserveFragments: isRecoverableFragmentInterruption(error))
                        runningTasks[jobID] = nil
                        speedEstimators[jobID] = nil
                        schedulePendingJobs()
                        return
                    case .waitForConnectivity:
                        setWaitingState(
                            jobID: jobID,
                            state: .waitingForNetwork,
                            message: IllucetError.networkOffline
                                .localizedDescription
                        )
                        runningTasks[jobID] = nil
                        speedEstimators[jobID] = nil
                        schedulePendingJobs()
                        return
                    case let .retry(reason, delay, _):
                        checkpointAutomaticRetry(
                            jobID: jobID,
                            reason: reason,
                            delay: delay
                        )
                        await diagnostics.record(
                            .warning,
                            subsystem: "downloads",
                            event: "automatic_retry_scheduled",
                            detail:
                                "job=\(jobID.uuidString), reason=\(reason.rawValue), attempt=\((jobs[jobID]?.retryCount ?? 0))"
                        )
                        try await retryController.wait(delay: delay)
                        guard try await authorizeCurrentNetwork(
                            jobID: jobID
                        ) else {
                            runningTasks[jobID] = nil
                            speedEstimators[jobID] = nil
                            schedulePendingJobs()
                            return
                        }
                    }
                }
            }
        } catch is NativeTransferCheckpointError {
            await finishExecutionDeferral(jobID, status: .init(state: .denied), persistenceFailure: true)
            return
        } catch let unavailable as BackgroundExecutionUnavailable {
            await finishExecutionDeferral(jobID, status: unavailable.status)
            return
        } catch is CancellationError {
            if await finishTransferRecoveryPipeline(jobID) { return }
            if await finishTransferRecoveryPipeline(jobID) { return }
            if await finishProcessingExpiration(jobID) { return }
            if await finishFragmentPauseIfRequested(jobID) { return }
            await finishCancellation(jobID)
            cleanupFailedWorkIfConfigured(jobID: jobID)
        } catch {
            if Task.isCancelled || retryController.isCancellation(error) {
                if await finishTransferRecoveryPipeline(jobID) { return }
                if await finishProcessingExpiration(jobID) { return }
                if await finishFragmentPauseIfRequested(jobID) { return }
                await finishCancellation(jobID)
            } else {
                await finishFailure(jobID, error: error)
            }
            cleanupFailedWorkIfConfigured(jobID: jobID)
        }
        await releaseTransferPermit(jobID: jobID)
        await releaseProcessingPermit(jobID: jobID)
        runningTasks[jobID] = nil
        speedEstimators[jobID] = nil
        schedulePendingJobs()
    }

    private func runPipelineAttempt(jobID: UUID, attempt: UUID) async throws {
        let runner = pipelineRunner
        let context = makePipelineContext(attempt: attempt)
        let task = Task { try await runner.run(jobID: jobID, context: context) }
        pipelineTasks[jobID] = (attempt, task)
        defer { if pipelineTasks[jobID]?.attempt == attempt { pipelineTasks[jobID] = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            if task.isCancelled { throw CancellationError() }
        } catch {
            if executionSuspensions.remove(jobID) != nil, !Task.isCancelled,
               executionAttempts[jobID] == attempt, jobs[jobID]?.state == .running {
                await releaseProcessingPermit(jobID: jobID)
                await releaseTransferPermit(jobID: jobID)
                try await requireExecution(jobID: jobID, attempt: attempt)
                throw DownloadPipelineControl.restartAfterExecutionGrant
            }
            throw error
        }
    }

    private func resetTransferActivity() {
        let now = transferClock()
        for id in Array(transferActivity.keys) { transferActivity[id]?.lastActivity = now }
    }

    /// Native ownership is inspected before recovery. This is also called on
    /// activation/resume; it does not depend on Queue being visible.
    func checkTransferLiveness() async {
        guard !checkingLiveness else { return }
        checkingLiveness = true
        defer { checkingLiveness = false }
        let now = transferClock()
        for id in Array(transferRecoveries.keys) {
            if let recovery = transferRecoveries[id], !recovery.controlAcknowledged,
               foregroundEligible, now >= recovery.acknowledgementDeadline {
                transferRecoveries[id]?.timedOut = true
                markTransferCleanupPending(id)
            }
        }
        guard foregroundEligible else { resetTransferActivity(); return }
        let snapshots = await downloader.nativeTaskSnapshot()
        for id in Array(transferActivity.keys) {
            guard var observation = transferActivity[id], transferRecoveries[id] == nil,
                  executionAttempts[id] == observation.attempt,
                  let job = jobs[id], job.state == .running,
                  [.downloadingVideo, .downloadingAudio].contains(job.stage),
                  networkDecision(for: job) == .allow else {
                transferActivity[id]?.lastActivity = now
                continue
            }
            let bytes = snapshots.filter { $0.descriptor.jobID == id }.reduce(into: Int64(0)) { total, entry in
                let sum = total.addingReportingOverflow(max(0, entry.networkBytesReceived))
                total = sum.overflow ? Int64.max : sum.partialValue
            }
            if bytes != observation.nativeBytes {
                observation.nativeBytes = bytes
                observation.lastActivity = now
            }
            transferActivity[id] = observation
            let pacing = (downloader as? StreamDownloadService)?.bandwidthLimiter.pacingDeadline(jobID: id)
            let wallNow = Date.now
            let availability = snapshots.filter { $0.descriptor.jobID == id }
                .compactMap { MediaAvailability.monotonicDeadline($0.earliestBeginDate, wallNow: wallNow, now: now) }
                .max()
            if livenessPolicy.isStalled(lastActivity: observation.lastActivity, now: now,
                                       pacingDeadline: pacing, availabilityDeadline: availability) {
                startTransferRecovery(id, attempt: observation.attempt)
            }
        }
    }

    private func startTransferRecovery(_ id: UUID, attempt: UUID) {
        guard transferRecoveries[id] == nil, var job = jobs[id], executionAttempts[id] == attempt else { return }
        let used = max(0, job.transferRecoveryCount ?? 0)
        let mayRetry = used < livenessPolicy.maximumRecoveries
        if mayRetry { job.transferRecoveryCount = used + 1 }
        job.foregroundResumeReason = nil
        jobs[id] = job
        transferRecoveries[id] = TransferRecovery(attempt: attempt,
            acknowledgementDeadline: transferClock() + livenessPolicy.acknowledgementTimeout, mayRetry: mayRetry)
        markTransferCleanupPending(id)
        runningTasks[id]?.cancel()
        beginTransferRecoveryControl(id, attempt: attempt)
    }

    private func beginTransferRecoveryControl(_ id: UUID, attempt: UUID) {
        let downloader = downloader
        transferRecoveryControls[id] = Task { [weak self] in
            let result = await downloader.cancel(jobID: id)
            await self?.acknowledgeTransferRecovery(id, attempt: attempt, result: result)
        }
    }

    private func markTransferCleanupPending(_ id: UUID) {
        guard var job = jobs[id] else { return }
        if job.state != .cancelled { job.state = .needsAttention }
        job.stage = .waiting
        job.errorCode = "transfer_cleanup_pending"
        job.errorMessage = "Waiting for transfer cleanup. Reopen Illucet if it does not finish."
        job.progress.smoothedBytesPerSecond = nil
        job.progress.downloadETASeconds = nil
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
    }

    private func acknowledgeTransferRecovery(_ id: UUID, attempt: UUID, result: StreamTaskControlResult) async {
        guard transferRecoveries[id]?.attempt == attempt else { return }
        transferRecoveries[id]?.controlAcknowledged = result.fullyAcknowledged
        if !result.fullyAcknowledged { transferRecoveries[id]?.timedOut = true }
        await diagnostics.record(.warning, subsystem: "downloads", event: "transfer_liveness_cleanup",
            detail: "job=\(id); attempt=\(attempt); acknowledged=\(result.fullyAcknowledged)")
        await finalizeTransferRecovery(id)
    }

    private func finishTransferRecoveryPipeline(_ id: UUID) async -> Bool {
        guard transferRecoveries[id] != nil else { return false }
        await releaseTransferPermit(jobID: id)
        await releaseProcessingPermit(jobID: id)
        transferRecoveries[id]?.pipelineFinished = true
        runningTasks[id] = nil
        speedEstimators[id] = nil
        await finalizeTransferRecovery(id)
        return true
    }

    private func finalizeTransferRecovery(_ id: UUID) async {
        guard let recovery = transferRecoveries[id], recovery.pipelineFinished,
              recovery.controlAcknowledged, !recovery.finalizing, executionAttempts[id] == nil else { return }
        transferRecoveries[id]?.finalizing = true
        await releaseTransferPermit(jobID: id)
        await releaseProcessingPermit(jobID: id)
        guard transferRecoveries[id]?.attempt == recovery.attempt else { return }
        transferRecoveries[id] = nil
        transferRecoveryControls[id] = nil
        guard var job = jobs[id] else { return }
        if job.state == .cancelled {
            job.errorCode = "user_cancelled"
            job.errorMessage = IllucetError.userCancelled.localizedDescription
            cleanupFailedWorkIfConfigured(jobID: id)
        } else if recovery.mayRetry && !recovery.timedOut {
            job.state = .queued
            job.stage = .restoring
            job.errorCode = nil
            job.errorMessage = nil
        } else {
            job.state = .needsAttention
            job.stage = .waiting
            job.errorCode = "transfer_stalled"
            job.errorMessage = "The transfer stopped responding. Retry to continue from verified files."
        }
        job.updatedAt = .now
        jobs[id] = job
        continuation.yield(.upsertJob(job))
        schedulePendingJobs()
    }

    private func finishFragmentPauseIfRequested(_ jobID: UUID) async -> Bool {
        guard let barrierID = fragmentPauseRestarts[jobID]?.id else { return false }
        await releaseTransferPermit(jobID: jobID)
        await releaseProcessingPermit(jobID: jobID)
        // Explicit Cancel can arrive during either await. Keep its marker and
        // cancellation intent until all control operations acknowledge too.
        guard fragmentPauseRestarts[jobID]?.id == barrierID else { return true }
        fragmentPauseRestarts[jobID]?.acknowledgeAcquisition()
        await finalizeFragmentPauseIfReady(jobID: jobID, barrierID: barrierID)
        return true
    }

    private func acknowledgeFragmentPauseControl(jobID: UUID, barrierID: UUID) async {
        guard fragmentPauseRestarts[jobID]?.id == barrierID else { return }
        fragmentPauseRestarts[jobID]?.acknowledgeControl()
        await finalizeFragmentPauseIfReady(jobID: jobID, barrierID: barrierID)
    }

    private func finalizeFragmentPauseIfReady(jobID: UUID, barrierID: UUID) async {
        guard var barrier = fragmentPauseRestarts[jobID], barrier.id == barrierID,
              barrier.claimFinalization() else { return }
        fragmentPauseRestarts[jobID] = barrier
        if barrier.cancellationRequested || jobs[jobID]?.state == .cancelled {
            await finishCancellation(jobID)
            cleanupFailedWorkIfConfigured(jobID: jobID)
        }
        // No replacement may be admitted until the old acquisition, its permit
        // releases and all job-wide transport cancellation calls have returned.
        fragmentPauseRestarts[jobID] = nil
        runningTasks[jobID] = nil
        speedEstimators[jobID] = nil
        schedulePendingJobs()
    }

    private func authorizeCurrentNetwork(
        jobID: UUID
    ) async throws -> Bool {
        try await networkController.authorize(
            jobID: jobID,
            settings: settings,
            network: currentNetwork,
            context: makeNetworkContext()
        )
    }

    private func networkDecision(
        for job: DownloadJob
    ) -> NetworkAccessDecision {
        DownloadScheduler.networkDecision(
            for: job,
            settings: settings,
            network: currentNetwork
        )
    }

    private func streamNetworkPolicy(
        for job: DownloadJob
    ) -> StreamTransferNetworkPolicy {
        DownloadScheduler.streamNetworkPolicy(
            for: job,
            settings: settings
        )
    }

    private func receiveNetworkSnapshot(
        _ snapshot: NetworkPathSnapshot
    ) async {
        guard snapshot != currentNetwork else { return }
        currentNetwork = snapshot
        resetTransferActivity()
        await networkController.receiveNetworkChange(
            snapshot,
            jobs: Array(jobs.values),
            settings: settings,
            context: makeNetworkContext()
        )
        schedulePendingJobs()
    }

    private func setWaitingState(
        jobID: UUID,
        state: DownloadJobState,
        message: String?
    ) {
        guard var job = jobs[jobID], job.state != .paused,
              job.state != state || job.errorMessage != message
        else {
            return
        }
        job.state = state
        job.stage = .waiting
        job.errorMessage = message
        job.updatedAt = .now
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
    }

    private func checkpointAutomaticRetry(
        jobID: UUID,
        reason: DownloadRetryReason,
        delay: Double
    ) {
        guard let current = jobs[jobID] else { return }
        let job = retryController.checkpoint(
            current,
            reason: reason,
            delay: delay
        )
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
    }

    private func makeNetworkContext() -> DownloadNetworkContext {
        DownloadNetworkContext(
            currentJob: { [weak self] jobID in
                await self?.pipelineJob(jobID)
            },
            persistJob: { [weak self] job in
                await self?.persistPipelineJob(job)
            },
            disableCellularPrompt: { [weak self] in
                await self?.disableCellularPrompt()
            },
            acquireTransferPermit: { [weak self] jobID in
                guard let self else { throw CancellationError() }
                try await self.acquireTransferPermit(jobID: jobID)
            },
            releaseTransferPermit: { [weak self] jobID in
                await self?.releaseTransferPermit(jobID: jobID)
            },
            cancelJob: { [weak self] jobID in
                await self?.cancel(jobID)
            }
        )
    }

    private func disableCellularPrompt() {
        settings.askBeforeCellular = false
    }

    private func makePipelineContext(attempt: UUID) -> DownloadPipelineContext {
        DownloadPipelineContext(
            requireExecution: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.requireExecution(jobID: id, attempt: attempt)
            },
            currentJob: { [weak self] jobID in
                await self?.pipelineJob(jobID)
            },
            settingsSnapshot: { [weak self] in
                await self?.pipelineSettings() ?? .defaults
            },
            folderBookmarkSnapshot: { [weak self] in
                await self?.pipelineFolderBookmark()
            },
            persistJob: { [weak self] job in
                await self?.persistPipelineJob(job)
            },
            checkpointJob: {
                [weak self] job, phase, sources, artwork, processed in
                guard let self else { return job }
                return await self.pipelineCheckpoint(
                    job,
                    phase: phase,
                    sourceFiles: sources,
                    artworkURL: artwork,
                    processedFileURL: processed
                )
            },
            authorizeNetwork: { [weak self] jobID in
                guard let self else { return false }
                return try await self.authorizeCurrentNetwork(
                    jobID: jobID
                )
            },
            streamNetworkPolicy: { [weak self] job in
                await self?.pipelineStreamNetworkPolicy(job)
                    ?? .unrestricted
            },
            acquireTransferPermit: { [weak self] jobID in
                guard let self else { throw CancellationError() }
                try await self.acquireTransferPermit(jobID: jobID)
            },
            releaseTransferPermit: { [weak self] jobID in
                await self?.releaseTransferPermit(jobID: jobID)
            },
            acquireProcessingPermit: { [weak self] jobID in
                guard let self else { throw CancellationError() }
                try await self.acquireProcessingPermit(jobID: jobID)
            },
            releaseProcessingPermit: { [weak self] jobID in
                await self?.releaseProcessingPermit(jobID: jobID)
            },
            recordTransferProgress: {
                [weak self] event, baseBytes, combinedTotal in
                await self?.recordTransferProgress(
                    event,
                    baseBytes: baseBytes,
                    combinedTotal: combinedTotal,
                    attempt: attempt
                )
            },
            recordProcessingProgress: {
                [weak self] event, jobID, expectedStage in
                await self?.recordProcessingProgress(
                    event,
                    jobID: jobID,
                    expectedStage: expectedStage,
                    attempt: attempt
                )
            },
            persistPublication: { [weak self] job in
                guard let self else { throw CancellationError() }
                return try await self.persistPublication(job, attempt: attempt)
            },
            publishOutput: { [weak self] job, plan, root in
                guard let self else { throw CancellationError() }
                return try await self.publishOutput(job, plan: plan, root: root, attempt: attempt)
            },
            completeDuplicateSkip: { [weak self] job in
                guard let self else { return job }
                return await self.pipelineCompleteDuplicateSkip(job, attempt: attempt)
            },
            checkpointExport: { [weak self] job, probe, result in
                guard let self else { return job }
                return await self.pipelineCheckpointExport(
                    job,
                    probe: probe,
                    result: result,
                    attempt: attempt
                )
            },
            checkpointPartialFile: {
                [weak self] job, fileURL, probe in
                guard let self else { return job }
                return await self.pipelineCheckpointPartialFile(
                    job,
                    fileURL: fileURL,
                    probe: probe,
                    attempt: attempt
                )
            },
            completeExport: {
                [weak self]
                job,
                probe,
                result,
                photoIdentifiers,
                shareRequest,
                temporaryRoot in
                guard let self else { return job }
                return await self.pipelineCompleteExport(
                    job,
                    probe: probe,
                    result: result,
                    photoIdentifiers: photoIdentifiers,
                    shareRequest: shareRequest,
                    temporaryRoot: temporaryRoot,
                    attempt: attempt
                )
            }
        )
    }

    private func pipelineJob(_ jobID: UUID) -> DownloadJob? {
        jobs[jobID]
    }

    private func pipelineSettings() -> AppSettings {
        settings
    }

    private func pipelineFolderBookmark() -> Data? {
        folderBookmark
    }

    private func pipelineStreamNetworkPolicy(
        _ job: DownloadJob
    ) -> StreamTransferNetworkPolicy {
        streamNetworkPolicy(for: job)
    }

    private func persistPipelineJob(_ input: DownloadJob) async {
        do { try await waitForUserResume(input.id) } catch { return }
        guard transferRecoveries[input.id] == nil else { return }
        guard jobs[input.id]?.state.isTerminal != true else { return }
        var job = input
        job.transferLimitOverride = jobs[input.id]?.transferLimitOverride
        if let current = jobs[job.id] {
            job.priority = current.priority
            job.retryRequestID = current.retryRequestID
            job.pipelineCheckpoint?.nativeFileReceipts = current.pipelineCheckpoint?.nativeFileReceipts
        }
        if let latest = jobs[job.id]?.pipelineCheckpoint?.fragmentURLRefreshCounts {
            var counts = job.pipelineCheckpoint?.fragmentURLRefreshCounts ?? [:]
            for (format, count) in latest { counts[format] = max(counts[format] ?? 0, count) }
            job.pipelineCheckpoint?.fragmentURLRefreshCounts = counts
        }
        jobs[job.id] = job
        continuation.yield(.upsertJob(job))
    }

    private func pipelineCheckpoint(
        _ input: DownloadJob,
        phase: DownloadPipelinePhase,
        sourceFiles: [String: URL]?,
        artworkURL: URL?,
        processedFileURL: URL?
    ) -> DownloadJob {
        var job = input
        job.transferLimitOverride = jobs[input.id]?.transferLimitOverride
        checkpoint(
            &job,
            phase: phase,
            sourceFiles: sourceFiles,
            artworkURL: artworkURL,
            processedFileURL: processedFileURL
        )
        return job
    }

    private func publishOutput(_ job: DownloadJob, plan: ExportPublicationPlan, root: URL, attempt: UUID) async throws -> DownloadJob {
        try await waitForUserResume(job.id)
        try await requireExecution(jobID: job.id, attempt: attempt)
        return try await DownloadPublicationWorkflow(exportFlow: exportFlow).run(
            job: job, plan: plan, root: root, context: makePipelineContext(attempt: attempt))
    }

    private func persistPublication(_ input: DownloadJob, attempt: UUID) async throws -> DownloadJob {
        guard executionAttempts[input.id] == attempt, let current = jobs[input.id] else { throw CancellationError() }
        var job = input
        job.transferLimitOverride = jobs[input.id]?.transferLimitOverride
        if current.state == .cancelled {
            job.state = current.state; job.errorCode = current.errorCode; job.errorMessage = current.errorMessage
        }
        job.pipelineCheckpoint?.publicationRevision = max(
            current.pipelineCheckpoint?.publicationRevision ?? 0,
            input.pipelineCheckpoint?.publicationRevision ?? 0) + 1
        job.updatedAt = .now
        if job.state == .completed {
            // Keep the terminal event and History in the same committed actor turn.
            // In particular, do not expose completion while its disk acknowledgement awaits.
            do { try await publicationWriter(job) }
            catch { throw ExportPublicationError.persistenceUnavailable }
            guard executionAttempts[job.id] == attempt, let latest = jobs[job.id] else { throw CancellationError() }
            return latest.state == .cancelled ? latest : job
        }
        jobs[job.id] = job
        continuation.yield(.upsertJob(job))
        do { try await publicationWriter(job) }
        catch {
            // No external effect follows a failed intent acknowledgement in this process.
            // A disk copy that still says committing remains conservative after relaunch.
            if var retained = jobs[job.id] {
                for index in retained.pipelineCheckpoint?.publicationReceipts?.indices ?? 0..<0 {
                    if retained.pipelineCheckpoint?.publicationReceipts?[index].state == .committing {
                        retained.pipelineCheckpoint?.publicationReceipts?[index].state = .notStarted
                        retained.pipelineCheckpoint?.publicationReceipts?[index].failureCode = "checkpoint_failed"
                    }
                }
                jobs[job.id] = retained
            }
            throw ExportPublicationError.persistenceUnavailable
        }
        guard executionAttempts[job.id] == attempt, let latest = jobs[job.id] else { throw CancellationError() }
        return latest
    }

    private func canCommitExport(_ job: DownloadJob, attempt: UUID) -> Bool {
        !Task.isCancelled && executionAttempts[job.id] == attempt
            && jobs[job.id]?.state.isTerminal == false
    }

    /// No suspension between storing authoritative state and emitting its events.
    private func commitExport(_ job: DownloadJob, completed: Bool = false) {
        jobs[job.id] = job
        continuation.yield(.upsertJob(job))
        if completed { continuation.yield(.addHistory(HistoryRecord(job: job))) }
    }

    private func pipelineCompleteDuplicateSkip(
        _ input: DownloadJob,
        attempt: UUID
    ) async -> DownloadJob {
        guard canCommitExport(input, attempt: attempt) else { return jobs[input.id] ?? input }
        let job = exportFlow.prepareDuplicateSkip(input)
        commitExport(job, completed: true)
        await exportFlow.recordDuplicateSkip(job)
        return job
    }

    private func pipelineCheckpointExport(
        _ input: DownloadJob,
        probe: MediaProbeResult?,
        result: ExportResult,
        attempt: UUID
    ) -> DownloadJob {
        guard canCommitExport(input, attempt: attempt) else { return jobs[input.id] ?? input }
        let job = exportFlow.checkpoint(input, probe: probe, result: result)
        commitExport(job)
        return job
    }

    private func pipelineCheckpointPartialFile(
        _ input: DownloadJob,
        fileURL: URL,
        probe: MediaProbeResult?,
        attempt: UUID
    ) -> DownloadJob {
        guard canCommitExport(input, attempt: attempt) else { return jobs[input.id] ?? input }
        let job = exportFlow.checkpointPartialFile(input, fileURL: fileURL, probe: probe)
        commitExport(job)
        return job
    }

    private func pipelineCompleteExport(
        _ input: DownloadJob,
        probe: MediaProbeResult?,
        result: ExportResult,
        photoIdentifiers: [String],
        shareRequest: SharePresentationRequest?,
        temporaryRoot: URL,
        attempt: UUID
    ) async -> DownloadJob {
        guard canCommitExport(input, attempt: attempt) else { return jobs[input.id] ?? input }
        var cleaning = input
        cleaning.state = .running
        cleaning.stage = .cleaningUp
        cleaning.updatedAt = .now
        commitExport(cleaning)
        var job = exportFlow.prepareCompletion(
            cleaning, probe: probe, result: result,
            photoIdentifiers: photoIdentifiers, shareRequest: shareRequest
        )
        if input.pipelineCheckpoint?.publicationPlan != nil {
            job.pipelineCheckpoint?.publicationPlan = input.pipelineCheckpoint?.publicationPlan
            do {
                job = try await persistPublication(job, attempt: attempt)
                guard job.state == .completed else { return job }
            } catch {
                // Keep all verified inputs/receipts when the final acknowledgement fails.
                let revision = jobs[job.id]?.pipelineCheckpoint?.publicationRevision
                job.pipelineCheckpoint = input.pipelineCheckpoint
                job.pipelineCheckpoint?.publicationRevision = revision
                jobs[job.id] = job
                await finishFailure(job.id, error: error)
                return jobs[job.id] ?? job
            }
        }
        try? fileManager.removeItem(at: temporaryRoot)
        commitExport(job, completed: true)
        await exportFlow.finishCompletion(
            job, shareRequest: shareRequest,
            notifyDownloadComplete: settings.notifyDownloadComplete
        )
        return job
    }

    private func acquireTransferPermit(jobID: UUID, resuming: Bool = false) async throws {
        while true {
            if !resuming { try await waitForUserResume(jobID) }
            guard var job = jobs[jobID], !job.state.isTerminal, job.state != .paused else { throw CancellationError() }
            let version = pauseVersions[jobID]
            job.state = .running
            job.stage = .waitingForTransfer
            job.updatedAt = .now
            jobs[jobID] = job
            continuation.yield(.upsertJob(job))
            do { try await scheduler.acquireTransfer(jobID: jobID, priority: job.priority, allowsOverLimit: job.transferLimitOverride == true) }
            catch {
                if !Task.isCancelled, jobs[jobID]?.state.isTerminal == false,
                   version != pauseVersions[jobID], !resuming { continue }
                throw error
            }
            guard let current = jobs[jobID], !current.state.isTerminal, !Task.isCancelled else {
                await scheduler.releaseTransfer(jobID: jobID)
                throw CancellationError()
            }
            if current.state == .paused || version != pauseVersions[jobID] {
                await scheduler.releaseTransfer(jobID: jobID)
                if resuming { throw CancellationError() }
                continue
            }
            if let attempt = executionAttempts[jobID] {
                transferActivity[jobID] = TransferActivity(attempt: attempt, lastActivity: transferClock())
            }
            return
        }
    }

    private func releaseTransferPermit(jobID: UUID) async {
        if let recovery = transferRecoveries[jobID], !recovery.controlAcknowledged { return }
        await scheduler.releaseTransfer(jobID: jobID)
    }

    private func acquireProcessingPermit(jobID: UUID) async throws {
        try await waitForUserResume(jobID)
        if let attempt = executionAttempts[jobID] { try await requireExecution(jobID: jobID, attempt: attempt) }
        guard var job = jobs[jobID], !job.state.isTerminal else {
            throw CancellationError()
        }
        job.state = .running
        job.stage = .waitingForProcessing
        job.updatedAt = .now
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
        try await scheduler.acquireProcessing(jobID: jobID)
        processingPermitJobs.insert(jobID)
        guard let current = jobs[jobID], !current.state.isTerminal else {
            await scheduler.releaseProcessing(jobID: jobID)
            throw CancellationError()
        }
        if let attempt = executionAttempts[jobID] {
            await processingContinuation?.begin(job: current, attempt: attempt) { [weak self] in
                await self?.expireProcessing(jobID: jobID, attempt: attempt)
            }
        }
        if let attempt = executionAttempts[jobID] { try await requireExecution(jobID: jobID, attempt: attempt) }
        try Task.checkCancellation()
    }

    /// An App Intent's granted window belongs to this one durable request.
    func beginIntentExecution(jobID: UUID) { intentExecution.insert(jobID) }

    func endIntentExecution(jobID: UUID) async {
        intentExecution.remove(jobID)
        await suspendUnsupportedProcessing(jobID: jobID)
    }

    func applicationDidEnterBackground() async {
        if sceneRevision == nil { foregroundEligible = false }
        await synchronizeTransferForegroundState()
        guard !foregroundEligible else { return }
        resetTransferActivity()
        for id in Array(jobs.keys) {
            guard !foregroundEligible else { break }
            await suspendUnsupportedProcessing(jobID: id)
        }
    }

    func resumeForegroundJobs() async {
        if sceneRevision == nil, !foregroundEligible {
            foregroundEligible = true
            foregroundActivation &+= 1
            resetTransferActivity()
        }
        await synchronizeTransferForegroundState()
        resumeEligibleForegroundJobs()
        await checkTransferLiveness()
    }

    func setForegroundEligibility(_ eligible: Bool, revision: UInt64) async {
        guard sceneRevision.map({ revision > $0 }) ?? true else { return }
        sceneRevision = revision
        if eligible != foregroundEligible { resetTransferActivity() }
        if eligible && !foregroundEligible { foregroundActivation &+= 1 }
        foregroundEligible = eligible
        await synchronizeTransferForegroundState()
        guard sceneRevision == revision else { return }
        if eligible {
            for job in Array(jobs.values) where job.state == .running {
                if let attempt = executionAttempts[job.id] {
                    await processingContinuation?.begin(job: job, attempt: attempt) { [weak self] in
                        await self?.expireProcessing(jobID: job.id, attempt: attempt)
                    }
                }
            }
            resumeEligibleForegroundJobs()
            await checkTransferLiveness()
        }
        else { await applicationDidEnterBackground() }
    }

    private func synchronizeTransferForegroundState() async {
        // An older scene callback may finish its downloader hop after a newer
        // one. Reapply current authority before either callback continues.
        while true {
            let active = foregroundEligible
            await downloader.setForegroundActive(active)
            if active == foregroundEligible { return }
        }
    }

    private func resumeEligibleForegroundJobs() {
        guard foregroundEligible else { return }
        for job in jobs.values where job.resumesOnForeground && runningTasks[job.id] == nil
            && executionAttempts[job.id] == nil && foregroundResumedAt[job.id] != foregroundActivation {
            foregroundResumedAt[job.id] = foregroundActivation
            retry(job.id, resetForegroundBudget: false)
        }
    }

    private func suspendUnsupportedProcessing(jobID: UUID) async {
        guard let job = jobs[jobID], job.state == .running,
              job.stage.requiresInProcessExecution || FragmentSourceLeases.shared.hasActiveSource(jobID: jobID),
              !intentExecution.contains(jobID), let attempt = executionAttempts[jobID],
              let processingContinuation,
              !(await processingContinuation.canProcess(jobID: jobID, attempt: attempt)) else { return }
        let status = await processingContinuation.status(jobID: jobID, attempt: attempt)
        if status.state.isPending {
            guard job.stage != .waitingForBackgroundTime, let pipeline = pipelineTasks[jobID], pipeline.attempt == attempt else { return }
            executionSuspensions.insert(jobID)
            pipeline.task.cancel()
            await mediaProcessor.cancel(operationID: jobID)
        } else { await expireProcessing(jobID: jobID, attempt: attempt) }
    }

    private func expireProcessing(jobID: UUID, attempt: UUID) async {
        guard executionAttempts[jobID] == attempt, let job = jobs[jobID], job.state == .running,
              job.stage.requiresInProcessExecution || FragmentSourceLeases.shared.hasActiveSource(jobID: jobID),
              !intentExecution.contains(jobID),
              let task = runningTasks[jobID] else { return }
        expiredProcessing.insert(jobID)
        task.cancel()
        await mediaProcessor.cancel(operationID: jobID)
        await task.value
    }

    private func finishProcessingExpiration(_ id: UUID) async -> Bool {
        guard expiredProcessing.remove(id) != nil else { return false }
        if var job = jobs[id], !job.state.isTerminal {
            job.state = .needsAttention
            job.stage = .waiting
            job.foregroundResumeReason = .processingTime
            job.errorCode = "background_processing_expired"
            job.errorMessage = "Open Illucet to continue processing. Your downloaded media has been kept."
            job.updatedAt = .now
            jobs[id] = job
            continuation.yield(.upsertJob(job))
        }
        // Keep completed source/checkpoint files; in-flight native output is rejected.
        await releaseTransferPermit(jobID: id)
        await releaseProcessingPermit(jobID: id)
        runningTasks[id] = nil
        speedEstimators[id] = nil
        schedulePendingJobs()
        return true
    }

    private func releaseProcessingPermit(jobID: UUID) async {
        processingPermitJobs.remove(jobID)
        await scheduler.releaseProcessing(jobID: jobID)
    }

    private func requireExecution(jobID: UUID, attempt: UUID) async throws {
        try await waitForUserResume(jobID)
        guard executionAttempts[jobID] == attempt else { throw CancellationError() }
        guard let controller = processingContinuation, !intentExecution.contains(jobID) else { return }
        if await controller.canProcess(jobID: jobID, attempt: attempt) { return }
        let previousStage = jobs[jobID]?.stage ?? .preparing
        let heldProcessing = processingPermitJobs.contains(jobID)
        while !(await controller.canProcess(jobID: jobID, attempt: attempt)) {
            let status = await controller.status(jobID: jobID, attempt: attempt)
            guard status.state.isPending else { throw BackgroundExecutionUnavailable(status: status) }
            guard var waiting = jobs[jobID], !waiting.state.isTerminal, waiting.state != .paused else { throw CancellationError() }
            waiting.state = .running
            waiting.stage = .waitingForBackgroundTime
            waiting.progress.smoothedBytesPerSecond = nil
            waiting.progress.downloadETASeconds = nil
            waiting.updatedAt = .now
            jobs[jobID] = waiting
            continuation.yield(.upsertJob(waiting))
            await releaseProcessingPermit(jobID: jobID)
            try await controller.waitForExecution(jobID: jobID, attempt: attempt)
            try Task.checkCancellation()
            guard executionAttempts[jobID] == attempt, jobs[jobID]?.state == .running else { throw CancellationError() }
        }
        if heldProcessing { try await acquireProcessingPermit(jobID: jobID) }
        if var current = jobs[jobID], current.stage == .waitingForBackgroundTime {
            current.stage = previousStage
            current.updatedAt = .now
            jobs[jobID] = current
            continuation.yield(.upsertJob(current))
        }
    }

    private func requireTransferExecution(jobID: UUID) async throws {
        // Submitting a prepared native HTTP request is bounded delegate work,
        // not CPU processing. A live app callback may hand it to the daemon
        // without a continued-processing grant. Extraction/assembly remain gated.
        try await waitForUserResume(jobID)
        try Task.checkCancellation()
        guard executionAttempts[jobID] != nil, jobs[jobID]?.state.isTerminal == false else { throw CancellationError() }
    }

    private func executionAttempt(for id: UUID) -> UUID? { executionAttempts[id] }

    private func finishExecutionDeferral(_ id: UUID, status: ContinuedProcessingStatus, persistenceFailure: Bool = false) async {
        if var job = jobs[id], !job.state.isTerminal, job.state != .paused {
            job.state = .needsAttention
            job.stage = .waiting
            job.foregroundResumeReason = persistenceFailure ? nil : .processingTime
            job.errorCode = persistenceFailure ? "state_save_failed" : status.state == .expired || status.reason == .expired
                ? "background_processing_expired" : "background_execution_denied"
            job.errorMessage = persistenceFailure ? "Couldn't save the download state. Verified files have been kept. Retry to continue."
                : "Open Illucet to continue. Verified files have been kept."
            job.updatedAt = .now
            jobs[id] = job
            continuation.yield(.upsertJob(job))
        }
        await releaseTransferPermit(jobID: id)
        await releaseProcessingPermit(jobID: id)
        runningTasks[id] = nil
        speedEstimators[id] = nil
    }

    private func checkpoint(
        _ job: inout DownloadJob,
        phase: DownloadPipelinePhase,
        sourceFiles: [String: URL]? = nil,
        artworkURL: URL? = nil,
        processedFileURL: URL? = nil
    ) {
        if transferRecoveries[job.id] != nil, let current = jobs[job.id] {
            job.state = current.state
            job.stage = current.stage
            job.errorCode = current.errorCode
            job.errorMessage = current.errorMessage
        }
        if let latest = jobs[job.id], latest.state.isTerminal {
            job = latest
            return
        }
        if let latest = jobs[job.id] {
            job.transferLimitOverride = latest.transferLimitOverride
            if latest.state == .paused {
                job.state = .paused
                job.resumableTransferStage = latest.resumableTransferStage
            }
            job.progress = latest.progress
            job.activeTransferDescriptors =
                latest.activeTransferDescriptors
        }
        var value = job.pipelineCheckpoint
            ?? DownloadPipelineCheckpoint(phase: phase)
        value.nativeFileReceipts = jobs[job.id]?.pipelineCheckpoint?.nativeFileReceipts
        if let latest = jobs[job.id]?.pipelineCheckpoint?.fragmentURLRefreshCounts {
            value.fragmentURLRefreshCounts = latest
        }
        value.phase = phase
        if let sourceFiles {
            value.sourceFiles = sourceFiles
        }
        if let artworkURL {
            value.artworkURL = artworkURL
        }
        if let processedFileURL {
            value.processedFileURL = processedFileURL
        }
        value.updatedAt = .now
        job.pipelineCheckpoint = value
        job.updatedAt = .now
        jobs[job.id] = job
        continuation.yield(.upsertJob(job))
        let storage = storage
        let jobID = job.id
        Task {
            await storage.touchTemporaryFiles(for: jobID)
        }
    }

    private func emitProgress(_ job: DownloadJob) {
        let now = ContinuousClock.now
        let finishedStage = job.stage.isProcessingWork ? job.progress.processingFraction == 1
            : job.progress.totalBytes.map { $0 > 0 && job.progress.bytesDownloaded >= $0 } ?? false
        guard finishedStage || progressEmissionStages[job.id] != job.stage
            || (progressEmissionTimes[job.id].map({ $0.duration(to: now) >= .milliseconds(200) }) ?? true) else { return }
        progressEmissionStages[job.id] = job.stage
        progressEmissionTimes[job.id] = now
        continuation.yield(.upsertJob(job))
    }

    private func recordTransferProgress(
        _ event: StreamTransferProgress,
        baseBytes: Int64,
        combinedTotal: Int64?,
        attempt: UUID
    ) async {
        guard executionAttempts[event.jobID] == attempt,
              var job = jobs[event.jobID], job.state == .running,
              job.stage.presentsTransferMetrics else { return }
        transferActivity[event.jobID]?.lastActivity = transferClock()
        var estimator = speedEstimators[event.jobID] ?? RollingSpeedEstimator()
        estimator.record(
            totalBytes: baseBytes + event.totalBytesWritten,
            at: ProcessInfo.processInfo.systemUptime
        )
        speedEstimators[event.jobID] = estimator
        job.progress.bytesDownloaded = baseBytes + event.totalBytesWritten
        job.progress.verifiedReusableBytes =
            baseBytes + event.verifiedReusableBytes
        job.progress.totalBytes = combinedTotal
        job.progress.instantaneousBytesPerSecond =
            event.instantaneousBytesPerSecond
        job.progress.smoothedBytesPerSecond =
            estimator.smoothedBytesPerSecond
        job.progress.sampleCount = estimator.sampleCount
        job.progress.currentStream = event.streamID
        job.progress.downloadETASeconds = nil
        if let combinedTotal {
            let remaining = max(
                0,
                combinedTotal - job.progress.bytesDownloaded
            )
            job.progress.downloadETASeconds = estimator.eta(
                remainingBytes: remaining
            )
            job.progress.overallFraction = min(
                0.78,
                Double(job.progress.bytesDownloaded)
                    / Double(max(1, combinedTotal)) * 0.78
            )
        }
        job.updatedAt = .now
        jobs[event.jobID] = job
        emitProgress(job)
        if job.activeTransferDescriptors?.isEmpty != false {
            let registrations =
                await downloader.reconcileBackgroundTasks()
                    .filter {
                        $0.descriptor.jobID == event.jobID
                    }
            if !registrations.isEmpty,
               var refreshed = jobs[event.jobID] {
                refreshed.activeTransferDescriptors =
                    registrations.map(\.descriptor)
                refreshed.updatedAt = .now
                jobs[event.jobID] = refreshed
                continuation.yield(.upsertJob(refreshed))
            }
        }
    }

    private func recordProcessingProgress(
        _ event: MediaProcessingProgress,
        jobID: UUID,
        expectedStage: DownloadStage,
        attempt: UUID
    ) {
        guard executionAttempts[jobID] == attempt, event.operationID == jobID,
              var job = jobs[jobID], job.state == .running
        else { return }
        guard let presentedStage = job.stage.applyingProcessingProgress(
            expectedStage: expectedStage,
            eventStage: event.stage
        ) else { return }
        job.stage = presentedStage
        job.progress.processingFraction = event.completedFraction
        if let fraction = event.completedFraction {
            job.progress.overallFraction = 0.78 + fraction * 0.18
        }
        job.progress.processingETASeconds = event.estimatedRemainingSeconds
        job.updatedAt = .now
        jobs[jobID] = job
        emitProgress(job)
    }

    private func update(
        _ job: inout DownloadJob,
        state: DownloadJobState,
        stage: DownloadStage
    ) {
        job.state = state
        job.stage = stage
        job.updatedAt = .now
        jobs[job.id] = job
        continuation.yield(.upsertJob(job))
    }

    private func finishCancellation(_ jobID: UUID) async {
        guard var job = jobs[jobID], job.state != .cancelled else { return }
        job.state = .cancelled
        job.stage = .cleaningUp
        job.errorCode = "user_cancelled"
        job.errorMessage = IllucetError.userCancelled.localizedDescription
        if var application = job.sponsorBlockApplication,
           application.status == .requested
            || application.status == .applied {
            application.status = .cancelled
            job.sponsorBlockApplication = application
        }
        job.updatedAt = .now
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
        await diagnostics.record(
            .info,
            subsystem: "downloads",
            event: "job_cancelled",
            detail: "job=\(jobID.uuidString)"
        )
    }

    private func finishFailure(_ jobID: UUID, error: any Error) async {
        guard var job = jobs[jobID] else { return }
        let message = safeErrorMessage(error)
        if job.configuration.destination == .share,
           job.exportOutcome == .sharePending
            || job.shareCompletionState == .pending {
            job.exportOutcome = .shareFailed
            job.shareCompletionState = .failed
            job.shareErrorMessage = message
        }
        job.state = .failed
        job.stage = .cleaningUp
        job.errorCode = errorCode(error)
        if error is ExportPublicationError, job.outputURL != nil,
           job.configuration.destination == .filesAndPhotos,
           job.pipelineCheckpoint?.publicationReceipts?.contains(where: { $0.destination == .photos && $0.failureCode != nil }) == true {
            job.errorCode = "files_saved_photos_failed"
        }
        job.retryExhausted = retryController.exhausted(error: error, job: job)
        job.errorMessage = message
        if var application = job.sponsorBlockApplication,
           application.status == .requested
            || application.status == .applied {
            application.status = .failed
            job.sponsorBlockApplication = application
        }
        job.updatedAt = .now
        jobs[jobID] = job
        if job.pipelineCheckpoint?.publicationPlan != nil { try? await publicationWriter(job) }
        continuation.yield(.upsertJob(job))
        continuation.yield(.addHistory(HistoryRecord(job: job)))
        await diagnostics.record(
            .error,
            subsystem: "downloads",
            event: "job_failed",
            detail: "job=\(jobID.uuidString), code=\(job.errorCode ?? "unknown")"
        )
        if settings.notifyFailure {
            await notifications.notifyFailure(job: job)
        }
    }

    private func errorCode(_ error: any Error) -> String {
        if let publication = error as? ExportPublicationError {
            switch publication {
            case .persistenceUnavailable: return "export_checkpoint_failed"
            case .outcomeUnknown: return "export_outcome_unknown"
            case .inputsUnavailable: return "export_inputs_unavailable"
            case let .destinationFailed(_, code): return code
            }
        }
        if case IllucetError.insufficientStorage = error { return "insufficient_storage" }
        if let account = error as? AccountError {
            switch account {
            case .expired: return "account_session_expired"
            case .unavailable: return "account_removed"
            case .storageUnavailable: return "account_storage_unavailable"
            default: return "account_session_invalid"
            }
        }
        if let extraction = error as? ExtractionError {
            switch extraction {
            case .invalidURL: return "invalid_url"
            case .unsupportedSite: return "unsupported_site"
            case .cancelled: return "cancelled"
            case let .extractorFailure(code, _, _): return code
            case .invalidResponse: return "invalid_extractor_response"
            }
        }
        if let resolution = error as? StreamResolutionError {
            if case let .resolverFailure(code, _) = resolution {
                return code
            }
            return "stream_resolution_failed"
        }
        if let transfer = error as? StreamDownloadError {
            return transfer.diagnosticCode
        }
        if error is MediaProcessorError {
            return "media_processing_failed"
        }
        if let subtitle = error as? SubtitlePipelineError {
            return subtitle.diagnosticCode
        }
        if let export = error as? ExportError {
            switch export {
            case .duplicateDecisionRequired:
                return "duplicate_decision_required"
            case .filesSavedPhotosFailed:
                return "files_saved_photos_failed"
            }
        }
        if error is IllucetError {
            return "illucet_error"
        }
        return "unknown_internal_error"
    }

    private func safeErrorMessage(_ error: any Error) -> String {
        if let transfer = error as? StreamDownloadError {
            return String(transfer.localizedDescription.prefix(512))
        }
        let message = error.localizedDescription
        guard
            !message.localizedCaseInsensitiveContains("http"),
            !message.localizedCaseInsensitiveContains("cookie"),
            !message.localizedCaseInsensitiveContains("token"),
            !message.localizedCaseInsensitiveContains("signature")
        else {
            return "The job failed. Technical details were redacted."
        }
        return String(message.prefix(512))
    }

    private func temporaryRoot(for jobID: UUID) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func isRecoverableFragmentInterruption(_ error: any Error) -> Bool {
        switch DownloadRetryPolicy().classify(error) {
        case .retryable, .waitForConnectivity: true
        case .cancelled, .permanent: false
        }
    }

    private func cleanupFailedWorkIfConfigured(jobID: UUID, preserveFragments: Bool = false) {
        guard transferRecoveries[jobID] == nil else { return }
        if jobs[jobID]?.state == .cancelled {
            try? (downloader as? any FragmentCheckpointManaging)?
                .discardFragmentCheckpoints(jobID: jobID, formatID: nil)
        }
        guard jobs[jobID]?.pipelineCheckpoint?.publicationPlan == nil,
              !settings.keepTemporaryFilesAfterFailure else { return }
        if !preserveFragments {
            try? (downloader as? any FragmentCheckpointManaging)?
                .discardFragmentCheckpoints(jobID: jobID, formatID: nil)
        }
        try? fileManager.removeItem(at: temporaryRoot(for: jobID))
        guard var job = jobs[jobID] else { return }
        let refreshCounts = job.pipelineCheckpoint?.fragmentURLRefreshCounts
        job.pipelineCheckpoint = preserveFragments ? DownloadPipelineCheckpoint(phase: .queued) : nil
        job.pipelineCheckpoint?.fragmentURLRefreshCounts = refreshCounts
        job.activeTransferDescriptors = nil
        job.updatedAt = .now
        jobs[jobID] = job
        continuation.yield(.upsertJob(job))
    }

}
