import SwiftUI
import UIKit

struct DownloadDefaultsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @FocusState private var filenameFieldFocused: Bool

    var body: some View {
        Form {
            Section("Output") {
                Picker("Default mode", selection: $model.settings.defaultMode) {
                    ForEach(DownloadMode.allCases) { mode in
                        brandedText(mode.rawValue).tag(mode)
                    }
                }
                Picker(
                    "Default quality",
                    selection: $model.settings.defaultPreset
                ) {
                    ForEach(DownloadPreset.allCases) { preset in
                        brandedText(preset.rawValue).tag(preset)
                    }
                }
                Picker(
                    "Maximum resolution",
                    selection: $model.settings.maximumResolution
                ) {
                    Text("No limit").tag(Int?.none)
                    ForEach(
                        [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320],
                        id: \.self
                    ) { value in
                        Text("\(value)p").tag(Int?.some(value))
                    }
                }
                if model.settings.defaultMode != .audioOnly {
                    Picker(
                        "Video codec",
                        selection: $model.settings.preferredVideoCodec
                    ) {
                        ForEach(
                            OutputCapabilityMatrix.enabledVideoCodecs(
                                for: model.settings.defaultMode
                            )
                        ) { codec in
                            brandedText(codec.rawValue).tag(codec)
                        }
                    }
                    if model.settings.preferredVideoCodec != .automatic {
                        Picker(
                            "Frame rate",
                            selection: $model.settings.defaultFrameRate
                        ) {
                            ForEach(
                                OutputCapabilityMatrix.enabledFrameRates
                            ) { rate in
                                brandedText(rate.rawValue).tag(rate)
                            }
                        }
                    }
                }
                if model.settings.defaultMode != .videoOnly {
                    Picker(
                        "Audio codec",
                        selection: $model.settings.preferredAudioCodec
                    ) {
                        ForEach(
                            OutputCapabilityMatrix.enabledAudioCodecs(
                                for: model.settings.defaultMode
                            )
                        ) { codec in
                            brandedText(codec.rawValue).tag(codec)
                        }
                    }
                }
                Picker(
                    "Container",
                    selection: $model.settings.preferredContainer
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledContainers(
                            for: model.settings.defaultMode,
                            audioCodec: model.settings.preferredAudioCodec,
                            videoCodec: model.settings.preferredVideoCodec
                        )
                    ) { container in
                        brandedText(container.rawValue).tag(container)
                    }
                }
                if let capability = ConversionCapabilityMatrix.audio(
                    model.settings.preferredAudioCodec
                ), !capability.isLossless,
                   !capability.bitRatesKbps.isEmpty {
                    Picker(
                        "Audio bitrate",
                        selection: $model.settings.defaultAudioBitrateKbps
                    ) {
                        ForEach(
                            capability.bitRatesKbps,
                            id: \.self
                        ) { rate in
                            Text("\(rate) kbps").tag(rate)
                        }
                    }
                }

                Label(
                    "Frame rate and HDR are preserved on stream-copy paths.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Extras") {
                Picker(
                    "Thumbnail",
                    selection: $model.settings.thumbnailBehavior
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledThumbnailBehaviors(
                            for: model.settings.configuration()
                        ).filter { ![.separate, .separateAndEmbed].contains($0) }
                    ) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .accessibilityIdentifier("settings.downloads.thumbnail")
                if model.settings.thumbnailBehavior == .thumbnailOnly
                    || (model.settings.defaultMode == .audioOnly && model.settings.thumbnailBehavior.embeds) {
                    Toggle("Square crop", isOn: Binding(
                        get: { model.settings.configuration().cropArtworkSquare },
                        set: { model.settings.cropArtworkSquare = $0 }
                    ))
                    .accessibilityIdentifier("settings.downloads.squareCrop")
                }
                Toggle(
                    "Preserve metadata",
                    isOn: $model.settings.preserveMetadata
                )
                Label(
                    "Subtitle delivery, verified chapters, and per-download packages are configured after analysis.",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Destination & network") {
                Picker(
                    "Default destination",
                    selection: $model.settings.defaultDestination
                ) {
                    ForEach(ExportDestination.allCases) { destination in
                        brandedText(destination.rawValue).tag(destination)
                    }
                }
                Toggle("Wi-Fi only", isOn: $model.settings.wifiOnly)
                Toggle("Start when charging", isOn: Binding(get: { model.settings.waitForCharging ?? false }, set: { model.settings.waitForCharging = $0 }))
                BandwidthPicker(title: "Total media speed limit", limit: $model.settings.downloadSpeedLimitBytesPerSecond)
                Toggle(
                    "Ask before cellular",
                    isOn: $model.settings.askBeforeCellular
                )
                Stepper(
                    "Simultaneous downloads: \(model.settings.maximumSimultaneousDownloads)",
                    value: $model.settings.maximumSimultaneousDownloads,
                    in: 1 ... 4
                )
                Stepper(
                    "Processing jobs: \(model.settings.maximumSimultaneousProcessingJobs)",
                    value: $model.settings.maximumSimultaneousProcessingJobs,
                    in: 1 ... 2
                )
                Stepper(
                    "Automatic retries: \(model.settings.automaticRetryCount)",
                    value: $model.settings.automaticRetryCount,
                    in: 0 ... 5
                )
            }

            Section {
                LabeledMenuPicker(
                    "Duplicate files",
                    selection: $model.settings.duplicateHandling
                ) {
                    ForEach(DuplicateHandling.allCases) { behavior in
                        brandedText(behavior.rawValue).tag(behavior)
                    }
                }
                .accessibilityIdentifier("settings.downloads.duplicates")
                TextField(
                    "Filename template",
                    text: $model.settings.filenameTemplate
                )
                .focused($filenameFieldFocused)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("settings.downloads.filename")
                Toggle(
                    "Keep temporary files after failure",
                    isOn: $model.settings.keepTemporaryFilesAfterFailure
                )
            } header: {
                Text("Files")
            } footer: {
                Text(
                    "Template fields: "
                        + FilenameSystem.supportedFields.map { "{\($0)}" }
                        .joined(separator: ", ")
                )
            }
        }
        .settingsFormBackground()
        .dismissesKeyboardFromUnusedSpace(
            identifier: "settings.downloads.unusedSpace",
            isFocused: filenameFieldFocused
        ) {
            filenameFieldFocused = false
        }
        .navigationTitle("Download defaults")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConversionDefaultsView: View {
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        Form {
            Section {
                Text("Compatible streams are copied without re-encoding.").font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Prefer VideoToolbox",
                    isOn: $model.settings.preferVideoToolbox
                )
                Toggle(
                    "Fast-start MP4 / MOV",
                    isOn: $model.settings.fastStartMP4
                )
                Picker(
                    "Default sample rate",
                    selection: $model.settings.defaultSampleRate
                ) {
                    ForEach(
                        OutputCapabilityMatrix.enabledSampleRates
                    ) { rate in
                        brandedText(rate.rawValue).tag(rate)
                    }
                }
                Toggle(
                    "Normalize loudness by default",
                    isOn: $model.settings.loudnessNormalization
                )
            } header: {
                Text("Processing")
            } footer: {
                Text(
                    "VideoToolbox use is reported from the encoder that actually ran. Fast-start is applied only to compatible MP4-family containers."
                )
            }

            Section("Foreground reliability") {
                Toggle(
                    "Keep screen awake while active",
                    isOn: $model.settings.keepScreenAwake
                )
                Text(
                    "Direct transfers use a background URL session. Native merging and conversion report checkpoints, but iOS may suspend CPU-heavy work after the app leaves the foreground."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Capabilities in this build") {
                capability("Stream-copy merge", available: true)
                capability("Original audio extraction", available: true)
                capability("AAC / MP3 encoding", available: true)
                capability("FLAC / ALAC encoding", available: true)
                capability("Opus / Vorbis / WAV encoding", available: true)
                capability("Sample rate / channels / loudness", available: true)
                capability("Video-only stream copy", available: true)
                capability("H.264 / HEVC VideoToolbox", available: true)
                capability("Verified audio artwork containers", available: true)
                capability("VP9 / AV1 encoding", available: false)
                capability("HDR-to-SDR conversion", available: false)
                capability("Subtitle embedding and burn-in", available: true)
                capability("Chapters and trimming", available: true)
                capability("Package folders and ZIP", available: true)
            }
        }
        .settingsFormBackground()
        .navigationTitle("Conversion")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capability(
        _ title: String,
        available: Bool
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(
                systemName: available
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .foregroundStyle(
                available ? IllucetTheme.success : IllucetTheme.warning
            )
            .accessibilityLabel(available ? "Implemented" : "Unavailable")
        }
    }
}


struct BandwidthPicker: View {
    let title: String
    @Binding var limit: Int64?
    var body: some View {
        VStack(alignment: .leading) {
            LabeledMenuPicker(title, selection: $limit) {
                Text("Unlimited").tag(nil as Int64?)
                ForEach([64, 128, 256, 512, 1024, 2048, 5120], id: \.self) { kib in
                    Text("\(kib) KiB/s").tag(Optional(Int64(kib * 1024)))
                }
            }
            DisclosureGroup("About speed limits") {
                brandedText("Applies to media while Illucet is running. Servers and iOS background transfers may exceed the limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
