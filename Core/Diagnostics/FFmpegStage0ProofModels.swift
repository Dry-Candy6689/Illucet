import Foundation

struct FFmpegStage0Proof: Codable, Sendable {
    let ffmpegVersion: String
    let configuration: String
    let outputDirectory: String
    let operations: [FFmpegStage0Operation]
    let outputs: [FFmpegStage0Output]
}

struct FFmpegStage0Operation: Codable, Sendable {
    let id: String
    let status: String
    let progressStage: String
}

struct FFmpegStage0Output: Codable, Sendable {
    let id: String
    let path: String
    let probe: FFmpegStage0Probe
}

struct FFmpegStage0Probe: Codable, Sendable {
    let format: String
    let formatLongName: String
    let duration: Double
    let bitRate: Int64
    let size: Int64
    var verificationClass: String? = nil
    var fullDecodePerformed: Bool? = nil
    var packetsInspected: Int? = nil
    var inspectedPacketBytes: Int64? = nil
    var tailSeekAttempted: Bool? = nil
    var tailSeekSucceeded: Bool? = nil
    var tailSeekReachedEOF: Bool? = nil
    let streamCount: Int
    let videoStreamCount: Int
    let audioStreamCount: Int
    let subtitleStreamCount: Int
    let artworkCount: Int
    let metadata: [String: String]
    var chapterCount: Int? = nil
    var chapters: [FFmpegStage0Chapter]? = nil
    let streams: [FFmpegStage0Stream]
}

struct FFmpegStage0Chapter: Codable, Sendable {
    let start: Double
    let end: Double
    let title: String
}

struct FFmpegStage0Stream: Codable, Sendable {
    let index: Int
    let type: String
    let codec: String
    let codecLongName: String
    let duration: Double
    let bitRate: Int64
    let attachedPicture: Bool
    var isDefault: Bool? = nil
    var forced: Bool? = nil
    let decodedFrames: Int
    var decodedSampleWindows: Int? = nil
    let width: Int
    let height: Int
    let frameRate: Double
    let sampleRate: Int
    let channels: Int
    let channelLayout: String
    var pixelFormat: String? = nil
    var colorSpace: String? = nil
    var colorTransfer: String? = nil
    var colorPrimaries: String? = nil
    var colorRange: String? = nil
    var isHDR: Bool? = nil
    let packetSHA256: String
    let metadata: [String: String]
}

struct FFmpegStage0ProgressEvent: Codable, Sendable {
    let stage: String
    let progress: Double
}

struct FFmpegStage0EvidenceEnvelope: Codable, Sendable {
    let generatedAt: Date
    let validationTarget: String
    let runtimeIdentifier: String
    let operatingSystemVersion: String
    let rawReportSHA256: String
    let proof: FFmpegStage0Proof
    let progressEvents: [FFmpegStage0ProgressEvent]
}
