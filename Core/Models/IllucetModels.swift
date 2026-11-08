import Foundation

enum DownloadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case videoAndAudio = "Video + Audio"
    case audioOnly = "Audio Only"
    case videoOnly = "Video Only"

    var id: String { rawValue }

    var effectiveOutputIdentity: EffectiveOutputIdentity {
        switch self {
        case .videoAndAudio: .videoAndAudio
        case .audioOnly: .audioOnly
        case .videoOnly: .videoOnly
        }
    }

    var systemImage: String {
        effectiveOutputIdentity.systemImage
    }

    var conciseDescription: String {
        switch self {
        case .videoAndAudio: "A complete, playable video"
        case .audioOnly: "Keep or convert the audio track"
        case .videoOnly: "Picture only, with zero audio streams"
        }
    }
}

enum EffectiveOutputIdentity: String, Codable, CaseIterable, Identifiable,
    Sendable
{
    case thumbnailOnly = "Thumbnail Only"
    case subtitlesOnly = "Subtitles Only"
    case audioOnly = "Audio Only"
    case videoOnly = "Video Only"
    case videoAndAudio = "Video + Audio"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .thumbnailOnly: "photo"
        case .subtitlesOnly: "captions.bubble"
        case .audioOnly: "waveform"
        case .videoOnly: "video"
        case .videoAndAudio: "play.rectangle.on.rectangle"
        }
    }

    static let implementedRequestCases: [Self] = [
        .videoAndAudio,
        .audioOnly,
        .videoOnly,
        .thumbnailOnly,
        .subtitlesOnly,
    ]
}

enum DownloadRequestKind: String, Codable, Sendable {
    case subtitlesOnly
}

enum DownloadModeAvailability: Equatable, Sendable {
    case unverified
    case available
    case unavailable(reason: String)

    var permitsSelection: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

enum SourceModeAvailability: Equatable, Sendable {
    case unverified
    case analyzed(hasVideo: Bool, hasAudio: Bool)

    init(analyzedMetadata: MediaMetadata?) {
        guard let analyzedMetadata else {
            self = .unverified
            return
        }
        self = .analyzed(
            hasVideo: analyzedMetadata.formats.contains(where: \.hasVideo),
            hasAudio: analyzedMetadata.formats.contains(where: \.hasAudio)
        )
    }

    func status(for mode: DownloadMode) -> DownloadModeAvailability {
        guard case let .analyzed(hasVideo, hasAudio) = self else {
            return .unverified
        }
        switch mode {
        case .audioOnly:
            return hasAudio
                ? .available
                : .unavailable(
                    reason:
                        "This analyzed source has no usable audio stream for Audio Only."
                )
        case .videoOnly:
            return hasVideo
                ? .available
                : .unavailable(
                    reason:
                        "This analyzed source has no usable video stream for Video Only."
                )
        case .videoAndAudio:
            if hasVideo, hasAudio { return .available }
            if !hasVideo, !hasAudio {
                return .unavailable(
                    reason:
                        "This analyzed source has no usable video or audio streams for Video + Audio."
                )
            }
            return .unavailable(
                reason: hasVideo
                    ? "This analyzed source has no usable audio stream for Video + Audio."
                    : "This analyzed source has no usable video stream for Video + Audio."
            )
        }
    }
}

enum DownloadPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case best = "Best"
    case compatible = "Compatible"
    case small = "Small"
    case audio = "Audio"
    case custom = "Custom"

    var id: String { rawValue }
}

enum VideoCodecPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Auto"
    case h264 = "H.264"
    case hevc = "HEVC / H.265"
    case av1 = "AV1"
    case vp9 = "VP9"

    var id: String { rawValue }
}

enum AudioCodecPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Auto"
    case original = "Original"
    case aac = "AAC"
    case mp3 = "MP3"
    case opus = "Opus"
    case vorbis = "Ogg Vorbis"
    case flac = "FLAC"
    case alac = "ALAC"
    case wav = "WAV"

    var id: String { rawValue }
}

enum OutputContainerChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Auto"
    case mp4 = "MP4"
    case mov = "MOV"
    case mkv = "MKV"
    case webm = "WebM"
    case m4a = "M4A"
    case mp3 = "MP3"
    case opus = "Opus"
    case ogg = "OGG"
    case flac = "FLAC"
    case alac = "ALAC"
    case wav = "WAV"

    var id: String { rawValue }
}

enum FrameRateChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve = "Preserve"
    case fps24 = "24 fps"
    case fps30 = "30 fps"
    case fps60 = "60 fps"

    var id: String { rawValue }

    var value: Double? {
        switch self {
        case .preserve: nil
        case .fps24: 24
        case .fps30: 30
        case .fps60: 60
        }
    }
}

enum AudioSampleRateChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve = "Preserve"
    case hz44100 = "44.1 kHz"
    case hz48000 = "48 kHz"

    var id: String { rawValue }

    var value: Int? {
        switch self {
        case .preserve: nil
        case .hz44100: 44_100
        case .hz48000: 48_000
        }
    }
}

enum AudioChannelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve = "Preserve"
    case mono = "Mono"
    case stereo = "Stereo"

    var id: String { rawValue }
}

enum AudioRateControlChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case bitRate = "Bitrate"
    case quality = "Quality"

    var id: String { rawValue }
}

enum AudioQualityChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case high = "High"
    case highest = "Highest"

    var id: String { rawValue }

    var nativeValue: Int {
        switch self {
        case .standard: 50
        case .high: 75
        case .highest: 100
        }
    }
}

enum ThumbnailBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case separate = "Download separately"
    case embed = "Embed when supported"
    case separateAndEmbed = "Separate and embed"
    case thumbnailOnly = "Save thumbnail only"
    case includeVideoThumbnail = "Include video thumbnail"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "Off"
        case .separate: "Save separate image"
        case .embed: "Embed in audio file"
        case .separateAndEmbed: "Embed in audio + save image"
        case .thumbnailOnly: "Thumbnail only"
        case .includeVideoThumbnail: "Include Thumbnail"
        }
    }

    var downloadsSeparately: Bool {
        self == .separate || self == .separateAndEmbed || self == .thumbnailOnly
    }

    var embeds: Bool {
        self == .embed || self == .separateAndEmbed
    }
}

enum ThumbnailFormatChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case jpeg = "JPEG"
    case png = "PNG"
    case webp = "WebP"

    var id: String { rawValue }
}

enum SubtitleDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "No subtitles"
    case sidecarSRT = "Sidecar SRT"
    case sidecarVTT = "Sidecar VTT"
    case embed = "Embed"
    case burnIn = "Burn into video"

    var id: String { rawValue }
}

enum BundleStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case mediaOnly = "Media file only"
    case mediaAndThumbnail = "Media + thumbnail"
    case packageFolder = "Package folder"
    case zip = "ZIP package"

    var id: String { rawValue }
}

enum MediaTrimMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fastKeyframe = "Fast (keyframe)"
    case accurate = "Accurate"

    var id: String { rawValue }
}

enum PlaylistBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case referencedVideo = "Referenced video only"
    case selectItems = "Select playlist items"
    case entirePlaylist = "Entire playlist"

    var id: String { rawValue }
}

enum ExportDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case appDocuments = "Illucet"
    case filesFolder = "Files folder"
    case photos = "Photos"
    case filesAndPhotos = "Files + Photos"
    case share = "Share after completion"
    case askEveryTime = "Ask Every Time"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appDocuments: "lock.doc"
        case .filesFolder: "folder"
        case .photos: "photo.on.rectangle"
        case .filesAndPhotos: "square.stack.3d.up"
        case .share: "square.and.arrow.up"
        case .askEveryTime: "questionmark.folder"
        }
    }

    var supportsSubtitlesOnly: Bool {
        switch self {
        case .appDocuments, .filesFolder, .share:
            true
        case .photos, .filesAndPhotos, .askEveryTime:
            false
        }
    }
}

enum DuplicateHandling: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask = "Ask"
    case skip = "Skip"
    case overwrite = "Overwrite"
    case addNumber = "Add number"
    case addVideoID = "Add video ID"

    var id: String { rawValue }
}

enum ExportAssetKind: String, Codable, Equatable, Sendable {
    case video
    case audio
    case image
}

enum ExportOutcome: String, Codable, Equatable, Sendable {
    case file
    case photos
    case filesAndPhotos
    case sharePending
    case shared
    case shareCancelled
    case shareFailed
    case shareUnconfirmed
    case duplicateSkipped
}

enum ShareCompletionState: String, Codable, Equatable, Sendable {
    case unconfirmed
    case pending
    case completed
    case cancelled
    case failed
}

struct SharePresentationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let jobID: UUID
    let title: String
    let fileURLs: [URL]
    let outcome = ShareOutcomeArbiter()

    init(jobID: UUID, title: String, fileURLs: [URL]) {
        id = jobID
        self.jobID = jobID
        self.title = title
        self.fileURLs = fileURLs
    }
}

struct DuplicateConflict: Equatable, Identifiable, Sendable {
    let id: UUID
    let jobID: UUID
    let videoID: String
    let desiredURL: URL
    let playlistItemID: String?

    init(
        id: UUID = UUID(),
        jobID: UUID,
        videoID: String,
        desiredURL: URL,
        playlistItemID: String?
    ) {
        self.id = id
        self.jobID = jobID
        self.videoID = videoID
        self.desiredURL = desiredURL
        self.playlistItemID = playlistItemID
    }

    init(
        id: UUID = UUID(),
        job: DownloadJob,
        desiredURL: URL
    ) {
        self.id = id
        jobID = job.id
        videoID = job.videoID
        self.desiredURL = desiredURL
        playlistItemID = job.playlistItemID
    }
}

enum PendingUserPresentation: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case duplicate(UUID)
        case share(UUID)
        case network(UUID)
    }

    case duplicate(DuplicateConflict)
    case share(SharePresentationRequest)
    case network(NetworkAccessRequest)

    var id: ID {
        switch self {
        case let .duplicate(conflict):
            .duplicate(conflict.id)
        case let .share(request):
            .share(request.jobID)
        case let .network(request):
            .network(request.id)
        }
    }

    var jobID: UUID {
        switch self {
        case let .duplicate(conflict):
            conflict.jobID
        case let .share(request):
            request.jobID
        case let .network(request):
            request.jobID
        }
    }
}

struct PendingUserPresentationQueue: Equatable, Sendable {
    private(set) var requests: [PendingUserPresentation] = []

    var current: PendingUserPresentation? {
        requests.first
    }

    var count: Int {
        requests.count
    }

    var isEmpty: Bool {
        requests.isEmpty
    }

    mutating func enqueue(_ request: PendingUserPresentation) {
        if let index = requests.firstIndex(where: {
            $0.id == request.id
        }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    @discardableResult
    mutating func dequeueCurrent(
        id: PendingUserPresentation.ID
    ) -> PendingUserPresentation? {
        guard requests.first?.id == id else { return nil }
        return requests.removeFirst()
    }

    @discardableResult
    mutating func remove(
        id: PendingUserPresentation.ID
    ) -> PendingUserPresentation? {
        guard let index = requests.firstIndex(where: {
            $0.id == id
        }) else {
            return nil
        }
        return requests.remove(at: index)
    }

    mutating func removeDuplicateRequests(jobID: UUID) {
        requests.removeAll {
            guard case let .duplicate(conflict) = $0 else {
                return false
            }
            return conflict.jobID == jobID
        }
    }

    mutating func removeRequests(jobID: UUID) {
        requests.removeAll { $0.jobID == jobID }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark = "Dark"
    case light = "Light"
    case system = "System"

    var id: String { rawValue }
}

enum CardDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfortable = "Comfortable"
    case compact = "Compact"

    var id: String { rawValue }
}

enum UpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case nightly = "Nightly"
    case stable = "Stable"
    case master = "Master"

    var id: String { rawValue }
    var title: String { self == .nightly ? "Nightly (Recommended)" : rawValue }

    var releaseRepository: String {
        switch self {
        case .nightly: "yt-dlp-nightly-builds"
        case .stable: "yt-dlp"
        case .master: "yt-dlp-master-builds"
        }
    }
}

enum FormatSelectionProvenance: String, Codable, Sendable {
    case automatic
    case manual
}

struct DownloadConfiguration: Codable, Equatable, Sendable {
    var metadataSidecars: Set<MetadataSidecarKind>? = nil
    var speedLimitBytesPerSecond: Int64? = nil
    var waitForCharging: Bool? = nil
    var wifiOnly: Bool? = nil
    var accountID: UUID? = nil
    var requestKind: DownloadRequestKind? = nil
    var mode: DownloadMode
    var preset: DownloadPreset
    var selectedVideoFormatID: String?
    var selectedAudioFormatID: String?
    var formatSelectionProvenance: FormatSelectionProvenance? = nil
    var maximumResolution: Int?
    var preserveSourceResolution: Bool
    var frameRate: FrameRateChoice
    var preserveHDR: Bool
    var convertHDRToSDR: Bool
    var videoCodec: VideoCodecPreference
    var audioCodec: AudioCodecPreference
    var container: OutputContainerChoice
    var audioBitrateKbps: Int?
    var audioRateControl: AudioRateControlChoice?
    var audioQuality: AudioQualityChoice?
    var sampleRate: AudioSampleRateChoice
    var channels: AudioChannelChoice
    var loudnessNormalization: Bool
    var thumbnailBehavior: ThumbnailBehavior
    var thumbnailFormat: ThumbnailFormatChoice
    var cropArtworkSquare: Bool
    var thumbnailID: String?
    var savesThumbnailSeparately: Bool {
        thumbnailBehavior.downloadsSeparately
            || (thumbnailBehavior == .includeVideoThumbnail && bundleStyle == .mediaAndThumbnail)
    }
    var subtitleDelivery: SubtitleDelivery
    var subtitleLanguages: Set<String>
    var includeAutomaticSubtitles: Bool
    var subtitleSelections: [SubtitleTrackSelection]? = nil
    var preserveChapters: Bool
    var writeChapters: Bool
    var splitChapters: Bool
    var bundleStyle: BundleStyle
    var playlistBehavior: PlaylistBehavior
    var maximumPlaylistItems: Int
    var continuePlaylistOnError: Bool
    var numberPlaylistFilenames: Bool
    var destination: ExportDestination
    var filenameTemplate: String
    var trimStartSeconds: Double?
    var trimEndSeconds: Double?
    var trimMode: MediaTrimMode? = nil
    private var sponsorBlockPolicy: SponsorBlockPolicy? = nil

    static let standard = Self(
        mode: .videoAndAudio,
        preset: .compatible,
        selectedVideoFormatID: nil,
        selectedAudioFormatID: nil,
        maximumResolution: nil,
        preserveSourceResolution: true,
        frameRate: .preserve,
        preserveHDR: true,
        convertHDRToSDR: false,
        videoCodec: .automatic,
        audioCodec: .automatic,
        container: .automatic,
        audioBitrateKbps: 192,
        audioRateControl: .bitRate,
        audioQuality: .high,
        sampleRate: .preserve,
        channels: .preserve,
        loudnessNormalization: false,
        thumbnailBehavior: .separateAndEmbed,
        thumbnailFormat: .original,
        cropArtworkSquare: true,
        thumbnailID: nil,
        subtitleDelivery: .none,
        subtitleLanguages: [],
        includeAutomaticSubtitles: false,
        preserveChapters: true,
        writeChapters: true,
        splitChapters: false,
        bundleStyle: .mediaOnly,
        playlistBehavior: .referencedVideo,
        maximumPlaylistItems: 25,
        continuePlaylistOnError: true,
        numberPlaylistFilenames: true,
        destination: .appDocuments,
        filenameTemplate: "{title}",
        trimStartSeconds: nil,
        trimEndSeconds: nil,
        trimMode: nil
    )

    var resolvedTrimMode: MediaTrimMode {
        trimMode ?? .accurate
    }

    var sponsorBlock: SponsorBlockPolicy {
        get { sponsorBlockPolicy ?? .disabled }
        set {
            let normalized = newValue.normalized()
            sponsorBlockPolicy = normalized.isPristineDisabled
                ? nil
                : normalized
        }
    }

    var hasMediaTimeline: Bool { !isSubtitlesOnly && thumbnailBehavior != .thumbnailOnly }

    var effectiveSponsorBlock: SponsorBlockPolicy {
        hasMediaTimeline ? sponsorBlock : .disabled
    }

    var selectedFormatIDs: [String] {
        [selectedVideoFormatID, selectedAudioFormatID].compactMap { $0 }
    }

    var shouldRefreshAutomaticFormatSelection: Bool {
        formatSelectionProvenance == .automatic || selectedFormatIDs.isEmpty
    }

    var explicitlyRemovesAudio: Bool {
        mode == .videoOnly
    }

    var effectiveOutputIdentity: EffectiveOutputIdentity {
        if requestKind == .subtitlesOnly { return .subtitlesOnly }
        if thumbnailBehavior == .thumbnailOnly { return .thumbnailOnly }
        return mode.effectiveOutputIdentity
    }

    var isSubtitlesOnly: Bool {
        requestKind == .subtitlesOnly
    }

    func sourceModeAvailability(
        in analyzedMetadata: MediaMetadata?
    ) -> DownloadModeAvailability {
        if effectiveOutputIdentity == .thumbnailOnly
            || effectiveOutputIdentity == .subtitlesOnly {
            return .available
        }
        return SourceModeAvailability(
            analyzedMetadata: analyzedMetadata
        ).status(for: mode)
    }

    var resolvedAudioRateControl: AudioRateControlChoice {
        audioRateControl ?? .bitRate
    }

    var resolvedAudioQuality: AudioQualityChoice {
        audioQuality ?? .high
    }

    var needsConversion: Bool {
        if convertHDRToSDR || frameRate != .preserve || loudnessNormalization {
            return true
        }
        switch mode {
        case .videoAndAudio:
            return videoCodec != .automatic || audioCodec != .automatic
        case .audioOnly:
            return ![.automatic, .original].contains(audioCodec)
        case .videoOnly:
            return videoCodec != .automatic
        }
    }
}

enum DownloadJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case waitingForNetwork
    case waitingForWiFi
    case waitingForCellularApproval
    case waitingForRetry
    case waitingForPower
    case running
    case paused
    case needsAttention
    case failed
    case cancelled
    case completed

    var isTerminal: Bool {
        self == .failed || self == .cancelled || self == .completed
    }
}

enum DownloadStage: String, Codable, CaseIterable, Hashable, Sendable {
    case analyzing = "Analyzing"
    case preparing = "Preparing"
    case downloadingVideo = "Downloading video"
    case downloadingAudio = "Downloading audio"
    case downloadingThumbnail = "Downloading thumbnail"
    case downloadingSubtitles = "Downloading subtitles"
    case verifyingSources = "Verifying source files"
    case merging = "Merging"
    case converting = "Converting"
    case embeddingMetadata = "Embedding metadata"
    case embeddingSubtitles = "Embedding subtitles"
    case burningInSubtitles = "Burning in subtitles"
    case trimming = "Trimming"
    case removingSponsorSegments = "Removing SponsorBlock segments"
    case writingChapters = "Writing chapters"
    case splittingChapters = "Splitting chapters"
    case packaging = "Building package"
    case zipping = "Creating ZIP"
    case verifyingOutput = "Verifying output"
    case savingFiles = "Saving to Files"
    case savingPhotos = "Saving to Photos"
    case cleaningUp = "Cleaning up"
    case complete = "Complete"
    case waiting = "Waiting"
    case waitingForTransfer = "Waiting for download slot"
    case waitingForProcessing = "Waiting for processing slot"
    case waitingForBackgroundTime = "Waiting for background time"
    case waitingToRetry = "Waiting to retry"
    case restoring = "Restoring transfer"

    var presentsTransferMetrics: Bool {
        switch self {
        case .downloadingVideo, .downloadingAudio, .downloadingThumbnail,
             .downloadingSubtitles, .restoring:
            true
        default:
            false
        }
    }
}

struct JobProgress: Codable, Equatable, Sendable {
    var bytesDownloaded: Int64
    /// Bytes already published into completed source files or atomically
    /// verified range staging. `nil` means a legacy/one-GET transfer cannot
    /// distinguish reusable bytes from URLSession's in-flight byte count.
    var verifiedReusableBytes: Int64? = nil
    var totalBytes: Int64?
    var instantaneousBytesPerSecond: Double?
    var smoothedBytesPerSecond: Double?
    var downloadETASeconds: Double?
    var processingFraction: Double?
    var processingETASeconds: Double?
    var overallFraction: Double?
    var overallETASeconds: Double?
    var currentStream: String?
    var sampleCount: Int

    static let zero = Self(
        bytesDownloaded: 0,
        verifiedReusableBytes: 0,
        totalBytes: nil,
        instantaneousBytesPerSecond: nil,
        smoothedBytesPerSecond: nil,
        downloadETASeconds: nil,
        processingFraction: nil,
        processingETASeconds: nil,
        overallFraction: 0,
        overallETASeconds: nil,
        currentStream: nil,
        sampleCount: 0
    )
}

enum ForegroundResumeReason: String, Codable, Sendable {
    case processingTime, legacyPlayback
}

struct DownloadJob: Codable, Equatable, Identifiable, Sendable {
    var retryRequestID: UUID? = nil
    var transferRecoveryCount: Int? = nil
    let id: UUID
    let sourceURL: URL
    let videoID: String
    var title: String
    var channel: String?
    var thumbnailURL: URL?
    let createdAt: Date
    var updatedAt: Date
    var configuration: DownloadConfiguration
    var state: DownloadJobState
    var stage: DownloadStage
    var progress: JobProgress
    var priority: Int
    var retryCount: Int
    var foregroundResumeReason: ForegroundResumeReason? = nil
    var retryExhausted: Bool? = nil
    var maximumRetries: Int
    var errorCode: String?
    var errorMessage: String?
    var outputURL: URL?
    var outputReferences: SavedOutputReferences? = nil
    var outputProbe: MediaProbeResult?
    var metadataSidecars: [MetadataSidecarRecord]? = nil
    var subtitleSidecars: [SubtitleSidecarRecord]? = nil
    var chapterOutputs: [ChapterOutputRecord]? = nil
    var packageURL: URL? = nil
    var selectedFormatIDs: [String]
    var extractorVersion: String?
    var exportOutcome: ExportOutcome? = nil
    var photosAssetLocalIdentifiers: [String]? = nil
    var shareCompletionState: ShareCompletionState? = nil
    var shareErrorMessage: String? = nil
    var playlistItemID: String? = nil
    var networkAuthorization: JobNetworkAuthorization? = nil
    var transferLimitOverride: Bool? = nil
    var retryAvailableAt: Date? = nil
    var lastRetryReason: DownloadRetryReason? = nil
    var pipelineCheckpoint: DownloadPipelineCheckpoint? = nil
    var activeTransferDescriptors: [StreamTransferDescriptor]? = nil
    var resumableTransferStage: DownloadStage? = nil
    var batchMembership: BatchJobMembership? = nil
    var sponsorBlockApplication: SponsorBlockApplicationRecord? = nil

    var resumesOnForeground: Bool {
        state == .needsAttention && (foregroundResumeReason != nil
            || errorCode == "playback_requires_foreground"
            || errorCode == "background_processing_expired")
    }

    var displaySubtitle: String {
        if let errorMessage, state == .failed || state == .needsAttention {
            return errorMessage
        }
        if state == .queued {
            return "Ready to start"
        }
        if state == .paused {
            return "Download paused"
        }
        return stage.rawValue
    }

    var effectiveOutputIdentity: EffectiveOutputIdentity {
        configuration.effectiveOutputIdentity
    }
}

struct ChapterOutputRecord: Codable, Equatable, Sendable {
    let title: String
    let startSeconds: Double
    let endSeconds: Double
    let filename: String
    var localURL: URL?
}

struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let jobID: UUID
    let videoID: String
    let title: String
    let channel: String?
    let completedAt: Date
    let mode: DownloadMode
    let destination: ExportDestination
    let status: DownloadJobState
    var fileURL: URL?
    var outputReferences: SavedOutputReferences? = nil
    let thumbnailURL: URL?
    var configuration: DownloadConfiguration
    let probe: MediaProbeResult?
    let errorMessage: String?
    var exportOutcome: ExportOutcome?
    let photosAssetLocalIdentifiers: [String]?
    var shareCompletionState: ShareCompletionState?
    var shareErrorMessage: String?
    var metadataSidecars: [MetadataSidecarRecord]? = nil
    var subtitleSidecars: [SubtitleSidecarRecord]? = nil
    var chapterOutputs: [ChapterOutputRecord]? = nil
    var packageURL: URL? = nil
    let batchMembership: BatchJobMembership?
    let sponsorBlockApplication: SponsorBlockApplicationRecord?
    var shareUpdatedAt: Date? = nil
    var publicationRevision: Int? = nil
    var publicationReceipts: [ExportPublicationReceipt]? = nil

    init(job: DownloadJob) {
        id = UUID()
        jobID = job.id
        videoID = job.videoID
        title = job.title
        channel = job.channel
        completedAt = job.updatedAt
        mode = job.configuration.mode
        destination = job.configuration.destination
        status = job.state
        fileURL = job.outputURL
        outputReferences = job.outputReferences
        thumbnailURL = job.thumbnailURL
        configuration = job.configuration
        probe = job.outputProbe
        errorMessage = job.errorMessage
        exportOutcome = job.exportOutcome
        photosAssetLocalIdentifiers = job.photosAssetLocalIdentifiers
        shareCompletionState = job.shareCompletionState
        shareErrorMessage = job.shareErrorMessage
        metadataSidecars = job.metadataSidecars
        subtitleSidecars = job.subtitleSidecars
        chapterOutputs = job.chapterOutputs
        packageURL = job.packageURL
        batchMembership = job.batchMembership
        sponsorBlockApplication = job.sponsorBlockApplication
        shareUpdatedAt = job.shareCompletionState == nil ? nil : job.updatedAt
        publicationRevision = job.pipelineCheckpoint?.publicationRevision
        publicationReceipts = job.pipelineCheckpoint?.publicationReceipts
    }

    var savedToPhotos: Bool {
        !(photosAssetLocalIdentifiers ?? []).isEmpty
    }

    var isThumbnailOnly: Bool {
        effectiveOutputIdentity == .thumbnailOnly
    }

    var isSubtitlesOnly: Bool {
        effectiveOutputIdentity == .subtitlesOnly
    }

    var effectiveOutputIdentity: EffectiveOutputIdentity {
        configuration.effectiveOutputIdentity
    }

    var ownedFileURLs: [URL] {
        var URLs = fileURL.map { [$0] } ?? []
        URLs.append(
            contentsOf: (subtitleSidecars ?? []).compactMap(\.localURL)
        )
        URLs.append(
            contentsOf: (chapterOutputs ?? []).compactMap(\.localURL)
        )
        if let packageURL { URLs.append(packageURL) }
        URLs.append(contentsOf: (metadataSidecars ?? []).map(\.localURL))
        var seen: Set<URL> = []
        return URLs.filter { seen.insert($0).inserted }
    }
}

struct RecentLink: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let title: String
    let thumbnailURL: URL?
    let analyzedAt: Date

    init(url: URL, title: String, thumbnailURL: URL?, analyzedAt: Date = .now) {
        id = UUID()
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.analyzedAt = analyzedAt
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var pip: PipPreferences? = nil
    var downloadExperience: DownloadExperiencePreferences? = nil
    var clipboard: ClipboardPreferences? = nil
    var sharedLinks: SharedLinkPreferences? = nil
    var shortcuts: ShortcutPreferences? = nil
    var waitForCharging: Bool? = nil
    var defaultMode: DownloadMode
    var defaultPreset: DownloadPreset
    var maximumResolution: Int?
    var defaultFrameRate: FrameRateChoice
    var preferredVideoCodec: VideoCodecPreference
    var preferredAudioCodec: AudioCodecPreference
    var preferredContainer: OutputContainerChoice
    var defaultAudioBitrateKbps: Int
    var preserveHDR: Bool
    var preferSmallerFiles: Bool
    var thumbnailBehavior: ThumbnailBehavior
    var subtitleDelivery: SubtitleDelivery
    var cropArtworkSquare: Bool? = nil
    var preserveChapters: Bool
    var preserveMetadata: Bool
    var defaultDestination: ExportDestination
    var askBeforeCellular: Bool
    var wifiOnly: Bool
    var maximumSimultaneousDownloads: Int
    var maximumSimultaneousProcessingJobs: Int
    var automaticRetryCount: Int
    var duplicateHandling: DuplicateHandling
    var filenameTemplate: String
    var keepTemporaryFilesAfterFailure: Bool
    var automaticallyCleanTemporaryFiles: Bool
    var preferStreamCopy: Bool
    var preferVideoToolbox: Bool
    var fastStartMP4: Bool
    var defaultSampleRate: AudioSampleRateChoice
    var loudnessNormalization: Bool
    var appearance: AppearanceMode
    var cardDensity: CardDensity
    var showAdvancedData: Bool
    var accentColor: AppAccentColor? = nil
    var oledDarkBackground: Bool? = nil
    var tapTabToScrollToTop: Bool? = nil
    var reduceMotion: Bool
    var keepScreenAwake: Bool
    var notifyDownloadComplete: Bool
    var notifyProcessingComplete: Bool
    var notifyFailure: Bool
    var notifyNeedsAttention: Bool
    var notifyLowStorage: Bool
    var notifyUpdates: Bool
    var notifyPlaylistComplete: Bool? = nil
    var notifyRetryExhausted: Bool? = nil
    var liveActivities: Bool
    var automaticUpdateChecks: Bool
    // Legacy persisted key: preserve it for older snapshot readers. Installation
    // is always explicit; this value does not enable automatic installation.
    var automaticUpdateInstallation: Bool
    var updateChannel: UpdateChannel
    var minimumFreeSpaceReserveBytes: Int64
    var autoCleanupDays: Int
    var largeDownloadWarningBytes: Int64
    var logLevel: DiagnosticLogLevel
    var downloadSpeedLimitBytesPerSecond: Int64?
    private var sponsorBlockPolicy: SponsorBlockPolicy? = nil
    private var sponsorBlockDiagnosticLogging: Bool? = nil

    static let defaults = Self(
        defaultMode: .videoAndAudio,
        defaultPreset: .compatible,
        maximumResolution: nil,
        defaultFrameRate: .preserve,
        preferredVideoCodec: .automatic,
        preferredAudioCodec: .automatic,
        preferredContainer: .automatic,
        defaultAudioBitrateKbps: 192,
        preserveHDR: true,
        preferSmallerFiles: false,
        thumbnailBehavior: .includeVideoThumbnail,
        subtitleDelivery: .none,
        preserveChapters: true,
        preserveMetadata: true,
        defaultDestination: .appDocuments,
        askBeforeCellular: true,
        wifiOnly: false,
        maximumSimultaneousDownloads: 2,
        maximumSimultaneousProcessingJobs: 1,
        automaticRetryCount: 1,
        duplicateHandling: .addNumber,
        filenameTemplate: "{title}",
        keepTemporaryFilesAfterFailure: true,
        automaticallyCleanTemporaryFiles: true,
        preferStreamCopy: true,
        preferVideoToolbox: true,
        fastStartMP4: false,
        defaultSampleRate: .preserve,
        loudnessNormalization: false,
        appearance: .system,
        cardDensity: .comfortable,
        showAdvancedData: false,
        reduceMotion: false,
        keepScreenAwake: false,
        notifyDownloadComplete: false,
        notifyProcessingComplete: false,
        notifyFailure: false,
        notifyNeedsAttention: false,
        notifyLowStorage: false,
        notifyUpdates: false,
        notifyPlaylistComplete: false,
        notifyRetryExhausted: false,
        liveActivities: true,
        automaticUpdateChecks: true,
        automaticUpdateInstallation: false,
        updateChannel: .nightly,
        minimumFreeSpaceReserveBytes: 1_073_741_824,
        autoCleanupDays: 7,
        largeDownloadWarningBytes: 536_870_912,
        logLevel: .info,
        downloadSpeedLimitBytesPerSecond: nil
    )

    func configuration() -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = defaultMode
        value.preset = defaultPreset
        value.maximumResolution = maximumResolution
        value.preserveSourceResolution = maximumResolution == nil
        value.frameRate = defaultFrameRate
        value.videoCodec = preferredVideoCodec
        value.audioCodec = preferredAudioCodec
        value.container = preferredContainer
        value.audioBitrateKbps = defaultAudioBitrateKbps
        value.sampleRate = defaultSampleRate
        value.loudnessNormalization = loudnessNormalization
        value.preserveHDR = preserveHDR
        value.thumbnailBehavior = thumbnailBehavior
        value.cropArtworkSquare = cropArtworkSquare ?? (thumbnailBehavior != .thumbnailOnly)
        value.subtitleDelivery = subtitleDelivery
        value.preserveChapters = preserveChapters
        value.writeChapters = preserveChapters
        value.destination = defaultDestination
        value.filenameTemplate = filenameTemplate
        var policy = sponsorBlock
        policy.clearSelection()
        value.sponsorBlock = policy
        return value
    }

    var sponsorBlock: SponsorBlockPolicy {
        get { sponsorBlockPolicy ?? .disabled }
        set {
            var normalized = newValue.normalized()
            normalized.clearSelection()
            sponsorBlockPolicy = normalized.isPristineDisabled
                ? nil
                : normalized
        }
    }

    var sponsorBlockDiagnosticLoggingEnabled: Bool {
        get { sponsorBlockDiagnosticLogging ?? false }
        set {
            sponsorBlockDiagnosticLogging = newValue ? true : nil
        }
    }
}

enum DiagnosticLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case error = "Errors"
    case warning = "Warnings"
    case info = "Info"
    case debug = "Debug"

    var id: String { rawValue }
}

struct StorageSnapshot: Codable, Equatable, Sendable {
    var availableBytes: Int64
    var appDocumentsBytes: Int64
    var temporaryBytes: Int64
    var mediaBytes: Int64
    var breakdown: StorageUsageBreakdown? = nil

    static let empty = Self(
        availableBytes: 0,
        appDocumentsBytes: 0,
        temporaryBytes: 0,
        mediaBytes: 0
    )
}

struct StorageUsageEntry: Codable, Equatable, Sendable, Identifiable {
    let relativePath: String
    let byteCount: Int64
    var jobID: UUID? = nil
    var isCleanupCandidate = false
    var id: String { relativePath }
}

struct StorageUsageBreakdown: Codable, Equatable, Sendable {
    let savedDownloadsBytes: Int64
    let activityLogBytes: Int64
    let otherDocuments: [StorageUsageEntry]
    let temporaryEntries: [StorageUsageEntry]
}

struct UpdateStatus: Codable, Equatable, Sendable {
    var previousYTDLPVersion: String? = nil
    var activeCertifiVersion: String? = nil
    var lastCheckedChannel: UpdateChannel? = nil
    // Nil denotes the bundled build; selected update channel is a separate preference.
    var activeChannel: UpdateChannel? = nil
    var bundledYTDLPVersion: String
    var activeYTDLPVersion: String
    var bundledEJSVersion: String
    var activeEJSVersion: String
    var availableRelease: ExtractorRelease?
    var lastCheckedAt: Date?
    var lastSuccessfulUpdateAt: Date?
    var state: State
    var message: String?

    var activeProfileLabel: String {
        if let activeChannel { return "Installed " + activeChannel.rawValue }
        return "Bundled (" + DependencyVersions.extractorProfile.capitalized + ")"
    }

    var runningChannel: UpdateChannel? {
        activeChannel ?? UpdateChannel.allCases.first {
            $0.rawValue.lowercased() == DependencyVersions.extractorProfile
        }
    }

    enum State: String, Codable, Sendable {
        case idle
        case checking
        case updateAvailable
        case current
        case installationDisabled
        case installing
        case staged
        case testing
        case failed
    }

    static let initial = Self(
        bundledYTDLPVersion: DependencyVersions.ytDLP,
        activeYTDLPVersion: DependencyVersions.ytDLP,
        bundledEJSVersion: DependencyVersions.ejs,
        activeEJSVersion: DependencyVersions.ejs,
        availableRelease: nil,
        lastCheckedAt: nil,
        lastSuccessfulUpdateAt: nil,
        state: .idle,
        message: nil
    )
}

enum IllucetError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case invalidURL
    case unsupportedSite
    case playlistConfirmationRequired
    case noCompatibleFormat
    case mediaURLExpired
    case networkOffline
    case cellularBlocked
    case insufficientStorage(required: Int64, available: Int64)
    case filesDestinationUnavailable
    case photosPermissionDenied
    case photosIncompatible
    case processingUnavailable(String)
    case backgroundTaskExpired
    case userCancelled
    case implementationNotDeviceValidated(String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL: "Paste or enter a media URL."
        case .invalidURL: "That link does not identify a supported video."
        case .unsupportedSite: "This build currently supports YouTube links."
        case .playlistConfirmationRequired:
            "Choose a single item or explicitly configure the playlist."
        case .noCompatibleFormat: "No compatible format matches this selection."
        case .mediaURLExpired: "The media link expired. Analyze it again to retry."
        case .networkOffline: "The network is unavailable."
        case .cellularBlocked: "This job is waiting for Wi-Fi."
        case let .insufficientStorage(required, available):
            "Not enough space. \(required.formatted(.byteCount(style: .file))) is "
                + "required; \(available.formatted(.byteCount(style: .file))) is available."
        case .filesDestinationUnavailable:
            "The selected Files folder is unavailable. Select it again."
        case .photosPermissionDenied:
            "Photos access is unavailable. Choose Files or enable access in Settings."
        case .photosIncompatible:
            "Photos accepts images and compatible MP4 or MOV video using H.264 or HEVC. Choose a compatible conversion, or save this valid output to Files, Illucet, or Share."
        case let .processingUnavailable(reason): reason
        case .backgroundTaskExpired:
            "iOS ended background processing before the job completed."
        case .userCancelled: "The job was cancelled."
        case let .implementationNotDeviceValidated(component):
            "\(component) is implemented but has not been validated on this device."
        case let .internalFailure(message): message
        }
    }
}

/// Portable opaque sRGB color. Missing values preserve the original adaptive palette.
struct AppAccentColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var luminance: Double {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

extension DownloadJob {
    var hasUnknownPublication: Bool {
        pipelineCheckpoint?.publicationReceipts?.contains { $0.state == .committing || $0.state == .outcomeUnknown } == true
    }
}
