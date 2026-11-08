import BackgroundTasks
import UIKit

enum ContinuedProcessingState: String, Sendable {
    case notRequested, requesting, queued, granted, denied, expired, finished
    var isPending: Bool { self == .requesting || self == .queued }
}

enum ContinuedProcessingReason: String, Sendable {
    case registrationRejected, submissionRejected, foregroundRequired, expired, cancelled
}

struct ContinuedProcessingStatus: Equatable, Sendable {
    var state: ContinuedProcessingState
    var reason: ContinuedProcessingReason? = nil
    var requestedAt: Date? = nil
    var updatedAt: Date = .now
    var hasFinishingTime = false
}

protocol ContinuedProcessingControlling: Sendable {
    func begin(job: DownloadJob, attempt: UUID, expiration: @escaping @Sendable () async -> Void) async
    func canProcess(jobID: UUID, attempt: UUID) async -> Bool
    func status(jobID: UUID, attempt: UUID) async -> ContinuedProcessingStatus
    func waitForExecution(jobID: UUID, attempt: UUID) async throws
    func finish(jobID: UUID, attempt: UUID, success: Bool) async
}

extension ContinuedProcessingControlling {
    func canProcess(jobID: UUID, attempt: UUID) async -> Bool { true }
    func status(jobID: UUID, attempt: UUID) async -> ContinuedProcessingStatus {
        await canProcess(jobID: jobID, attempt: attempt) ? .init(state: .granted) : .init(state: .denied)
    }
    func waitForExecution(jobID: UUID, attempt: UUID) async throws { try Task.checkCancellation() }
}

@MainActor
protocol ContinuedProcessingTaskHandling: AnyObject {
    var identifier: String { get }
    func prepare(expiration: @escaping @Sendable () -> Void)
    func report(title: String, subtitle: String, fraction: Double?)
    func complete(success: Bool)
}

extension BGContinuedProcessingTask: ContinuedProcessingTaskHandling {
    func prepare(expiration: @escaping @Sendable () -> Void) {
        JobStatusPresentation.updateSystemProgress(progress, stage: "Preparing download", fraction: nil)
        expirationHandler = expiration
    }
    func report(title: String, subtitle: String, fraction: Double?) {
        updateTitle(title, subtitle: subtitle)
        JobStatusPresentation.updateSystemProgress(progress, stage: subtitle, fraction: fraction)
    }
    func complete(success: Bool) {
        expirationHandler = nil
        if success { JobStatusPresentation.updateSystemProgress(progress, stage: "Download completed", fraction: 1) }
        setTaskCompleted(success: success)
    }
}

@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    func register(identifier: String, handler: @escaping @MainActor @Sendable (any ContinuedProcessingTaskHandling) -> Void) -> Bool
    func submit(identifier: String, title: String, subtitle: String) async throws
    func cancel(identifier: String)
}

@MainActor
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    func register(identifier: String, handler: @escaping @MainActor @Sendable (any ContinuedProcessingTaskHandling) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                handler(continued)
            }
        }
    }
    func submit(identifier: String, title: String, subtitle: String) async throws {
        // Submission can wait on the system scheduler. Construct and submit on
        // a worker so its IPC never blocks scene changes or Queue controls.
        do {
            try await Task.detached(priority: .userInitiated) {
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
                request.strategy = .queue
                // CPU/network only. No unverified background GPU capability is requested.
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
            }.value
        } catch {
            let failure = error as NSError
            // Bounded system facts only: no title, request URL or upstream error text.
            NSLog("Illucet background submission rejected: kind=%@ code=%ld",
                  failure.domain == "BGTaskSchedulerErrorDomain" ? "scheduler" : "system", failure.code)
            throw error
        }
    }
    func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}

/// UIKit's bounded finishing allowance; an invalid token grants no execution.
@MainActor
protocol BackgroundFinishingTimeProviding: AnyObject {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
final class SystemBackgroundFinishingTime: BackgroundFinishingTimeProviding {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Finish Illucet download", expirationHandler: expiration)
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) { UIApplication.shared.endBackgroundTask(identifier) }
}

/// Tracks an attempt-bound lease; a queued launch wakes the existing runner.
@MainActor
final class ContinuedProcessingController: ContinuedProcessingControlling {
    static let shared = ContinuedProcessingController(finishingTime: SystemBackgroundFinishingTime())
    private struct Session {
        let attempt: UUID
        let identifier: String
        let expiration: @Sendable () async -> Void
        var status: ContinuedProcessingStatus
        var task: (any ContinuedProcessingTaskHandling)?
        var completed = false
        var finishingTask: UIBackgroundTaskIdentifier = .invalid
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private var sessions: [UUID: Session] = [:]
    private let scheduler: any ContinuedProcessingScheduling
    private let foregroundFallback: @MainActor () -> Bool
    private let finishingTime: (any BackgroundFinishingTimeProviding)?
    private var reporter: @Sendable (UUID, UUID, ContinuedProcessingStatus) async -> Void = { _, _, _ in }
    private var activeSceneIDs: Set<UUID> = []
    private var hasSceneReport = false
    private var prefix: String { (Bundle.main.bundleIdentifier ?? "com.local.illucet") + ".continued." }

    init(scheduler: any ContinuedProcessingScheduling = SystemContinuedProcessingScheduler(),
         foreground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background },
         finishingTime: (any BackgroundFinishingTimeProviding)? = nil) {
        self.scheduler = scheduler
        foregroundFallback = foreground
        self.finishingTime = finishingTime
    }

    func setReporter(_ reporter: @escaping @Sendable (UUID, UUID, ContinuedProcessingStatus) async -> Void) {
        self.reporter = reporter
    }

    @discardableResult
    func setSceneActive(_ id: UUID, active: Bool) -> Bool {
        hasSceneReport = true
        if active { activeSceneIDs.insert(id) }
        else { activeSceneIDs.remove(id) }
        if isForeground {
            for id in Array(sessions.keys) { wake(id) }
        }
        return isForeground
    }

    private var isForeground: Bool { hasSceneReport ? !activeSceneIDs.isEmpty : foregroundFallback() }

    func begin(job: DownloadJob, attempt: UUID, expiration: @escaping @Sendable () async -> Void) async {
        if let old = sessions[job.id] {
            if old.attempt == attempt && old.status.state != .finished
                && old.status.reason != .foregroundRequired { return }
            close(job.id, success: false)
        }
        // Each lease has its own identity, even when Pause/Resume retains the attempt.
        let identifier = prefix + UUID().uuidString
        sessions[job.id] = Session(attempt: attempt, identifier: identifier,
            expiration: expiration, status: .init(state: .requesting, requestedAt: .now))
        publish(job.id)
        guard isForeground else { transition(job.id, to: .denied, reason: .foregroundRequired); return }
        // Reserve UIKit's bounded finishing allowance while still foregrounded.
        // This bridges analysis/native handoff and short finalization if the
        // continued-processing request is queued or unavailable. It grants no
        // authority after UIKit expires it, and never replaces native transfer.
        if let finishingTime {
            let jobID = job.id
            sessions[job.id]?.finishingTask = finishingTime.begin { [weak self] in
                self?.expireFinishingTime(jobID: jobID, identifier: identifier)
            }
            publish(job.id)
        }
        // The plist permits a wildcard, but each launch handler must be
        // registered for the exact identifier being submitted for this lease.
        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            guard let self else { task.complete(success: false); return }
            self.receive(task)
        }
        guard registered else { transition(job.id, to: .denied, reason: .registrationRejected); return }
        do {
            try await scheduler.submit(identifier: identifier, title: String(job.title.prefix(96)), subtitle: job.stage.rawValue)
            guard sessions[job.id]?.identifier == identifier,
                  sessions[job.id]?.status.state != .finished else {
                scheduler.cancel(identifier: identifier)
                return
            }
            if sessions[job.id]?.status.state == .requesting { transition(job.id, to: .queued) }
        } catch {
            guard sessions[job.id]?.identifier == identifier,
                  sessions[job.id]?.status.state != .finished else { return }
            transition(job.id, to: .denied, reason: .submissionRejected)
        }
        pruneFinished()
    }

    func canProcess(jobID: UUID, attempt: UUID) async -> Bool {
        if isForeground { return true }
        guard let entry = sessions[jobID], entry.attempt == attempt else { return false }
        return entry.status.state == .granted || entry.finishingTask != .invalid
    }

    func status(jobID: UUID, attempt: UUID) async -> ContinuedProcessingStatus {
        guard let entry = sessions[jobID], entry.attempt == attempt else { return .init(state: .notRequested) }
        var status = entry.status
        status.hasFinishingTime = entry.finishingTask != .invalid
        return status
    }

    func waitForExecution(jobID: UUID, attempt: UUID) async throws {
        try Task.checkCancellation()
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard !isForeground, let entry = sessions[jobID], entry.attempt == attempt,
                      entry.status.state.isPending else { continuation.resume(); return }
                sessions[jobID]?.waiters[waiter] = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in
                self.sessions[jobID]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
            }
        }
    }

    private func receive(_ task: any ContinuedProcessingTaskHandling) {
        guard let id = sessions.first(where: { $0.value.identifier == task.identifier })?.key,
              let entry = sessions[id], entry.status.state.isPending else {
            task.complete(success: false)
            return
        }
        sessions[id]?.task = task
        let identifier = entry.identifier
        task.prepare { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.sessions[id], current.identifier == identifier,
                      current.status.state == .granted else { return }
                self.transition(id, to: .expired, reason: .expired)
                await current.expiration()
                // Teardown may have completed or replaced this lease while awaiting cleanup.
                guard self.sessions[id]?.identifier == identifier else { return }
                self.completeHandle(id, success: false)
            }
        }
        // The real continued-processing grant supersedes the shorter UIKit one.
        endFinishingTime(id)
        transition(id, to: .granted)
    }

    func update(job: DownloadJob) {
        guard let entry = sessions[job.id], entry.status.state == .granted else { return }
        entry.task?.report(title: String(job.title.prefix(96)), subtitle: job.stage.rawValue,
                           fraction: job.progress.overallFraction)
    }

    func finish(jobID: UUID, attempt: UUID, success: Bool) async {
        guard sessions[jobID]?.attempt == attempt else { return }
        close(jobID, success: success)
    }

    private func close(_ id: UUID, success: Bool) {
        guard let entry = sessions[id], entry.status.state != .finished else { return }
        endFinishingTime(id)
        completeHandle(id, success: success)
        scheduler.cancel(identifier: entry.identifier)
        transition(id, to: .finished, reason: entry.status.reason ?? (success ? nil : .cancelled))
    }

    private func endFinishingTime(_ id: UUID) {
        guard let token = sessions[id]?.finishingTask, token != .invalid else { return }
        sessions[id]?.finishingTask = .invalid
        finishingTime?.end(token)
    }

    private func expireFinishingTime(jobID: UUID, identifier: String) {
        guard let entry = sessions[jobID], entry.identifier == identifier,
              entry.finishingTask != .invalid else { return }
        // End promptly before awaiting cancellation/checkpoint work. The lease
        // identity also fences a late callback from a replaced attempt.
        endFinishingTime(jobID)
        publish(jobID)
        if !isForeground, entry.status.state != .granted {
            Task { [weak self] in
                guard let self, let current = sessions[jobID], current.identifier == identifier,
                      !isForeground, current.status.state != .granted,
                      current.status.state != .finished else { return }
                await entry.expiration()
            }
        }
    }

    private func completeHandle(_ id: UUID, success: Bool) {
        guard let entry = sessions[id], !entry.completed else { return }
        sessions[id]?.completed = true
        entry.task?.complete(success: success)
    }

    private func transition(_ id: UUID, to state: ContinuedProcessingState, reason: ContinuedProcessingReason? = nil) {
        guard sessions[id] != nil else { return }
        sessions[id]?.status.state = state
        sessions[id]?.status.reason = reason
        sessions[id]?.status.updatedAt = .now
        publish(id)
        if !state.isPending { wake(id) }
    }

    private func wake(_ id: UUID) {
        let waiters = sessions[id]?.waiters ?? [:]
        sessions[id]?.waiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    private func publish(_ id: UUID) {
        guard let entry = sessions[id] else { return }
        let reporter = reporter
        var status = entry.status
        status.hasFinishingTime = entry.finishingTask != .invalid
        Task { await reporter(id, entry.attempt, status) }
    }

    private func pruneFinished() {
        let inactive = sessions.filter { !$0.value.status.state.isPending && $0.value.status.state != .granted
            && $0.value.finishingTask == .invalid }
            .sorted { $0.value.status.updatedAt < $1.value.status.updatedAt }
        for (id, _) in inactive.prefix(max(0, inactive.count - 128)) { sessions[id] = nil }
    }
}
