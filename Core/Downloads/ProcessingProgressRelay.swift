import Foundation

/// Bounds processing-only progress work without changing the coordinator's
/// lossless mixed event stream. One worker owns delivery for an operation;
/// pending steady-state values are replaced by the newest value.
final class ProcessingProgressRelay: @unchecked Sendable {
    typealias Delivery = @Sendable (MediaProcessingProgress) async -> Void

    private let lock = NSLock()
    private let minimumDeliveryInterval: Duration
    private let delivery: Delivery
    private var pending: [MediaProcessingProgress] = []
    private var newestStage: MediaProcessingStage?
    private var worker: Task<Void, Never>?
    private var invalidated = false

    init(
        minimumDeliveryInterval: Duration = .milliseconds(100),
        delivery: @escaping Delivery
    ) {
        self.minimumDeliveryInterval = minimumDeliveryInterval
        self.delivery = delivery
    }

    func report(_ progress: MediaProcessingProgress) {
        lock.withLock {
            guard !invalidated else { return }
            enqueue(progress)
            if worker == nil {
                worker = Task { [weak self] in
                    await self?.drain()
                }
            }
        }
    }

    /// Waits for at most the bounded semantic tail before its owner advances
    /// the job to a later stage or terminal state.
    func finish() async {
        while let current = currentWorker() {
            await current.value
        }
    }

    /// Drops pending values after failure/cancellation. At most the single
    /// already-delivering value can remain, and coordinator stage guards reject
    /// it once newer job truth has been committed.
    func invalidate() {
        lock.withLock {
            invalidated = true
            pending.removeAll(keepingCapacity: false)
        }
    }

    private func enqueue(_ progress: MediaProcessingProgress) {
        if newestStage != progress.stage {
            newestStage = progress.stage
            pending.removeAll(keepingCapacity: true)
            pending.append(progress)
            return
        }
        guard !pending.isEmpty else {
            pending.append(progress)
            return
        }
        if isTerminal(progress) {
            if pending.count < 3 {
                pending.append(progress)
            } else {
                pending[pending.count - 1] = progress
            }
            return
        }
        if pending.count == 1 {
            pending.append(progress)
        } else {
            pending[pending.count - 1] = progress
        }
    }

    private func drain() async {
        var lastStage: MediaProcessingStage?
        var lastDelivery: ContinuousClock.Instant?
        let clock = ContinuousClock()

        while !Task.isCancelled {
            guard let candidate = peek() else {
                // Teardown is rechecked while holding the same lock used by
                // report(). If a report won the race, this worker keeps going;
                // if teardown won, that report observes nil and starts another.
                if finishWorkerIfEmpty() {
                    return
                }
                continue
            }
            if candidate.stage == lastStage,
               !isTerminal(candidate),
               let lastDelivery {
                let elapsed = lastDelivery.duration(to: clock.now)
                if elapsed < minimumDeliveryInterval {
                    try? await Task.sleep(
                        for: minimumDeliveryInterval - elapsed
                    )
                    continue
                }
            }
            guard let next = pop() else { continue }
            await delivery(next)
            lastStage = next.stage
            lastDelivery = clock.now
        }
        _ = finishWorkerIfEmpty()
    }

    private func peek() -> MediaProcessingProgress? {
        lock.withLock {
            invalidated ? nil : pending.first
        }
    }

    private func pop() -> MediaProcessingProgress? {
        lock.withLock {
            guard !invalidated, !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
    }

    private func currentWorker() -> Task<Void, Never>? {
        lock.withLock { worker }
    }

    private func finishWorkerIfEmpty() -> Bool {
        lock.withLock {
            if pending.isEmpty || invalidated {
                worker = nil
                return true
            }
            return false
        }
    }

    private func isTerminal(_ progress: MediaProcessingProgress) -> Bool {
        (progress.completedFraction ?? -1) >= 1
    }
}
