import Foundation

enum NetworkAccessReason: String, Codable, Equatable, Sendable {
    case cellular
    case expensive
    case constrained
}

enum NetworkAccessChoice: String, Codable, Equatable, Sendable {
    case continueOnce
    case alwaysAllow
    case waitForWiFi
    case cancel
}

struct NetworkAccessRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let jobID: UUID
    let title: String
    let reason: NetworkAccessReason

    init(
        id: UUID = UUID(),
        jobID: UUID,
        title: String,
        reason: NetworkAccessReason
    ) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.reason = reason
    }
}

enum JobNetworkAuthorization: String, Codable, Equatable, Sendable {
    case continueOnce
    case waitForWiFi
}

enum DownloadPipelinePhase: String, Codable, Equatable, Sendable {
    case queued
    case analyzing
    case streamsResolved
    case transferring
    case sourcesReady
    case processing
    case awaitingPlaybackVerification
    case outputVerified
    case sponsorBlockVerified
    case chaptersVerified
    case exporting
    case complete
}

/// Durable state is recorded only at restart-safe boundaries. Signed media
/// URLs and HTTP headers are deliberately excluded.
struct DownloadPipelineCheckpoint: Codable, Equatable, Sendable {
    var phase: DownloadPipelinePhase
    var sourceFiles: [String: URL]
    var artworkURL: URL?
    var processedFileURL: URL?
    // Verified assembly before timeline/subtitle/chapter edits. Kept separately
    // so an interrupted edit can restart without editing an edited timeline.
    var baseProcessedFileURL: URL? = nil
    var sponsorBlockEditVerified: Bool?
    var sponsorBlockChaptersVerified: Bool?
    var sponsorBlockChapters: [MediaChapter]?
    var sponsorBlockFinalDurationSeconds: Double?
    var publicationRevision: Int?
    var publicationPlan: ExportPublicationPlan?
    var publicationReceipts: [ExportPublicationReceipt]?
    var nativeFileReceipts: [NativeFileReceipt]?
    var fragmentURLRefreshCounts: [String: Int]?
    var updatedAt: Date

    init(
        phase: DownloadPipelinePhase,
        sourceFiles: [String: URL] = [:],
        artworkURL: URL? = nil,
        processedFileURL: URL? = nil,
        sponsorBlockEditVerified: Bool? = nil,
        sponsorBlockChaptersVerified: Bool? = nil,
        sponsorBlockChapters: [MediaChapter]? = nil,
        sponsorBlockFinalDurationSeconds: Double? = nil,
        updatedAt: Date = .now
    ) {
        self.phase = phase
        self.sourceFiles = sourceFiles
        self.artworkURL = artworkURL
        self.processedFileURL = processedFileURL
        self.sponsorBlockEditVerified = sponsorBlockEditVerified
        self.sponsorBlockChaptersVerified = sponsorBlockChaptersVerified
        self.sponsorBlockChapters = sponsorBlockChapters
        self.sponsorBlockFinalDurationSeconds =
            sponsorBlockFinalDurationSeconds
        self.updatedAt = updatedAt
    }
}

extension DownloadStage {
    var supportsTransferPause: Bool {
        switch self {
        case .downloadingVideo, .downloadingAudio, .downloadingThumbnail, .downloadingSubtitles,
             .analyzing, .preparing, .waitingForTransfer, .waitingForProcessing, .waitingForBackgroundTime:
            true
        default:
            false
        }
    }

    var isProcessingWork: Bool {
        switch self {
        case .verifyingSources, .merging, .converting, .embeddingMetadata,
             .embeddingSubtitles, .burningInSubtitles,
             .removingSponsorSegments, .trimming, .writingChapters,
             .splittingChapters, .packaging, .zipping, .verifyingOutput:
            true
        default:
            false
        }
    }

    var requiresInProcessExecution: Bool {
        switch self {
        case .downloadingVideo, .downloadingAudio, .waiting, .waitingForTransfer, .waitingToRetry, .complete:
            false
        default: true
        }
    }

    func applyingProcessingProgress(
        expectedStage: DownloadStage,
        eventStage: MediaProcessingStage
    ) -> DownloadStage? {
        let isVerificationEvent = eventStage == .probing
            || eventStage == .verifying
        guard self == expectedStage
            || (self == .verifyingOutput && isVerificationEvent)
        else {
            return nil
        }
        return isVerificationEvent ? .verifyingOutput : self
    }
}

extension DownloadJob {
    var isAwaitingTransferCleanup: Bool { errorCode == "transfer_cleanup_pending" }
    var canPause: Bool {
        if [.queued, .waitingForNetwork, .waitingForWiFi, .waitingForCellularApproval,
            .waitingForRetry, .waitingForPower].contains(state) { return true }
        return state == .running && stage.supportsTransferPause
    }
    var isWaitingForTransferSlot: Bool { state == .running && stage == .waitingForTransfer }
    var isWaitingForBackgroundTime: Bool { state == .running && stage == .waitingForBackgroundTime }
}
