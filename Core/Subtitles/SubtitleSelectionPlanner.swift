import Foundation

enum SubtitleSelectionPlanner {
    static let maximumSelections = 32

    static func defaultEnglishSelection(in tracks: [MediaSubtitleTrack]) -> SubtitleTrackSelection? {
        let candidates = tracks.filter {
            let language = $0.language.lowercased().replacingOccurrences(of: "_", with: "-")
            return (language == "en" || language.hasPrefix("en-"))
                && $0.formats.contains(where: isSelectableWebVTT)
        }.sorted {
            if $0.automatic != $1.automatic { return !$0.automatic }
            let lhs = $0.language.lowercased() == "en", rhs = $1.language.lowercased() == "en"
            if lhs != rhs { return lhs }
            return $0.trackID < $1.trackID
        }
        guard let track = candidates.first,
              let format = track.formats.first(where: isSelectableWebVTT) else { return nil }
        return SubtitleTrackSelection(trackID: track.trackID, formatID: format.formatID,
            language: track.language, automatic: track.automatic)
    }

    static func plans(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws -> [SubtitleDownloadPlan] {
        guard configuration.subtitleDelivery != .none else { return [] }
        guard let kind = SubtitleSidecarKind(
            delivery: configuration.subtitleDelivery
        ) else {
            throw SubtitlePipelineError.unsupportedDelivery
        }
        let isSidecar = [
            SubtitleDelivery.sidecarVTT,
            .sidecarSRT,
        ].contains(configuration.subtitleDelivery)
        guard !isSidecar || configuration.destination != .photos else {
            throw SubtitlePipelineError.photosOnlyDestination
        }
        let selections = configuration.subtitleSelections ?? []
        guard !selections.isEmpty, selections.count <= maximumSelections else {
            throw SubtitlePipelineError.missingSelection
        }
        guard Set(selections).count == selections.count else {
            throw SubtitlePipelineError.invalidSelection
        }
        return try selections.map {
            try plan(
                selection: $0,
                kind: kind,
                metadata: metadata
            )
        }
    }

    static func refreshedPlan(
        selection: SubtitleTrackSelection,
        kind: SubtitleSidecarKind,
        metadata: MediaMetadata,
        expectedVideoID: String
    ) throws -> SubtitleDownloadPlan {
        guard metadata.videoID == expectedVideoID else {
            throw SubtitlePipelineError.trackUnavailable
        }
        return try plan(
            selection: selection,
            kind: kind,
            metadata: metadata
        )
    }

    static func isSelectableWebVTT(
        _ format: MediaSubtitleFormat
    ) -> Bool {
        format.extension?.lowercased() == "vtt"
    }

    static func isValidSelection(
        _ selection: SubtitleTrackSelection
    ) -> Bool {
        isIdentity(selection.trackID, prefix: "subtitle-")
            && isIdentity(
                selection.formatID,
                prefix: "subtitle-format-"
            )
            && isLanguage(selection.language)
    }

    private static func plan(
        selection: SubtitleTrackSelection,
        kind: SubtitleSidecarKind,
        metadata: MediaMetadata
    ) throws -> SubtitleDownloadPlan {
        guard isValidSelection(selection) else {
            throw SubtitlePipelineError.invalidSelection
        }
        guard let track = metadata.subtitles.first(where: {
            $0.trackID == selection.trackID
        }) else {
            throw SubtitlePipelineError.trackUnavailable
        }
        guard
            track.language == selection.language,
            track.automatic == selection.automatic
        else {
            throw SubtitlePipelineError.trackUnavailable
        }
        guard let format = track.formats.first(where: {
            $0.formatID == selection.formatID
        }), isSelectableWebVTT(format) else {
            throw SubtitlePipelineError.formatUnavailable
        }
        return SubtitleDownloadPlan(
            selection: selection,
            kind: kind,
            transportURL: format.url
        )
    }

    private static func isIdentity(
        _ value: String,
        prefix: String
    ) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.utf8.count == 24 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isLanguage(_ value: String) -> Bool {
        let normalized = value.precomposedStringWithCanonicalMapping
        return !normalized.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && normalized.utf8.count <= 128
    }
}
