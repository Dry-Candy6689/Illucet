import Foundation
import Testing
@testable import Illucet

struct PresentationQueueTests {
    @Test
    func preservesFIFOOrderAcrossSeveralArrivals() throws {
        let duplicateA = duplicate(
            requestID: fixedUUID(1),
            jobID: fixedUUID(101),
            filename: "A.mp4"
        )
        let shareB = share(
            jobID: fixedUUID(102),
            title: "B"
        )
        let duplicateC = duplicate(
            requestID: fixedUUID(3),
            jobID: fixedUUID(103),
            filename: "C.mp4"
        )
        var queue = PendingUserPresentationQueue()

        queue.enqueue(.duplicate(duplicateA))
        queue.enqueue(.share(shareB))
        queue.enqueue(.duplicate(duplicateC))

        #expect(queue.count == 3)
        #expect(queue.current == .duplicate(duplicateA))
        #expect(
            queue.dequeueCurrent(id: .duplicate(duplicateA.id))
                == .duplicate(duplicateA)
        )
        #expect(queue.current == .share(shareB))
        #expect(
            queue.dequeueCurrent(id: .share(shareB.jobID))
                == .share(shareB)
        )
        #expect(queue.current == .duplicate(duplicateC))
    }

    @Test
    func severalDuplicateRequestsCannotOverwriteEachOther() {
        let sharedJobID = fixedUUID(201)
        let first = duplicate(
            requestID: fixedUUID(11),
            jobID: sharedJobID,
            filename: "Media.mp4"
        )
        let second = duplicate(
            requestID: fixedUUID(12),
            jobID: sharedJobID,
            filename: "Media-thumbnail.jpg"
        )
        var queue = PendingUserPresentationQueue()

        queue.enqueue(.duplicate(first))
        queue.enqueue(.duplicate(second))

        #expect(queue.count == 2)
        #expect(first.id != second.id)
        #expect(queue.current == .duplicate(first))
        _ = queue.dequeueCurrent(id: .duplicate(first.id))
        #expect(queue.current == .duplicate(second))
    }

    @Test
    func sequentialConflictsForOneJobReceiveUniqueRequestIDs() {
        let jobID = fixedUUID(251)
        let first = DuplicateConflict(
            jobID: jobID,
            videoID: "fixture-video",
            desiredURL: URL(filePath: "/tmp/Media.mp4"),
            playlistItemID: nil
        )
        let companion = DuplicateConflict(
            jobID: jobID,
            videoID: "fixture-video",
            desiredURL: URL(filePath: "/tmp/Media-thumbnail.jpg"),
            playlistItemID: nil
        )

        #expect(first.jobID == companion.jobID)
        #expect(first.id != companion.id)
    }

    @Test
    func repeatedShareForOneJobRefreshesInPlace() {
        let jobID = fixedUUID(301)
        let first = share(
            jobID: jobID,
            title: "First",
            filenames: ["media.mp4"]
        )
        let refreshed = share(
            jobID: jobID,
            title: "Refreshed",
            filenames: ["media.mp4", "thumbnail.jpg"]
        )
        let later = share(
            jobID: fixedUUID(302),
            title: "Later"
        )
        var queue = PendingUserPresentationQueue()

        queue.enqueue(.share(first))
        queue.enqueue(.share(later))
        queue.enqueue(.share(refreshed))

        #expect(queue.count == 2)
        #expect(queue.current == .share(refreshed))
        _ = queue.dequeueCurrent(id: .share(jobID))
        #expect(queue.current == .share(later))
    }

    @Test
    func staleCallbackCannotRemoveCurrentRequest() {
        let first = duplicate(
            requestID: fixedUUID(21),
            jobID: fixedUUID(401),
            filename: "First.mp4"
        )
        let second = duplicate(
            requestID: fixedUUID(22),
            jobID: fixedUUID(402),
            filename: "Second.mp4"
        )
        var queue = PendingUserPresentationQueue()
        queue.enqueue(.duplicate(first))
        queue.enqueue(.duplicate(second))
        _ = queue.dequeueCurrent(id: .duplicate(first.id))

        let staleResult = queue.dequeueCurrent(
            id: .duplicate(first.id)
        )

        #expect(staleResult == nil)
        #expect(queue.current == .duplicate(second))
        #expect(queue.count == 1)
    }

    @Test
    func cancellationRemovesOnlyDuplicateRequestsForThatJob() {
        let cancelledJobID = fixedUUID(501)
        let first = duplicate(
            requestID: fixedUUID(31),
            jobID: cancelledJobID,
            filename: "First.mp4"
        )
        let retainedShare = share(
            jobID: cancelledJobID,
            title: "Finished share"
        )
        let retainedDuplicate = duplicate(
            requestID: fixedUUID(32),
            jobID: fixedUUID(502),
            filename: "Other.mp4"
        )
        var queue = PendingUserPresentationQueue()
        queue.enqueue(.duplicate(first))
        queue.enqueue(.share(retainedShare))
        queue.enqueue(.duplicate(retainedDuplicate))

        queue.removeDuplicateRequests(jobID: cancelledJobID)

        #expect(queue.count == 2)
        #expect(queue.current == .share(retainedShare))
        #expect(
            queue.requests.contains(.duplicate(retainedDuplicate))
        )
    }

    @Test
    func appPresentationStateGatesFIFOUntilDismissalFinishes() throws {
        let conflict = duplicate(
            requestID: fixedUUID(41),
            jobID: fixedUUID(601),
            filename: "First.mp4"
        )
        let laterShare = share(
            jobID: fixedUUID(602),
            title: "Later"
        )
        var state = IllucetAppPresentationState()

        state.enqueue(.duplicate(conflict))
        state.enqueue(.share(laterShare))

        #expect(state.pendingDuplicateConflict == conflict)
        let beganResolution = state.beginDuplicateResolution(
            requestID: conflict.id
        )
        #expect(beganResolution)
        let dismissalValue = state.dismissDuplicate(requestID: conflict.id)
        let dismissal = try #require(dismissalValue)
        #expect(!dismissal.needsCancellation)
        #expect(state.isDismissing)
        #expect(state.pendingShareRequest == nil)

        state.finishDismissal()

        #expect(!state.isDismissing)
        #expect(state.pendingShareRequest == laterShare)
    }

    @Test
    func appPresentationStateTreatsUnsubmittedDismissalAsCancellation()
        throws
    {
        let conflict = duplicate(
            requestID: fixedUUID(42),
            jobID: fixedUUID(603),
            filename: "Cancelled.mp4"
        )
        var state = IllucetAppPresentationState()
        state.enqueue(.duplicate(conflict))

        let dismissalValue = state.dismissDuplicate(requestID: conflict.id)
        let dismissal = try #require(dismissalValue)

        #expect(dismissal.value == conflict)
        #expect(dismissal.needsCancellation)
        #expect(state.queue.isEmpty)
        state.finishDismissal()
        #expect(!state.isEnabled)
    }

    @Test
    func appPresentationStateDiscardAdvancesOnlyAfterDismissalBoundary() {
        let cancelledJobID = fixedUUID(604)
        let cancelled = duplicate(
            requestID: fixedUUID(43),
            jobID: cancelledJobID,
            filename: "Cancelled.mp4"
        )
        let retained = duplicate(
            requestID: fixedUUID(44),
            jobID: fixedUUID(605),
            filename: "Retained.mp4"
        )
        var state = IllucetAppPresentationState()
        state.enqueue(.duplicate(cancelled))
        state.enqueue(.duplicate(retained))

        let discardedActive = state.discardDuplicateRequests(
            jobID: cancelledJobID
        )
        #expect(discardedActive)
        #expect(state.pendingDuplicateConflict == nil)
        #expect(state.queue.current == .duplicate(retained))

        state.finishDismissal()

        #expect(state.pendingDuplicateConflict == retained)
    }

    @Test
    func appPresentationStateKeepsNetworkSubmissionIdempotent() throws {
        let request = NetworkAccessRequest(
            id: fixedUUID(45),
            jobID: fixedUUID(606),
            title: "Cellular fixture",
            reason: .cellular
        )
        var state = IllucetAppPresentationState()
        state.enqueue(.network(request))

        let firstSubmission = state.beginNetworkResolution(
            requestID: request.id
        )
        let repeatedSubmission = state.beginNetworkResolution(
            requestID: request.id
        )
        #expect(firstSubmission)
        #expect(!repeatedSubmission)
        let dismissalValue = state.dismissNetwork(requestID: request.id)
        let dismissal = try #require(dismissalValue)

        #expect(!dismissal.needsCancellation)
        #expect(dismissal.value == request)
    }

    private func duplicate(
        requestID: UUID,
        jobID: UUID,
        filename: String
    ) -> DuplicateConflict {
        DuplicateConflict(
            id: requestID,
            jobID: jobID,
            videoID: "fixture-video",
            desiredURL: URL(filePath: "/tmp/\(filename)"),
            playlistItemID: nil
        )
    }

    private func share(
        jobID: UUID,
        title: String,
        filenames: [String] = ["media.mp4"]
    ) -> SharePresentationRequest {
        SharePresentationRequest(
            jobID: jobID,
            title: title,
            fileURLs: filenames.map {
                URL(filePath: "/tmp/\($0)")
            }
        )
    }

    private func fixedUUID(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                value
            )
        )!
    }
}
