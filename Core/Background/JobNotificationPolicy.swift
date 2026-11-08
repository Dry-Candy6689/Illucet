import Foundation

extension AppSettings {
    var hasNotificationEventsEnabled: Bool {
        notifyDownloadComplete || notifyProcessingComplete || notifyFailure
            || notifyNeedsAttention || notifyLowStorage || notifyUpdates
            || (notifyPlaylistComplete ?? true) || (notifyRetryExhausted ?? true)
    }

    /// Explicit permission requests opt in to useful events if none were chosen.
    /// Existing individual event choices remain intact.
    mutating func enableRecommendedNotificationEventsIfNeeded() {
        guard !hasNotificationEventsEnabled else { return }
        notifyDownloadComplete = true
        notifyFailure = true
        notifyNeedsAttention = true
        notifyLowStorage = true
        notifyUpdates = true
        notifyPlaylistComplete = true
        notifyRetryExhausted = true
    }
}

enum JobNotificationKind: String, Sendable {
    case processingComplete, needsAttention, lowStorage, retryExhausted
    var title: String {
        switch self {
        case .processingComplete: "Processing complete"
        case .needsAttention: "Illucet needs attention"
        case .lowStorage: "Not enough storage"
        case .retryExhausted: "Download retries exhausted"
        }
    }
}

enum JobNotificationPolicy {
    static func events(previous: DownloadJob?, job: DownloadJob, settings: AppSettings) -> [JobNotificationKind] {
        // Restored terminal records are history, not new events.
        guard let previous else { return [] }
        var events: [JobNotificationKind] = []
        if settings.notifyProcessingComplete, job.pipelineCheckpoint?.phase == .exporting,
           previous.pipelineCheckpoint?.phase != .exporting,
           job.pipelineCheckpoint?.processedFileURL != nil { events.append(.processingComplete) }
        if settings.notifyNeedsAttention, previous.state != job.state,
           job.state == .needsAttention || job.state == .waitingForCellularApproval { events.append(.needsAttention) }
        if job.state == .failed, previous.state != .failed {
            if settings.notifyLowStorage, job.errorCode == "insufficient_storage" { events.append(.lowStorage) }
            if settings.notifyRetryExhausted ?? true, job.retryExhausted == true { events.append(.retryExhausted) }
        }
        return events
    }
}
