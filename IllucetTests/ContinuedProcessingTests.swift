import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Illucet

@Suite @MainActor
struct ContinuedProcessingTests {
    @Test
    func systemOverlaysKeepForegroundExecutionUntilTheSceneBackgrounds() async {
        let controller = ContinuedProcessingController(scheduler: LeaseSchedulerFixture(), foreground: { false })
        let scene = UUID(), job = UUID(), attempt = UUID()
        for phase in [ScenePhase.active, .inactive, .active] {
            #expect(controller.setSceneActive(scene, active: phase.permitsDownloadExecution))
            #expect(await controller.canProcess(jobID: job, attempt: attempt))
        }
        #expect(!controller.setSceneActive(scene, active: ScenePhase.background.permitsDownloadExecution))
        #expect(!(await controller.canProcess(jobID: job, attempt: attempt)))
    }

    @Test
    func anyActiveSceneAllowsForegroundWork() async {
        let controller = ContinuedProcessingController()
        let first = UUID(), second = UUID(), job = UUID(), attempt = UUID()
        #expect(controller.setSceneActive(first, active: true))
        #expect(controller.setSceneActive(second, active: true))
        #expect(controller.setSceneActive(first, active: false))
        #expect(await controller.canProcess(jobID: job, attempt: attempt))
        #expect(!controller.setSceneActive(second, active: false))
        #expect(!(await controller.canProcess(jobID: job, attempt: attempt)))
    }
}

@Suite @MainActor
struct ContinuedProcessingLeaseTests {
    @Test(arguments: [false, true])
    func finishingAllowanceSurvivesSchedulerRejectionOnlyUntilUIKitExpires(submission: Bool) async throws {
        let scheduler = LeaseSchedulerFixture()
        scheduler.registered = submission
        scheduler.rejectSubmission = submission
        let finishing = FinishingTimeFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true }, finishingTime: finishing)
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID()
        let expired = LeaseWaitFlag()
        await controller.begin(job: job, attempt: attempt, expiration: { await expired.mark() })
        _ = controller.setSceneActive(UUID(), active: false)
        #expect(await controller.canProcess(jobID: job.id, attempt: attempt))
        #expect(!(await controller.canProcess(jobID: job.id, attempt: UUID())))
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .denied)
        #expect(await controller.status(jobID: job.id, attempt: attempt).hasFinishingTime)
        finishing.expirations[0]()
        #expect(finishing.ended == finishing.started, "End UIKit's task synchronously in its expiration handler")
        for _ in 0..<100 {
            if await expired.value { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await expired.value)
        #expect(!(await controller.canProcess(jobID: job.id, attempt: attempt)))
        #expect(!(await controller.status(jobID: job.id, attempt: attempt).hasFinishingTime))
        #expect(finishing.ended == finishing.started)
        await controller.finish(jobID: job.id, attempt: attempt, success: false)
        #expect(finishing.ended.count == 1)
    }

    @Test func invalidFinishingTokenAndBackgroundStartsGrantNoAuthority() async {
        let scheduler = LeaseSchedulerFixture()
        scheduler.registered = false
        let finishing = FinishingTimeFixture()
        finishing.permitsBegin = false
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true }, finishingTime: finishing)
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID()
        await controller.begin(job: job, attempt: attempt, expiration: {})
        _ = controller.setSceneActive(UUID(), active: false)
        #expect(!(await controller.canProcess(jobID: job.id, attempt: attempt)))
        #expect(!(await controller.status(jobID: job.id, attempt: attempt).hasFinishingTime))
        await controller.finish(jobID: job.id, attempt: attempt, success: false)
        #expect(finishing.ended.isEmpty)
        finishing.permitsBegin = true
        await controller.begin(job: job, attempt: UUID(), expiration: {})
        #expect(finishing.started.isEmpty, "A background start cannot reserve foreground finishing time")
    }

    @Test func actualContinuedGrantEndsFinishingTimeAndFencesItsLateExpiration() async throws {
        let scheduler = LeaseSchedulerFixture()
        let finishing = FinishingTimeFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true }, finishingTime: finishing)
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID()
        let expired = LeaseWaitFlag()
        await controller.begin(job: job, attempt: attempt, expiration: { await expired.mark() })
        _ = controller.setSceneActive(UUID(), active: false)
        let real = LeaseTaskFixture(identifier: try #require(scheduler.submissions.first))
        scheduler.launch(real)
        #expect(finishing.ended == finishing.started)
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .granted)
        #expect(!(await controller.status(jobID: job.id, attempt: attempt).hasFinishingTime))
        finishing.expirations[0]()
        await Task.yield()
        #expect(!(await expired.value))
        #expect(await controller.canProcess(jobID: job.id, attempt: attempt))
        await controller.finish(jobID: job.id, attempt: attempt, success: true)
        #expect(real.completions == [true])
        #expect(finishing.ended.count == 1)
    }

    @Test(arguments: [false, true])
    func staleFinishingExpirationCannotEndTheReplacementAttempt(sameAttempt: Bool) async {
        let scheduler = LeaseSchedulerFixture()
        scheduler.registered = false
        let finishing = FinishingTimeFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true }, finishingTime: finishing)
        let job = DeveloperFixtures.sponsorBlockAppliedJob, first = UUID()
        let current = sameAttempt ? first : UUID()
        let expired = LeaseWaitFlag()
        await controller.begin(job: job, attempt: first, expiration: { await expired.mark() })
        await controller.finish(jobID: job.id, attempt: first, success: false)
        await controller.begin(job: job, attempt: current, expiration: { await expired.mark() })
        _ = controller.setSceneActive(UUID(), active: false)
        finishing.expirations[0]()
        await Task.yield()
        #expect(!(await expired.value))
        #expect(await controller.canProcess(jobID: job.id, attempt: current))
        #expect(finishing.ended.count == 1)
        await controller.finish(jobID: job.id, attempt: current, success: true)
        await controller.finish(jobID: job.id, attempt: current, success: true)
        #expect(finishing.ended == finishing.started)
    }
    @Test(arguments: [false, true])
    func submissionAcknowledgedAfterCancellationCannotLeaveAQueuedRequest(rejected: Bool) async throws {
        let scheduler = LeaseSchedulerFixture()
        scheduler.holdNextSubmission = true
        scheduler.rejectSubmission = rejected
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true })
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID()
        let begin = Task { await controller.begin(job: job, attempt: attempt, expiration: {}) }
        for _ in 0..<200 where scheduler.submissions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let identifier = try #require(scheduler.submissions.first)
        await controller.finish(jobID: job.id, attempt: attempt, success: false)
        scheduler.releaseSubmission()
        await begin.value
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .finished)
        #expect(scheduler.cancelled == Array(repeating: identifier, count: rejected ? 1 : 2))
        let stale = LeaseTaskFixture(identifier: identifier)
        scheduler.launch(stale)
        #expect(stale.completions == [false])
    }

    @Test
    func queuedLeaseWakesTheExistingWaiterOnlyAfterGrant() async throws {
        let scheduler = LeaseSchedulerFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true })
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID(), scene = UUID()
        await controller.begin(job: job, attempt: attempt, expiration: {})
        #expect(scheduler.registrations == scheduler.submissions)
        #expect(scheduler.registrations.count == 1)
        #expect(!scheduler.registrations[0].contains("*"))
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .queued)
        _ = controller.setSceneActive(scene, active: false)
        #expect(!(await controller.canProcess(jobID: job.id, attempt: attempt)))
        let reached = LeaseWaitFlag()
        let wait = Task { try await controller.waitForExecution(jobID: job.id, attempt: attempt); await reached.mark() }
        await Task.yield()
        #expect(!(await reached.value))
        let grant = LeaseTaskFixture(identifier: try #require(scheduler.submissions.first))
        scheduler.launch(grant)
        try await wait.value
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .granted)
        #expect(await controller.canProcess(jobID: job.id, attempt: attempt))
        await controller.finish(jobID: job.id, attempt: attempt, success: true)
        await controller.finish(jobID: job.id, attempt: attempt, success: true)
        #expect(grant.completions == [true])
        #expect(scheduler.cancelled.count == 1)
    }

    @Test(arguments: [false, true])
    func rejectedRegistrationOrSubmissionHasSafeReasonAndNoRetryLoop(submission: Bool) async {
        let scheduler = LeaseSchedulerFixture()
        scheduler.registered = submission
        scheduler.rejectSubmission = submission
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true })
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID()
        await controller.begin(job: job, attempt: attempt, expiration: {})
        await controller.begin(job: job, attempt: attempt, expiration: {})
        let status = await controller.status(jobID: job.id, attempt: attempt)
        #expect(status.state == .denied)
        #expect(status.reason == (submission ? .submissionRejected : .registrationRejected))
        #expect(await controller.canProcess(jobID: job.id, attempt: attempt))
        _ = controller.setSceneActive(UUID(), active: false)
        #expect(!(await controller.canProcess(jobID: job.id, attempt: attempt)))
        #expect(scheduler.submissions.count == (submission ? 1 : 0))
        #expect(scheduler.registrationCount == 1)
    }

    @Test
    func cancellationRemovesOnlyItsWaiterAndForegroundCanWakeTheOther() async throws {
        let scheduler = LeaseSchedulerFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true })
        let job = DeveloperFixtures.sponsorBlockAppliedJob, attempt = UUID(), scene = UUID()
        await controller.begin(job: job, attempt: attempt, expiration: {})
        _ = controller.setSceneActive(scene, active: false)
        let cancelled = Task { try await controller.waitForExecution(jobID: job.id, attempt: attempt) }
        let surviving = Task { try await controller.waitForExecution(jobID: job.id, attempt: attempt) }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        _ = controller.setSceneActive(scene, active: true)
        try await surviving.value
        #expect(await controller.status(jobID: job.id, attempt: attempt).state == .queued)
        #expect(await controller.canProcess(jobID: job.id, attempt: attempt))
        await controller.finish(jobID: job.id, attempt: attempt, success: false)
        let late = LeaseTaskFixture(identifier: try #require(scheduler.submissions.first))
        scheduler.launch(late)
        #expect(late.completions == [false])
    }

    @Test(arguments: [false, true])
    func staleLaunchAndExpirationCannotAffectReplacementLease(sameAttempt: Bool) async throws {
        let scheduler = LeaseSchedulerFixture()
        let controller = ContinuedProcessingController(scheduler: scheduler, foreground: { true })
        let job = DeveloperFixtures.sponsorBlockAppliedJob, oldAttempt = UUID()
        let newAttempt = sameAttempt ? oldAttempt : UUID()
        let expirations = LeaseWaitFlag()
        await controller.begin(job: job, attempt: oldAttempt, expiration: { await expirations.mark() })
        let old = LeaseTaskFixture(identifier: try #require(scheduler.submissions.first))
        scheduler.launch(old)
        let staleExpiration = try #require(old.expiration)
        await controller.finish(jobID: job.id, attempt: oldAttempt, success: false)
        await controller.begin(job: job, attempt: newAttempt, expiration: { await expirations.mark() })
        let current = LeaseTaskFixture(identifier: try #require(scheduler.submissions.last))
        scheduler.launch(current)
        staleExpiration()
        await Task.yield()
        #expect(await controller.status(jobID: job.id, attempt: newAttempt).state == .granted)
        #expect(!(await expirations.value))
        #expect(current.completions.isEmpty)
        current.expiration?()
        for _ in 0..<100 where current.completions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(current.completions == [false])
        #expect(await expirations.value)
        #expect(await controller.status(jobID: job.id, attempt: newAttempt).state == .expired)
        await controller.finish(jobID: job.id, attempt: newAttempt, success: false)
        #expect(current.completions == [false])
        let unknown = LeaseTaskFixture(identifier: "unknown")
        scheduler.launch(unknown)
        #expect(unknown.completions == [false])
    }
}

@MainActor
private final class LeaseSchedulerFixture: ContinuedProcessingScheduling {
    var registered = true
    var rejectSubmission = false
    var holdNextSubmission = false
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    var registrationCount = 0
    var registrations: [String] = []
    var submissions: [String] = []
    var cancelled: [String] = []
    var handler: (@MainActor @Sendable (any ContinuedProcessingTaskHandling) -> Void)?
    func register(identifier: String, handler: @escaping @MainActor @Sendable (any ContinuedProcessingTaskHandling) -> Void) -> Bool {
        registrationCount += 1
        registrations.append(identifier)
        self.handler = handler
        return registered
    }
    func submit(identifier: String, title: String, subtitle: String) async throws {
        submissions.append(identifier)
        if holdNextSubmission {
            holdNextSubmission = false
            await withCheckedContinuation { submissionWaiter = $0 }
        }
        if rejectSubmission { throw LeaseFixtureError.rejected }
    }
    func releaseSubmission() { submissionWaiter?.resume(); submissionWaiter = nil }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func launch(_ task: LeaseTaskFixture) { handler?(task) }
}

@MainActor
private final class FinishingTimeFixture: BackgroundFinishingTimeProviding {
    var permitsBegin = true
    var started: [UIBackgroundTaskIdentifier] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var expirations: [@MainActor @Sendable () -> Void] = []
    private var next = UIBackgroundTaskIdentifier(rawValue: 1)
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        expirations.append(expiration)
        guard permitsBegin else { return .invalid }
        let token = next
        next = .init(rawValue: token.rawValue + 1)
        started.append(token)
        return token
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) { ended.append(identifier) }
}

@MainActor
private final class LeaseTaskFixture: ContinuedProcessingTaskHandling {
    let identifier: String
    var expiration: (@Sendable () -> Void)?
    var completions: [Bool] = []
    init(identifier: String) { self.identifier = identifier }
    func prepare(expiration: @escaping @Sendable () -> Void) { self.expiration = expiration }
    func report(title: String, subtitle: String, fraction: Double?) {}
    func complete(success: Bool) { completions.append(success) }
}

private actor LeaseWaitFlag {
    private(set) var value = false
    func mark() { value = true }
}
private enum LeaseFixtureError: Error { case rejected }
