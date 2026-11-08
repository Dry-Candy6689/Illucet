import Foundation

/// Executable conversion capabilities backed by the pinned native archive.
///
/// This type describes encoders and muxers only. Source stream-copy behavior
/// remains in `OutputCapabilityMatrix`, which consumes these rules when a
/// request requires conversion.
enum ConversionCapabilityMatrix {
    struct AudioCapability: Equatable, Sendable {
        let codec: AudioCodecPreference
        let nativeCodec: MediaCodec
        let containers: [OutputContainerChoice]
        let rateControls: [AudioRateControlChoice]
        let bitRatesKbps: [Int]
        let isLossless: Bool
        let supportsArtworkIn: [OutputContainerChoice]
    }

    struct VideoCapability: Equatable, Sendable {
        let codec: VideoCodecPreference
        let nativeCodec: MediaCodec
        let encoderName: String?
        let containers: [OutputContainerChoice]
        let preservesHDR: Bool
        let supportsHDRToSDR: Bool
        let unavailableReason: String?

        var isSelectable: Bool {
            encoderName != nil && unavailableReason == nil
        }
    }

    static let audioCodecs: [AudioCodecPreference] = [
        .aac,
        .mp3,
        .flac,
        .alac,
        .opus,
        .vorbis,
        .wav,
    ]

    static let selectableVideoCodecs: [VideoCodecPreference] = [
        .h264,
        .hevc,
    ]

    static let unavailableVideoCodecs: [VideoCodecPreference] = [
        .vp9,
        .av1,
    ]

    static let frameRates: [FrameRateChoice] = [
        .preserve,
        .fps24,
        .fps30,
        .fps60,
    ]

    static let sampleRates: [AudioSampleRateChoice] = [
        .preserve,
        .hz44100,
        .hz48000,
    ]

    static let channelChoices: [AudioChannelChoice] = [
        .preserve,
        .mono,
        .stereo,
    ]

    static func audio(
        _ codec: AudioCodecPreference
    ) -> AudioCapability? {
        switch codec {
        case .aac:
            AudioCapability(
                codec: codec,
                nativeCodec: .aac,
                containers: [.m4a, .mov, .mp4, .mkv],
                rateControls: [.bitRate, .quality],
                bitRatesKbps: [64, 96, 128, 160, 192, 256, 320],
                isLossless: false,
                supportsArtworkIn: [.m4a, .mp4]
            )
        case .mp3:
            AudioCapability(
                codec: codec,
                nativeCodec: .mp3,
                containers: [.mp3, .mkv],
                rateControls: [.bitRate, .quality],
                bitRatesKbps: [64, 96, 128, 160, 192, 256, 320],
                isLossless: false,
                supportsArtworkIn: [.mp3]
            )
        case .flac:
            AudioCapability(
                codec: codec,
                nativeCodec: .flac,
                containers: [.flac, .mkv, .ogg],
                rateControls: [],
                bitRatesKbps: [],
                isLossless: true,
                supportsArtworkIn: [.flac]
            )
        case .alac:
            AudioCapability(
                codec: codec,
                nativeCodec: .alac,
                containers: [.m4a, .mov, .mp4, .mkv],
                rateControls: [],
                bitRatesKbps: [],
                isLossless: true,
                supportsArtworkIn: [.m4a, .mp4]
            )
        case .opus:
            AudioCapability(
                codec: codec,
                nativeCodec: .opus,
                containers: [.opus, .ogg, .webm, .mkv],
                rateControls: [.bitRate],
                bitRatesKbps: [48, 64, 96, 128, 160, 192, 256],
                isLossless: false,
                supportsArtworkIn: []
            )
        case .vorbis:
            AudioCapability(
                codec: codec,
                nativeCodec: .vorbis,
                containers: [.ogg, .webm, .mkv],
                rateControls: [.quality],
                bitRatesKbps: [],
                isLossless: false,
                supportsArtworkIn: []
            )
        case .wav:
            AudioCapability(
                codec: codec,
                nativeCodec: .pcmS16LE,
                containers: [.wav, .mov],
                rateControls: [],
                bitRatesKbps: [],
                isLossless: true,
                supportsArtworkIn: []
            )
        case .automatic, .original:
            nil
        }
    }

    static func video(
        _ codec: VideoCodecPreference
    ) -> VideoCapability? {
        switch codec {
        case .h264:
            VideoCapability(
                codec: codec,
                nativeCodec: .h264,
                encoderName: "h264_videotoolbox",
                containers: [.mp4, .mov, .mkv],
                preservesHDR: false,
                supportsHDRToSDR: false,
                unavailableReason: nil
            )
        case .hevc:
            VideoCapability(
                codec: codec,
                nativeCodec: .hevc,
                encoderName: "hevc_videotoolbox",
                containers: [.mp4, .mov, .mkv],
                preservesHDR: true,
                supportsHDRToSDR: false,
                unavailableReason: nil
            )
        case .vp9:
            VideoCapability(
                codec: codec,
                nativeCodec: .vp9,
                encoderName: nil,
                containers: [],
                preservesHDR: false,
                supportsHDRToSDR: false,
                unavailableReason:
                    "The pinned native archive contains a VP9 decoder but no practical iPhone encoder."
            )
        case .av1:
            VideoCapability(
                codec: codec,
                nativeCodec: .av1,
                encoderName: nil,
                containers: [],
                preservesHDR: false,
                supportsHDRToSDR: false,
                unavailableReason:
                    "The pinned native archive contains an AV1 decoder but no practical iPhone encoder."
            )
        case .automatic:
            nil
        }
    }

    static func rateControls(
        for codec: AudioCodecPreference
    ) -> [AudioRateControlChoice] {
        audio(codec)?.rateControls ?? []
    }

    static func bitRatesKbps(
        for codec: AudioCodecPreference
    ) -> [Int] {
        audio(codec)?.bitRatesKbps ?? []
    }

    /// Encoded AAC, Opus, and Vorbis report content-dependent average rates,
    /// especially for very short clips. This still rejects a materially
    /// different request while avoiding false failures for valid native
    /// encoder output.
    static func bitRateToleranceFraction(
        for codec: MediaCodec?
    ) -> Double {
        switch codec {
        case .aac, .opus, .vorbis:
            0.30
        default:
            0.20
        }
    }

    static func supportsArtwork(
        codec: AudioCodecPreference,
        container: OutputContainerChoice
    ) -> Bool {
        audio(codec)?.supportsArtworkIn.contains(container) == true
    }

    static func supportsAudioCopy(
        _ codec: MediaCodec?,
        in container: MediaContainer
    ) -> Bool {
        switch container {
        case .mp4, .mov:
            codec == .aac || codec == .alac || codec == .mp3
        case .matroska:
            codec != nil
        default:
            false
        }
    }
}
