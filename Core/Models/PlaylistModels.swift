import Foundation

enum PlaylistKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case mix
    case shorts
    case privateCollection
    case creatorUploads, creatorShorts, creatorReplays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlist: "Playlist"
        case .mix: "Mix / radio"
        case .shorts: "Shorts playlist"
        case .privateCollection: "Private playlist"
        case .creatorUploads: "Creator uploads"
        case .creatorShorts: "Creator Shorts"
        case .creatorReplays: "Creator replays"
        }
    }
}

enum PlaylistEntryAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case privateVideo
    case deleted

    var isDownloadable: Bool {
        self == .available
    }
}

struct PlaylistEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let index: Int
    let videoID: String?
    let canonicalURL: URL?
    let title: String
    let creator: String?
    let durationSeconds: Double?
    let thumbnailURL: URL?
    let estimatedBytes: Int64?
    let availability: PlaylistEntryAvailability

    var uploadDate: String? = nil
    var height: Int? = nil
    var isShort: Bool? = nil
    var isLive: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case uploadDate = "upload_date"
        case height
        case isShort = "is_short"
        case isLive = "is_live"
        case id
        case index
        case videoID = "video_id"
        case canonicalURL = "canonical_url"
        case title
        case creator
        case durationSeconds = "duration_seconds"
        case thumbnailURL = "thumbnail_url"
        case estimatedBytes = "estimated_bytes"
        case availability
    }

    init(
        id: String? = nil,
        index: Int,
        videoID: String?,
        canonicalURL: URL?,
        title: String,
        creator: String?,
        durationSeconds: Double?,
        thumbnailURL: URL?,
        estimatedBytes: Int64?,
        availability: PlaylistEntryAvailability
    ) {
        self.id = id ?? Self.stableID(index: index, videoID: videoID)
        self.index = index
        self.videoID = videoID
        self.canonicalURL = canonicalURL
        self.title = title
        self.creator = creator
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.estimatedBytes = estimatedBytes
        self.availability = availability
    }

    private static func stableID(index: Int, videoID: String?) -> String {
        "\(max(1, index)):\(videoID ?? "unavailable")"
    }
}

struct PlaylistAnalysis: Codable, Equatable, Sendable {
    let canonicalURL: URL
    let playlistID: String
    let kind: PlaylistKind
    let referencedVideoID: String?
    let title: String
    let creator: String?
    let thumbnailURL: URL?
    let reportedItemCount: Int?
    let estimatedTotalBytes: Int64?
    let entries: [PlaylistEntry]
    let isTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case canonicalURL = "canonical_url"
        case playlistID = "playlist_id"
        case kind
        case referencedVideoID = "referenced_video_id"
        case title
        case creator
        case thumbnailURL = "thumbnail_url"
        case reportedItemCount = "reported_item_count"
        case estimatedTotalBytes = "estimated_total_bytes"
        case entries
        case isTruncated = "is_truncated"
    }

    var availableItemCount: Int {
        entries.count { $0.availability.isDownloadable }
    }

    var unavailableItemCount: Int {
        entries.count - availableItemCount
    }
}

enum PlaylistSelectionMode: String, Codable, CaseIterable, Sendable {
    case referencedVideo
    case all
    case selected
    case range
    case first
    case last

    var label: String {
        switch self {
        case .referencedVideo: "Referenced video only"
        case .all: "Entire playlist"
        case .selected: "Selected items"
        case .range: "Item range"
        case .first: "First items"
        case .last: "Last items"
        }
    }
}

struct PlaylistSelection: Codable, Equatable, Sendable {
    var mode: PlaylistSelectionMode
    var selectedEntryIDs: [String]
    var rangeStart: Int?
    var rangeEnd: Int?
    var count: Int?

    static let referencedVideo = Self(
        mode: .referencedVideo,
        selectedEntryIDs: [],
        rangeStart: nil,
        rangeEnd: nil,
        count: nil
    )

    static let entirePlaylist = Self(
        mode: .all,
        selectedEntryIDs: [],
        rangeStart: nil,
        rangeEnd: nil,
        count: nil
    )

    func resolvedEntries(
        in analysis: PlaylistAnalysis,
        maximumItems: Int
    ) throws -> [PlaylistEntry] {
        guard maximumItems > 0 else {
            throw PlaylistModelError.invalidItemLimit
        }
        if analysis.isTruncated,
           mode == .all || mode == .last {
            throw PlaylistModelError.analysisTruncated
        }
        let available = analysis.entries.filter {
            $0.availability.isDownloadable
        }
        let result: [PlaylistEntry]
        switch mode {
        case .referencedVideo:
            guard let referencedVideoID = analysis.referencedVideoID else {
                throw PlaylistModelError.noReferencedVideo
            }
            guard let entry = available.first(where: {
                $0.videoID == referencedVideoID
            }) else {
                throw PlaylistModelError.referencedVideoUnavailable
            }
            result = [entry]
        case .all:
            result = available
        case .selected:
            let requested = Set(selectedEntryIDs)
            guard !requested.isEmpty else {
                throw PlaylistModelError.emptySelection
            }
            let matching = analysis.entries.filter {
                requested.contains($0.id)
            }
            guard matching.count == requested.count else {
                throw PlaylistModelError.unknownSelection
            }
            guard matching.allSatisfy({
                $0.availability.isDownloadable
            }) else {
                throw PlaylistModelError.selectedItemUnavailable
            }
            result = matching
        case .range:
            guard let rangeStart, let rangeEnd,
                  rangeStart > 0, rangeEnd >= rangeStart
            else {
                throw PlaylistModelError.invalidRange
            }
            result = available.filter {
                (rangeStart ... rangeEnd).contains($0.index)
            }
        case .first:
            guard let count, count > 0 else {
                throw PlaylistModelError.invalidCount
            }
            result = Array(available.prefix(count))
        case .last:
            guard let count, count > 0 else {
                throw PlaylistModelError.invalidCount
            }
            result = Array(available.suffix(count))
        }
        guard !result.isEmpty else {
            throw PlaylistModelError.emptySelection
        }
        guard result.count <= maximumItems else {
            throw PlaylistModelError.itemLimitExceeded(
                selected: result.count,
                maximum: maximumItems
            )
        }
        return result
    }
}

enum BatchDestinationStructure: String, Codable, CaseIterable, Identifiable,
    Sendable {
    case selectedFolder
    case playlistSubfolder
    case packageFolder
    case zipArchive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .selectedFolder: "Selected folder"
        case .playlistSubfolder: "Playlist subfolder"
        case .packageFolder: "Package folder"
        case .zipArchive: "Final ZIP"
        }
    }

    var needsBatchDirectory: Bool {
        self != .selectedFolder
    }
}

enum DownloadBatchState: String, Codable, CaseIterable, Sendable {
    case preparing
    case queued
    case running
    case paused
    case needsAttention
    case failed
    case cancelled
    case completed
    case completedWithFailures

    var isTerminal: Bool {
        switch self {
        case .failed, .cancelled, .completed, .completedWithFailures:
            true
        case .preparing, .queued, .running, .paused, .needsAttention:
            false
        }
    }
}

enum DownloadBatchItemState: String, Codable, CaseIterable, Sendable {
    case pendingAnalysis
    case analyzing
    case queued
    case running
    case paused
    case needsAttention
    case archivedSkipped
    case skipped
    case unavailable
    case failed
    case cancelled
    case completed

    var isTerminal: Bool {
        switch self {
        case .archivedSkipped, .skipped, .unavailable, .failed, .cancelled,
             .completed:
            true
        case .pendingAnalysis, .analyzing, .queued, .running, .paused,
             .needsAttention:
            false
        }
    }
}

struct DownloadBatchItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let playlistIndex: Int
    let videoID: String?
    let sourceURL: URL?
    var title: String
    var thumbnailURL: URL?
    var estimatedBytes: Int64? = nil
    var jobID: UUID?
    var state: DownloadBatchItemState
    var isDismissedFromQueue: Bool? = nil
    var errorCode: String?
    var errorMessage: String?

    init(entry: PlaylistEntry) {
        id = entry.id
        playlistIndex = entry.index
        videoID = entry.videoID
        sourceURL = entry.canonicalURL
        title = entry.title
        thumbnailURL = entry.thumbnailURL
        estimatedBytes = entry.estimatedBytes
        jobID = nil
        state = entry.availability.isDownloadable
            ? .pendingAnalysis
            : .unavailable
        isDismissedFromQueue = nil
        errorCode = nil
        errorMessage = nil
    }
}

struct DownloadBatchProgress: Codable, Equatable, Sendable {
    var totalItems: Int
    var completedItems: Int
    var failedItems: Int
    var skippedItems: Int
    var activeItems: Int
    var bytesDownloaded: Int64
    var totalBytes: Int64?
    var overallFraction: Double?

    static func zero(totalItems: Int) -> Self {
        Self(
            totalItems: totalItems,
            completedItems: 0,
            failedItems: 0,
            skippedItems: 0,
            activeItems: 0,
            bytesDownloaded: 0,
            totalBytes: nil,
            overallFraction: totalItems == 0 ? 1 : 0
        )
    }
}

struct DownloadBatch: Codable, Equatable, Identifiable, Sendable {
    var admissionPaused: Bool? = nil
    var stoppedRetryRequests: [String: UUID]? = nil
    let id: UUID
    let sourceURL: URL
    let playlistID: String
    let kind: PlaylistKind
    var title: String
    var creator: String?
    var thumbnailURL: URL?
    let createdAt: Date
    var updatedAt: Date
    var selection: PlaylistSelection
    var configuration: DownloadConfiguration
    var itemOverrides: [String: DownloadConfiguration]
    var destinationStructure: BatchDestinationStructure
    var continueOnError: Bool
    var skipArchivedItems: Bool
    var numberFilenames: Bool
    var filenameIndexWidth: Int
    var items: [DownloadBatchItem]
    var state: DownloadBatchState
    var progress: DownloadBatchProgress
    var packageURL: URL?
    var packageErrorMessage: String? = nil
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        analysis: PlaylistAnalysis,
        selection: PlaylistSelection,
        configuration: DownloadConfiguration,
        itemOverrides: [String: DownloadConfiguration] = [:],
        destinationStructure: BatchDestinationStructure,
        continueOnError: Bool,
        skipArchivedItems: Bool,
        numberFilenames: Bool,
        filenameIndexWidth: Int,
        entries: [PlaylistEntry],
        createdAt: Date = .now
    ) {
        self.id = id
        sourceURL = analysis.canonicalURL
        playlistID = analysis.playlistID
        kind = analysis.kind
        title = analysis.title
        creator = analysis.creator
        thumbnailURL = analysis.thumbnailURL
        self.createdAt = createdAt
        updatedAt = createdAt
        self.selection = selection
        self.configuration = configuration
        self.itemOverrides = itemOverrides
        self.destinationStructure = destinationStructure
        self.continueOnError = continueOnError
        self.skipArchivedItems = skipArchivedItems
        self.numberFilenames = numberFilenames
        self.filenameIndexWidth = min(max(filenameIndexWidth, 1), 8)
        items = entries.map(DownloadBatchItem.init)
        state = .preparing
        progress = .zero(totalItems: entries.count)
        packageURL = nil
        packageErrorMessage = nil
        errorMessage = nil
    }
}

struct BatchJobMembership: Codable, Equatable, Sendable {
    let batchID: UUID
    let playlistID: String
    let entryID: String
    let playlistTitle: String
    let playlistIndex: Int
    let playlistItemCount: Int
    let filenameIndexWidth: Int
    let relativeOutputDirectory: String?

    var formattedPlaylistIndex: String {
        String(
            format: "%0\(min(max(filenameIndexWidth, 1), 8))d",
            playlistIndex
        )
    }
}

struct DownloadArchiveEntry: Codable, Equatable, Hashable, Identifiable,
    Sendable {
    let site: String
    let videoID: String
    let completedAt: Date
    let historyRecordID: UUID?
    let batchID: UUID?

    var id: String {
        "\(site.lowercased()):\(videoID)"
    }

    static func youtube(
        videoID: String,
        completedAt: Date = .now,
        historyRecordID: UUID? = nil,
        batchID: UUID? = nil
    ) -> Self {
        Self(
            site: "youtube",
            videoID: videoID,
            completedAt: completedAt,
            historyRecordID: historyRecordID,
            batchID: batchID
        )
    }
}

enum PlaylistModelError: LocalizedError, Equatable, Sendable {
    case noReferencedVideo
    case referencedVideoUnavailable
    case emptySelection
    case unknownSelection
    case selectedItemUnavailable
    case invalidRange
    case invalidCount
    case invalidItemLimit
    case analysisTruncated
    case itemLimitExceeded(selected: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .noReferencedVideo:
            "This link does not reference one specific playlist item."
        case .referencedVideoUnavailable:
            "The referenced video is unavailable in this playlist."
        case .emptySelection:
            "Select at least one available playlist item."
        case .unknownSelection:
            "The selected playlist items no longer match this analysis."
        case .selectedItemUnavailable:
            "One or more selected playlist items are unavailable."
        case .invalidRange:
            "Enter a valid inclusive playlist range."
        case .invalidCount:
            "Enter a positive playlist item count."
        case .invalidItemLimit:
            "The playlist item limit must be positive."
        case .analysisTruncated:
            "Increase the item limit or choose explicit loaded items before continuing."
        case let .itemLimitExceeded(selected, maximum):
            "The selection contains \(selected) items; the current limit is \(maximum)."
        }
    }
}
