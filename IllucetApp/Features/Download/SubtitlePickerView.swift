import SwiftUI

struct SubtitlePickerView: View {
    @Environment(\.illucetPalette) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var selections: [SubtitleTrackSelection]
    @State private var catalog = SubtitlePickerCatalog(tracks: [])
    @State private var loaded = false
    private let tracks: [MediaSubtitleTrack]
    @State private var query = ""
    @State private var filter: SubtitlePickerCatalog.Filter = .all
    let maximumSelections: Int

    init(tracks: [MediaSubtitleTrack], selections: Binding<[SubtitleTrackSelection]>, maximumSelections: Int) {
        _selections = selections
        self.tracks = tracks
        self.maximumSelections = maximumSelections
    }

    var body: some View {
        let selected = Set(selections)
        let matches = catalog.matching(query, filter: filter, excluding: selected)
        NavigationStack {
            List {
                Section {
                    Picker("Subtitle type", selection: $filter) {
                        ForEach(SubtitlePickerCatalog.Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("\(selected.count) selected · Up to \(maximumSelections)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !selected.isEmpty {
                    Section("Selected") {
                        ForEach(catalog.entries.filter { selected.contains($0.selection) }) { row($0, selected: true) }
                        Button("Clear selection") { selections.removeAll() }
                    }
                }
                Section("\(matches.count) available") {
                    ForEach(matches) { row($0, selected: false) }
                    if !loaded { ProgressView("Loading languages…") }
                    else if matches.isEmpty {
                        Text("No matching subtitles").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Language, code, or track name")
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            guard !loaded else { return }
            let source = tracks
            let result = await Task.detached(priority: .userInitiated) {
                SubtitlePickerCatalog(tracks: source)
            }.value
            guard !Task.isCancelled else { return }
            catalog = result
            loaded = true
        }
        .accessibilityIdentifier("subtitles.picker")
    }

    private func row(_ entry: SubtitlePickerCatalog.Entry, selected: Bool) -> some View {
        Button {
            if selected { selections.removeAll { $0 == entry.selection } }
            else if selections.count < maximumSelections { selections.append(entry.selection) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).foregroundStyle(.primary)
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? theme.foregroundAccent : .secondary)
            }
            .contentShape(Rectangle())
        }
        .disabled(!selected && selections.count >= maximumSelections)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("configuration.subtitle.\(entry.selection.trackID).\(entry.selection.formatID)")
    }
}
