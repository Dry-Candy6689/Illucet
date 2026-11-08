import SwiftUI

extension DownloadConfigurationView {
    var thumbnailOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "Thumbnail & artwork",
                subtitle: isThumbnailOnly
                    ? "Only the selected image will be downloaded"
                    : nil,
                systemImage: "photo"
            )
            Menu {
                Picker("Save thumbnail", selection: thumbnailBehaviorBinding) {
                    ForEach(thumbnailChoices) { behavior in
                        Text(behavior.displayName).tag(behavior)
                            .disabled(behavior == .includeVideoThumbnail && !supportsVideoThumbnail)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Save thumbnail").foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.configuration.thumbnailBehavior.displayName)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("configuration.thumbnail.behavior")
            if model.configuration.thumbnailBehavior == .includeVideoThumbnail {
                Text(supportsVideoThumbnail
                    ? "Embedded MP4 cover. Display depends on your player."
                    : "Video covers require MP4. Change File format or turn this off.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.configuration.mode != .audioOnly && !supportsVideoThumbnail && !isThumbnailOnly {
                Text("Video covers require MP4.").font(.caption).foregroundStyle(.secondary)
            }
            if model.configuration.thumbnailBehavior != .none && model.configuration.thumbnailBehavior != .includeVideoThumbnail {
                LabeledMenuPicker(
                    "Image format",
                    selection: $model.configuration.thumbnailFormat
                ) {
                    ForEach(ThumbnailService.supportedOutputFormats) { format in
                        brandedText(format.rawValue).tag(format)
                    }
                }
                if isThumbnailOnly {
                    Toggle(
                        "Crop output to square",
                        isOn: $model.configuration.cropArtworkSquare
                    )
                } else if model.configuration.mode == .audioOnly,
                          model.configuration.thumbnailBehavior.embeds {
                    Toggle(
                        "Crop square for audio artwork",
                        isOn: $model.configuration.cropArtworkSquare
                    )
                }

            }
        }
        .illucetCard()
    }

    var isThumbnailOnly: Bool {
        model.configuration.thumbnailBehavior == .thumbnailOnly
    }

    private var thumbnailChoices: [ThumbnailBehavior] {
        if model.configuration.mode == .audioOnly {
            return OutputCapabilityMatrix.enabledThumbnailBehaviors(for: model.configuration)
        }
        var choices: [ThumbnailBehavior] = [.none, .includeVideoThumbnail, .thumbnailOnly]
        // Keep legacy saved separate-image choices truthful until changed.
        let current = model.configuration.thumbnailBehavior
        if !choices.contains(current) { choices.append(current) }
        return choices
    }

    private var supportsVideoThumbnail: Bool {
        var configuration = model.configuration
        configuration.thumbnailBehavior = .none
        configuration.bundleStyle = .mediaOnly
        if isThumbnailOnly {
            FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
        }
        return (try? OutputCapabilityMatrix.makePlan(configuration: configuration, metadata: metadata))?.container == .mp4
    }

    var isSubtitlesOnly: Bool {
        model.configuration.isSubtitlesOnly
    }

    var subtitleOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            IllucetSectionHeader(
                title: "Subtitles",
                subtitle: isSubtitlesOnly
                    ? "Exact verified subtitle files with no media transfer"
                    : "Verified sidecars or container-native text tracks",
                systemImage: "captions.bubble"
            )
            LabeledMenuPicker(
                isSubtitlesOnly ? "Output format" : "Delivery",
                selection: Binding(get: { model.configuration.subtitleDelivery }, set: model.selectSubtitleDelivery)
            ) {
                ForEach(
                    isSubtitlesOnly
                        ? [.sidecarVTT, .sidecarSRT]
                        : OutputCapabilityMatrix.enabledSubtitleDeliveries
                ) {
                    Text($0.rawValue).tag($0)
                }
            }
            .accessibilityIdentifier("configuration.subtitle.delivery")
            if model.configuration.subtitleDelivery != .none {
                Button { presentsSubtitlePicker = true } label: {
                    HStack {
                        Label("Choose languages", systemImage: "globe")
                        Spacer()
                        Text("\((model.configuration.subtitleSelections ?? []).count) selected")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("configuration.subtitle.choose")
                if metadata.subtitles.isEmpty {
                    Text("No subtitle tracks were reported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.configuration.destination.supportsSubtitlesOnly,
                   isSubtitlesOnly {
                    Label(
                        "Subtitles Only requires Illucet, Files, or Share.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                    .accessibilityIdentifier(
                        "configuration.subtitle.destinationUnavailable"
                    )
                } else if model.configuration.destination == .photos,
                   model.configuration.subtitleDelivery == .sidecarVTT
                    || model.configuration.subtitleDelivery == .sidecarSRT {
                    Label(
                        "Photos-only cannot retain subtitle sidecars.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                }
                if model.configuration.subtitleDelivery == .burnIn {
                    Label(
                        "Burn In renders subtitle pixels and fully re-encodes the video. It supports SDR H.264 or HEVC in MP4/MOV with up to four selected tracks.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(IllucetTheme.warning)
                }
            } else {
                Text(
                    "Select exact manual or automatic WebVTT tracks for sidecar, embedded, or rendered delivery."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .illucetCard()
    }

    var chapterAndBundleOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                IllucetSectionHeader(
                    title: "Chapters & bundle",
                    subtitle: metadata.chapters.isEmpty
                        ? "No creator chapters reported"
                        : "\(metadata.chapters.count) creator chapters",
                    systemImage: "shippingbox"
                )
                Button { showsChapterHelp = true } label: { Image(systemName: "info.circle") }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("About chapter options")
                    .accessibilityIdentifier("configuration.chapters.info")
            }
            Toggle(
                "Keep source chapters",
                isOn: $model.configuration.preserveChapters
            )
            Toggle(
                "Add creator chapters",
                isOn: $model.configuration.writeChapters
            )
            .disabled(metadata.chapters.isEmpty)
            Toggle(
                "Save each chapter as a file",
                isOn: $model.configuration.splitChapters
            )
            .disabled(metadata.chapters.isEmpty)
            LabeledMenuPicker(
                "Bundle",
                selection: $model.configuration.bundleStyle
            ) {
                ForEach(OutputCapabilityMatrix.enabledBundleStyles) {
                    Text($0.rawValue).tag($0)
                }
            }
            if [.packageFolder, .zip].contains(
                model.configuration.bundleStyle
            ) {
                Text(
                    "Packages are finalized before export and include media, thumbnail, selected subtitles, metadata JSON, description, chapters, and a manifest. ZIP reports byte progress and contains only that finalized folder."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .illucetCard()
        .sheet(isPresented: $showsChapterHelp) {
            NavigationStack {
                List {
                    Section("Keep source chapters") { Text("Keep chapter markers already inside the downloaded media.") }
                    Section("Add creator chapters") { Text("Write the creator’s YouTube chapters into the file. These replace source chapters when available.") }
                    Section("Save each chapter as a file") { Text("Also save a separate media file for each creator chapter.") }
                }
                .navigationTitle("Chapter options")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsChapterHelp = false } } }
            }
        }
    }

    private var thumbnailBehaviorBinding: Binding<ThumbnailBehavior> {
        Binding(
            get: { model.configuration.thumbnailBehavior },
            set: { model.selectThumbnailBehavior($0) }
        )
    }


}


struct MetadataSidecarOptions: View {
    @Binding var configuration: DownloadConfiguration
    @State private var showsNetwork = false
    @State private var showsExtraFiles = false

    private var networkSummary: String {
        var values: [String] = []
        if configuration.wifiOnly == true { values.append("Wi-Fi only") }
        if configuration.waitForCharging == true { values.append("When charging") }
        if let limit = configuration.speedLimitBytesPerSecond { values.append("\(limit / 1024) KiB/s") }
        return values.isEmpty ? "No extra restrictions" : values.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    showsNetwork.toggle()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Network & charging").font(.headline)
                            Text(networkSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: showsNetwork ? "chevron.up" : "chevron.down")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsNetwork ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("configuration.network")
                if showsNetwork {
                    VStack(alignment: .leading, spacing: 12) {
                        BandwidthPicker(title: "Speed limit", limit: $configuration.speedLimitBytesPerSecond)
                        Toggle("Start on Wi-Fi only", isOn: Binding(get: { configuration.wifiOnly ?? false }, set: { configuration.wifiOnly = $0 }))
                        Toggle("Start when charging", isOn: Binding(get: { configuration.waitForCharging ?? false }, set: { configuration.waitForCharging = $0 }))
                        brandedText("Queued work starts while iOS allows Illucet to run.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
            }
            .illucetCard()
            VStack(alignment: .leading, spacing: 12) {
                Button { showsExtraFiles.toggle() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extra files").font(.headline)
                            Text((configuration.metadataSidecars ?? []).isEmpty
                                 ? "None" : "\((configuration.metadataSidecars ?? []).count) selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: showsExtraFiles ? "chevron.up" : "chevron.down")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsExtraFiles ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("configuration.extraFiles")
                if showsExtraFiles {
                    ForEach(MetadataSidecarKind.allCases) { kind in
                        Toggle(kind.rawValue, isOn: Binding(get: { (configuration.metadataSidecars ?? []).contains(kind) }, set: { enabled in
                            var kinds = configuration.metadataSidecars ?? []
                            if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
                            configuration.metadataSidecars = kinds
                        }))
                    }
                    DisclosureGroup("About extra files") {
                        brandedText("Saved beside media in Illucet or Files. Packages already include metadata and artwork. Checksums cover the completed media file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.illucetCard()
        }
    }
}
