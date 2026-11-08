import Foundation

/// Builds one deterministic output plan from a normalized configuration and
/// extractor metadata. Encoder and muxer availability comes exclusively from
/// `ConversionCapabilityMatrix`.
enum OutputConversionPlanner {
    static func makePlan(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata
    ) throws -> OutputPlan {
        let selected = metadata.formats.filter {
            configuration.selectedFormatIDs.contains($0.formatID)
        }
        guard selected.count == Set(configuration.selectedFormatIDs).count,
              !selected.isEmpty else {
            throw OutputCompatibilityError.invalidFormatSelection
        }

        let video = selected.first(where: \.hasVideo)
        let separateAudio = selected.first {
            $0.hasAudio && !$0.hasVideo
        }
        let combined = selected.first {
            $0.hasVideo && $0.hasAudio
        }

        switch configuration.mode {
        case .audioOnly:
            guard
                selected.count == 1,
                let audio = separateAudio ?? combined
            else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            return try audioOnlyPlan(
                configuration: configuration,
                source: audio
            )

        case .videoOnly:
            guard let video, separateAudio == nil else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            return try videoPlan(
                configuration: configuration,
                video: video,
                audio: nil,
                hasSeparateAudio: false,
                sourceContainer: sourceContainer(for: video)
            )

        case .videoAndAudio:
            guard let video else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            let audio = separateAudio ?? combined
            guard let audio else {
                throw OutputCompatibilityError.invalidFormatSelection
            }
            return try videoPlan(
                configuration: configuration,
                video: video,
                audio: audio,
                hasSeparateAudio: separateAudio != nil,
                sourceContainer: combined.flatMap(sourceContainer(for:))
            )
        }
    }

    static func defaultContainer(
        for codec: AudioCodecPreference
    ) -> OutputContainerChoice? {
        ConversionCapabilityMatrix.audio(codec)?.containers.first
    }

    static func fileExtension(
        for choice: OutputContainerChoice,
        audioOnly: Bool
    ) -> String {
        switch choice {
        case .automatic:
            "media"
        case .mp4:
            "mp4"
        case .mov:
            "mov"
        case .mkv:
            "mkv"
        case .webm:
            "webm"
        case .m4a, .alac:
            "m4a"
        case .mp3:
            "mp3"
        case .opus:
            "opus"
        case .ogg:
            "ogg"
        case .flac:
            "flac"
        case .wav:
            "wav"
        }
    }

    static func canMux(
        video: MediaCodec?,
        audio: MediaCodec?,
        in container: MediaContainer
    ) -> Bool {
        switch container {
        case .mp4:
            (video.map {
                [.h264, .hevc, .av1].contains($0)
            } ?? true)
                && (audio.map {
                    [.aac, .alac, .mp3].contains($0)
                } ?? true)
        case .mov:
            (video.map {
                [.h264, .hevc, .av1].contains($0)
            } ?? true)
                && (audio.map {
                    [.aac, .alac, .mp3, .pcmS16LE].contains($0)
                } ?? true)
        case .m4a:
            video == nil && (audio == .aac || audio == .alac)
        case .webM:
            (video.map { [.vp9, .av1].contains($0) } ?? true)
                && (audio.map { [.opus, .vorbis].contains($0) } ?? true)
        case .mp3:
            video == nil && audio == .mp3
        case .flac:
            video == nil && audio == .flac
        case .wav:
            video == nil && audio == .pcmS16LE
        case .ogg:
            video == nil && (audio == .opus || audio == .vorbis)
        case .matroska:
            video != nil || audio != nil
        case .automatic:
            false
        default:
            false
        }
    }

    static func sourceContainer(
        for format: MediaFormat
    ) -> MediaContainer? {
        let values = [format.extension, format.container]
            .compactMap { $0?.lowercased() }
        if values.contains(where: { $0 == "m4a" || $0.hasPrefix("m4a_") }) {
            return .m4a
        }
        if values.contains(where: { $0 == "mp4" || $0.hasPrefix("mp4_") }) {
            return .mp4
        }
        if values.contains(where: { $0 == "mov" || $0.hasPrefix("mov_") }) {
            return .mov
        }
        if values.contains(where: { $0 == "webm" || $0.hasPrefix("webm_") }) {
            return .webM
        }
        if values.contains(where: {
            ["mkv", "matroska", "mka"].contains($0)
        }) {
            return .matroska
        }
        if values.contains("mp3") { return .mp3 }
        if values.contains("flac") { return .flac }
        if values.contains("ogg") || values.contains("opus") { return .ogg }
        if values.contains("wav") { return .wav }
        return nil
    }

    static func mediaCodec(_ rawValue: String?) -> MediaCodec? {
        guard let value = rawValue?.lowercased(), !value.isEmpty else {
            return nil
        }
        if value.contains("avc") || value.contains("h264") {
            return .h264
        }
        if value.contains("hev") || value.contains("hvc")
            || value.contains("h265") {
            return .hevc
        }
        if value.contains("av01") || value == "av1" {
            return .av1
        }
        if value.contains("vp9") || value.contains("vp09") {
            return .vp9
        }
        if value.contains("mp4a") || value.contains("aac") {
            return .aac
        }
        if value.contains("alac") { return .alac }
        if value.contains("flac") { return .flac }
        if value.contains("opus") { return .opus }
        if value.contains("vorbis") { return .vorbis }
        if value.contains("mp3") { return .mp3 }
        if value.contains("pcm") { return .pcmS16LE }
        return MediaCodec(rawValue: value)
    }

    private static func audioOnlyPlan(
        configuration: DownloadConfiguration,
        source: MediaFormat
    ) throws -> OutputPlan {
        let sourceCodec = mediaCodec(source.audioCodec)
        guard let capability = ConversionCapabilityMatrix.audio(
            configuration.audioCodec
        ) else {
            let target = originalAudioContainer(
                codec: sourceCodec,
                source: sourceContainer(for: source)
            )
            return OutputPlan(
                mode: .audioOnly,
                containerChoice: target.choice,
                container: target.container,
                fileExtension: target.extension,
                strategy: .extractOriginalAudio,
                sourceVideoCodec: nil,
                sourceAudioCodec: sourceCodec,
                videoEncodingCodec: nil,
                videoEncodingFrameRate: nil,
                audioEncodingSettings: nil,
                expectedVideoCodec: nil,
                expectedAudioCodec: sourceCodec,
                expectedDimensions: nil,
                expectedFrameRate: nil,
                expectedHDR: nil,
                expectedSampleRate: nil,
                expectedChannelCount: nil,
                expectedAudioBitRate: nil,
                expectedVideoStreams: 0 ... 0,
                expectedAudioStreams: 1 ... 1,
                requireArtwork: false,
                requiresApplePlayback: isApplePlaybackContainer(
                    target.container
                )
            )
        }

        let choice = configuration.container == .automatic
            ? try requiredDefaultContainer(for: configuration.audioCodec)
            : configuration.container
        guard capability.containers.contains(choice) else {
            throw OutputCompatibilityError.incompatibleContainer(
                "\(configuration.audioCodec.rawValue) cannot be encoded in \(choice.rawValue)."
            )
        }
        let container = OutputCapabilityMatrix.mediaContainer(choice)
        let settings = audioSettings(
            configuration: configuration,
            capability: capability
        )
        return OutputPlan(
            mode: .audioOnly,
            containerChoice: choice,
            container: container,
            fileExtension: fileExtension(for: choice, audioOnly: true),
            strategy: .transcodeAudio,
            sourceVideoCodec: nil,
            sourceAudioCodec: sourceCodec,
            videoEncodingCodec: nil,
            videoEncodingFrameRate: nil,
            audioEncodingSettings: settings,
            expectedVideoCodec: nil,
            expectedAudioCodec: capability.nativeCodec,
            expectedDimensions: nil,
            expectedFrameRate: nil,
            expectedHDR: nil,
            expectedSampleRate: settings.sampleRate,
            expectedChannelCount: expectedChannelCount(
                settings.channelLayout
            ),
            expectedAudioBitRate: settings.bitRate,
            expectedVideoStreams: 0 ... 0,
            expectedAudioStreams: 1 ... 1,
            requireArtwork: configuration.thumbnailBehavior.embeds,
            requiresApplePlayback: isApplePlaybackContainer(container)
        )
    }

    private static func videoPlan(
        configuration: DownloadConfiguration,
        video: MediaFormat,
        audio: MediaFormat?,
        hasSeparateAudio: Bool,
        sourceContainer: MediaContainer?
    ) throws -> OutputPlan {
        let sourceVideoCodec = mediaCodec(video.videoCodec)
        let sourceAudioCodec = audio.flatMap { mediaCodec($0.audioCodec) }
        let videoCapability = ConversionCapabilityMatrix.video(
            configuration.videoCodec
        )
        let audioCapability = ConversionCapabilityMatrix.audio(
            configuration.audioCodec
        )
        let targetVideoCodec =
            videoCapability?.nativeCodec ?? sourceVideoCodec
        let targetAudioCodec =
            audioCapability?.nativeCodec ?? sourceAudioCodec

        guard targetVideoCodec != nil else {
            throw OutputCompatibilityError.invalidFormatSelection
        }
        if configuration.mode == .videoAndAudio,
           targetAudioCodec == nil {
            throw OutputCompatibilityError.invalidFormatSelection
        }

        let requestedDimensions = encodedDimensions(
            source: video,
            maximumResolution: configuration.maximumResolution,
            conversionSelected: videoCapability != nil
        )
        let changesDimensions =
            requestedDimensions != dimensions(video)
        let changesFrameRate = configuration.frameRate != .preserve
        let needsVideoEncoding = videoCapability != nil
            && (
                sourceVideoCodec != targetVideoCodec
                    || changesDimensions
                    || changesFrameRate
            )
        let needsAudioEncoding = audioCapability != nil

        if needsVideoEncoding, video.isHDR {
            guard videoCapability?.preservesHDR == true else {
                throw OutputCompatibilityError.incompatibleContainer(
                    "HDR-to-\(configuration.videoCodec.rawValue) conversion is unavailable. Choose HEVC or preserve the source."
                )
            }
        }
        if configuration.convertHDRToSDR {
            guard videoCapability?.supportsHDRToSDR == true else {
                throw OutputCompatibilityError.incompatibleContainer(
                    "The pinned native build has no verified HDR-to-SDR conversion path."
                )
            }
        }

        let choice = try resolvedVideoContainer(
            configuration: configuration,
            sourceContainer: sourceContainer,
            videoCodec: targetVideoCodec,
            audioCodec: configuration.mode == .videoOnly
                ? nil
                : targetAudioCodec
        )
        let container = OutputCapabilityMatrix.mediaContainer(choice)
        guard canMux(
            video: targetVideoCodec,
            audio: configuration.mode == .videoOnly
                ? nil
                : targetAudioCodec,
            in: container
        ) else {
            throw OutputCompatibilityError.incompatibleContainer(
                "The selected video and audio codecs cannot be muxed in \(choice.rawValue)."
            )
        }
        if let videoCapability,
           !videoCapability.containers.contains(choice) {
            throw OutputCompatibilityError.incompatibleContainer(
                "\(configuration.videoCodec.rawValue) cannot be encoded in \(choice.rawValue)."
            )
        }
        if let audioCapability,
           !audioCapability.containers.contains(choice) {
            throw OutputCompatibilityError.incompatibleContainer(
                "\(configuration.audioCodec.rawValue) cannot be encoded in \(choice.rawValue)."
            )
        }

        let audioEncodingSettings = audioCapability.map {
            audioSettings(
                configuration: configuration,
                capability: $0
            )
        }
        let strategy: OutputPlan.Strategy
        switch configuration.mode {
        case .videoOnly:
            strategy = needsVideoEncoding
                ? .transcodeVideo
                : .copyVideoOnly
        case .videoAndAudio:
            if needsVideoEncoding || needsAudioEncoding {
                strategy = .assembleConvertedStreams
            } else if hasSeparateAudio {
                strategy = .mergeStreamCopy
            } else {
                strategy = .remuxCombinedStreamCopy
            }
        case .audioOnly:
            preconditionFailure("Audio-only planning has a dedicated path.")
        }

        return OutputPlan(
            mode: configuration.mode,
            containerChoice: choice,
            container: container,
            fileExtension: fileExtension(for: choice, audioOnly: false),
            strategy: strategy,
            sourceVideoCodec: sourceVideoCodec,
            sourceAudioCodec: sourceAudioCodec,
            videoEncodingCodec: needsVideoEncoding
                ? videoCapability?.nativeCodec
                : nil,
            videoEncodingFrameRate: needsVideoEncoding
                ? configuration.frameRate.value
                : nil,
            audioEncodingSettings: needsAudioEncoding
                ? audioEncodingSettings
                : nil,
            expectedVideoCodec: targetVideoCodec,
            expectedAudioCodec: configuration.mode == .videoOnly
                ? nil
                : targetAudioCodec,
            expectedDimensions: needsVideoEncoding
                ? requestedDimensions
                : dimensions(video),
            expectedFrameRate: needsVideoEncoding
                ? configuration.frameRate.value
                    ?? video.framesPerSecond
                : video.framesPerSecond,
            expectedHDR: video.isHDR,
            expectedSampleRate: audioEncodingSettings?.sampleRate,
            expectedChannelCount: audioEncodingSettings.map {
                expectedChannelCount($0.channelLayout)
            } ?? nil,
            expectedAudioBitRate: audioEncodingSettings?.bitRate,
            expectedVideoStreams: 1 ... 1,
            expectedAudioStreams: configuration.mode == .videoOnly
                ? 0 ... 0
                : 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: isApplePlaybackContainer(container)
        )
    }

    private static func resolvedVideoContainer(
        configuration: DownloadConfiguration,
        sourceContainer: MediaContainer?,
        videoCodec: MediaCodec?,
        audioCodec: MediaCodec?
    ) throws -> OutputContainerChoice {
        if configuration.container != .automatic {
            return configuration.container
        }
        if configuration.videoCodec == .automatic,
           configuration.audioCodec == .automatic
            || configuration.audioCodec == .original,
           let sourceContainer,
           canMux(
               video: videoCodec,
               audio: audioCodec,
               in: sourceContainer
           ) {
            return OutputCapabilityMatrix.containerChoice(sourceContainer)
        }
        var candidates: [OutputContainerChoice] = [
            .mp4,
            .mov,
            .mkv,
            .webm,
        ]
        if let video = ConversionCapabilityMatrix.video(
            configuration.videoCodec
        ) {
            candidates = candidates.filter {
                video.containers.contains($0)
            }
        }
        if let audio = ConversionCapabilityMatrix.audio(
            configuration.audioCodec
        ) {
            candidates = candidates.filter {
                audio.containers.contains($0)
            }
        }
        if let candidate = candidates.first(where: {
            canMux(
                video: videoCodec,
                audio: audioCodec,
                in: OutputCapabilityMatrix.mediaContainer($0)
            )
        }) {
            return candidate
        }
        throw OutputCompatibilityError.incompatibleContainer(
            "No verified container can hold the selected codec combination."
        )
    }

    private static func originalAudioContainer(
        codec: MediaCodec?,
        source: MediaContainer?
    ) -> (
        choice: OutputContainerChoice,
        container: MediaContainer,
        extension: String
    ) {
        switch codec?.rawValue {
        case MediaCodec.aac.rawValue, MediaCodec.alac.rawValue:
            return (.m4a, .m4a, "m4a")
        case MediaCodec.mp3.rawValue:
            return (.mp3, .mp3, "mp3")
        case MediaCodec.flac.rawValue:
            return (.flac, .flac, "flac")
        case MediaCodec.opus.rawValue, MediaCodec.vorbis.rawValue:
            if source == .ogg {
                return (.ogg, .ogg, "ogg")
            }
            return (.webm, .webM, "webm")
        case MediaCodec.pcmS16LE.rawValue:
            return (.wav, .wav, "wav")
        default:
            if let source {
                let choice = OutputCapabilityMatrix.containerChoice(source)
                return (
                    choice,
                    source,
                    fileExtension(for: choice, audioOnly: true)
                )
            }
            return (.mkv, .matroska, "mka")
        }
    }

    private static func audioSettings(
        configuration: DownloadConfiguration,
        capability: ConversionCapabilityMatrix.AudioCapability
    ) -> AudioEncodingSettings {
        let bitRate: Int64? =
            configuration.resolvedAudioRateControl == .bitRate
                ? configuration.audioBitrateKbps.map {
                    Int64($0 * 1_000)
                }
                : nil
        let quality: AudioEncodingQuality? =
            configuration.resolvedAudioRateControl == .quality
                ? AudioEncodingQuality(
                    value: configuration.resolvedAudioQuality.nativeValue
                )
                : nil
        return AudioEncodingSettings(
            codec: capability.nativeCodec,
            bitRate: bitRate,
            quality: quality,
            sampleRate: configuration.sampleRate.value,
            channelLayout: channelLayout(configuration.channels),
            loudnessNormalization: configuration.loudnessNormalization
                ? LoudnessNormalizationSettings(
                    integratedLoudnessLUFS: -16,
                    loudnessRangeLU: 11,
                    truePeakDBTP: -1.5
                )
                : nil
        )
    }

    private static func encodedDimensions(
        source: MediaFormat,
        maximumResolution: Int?,
        conversionSelected: Bool
    ) -> MediaDimensions? {
        guard
            conversionSelected,
            let sourceWidth = source.width,
            let sourceHeight = source.height,
            sourceWidth > 0,
            sourceHeight > 0,
            let sourceResolution = source.pResolution,
            let maximumResolution,
            maximumResolution > 0,
            sourceResolution > maximumResolution
        else {
            return dimensions(source)
        }
        let scale = Double(maximumResolution) / Double(sourceResolution)
        var width = Int((Double(sourceWidth) * scale).rounded())
        var height = Int((Double(sourceHeight) * scale).rounded())
        if width % 2 != 0 { width -= 1 }
        if height % 2 != 0 { height -= 1 }
        return MediaDimensions(
            width: max(width, 2),
            height: max(height, 2)
        )
    }

    private static func dimensions(
        _ format: MediaFormat
    ) -> MediaDimensions? {
        guard let width = format.width, let height = format.height else {
            return nil
        }
        return MediaDimensions(width: width, height: height)
    }

    private static func channelLayout(
        _ choice: AudioChannelChoice
    ) -> AudioChannelLayoutPolicy {
        switch choice {
        case .preserve: .preserve
        case .mono: .mono
        case .stereo: .stereo
        }
    }

    private static func expectedChannelCount(
        _ layout: AudioChannelLayoutPolicy
    ) -> Int? {
        switch layout {
        case .preserve: nil
        case .mono: 1
        case .stereo: 2
        }
    }

    private static func requiredDefaultContainer(
        for codec: AudioCodecPreference
    ) throws -> OutputContainerChoice {
        guard let value = defaultContainer(for: codec) else {
            throw OutputCompatibilityError.unsupportedConfiguration
        }
        return value
    }

    private static func isApplePlaybackContainer(
        _ container: MediaContainer
    ) -> Bool {
        [.mp4, .mov, .m4a, .mp3, .wav].contains(container)
    }
}

struct OutputPlan: Equatable, Sendable {
    enum Strategy: String, Equatable, Sendable {
        case remuxCombinedStreamCopy
        case mergeStreamCopy
        case extractOriginalAudio
        case transcodeAudio
        case copyVideoOnly
        case transcodeVideo
        case assembleConvertedStreams
    }

    let mode: DownloadMode
    let containerChoice: OutputContainerChoice
    let container: MediaContainer
    let fileExtension: String
    let strategy: Strategy
    let sourceVideoCodec: MediaCodec?
    let sourceAudioCodec: MediaCodec?
    let videoEncodingCodec: MediaCodec?
    let videoEncodingFrameRate: Double?
    let audioEncodingSettings: AudioEncodingSettings?
    let expectedVideoCodec: MediaCodec?
    let expectedAudioCodec: MediaCodec?
    let expectedDimensions: MediaDimensions?
    let expectedFrameRate: Double?
    let expectedHDR: Bool?
    let expectedSampleRate: Int?
    let expectedChannelCount: Int?
    let expectedAudioBitRate: Int64?
    let expectedVideoStreams: ClosedRange<Int>
    let expectedAudioStreams: ClosedRange<Int>
    let requireArtwork: Bool
    let requiresApplePlayback: Bool

    var needsVideoConversion: Bool {
        videoEncodingCodec != nil
    }

    var needsAudioConversion: Bool {
        audioEncodingSettings != nil
    }

    var needsConversion: Bool {
        needsVideoConversion || needsAudioConversion
    }
}
