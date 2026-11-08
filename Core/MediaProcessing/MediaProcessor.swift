import Foundation

/// The Swift boundary around native, in-process media processing.
///
/// Implementations own all native handles and must not expose FFmpeg objects
/// across this boundary. An implementation is also responsible for honoring
/// cooperative `Task` cancellation in addition to explicit `cancel` requests.
protocol MediaProcessor: Sendable {
    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult

    func cancel(operationID: UUID) async
}

extension MediaProcessor {
    /// Explicit complete-media diagnostic proof. Production publication paths
    /// choose a bounded verification class instead of using this helper.
    func probeFullyDecoding(
        _ fileURL: URL
    ) async throws -> MediaProbeResult {
        try await probe(
            fileURL,
            verificationClass: .strongFullDecode
        )
    }
}

typealias MediaProcessingProgressHandler =
    @Sendable (MediaProcessingProgress) -> Void

struct MediaProcessingRequest: Equatable, Sendable {
    let operationID: UUID
    let operation: MediaProcessingOperation
    let destinationURL: URL
    let output: MediaOutputSpecification
    let metadata: MediaTagSet
    let chapters: [MediaChapter]
    let trimming: MediaTrimRange?
    let overwriteExisting: Bool
    let verification: MediaVerificationRequirements
}

enum MediaProcessingOperation: Equatable, Sendable {
    case merge(videoURL: URL, audioURL: URL)
    case remux(inputURL: URL)
    case extractAudio(inputURL: URL)
    case transcodeAudio(inputURL: URL)
    case transcodeVideo(inputURL: URL)
    case removeAudio(inputURL: URL)
    case attachArtwork(mediaURL: URL, artworkURL: URL)
    case embedSubtitles(mediaURL: URL, subtitles: [MediaSubtitleInput])
    case burnSubtitles(mediaURL: URL, cues: [MediaRenderedSubtitleCue])
    case writeChapters(mediaURL: URL)
    case trim(mediaURL: URL, mode: MediaTrimMode)
    case removeRanges(
        mediaURL: URL,
        mode: SponsorBlockRemovalMode,
        keptRanges: [MediaTimeRange]
    )
    case splitChapters(inputURL: URL)

    var inputURLs: [URL] {
        switch self {
        case let .merge(videoURL, audioURL):
            [videoURL, audioURL]
        case let .remux(inputURL),
             let .extractAudio(inputURL),
             let .transcodeAudio(inputURL),
             let .transcodeVideo(inputURL),
             let .removeAudio(inputURL),
             let .writeChapters(mediaURL: inputURL),
             let .trim(mediaURL: inputURL, _),
             let .removeRanges(mediaURL: inputURL, _, _),
             let .splitChapters(inputURL):
            [inputURL]
        case let .attachArtwork(mediaURL, artworkURL):
            [mediaURL, artworkURL]
        case let .embedSubtitles(mediaURL, subtitles):
            [mediaURL] + subtitles.map(\.fileURL)
        case let .burnSubtitles(mediaURL, _):
            [mediaURL]
        }
    }
}

struct MediaOutputSpecification: Equatable, Sendable {
    let container: MediaContainer
    let video: VideoOutputPolicy
    let audio: AudioOutputPolicy
    let dynamicRange: DynamicRangePolicy
    let subtitleCodec: MediaCodec?
    let fastStart: Bool
    let preserveMetadata: Bool
    let preserveChapters: Bool
}

enum VideoOutputPolicy: Equatable, Sendable {
    case copy
    case encode(VideoEncodingSettings)
    case remove
}

struct VideoEncodingSettings: Equatable, Sendable {
    let codec: MediaCodec
    let bitRate: Int64?
    let dimensions: MediaDimensions?
    let frameRate: Double?
    let pixelFormat: String?
    let profile: String?
    let level: String?
    let acceleration: HardwareAccelerationPolicy
}

enum AudioOutputPolicy: Equatable, Sendable {
    case copy
    case encode(AudioEncodingSettings)
    case remove
}

struct AudioEncodingSettings: Equatable, Sendable {
    let codec: MediaCodec
    let bitRate: Int64?
    let quality: AudioEncodingQuality?
    let sampleRate: Int?
    let channelLayout: AudioChannelLayoutPolicy
    let loudnessNormalization: LoudnessNormalizationSettings?

    init(
        codec: MediaCodec,
        bitRate: Int64?,
        quality: AudioEncodingQuality? = nil,
        sampleRate: Int?,
        channelLayout: AudioChannelLayoutPolicy,
        loudnessNormalization: LoudnessNormalizationSettings?
    ) {
        self.codec = codec
        self.bitRate = bitRate
        self.quality = quality
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.loudnessNormalization = loudnessNormalization
    }
}

struct AudioEncodingQuality: Equatable, Sendable {
    let value: Int

    init(value: Int) {
        self.value = min(max(value, 0), 100)
    }
}

enum AudioChannelLayoutPolicy: String, Equatable, Sendable {
    case preserve
    case mono
    case stereo
}

struct LoudnessNormalizationSettings: Equatable, Sendable {
    let integratedLoudnessLUFS: Double
    let loudnessRangeLU: Double
    let truePeakDBTP: Double
}

enum DynamicRangePolicy: String, Equatable, Sendable {
    case preserve
    case convertToSDR
}

enum HardwareAccelerationPolicy: String, Equatable, Sendable {
    case automatic
    case preferVideoToolbox
    case softwareOnly
}

struct MediaCodec: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let aac = Self(rawValue: "aac")
    static let alac = Self(rawValue: "alac")
    static let flac = Self(rawValue: "flac")
    static let h264 = Self(rawValue: "h264")
    static let hevc = Self(rawValue: "hevc")
    static let mp3 = Self(rawValue: "mp3")
    static let opus = Self(rawValue: "opus")
    static let pcmS16LE = Self(rawValue: "pcm_s16le")
    static let vorbis = Self(rawValue: "vorbis")
    static let av1 = Self(rawValue: "av1")
    static let vp9 = Self(rawValue: "vp9")
    static let movText = Self(rawValue: "mov_text")
    static let subRip = Self(rawValue: "subrip")
    static let webVTT = Self(rawValue: "webvtt")
}

struct MediaContainer: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let automatic = Self(rawValue: "auto")
    static let flac = Self(rawValue: "flac")
    static let m4a = Self(rawValue: "m4a")
    static let matroska = Self(rawValue: "matroska")
    static let mov = Self(rawValue: "mov")
    static let mp3 = Self(rawValue: "mp3")
    static let mp4 = Self(rawValue: "mp4")
    static let ogg = Self(rawValue: "ogg")
    static let wav = Self(rawValue: "wav")
    static let webM = Self(rawValue: "webm")
}

struct MediaDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct MediaTrimRange: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double?
}

struct MediaTimeRange: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double { endSeconds - startSeconds }
}

struct MediaTagSet: Codable, Equatable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let comment: String?
    let date: String?
    let genre: String?
    let language: String?
    let description: String?
    let additional: [String: String]

    static let empty = Self(
        title: nil,
        artist: nil,
        album: nil,
        albumArtist: nil,
        comment: nil,
        date: nil,
        genre: nil,
        language: nil,
        description: nil,
        additional: [:]
    )
}

struct MediaSubtitleInput: Codable, Equatable, Sendable {
    let fileURL: URL
    let languageCode: String?
    let title: String?
    let isAutomatic: Bool
    let isDefault: Bool
    let isForced: Bool
}

struct MediaRenderedSubtitleCue: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let trackIndex: Int
}

struct MediaChapter: Codable, Equatable, Sendable {
    let title: String
    let startSeconds: Double
    let endSeconds: Double
}

struct MediaVerificationRequirements: Equatable, Sendable {
    let expectedContainer: MediaContainer?
    let expectedFileExtension: String?
    let expectedVideoStreams: ClosedRange<Int>?
    let expectedAudioStreams: ClosedRange<Int>?
    let expectedSubtitleStreams: ClosedRange<Int>?
    let expectedVideoCodec: MediaCodec?
    let expectedAudioCodec: MediaCodec?
    let expectedDimensions: MediaDimensions?
    let expectedFrameRate: Double?
    let frameRateTolerance: Double
    let expectedHDR: Bool?
    let expectedAudioSampleRate: Int?
    let expectedAudioChannelCount: Int?
    let expectedDurationSeconds: Double?
    let durationToleranceSeconds: Double
    let expectedAudioBitRate: Int64?
    let audioBitRateToleranceFraction: Double
    let expectedChapterCount: ClosedRange<Int>?
    let requireArtwork: Bool?
    let requireMetadataKeys: Set<String>
    let expectedMetadataValues: [String: String]
    let forbiddenMetadataKeys: Set<String>
    let requiredVerificationClass: MediaVerificationClass

    static let basicPlayback = Self(
        expectedContainer: nil,
        expectedFileExtension: nil,
        expectedVideoStreams: nil,
        expectedAudioStreams: nil,
        expectedSubtitleStreams: nil,
        expectedVideoCodec: nil,
        expectedAudioCodec: nil,
        expectedDimensions: nil,
        expectedFrameRate: nil,
        frameRateTolerance: 0.05,
        expectedHDR: nil,
        expectedAudioSampleRate: nil,
        expectedAudioChannelCount: nil,
        expectedDurationSeconds: nil,
        durationToleranceSeconds: 0.5,
        expectedAudioBitRate: nil,
        audioBitRateToleranceFraction: 0.08,
        expectedChapterCount: nil,
        requireArtwork: nil,
        requireMetadataKeys: [],
        expectedMetadataValues: [:],
        forbiddenMetadataKeys: [],
        requiredVerificationClass: .boundedStrong
    )

    func withExpectedDuration(
        _ seconds: Double,
        tolerance: Double
    ) -> Self {
        Self(
            expectedContainer: expectedContainer,
            expectedFileExtension: expectedFileExtension,
            expectedVideoStreams: expectedVideoStreams,
            expectedAudioStreams: expectedAudioStreams,
            expectedSubtitleStreams: expectedSubtitleStreams,
            expectedVideoCodec: expectedVideoCodec,
            expectedAudioCodec: expectedAudioCodec,
            expectedDimensions: expectedDimensions,
            expectedFrameRate: expectedFrameRate,
            frameRateTolerance: frameRateTolerance,
            expectedHDR: expectedHDR,
            expectedAudioSampleRate: expectedAudioSampleRate,
            expectedAudioChannelCount: expectedAudioChannelCount,
            expectedDurationSeconds: seconds,
            durationToleranceSeconds: tolerance,
            expectedAudioBitRate: expectedAudioBitRate,
            audioBitRateToleranceFraction: audioBitRateToleranceFraction,
            expectedChapterCount: expectedChapterCount,
            requireArtwork: requireArtwork,
            requireMetadataKeys: requireMetadataKeys,
            expectedMetadataValues: expectedMetadataValues,
            forbiddenMetadataKeys: forbiddenMetadataKeys,
            requiredVerificationClass: requiredVerificationClass
        )
    }

    func withExpectedChapterCount(_ count: Int) -> Self {
        Self(
            expectedContainer: expectedContainer,
            expectedFileExtension: expectedFileExtension,
            expectedVideoStreams: expectedVideoStreams,
            expectedAudioStreams: expectedAudioStreams,
            expectedSubtitleStreams: expectedSubtitleStreams,
            expectedVideoCodec: expectedVideoCodec,
            expectedAudioCodec: expectedAudioCodec,
            expectedDimensions: expectedDimensions,
            expectedFrameRate: expectedFrameRate,
            frameRateTolerance: frameRateTolerance,
            expectedHDR: expectedHDR,
            expectedAudioSampleRate: expectedAudioSampleRate,
            expectedAudioChannelCount: expectedAudioChannelCount,
            expectedDurationSeconds: expectedDurationSeconds,
            durationToleranceSeconds: durationToleranceSeconds,
            expectedAudioBitRate: expectedAudioBitRate,
            audioBitRateToleranceFraction: audioBitRateToleranceFraction,
            expectedChapterCount: count ... count,
            requireArtwork: requireArtwork,
            requireMetadataKeys: requireMetadataKeys,
            expectedMetadataValues: expectedMetadataValues,
            forbiddenMetadataKeys: forbiddenMetadataKeys,
            requiredVerificationClass: requiredVerificationClass
        )
    }

    func withRequiredVerificationClass(
        _ verificationClass: MediaVerificationClass
    ) -> Self {
        Self(
            expectedContainer: expectedContainer,
            expectedFileExtension: expectedFileExtension,
            expectedVideoStreams: expectedVideoStreams,
            expectedAudioStreams: expectedAudioStreams,
            expectedSubtitleStreams: expectedSubtitleStreams,
            expectedVideoCodec: expectedVideoCodec,
            expectedAudioCodec: expectedAudioCodec,
            expectedDimensions: expectedDimensions,
            expectedFrameRate: expectedFrameRate,
            frameRateTolerance: frameRateTolerance,
            expectedHDR: expectedHDR,
            expectedAudioSampleRate: expectedAudioSampleRate,
            expectedAudioChannelCount: expectedAudioChannelCount,
            expectedDurationSeconds: expectedDurationSeconds,
            durationToleranceSeconds: durationToleranceSeconds,
            expectedAudioBitRate: expectedAudioBitRate,
            audioBitRateToleranceFraction: audioBitRateToleranceFraction,
            expectedChapterCount: expectedChapterCount,
            requireArtwork: requireArtwork,
            requireMetadataKeys: requireMetadataKeys,
            expectedMetadataValues: expectedMetadataValues,
            forbiddenMetadataKeys: forbiddenMetadataKeys,
            requiredVerificationClass: verificationClass
        )
    }
}

enum MediaVerificationClass: String, Codable, Equatable, Sendable {
    case fastStructural
    case boundedStrong
    case strongFullDecode

    func satisfies(_ required: Self) -> Bool {
        switch (self, required) {
        case (.strongFullDecode, _),
             (.boundedStrong, .boundedStrong),
             (.boundedStrong, .fastStructural),
             (.fastStructural, .fastStructural):
            true
        case (.fastStructural, .boundedStrong),
             (.fastStructural, .strongFullDecode),
             (.boundedStrong, .strongFullDecode):
            false
        }
    }
}

struct MediaProcessingProgress: Equatable, Sendable {
    let operationID: UUID
    let stage: MediaProcessingStage
    let completedFraction: Double?
    let processedMediaSeconds: Double?
    let totalMediaSeconds: Double?
    let processedBytes: Int64?
    let estimatedRemainingSeconds: Double?
}

enum MediaProcessingStage: String, Codable, Equatable, Sendable {
    case preparing
    case readingInput
    case decoding
    case filtering
    case encoding
    case muxing
    case writingMetadata
    case attachingArtwork
    case embeddingSubtitles
    case writingChapters
    case writingTrailer
    case probing
    case verifying
    case finalizing
}

struct MediaProcessingResult: Equatable, Sendable {
    let operationID: UUID
    let outputURLs: [URL]
    let probes: [MediaProbeResult]
    let usedStreamCopy: Bool
    let usedHardwareAcceleration: Bool
    let usedSoftwareFallback: Bool
    let videoEncoderName: String?
    let appliedLoudnessNormalization: Bool
    let elapsedSeconds: Double
    var appliedTimeRanges: [MediaTimeRange]? = nil
}

struct MediaProbeResult: Codable, Equatable, Sendable {
    let fileURL: URL
    let formatNames: [String]
    let formatLongName: String?
    let durationSeconds: Double?
    let startTimeSeconds: Double?
    let bitRate: Int64?
    let fileSize: Int64
    let metadata: [String: String]
    let streams: [MediaStreamProbe]
    let chapters: [MediaChapter]
    var verificationEvidence: MediaProbeEvidence? = nil

    var videoStreamCount: Int {
        streams.count { $0.kind == .video && !$0.disposition.attachedPicture }
    }

    var audioStreamCount: Int {
        streams.count { $0.kind == .audio }
    }

    var subtitleStreamCount: Int {
        streams.count { $0.kind == .subtitle }
    }

    func verifyAudioVideoSync(toleranceSeconds: Double) throws {
        guard videoStreamCount == 1, audioStreamCount == 1 else { return }
        guard toleranceSeconds.isFinite, toleranceSeconds >= 0,
              let videoDuration = streams.first(where: {
                  $0.kind == .video && !$0.disposition.attachedPicture
              })?.durationSeconds,
              let audioDuration = streams.first(where: {
                  $0.kind == .audio
              })?.durationSeconds,
              videoDuration.isFinite,
              audioDuration.isFinite,
              abs(videoDuration - audioDuration) <= toleranceSeconds
        else {
            throw MediaProcessorError.verificationMismatch(
                "The edited audio and video timelines are not synchronized."
            )
        }
    }
}

enum SourceRelativeVideoBitRate {
    static func resolve(
        inputProbe: MediaProbeResult,
        expectedCodec: MediaCodec?,
        expectedDimensions: MediaDimensions?,
        expectedFrameRate: Double?,
        frameRateTolerance: Double = 0.12
    ) -> Int64? {
        guard let expectedCodec,
              let expectedDimensions,
              let expectedFrameRate,
              expectedFrameRate.isFinite,
              expectedFrameRate > 0,
              frameRateTolerance.isFinite,
              frameRateTolerance >= 0,
              let stream = inputProbe.streams.first(where: {
                  $0.kind == .video && !$0.disposition.attachedPicture
              }),
              expectedCodec.matches(probeCodec: stream.codecName),
              stream.video?.width == expectedDimensions.width,
              stream.video?.height == expectedDimensions.height,
              let sourceFrameRate = stream.video?.averageFrameRate?.doubleValue,
              sourceFrameRate.isFinite,
              abs(sourceFrameRate - expectedFrameRate) <= frameRateTolerance,
              let bitRate = stream.bitRate,
              bitRate > 0
        else {
            return nil
        }
        return bitRate
    }
}

struct MediaProbeEvidence: Codable, Equatable, Sendable {
    let verificationClass: MediaVerificationClass
    let fullDecodePerformed: Bool
    let packetsInspected: Int64
    let inspectedPacketBytes: Int64
    let tailInspectionAttempted: Bool
    let tailInspectionSucceeded: Bool
    let tailInspectionReachedEOF: Bool
}

struct MediaStreamProbe: Codable, Equatable, Sendable {
    let index: Int
    let kind: MediaStreamKind
    let codecName: String?
    let codecLongName: String?
    let codecProfile: String?
    let codecTag: String?
    let durationSeconds: Double?
    let bitRate: Int64?
    let timeBase: MediaRational?
    let disposition: MediaStreamDisposition
    let metadata: [String: String]
    let video: VideoStreamProbe?
    let audio: AudioStreamProbe?
    let subtitle: SubtitleStreamProbe?
    var decodedFrames: Int? = nil
    var decodedSampleWindows: Int? = nil
}

enum MediaStreamKind: String, Codable, Equatable, Sendable {
    case video
    case audio
    case subtitle
    case attachment
    case data
    case unknown
}

struct VideoStreamProbe: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: String?
    let averageFrameRate: MediaRational?
    let realFrameRate: MediaRational?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let colorRange: String?
    let fieldOrder: String?
    let isHDR: Bool
}

struct AudioStreamProbe: Codable, Equatable, Sendable {
    let sampleFormat: String?
    let sampleRate: Int?
    let channelCount: Int?
    let channelLayout: String?
    let bitsPerSample: Int?
}

struct SubtitleStreamProbe: Codable, Equatable, Sendable {
    let languageCode: String?
    let title: String?
    let isAutomatic: Bool
}

struct MediaStreamDisposition: Codable, Equatable, Sendable {
    let isDefault: Bool
    let forced: Bool
    let attachedPicture: Bool
}

struct MediaRational: Codable, Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64

    var doubleValue: Double? {
        guard denominator != 0 else {
            return nil
        }
        return Double(numerator) / Double(denominator)
    }
}

enum MediaProcessorError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case inputUnavailable(URL)
    case outputAlreadyExists(URL)
    case codecUnavailable(MediaCodec)
    case nativeFailure(String)
    case probeFailure(String)
    case verificationMismatch(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(reason):
            "Invalid media-processing request: \(reason)"
        case let .inputUnavailable(url):
            "Media input is unavailable: \(url.lastPathComponent)"
        case let .outputAlreadyExists(url):
            "The output already exists: \(url.lastPathComponent)"
        case let .codecUnavailable(codec):
            "The required codec is unavailable: \(codec.rawValue)"
        case let .nativeFailure(reason):
            "Native media processing failed: \(reason)"
        case let .probeFailure(reason):
            "Output probing failed: \(reason)"
        case let .verificationMismatch(reason):
            "The processed output did not match the request: \(reason)"
        case let .insufficientStorage(requiredBytes, availableBytes):
            "Insufficient storage. Required \(requiredBytes) bytes; "
                + "\(availableBytes) bytes are available."
        case .cancelled:
            "Media processing was cancelled."
        }
    }
}

enum MediaOutputVerifier {
    static func verify(
        _ probe: MediaProbeResult,
        requirements: MediaVerificationRequirements
    ) throws {
        guard let evidence = probe.verificationEvidence else {
            throw MediaProcessorError.verificationMismatch(
                "The media probe did not include verification evidence."
            )
        }
        guard evidence.verificationClass.satisfies(
            requirements.requiredVerificationClass
        ) else {
            throw MediaProcessorError.verificationMismatch(
                "The performed verification class did not satisfy the request."
            )
        }
        let expectedFullDecode = evidence.verificationClass
            == .strongFullDecode
        guard evidence.fullDecodePerformed == expectedFullDecode else {
            throw MediaProcessorError.verificationMismatch(
                "The verification evidence was internally inconsistent."
            )
        }
        guard evidence.packetsInspected > 0,
              evidence.inspectedPacketBytes > 0
        else {
            throw MediaProcessorError.verificationMismatch(
                "The media probe inspected no packet payloads."
            )
        }
        if evidence.verificationClass != .strongFullDecode {
            guard evidence.tailInspectionAttempted,
                  evidence.tailInspectionSucceeded
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The structural probe did not inspect the media tail."
                )
            }
        }
        let primaryStreams = probe.streams.filter {
            ($0.kind == .video && !$0.disposition.attachedPicture)
                || $0.kind == .audio
        }
        switch evidence.verificationClass {
        case .fastStructural:
            break
        case .boundedStrong:
            guard !primaryStreams.isEmpty,
                  primaryStreams.allSatisfy({
                      ($0.decodedFrames ?? 0) > 0
                          && ($0.decodedSampleWindows ?? 0) >= 3
                  })
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The bounded probe did not decode every primary stream in its representative windows."
                )
            }
        case .strongFullDecode:
            guard !primaryStreams.isEmpty,
                  primaryStreams.allSatisfy({
                      ($0.decodedFrames ?? 0) > 0
                  })
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The full probe did not decode every primary stream."
                )
            }
        }
        guard probe.fileSize > 0 else {
            throw MediaProcessorError.verificationMismatch(
                "The processed output is empty."
            )
        }
        if probe.videoStreamCount > 0 || probe.audioStreamCount > 0 {
            guard let duration = probe.durationSeconds,
                  duration.isFinite,
                  duration > 0
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The processed output has no sane finite duration."
                )
            }
        }
        if let container = requirements.expectedContainer,
           !container.matches(formatNames: probe.formatNames) {
            throw MediaProcessorError.verificationMismatch(
                "Expected the \(container.rawValue) container; the probe reported \(probe.formatNames.joined(separator: ", "))."
            )
        }
        if let expectedExtension = requirements.expectedFileExtension {
            let actualExtension = probe.fileURL.pathExtension.lowercased()
            if actualExtension != expectedExtension.lowercased() {
                throw MediaProcessorError.verificationMismatch(
                    "Expected a .\(expectedExtension) file; found .\(actualExtension)."
                )
            }
        }
        if let range = requirements.expectedVideoStreams,
           !range.contains(probe.videoStreamCount) {
            throw MediaProcessorError.verificationMismatch(
                "Expected \(range) video streams; found \(probe.videoStreamCount)."
            )
        }
        if let range = requirements.expectedAudioStreams,
           !range.contains(probe.audioStreamCount) {
            throw MediaProcessorError.verificationMismatch(
                "Expected \(range) audio streams; found \(probe.audioStreamCount)."
            )
        }
        if let range = requirements.expectedSubtitleStreams,
           !range.contains(probe.subtitleStreamCount) {
            throw MediaProcessorError.verificationMismatch(
                "Expected \(range) subtitle streams; found \(probe.subtitleStreamCount)."
            )
        }
        if let codec = requirements.expectedVideoCodec,
           !probe.streams.contains(where: {
               $0.kind == .video
                   && !$0.disposition.attachedPicture
                   && codec.matches(probeCodec: $0.codecName)
           }) {
            throw MediaProcessorError.verificationMismatch(
                "The expected \(codec.rawValue) video codec was not found."
            )
        }
        if let codec = requirements.expectedAudioCodec,
           !probe.streams.contains(where: {
               $0.kind == .audio && codec.matches(probeCodec: $0.codecName)
           }) {
            throw MediaProcessorError.verificationMismatch(
                "The expected \(codec.rawValue) audio codec was not found."
            )
        }
        if let dimensions = requirements.expectedDimensions,
           !probe.streams.contains(where: {
               $0.video?.width == dimensions.width
                   && $0.video?.height == dimensions.height
           }) {
            throw MediaProcessorError.verificationMismatch(
                "The output dimensions do not match the request."
            )
        }
        if let expectedFrameRate = requirements.expectedFrameRate {
            let actual = probe.streams.first(where: {
                $0.kind == .video && !$0.disposition.attachedPicture
            })?.video?.averageFrameRate?.doubleValue
            guard let actual,
                  abs(actual - expectedFrameRate)
                    <= requirements.frameRateTolerance else {
                throw MediaProcessorError.verificationMismatch(
                    "The output frame rate \(actual.map(String.init(describing:)) ?? "unknown") does not match the requested \(expectedFrameRate)."
                )
            }
        }
        if let expectedHDR = requirements.expectedHDR {
            let actual = probe.streams.first(where: {
                $0.kind == .video && !$0.disposition.attachedPicture
            })?.video?.isHDR
            if actual != expectedHDR {
                throw MediaProcessorError.verificationMismatch(
                    "The output dynamic range does not match the request."
                )
            }
        }
        if let expectedSampleRate = requirements.expectedAudioSampleRate {
            let actual = probe.streams.first(where: {
                $0.kind == .audio
            })?.audio?.sampleRate
            if actual != expectedSampleRate {
                throw MediaProcessorError.verificationMismatch(
                    "The output audio sample rate does not match the request."
                )
            }
        }
        if let expectedChannels = requirements.expectedAudioChannelCount {
            let actual = probe.streams.first(where: {
                $0.kind == .audio
            })?.audio?.channelCount
            if actual != expectedChannels {
                throw MediaProcessorError.verificationMismatch(
                    "The output audio channel count does not match the request."
                )
            }
        }
        if let duration = requirements.expectedDurationSeconds {
            guard let actual = probe.durationSeconds,
                  abs(duration - actual)
                    <= requirements.durationToleranceSeconds else {
                throw MediaProcessorError.verificationMismatch(
                    "The output duration differs from the source."
                )
            }
        }
        if let expected = requirements.expectedAudioBitRate {
            let streamBitRate = probe.streams.first(where: {
                $0.kind == .audio
            })?.bitRate
            let audioOnlyContainerBitRate =
                probe.videoStreamCount == 0 && probe.audioStreamCount == 1
                    ? probe.bitRate
                    : nil
            guard
                expected > 0,
                let actual = streamBitRate ?? audioOnlyContainerBitRate
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The encoded audio bitrate could not be verified."
                )
            }
            let difference =
                abs(Double(actual - expected)) / Double(expected)
            guard
                difference
                    <= requirements.audioBitRateToleranceFraction
            else {
                let tolerance = Int(
                    requirements.audioBitRateToleranceFraction * 100
                )
                throw MediaProcessorError.verificationMismatch(
                    "The encoded audio bitrate \(actual) differs from the requested \(expected) by more than \(tolerance)%."
                )
            }
        }
        if let expectedChapters = requirements.expectedChapterCount,
           !expectedChapters.contains(probe.chapters.count) {
            throw MediaProcessorError.verificationMismatch(
                "The output chapter count does not match the request."
            )
        }
        if let artwork = requirements.requireArtwork {
            let hasArtwork = probe.streams.contains {
                $0.disposition.attachedPicture
            }
            if artwork != hasArtwork {
                throw MediaProcessorError.verificationMismatch(
                    "Artwork presence does not match the request."
                )
            }
        }
        var metadata: [String: String] = [:]
        for stream in probe.streams {
            for (key, value) in stream.metadata {
                metadata[key.lowercased()] = value
            }
        }
        for (key, value) in probe.metadata {
            metadata[key.lowercased()] = value
        }
        let metadataKeys = Set(metadata.keys)
        let requiredKeys = Set(
            requirements.requireMetadataKeys.map { $0.lowercased() }
        )
        if !requiredKeys.isSubset(of: metadataKeys) {
            let missing = requiredKeys
                .subtracting(metadataKeys)
                .sorted()
                .joined(separator: ", ")
            throw MediaProcessorError.verificationMismatch(
                "Required metadata is missing: \(missing)."
            )
        }
        for (key, expectedValue) in requirements.expectedMetadataValues {
            let actualValue = metadata[key.lowercased()]
            if actualValue != expectedValue {
                throw MediaProcessorError.verificationMismatch(
                    "Metadata value \(key) does not match the request (actual: \(actualValue ?? "<missing>"))."
                )
            }
        }
        let forbiddenKeys = Set(
            requirements.forbiddenMetadataKeys.map { $0.lowercased() }
        )
        if !forbiddenKeys.isDisjoint(with: metadataKeys) {
            throw MediaProcessorError.verificationMismatch(
                "Metadata requested for removal is still present."
            )
        }
    }
}

extension MediaContainer {
    func matches(formatNames: [String]) -> Bool {
        let names = Set(formatNames.map { $0.lowercased() })
        switch self {
        case .automatic:
            return !names.isEmpty
        case .mp4:
            return names.contains("mp4")
        case .mov:
            return names.contains("mov")
        case .m4a:
            return names.contains("m4a")
        case .matroska:
            return names.contains("matroska")
        case .webM:
            return names.contains("webm")
        case .mp3:
            return names.contains("mp3")
        case .ogg:
            return names.contains("ogg")
        case .flac:
            return names.contains("flac")
        case .wav:
            return names.contains("wav")
        default:
            return names.contains(rawValue.lowercased())
        }
    }
}

extension MediaCodec {
    func matches(probeCodec: String?) -> Bool {
        guard let value = probeCodec?.lowercased() else { return false }
        switch self {
        case .h264:
            return value == "h264" || value.contains("avc")
        case .hevc:
            return value == "hevc" || value == "h265"
        case .aac:
            return value == "aac" || value.contains("mp4a")
        case .vp9:
            return value == "vp9" || value.contains("vp09")
        case .av1:
            return value == "av1" || value.contains("av01")
        default:
            return value == rawValue.lowercased()
        }
    }
}
