import Foundation

/// The production source of truth for output controls Illucet can honor end
/// to end. Native encoder details remain in `ConversionCapabilityMatrix`;
/// deterministic request planning lives in `OutputConversionPlanner`.
enum OutputCapabilityMatrix {
    static let enabledFrameRates = ConversionCapabilityMatrix.frameRates
    static let enabledSampleRates = ConversionCapabilityMatrix.sampleRates
    static let enabledChannelChoices =
        ConversionCapabilityMatrix.channelChoices
    static let enabledSubtitleDeliveries: [SubtitleDelivery] = [
        .none,
        .sidecarVTT,
        .sidecarSRT,
        .embed,
        .burnIn,
    ]
    static let enabledBundleStyles: [BundleStyle] = BundleStyle.allCases
    static let enabledPlaylistBehaviors: [PlaylistBehavior] = [
        .referencedVideo,
    ]

    private static let videoContainerOrder: [OutputContainerChoice] = [
        .mp4,
        .mov,
        .mkv,
        .webm,
    ]

    static func enabledVideoCodecs(
        for mode: DownloadMode
    ) -> [VideoCodecPreference] {
        switch mode {
        case .audioOnly:
            []
        case .videoAndAudio, .videoOnly:
            [.automatic] + ConversionCapabilityMatrix.selectableVideoCodecs
        }
    }

    static func enabledAudioCodecs(
        for mode: DownloadMode
    ) -> [AudioCodecPreference] {
        switch mode {
        case .videoOnly:
            []
        case .audioOnly, .videoAndAudio:
            [.automatic, .original]
                + ConversionCapabilityMatrix.audioCodecs
        }
    }

    static func enabledContainers(
        for mode: DownloadMode,
        audioCodec: AudioCodecPreference,
        videoCodec: VideoCodecPreference = .automatic
    ) -> [OutputContainerChoice] {
        switch mode {
        case .audioOnly:
            guard let capability = ConversionCapabilityMatrix.audio(
                audioCodec
            ) else {
                return [.automatic]
            }
            return [.automatic] + capability.containers

        case .videoOnly:
            guard let capability = ConversionCapabilityMatrix.video(
                videoCodec
            ) else {
                return [.automatic]
            }
            return [.automatic] + capability.containers

        case .videoAndAudio:
            guard let videoCapability = ConversionCapabilityMatrix.video(
                videoCodec
            ) else {
                return [.automatic]
            }
            let videoChoices = videoCapability.containers
            let audioChoices =
                ConversionCapabilityMatrix.audio(audioCodec)?.containers
                    ?? videoContainerOrder
            let choices = videoContainerOrder.filter {
                videoChoices.contains($0) && audioChoices.contains($0)
            }
            return [.automatic] + choices
        }
    }

    static func enabledAudioRateControls(
        for codec: AudioCodecPreference
    ) -> [AudioRateControlChoice] {
        ConversionCapabilityMatrix.rateControls(for: codec)
    }

    static func enabledAudioBitRates(
        for codec: AudioCodecPreference
    ) -> [Int] {
        ConversionCapabilityMatrix.bitRatesKbps(for: codec)
    }

    static func audioCodecIsLossless(
        _ codec: AudioCodecPreference
    ) -> Bool {
        ConversionCapabilityMatrix.audio(codec)?.isLossless == true
    }

    static func enabledThumbnailBehaviors(
        for configuration: DownloadConfiguration
    ) -> [ThumbnailBehavior] {
        if configuration.mode != .audioOnly {
            return [.none, .includeVideoThumbnail, .thumbnailOnly, .separate]
        }
        guard
            configuration.mode == .audioOnly,
            ConversionCapabilityMatrix.audio(configuration.audioCodec) != nil
        else {
            return [.none, .separate, .thumbnailOnly]
        }
        let container = configuration.container == .automatic
            ? OutputConversionPlanner.defaultContainer(
                for: configuration.audioCodec
            )
            : configuration.container
        guard
            let container,
            ConversionCapabilityMatrix.supportsArtwork(
                codec: configuration.audioCodec,
                container: container
            )
        else {
            return [.none, .separate, .thumbnailOnly]
        }
        return [
            .none,
            .separate,
            .embed,
            .separateAndEmbed,
            .thumbnailOnly,
        ]
    }

    static func normalized(
        _ value: DownloadConfiguration
    ) -> DownloadConfiguration {
        var result = value
        result.sponsorBlock = result.sponsorBlock.normalized()

        if result.isSubtitlesOnly {
            result.selectedVideoFormatID = nil
            result.selectedAudioFormatID = nil
            result.thumbnailBehavior = .none
            result.thumbnailID = nil
            result.cropArtworkSquare = false
            if ![.sidecarVTT, .sidecarSRT].contains(
                result.subtitleDelivery
            ) {
                result.subtitleDelivery = .sidecarVTT
            }
            let selections = result.subtitleSelections ?? []
            result.subtitleLanguages = Set(selections.map(\.language))
            result.includeAutomaticSubtitles = selections.contains(
                where: \.automatic
            )
            result.preserveChapters = false
            result.writeChapters = false
            result.splitChapters = false
            result.bundleStyle = .mediaOnly
            result.playlistBehavior = .referencedVideo
            result.trimStartSeconds = nil
            result.trimEndSeconds = nil
            result.trimMode = nil
            return result
        }

        if !enabledVideoCodecs(for: result.mode).contains(result.videoCodec) {
            result.videoCodec = .automatic
        }
        if !enabledAudioCodecs(for: result.mode).contains(result.audioCodec) {
            result.audioCodec = result.mode == .audioOnly
                ? .original
                : .automatic
        }
        let containers = enabledContainers(
            for: result.mode,
            audioCodec: result.audioCodec,
            videoCodec: result.videoCodec
        )
        if !containers.contains(result.container) {
            result.container = .automatic
        }

        if result.videoCodec == .automatic
            || result.mode == .audioOnly {
            result.frameRate = .preserve
        } else if !enabledFrameRates.contains(result.frameRate) {
            result.frameRate = .preserve
        }
        result.convertHDRToSDR = false
        result.preserveHDR = result.mode != .audioOnly

        if let capability = ConversionCapabilityMatrix.audio(
            result.audioCodec
        ) {
            if !enabledSampleRates.contains(result.sampleRate) {
                result.sampleRate = .preserve
            }
            if !enabledChannelChoices.contains(result.channels) {
                result.channels = .preserve
            }
            normalizeAudioEncoding(
                &result,
                capability: capability
            )
        } else {
            result.audioBitrateKbps = nil
            result.audioRateControl = nil
            result.audioQuality = nil
            result.sampleRate = .preserve
            result.channels = .preserve
            result.loudnessNormalization = false
        }

        if !enabledThumbnailBehaviors(for: result).contains(
            result.thumbnailBehavior
        ) {
            result.thumbnailBehavior = .separate
        }
        if !ThumbnailService.supportedOutputFormats.contains(
            result.thumbnailFormat
        ) {
            result.thumbnailFormat = .original
        }

        if !enabledSubtitleDeliveries.contains(result.subtitleDelivery) {
            result.subtitleDelivery = .none
        }
        if [.embed, .burnIn].contains(result.subtitleDelivery)
            && result.mode == .audioOnly {
            result.subtitleDelivery = .none
        }
        if result.thumbnailBehavior == .thumbnailOnly
            || result.subtitleDelivery == .none {
            result.subtitleDelivery = .none
            result.subtitleSelections = nil
            result.subtitleLanguages = []
            result.includeAutomaticSubtitles = false
        } else {
            let selections = result.subtitleSelections ?? []
            result.subtitleLanguages = Set(selections.map(\.language))
            result.includeAutomaticSubtitles = selections.contains(
                where: \.automatic
            )
        }
        if result.thumbnailBehavior == .thumbnailOnly {
            result.selectedVideoFormatID = nil
            result.selectedAudioFormatID = nil
        }
        if result.mode == .audioOnly
            || result.thumbnailBehavior == .thumbnailOnly {
            result.splitChapters = false
        }
        if !enabledBundleStyles.contains(result.bundleStyle) {
            result.bundleStyle = .mediaOnly
        }
        if result.bundleStyle == .mediaAndThumbnail,
           !result.thumbnailBehavior.downloadsSeparately,
           result.thumbnailBehavior != .includeVideoThumbnail {
            result.thumbnailBehavior = .separate
        } else if result.bundleStyle != .mediaOnly,
                  result.thumbnailBehavior == .none {
            result.thumbnailBehavior = .separate
        }
        if !enabledPlaylistBehaviors.contains(result.playlistBehavior) {
            result.playlistBehavior = .referencedVideo
        }
        normalizeTrim(&result)

        switch result.mode {
        case .videoAndAudio:
            break
        case .audioOnly:
            result.selectedVideoFormatID = nil
            result.videoCodec = .automatic
            result.frameRate = .preserve
            result.maximumResolution = nil
            result.preserveSourceResolution = true
        case .videoOnly:
            result.selectedAudioFormatID = nil
            result.audioCodec = .automatic
            result.audioBitrateKbps = nil
            result.audioRateControl = nil
            result.audioQuality = nil
            result.sampleRate = .preserve
            result.channels = .preserve
            result.loudnessNormalization = false
        }
        return result
    }

    static func selectingMode(
        _ mode: DownloadMode,
        in value: DownloadConfiguration
    ) -> DownloadConfiguration {
        var result = value
        result.requestKind = nil
        if result.thumbnailBehavior == .thumbnailOnly {
            result.thumbnailBehavior = .none
        }
        result.mode = mode
        return normalized(result)
    }

    static func selectingThumbnailBehavior(
        _ behavior: ThumbnailBehavior,
        in value: DownloadConfiguration
    ) -> DownloadConfiguration {
        var result = value
        result.requestKind = nil
        if behavior == .thumbnailOnly, value.thumbnailBehavior != .thumbnailOnly {
            result.cropArtworkSquare = false
        }
        result.thumbnailBehavior = behavior
        return normalized(result)
    }

    static func selectingSubtitlesOnly(
        in value: DownloadConfiguration
    ) -> DownloadConfiguration {
        var result = value
        result.requestKind = .subtitlesOnly
        result.thumbnailBehavior = .none
        return normalized(result)
    }

    static func normalized(_ value: AppSettings) -> AppSettings {
        var result = value
        result.automaticRetryCount = min(5, max(0, value.automaticRetryCount))
        result.sponsorBlock = result.sponsorBlock.normalized()
        if [.separate, .separateAndEmbed].contains(result.thumbnailBehavior) {
            result.thumbnailBehavior = .none
        }
        if !enabledVideoCodecs(for: result.defaultMode).contains(
            result.preferredVideoCodec
        ) {
            result.preferredVideoCodec = .automatic
        }
        if !enabledAudioCodecs(for: result.defaultMode).contains(
            result.preferredAudioCodec
        ) {
            result.preferredAudioCodec = result.defaultMode == .audioOnly
                ? .original
                : .automatic
        }
        if !enabledContainers(
            for: result.defaultMode,
            audioCodec: result.preferredAudioCodec,
            videoCodec: result.preferredVideoCodec
        ).contains(result.preferredContainer) {
            result.preferredContainer = .automatic
        }
        if result.preferredVideoCodec == .automatic
            || result.defaultMode == .audioOnly {
            result.defaultFrameRate = .preserve
        } else if !enabledFrameRates.contains(result.defaultFrameRate) {
            result.defaultFrameRate = .preserve
        }
        if ConversionCapabilityMatrix.audio(
            result.preferredAudioCodec
        ) == nil {
            result.defaultSampleRate = .preserve
            result.loudnessNormalization = false
        } else if !enabledSampleRates.contains(result.defaultSampleRate) {
            result.defaultSampleRate = .preserve
        }
        let rates = enabledAudioBitRates(
            for: result.preferredAudioCodec
        )
        if !rates.isEmpty,
           !rates.contains(result.defaultAudioBitrateKbps) {
            result.defaultAudioBitrateKbps =
                rates.contains(192) ? 192 : rates[0]
        }
        result.preserveHDR = result.defaultMode != .audioOnly
        if !enabledSubtitleDeliveries.contains(result.subtitleDelivery) {
            result.subtitleDelivery = .none
        }
        if [.embed, .burnIn].contains(result.subtitleDelivery)
            && result.defaultMode == .audioOnly {
            result.subtitleDelivery = .none
        }
        if !enabledThumbnailBehaviors(
            for: result.configuration()
        ).contains(result.thumbnailBehavior) {
            result.thumbnailBehavior = .none
        }
        return result
    }

    static func validate(
        _ configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws {
        if !(configuration.metadataSidecars ?? []).isEmpty {
            guard [.appDocuments, .filesFolder].contains(configuration.destination),
                  configuration.bundleStyle == .mediaOnly,
                  !configuration.isSubtitlesOnly,
                  configuration.thumbnailBehavior != .thumbnailOnly else {
                throw OutputCompatibilityError.incompatibleContainer("Extra sidecars require a media download to Illucet or a Files folder, without a package.")
            }
        }
        guard normalized(configuration) == configuration else {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        if configuration.isSubtitlesOnly {
            guard configuration.destination.supportsSubtitlesOnly else {
                throw SubtitlePipelineError.subtitlesOnlyDestination
            }
            guard [.sidecarVTT, .sidecarSRT].contains(
                configuration.subtitleDelivery
            ) else {
                throw SubtitlePipelineError.unsupportedDelivery
            }
            _ = try SubtitleSelectionPlanner.plans(
                configuration: configuration,
                metadata: metadata
            )
            return
        }
        if configuration.thumbnailBehavior == .thumbnailOnly {
            try validateThumbnailSelection(
                configuration,
                metadata: metadata
            )
            return
        }
        _ = try SubtitleSelectionPlanner.plans(
            configuration: configuration,
            metadata: metadata
        )
        if configuration.thumbnailBehavior.embeds || configuration.thumbnailBehavior == .includeVideoThumbnail {
            try validateThumbnailSelection(
                configuration,
                metadata: metadata
            )
        }
        _ = try FormatSelection.selectedSourceFacts(
            configuration: configuration,
            metadata: metadata
        )
        let plan = try makePlan(
            configuration: configuration,
            metadata: metadata
        )
        if configuration.thumbnailBehavior == .includeVideoThumbnail,
           (configuration.mode == .audioOnly || plan.container != .mp4) {
            throw OutputCompatibilityError.incompatibleContainer("Embedded video thumbnails require MP4. Choose MP4 or turn off Include Thumbnail.")
        }
        if [
            ExportDestination.photos,
            .filesAndPhotos,
        ].contains(configuration.destination) {
            guard configuration.mode != .audioOnly,
                  [.mp4, .mov].contains(plan.container),
                  let videoCodec = plan.expectedVideoCodec,
                  [.h264, .hevc].contains(videoCodec)
            else {
                throw IllucetError.photosIncompatible
            }
        }
        if [.packageFolder, .zip].contains(configuration.bundleStyle),
           configuration.destination != .appDocuments
            && configuration.destination != .filesFolder {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        if configuration.writeChapters, !metadata.chapters.isEmpty {
            _ = try ChapterWorkflow.normalized(
                metadata.chapters,
                durationSeconds: metadata.durationSeconds
            )
        }
        if configuration.splitChapters {
            guard !metadata.chapters.isEmpty
                    || configuration.sponsorBlock
                        .hasSelectedChapterIntent,
                  configuration.subtitleDelivery == .none,
                  configuration.destination == .appDocuments
                    || configuration.destination == .filesFolder,
                  [.mp4, .mov].contains(plan.container),
                  let codec = plan.expectedVideoCodec,
                  [.h264, .hevc].contains(codec)
            else {
                throw OutputCompatibilityError.unsupportedConfiguration
            }
        }
        if configuration.trimStartSeconds != nil
            || configuration.trimEndSeconds != nil {
            let start = configuration.trimStartSeconds ?? 0
            let end = configuration.trimEndSeconds
            let sponsorBlockComposesTimeline = configuration.sponsorBlock
                .hasSelectedOutputMutation
            guard configuration.subtitleDelivery == .none,
                  sponsorBlockComposesTimeline
                    || (!configuration.preserveChapters
                        && !configuration.writeChapters
                        && !configuration.splitChapters),
                  [.mp4, .mov].contains(plan.container),
                  let codec = plan.expectedVideoCodec,
                  [.h264, .hevc].contains(codec),
                  start >= 0,
                  end.map({ $0 > start }) ?? true,
                  metadata.durationSeconds.map({ duration in
                      start < duration
                        && (end.map { $0 <= duration + 0.05 } ?? true)
                  }) ?? true
            else {
                throw OutputCompatibilityError.unsupportedConfiguration
            }
        }
        if configuration.subtitleDelivery == .embed,
           SubtitleEmbeddingWorkflow.codec(for: plan.container) == nil {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        if configuration.subtitleDelivery == .burnIn {
            guard [.mp4, .mov].contains(plan.container),
                  let codec = plan.expectedVideoCodec,
                  [.h264, .hevc].contains(codec),
                  plan.expectedHDR != true,
                  (configuration.subtitleSelections?.count ?? 0)
                    <= SubtitleBurnInRenderer.maximumTrackCount
            else {
                throw OutputCompatibilityError.unsupportedConfiguration
            }
        }
    }

    private static func normalizeTrim(
        _ value: inout DownloadConfiguration
    ) {
        let hasRange = value.trimStartSeconds != nil
            || value.trimEndSeconds != nil
        guard hasRange else {
            value.trimMode = nil
            return
        }
        let start = value.trimStartSeconds ?? 0
        let valid = value.mode != .audioOnly
            && value.thumbnailBehavior != .thumbnailOnly
            && start.isFinite
            && start >= 0
            && (value.trimEndSeconds?.isFinite ?? true)
            && (value.trimEndSeconds.map { $0 > start } ?? true)
        guard valid else {
            value.trimStartSeconds = nil
            value.trimEndSeconds = nil
            value.trimMode = nil
            return
        }
        value.trimStartSeconds = start
        value.trimMode = value.trimMode ?? .accurate
        value.subtitleDelivery = .none
        value.subtitleSelections = nil
        value.subtitleLanguages = []
        value.includeAutomaticSubtitles = false
        if !value.sponsorBlock.hasSelectedOutputMutation {
            value.preserveChapters = false
            value.writeChapters = false
            value.splitChapters = false
        }
    }

    static func validateSourceProbes(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata,
        probesByFormatID: [String: MediaProbeResult]
    ) throws {
        for formatID in Set(configuration.selectedFormatIDs) {
            guard
                let format = metadata.formats.first(where: {
                    $0.formatID == formatID
                }),
                let probe = probesByFormatID[formatID]
            else {
                throw OutputCompatibilityError.sourceProbeMismatch(
                    "A selected source could not be matched to its native probe."
                )
            }
            if format.hasVideo != (probe.videoStreamCount > 0)
                || format.hasAudio != (probe.audioStreamCount > 0) {
                throw OutputCompatibilityError.sourceProbeMismatch(
                    "Format \(formatID) contains different stream types than the extractor reported."
                )
            }
            if let expected = OutputConversionPlanner.mediaCodec(
                format.videoCodec
            ), !probe.streams.contains(where: {
                $0.kind == .video
                    && !$0.disposition.attachedPicture
                    && expected.matches(probeCodec: $0.codecName)
            }) {
                throw OutputCompatibilityError.sourceProbeMismatch(
                    "Format \(formatID) has a different video codec than the extractor reported."
                )
            }
            if let expected = OutputConversionPlanner.mediaCodec(
                format.audioCodec
            ), !probe.streams.contains(where: {
                $0.kind == .audio
                    && expected.matches(probeCodec: $0.codecName)
            }) {
                throw OutputCompatibilityError.sourceProbeMismatch(
                    "Format \(formatID) has a different audio codec than the extractor reported."
                )
            }
            if !sourceContainerMatches(format, probe: probe) {
                throw OutputCompatibilityError.sourceProbeMismatch(
                    "Format \(formatID) has a different container than the extractor reported."
                )
            }
        }
    }

    private static func sourceContainerMatches(
        _ format: MediaFormat,
        probe: MediaProbeResult
    ) -> Bool {
        // HLS metadata describes the intended file container. Its downloaded
        // segments may instead be MPEG-TS (RFC 8216 section 3.2); the existing
        // conversion workflow remuxes them into the verified final container.
        // This exception applies only to the exact typed HLS source. Codecs
        // and stream roles above remain mandatory, including for MPEG-TS.
        let formats = Set(probe.formatNames.map { $0.lowercased() })
        if formats.contains("mpegts") {
            return FormatSelection.supportedTransport(format) == .HLSResources
                && ["mp4", "m4a"].contains(format.extension?.lowercased() ?? "")
                && formats == ["mpegts"]
        }
        return OutputConversionPlanner.sourceContainer(for: format)
            .map { $0.matches(formatNames: probe.formatNames) } ?? true
    }

    static func makePlan(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws -> OutputPlan {
        guard !configuration.isSubtitlesOnly else {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        guard normalized(configuration) == configuration else {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        return try OutputConversionPlanner.makePlan(
            configuration: configuration,
            metadata: metadata
        )
    }

    static func mediaContainer(
        _ value: OutputContainerChoice
    ) -> MediaContainer {
        switch value {
        case .automatic: .automatic
        case .mp4: .mp4
        case .mov: .mov
        case .mkv: .matroska
        case .webm: .webM
        case .m4a, .alac: .m4a
        case .mp3: .mp3
        case .opus, .ogg: .ogg
        case .flac: .flac
        case .wav: .wav
        }
    }

    static func containerChoice(
        _ value: MediaContainer
    ) -> OutputContainerChoice {
        switch value {
        case .mp4: .mp4
        case .mov: .mov
        case .matroska: .mkv
        case .webM: .webm
        case .m4a: .m4a
        case .mp3: .mp3
        case .ogg: .ogg
        case .flac: .flac
        case .wav: .wav
        default: .automatic
        }
    }

    private static func normalizeAudioEncoding(
        _ result: inout DownloadConfiguration,
        capability: ConversionCapabilityMatrix.AudioCapability
    ) {
        guard !capability.isLossless else {
            result.audioBitrateKbps = nil
            result.audioRateControl = nil
            result.audioQuality = nil
            return
        }
        let controls = capability.rateControls
        if !controls.contains(result.resolvedAudioRateControl) {
            result.audioRateControl = controls.first
        } else if result.audioRateControl == nil {
            result.audioRateControl = result.resolvedAudioRateControl
        }
        switch result.resolvedAudioRateControl {
        case .bitRate:
            if !capability.bitRatesKbps.contains(
                result.audioBitrateKbps ?? -1
            ) {
                result.audioBitrateKbps =
                    capability.bitRatesKbps.contains(192)
                        ? 192
                        : capability.bitRatesKbps.first
            }
            result.audioQuality = nil
        case .quality:
            result.audioBitrateKbps = nil
            if result.audioQuality == nil {
                result.audioQuality = .high
            }
        }
    }

    private static func validateThumbnailSelection(
        _ configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws {
        guard !metadata.thumbnails.isEmpty else {
            throw OutputCompatibilityError.invalidFormatSelection
        }
        if let thumbnailID = configuration.thumbnailID,
           !metadata.thumbnails.contains(where: {
               $0.id == thumbnailID
           }) {
            throw OutputCompatibilityError.invalidFormatSelection
        }
        guard ThumbnailService.supportedOutputFormats.contains(
            configuration.thumbnailFormat
        ) else {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
    }
}

enum OutputCompatibilityError: LocalizedError, Equatable, Sendable {
    case unsupportedConfiguration
    case invalidFormatSelection
    case incompatibleContainer(String)
    case sourceProbeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration:
            "One or more selected output options are not available in this build."
        case .invalidFormatSelection:
            "The selected format IDs do not provide the streams required by this output mode."
        case let .incompatibleContainer(reason):
            reason
        case let .sourceProbeMismatch(reason):
            reason
        }
    }
}
