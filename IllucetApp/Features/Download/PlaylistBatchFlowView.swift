import SwiftUI

struct PlaylistBatchFlowView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel

    @State private var collectionFilter = CollectionFilter()

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                if let draft = model.playlistDraft {
                    switch draft.step {
                    case .selection:
                        playlistSelection(draft)
                    case .options:
                        batchOptions(draft)
                    case .review:
                        batchReview(draft)
                    }
                } else {
                    ContentUnavailableView(
                        "Playlist unavailable",
                        systemImage: "rectangle.stack.badge.xmark",
                        description: Text(
                            "Analyze the playlist again to rebuild this selection."
                        )
                    )
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelPlaylistBatchFlow()
                    }
                    .accessibilityIdentifier("playlist.cancel")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .filesFolderImporter(model: model, source: .playlist)
        .appAlertPresenter(model: model)
        .accessibilityIdentifier("playlist.sheet")
    }

    private var navigationTitle: String {
        switch model.playlistDraft?.step {
        case .selection: "Choose playlist items"
        case .options: "Batch options"
        case .review: "Review batch"
        case nil: "Playlist"
        }
    }

    private func playlistSelection(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                playlistHeader(draft)
                selectionControls(draft)
                collectionFilters(draft)
                entryInventory(draft)
                Button {
                    model.continuePlaylistSelection()
                } label: {
                    Label(
                        "Continue with \(draft.selectedEntries.count) item\(draft.selectedEntries.count == 1 ? "" : "s")",
                        systemImage: "arrow.right.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(draft.selectedEntries.isEmpty)
                .accessibilityIdentifier("playlist.continue")
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("playlist.step.selection")
    }

    private func playlistHeader(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: draft.analysis.thumbnailURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        theme.raisedCard
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(theme.foregroundAccent)
                    }
                }
            }
            .frame(width: 112, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 5) {
                Text(draft.analysis.title)
                    .font(.headline)
                    .lineLimit(2)
                if let creator = draft.analysis.creator {
                    Text(creator)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    IllucetPill(
                        text: draft.analysis.kind.label,
                        color: IllucetTheme.violet
                    )
                    Text(
                        "\(draft.analysis.availableItemCount) available"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .illucetCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playlist.header")
    }

    private func selectionControls(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "What should be queued?",
                subtitle: "Illucet never expands a playlist without this choice",
                systemImage: "checklist"
            )
            if [.creatorUploads, .creatorShorts, .creatorReplays].contains(draft.analysis.kind) {
                Picker("Creator section", selection: Binding(get: { draft.analysis.kind }, set: { kind in
                    let tab = kind == .creatorShorts ? "shorts" : kind == .creatorReplays ? "streams" : "videos"
                    model.URLText = draft.analysis.canonicalURL.deletingLastPathComponent().appendingPathComponent(tab).absoluteString
                    model.reloadPlaylistInventory()
                })) {
                    Text("Uploads").tag(PlaylistKind.creatorUploads)
                    Text("Shorts").tag(PlaylistKind.creatorShorts)
                    Text("Completed streams").tag(PlaylistKind.creatorReplays)
                }.disabled(model.isAnalyzing)
            }
            Picker(
                "Selection",
                selection: Binding(
                    get: { draft.selection.mode },
                    set: { mode in
                        updateDraft {
                            $0.selectSelectionMode(mode)
                        }
                    }
                )
            ) {
                ForEach(availableModes(for: draft), id: \.rawValue) {
                    mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("playlist.selection.mode")

            switch draft.selection.mode {
            case .selected:
                HStack {
                    Button("Select all loaded") {
                        updateDraft { $0.selectAllLoadedEntries() }
                    }
                    Spacer()
                    Button("Clear") {
                        updateDraft { $0.clearSelectedEntries() }
                    }
                }
                .font(.subheadline.weight(.semibold))
            case .range:
                HStack(spacing: 14) {
                    boundedStepper(
                        "From",
                        keyPath: \.selection.rangeStart,
                        defaultValue: 1,
                        limit: maxPlaylistIndex(in: draft)
                    )
                    boundedStepper(
                        "Through",
                        keyPath: \.selection.rangeEnd,
                        defaultValue: min(
                            5,
                            maxPlaylistIndex(in: draft)
                        ),
                        limit: maxPlaylistIndex(in: draft)
                    )
                }
            case .first, .last:
                boundedStepper(
                    "Item count",
                    keyPath: \.selection.count,
                    defaultValue: min(
                        5,
                        draft.analysis.availableItemCount
                    ),
                    limit: draft.configuration.maximumPlaylistItems
                )
            case .referencedVideo, .all:
                EmptyView()
            }

            Stepper(
                value: draftBinding(
                    \.configuration.maximumPlaylistItems,
                    fallback: 25
                ),
                in: 1 ... YTDLPPlaylistAnalyzer.maximumEntries
            ) {
                HStack {
                    Text("Maximum items")
                    Spacer()
                    Text(
                        "\(draft.configuration.maximumPlaylistItems)"
                    )
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("playlist.maximumItems")

            if draft.analysis.isTruncated {
                Label(
                    "Only the first \(draft.analysis.entries.count) entries were loaded. Increase the limit and reload, or choose explicit loaded items.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
                Button {
                    model.reloadPlaylistInventory()
                } label: {
                    if model.isAnalyzing {
                        ProgressView()
                    } else {
                        Label(
                            "Reload playlist inventory",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isAnalyzing)
                .accessibilityIdentifier("playlist.reload")
            }
        }
        .illucetCard()
    }

    private func collectionFilters(_ draft: PlaylistBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search title, creator, or ID", text: $collectionFilter.query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("collection.search")
            DisclosureGroup("Filter loaded items") {
                TextField("Minimum duration (seconds)", value: $collectionFilter.minimumSeconds, format: .number).keyboardType(.decimalPad)
                TextField("Maximum duration (seconds)", value: $collectionFilter.maximumSeconds, format: .number).keyboardType(.decimalPad)
                TextField("Uploaded after (YYYY-MM-DD)", text: $collectionFilter.uploadedAfter)
                TextField("Uploaded before (YYYY-MM-DD)", text: $collectionFilter.uploadedBefore)
                TextField("Minimum height (pixels)", value: $collectionFilter.minimumHeight, format: .number).keyboardType(.numberPad)
                TextField("Maximum estimated bytes", value: $collectionFilter.maximumBytes, format: .number).keyboardType(.numberPad)
                Picker("Shorts", selection: $collectionFilter.shorts) {
                    ForEach(CollectionFilter.Requirement.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Live / upcoming", selection: $collectionFilter.live) {
                    ForEach(CollectionFilter.Requirement.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Filters apply to loaded metadata only. Items with unknown values are excluded by that filter. Hidden items remain selected until you replace the selection below.").font(.caption).foregroundStyle(.secondary)
                if let message = collectionFilter.validationMessage { Text(message).foregroundStyle(.orange) }
                Button("Reset filters") { collectionFilter = CollectionFilter() }
                Button("Load detailed metadata for filters") { model.reloadPlaylistInventory(detailed: true) }.disabled(model.isAnalyzing)
                Text("Detailed analysis makes additional requests for up to the chosen item limit. Review your selection again when it finishes.").font(.caption).foregroundStyle(.secondary)
            }
            let matches = draft.availableEntries.filter(collectionFilter.matches)
            Button("Select these \(matches.count) matching items") {
                updateDraft {
                    $0.selection.mode = .selected
                    $0.selection.selectedEntryIDs = matches.map(\.id)
                }
            }.accessibilityIdentifier("collection.selectMatches")
        }.illucetCard()
    }

    private func entryInventory(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Playlist items",
                subtitle:
                    "\(draft.analysis.availableItemCount) available • \(draft.analysis.unavailableItemCount) unavailable",
                systemImage: "list.number"
            )
            ForEach(draft.analysis.entries.filter(collectionFilter.matches)) { entry in
                let included = draft.selectedEntries.contains {
                    $0.id == entry.id
                }
                Button {
                    guard entry.availability.isDownloadable else {
                        return
                    }
                    updateDraft { $0.toggle(entryID: entry.id) }
                } label: {
                    PlaylistEntryLabel(
                        entry: entry,
                        included: included,
                        selectable: entry.availability.isDownloadable
                    )
                }
                .buttonStyle(.plain)
                .disabled(!entry.availability.isDownloadable)
                .accessibilityIdentifier(
                    "playlist.entry.\(entry.id)"
                )
                if entry.id != draft.analysis.entries.last?.id {
                    Divider().opacity(0.45)
                }
            }
        }
        .illucetCard()
    }

    private func batchOptions(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                compactBatchHeader(draft)
                outputOptions(draft)
                destinationOptions(draft)
                batchBehaviorOptions(draft)
                perItemOverrides(draft)
                HStack(spacing: 12) {
                    Button {
                        model.returnToPlaylistStep(.selection)
                    } label: {
                        Label("Items", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.reviewPlaylistBatch()
                    } label: {
                        Label("Review", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityIdentifier("playlist.review")
                }
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("playlist.step.options")
    }

    private func compactBatchHeader(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        HStack {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(theme.foregroundAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.analysis.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(draft.selectedEntries.count) selected items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .illucetCard()
    }

    private func outputOptions(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "Apply to all items",
                subtitle: "Each item is analyzed before its job is created",
                systemImage: "slider.horizontal.3"
            )
            Picker(
                "Preset",
                selection: Binding(
                    get: { draft.configuration.preset },
                    set: { preset in
                        updateDraft { $0.applyPreset(preset) }
                    }
                )
            ) {
                ForEach(DownloadPreset.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                ForEach(DownloadMode.allCases) { mode in
                    Button {
                        updateDraft { $0.selectMode(mode) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: mode.systemImage)
                            brandedText(mode.rawValue)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(
                        IllucetSelectionButtonStyle(
                            isSelected:
                                draft.configuration.mode == mode
                        )
                    )
                    .accessibilityIdentifier(
                        "playlist.mode.\(mode.rawValue)"
                    )
                }
            }

            if draft.configuration.mode != .audioOnly {
                Picker(
                    "Maximum resolution",
                    selection: draftBinding(
                        \.configuration.maximumResolution,
                        fallback: nil
                    )
                ) {
                    Text("Best available").tag(Int?.none)
                    ForEach([360, 480, 720, 1080, 1440, 2160], id: \.self) {
                        Text("\($0)p").tag(Int?.some($0))
                    }
                }
            } else {
                Picker(
                    "Audio output",
                    selection: Binding(
                        get: { draft.configuration.audioCodec },
                        set: { codec in
                            updateDraft {
                                $0.configuration.audioCodec = codec
                                $0.configuration.container =
                                    codec == .mp3 ? .mp3 : .automatic
                                $0.normalizeConfiguration()
                            }
                        }
                    )
                ) {
                    Text("Preserve original").tag(
                        AudioCodecPreference.original
                    )
                    Text("MP3").tag(AudioCodecPreference.mp3)
                }
                if draft.configuration.audioCodec == .mp3 {
                    Picker(
                        "MP3 bitrate",
                        selection: draftBinding(
                            \.configuration.audioBitrateKbps,
                            fallback: 192
                        )
                    ) {
                        ForEach(
                            [64, 96, 128, 160, 192, 256, 320],
                            id: \.self
                        ) {
                            Text("\($0) kbps").tag(Int?.some($0))
                        }
                    }
                }
            }

            Picker(
                "Thumbnail",
                selection: draftBinding(
                    \.configuration.thumbnailBehavior,
                    fallback: .none
                )
            ) {
                ForEach(ThumbnailBehavior.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
        }
        .illucetCard()
    }

    private func destinationOptions(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "Destination & structure",
                systemImage: "folder.badge.plus"
            )
            Picker(
                "Destination",
                selection: draftBinding(
                    \.configuration.destination,
                    fallback: .appDocuments
                )
            ) {
                ForEach(
                    ExportDestination.allCases.filter {
                        $0 != .askEveryTime
                    }
                ) {
                    Label(
                        $0.rawValue,
                        systemImage: $0.systemImage
                    ).tag($0)
                }
            }
            if [
                ExportDestination.filesFolder,
                .filesAndPhotos,
            ].contains(draft.configuration.destination) {
                Button {
                    model.requestFilesFolderPicker(from: .playlist)
                } label: {
                    Label(
                        model.filesFolderName ?? "Select Files folder",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("playlist.filesFolder")
            }
            Picker(
                "Folder layout",
                selection: draftBinding(
                    \.destinationStructure,
                    fallback: .playlistSubfolder
                )
            ) {
                ForEach(BatchDestinationStructure.allCases) {
                    Text($0.label).tag($0)
                }
            }
            if draft.destinationStructure == .zipArchive {
                Label(
                    "The ZIP is created only after every selected item reaches a final state.",
                    systemImage: "archivebox"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            TextField(
                "{playlist_index} {title}",
                text: draftBinding(
                    \.configuration.filenameTemplate,
                    fallback: "{title}"
                )
            )
            .textInputAutocapitalization(.never)
            .padding(11)
            .background(
                theme.input,
                in: RoundedRectangle(cornerRadius: 12)
            )
            Text(
                "Fields include {title}, {video_id}, {playlist}, and {playlist_index}."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .illucetCard()
    }

    private func batchBehaviorOptions(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            IllucetSectionHeader(
                title: "Batch behavior",
                systemImage: "arrow.triangle.branch"
            )
            Toggle(
                "Continue when one item fails",
                isOn: draftBinding(
                    \.configuration.continuePlaylistOnError,
                    fallback: true
                )
            )
            Toggle(
                "Number filenames",
                isOn: draftBinding(
                    \.configuration.numberPlaylistFilenames,
                    fallback: true
                )
            )
            Toggle(
                "Skip items in Playlist Archive",
                isOn: draftBinding(
                    \.skipArchivedItems,
                    fallback: true
                )
            )
        }
        .illucetCard()
    }

    private func perItemOverrides(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Per-item overrides",
                subtitle: "Optional",
                systemImage: "switch.2"
            )
            ForEach(draft.selectedEntries) { entry in
                HStack(spacing: 10) {
                    Text("\(entry.index)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(entry.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Use batch settings") {
                            updateDraft {
                                $0.setOverrideMode(
                                    nil,
                                    for: entry.id
                                )
                            }
                        }
                        ForEach(DownloadMode.allCases) { mode in
                            Button(mode.rawValue) {
                                updateDraft {
                                    $0.setOverrideMode(
                                        mode,
                                        for: entry.id
                                    )
                                }
                            }
                        }
                    } label: {
                        Text(
                            draft.overrideMode(for: entry.id)?
                                .rawValue ?? "Batch"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .accessibilityIdentifier(
                        "playlist.override.\(entry.id)"
                    )
                }
                if entry.id != draft.selectedEntries.last?.id {
                    Divider().opacity(0.45)
                }
            }
        }
        .illucetCard()
    }

    private func batchReview(
        _ draft: PlaylistBatchDraft
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                playlistHeader(draft)
                VStack(alignment: .leading, spacing: 11) {
                    IllucetSectionHeader(
                        title: "Final summary",
                        systemImage: "checkmark.seal"
                    )
                    reviewRow(
                        "Items",
                        "\(draft.selectedEntries.count)"
                    )
                    reviewRow(
                        "Output",
                        draft.configuration.mode.rawValue
                    )
                    reviewRow(
                        "Preset",
                        draft.configuration.preset.rawValue
                    )
                    reviewRow(
                        "Destination",
                        draft.configuration.destination.rawValue
                    )
                    reviewRow(
                        "Layout",
                        draft.destinationStructure.label
                    )
                    reviewRow(
                        "Known source size",
                        draft.estimatedSelectedBytes?.formatted(
                            .byteCount(style: .file)
                        ) ?? "Not fully known"
                    )
                    reviewRow(
                        "Error policy",
                        draft.configuration.continuePlaylistOnError
                            ? "Continue"
                            : "Stop on first error"
                    )
                    reviewRow(
                        "Overrides",
                        "\(draft.itemOverrides.count)"
                    )
                }
                .illucetCard()

                VStack(alignment: .leading, spacing: 10) {
                    IllucetSectionHeader(
                        title: "Queue order",
                        systemImage: "list.number"
                    )
                    ForEach(draft.selectedEntries) { entry in
                        HStack {
                            Text(
                                String(
                                    format: "%02d",
                                    entry.index
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text(entry.title)
                                .lineLimit(1)
                            Spacer()
                            Text(
                                draft.overrideMode(for: entry.id)?
                                    .rawValue
                                    ?? draft.configuration.mode.rawValue
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .illucetCard()

                HStack(spacing: 12) {
                    Button {
                        model.returnToPlaylistStep(.options)
                    } label: {
                        Label("Edit", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.startPlaylistBatch()
                    } label: {
                        Label(
                            "Queue batch",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .accessibilityIdentifier("playlist.start")
                }
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("playlist.step.review")
    }

    private func availableModes(
        for draft: PlaylistBatchDraft
    ) -> [PlaylistSelectionMode] {
        PlaylistSelectionMode.allCases.filter { mode in
            if mode == .referencedVideo {
                return draft.analysis.referencedVideoID != nil
            }
            if draft.analysis.isTruncated,
               mode == .all || mode == .last {
                return false
            }
            return true
        }
    }

    private func maxPlaylistIndex(
        in draft: PlaylistBatchDraft
    ) -> Int {
        max(1, draft.analysis.entries.map(\.index).max() ?? 1)
    }

    private func boundedStepper(
        _ title: String,
        keyPath: WritableKeyPath<PlaylistBatchDraft, Int?>,
        defaultValue: Int,
        limit: Int
    ) -> some View {
        Stepper(
            value: Binding(
                get: {
                    model.playlistDraft?[keyPath: keyPath]
                        ?? max(1, defaultValue)
                },
                set: { value in
                    updateDraft {
                        $0[keyPath: keyPath] = value
                    }
                }
            ),
            in: 1 ... max(1, limit)
        ) {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "\(model.playlistDraft?[keyPath: keyPath] ?? max(1, defaultValue))"
                )
                .font(.headline.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func draftBinding<Value>(
        _ keyPath: WritableKeyPath<PlaylistBatchDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                model.playlistDraft?[keyPath: keyPath] ?? fallback
            },
            set: { value in
                updateDraft { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func updateDraft(
        _ update: (inout PlaylistBatchDraft) -> Void
    ) {
        guard var draft = model.playlistDraft else { return }
        update(&draft)
        model.playlistDraft = draft
    }

    private func reviewRow(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private struct PlaylistEntryLabel: View {
    @Environment(\.illucetPalette) private var theme
    let entry: PlaylistEntry
    let included: Bool
    let selectable: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.raisedCard)
                Text("\(entry.index)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 7) {
                    if let duration = entry.durationSeconds {
                        Text(duration.conciseDuration)
                    }
                    if let size = entry.estimatedBytes {
                        Text(size.formatted(.byteCount(style: .file)))
                    }
                    if !entry.availability.isDownloadable {
                        Text(availabilityLabel)
                            .foregroundStyle(IllucetTheme.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(
                systemName: entry.availability.isDownloadable
                    ? (
                        included
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    : "nosign"
            )
            .foregroundStyle(
                included ? theme.foregroundAccent : .secondary
            )
            .opacity(selectable || !entry.availability.isDownloadable
                ? 1
                : 0.55)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            entry.availability.isDownloadable
                ? (included ? "Included" : "Not included")
                : availabilityLabel
        )
    }

    private var availabilityLabel: String {
        switch entry.availability {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .privateVideo: "Private"
        case .deleted: "Deleted"
        }
    }
}

private struct IllucetSelectionButtonStyle: ButtonStyle {
    @Environment(\.illucetPalette) private var theme
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected
                    ? theme.actionFill
                    : theme.raisedCard,
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(
                        isSelected
                            ? theme.foregroundAccent
                            : IllucetTheme.border,
                        lineWidth: 1
                    )
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
