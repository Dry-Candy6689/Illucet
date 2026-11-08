import Foundation

/// A URL-free presentation index. Exact transport-bearing tracks stay in metadata.
struct SubtitlePickerCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        let selection: SubtitleTrackSelection
        let title: String
        let detail: String
        let searchText: String
        var id: String { selection.trackID + ":" + selection.formatID }
    }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", manual = "Manual", automatic = "Automatic"
        var id: String { rawValue }
    }
    let entries: [Entry]

    init(tracks: [MediaSubtitleTrack], locale: Locale = .current) {
        entries = tracks.flatMap { track in
            let languageName = locale.localizedString(forLanguageCode: track.language) ?? track.language
            return track.formats.filter(SubtitleSelectionPlanner.isSelectableWebVTT).map { format in
                let title = track.name ?? languageName
                let detail = [track.language, track.automatic ? "Automatic" : "Manual", format.name ?? "WebVTT"].joined(separator: " • ")
                return Entry(selection: SubtitleTrackSelection(trackID: track.trackID,
                    formatID: format.formatID, language: track.language, automatic: track.automatic),
                    title: title, detail: detail,
                    searchText: [languageName, title, detail].joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale))
            }
        }
    }

    func matching(_ query: String, filter: Filter, excluding selections: Set<SubtitleTrackSelection>,
                  locale: Locale = .current) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return entries.filter {
            !selections.contains($0.selection)
                && (filter == .all || $0.selection.automatic == (filter == .automatic))
                && (query.isEmpty || $0.searchText.contains(query))
        }
    }
}
