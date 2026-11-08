import SwiftUI

struct QuickStartConfirmationView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    let metadata: MediaMetadata

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        mediaHeader
                        summaryCard
                        Button {
                            model.confirmQuickStartDownload()
                        } label: {
                            if model.isStartingQuickStart {
                                HStack {
                                    ProgressView()
                                    Text("Starting")
                                }
                            } else {
                                Label(
                                    "Download",
                                    systemImage: "arrow.down.circle.fill"
                                )
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(
                            model.isStartingQuickStart
                                || !currentModeAvailability.permitsSelection
                        )
                        .accessibilityIdentifier("quick.confirm.download")

                        Button {
                            model.editQuickStartDownload()
                        } label: {
                            Label(
                                "Edit details",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("quick.confirm.edit")
                    }
                    .padding(18)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Quick confirmation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelQuickStart()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .filesFolderImporter(model: model, source: .quickStart)
        .appAlertPresenter(model: model)
        .accessibilityIdentifier("quick.confirmation.sheet")
    }

    private var mediaHeader: some View {
        HStack(spacing: 13) {
            AsyncImage(url: metadata.thumbnails.last?.url) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    theme.raisedCard
                        .overlay(Image(systemName: "play.rectangle"))
                }
            }
            .frame(width: 104, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(metadata.channel ?? metadata.uploader ?? metadata.videoID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .illucetCard()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: model.activeQuickStartPreset?.name ?? "Quick Start",
                subtitle: "Ready with your saved choices",
                systemImage:
                    model.activeQuickStartPreset?.systemImage ?? "bolt.fill"
            )
            summaryRow(
                "Mode",
                model.configuration.effectiveOutputIdentity.rawValue
            )
            if let reason = currentModeAvailability.unavailableReason {
                Label(
                    "\(reason) Choose Edit details to select an available mode.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quick.confirm.modeUnavailable")
            }
            summaryRow("Quality", resolvedQuality)
            summaryRow("Expected output", expectedOutput)
            summaryRow("Approximate size", estimatedSize)
            summaryRow(
                "Destination",
                model.configuration.destination.rawValue
            )
        }
        .illucetCard()
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var resolvedQuality: String {
        switch model.configuration.mode {
        case .audioOnly:
            if let capability = ConversionCapabilityMatrix.audio(
                model.configuration.audioCodec
            ) {
                if capability.isLossless {
                    return "Lossless"
                }
                if model.configuration.resolvedAudioRateControl == .quality {
                    return model.configuration.resolvedAudioQuality.rawValue
                }
                return "\(model.configuration.audioBitrateKbps ?? 192) kbps"
            }
            return selectedAudio?.formatNote
                ?? selectedAudio?.audioBitrateKbps.map {
                    "\(Int($0)) kbps source"
                }
                ?? "Original"
        case .videoAndAudio, .videoOnly:
            guard let video = selectedVideo else {
                return model.activeQuickStartPreset?.qualityLabel
                    ?? "Automatic"
            }
            let resolution = video.pResolution.map { "\($0)p" } ?? "Source"
            if let framesPerSecond = video.framesPerSecond {
                return "\(resolution) • \(Int(framesPerSecond.rounded())) fps"
            }
            return resolution
        }
    }

    private var expectedOutput: String {
        guard let plan = try? OutputCapabilityMatrix.makePlan(
            configuration: model.configuration,
            metadata: metadata
        ) else {
            return model.activeQuickStartPreset?.outputLabel ?? "Unavailable"
        }
        let operation = plan.needsConversion ? "Convert" : "Stream copy"
        return "\(plan.fileExtension.uppercased()) • \(operation)"
    }

    private var estimatedSize: String {
        FormatSelection.estimatedOutputBytes(
            configuration: model.configuration,
            metadata: metadata
        )?.formatted(.byteCount(style: .file)) ?? "Unknown"
    }

    private var selectedVideo: MediaFormat? {
        guard let id = model.configuration.selectedVideoFormatID else {
            return nil
        }
        return metadata.formats.first { $0.formatID == id }
    }

    private var selectedAudio: MediaFormat? {
        guard let id = model.configuration.selectedAudioFormatID else {
            return nil
        }
        return metadata.formats.first { $0.formatID == id }
    }

    private var currentModeAvailability: DownloadModeAvailability {
        model.configuration.sourceModeAvailability(in: metadata)
    }
}

struct QuickStartPresetSections: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @State private var confirmsReset = false

    var body: some View {
        Group {
            Section("Quick Start Presets") {
                Button {
                    _ = model.addQuickStartPreset()
                } label: {
                    Label("New preset", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("quick.settings.add")
                .pipAnchor(.customPresets)
                ForEach(model.quickStartPresets) { preset in
                    NavigationLink {
                        QuickStartPresetEditorView(preset: preset)
                    } label: {
                        presetRow(preset)
                    }
                    .accessibilityIdentifier("quick.settings.preset.\(preset.id.uuidString)")
                    .accessibilityAction(named: "Move up") { move(preset, by: -1) }
                    .accessibilityAction(named: "Move down") { move(preset, by: 1) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteQuickStartPreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            model.duplicateQuickStartPreset(preset)
                        } label: {
                            Label(
                                "Duplicate",
                                systemImage: "plus.square.on.square"
                            )
                        }
                        .tint(theme.foregroundAccent)
                    }
                }
                .onMove(perform: model.moveQuickStartPresets)


            }

            Section {
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    Label(
                        "Reset to Defaults",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .accessibilityIdentifier("quick.settings.reset")
            }
        }
        .confirmationDialog(
            "Reset every Quick Start preset?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset presets", role: .destructive) {
                model.resetQuickStartPresets()
            }
            Button("Keep presets", role: .cancel) {}
        }
    }

    private func move(_ preset: QuickStartPreset, by offset: Int) {
        guard let index = model.quickStartPresets.firstIndex(where: { $0.id == preset.id }),
              model.quickStartPresets.indices.contains(index + offset) else { return }
        model.moveQuickStartPresets(fromOffsets: IndexSet(integer: index),
            toOffset: index + offset + (offset > 0 ? 1 : 0))
    }

    private func presetRow(_ preset: QuickStartPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: preset.systemImage)
                .foregroundStyle(theme.foregroundAccent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.body.weight(.medium))
                Text(
                    "\(preset.configuration.effectiveOutputIdentity.rawValue) • \(preset.qualityLabel)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if preset.launchBehavior == .immediate {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(IllucetTheme.warning)
                    .accessibilityLabel("Immediate download")
            }
        }
    }
}

struct QuickStartPresetEditorView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuickStartPreset
    @State private var confirmsImmediate = false
    @FocusState private var textEntryFocused: Bool
    private let originalLaunchBehavior: QuickStartLaunchBehavior

    init(preset: QuickStartPreset) {
        _draft = State(initialValue: preset)
        originalLaunchBehavior = preset.launchBehavior
    }

    var body: some View {
        Form {
            identitySection
            outputSection
            extrasSection
            sponsorBlockSection
            destinationSection
            behaviorSection
            saveSection
        }
        .settingsFormBackground()
        .dismissesKeyboardFromUnusedSpace(
            identifier: "quick.editor.unusedSpace",
            isFocused: textEntryFocused
        ) {
            textEntryFocused = false
        }
        .navigationTitle("Edit preset")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft.configuration.audioCodec) { _, _ in
            normalizeDraft()
        }
        .onChange(of: draft.configuration.videoCodec) { _, _ in
            normalizeDraft()
        }
        .confirmationDialog(
            "Enable immediate download?",
            isPresented: $confirmsImmediate,
            titleVisibility: .visible
        ) {
            Button("Enable Immediate Download") {
                persistAndDismiss()
            }
            Button("Keep Quick Confirmation", role: .cancel) {
                draft.launchBehavior = .confirmation
            }
        } message: {
            Text(
                "This preset will enter the queue immediately after analysis. Illucet will still stop for cellular approval, missing folder access, insufficient storage, playlist ambiguity, or an unsupported output."
            )
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Preset name", text: $draft.name)
                .focused($textEntryFocused)
                .accessibilityIdentifier("quick.editor.name")
            Picker("Icon", selection: $draft.systemImage) {
                ForEach(
                    QuickStartPresetLibrary.allowedSystemImages,
                    id: \.self
                ) { icon in
                    Label(iconName(icon), systemImage: icon).tag(icon)
                }
            }
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("Mode", selection: outputMode) {
                ForEach(DownloadMode.allCases) { mode in
                    brandedText(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("quick.editor.mode")

            if draft.configuration.mode != .audioOnly {
                Picker(
                    "Quality strategy",
                    selection: $draft.configuration.preset
                ) {
                    Text("Best available").tag(DownloadPreset.best)
                    Text("Apple-compatible").tag(DownloadPreset.compatible)
                    Text("Small").tag(DownloadPreset.small)
                    Text("Custom").tag(DownloadPreset.custom)
                }
                Picker(
                    "Maximum resolution",
                    selection: $draft.configuration.maximumResolution
                ) {
                    Text("Best available").tag(Int?.none)
                    ForEach(
                        [360, 480, 720, 1080, 1440, 2160, 4320],
                        id: \.self
                    ) { height in
                        Text("\(height)p").tag(Int?.some(height))
                    }
                }
                Picker(
                    "Video codec",
                    selection: $draft.configuration.videoCodec
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledVideoCodecs(
                            for: draft.configuration.mode
                        )
                    ) { codec in
                        brandedText(codec.rawValue).tag(codec)
                    }
                }
                if draft.configuration.videoCodec != .automatic {
                    Picker(
                        "Frame rate",
                        selection: $draft.configuration.frameRate
                    ) {
                        ForEach(
                            OutputCapabilityMatrix.enabledFrameRates
                        ) { rate in
                            brandedText(rate.rawValue).tag(rate)
                        }
                    }
                }
            }

            if draft.configuration.mode != .videoOnly {
                Picker(
                    "Audio codec",
                    selection: $draft.configuration.audioCodec
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledAudioCodecs(
                            for: draft.configuration.mode
                        )
                    ) { codec in
                        brandedText(codec.rawValue).tag(codec)
                    }
                }
                if let capability = ConversionCapabilityMatrix.audio(
                    draft.configuration.audioCodec
                ) {
                    if capability.rateControls.count > 1 {
                        Picker(
                            "Rate control",
                            selection: audioRateControl
                        ) {
                            ForEach(capability.rateControls) { control in
                                brandedText(control.rawValue).tag(control)
                            }
                        }
                    }
                    if !capability.isLossless,
                       draft.configuration.resolvedAudioRateControl
                        == .bitRate {
                        Picker(
                            "Audio bitrate",
                            selection: audioBitrate
                        ) {
                            ForEach(
                                capability.bitRatesKbps,
                                id: \.self
                            ) { bitrate in
                                Text("\(bitrate) kbps").tag(bitrate)
                            }
                        }
                    }
                    if draft.configuration.resolvedAudioRateControl
                        == .quality {
                        Picker(
                            "Encoder quality",
                            selection: audioQuality
                        ) {
                            ForEach(
                                AudioQualityChoice.allCases
                            ) { quality in
                                brandedText(quality.rawValue).tag(quality)
                            }
                        }
                    }
                    Picker(
                        "Sample rate",
                        selection: $draft.configuration.sampleRate
                    ) {
                        ForEach(
                            OutputCapabilityMatrix.enabledSampleRates
                        ) { rate in
                            brandedText(rate.rawValue).tag(rate)
                        }
                    }
                    Picker(
                        "Channels",
                        selection: $draft.configuration.channels
                    ) {
                        ForEach(
                            OutputCapabilityMatrix.enabledChannelChoices
                        ) { channels in
                            brandedText(channels.rawValue).tag(channels)
                        }
                    }
                    Toggle(
                        "Normalize loudness",
                        isOn: $draft.configuration.loudnessNormalization
                    )
                    Text(
                        "Transcoding cannot improve quality missing from the source."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Picker(
                "Container",
                selection: $draft.configuration.container
            ) {
                ForEach(
                    OutputCapabilityMatrix.enabledContainers(
                        for: draft.configuration.mode,
                        audioCodec: draft.configuration.audioCodec,
                        videoCodec: draft.configuration.videoCodec
                    )
                ) { container in
                    brandedText(container.rawValue).tag(container)
                }
            }
        }
    }

    private var extrasSection: some View {
        Section("Extras") {
            Picker(
                "Thumbnail",
                selection: thumbnailBehavior
            ) {
                ForEach(
                    OutputCapabilityMatrix.enabledThumbnailBehaviors(
                        for: draft.configuration
                    )
                ) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            Label(
                "Subtitle, chapter, and package choices remain available in the analyzed download options.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var sponsorBlockSection: some View {
        Section("SponsorBlock") {
            SponsorBlockPolicyControls(policy: sponsorBlockPolicy)
            if draft.configuration.sponsorBlock.needsSegmentReview {
                Label(
                    "This preset will always open analyzed segment review. Immediate download is unavailable while SponsorBlock categories are active.",
                    systemImage: "checklist"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
                .accessibilityIdentifier("quick.editor.sponsorblock.review")
            }
        }
    }

    private var destinationSection: some View {
        Section("Destination & filename") {
            Picker(
                "Destination",
                selection: $draft.configuration.destination
            ) {
                ForEach(ExportDestination.allCases) { destination in
                    brandedText(destination.rawValue).tag(destination)
                }
            }
            TextField(
                "Filename template",
                text: $draft.configuration.filenameTemplate
            )
            .focused($textEntryFocused)
            .textInputAutocapitalization(.never)
        }
    }

    private var behaviorSection: some View {
        Section("Start behavior") {
            Picker(
                "After analysis",
                selection: $draft.launchBehavior
            ) {
                ForEach(QuickStartLaunchBehavior.allCases) { behavior in
                    brandedText(behavior.rawValue).tag(behavior)
                }
            }
            .disabled(draft.configuration.sponsorBlock.needsSegmentReview)
            Text(
                draft.configuration.sponsorBlock.needsSegmentReview
                    ? "SponsorBlock requires analyzed segment review before any download can start."
                    : draft.launchBehavior == .immediate
                    ? "The job starts without the compact summary unless a technical decision needs attention."
                    : "A compact summary appears with one Download button."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                save()
            } label: {
                Label("Save Preset", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("quick.editor.save")
        }
    }

    private var audioBitrate: Binding<Int> {
        Binding(
            get: { draft.configuration.audioBitrateKbps ?? 192 },
            set: { draft.configuration.audioBitrateKbps = $0 }
        )
    }

    private var sponsorBlockPolicy: Binding<SponsorBlockPolicy> {
        Binding(
            get: { draft.configuration.sponsorBlock },
            set: { policy in
                draft.configuration.sponsorBlock = policy
                if policy.needsSegmentReview {
                    draft.launchBehavior = .confirmation
                }
            }
        )
    }

    private var outputMode: Binding<DownloadMode> {
        Binding(
            get: { draft.configuration.mode },
            set: { mode in
                var configuration = OutputCapabilityMatrix.selectingMode(
                    mode,
                    in: draft.configuration
                )
                configuration.preserveSourceResolution =
                    configuration.maximumResolution == nil
                draft.configuration = configuration
            }
        )
    }

    private var thumbnailBehavior: Binding<ThumbnailBehavior> {
        Binding(
            get: { draft.configuration.thumbnailBehavior },
            set: { behavior in
                draft.configuration =
                    OutputCapabilityMatrix.selectingThumbnailBehavior(
                        behavior,
                        in: draft.configuration
                    )
            }
        )
    }

    private var audioRateControl: Binding<AudioRateControlChoice> {
        Binding(
            get: { draft.configuration.resolvedAudioRateControl },
            set: {
                draft.configuration.audioRateControl = $0
                normalizeDraft()
            }
        )
    }

    private var audioQuality: Binding<AudioQualityChoice> {
        Binding(
            get: { draft.configuration.resolvedAudioQuality },
            set: { draft.configuration.audioQuality = $0 }
        )
    }

    private func normalizeDraft() {
        draft.configuration.preserveSourceResolution =
            draft.configuration.maximumResolution == nil
        draft.configuration = OutputCapabilityMatrix.normalized(
            draft.configuration
        )
        if draft.configuration.sponsorBlock.needsSegmentReview {
            draft.launchBehavior = .confirmation
        }
    }

    private func save() {
        normalizeDraft()
        if draft.launchBehavior == .immediate,
           originalLaunchBehavior != .immediate {
            confirmsImmediate = true
        } else {
            persistAndDismiss()
        }
    }

    private func persistAndDismiss() {
        model.saveQuickStartPreset(draft)
        dismiss()
    }

    private func iconName(_ icon: String) -> String {
        icon.replacingOccurrences(of: ".", with: " ").capitalized
    }
}
