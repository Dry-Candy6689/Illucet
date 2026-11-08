import SwiftUI

extension DownloadConfigurationView {
    var modeOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(title: "Quality & format", systemImage: "slider.horizontal.3")
            if model.configuration.mode != .audioOnly { resolutionPicker }
            LabeledMenuPicker("File format", selection: containerBinding) {
                ForEach(videoContainers) { container in
                    Text(container == .automatic ? "Automatic" : container.rawValue).tag(container)
                }
            }
            .accessibilityIdentifier("configuration.container")
            selectedMediaSummary
            if model.configuration.mode == .videoOnly {
                Label("No audio will be included", systemImage: "speaker.slash.fill")
                    .font(.caption).foregroundStyle(IllucetTheme.warning)
            }
            if let warning = FormatSelection.sourceQualityWarning(configuration: model.configuration, metadata: metadata) {
                Label(warning, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(IllucetTheme.warning)
                    .accessibilityIdentifier("configuration.qualityWarning")
            }
            if outputPlan?.needsConversion == true {
                Label("These choices require conversion", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                showsAdvancedMedia.toggle()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced")
                        if let summary = advancedSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: showsAdvancedMedia ? "chevron.up" : "chevron.down")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.foregroundAccent)
            .accessibilityValue(showsAdvancedMedia ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("configuration.advanced")
            if showsAdvancedMedia {
                VStack(alignment: .leading, spacing: 14) {
                    if model.configuration.mode != .audioOnly {
                        formatPicker(title: "Video source", selection: formatSelectionBinding(for: .video), formats: videoFormats)
                    }
                    if model.configuration.mode != .videoOnly {
                        formatPicker(title: "Audio source", selection: formatSelectionBinding(for: .audio), formats: audioFormats)
                    }
                    codecAndContainerPickers
                    if model.configuration.mode != .audioOnly { videoEncodingControls }
                    if model.configuration.mode != .videoOnly { audioEncodingControls }
                    Button {
                        showsTechnicalDetails.toggle()
                    } label: {
                        HStack {
                            Text("Technical details")
                            Spacer(minLength: 8)
                            Image(systemName: showsTechnicalDetails ? "chevron.up" : "chevron.down")
                                .frame(width: 44, height: 48)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.foregroundAccent)
                    .accessibilityValue(showsTechnicalDetails ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("configuration.technicalDetails")
                    if showsTechnicalDetails {
                        ForEach(selectedFormats, id: \.formatID) { format in
                            Text(MediaSourceSummary.technical(format))
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }.illucetCard()
    }

    private var selectedFormats: [MediaFormat] {
        metadata.formats.filter { model.configuration.selectedFormatIDs.contains($0.formatID) }
    }

    private var advancedSummary: String? {
        var values: [String] = []
        let config = model.configuration
        if config.formatSelectionProvenance == .manual { values.append("Manual sources") }
        if config.mode != .audioOnly, config.videoCodec != .automatic {
            values.append(config.videoCodec.rawValue)
            if config.frameRate != .preserve { values.append(config.frameRate.rawValue) }
        }
        if config.mode != .videoOnly, ![.automatic, .original].contains(config.audioCodec) {
            values.append(config.audioCodec.rawValue)
            if config.sampleRate != .preserve { values.append(config.sampleRate.rawValue) }
            if config.channels != .preserve { values.append(config.channels.rawValue) }
            if config.loudnessNormalization { values.append("Loudness normalization") }
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var selectedMediaSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.configuration.formatSelectionProvenance == .manual ? "Selected sources" : "Automatically selected sources")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(selectedFormats, id: \.formatID) { format in
                Text(MediaSourceSummary.friendly(format))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("configuration.sourcesSummary")
    }

    private var resolutionPicker: some View {
        LabeledMenuPicker("Video quality", selection: resolutionBinding) {
            Text("Best available").tag(Int?.none)
            ForEach(FormatSelection.availableResolutions(in: metadata), id: \.self) { height in
                Text("Up to \(height)p").tag(Int?.some(height))
            }
        }
        .accessibilityIdentifier("configuration.resolution")
    }

    private func formatPicker(title: String, selection: Binding<String?>, formats: [MediaFormat]) -> some View {
        let selected = formats.first { $0.formatID == selection.wrappedValue }
        return Menu {
            Picker(title, selection: selection) {
                Text("Automatic").tag(String?.none)
                ForEach(formats, id: \.formatID) { format in
                    Text(MediaSourceSummary.friendly(format) + " · Source " + format.formatID)
                        .tag(String?.some(format.formatID))
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(.primary)
                HStack(alignment: .center, spacing: 10) {
                    Text(selected.map { MediaSourceSummary.friendly($0) + " · Source " + $0.formatID }
                         ?? (selection.wrappedValue == nil ? "Automatic" : "Unavailable source"))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(title == "Video source" ? "configuration.source.video" : "configuration.source.audio")
    }

    private enum FormatPickerRole {
        case video
        case audio
    }

    private func formatSelectionBinding(
        for role: FormatPickerRole
    ) -> Binding<String?> {
        Binding(
            get: {
                switch role {
                case .video:
                    model.configuration.selectedVideoFormatID
                case .audio:
                    model.configuration.selectedAudioFormatID
                }
            },
            set: { formatID in
                guard let formatID else {
                    FormatSelection.applyAutomaticSelection(
                        to: &model.configuration,
                        metadata: metadata
                    )
                    return
                }
                switch role {
                case .video:
                    model.configuration.selectedVideoFormatID = formatID
                case .audio:
                    model.configuration.selectedAudioFormatID = formatID
                }
                model.configuration.formatSelectionProvenance = .manual
            }
        )
    }

    private var codecAndContainerPickers: some View {
        Group {
            if model.configuration.mode != .audioOnly {
                LabeledMenuPicker("Video encoding", selection: videoCodecBinding) {
                    ForEach(OutputCapabilityMatrix.enabledVideoCodecs(for: model.configuration.mode)) { codec in
                        Text(codec == .automatic ? "Automatic" : codec.rawValue).tag(codec)
                    }
                }
                .accessibilityIdentifier("configuration.encoding.video")
            }
            if model.configuration.mode != .videoOnly {
                LabeledMenuPicker("Audio encoding", selection: audioCodecBinding) {
                    ForEach(OutputCapabilityMatrix.enabledAudioCodecs(for: model.configuration.mode)) { codec in
                        Text(codec == .automatic ? "Automatic" : codec.rawValue).tag(codec)
                    }
                }
            }
        }
    }

    private var audioEncodingControls: some View {
        Group {
            if let capability = ConversionCapabilityMatrix.audio(
                model.configuration.audioCodec
            ) {
                if capability.rateControls.count > 1 {
                    LabeledMenuPicker(
                        "Rate control",
                        selection: audioRateControlBinding
                    ) {
                        ForEach(capability.rateControls) { control in
                            brandedText(control.rawValue).tag(control)
                        }
                    }
                }
                if !capability.isLossless,
                   model.configuration.resolvedAudioRateControl == .bitRate {
                    LabeledMenuPicker(
                        "Output bitrate",
                        selection: $model.configuration.audioBitrateKbps
                    ) {
                        ForEach(capability.bitRatesKbps, id: \.self) { rate in
                            Text("\(rate) kbps").tag(Int?.some(rate))
                        }
                    }
                }
                if model.configuration.resolvedAudioRateControl == .quality {
                    LabeledMenuPicker(
                        "Encoder quality",
                        selection: audioQualityBinding
                    ) {
                        ForEach(AudioQualityChoice.allCases) { quality in
                            brandedText(quality.rawValue).tag(quality)
                        }
                    }
                }
                LabeledMenuPicker(
                    "Sample rate",
                    selection: $model.configuration.sampleRate
                ) {
                    ForEach(OutputCapabilityMatrix.enabledSampleRates) { rate in
                        brandedText(rate.rawValue).tag(rate)
                    }
                }
                LabeledMenuPicker(
                    "Channels",
                    selection: $model.configuration.channels
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledChannelChoices
                    ) { channels in
                        brandedText(channels.rawValue).tag(channels)
                    }
                }
                Toggle(
                    "Normalize loudness",
                    isOn: $model.configuration.loudnessNormalization
                )
                if capability.isLossless {
                    Label(
                        "Lossless encoding has no bitrate control.",
                        systemImage: "waveform.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Label(
                    "Transcoding cannot restore quality missing from the selected source.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
            } else {
                Label(
                    "Original audio preserves the source sample rate, channel layout, and codec.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var videoEncodingControls: some View {
        Group {
            if ConversionCapabilityMatrix.video(
                model.configuration.videoCodec
            ) != nil {
                LabeledMenuPicker(
                    "Frame rate",
                    selection: $model.configuration.frameRate
                ) {
                    ForEach(OutputCapabilityMatrix.enabledFrameRates) { rate in
                        brandedText(rate.rawValue).tag(rate)
                    }
                }
                if model.configuration.videoCodec == .hevc {
                    Label(
                        "HEVC conversion preserves verified HDR color properties. HDR-to-SDR conversion is unavailable.",
                        systemImage: "sun.max"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "H.264 conversion is available for SDR sources. HDR sources require HEVC or stream copy.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                }
            }
        }
    }

    private var videoFormats: [MediaFormat] {
        metadata.formats
            .filter(\.hasVideo)
            .sorted {
                ($0.pResolution ?? 0, $0.framesPerSecond ?? 0)
                    > ($1.pResolution ?? 0, $1.framesPerSecond ?? 0)
            }
    }

    private var audioFormats: [MediaFormat] {
        metadata.formats
            .filter(\.hasAudio)
            .sorted {
                ($0.audioBitrateKbps ?? 0) > ($1.audioBitrateKbps ?? 0)
            }
    }

    private var videoContainers: [OutputContainerChoice] {
        OutputCapabilityMatrix.enabledContainers(
            for: model.configuration.mode,
            audioCodec: model.configuration.audioCodec,
            videoCodec: model.configuration.videoCodec
        )
    }

    private var resolutionBinding: Binding<Int?> {
        Binding(
            get: { model.configuration.maximumResolution },
            set: { value in
                model.configuration.maximumResolution = value
                model.configuration.preserveSourceResolution = value == nil
                FormatSelection.applyAutomaticSelection(
                    to: &model.configuration,
                    metadata: metadata
                )
            }
        )
    }

    private var videoCodecBinding: Binding<VideoCodecPreference> {
        Binding(
            get: { model.configuration.videoCodec },
            set: { value in
                model.configuration.videoCodec = value
                model.configuration.container = .automatic
                FormatSelection.applyAutomaticSelection(
                    to: &model.configuration,
                    metadata: metadata
                )
            }
        )
    }

    private var audioCodecBinding: Binding<AudioCodecPreference> {
        Binding(
            get: { model.configuration.audioCodec },
            set: { value in
                model.configuration.audioCodec = value
                model.configuration.container = .automatic
                FormatSelection.applyAutomaticSelection(
                    to: &model.configuration,
                    metadata: metadata
                )
            }
        )
    }

    private var audioRateControlBinding: Binding<AudioRateControlChoice> {
        Binding(
            get: { model.configuration.resolvedAudioRateControl },
            set: { value in
                model.configuration.audioRateControl = value
                model.configuration = OutputCapabilityMatrix.normalized(
                    model.configuration
                )
            }
        )
    }

    private var audioQualityBinding: Binding<AudioQualityChoice> {
        Binding(
            get: { model.configuration.resolvedAudioQuality },
            set: { model.configuration.audioQuality = $0 }
        )
    }

    private var containerBinding: Binding<OutputContainerChoice> {
        Binding(
            get: { model.configuration.container },
            set: { value in
                model.configuration.container = value
                FormatSelection.applyAutomaticSelection(
                    to: &model.configuration,
                    metadata: metadata
                )
            }
        )
    }

    var outputPlan: OutputPlan? {
        try? OutputCapabilityMatrix.makePlan(
            configuration: model.configuration,
            metadata: metadata
        )
    }

}

/// Display projection only: source identities and selection remain unchanged.
enum MediaSourceSummary {
    static func friendly(_ format: MediaFormat) -> String {
        var parts: [String] = []
        if format.hasVideo {
            parts.append(format.pResolution.map { "\($0)p" } ?? "Video")
            if let fps = format.framesPerSecond, fps.isFinite, fps > 0 {
                parts.append("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps")
            }
            if format.isHDR { parts.append("HDR") }
        } else {
            let codec = format.audioCodec?.lowercased() ?? ""
            let name = codec.hasPrefix("mp4a") || codec.hasPrefix("aac") ? "AAC"
                : codec.hasPrefix("opus") ? "Opus"
                : codec.hasPrefix("mp3") ? "MP3" : nil
            parts.append(name.map { "\($0) audio" } ?? "Audio")
        }
        if !format.hasVideo, let rate = format.audioBitrateKbps, rate.isFinite, rate > 0 {
            parts.append("\(rate.formatted(.number.precision(.fractionLength(0)))) kbps")
        }
        if let bytes = format.fileSize, bytes > 0 {
            let prefix = format.exactFileSizeBytes == nil ? "About " : ""
            parts.append(prefix + bytes.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    static func technical(_ format: MediaFormat) -> String {
        ["Source \(format.formatID)", format.resolution, format.videoCodec, format.audioCodec,
         format.container ?? format.extension, format.protocolName].compactMap { $0 }.joined(separator: " · ")
    }
}
