import Foundation

typealias PlaylistItemMetadataLoader =
    @Sendable (URL) async throws -> MediaMetadata

typealias PlaylistChildJobEnqueuer =
    @Sendable (
        MediaMetadata,
        DownloadConfiguration,
        String?,
        BatchJobMembership
    ) async throws -> DownloadJob

enum PlaylistChildJobFactoryError: LocalizedError, Equatable, Sendable {
    case unavailableEntry
    case missingSourceURL
    case entryNotInBatch
    case identityMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unavailableEntry:
            "This playlist item is unavailable."
        case .missingSourceURL:
            "This playlist item has no safe media URL."
        case .entryNotInBatch:
            "This playlist item does not belong to the batch."
        case let .identityMismatch(expected, actual):
            "The analyzed video ID \(actual) did not match \(expected)."
        }
    }
}

actor PlaylistChildJobFactory {
    private let loadMetadata: @Sendable (URL, UUID?) async throws -> MediaMetadata
    private let enqueue: PlaylistChildJobEnqueuer

    init(
        loadMetadata: @escaping PlaylistItemMetadataLoader,
        enqueue: @escaping PlaylistChildJobEnqueuer
    ) {
        self.loadMetadata = { url, accountID in
            guard accountID == nil else { throw AccountError.unavailable }
            return try await loadMetadata(url)
        }
        self.enqueue = enqueue
    }

    init(loadAccountMetadata: @escaping @Sendable (URL, UUID?) async throws -> MediaMetadata,
         enqueue: @escaping PlaylistChildJobEnqueuer) {
        self.loadMetadata = loadAccountMetadata
        self.enqueue = enqueue
    }

    func enqueueChild(
        entry: PlaylistEntry,
        in batch: DownloadBatch,
        extractorVersion: String?
    ) async throws -> DownloadJob {
        guard entry.availability.isDownloadable else {
            throw PlaylistChildJobFactoryError.unavailableEntry
        }
        guard batch.items.contains(where: { $0.id == entry.id }) else {
            throw PlaylistChildJobFactoryError.entryNotInBatch
        }
        guard let sourceURL = entry.canonicalURL,
              let expectedVideoID = entry.videoID
        else {
            throw PlaylistChildJobFactoryError.missingSourceURL
        }

        try Task.checkCancellation()
        let accountID = batch.configuration.accountID
        let metadata = try await loadMetadata(sourceURL, accountID)
        try Task.checkCancellation()
        guard metadata.videoID == expectedVideoID else {
            throw PlaylistChildJobFactoryError.identityMismatch(
                expected: expectedVideoID,
                actual: metadata.videoID
            )
        }

        let membership = Self.membership(for: entry, in: batch)
        var configuration =
            batch.itemOverrides[entry.id] ?? batch.configuration
        configuration.accountID = accountID
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = nil
        configuration.playlistBehavior = .referencedVideo
        configuration.filenameTemplate = Self.specializedFilenameTemplate(
            configuration.filenameTemplate,
            membership: membership,
            numberFilename: batch.numberFilenames
        )
        return try await enqueue(
            metadata,
            configuration,
            extractorVersion,
            membership
        )
    }

    static func membership(
        for entry: PlaylistEntry,
        in batch: DownloadBatch
    ) -> BatchJobMembership {
        BatchJobMembership(
            batchID: batch.id,
            playlistID: batch.playlistID,
            entryID: entry.id,
            playlistTitle: batch.title,
            playlistIndex: entry.index,
            playlistItemCount: batch.items.count,
            filenameIndexWidth: batch.filenameIndexWidth,
            relativeOutputDirectory: relativeOutputDirectory(for: batch)
        )
    }

    static func specializedFilenameTemplate(
        _ template: String,
        membership: BatchJobMembership,
        numberFilename: Bool
    ) -> String {
        let hadIndexField = template.contains("{playlist_index}")
        var result = template
            .replacingOccurrences(
                of: "{playlist}",
                with: FilenameSystem.sanitizeComponent(
                    membership.playlistTitle
                )
            )
            .replacingOccurrences(
                of: "{playlist_index}",
                with: membership.formattedPlaylistIndex
            )
        if numberFilename && !hadIndexField {
            result = "\(membership.formattedPlaylistIndex) \(result)"
        }
        return result
    }

    private static func relativeOutputDirectory(
        for batch: DownloadBatch
    ) -> String? {
        guard batch.destinationStructure.needsBatchDirectory else {
            return nil
        }
        let title = FilenameSystem.sanitizeComponent(batch.title)
        let fallback = FilenameSystem.sanitizeComponent(
            "Playlist \(batch.playlistID)"
        )
        let base = title.isEmpty ? fallback : title
        switch batch.destinationStructure {
        case .selectedFolder:
            return nil
        case .playlistSubfolder:
            return base
        case .packageFolder, .zipArchive:
            return FilenameSystem.sanitizeComponent("\(base) Package")
        }
    }
}
