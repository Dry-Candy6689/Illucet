import Foundation

struct AsyncPermitPoolSnapshot: Equatable, Sendable {
    let limit: Int
    let activeCount: Int
    let waitingCount: Int
}

actor AsyncPermitPool {
    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Permit, Error>
        var priority: Int
        var allowsOverLimit: Bool
        let order: UInt64
    }

    private var limit: Int
    private var active: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var nextOrder: UInt64 = 0
    private var priorityHints: [UUID: Int] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(id: UUID = UUID(), priority: Int = 0, allowsOverLimit: Bool = false) async throws -> Permit {
        return try await withTaskCancellationHandler {
            let permit = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Permit, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                nextOrder &+= 1
                waiters.append(Waiter(id: id, continuation: continuation,
                    priority: priorityHints.removeValue(forKey: id) ?? priority, allowsOverLimit: allowsOverLimit, order: nextOrder))
                sortWaiters()
                grantAvailablePermits()
            }
            do {
                try Task.checkCancellation()
                return permit
            } catch {
                releaseID(id)
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    func prioritize(id: UUID, priority: Int) {
        guard !active.contains(id) else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters[index].priority = priority
            sortWaiters()
        } else { priorityHints[id] = priority }
    }

    private func sortWaiters() {
        waiters.sort { $0.priority == $1.priority ? $0.order < $1.order : $0.priority < $1.priority }
    }

    func release(_ permit: Permit) {
        releaseID(permit.id)
    }

    func resize(to requestedLimit: Int) {
        limit = max(1, requestedLimit)
        grantAvailablePermits()
    }

    func snapshot() -> AsyncPermitPoolSnapshot {
        AsyncPermitPoolSnapshot(
            limit: limit,
            activeCount: active.count,
            waitingCount: waiters.count
        )
    }

    func withPermit<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let permit = try await acquire()
        defer { release(permit) }
        return try await operation()
    }

    private func cancelWaiter(_ id: UUID) {
        priorityHints[id] = nil
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        // Once granted, acquire() owns cancellation cleanup until it returns.
        // A delayed cancellation task must not revoke a permit already handed
        // to the caller, which now owns its explicit release.
    }

    private func releaseID(_ id: UUID) {
        priorityHints[id] = nil
        guard active.remove(id) != nil else { return }
        grantAvailablePermits()
    }

    private func grantAvailablePermits() {
        while let index = waiters.firstIndex(where: { active.count < limit || $0.allowsOverLimit }) {
            let waiter = waiters.remove(at: index)
            active.insert(waiter.id)
            waiter.continuation.resume(
                returning: Permit(id: waiter.id)
            )
        }
    }
}
