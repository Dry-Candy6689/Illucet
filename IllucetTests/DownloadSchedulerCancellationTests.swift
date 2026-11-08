import Foundation
import Testing
@testable import Illucet

struct DownloadSchedulerCancellationTests {
    @Test(arguments: Budget.allCases)
    func cancellingAQueuedCallerRemovesItsWaitWithoutReleasingAnotherJob(
        budget: Budget
    ) async throws {
        let scheduler = scheduler()
        let holder = UUID()
        let waiting = UUID()
        try await budget.acquire(scheduler, jobID: holder)
        let completion = Completion()
        let task = acquisition(scheduler, budget, waiting, completion)
        try await waitUntil { await budget.snapshot(scheduler).waitingCount == 1 }

        task.cancel()
        let completedBeforeRelease = await waitFor { await completion.finished }
        let afterCancellation = await budget.snapshot(scheduler)
        // Release even after a failed assertion so the regression cannot hang
        // the suite when a cancellation implementation leaves its waiter queued.
        await budget.release(scheduler, jobID: holder)
        await task.value
        await budget.release(scheduler, jobID: waiting)

        #expect(completedBeforeRelease)
        #expect(await completion.cancelled)
        #expect(afterCancellation.activeCount == 1)
        #expect(await budget.snapshot(scheduler).activeCount == 0)
        try await waitUntil { await budget.snapshot(scheduler).waitingCount == 0 }
    }

    @Test(arguments: Budget.allCases)
    func cancellingOneCallerKeepsAnotherCallerForTheSameJob(
        budget: Budget
    ) async throws {
        let scheduler = scheduler()
        let holder = UUID()
        let waiting = UUID()
        try await budget.acquire(scheduler, jobID: holder)
        let cancelledCompletion = Completion()
        let survivingCompletion = Completion()
        let cancelled = acquisition(scheduler, budget, waiting, cancelledCompletion)
        let surviving = acquisition(scheduler, budget, waiting, survivingCompletion)
        try await waitUntil { await budget.snapshot(scheduler).waitingCount == 1 }

        cancelled.cancel()
        let cancelledBeforeRelease = await waitFor { await cancelledCompletion.finished }
        #expect(!(await survivingCompletion.finished))
        await budget.release(scheduler, jobID: holder)
        await cancelled.value
        await surviving.value

        #expect(cancelledBeforeRelease)
        #expect(await cancelledCompletion.cancelled)
        #expect(await survivingCompletion.succeeded)
        #expect(await budget.snapshot(scheduler).activeCount == 1)
        #expect(await budget.snapshot(scheduler).waitingCount == 0)
        await budget.release(scheduler, jobID: waiting)
        #expect(await budget.snapshot(scheduler).activeCount == 0)
    }

    @Test(arguments: Budget.allCases)
    func explicitReleaseInvalidatesTheOldRequestBeforeReacquiringTheSameJob(
        budget: Budget
    ) async throws {
        let scheduler = scheduler()
        let holder = UUID()
        let waiting = UUID()
        try await budget.acquire(scheduler, jobID: holder)
        let oldCompletion = Completion()
        let old = acquisition(scheduler, budget, waiting, oldCompletion)
        try await waitUntil { await budget.snapshot(scheduler).waitingCount == 1 }

        await budget.release(scheduler, jobID: waiting)
        await old.value
        #expect(await oldCompletion.cancelled)
        #expect(await budget.snapshot(scheduler).activeCount == 1)
        #expect(await budget.snapshot(scheduler).waitingCount == 0)

        let newCompletion = Completion()
        let replacement = acquisition(scheduler, budget, waiting, newCompletion)
        try await waitUntil { await budget.snapshot(scheduler).waitingCount == 1 }
        await budget.release(scheduler, jobID: holder)
        await replacement.value

        #expect(await newCompletion.succeeded)
        #expect(await budget.snapshot(scheduler).activeCount == 1)
        await budget.release(scheduler, jobID: waiting)
        #expect(await budget.snapshot(scheduler).activeCount == 0)
    }

    @Test(arguments: Budget.allCases)
    func alreadyCancelledCallerCannotClaimOrReleaseAnExistingJobPermit(
        budget: Budget
    ) async throws {
        let scheduler = scheduler()
        let jobID = UUID()
        try await budget.acquire(scheduler, jobID: jobID)
        let completion = Completion()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await budget.acquire(scheduler, jobID: jobID)
                await completion.record(succeeded: true)
            } catch is CancellationError {
                await completion.record(cancelled: true)
            } catch { Issue.record("Unexpected error: \(error)") }
        }
        await task.value

        #expect(await completion.cancelled)
        #expect(await budget.snapshot(scheduler).activeCount == 1)
        await budget.release(scheduler, jobID: jobID)
        #expect(await budget.snapshot(scheduler).activeCount == 0)
    }

    @Test
    func cancellingAnOperationAfterItAcquiresDoesNotRevokeItsPermit() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let acquired = Completion()
        let finish = AsyncGate()
        let task = Task {
            try await pool.withPermit {
                await acquired.record(succeeded: true)
                // Model native work that cooperatively finishes after cancel.
                await finish.wait()
            }
        }
        try await waitUntil { await acquired.finished }
        task.cancel()
        #expect(await pool.snapshot().activeCount == 1)
        await finish.open()
        try await task.value
        #expect(await pool.snapshot().activeCount == 0)
    }

    @Test
    func prioritizingAWaiterChangesNextAdmissionWithoutPreemption() async throws {
        let scheduler = scheduler()
        let holder = UUID(), firstID = UUID(), secondID = UUID()
        try await scheduler.acquireTransfer(jobID: holder)
        let firstDone = Completion(), secondDone = Completion()
        let first = acquisition(scheduler, .transfer, firstID, firstDone)
        try await waitUntil { await scheduler.transferSnapshot().waitingCount == 1 }
        let second = acquisition(scheduler, .transfer, secondID, secondDone)
        try await waitUntil { await scheduler.transferSnapshot().waitingCount == 2 }
        await scheduler.prioritizeTransfer(jobID: secondID, priority: -1)
        #expect(await scheduler.transferSnapshot().activeCount == 1)
        #expect(!(await secondDone.finished))
        await scheduler.releaseTransfer(jobID: holder)
        try await waitUntil { await secondDone.succeeded }
        #expect(!(await firstDone.finished))
        await scheduler.releaseTransfer(jobID: secondID)
        await first.value; await second.value
        await scheduler.releaseTransfer(jobID: firstID)
        #expect(await scheduler.transferSnapshot().activeCount == 0)
    }

    enum Budget: CaseIterable, Sendable {
        case transfer, processing

        func acquire(_ scheduler: DownloadScheduler, jobID: UUID) async throws {
            switch self {
            case .transfer: try await scheduler.acquireTransfer(jobID: jobID)
            case .processing: try await scheduler.acquireProcessing(jobID: jobID)
            }
        }

        func release(_ scheduler: DownloadScheduler, jobID: UUID) async {
            switch self {
            case .transfer: await scheduler.releaseTransfer(jobID: jobID)
            case .processing: await scheduler.releaseProcessing(jobID: jobID)
            }
        }

        func snapshot(_ scheduler: DownloadScheduler) async -> AsyncPermitPoolSnapshot {
            switch self {
            case .transfer: await scheduler.transferSnapshot()
            case .processing: await scheduler.processingSnapshot()
            }
        }
    }

    private func scheduler() -> DownloadScheduler {
        DownloadScheduler(
            transferPermits: AsyncPermitPool(limit: 1),
            processingPermits: AsyncPermitPool(limit: 1)
        )
    }

    private func acquisition(
        _ scheduler: DownloadScheduler,
        _ budget: Budget,
        _ jobID: UUID,
        _ completion: Completion
    ) -> Task<Void, Never> {
        Task {
            do {
                try await budget.acquire(scheduler, jobID: jobID)
                await completion.record(succeeded: true)
            } catch is CancellationError {
                await completion.record(cancelled: true)
            } catch {
                await completion.record()
                Issue.record("Unexpected scheduler error: \(error)")
            }
        }
    }

    private func waitUntil(
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let satisfied = await waitFor(condition)
        try #require(satisfied, "Scheduler did not reach the expected state.")
    }

    private func waitFor(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor Completion {
    private(set) var finished = false
    private(set) var succeeded = false
    private(set) var cancelled = false

    func record(succeeded: Bool = false, cancelled: Bool = false) {
        finished = true
        self.succeeded = succeeded
        self.cancelled = cancelled
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
