import Foundation

struct SubtitleTrackSelection: Codable, Equatable, Hashable, Sendable {
    let trackID: String
    let formatID: String
    let language: String
    let automatic: Bool

    var stableKey: String {
        "\(trackID)|\(formatID)"
    }
}

enum SubtitleSidecarKind: String, Codable, Equatable, Sendable {
    case webVTT = "vtt"
    case subRip = "srt"

    init?(delivery: SubtitleDelivery) {
        switch delivery {
        case .sidecarVTT:
            self = .webVTT
        case .sidecarSRT:
            self = .subRip
        case .embed, .burnIn:
            self = .webVTT
        case .none:
            return nil
        }
    }
}

struct SubtitleSidecarRecord: Codable, Equatable, Sendable {
    let selection: SubtitleTrackSelection
    let kind: SubtitleSidecarKind
    let filename: String
    var localURL: URL?
}

struct SubtitleDownloadPlan: Equatable, Sendable {
    let selection: SubtitleTrackSelection
    let kind: SubtitleSidecarKind
    let transportURL: URL
}

struct PreparedSubtitleSidecar: Equatable, Sendable {
    let selection: SubtitleTrackSelection
    let kind: SubtitleSidecarKind
    let temporaryURL: URL
}

struct SubtitleSidecarExport: Equatable, Sendable {
    let records: [SubtitleSidecarRecord]
    let shareRequest: SharePresentationRequest?
}

struct SubtitleFileSetExport: Equatable, Sendable {
    let records: [SubtitleSidecarRecord]
    let result: ExportResult
}

enum SubtitleResponseClassification: Equatable, Sendable {
    case emptyBody
    case HTMLBody
    case JSONBody
    case XMLBody
    case otherNonWebVTTBody
    case webVTTParserRejected

    var diagnosticCode: String {
        switch self {
        case .emptyBody: "subtitle_empty_response"
        case .HTMLBody: "subtitle_html_response"
        case .JSONBody: "subtitle_json_response"
        case .XMLBody: "subtitle_xml_response"
        case .otherNonWebVTTBody: "subtitle_non_vtt_response"
        case .webVTTParserRejected: "subtitle_webvtt_parser_rejected"
        }
    }

    var message: String {
        switch self {
        case .emptyBody:
            "The subtitle server returned an empty response."
        case .HTMLBody:
            "The subtitle server returned an HTML error page instead of WebVTT."
        case .JSONBody:
            "The subtitle server returned a JSON-like response instead of WebVTT."
        case .XMLBody:
            "The subtitle server returned XML or markup instead of WebVTT."
        case .otherNonWebVTTBody:
            "The subtitle server returned a non-WebVTT response."
        case .webVTTParserRejected:
            "The subtitle response identified itself as WebVTT but did not satisfy the bounded parser."
        }
    }

    var permitsExactTransportRefresh: Bool {
        self != .webVTTParserRejected
    }
}

enum SubtitlePipelineError: LocalizedError, Equatable, Sendable {
    case unsupportedDelivery
    case missingSelection
    case invalidSelection
    case trackUnavailable
    case formatUnavailable
    case photosOnlyDestination
    case subtitlesOnlyDestination
    case unsafeDestination
    case DNSResolutionFailed
    case DNSAnswerChanged
    case tooManyRedirects
    case insecureRedirect
    case expiredTransport
    case HTTPFailure
    case responseTooLarge
    case invalidWebVTT
    case unusableResponse(SubtitleResponseClassification)
    case sidecarCollision
    case exportFailed
    case embeddingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedDelivery:
            "The selected subtitle delivery is not available in this build."
        case .missingSelection:
            "Select at least one reported subtitle track."
        case .invalidSelection:
            "The selected subtitle identity is invalid."
        case .trackUnavailable:
            "The exact selected subtitle track is no longer available."
        case .formatUnavailable:
            "The exact selected WebVTT format is no longer available."
        case .photosOnlyDestination:
            "Subtitle sidecars require Illucet, Files, Files + Photos, or Share."
        case .subtitlesOnlyDestination:
            "Subtitles Only requires Illucet, Files, or Share. Photos destinations cannot store subtitle files."
        case .unsafeDestination:
            "The subtitle host did not satisfy the public HTTPS transport policy."
        case .DNSResolutionFailed:
            "The subtitle host could not be resolved safely."
        case .DNSAnswerChanged:
            "The subtitle host changed addresses during the request."
        case .tooManyRedirects:
            "The subtitle request exceeded the redirect limit."
        case .insecureRedirect:
            "The subtitle request attempted an insecure redirect."
        case .expiredTransport:
            "The selected subtitle URL expired and could not be refreshed."
        case .HTTPFailure:
            "The subtitle server returned an unusable response."
        case .responseTooLarge:
            "The subtitle response exceeded the safe size limit."
        case .invalidWebVTT:
            "The subtitle response was not valid bounded WebVTT."
        case let .unusableResponse(classification):
            classification.message
        case .sidecarCollision:
            "A subtitle sidecar with the required name already exists."
        case .exportFailed:
            "The subtitle sidecar could not be published safely."
        case .embeddingFailed:
            "The selected subtitles could not be embedded and verified."
        }
    }

    var permitsExactTransportRefresh: Bool {
        switch self {
        case .expiredTransport:
            true
        case let .unusableResponse(classification):
            classification.permitsExactTransportRefresh
        default:
            false
        }
    }

    var diagnosticCode: String {
        switch self {
        case .unsupportedDelivery: "subtitle_unsupported_delivery"
        case .missingSelection: "subtitle_missing_selection"
        case .invalidSelection: "subtitle_invalid_selection"
        case .trackUnavailable: "subtitle_track_unavailable"
        case .formatUnavailable: "subtitle_format_unavailable"
        case .photosOnlyDestination: "subtitle_photos_only_destination"
        case .subtitlesOnlyDestination: "subtitle_only_destination"
        case .unsafeDestination: "subtitle_unsafe_destination"
        case .DNSResolutionFailed: "subtitle_dns_resolution_failed"
        case .DNSAnswerChanged: "subtitle_dns_answer_changed"
        case .tooManyRedirects: "subtitle_too_many_redirects"
        case .insecureRedirect: "subtitle_insecure_redirect"
        case .expiredTransport: "subtitle_transport_expired"
        case .HTTPFailure: "subtitle_http_failure"
        case .responseTooLarge: "subtitle_response_too_large"
        case .invalidWebVTT: "subtitle_invalid_webvtt"
        case let .unusableResponse(classification):
            classification.diagnosticCode
        case .sidecarCollision: "subtitle_sidecar_collision"
        case .exportFailed: "subtitle_export_failed"
        case .embeddingFailed: "subtitle_embedding_failed"
        }
    }
}
