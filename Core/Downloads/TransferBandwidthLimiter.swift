import Foundation

/// Paces foreground transfers. Background handoff balances only limiter-owned
/// suspension; explicit job/task pause never depends on a throttle timer.
final class TransferBandwidthLimiter: @unchecked Sendable {
    private struct Suspension {
        let task: URLSessionTask
        var deadline: Double
        var ownsSuspension: Bool
    }
    private let lock = NSLock()
    private var foregroundActive = true
    private var globalLimit: Int64?
    private var jobLimits: [UUID: Int64] = [:]
    private var globalDeadline: Double = 0
    private var jobDeadlines: [UUID: Double] = [:]
    private var suspended: [Int: Suspension] = [:]
    private var knownTasks: [Int: URLSessionTask] = [:]
    private var receivedBaselines: [Int: Int64] = [:]
    private var userPaused: Set<Int> = []
    private var admissionWaiters: [UUID: Int] = [:]
    private var pausedJobs: Set<UUID> = []
    private struct AdmissionSignal {
        let jobID: UUID
        let continuation: CheckedContinuation<Void, Error>
        var timer: Task<Void, Never>?
    }
    private var admissionSignals: [UUID: AdmissionSignal] = [:]
    private let admissionSleeper: @Sendable (Double) async throws -> Void

    init(admissionSleeper: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds(min(60, $0))) }) {
        self.admissionSleeper = admissionSleeper
    }

    func setForegroundActive(_ active: Bool) {
        lock.withLock {
            guard foregroundActive != active else { return }
            foregroundActive = active
            globalDeadline = 0
            jobDeadlines.removeAll()
            for (id, task) in knownTasks { receivedBaselines[id] = max(0, task.countOfBytesReceived) }
            let reservations = suspended
            suspended.removeAll()
            for (id, reservation) in reservations where reservation.ownsSuspension && !userPaused.contains(id) {
                reservation.task.resume()
            }
            wakeAdmissionsLocked()
        }
    }

    func configure(global: Int64?, jobID: UUID? = nil, perJob: Int64? = nil) {
        lock.withLock {
            let value = Self.valid(global)
            if value != globalLimit { globalDeadline = 0 }
            globalLimit = value
            if let jobID { jobLimits[jobID] = Self.valid(perJob) }
            wakeAdmissionsLocked()
        }
    }
    func finish(jobID: UUID) {
        lock.withLock {
            jobLimits[jobID] = nil; jobDeadlines[jobID] = nil; pausedJobs.remove(jobID)
            wakeAdmissionsLocked(jobID: jobID)
        }
    }
    func suggestedChunkBytes(jobID: UUID) -> Int64? {
        lock.withLock {
            [globalLimit, jobLimits[jobID]].compactMap { $0 }.min().map { max(65_536, min(1_048_576, $0)) }
        }
    }
    func permitsRequestBatch(jobID: UUID) -> Bool {
        lock.withLock { !foregroundActive || (globalLimit == nil && jobLimits[jobID] == nil) }
    }
    func pacingDeadline(jobID: UUID) -> Double? {
        lock.withLock {
            guard foregroundActive else { return nil }
            return max(globalDeadline, jobDeadlines[jobID] ?? 0)
        }
    }
    func waitForAdmission(jobID: UUID) async throws {
        lock.withLock { admissionWaiters[jobID, default: 0] += 1 }
        defer { lock.withLock { admissionWaiters[jobID, default: 0] -= 1 } }
        while true {
            try Task.checkCancellation()
            if lock.withLock({ admissionDelayLocked(jobID: jobID) == 0 }) { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                        let delay = admissionDelayLocked(jobID: jobID)
                        guard delay != 0 else { continuation.resume(); return }
                        admissionSignals[id] = AdmissionSignal(jobID: jobID, continuation: continuation)
                        if let delay {
                            let sleeper = admissionSleeper
                            admissionSignals[id]?.timer = Task { [weak self] in
                                do { try await sleeper(delay) } catch { return }
                                self?.signalAdmission(id)
                            }
                        }
                    }
                }
            } onCancel: { self.signalAdmission(id, cancelled: true) }
        }
    }

    private func admissionDelayLocked(jobID: UUID) -> Double? {
        if pausedJobs.contains(jobID) { return nil }
        guard foregroundActive else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        return max(0, globalLimit == nil ? 0 : globalDeadline - now,
            jobLimits[jobID] == nil ? 0 : (jobDeadlines[jobID] ?? 0) - now)
    }

    private func signalAdmission(_ id: UUID, cancelled: Bool = false) {
        lock.withLock {
            guard let signal = admissionSignals.removeValue(forKey: id) else { return }
            signal.timer?.cancel()
            if cancelled { signal.continuation.resume(throwing: CancellationError()) }
            else { signal.continuation.resume() }
        }
    }

    private func wakeAdmissionsLocked(jobID: UUID? = nil) {
        let signals = admissionSignals.filter { jobID == nil || $0.value.jobID == jobID }
        for (id, signal) in signals {
            admissionSignals[id] = nil
            signal.timer?.cancel()
            signal.continuation.resume()
        }
    }
    func pauseAdmission(jobID: UUID) -> Int {
        lock.withLock {
            pausedJobs.insert(jobID)
            wakeAdmissionsLocked(jobID: jobID)
            return admissionWaiters[jobID] ?? 0
        }
    }
    func resumeAdmission(jobID: UUID) -> Int {
        lock.withLock {
            pausedJobs.remove(jobID)
            wakeAdmissionsLocked(jobID: jobID)
            return admissionWaiters[jobID] ?? 0
        }
    }
    private static func valid(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return max(16_384, value)
    }
    func reserve(bytes: Int64, jobID: UUID, now: Double) -> Double {
        lock.withLock { reserveLocked(bytes: bytes, jobID: jobID, now: now) }
    }
    private func reserveLocked(bytes: Int64, jobID: UUID, now: Double) -> Double {
        guard foregroundActive, bytes > 0 else { return now }
        if let limit = globalLimit { globalDeadline = max(now, globalDeadline) + Double(bytes) / Double(limit) }
        if let limit = jobLimits[jobID] { jobDeadlines[jobID] = max(now, jobDeadlines[jobID] ?? now) + Double(bytes) / Double(limit) }
        return max(now, globalLimit == nil ? now : globalDeadline, jobDeadlines[jobID] ?? now)
    }
    func pause(_ task: URLSessionTask) -> Bool {
        lock.withLock {
            guard task.state == .running || suspended[task.taskIdentifier] != nil else { return false }
            let added = userPaused.insert(task.taskIdentifier).inserted
            if added && task.state == .running && suspended[task.taskIdentifier]?.ownsSuspension != true { task.suspend() }
            return added
        }
    }
    func resume(_ task: URLSessionTask, jobID: UUID) -> Bool {
        lock.withLock {
            if pausedJobs.contains(jobID) { userPaused.insert(task.taskIdentifier); return false }
            userPaused.remove(task.taskIdentifier)
            guard task.state == .suspended else { return false }
            if suspended[task.taskIdentifier] == nil { task.resume() }
            else { suspended[task.taskIdentifier]?.ownsSuspension = true }
            return true
        }
    }
    func isThrottled(_ task: URLSessionTask) -> Bool {
        lock.withLock { suspended[task.taskIdentifier] != nil && !userPaused.contains(task.taskIdentifier) }
    }
    func throttle(_ task: URLSessionTask, bytes: Int64, jobID: UUID, totalBytes: Int64? = nil) {
        let start = lock.withLock {
            let id = task.taskIdentifier
            knownTasks[id] = task
            var charge = max(0, bytes)
            if let totalBytes {
                let baseline = receivedBaselines[id] ?? max(0, totalBytes - charge)
                charge = min(charge, max(0, totalBytes - baseline))
                receivedBaselines[id] = max(baseline, totalBytes)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let deadline = reserveLocked(bytes: charge, jobID: jobID, now: now)
            guard foregroundActive, deadline > now else { return false }
            let first = suspended[id] == nil
            let owns = suspended[id]?.ownsSuspension ?? (task.state == .running)
            suspended[id] = Suspension(task: task, deadline: deadline, ownsSuspension: owns)
            if first && owns { task.suspend() }
            return first
        }
        guard start else { return }
        Task {
            while true {
                let delay: Double? = lock.withLock {
                    let id = task.taskIdentifier
                    if task.state == .canceling || task.state == .completed {
                        suspended[id] = nil
                        userPaused.remove(id)
                        return nil
                    }
                    guard let entry = suspended[id] else { return nil }
                    let remaining = entry.deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 {
                        suspended[id] = nil
                        if entry.ownsSuspension && !userPaused.contains(id) { task.resume() }
                        return nil
                    }
                    return remaining
                }
                guard let delay else { return }
                try? await Task.sleep(for: .seconds(min(delay, 0.25)))
            }
        }
    }
    func complete(_ task: URLSessionTask) {
        lock.withLock {
            let id = task.taskIdentifier
            suspended[id] = nil
            knownTasks[id] = nil
            receivedBaselines[id] = nil
            userPaused.remove(id)
        }
    }
}
