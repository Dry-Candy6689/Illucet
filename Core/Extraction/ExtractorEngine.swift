import Foundation

protocol ExtractorEngine: Sendable {
    func versions() async throws -> ExtractorVersions
    func analyze(url: URL) async throws -> MediaMetadata
    func analyzeForDownload(url: URL, allowRecent: Bool) async throws -> DownloadAnalysis
    func cancel(requestID: UInt64)
}

/// An in-process handoff only; never part of a persisted job or metadata record.
struct DownloadAnalysis: Sendable {
    let metadata: MediaMetadata
    let reuseToken: String?
}

extension ExtractorEngine {
    func analyzeForDownload(url: URL, allowRecent: Bool) async throws -> DownloadAnalysis {
        DownloadAnalysis(metadata: try await analyze(url: url), reuseToken: nil)
    }
}

struct ExtractorVersions: Codable, Equatable, Sendable {
    var openSSL: String? = nil
    let python: String
    let ytDLP: String
    let ejs: String
}

struct MediaMetadata: Codable, Equatable, Sendable {
    let canonicalURL: URL
    let videoID: String
    let title: String
    let channel: String?
    let uploader: String?
    let durationSeconds: Double?
    let uploadDate: String?
    let description: String?
    let isLive: Bool
    let liveStatus: String?
    let thumbnails: [MediaThumbnail]
    let chapters: [ExtractedChapter]
    let subtitles: [MediaSubtitleTrack]
    let formats: [MediaFormat]

    enum CodingKeys: String, CodingKey {
        case canonicalURL = "canonical_url"
        case videoID = "video_id"
        case title
        case channel
        case uploader
        case durationSeconds = "duration_seconds"
        case uploadDate = "upload_date"
        case description
        case isLive = "is_live"
        case liveStatus = "live_status"
        case thumbnails
        case chapters
        case subtitles
        case formats
    }
}

struct MediaThumbnail: Codable, Equatable, Sendable {
    let url: URL
    let width: Int?
    let height: Int?
    let id: String?
}

struct ExtractedChapter: Codable, Equatable, Sendable {
    let title: String?
    let startTimeSeconds: Double
    let endTimeSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case title
        case startTimeSeconds = "start_time_seconds"
        case endTimeSeconds = "end_time_seconds"
    }
}

struct MediaSubtitleTrack: Codable, Equatable, Sendable {
    let trackID: String
    let language: String
    let name: String?
    let automatic: Bool
    let formats: [MediaSubtitleFormat]

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case language
        case name
        case automatic
        case formats
    }
}

struct MediaSubtitleFormat: Codable, Equatable, Sendable {
    let formatID: String
    let url: URL
    let `extension`: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case url
        case `extension`
        case name
    }
}

struct MediaFormat: Codable, Equatable, Sendable {
    var extractorPreferenceRank: Int? = nil
    let formatID: String
    let formatNote: String?
    let `extension`: String?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let resolution: String?
    let framesPerSecond: Double?
    let dynamicRange: String?
    let isHDR: Bool
    let audioBitrateKbps: Double?
    let videoBitrateKbps: Double?
    let totalBitrateKbps: Double?
    let exactFileSizeBytes: Int64?
    let approximateFileSizeBytes: Int64?
    let hasVideo: Bool
    let hasAudio: Bool
    let protocolName: String?
    let sourceType: String
    let language: String?

    var fileSize: Int64? {
        exactFileSizeBytes ?? approximateFileSizeBytes
    }

    /// The extractor's semantic user-facing `p` quality tier, with one
    /// bounded orientation-independent geometry fallback. Raw width and
    /// height remain unchanged for exact format identity.
    var pResolution: Int? {
        if let semantic = Self.semanticPResolution(in: formatNote)
            ?? Self.semanticPResolution(in: resolution) {
            return semantic
        }
        let width = Self.boundedGeometryDimension(width)
        let height = Self.boundedGeometryDimension(height)
        return switch (width, height) {
        case let (.some(width), .some(height)):
            min(width, height)
        case let (.some(width), nil):
            width
        case let (nil, .some(height)):
            height
        case (nil, nil):
            nil
        }
    }

    private static let minimumPResolution = 144
    private static let maximumPResolution = 16_384

    private static func semanticPResolution(in value: String?) -> Int? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 112 || bytes[index] == 80 {
            var start = index
            while start > bytes.startIndex {
                let preceding = bytes[bytes.index(before: start)]
                guard (48...57).contains(preceding) else { break }
                start = bytes.index(before: start)
            }
            let digits = bytes[start..<index]
            guard !digits.isEmpty, digits.count <= 5,
                  let tier = Int(String(decoding: digits, as: UTF8.self)),
                  (minimumPResolution...maximumPResolution).contains(tier)
            else {
                continue
            }
            return tier
        }
        return nil
    }

    private static func boundedGeometryDimension(_ value: Int?) -> Int? {
        guard let value,
              (1...maximumPResolution).contains(value)
        else {
            return nil
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case extractorPreferenceRank = "extractor_preference_rank"
        case formatID = "format_id"
        case formatNote = "format_note"
        case `extension`
        case container
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case width
        case height
        case resolution
        case framesPerSecond = "frames_per_second"
        case dynamicRange = "dynamic_range"
        case isHDR = "is_hdr"
        case audioBitrateKbps = "audio_bitrate_kbps"
        case videoBitrateKbps = "video_bitrate_kbps"
        case totalBitrateKbps = "total_bitrate_kbps"
        case exactFileSizeBytes = "exact_file_size_bytes"
        case approximateFileSizeBytes = "approximate_file_size_bytes"
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
        case protocolName = "protocol"
        case sourceType = "source_type"
        case language
    }
}

struct JavaScriptChallengeCounts: Codable, Equatable, Sendable {
    let n: Int
    let sig: Int
}

struct JavaScriptProviderEvidence: Codable, Equatable, Sendable {
    let ytDLPVersion: String
    let ejsVersion: String
    let quickJSVersion: String
    let providerKey: String
    let providerRegistered: Bool
    let externalJSRuntimesEnabled: Bool
    let remoteComponentsEnabled: Bool
    let challengeProviderUsed: Bool
    let challengeRequestCount: Int
    let challengeResponseCount: Int
    let formatCount: Int
    let warningCount: Int
    let errorCount: Int
    let challengeTypes: [String]
    let providerConstructedCount: Int
    let providerAvailableCount: Int
    let providerAvailable: Bool
    let bulkSolveCallCount: Int
    let challengeRequestCounts: JavaScriptChallengeCounts
    let challengeResponseCounts: JavaScriptChallengeCounts
    let runtimeCallCount: Int
    let runtimeErrorCount: Int
    let runtimeCancellationCount: Int
    let runtimeTimeoutCount: Int
    let providerFailureCount: Int
    let ejsCoreSHA3512: String?
    let ejsLibrarySHA3512: String?
    let formatInventorySHA256: String

    enum CodingKeys: String, CodingKey {
        case ytDLPVersion = "yt_dlp_version"
        case ejsVersion = "ejs_version"
        case quickJSVersion = "quickjs_version"
        case providerKey = "provider_key"
        case providerRegistered = "provider_registered"
        case externalJSRuntimesEnabled = "external_js_runtimes_enabled"
        case remoteComponentsEnabled = "remote_components_enabled"
        case challengeProviderUsed = "challenge_provider_used"
        case challengeRequestCount = "challenge_request_count"
        case challengeResponseCount = "challenge_response_count"
        case formatCount = "format_count"
        case warningCount = "warning_count"
        case errorCount = "error_count"
        case challengeTypes = "challenge_types"
        case providerConstructedCount = "provider_constructed_count"
        case providerAvailableCount = "provider_available_count"
        case providerAvailable = "provider_available"
        case bulkSolveCallCount = "bulk_solve_call_count"
        case challengeRequestCounts = "challenge_request_counts"
        case challengeResponseCounts = "challenge_response_counts"
        case runtimeCallCount = "runtime_call_count"
        case runtimeErrorCount = "runtime_error_count"
        case runtimeCancellationCount = "runtime_cancellation_count"
        case runtimeTimeoutCount = "runtime_timeout_count"
        case providerFailureCount = "provider_failure_count"
        case ejsCoreSHA3512 = "ejs_core_sha3_512"
        case ejsLibrarySHA3512 = "ejs_library_sha3_512"
        case formatInventorySHA256 = "format_inventory_sha256"
    }
}

struct LiveMetadataExtraction: Codable, Equatable, Sendable {
    let metadata: MediaMetadata
    let providerEvidence: JavaScriptProviderEvidence
    var reuseToken: String? = nil

    enum CodingKeys: String, CodingKey {
        case metadata
        case providerEvidence = "provider_evidence"
        case reuseToken = "reuse_token"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(providerEvidence, forKey: .providerEvidence)
    }
}
