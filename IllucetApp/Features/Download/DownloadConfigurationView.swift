import SwiftUI

struct DownloadConfigurationView: View {
    @Environment(\.illucetPalette) var theme
    enum TextEntryField: Hashable {
        case filename
    }

    @EnvironmentObject var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState var focusedTextEntry: TextEntryField?
    @State var presentsSubtitlePicker = false
    @State var showsAdvancedMedia = false
    @State var showsTechnicalDetails = false
    @State var showsChapterHelp = false
    let metadata: MediaMetadata

    private var hasSelectableSubtitles: Bool {
        metadata.subtitles.contains { $0.formats.contains(where: SubtitleSelectionPlanner.isSelectableWebVTT) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        sourceHeader
                        AccountBindingLabel(accountID: model.configuration.accountID)
                        modeSelector
                        if !isThumbnailOnly && !isSubtitlesOnly {
                            presetSelector
                            modeOptions
                        }
                        if !isSubtitlesOnly {
                            if !isThumbnailOnly { MetadataSidecarOptions(configuration: $model.configuration) }
                            thumbnailOptions
                        }
                        if !isThumbnailOnly {
                            subtitleOptions
                            if !isSubtitlesOnly {
                                chapterAndBundleOptions
                                SponsorBlockDownloadOptions()
                            }
                        }
                        destinationOptions
                        if !isSubtitlesOnly {
                            filenameOptions
                        }
                        reviewSummary
                        if model.settings.experience.skipDownloadReview {
                            if let bytes = FormatSelection.estimatedDownloadBytes(configuration: model.configuration, metadata: metadata),
                               bytes > model.settings.largeDownloadWarningBytes {
                                Label("Large download: \(bytes.formatted(.byteCount(style: .file)))", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(IllucetTheme.warning)
                            }
                            if (metadata.formats.filter { $0.formatID == model.configuration.selectedVideoFormatID }.compactMap(\.pResolution).max() ?? 0) >= 2_160 {
                                Label("4K or higher source", systemImage: "4k.tv")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if outputPlan?.needsConversion == true {
                                Label { brandedText("Conversion can take time. Keep Illucet open for the most reliable result.") }
                                    icon: { Image(systemName: "info.circle") }
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            model.showConfirmation()
                        } label: {
                            Label(
                                model.settings.experience.skipDownloadReview
                                    ? "Download"
                                    : isThumbnailOnly
                                    ? "Review thumbnail"
                                    : isSubtitlesOnly
                                        ? "Review subtitles"
                                        : "Review download",
                                systemImage: isThumbnailOnly
                                    ? "photo.badge.checkmark"
                                    : isSubtitlesOnly
                                        ? "captions.bubble"
                                        : "checklist"
                            )
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!canReviewConfiguration || model.isStartingDownload)
                        .accessibilityHint(
                            reviewUnavailableReason
                                ?? (model.settings.experience.skipDownloadReview ? "Download with these options" : "Review this configuration")
                        )
                        .accessibilityIdentifier("configuration.review")
                        if let reviewUnavailableReason {
                            Label(
                                reviewUnavailableReason,
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(IllucetTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "configuration.review.unavailableReason"
                            )
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                    .illucetContentWidth()
                }
                .dismissesKeyboardFromUnusedSpace(
                    identifier: "configuration.unusedSpace",
                    isFocused: focusedTextEntry != nil
                ) {
                    focusedTextEntry = nil
                }
            }
            .navigationTitle("Download options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        dismiss()
                        model.presentsMetadata = model.configurationReturnsToDetails
                    }
                }
            }
        }
        .sheet(isPresented: $presentsSubtitlePicker) {
            SubtitlePickerView(tracks: metadata.subtitles,
                selections: Binding(get: { model.configuration.subtitleSelections ?? [] },
                    set: { model.configuration.subtitleSelections = $0 }),
                maximumSelections: model.configuration.subtitleDelivery == .burnIn ? 4 : SubtitleSelectionPlanner.maximumSelections)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(false)
        .onChange(of: model.configuration) { _, value in
            let normalized = OutputCapabilityMatrix.normalized(value)
            if normalized != value {
                model.configuration = normalized
            }
        }
        .filesFolderImporter(model: model, source: .configuration)
        .appAlertPresenter(model: model)
        .accessibilityIdentifier("configuration.sheet")
    }

    private var sourceHeader: some View {
        HStack(spacing: 13) {
            AsyncImage(url: metadata.thumbnails.last?.url) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    theme.raisedCard
                        .overlay(Image(systemName: "play.rectangle"))
                }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(
                    metadata.durationSeconds?.conciseDuration ?? "Unknown duration"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .illucetCard()
        .accessibilityElement(children: .combine)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(DownloadMode.allCases) { mode in
                    let availability = sourceModeAvailability.status(for: mode)
                    Button {
                        model.selectMode(mode)
                    } label: {
                        Label(mode.rawValue + (availability.unavailableReason.map { " — " + $0 } ?? ""),
                              systemImage: model.configuration.effectiveOutputIdentity == mode.effectiveOutputIdentity ? "checkmark" : mode.systemImage)
                    }
                    .disabled(!availability.permitsSelection)
                    .accessibilityValue(model.configuration.effectiveOutputIdentity == mode.effectiveOutputIdentity ? "Selected" : "Not selected")
                    .accessibilityIdentifier("configuration.mode.\(mode.id)")
                }
                Button { model.selectThumbnailBehavior(.thumbnailOnly) } label: {
                    Label("Thumbnail Only", systemImage: isThumbnailOnly ? "checkmark" : "photo")
                }
                .disabled(metadata.thumbnails.isEmpty)
                .accessibilityIdentifier("configuration.mode.Thumbnail Only")
                Button { model.selectSubtitlesOnly() } label: {
                    Label(hasSelectableSubtitles ? "Subtitles Only" : "Subtitles Only — No available subtitles",
                          systemImage: isSubtitlesOnly ? "checkmark" : "captions.bubble")
                }
                .disabled(!hasSelectableSubtitles)
                .accessibilityValue(isSubtitlesOnly ? "Selected" : "Not selected")
                .accessibilityIdentifier("configuration.mode.Subtitles Only")
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Output").foregroundStyle(.primary)
                        Spacer()
                        Label(model.configuration.effectiveOutputIdentity.rawValue, systemImage: "chevron.up.chevron.down")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output").foregroundStyle(.primary)
                        Label(model.configuration.effectiveOutputIdentity.rawValue, systemImage: "chevron.up.chevron.down")
                    }
                }
            }
            .accessibilityIdentifier("configuration.output")
            if model.configuration.hasMediaTimeline, let reason = selectedModeAvailability.unavailableReason {
                Label("Choose an available output. \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(IllucetTheme.warning)
                    .accessibilityIdentifier("configuration.mode.unavailableSelection")
            }
        }.illucetCard()
    }

    private var presetSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Preset",
                systemImage: "wand.and.stars"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(DownloadPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            model.applyPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .tint(
                            model.configuration.preset == preset
                                ? theme.foregroundAccent
                                : .secondary
                        )
                    }
                }
            }
        }
        .illucetCard()
    }

    private var destinationOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "Destination",
                systemImage: "folder.badge.plus"
            )
            LabeledMenuPicker(
                "Save to",
                selection: $model.configuration.destination
            ) {
                ForEach(ExportDestination.allCases) { destination in
                    Label(
                        destination.rawValue,
                        systemImage: destination.systemImage
                    )
                    .tag(destination)
                    .disabled(
                        isSubtitlesOnly
                            && !destination.supportsSubtitlesOnly
                    )
                }
            }
            .accessibilityIdentifier("configuration.destination.menu")
            if [
                ExportDestination.filesFolder,
                .filesAndPhotos,
            ].contains(model.configuration.destination) {
                Button {
                    model.requestFilesFolderPicker(from: .configuration)
                } label: {
                    Label(
                        model.filesFolderName ?? "Select Files folder",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("configuration.filesFolder")
            }
            if !isThumbnailOnly,
               !isSubtitlesOnly,
               model.configuration.mode == .audioOnly,
               [
                   ExportDestination.photos,
                   .filesAndPhotos,
               ].contains(model.configuration.destination) {
                Label(
                    "Audio-only files must be saved to Files, Illucet, or Share.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
            }
        }
        .illucetCard()
    }

    private var filenameOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Filename",
                systemImage: "textformat"
            )
            TextField(
                "{title}",
                text: $model.configuration.filenameTemplate
            )
            .textInputAutocapitalization(.never)
            .focused($focusedTextEntry, equals: .filename)
            .accessibilityIdentifier("configuration.filename")
            .padding(12)
            .background(
                theme.input,
                in: RoundedRectangle(cornerRadius: 12)
            )
            Text("Preview: \(filenamePreview)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(
                    FilenameSystem.supportedFields.map { "{\($0)}" }
                        .joined(separator: "  ")
                )
                .font(.caption.monospaced())
                .foregroundStyle(theme.foregroundAccent)
            }
        }
        .illucetCard()
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    isThumbnailOnly
                        ? "Thumbnail only — no media streams"
                        : isSubtitlesOnly
                            ? "Subtitles only — no media streams"
                        : outputPlan?.needsConversion == true
                            ? "Conversion required"
                            : "Stream copy / merge",
                    systemImage: isThumbnailOnly
                        ? "photo"
                        : isSubtitlesOnly
                            ? "captions.bubble"
                        : outputPlan?.needsConversion == true
                            ? "gearshape.2"
                            : "arrow.triangle.merge"
                )
                .foregroundStyle(
                    isThumbnailOnly
                        ? theme.foregroundAccent
                        : isSubtitlesOnly
                            ? theme.foregroundAccent
                        : outputPlan?.needsConversion == true
                        ? IllucetTheme.warning
                        : theme.foregroundAccent
                )
                Spacer()
                Text(
                    isSubtitlesOnly
                        ? "\(model.configuration.subtitleSelections?.count ?? 0) tracks"
                        : estimatedSize
                )
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text(
                isThumbnailOnly
                    ? "Image: \(model.configuration.thumbnailFormat.rawValue)"
                    : isSubtitlesOnly
                        ? "Format: \(model.configuration.subtitleDelivery.rawValue)"
                    : "Formats: \(selectedFormatsText)"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .illucetCard()
        .accessibilityElement(children: .combine)
    }

    private var sourceModeAvailability: SourceModeAvailability {
        SourceModeAvailability(analyzedMetadata: metadata)
    }

    private var selectedModeAvailability: DownloadModeAvailability {
        sourceModeAvailability.status(for: model.configuration.mode)
    }

    private var canReviewConfiguration: Bool {
        reviewUnavailableReason == nil
    }

    private var reviewUnavailableReason: String? {
        if let reason = model.sponsorBlockReviewState.unavailableReason {
            return reason
        }
        if isSubtitlesOnly {
            guard model.configuration.destination.supportsSubtitlesOnly else {
                return "Choose Illucet, Files, or Share for a Subtitles Only request."
            }
            guard !(model.configuration.subtitleSelections ?? []).isEmpty
            else {
                return "Select at least one subtitle track before review."
            }
            guard [.sidecarVTT, .sidecarSRT].contains(
                model.configuration.subtitleDelivery
            ) else {
                return "Choose WebVTT or SRT for a Subtitles Only request."
            }
            guard (try? OutputCapabilityMatrix.validate(
                model.configuration,
                metadata: metadata
            )) != nil else {
                return "Resolve the highlighted subtitle configuration before review."
            }
            return nil
        }
        return model.configuration.sourceModeAvailability(
            in: metadata
        ).unavailableReason
    }

    private var estimatedSize: String {
        guard let bytes = FormatSelection.estimatedOutputBytes(
            configuration: model.configuration,
            metadata: metadata
        ) else { return "Size unknown" }
        return bytes.formatted(.byteCount(style: .file))
    }

    private var selectedFormatsText: String {
        let IDs = model.configuration.selectedFormatIDs
        return IDs.isEmpty ? "Automatic" : IDs.joined(separator: " + ")
    }

    private var filenamePreview: String {
        let selected = metadata.formats.first {
            model.configuration.selectedFormatIDs.contains($0.formatID)
        }
        return FilenameSystem.render(
            template: model.configuration.filenameTemplate,
            metadata: metadata,
            configuration: model.configuration,
            format: selected
        )
    }
}
