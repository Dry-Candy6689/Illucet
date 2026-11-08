import Foundation

/// Keeps explicit pause intent between native requests; each cancelled caller owns its waiter.
actor DownloadPauseGate {
    private var paused: Set<UUID> = []
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, Error>]] = [:]

    func pause(_ jobID: UUID) { paused.insert(jobID) }
    func resume(_ jobID: UUID) {
        paused.remove(jobID)
        let pending = waiters.removeValue(forKey: jobID) ?? [:]
        for waiter in pending.values { waiter.resume() }
    }
    func wait(_ jobID: UUID) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !paused.contains(jobID) { continuation.resume() }
                else { waiters[jobID, default: [:]][id] = continuation }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancel(jobID, waiter: id) } }
    }
    private func cancel(_ jobID: UUID, waiter: UUID) {
        waiters[jobID]?.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if waiters[jobID]?.isEmpty == true { waiters[jobID] = nil }
    }
}
