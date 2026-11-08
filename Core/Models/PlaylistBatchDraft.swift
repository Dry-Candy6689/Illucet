import Foundation

enum PlaylistBatchFlowStep: String, Equatable, Sendable {
    case selection
    case options
    case review
}

struct PlaylistBatchDraft: Equatable, Sendable {
    let analysis: PlaylistAnalysis
    var selection: PlaylistSelection
    var configuration: DownloadConfiguration
    var itemOverrides: [String: DownloadConfiguration]
    var destinationStructure: BatchDestinationStructure
    var skipArchivedItems: Bool
    var step: PlaylistBatchFlowStep

    init(
        analysis: PlaylistAnalysis,
        configuration: DownloadConfiguration
    ) {
        self.analysis = analysis
        if analysis.referencedVideoID != nil {
            selection = .referencedVideo
        } else if analysis.isTruncated {
            selection = PlaylistSelection(
                mode: .selected,
                selectedEntryIDs: analysis.entries
                    .filter(\.availability.isDownloadable)
                    .map(\.id),
                rangeStart: nil,
                rangeEnd: nil,
                count: nil
            )
        } else {
            selection = .entirePlaylist
        }
        var normalized = OutputCapabilityMatrix.normalized(configuration)
        normalized.selectedVideoFormatID = nil
        normalized.selectedAudioFormatID = nil
        normalized.playlistBehavior = analysis.referencedVideoID == nil
            ? .entirePlaylist
            : .referencedVideo
        self.configuration = normalized
        itemOverrides = [:]
        destinationStructure = .playlistSubfolder
        skipArchivedItems = true
        step = .selection
    }

    var availableEntries: [PlaylistEntry] {
        analysis.entries.filter(\.availability.isDownloadable)
    }

    var selectedEntries: [PlaylistEntry] {
        (try? resolvedEntries()) ?? []
    }

    var estimatedSelectedBytes: Int64? {
        let selected = selectedEntries
        guard !selected.isEmpty,
              selected.allSatisfy({ $0.estimatedBytes.map { $0 >= 0 } == true })
        else {
            return nil
        }
        return selected.reduce(into: Int64(0)) {
            $0 = StorageByteArithmetic.adding($0, $1.estimatedBytes ?? 0)
        }
    }

    func resolvedEntries() throws -> [PlaylistEntry] {
        try selection.resolvedEntries(
            in: analysis,
            maximumItems: configuration.maximumPlaylistItems
        )
    }

    mutating func selectAllLoadedEntries() {
        selection.mode = .selected
        selection.selectedEntryIDs = availableEntries.map(\.id)
    }

    mutating func selectSelectionMode(_ mode: PlaylistSelectionMode) {
        selection.mode = mode
        switch mode {
        case .range:
            selection.rangeStart = selection.rangeStart ?? 1
            selection.rangeEnd = selection.rangeEnd
                ?? min(
                    max(1, analysis.entries.map(\.index).max() ?? 1),
                    5
                )
        case .first, .last:
            selection.count = selection.count
                ?? min(max(1, availableEntries.count), 5)
        case .referencedVideo, .all, .selected:
            break
        }
    }

    mutating func clearSelectedEntries() {
        selection.mode = .selected
        selection.selectedEntryIDs = []
    }

    mutating func toggle(entryID: String) {
        var selected = Set(selection.selectedEntryIDs)
        if selected.contains(entryID) {
            selected.remove(entryID)
        } else {
            selected.insert(entryID)
        }
        selection.mode = .selected
        selection.selectedEntryIDs = analysis.entries
            .filter { selected.contains($0.id) }
            .map(\.id)
    }

    mutating func applyPreset(_ preset: DownloadPreset) {
        configuration.preset = preset
        switch preset {
        case .best:
            configuration.mode = .videoAndAudio
            configuration.maximumResolution = nil
            configuration.preserveSourceResolution = true
            configuration.videoCodec = .automatic
            configuration.audioCodec = .automatic
            configuration.container = .automatic
        case .compatible:
            configuration.mode = .videoAndAudio
            configuration.maximumResolution = nil
            configuration.preserveSourceResolution = true
            configuration.videoCodec = .h264
            configuration.audioCodec = .automatic
            configuration.container = .mp4
        case .small:
            configuration.mode = .videoAndAudio
            configuration.maximumResolution = 720
            configuration.preserveSourceResolution = false
            configuration.videoCodec = .automatic
            configuration.audioCodec = .automatic
            configuration.container = .automatic
        case .audio:
            configuration.mode = .audioOnly
            configuration.audioCodec = .mp3
            configuration.container = .mp3
            configuration.audioBitrateKbps = 192
        case .custom:
            break
        }
        normalizeConfiguration()
    }

    mutating func selectMode(_ mode: DownloadMode) {
        configuration.mode = mode
        configuration.preset = .custom
        if mode == .audioOnly {
            configuration.videoCodec = .automatic
            configuration.audioCodec = configuration.audioCodec == .mp3
                ? .mp3
                : .original
            configuration.container = configuration.audioCodec == .mp3
                ? .mp3
                : .automatic
        } else {
            configuration.audioCodec = mode == .videoOnly
                ? .automatic
                : configuration.audioCodec
            if configuration.container == .mp3 {
                configuration.container = .automatic
            }
        }
        normalizeConfiguration()
    }

    mutating func setOverrideMode(
        _ mode: DownloadMode?,
        for entryID: String
    ) {
        guard let mode else {
            itemOverrides[entryID] = nil
            return
        }
        var override = configuration
        override.mode = mode
        override.preset = .custom
        override.selectedVideoFormatID = nil
        override.selectedAudioFormatID = nil
        if mode == .audioOnly {
            override.videoCodec = .automatic
            override.audioCodec = .original
            override.container = .automatic
        } else if mode == .videoOnly {
            override.audioCodec = .automatic
            if override.container == .mp3 {
                override.container = .automatic
            }
        } else if override.container == .mp3 {
            override.container = .automatic
            override.audioCodec = .automatic
        }
        itemOverrides[entryID] = OutputCapabilityMatrix.normalized(
            override
        )
    }

    func overrideMode(for entryID: String) -> DownloadMode? {
        itemOverrides[entryID]?.mode
    }

    mutating func normalizeConfiguration() {
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = nil
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let overrideModes = itemOverrides.mapValues(\.mode)
        itemOverrides.removeAll(keepingCapacity: true)
        for (entryID, mode) in overrideModes {
            setOverrideMode(mode, for: entryID)
        }
    }
}

enum PlaylistBatchDraftError: LocalizedError, Equatable, Sendable {
    case filesFolderRequired
    case unsupportedBatchDestination
    case zipDuplicateDecisionRequired

    var errorDescription: String? {
        switch self {
        case .filesFolderRequired:
            "Select a Files folder before starting this playlist."
        case .unsupportedBatchDestination:
            "This batch structure is not compatible with the selected destination."
        case .zipDuplicateDecisionRequired:
            "Choose a fixed duplicate rule before creating a ZIP batch."
        }
    }
}
