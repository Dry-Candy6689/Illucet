import Foundation

struct IllucetAppPresentationState: Equatable, Sendable {
    struct Dismissal<Value: Equatable & Sendable>:
        Equatable,
        Sendable
    {
        let value: Value
        let needsCancellation: Bool
    }

    private(set) var queue = PendingUserPresentationQueue()
    private(set) var isEnabled = false
    private(set) var isDismissing = false

    private var submittedDuplicateRequestID: UUID?
    private var submittedShareRequestID: UUID?
    private var submittedNetworkRequestID: UUID?

    var pendingDuplicateConflict: DuplicateConflict? {
        guard isEnabled,
              case let .duplicate(conflict) = queue.current
        else {
            return nil
        }
        return conflict
    }

    var pendingShareRequest: SharePresentationRequest? {
        guard isEnabled,
              case let .share(request) = queue.current
        else {
            return nil
        }
        return request
    }

    var pendingNetworkAccessRequest: NetworkAccessRequest? {
        guard isEnabled,
              case let .network(request) = queue.current
        else {
            return nil
        }
        return request
    }

    mutating func enqueue(_ presentation: PendingUserPresentation) {
        queue.enqueue(presentation)
        guard !isEnabled, !isDismissing else { return }
        isEnabled = true
    }

    mutating func beginDuplicateResolution(requestID: UUID) -> Bool {
        guard pendingDuplicateConflict?.id == requestID,
              submittedDuplicateRequestID == nil
        else {
            return false
        }
        submittedDuplicateRequestID = requestID
        return true
    }

    mutating func dismissDuplicate(
        requestID: UUID?
    ) -> Dismissal<DuplicateConflict>? {
        guard let requestID,
              case let .duplicate(conflict) = queue.current,
              conflict.id == requestID
        else {
            return nil
        }
        beginDismissal()
        let dismissal = Dismissal(
            value: conflict,
            needsCancellation: submittedDuplicateRequestID != conflict.id
        )
        _ = queue.dequeueCurrent(id: .duplicate(conflict.id))
        submittedDuplicateRequestID = nil
        return dismissal
    }

    mutating func beginNetworkResolution(requestID: UUID) -> Bool {
        guard pendingNetworkAccessRequest?.id == requestID,
              submittedNetworkRequestID == nil
        else {
            return false
        }
        submittedNetworkRequestID = requestID
        return true
    }

    mutating func dismissNetwork(
        requestID: UUID?
    ) -> Dismissal<NetworkAccessRequest>? {
        guard let requestID,
              case let .network(request) = queue.current,
              request.id == requestID
        else {
            return nil
        }
        beginDismissal()
        let dismissal = Dismissal(
            value: request,
            needsCancellation: submittedNetworkRequestID != request.id
        )
        _ = queue.dequeueCurrent(id: .network(request.id))
        submittedNetworkRequestID = nil
        return dismissal
    }

    mutating func beginShareCompletion(requestID: UUID) -> Bool {
        guard pendingShareRequest?.id == requestID,
              submittedShareRequestID == nil
        else {
            return false
        }
        submittedShareRequestID = requestID
        beginDismissal()
        return true
    }

    mutating func dismissShare() -> Dismissal<SharePresentationRequest>? {
        guard case let .share(request) = queue.current else { return nil }
        let dismissal = Dismissal(
            value: request,
            needsCancellation: submittedShareRequestID != request.id
        )
        beginDismissal()
        _ = queue.dequeueCurrent(id: .share(request.jobID))
        submittedShareRequestID = nil
        return dismissal
    }

    mutating func finishDismissal() {
        isDismissing = false
        isEnabled = !queue.isEmpty
    }

    mutating func discardDuplicateRequests(jobID: UUID) -> Bool {
        let activeConflict: DuplicateConflict? = {
            guard case let .duplicate(conflict) = queue.current,
                  conflict.jobID == jobID
            else {
                return nil
            }
            return conflict
        }()
        if let activeConflict {
            submittedDuplicateRequestID = activeConflict.id
            beginDismissal()
        }
        queue.removeDuplicateRequests(jobID: jobID)
        if activeConflict != nil {
            submittedDuplicateRequestID = nil
            return true
        }
        if queue.isEmpty {
            isEnabled = false
        }
        return false
    }

    mutating func discardRequests(jobID: UUID) -> Bool {
        let activeRequest = queue.current
        queue.removeRequests(jobID: jobID)
        guard let activeRequest, activeRequest.jobID == jobID else {
            return false
        }
        beginDismissal()
        submittedDuplicateRequestID = nil
        submittedNetworkRequestID = nil
        return true
    }

    private mutating func beginDismissal() {
        isEnabled = false
        isDismissing = true
    }
}
