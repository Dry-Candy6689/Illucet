import Foundation

struct ScheduledDownload: Equatable, Sendable {
    let jobID: UUID
    let networkDecision: NetworkAccessDecision
}

/// Owns queue ordering, network admission decisions, and the two independent
/// concurrency budgets. It deliberately does not own `DownloadJob` state;
/// the coordinator remains the single writer for persisted/UI-visible jobs.
actor DownloadScheduler {
    private let transferBudget: JobPermitBudget
    private let processingBudget: JobPermitBudget

    init(
        transferPermits: AsyncPermitPool? = nil,
        processingPermits: AsyncPermitPool? = nil
    ) {
        transferBudget = JobPermitBudget(pool: transferPermits
            ?? AsyncPermitPool(
                limit: AppSettings.defaults.maximumSimultaneousDownloads
            ))
        processingBudget = JobPermitBudget(pool: processingPermits
            ?? AsyncPermitPool(
                limit: AppSettings.defaults.maximumSimultaneousProcessingJobs
            ))
    }

    func configure(settings: AppSettings) async {
        await transferBudget.resize(to: settings.maximumSimultaneousDownloads)
        await processingBudget.resize(to: settings.maximumSimultaneousProcessingJobs)
    }

    func pendingDownloads(
        jobs: [DownloadJob],
        runningJobIDs: Set<UUID>,
        settings: AppSettings,
        network: NetworkPathSnapshot
    ) -> [ScheduledDownload] {
        jobs
            .filter {
                !runningJobIDs.contains($0.id)
                    && Self.schedulableStates.contains($0.state)
            }
            .sorted {
                if $0.priority == $1.priority {
                    return $0.createdAt < $1.createdAt
                }
                return $0.priority < $1.priority
            }
            .map {
                ScheduledDownload(
                    jobID: $0.id,
                    networkDecision: Self.networkDecision(
                        for: $0,
                        settings: settings,
                        network: network
                    )
                )
            }
    }

    nonisolated static func networkDecision(
        for job: DownloadJob,
        settings: AppSettings,
        network: NetworkPathSnapshot
    ) -> NetworkAccessDecision {
        // Publication recovery reads only verified local inputs.
        if job.pipelineCheckpoint?.publicationPlan != nil { return .allow }
        let forceWiFi = job.networkAuthorization == .waitForWiFi || job.configuration.wifiOnly == true
        let approved = job.networkAuthorization == .continueOnce
        return NetworkAccessPolicy(
            wifiOnly: settings.wifiOnly || forceWiFi,
            askBeforeCellular: settings.askBeforeCellular,
            allowsExpensiveAccess: !(settings.wifiOnly || forceWiFi),
            allowsConstrainedAccess: !(settings.wifiOnly || forceWiFi)
        ).decision(
            for: network,
            cellularApprovalGranted: approved
        )
    }

    nonisolated static func streamNetworkPolicy(
        for job: DownloadJob,
        settings: AppSettings
    ) -> StreamTransferNetworkPolicy {
        let forceWiFi = settings.wifiOnly || job.configuration.wifiOnly == true
            || job.networkAuthorization == .waitForWiFi
        let cellularApproved =
            job.networkAuthorization == .continueOnce
                || !settings.askBeforeCellular
        return StreamTransferNetworkPolicy(
            allowsExpensiveAccess:
                !forceWiFi && cellularApproved,
            allowsConstrainedAccess: !forceWiFi
        )
    }

    func acquireTransfer(jobID: UUID, priority: Int = 0, allowsOverLimit: Bool = false) async throws {
        try await transferBudget.acquire(jobID: jobID, priority: priority, allowsOverLimit: allowsOverLimit)
    }

    func prioritizeTransfer(jobID: UUID, priority: Int) async {
        await transferBudget.prioritize(jobID: jobID, priority: priority)
    }

    func releaseTransfer(jobID: UUID) async {
        await transferBudget.release(jobID: jobID)
    }

    func acquireProcessing(jobID: UUID) async throws {
        try await processingBudget.acquire(jobID: jobID)
    }

    func releaseProcessing(jobID: UUID) async {
        await processingBudget.release(jobID: jobID)
    }

    func transferSnapshot() async -> AsyncPermitPoolSnapshot {
        await transferBudget.snapshot()
    }

    func processingSnapshot() async -> AsyncPermitPoolSnapshot {
        await processingBudget.snapshot()
    }

    private static let schedulableStates: Set<DownloadJobState> = [
        .queued,
        .waitingForNetwork,
        .waitingForWiFi,
        .waitingForCellularApproval,
        .waitingForRetry,
        .waitingForPower,
    ]
}

/// Coalesces calls for one job while keeping each caller's cancellation local.
/// A grant is retained only after a caller accepts it; a cancelled last caller
/// cannot leave an orphan permit between continuation resumption and return.
private actor JobPermitBudget {
    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UUID, Error>]
    }

    private struct Grant {
        let id: UUID
        let permit: AsyncPermitPool.Permit
        var acceptingWaiters: Set<UUID>
        var accepted = false
    }

    private let pool: AsyncPermitPool
    private var pending: [UUID: Pending] = [:]
    private var held: [UUID: Grant] = [:]

    init(pool: AsyncPermitPool) {
        self.pool = pool
    }

    func acquire(jobID: UUID, priority: Int = 0, allowsOverLimit: Bool = false) async throws {
        try Task.checkCancellation()
        if var grant = held[jobID] {
            grant.accepted = true
            held[jobID] = grant
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            let grantID = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UUID, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if pending[jobID] != nil {
                    pending[jobID]?.waiters[waiterID] = continuation
                } else {
                    let id = UUID()
                    let pool = pool
                    let task = Task {
                        let result: Result<AsyncPermitPool.Permit, Error>
                        do { result = .success(try await pool.acquire(id: id, priority: priority, allowsOverLimit: allowsOverLimit)) }
                        catch { result = .failure(error) }
                        await finish(result, jobID: jobID, acquisitionID: id)
                    }
                    pending[jobID] = Pending(
                        id: id,
                        task: task,
                        waiters: [waiterID: continuation]
                    )
                }
            }
            guard var grant = held[jobID], grant.id == grantID else {
                throw CancellationError()
            }
            grant.acceptingWaiters.remove(waiterID)
            if Task.isCancelled {
                if !grant.accepted && grant.acceptingWaiters.isEmpty {
                    held[jobID] = nil
                    await pool.release(grant.permit)
                } else {
                    held[jobID] = grant
                }
                throw CancellationError()
            }
            grant.accepted = true
            held[jobID] = grant
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, jobID: jobID) }
        }
    }

    func prioritize(jobID: UUID, priority: Int) async {
        guard let entry = pending[jobID] else { return }
        await pool.prioritize(id: entry.id, priority: priority)
    }

    func release(jobID: UUID) async {
        let acquisition = pending.removeValue(forKey: jobID)
        let grant = held.removeValue(forKey: jobID)
        if let acquisition {
            acquisition.task.cancel()
            for waiter in acquisition.waiters.values {
                waiter.resume(throwing: CancellationError())
            }
            // The late completion owns release of any permit it already got.
            // Waiting here also makes explicit release a completion boundary.
            await acquisition.task.value
        }
        if let grant { await pool.release(grant.permit) }
    }

    func resize(to limit: Int) async { await pool.resize(to: limit) }
    func snapshot() async -> AsyncPermitPoolSnapshot { await pool.snapshot() }

    private func cancelWaiter(_ waiterID: UUID, jobID: UUID) {
        guard var acquisition = pending[jobID],
              let waiter = acquisition.waiters.removeValue(forKey: waiterID)
        else { return }
        if acquisition.waiters.isEmpty {
            pending[jobID] = nil
            acquisition.task.cancel()
        } else {
            pending[jobID] = acquisition
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(
        _ result: Result<AsyncPermitPool.Permit, Error>,
        jobID: UUID,
        acquisitionID: UUID
    ) async {
        guard let acquisition = pending[jobID],
              acquisition.id == acquisitionID else {
            if case .success(let permit) = result { await pool.release(permit) }
            return
        }
        pending[jobID] = nil
        switch result {
        case .success(let permit):
            held[jobID] = Grant(
                id: acquisitionID,
                permit: permit,
                acceptingWaiters: Set(acquisition.waiters.keys)
            )
            for waiter in acquisition.waiters.values {
                waiter.resume(returning: acquisitionID)
            }
        case .failure(let error):
            for waiter in acquisition.waiters.values {
                waiter.resume(throwing: error)
            }
        }
    }
}
