import Foundation

private struct NetworkContinuationEntry {
    let jobID: UUID
    let continuation: CheckedContinuation<NetworkAccessChoice, Never>
}

struct DownloadNetworkContext: Sendable {
    let currentJob:
        @Sendable (UUID) async -> DownloadJob?
    let persistJob:
        @Sendable (DownloadJob) async -> Void
    let disableCellularPrompt:
        @Sendable () async -> Void
    let acquireTransferPermit:
        @Sendable (UUID) async throws -> Void
    let releaseTransferPermit:
        @Sendable (UUID) async -> Void
    let cancelJob:
        @Sendable (UUID) async -> Void
}

/// Owns user network decisions and transfer suspension/resumption. Queue
/// ordering and the underlying concurrency budgets remain in
/// `DownloadScheduler`.
actor DownloadNetworkController {
    private let downloader: any StreamDownloading
    private let eventSink:
        @Sendable (DownloadCoordinatorEvent) -> Void
    private var continuations: [
        UUID: NetworkContinuationEntry
    ] = [:]
    private var requestByJob: [UUID: UUID] = [:]
    private var suspendedJobs: Set<UUID> = []
    private var restartJobs: Set<UUID> = []
    private var promptTasks: [UUID: Task<Void, Never>] = [:]

    init(
        downloader: any StreamDownloading,
        eventSink: @escaping
            @Sendable (DownloadCoordinatorEvent) -> Void
    ) {
        self.downloader = downloader
        self.eventSink = eventSink
    }

    func resolve(
        requestID: UUID,
        choice: NetworkAccessChoice
    ) {
        guard let entry = continuations.removeValue(
            forKey: requestID
        ) else {
            return
        }
        if requestByJob[entry.jobID] == requestID {
            requestByJob[entry.jobID] = nil
        }
        entry.continuation.resume(returning: choice)
    }

    func cancelRequests(jobID: UUID) {
        promptTasks[jobID]?.cancel()
        promptTasks[jobID] = nil
        restartJobs.remove(jobID)
        suspendedJobs.remove(jobID)
        let requestIDs = continuations.compactMap {
            requestID, entry in
            entry.jobID == jobID ? requestID : nil
        }
        for requestID in requestIDs {
            continuations.removeValue(
                forKey: requestID
            )?.continuation.resume(returning: .cancel)
        }
        requestByJob[jobID] = nil
    }

    func consumeRestart(jobID: UUID) -> Bool {
        restartJobs.remove(jobID) != nil
    }

    func authorize(
        jobID: UUID,
        settings: AppSettings,
        network: NetworkPathSnapshot,
        context: DownloadNetworkContext
    ) async throws -> Bool {
        guard var job = await context.currentJob(jobID) else {
            return false
        }
        switch DownloadScheduler.networkDecision(
            for: job,
            settings: settings,
            network: network
        ) {
        case .allow:
            if job.networkAuthorization == .waitForWiFi {
                job.networkAuthorization = nil
                await context.persistJob(job)
            }
            return true
        case .waitForConnectivity, .waitForUnconstrainedNetwork:
            await setWaitingState(
                jobID: jobID,
                state: .waitingForNetwork,
                message: nil,
                context: context
            )
            return false
        case .waitForWiFi, .waitForUnmeteredNetwork:
            await setWaitingState(
                jobID: jobID,
                state: .waitingForWiFi,
                message: nil,
                context: context
            )
            return false
        case .requireCellularConfirmation:
            let request = NetworkAccessRequest(
                jobID: jobID,
                title: job.title,
                reason: .cellular
            )
            requestByJob[jobID] = request.id
            await setWaitingState(
                jobID: jobID,
                state: .waitingForCellularApproval,
                message: nil,
                context: context
            )
            let choice = await waitForChoice(request)
            try Task.checkCancellation()
            guard var current = await context.currentJob(jobID) else {
                return false
            }
            switch choice {
            case .continueOnce:
                current.networkAuthorization = .continueOnce
                current.state = .running
                current.stage = .analyzing
            case .alwaysAllow:
                current.networkAuthorization = .continueOnce
                current.state = .running
                current.stage = .analyzing
                await context.disableCellularPrompt()
                eventSink(.cellularPromptPreferenceChanged(false))
            case .waitForWiFi:
                current.networkAuthorization = .waitForWiFi
                current.state = .waitingForWiFi
                current.stage = .waiting
            case .cancel:
                throw CancellationError()
            }
            current.updatedAt = .now
            await context.persistJob(current)
            return choice == .continueOnce || choice == .alwaysAllow
        }
    }

    func receiveNetworkChange(
        _ snapshot: NetworkPathSnapshot,
        jobs: [DownloadJob],
        settings: AppSettings,
        context: DownloadNetworkContext
    ) async {
        let activeTransfers = jobs.filter {
            $0.state == .running && $0.stage.supportsTransferPause
        }
        for job in activeTransfers {
            let decision = DownloadScheduler.networkDecision(
                for: job,
                settings: settings,
                network: snapshot
            )
            guard decision != .allow else { continue }
            await suspendTransfer(
                jobID: job.id,
                decision: decision,
                settings: settings,
                network: snapshot,
                context: context
            )
        }
        for jobID in suspendedJobs {
            guard let job = await context.currentJob(jobID),
                  promptTasks[jobID] == nil,
                  DownloadScheduler.networkDecision(
                      for: job,
                      settings: settings,
                      network: snapshot
                  ) == .allow
            else {
                continue
            }
            await resumeTransfer(
                jobID: jobID,
                settings: settings,
                network: snapshot,
                context: context
            )
        }
    }

    private func suspendTransfer(
        jobID: UUID,
        decision: NetworkAccessDecision,
        settings: AppSettings,
        network: NetworkPathSnapshot,
        context: DownloadNetworkContext
    ) async {
        guard var job = await context.currentJob(jobID),
              !suspendedJobs.contains(jobID)
        else {
            return
        }
        let transferStage = job.stage
        let result = await downloader.pause(jobID: jobID)
        guard result.matchedTaskCount > 0,
              result.fullyAcknowledged
        else {
            return
        }
        await context.releaseTransferPermit(jobID)
        suspendedJobs.insert(jobID)
        job.resumableTransferStage = transferStage
        switch decision {
        case .waitForWiFi, .waitForUnmeteredNetwork:
            job.state = .waitingForWiFi
        case .requireCellularConfirmation:
            job.state = .waitingForCellularApproval
        case .waitForConnectivity, .waitForUnconstrainedNetwork:
            job.state = .waitingForNetwork
        case .allow:
            return
        }
        job.stage = .waiting
        job.updatedAt = .now
        await context.persistJob(job)
        if decision == .requireCellularConfirmation,
           promptTasks[jobID] == nil {
            promptTasks[jobID] = Task {
                await self.handleSuspendedPrompt(
                    jobID: jobID,
                    settings: settings,
                    network: network,
                    context: context
                )
            }
        }
    }

    private func handleSuspendedPrompt(
        jobID: UUID,
        settings: AppSettings,
        network: NetworkPathSnapshot,
        context: DownloadNetworkContext
    ) async {
        defer { promptTasks[jobID] = nil }
        guard let job = await context.currentJob(jobID) else { return }
        let request = NetworkAccessRequest(
            jobID: jobID,
            title: job.title,
            reason: .cellular
        )
        requestByJob[jobID] = request.id
        let choice = await waitForChoice(request)
        guard !Task.isCancelled,
              var current = await context.currentJob(jobID)
        else {
            return
        }
        switch choice {
        case .continueOnce, .alwaysAllow:
            current.networkAuthorization = .continueOnce
            current.state = .running
            current.stage = .restoring
            current.updatedAt = .now
            await context.persistJob(current)
            if choice == .alwaysAllow {
                await context.disableCellularPrompt()
                eventSink(.cellularPromptPreferenceChanged(false))
            }
            suspendedJobs.remove(jobID)
            restartJobs.insert(jobID)
            _ = await downloader.cancel(jobID: jobID)
        case .waitForWiFi:
            current.networkAuthorization = .waitForWiFi
            current.state = .waitingForWiFi
            current.stage = .waiting
            current.updatedAt = .now
            await context.persistJob(current)
            if DownloadScheduler.networkDecision(
                for: current,
                settings: settings,
                network: network
            ) == .allow {
                await resumeTransfer(
                    jobID: jobID,
                    settings: settings,
                    network: network,
                    context: context
                )
            }
        case .cancel:
            await context.cancelJob(jobID)
        }
    }

    private func resumeTransfer(
        jobID: UUID,
        settings: AppSettings,
        network: NetworkPathSnapshot,
        context: DownloadNetworkContext
    ) async {
        guard var job = await context.currentJob(jobID),
              suspendedJobs.contains(jobID),
              DownloadScheduler.networkDecision(
                  for: job,
                  settings: settings,
                  network: network
              ) == .allow
        else {
            return
        }
        do {
            try await context.acquireTransferPermit(jobID)
        } catch {
            return
        }
        guard let refreshed = await context.currentJob(jobID),
              DownloadScheduler.networkDecision(
                  for: refreshed,
                  settings: settings,
                  network: network
              ) == .allow
        else {
            await context.releaseTransferPermit(jobID)
            return
        }
        let result = await downloader.resume(jobID: jobID)
        guard result.matchedTaskCount > 0,
              result.fullyAcknowledged
        else {
            await context.releaseTransferPermit(jobID)
            return
        }
        suspendedJobs.remove(jobID)
        job.state = .running
        job.stage = job.resumableTransferStage ?? .downloadingVideo
        job.resumableTransferStage = nil
        job.updatedAt = .now
        await context.persistJob(job)
    }

    private func setWaitingState(
        jobID: UUID,
        state: DownloadJobState,
        message: String?,
        context: DownloadNetworkContext
    ) async {
        guard var job = await context.currentJob(jobID),
              job.state != state || job.errorMessage != message
        else {
            return
        }
        job.state = state
        job.stage = .waiting
        job.errorMessage = message
        job.updatedAt = .now
        await context.persistJob(job)
    }

    private func waitForChoice(
        _ request: NetworkAccessRequest
    ) async -> NetworkAccessChoice {
        await withCheckedContinuation { continuation in
            continuations[request.id] = NetworkContinuationEntry(
                jobID: request.jobID,
                continuation: continuation
            )
            eventSink(.requestNetworkAccess(request))
        }
    }
}
