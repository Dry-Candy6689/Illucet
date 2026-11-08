import Foundation

/// A transport-staging fact, never authority to reuse a complete media source.
/// Ciphertext/resource bytes and partial ranges remain distinct from accepted media.
struct NativeFileReceipt: Codable, Equatable, Sendable {
    let identity: StreamTransferDestinationIdentity
    let taskIdentifier: Int
    let formatID: String?
    let byteCount: Int64
    let recordedAt: Date
}

enum NativeTransferCheckpointError: Error { case persistenceUnavailable }

/// Delegate delivery fences only the writes already enqueued for that cycle.
/// It never waits for a processing grant or a later network request.
final class NativeTransferAcknowledgements: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: Task<Void, Error>] = [:]
    private var outcomes: [Int: Result<Void, Error>] = [:]
    private var consumedOrder: [Int] = []

    func enqueue(taskID: Int, operation: @escaping @Sendable () async throws -> Void) {
        lock.withLock {
            guard pending[taskID] == nil, outcomes[taskID] == nil else { return }
            pending[taskID] = Task {
                let result: Result<Void, Error>
                do { try await operation(); result = .success(()) }
                catch { result = .failure(error) }
                self.finish(taskID, result: result)
                try result.get()
            }
        }
    }

    func wait(taskID: Int) async throws {
        defer {
            lock.withLock {
                if !consumedOrder.contains(taskID) { consumedOrder.append(taskID) }
                while consumedOrder.count > 128 { outcomes[consumedOrder.removeFirst()] = nil }
            }
        }
        let captured = lock.withLock { (pending[taskID], outcomes[taskID]) }
        if let task = captured.0 { try await task.value }
        else { try captured.1?.get() }
    }

    func captureDeliveryBarrier() -> @Sendable () async -> Void {
        let tasks = lock.withLock { Array(pending.values) }
        return { for task in tasks { _ = try? await task.value } }
    }

    private func finish(_ id: Int, result: Result<Void, Error>) {
        lock.withLock {
            pending[id] = nil
            outcomes[id] = result
        }
    }
}

/// Background delegates may arrive before startup installs the durable writer.
/// Keep those receipts pending instead of acknowledging them through a no-op.
final class NativeReceiptWriter: @unchecked Sendable {
    typealias Handler = @Sendable (UUID, UUID?, NativeFileReceipt) async throws -> Void
    private let lock = NSLock()
    private var handler: Handler?
    private var rejected = false
    private var waiters: [CheckedContinuation<Handler, Error>] = []

    func install(_ handler: @escaping Handler) {
        let pending = lock.withLock {
            self.handler = handler
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(returning: handler) }
    }

    func reject() {
        let pending = lock.withLock {
            rejected = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(throwing: NativeTransferCheckpointError.persistenceUnavailable) }
    }

    func write(jobID: UUID, attempt: UUID?, receipt: NativeFileReceipt) async throws {
        let writer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Handler, Error>) in
            lock.withLock {
                if rejected { continuation.resume(throwing: NativeTransferCheckpointError.persistenceUnavailable) }
                else if let handler { continuation.resume(returning: handler) }
                else { waiters.append(continuation) }
            }
        }
        try await writer(jobID, attempt, receipt)
    }
}
