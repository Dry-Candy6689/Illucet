import Foundation

enum ExtractionError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedSite
    case cancelled
    case extractorFailure(code: String, message: String, retryable: Bool)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The URL does not identify a supported YouTube video."
        case .unsupportedSite:
            "This extractor currently supports YouTube URLs only."
        case .cancelled:
            "Metadata extraction was cancelled."
        case let .extractorFailure(_, message, _):
            message
        case let .invalidResponse(message):
            "The extractor returned invalid metadata: \(message)"
        }
    }
}

struct LiveExtractionRequest: Encodable, Equatable, Sendable {
    let action = "extract_metadata"
    let url: String
    let download = false
    var retainForDownload = false
    var reuseRecentExtraction = false

    enum CodingKeys: String, CodingKey {
        case action, url, download
        case retainForDownload = "retain_for_download"
        case reuseRecentExtraction = "reuse_recent_extraction"
    }
}

private struct LiveExtractionErrorPayload: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

private struct LiveExtractionEnvelope: Decodable {
    let ok: Bool
    let action: String
    let data: LiveMetadataExtraction?
    let error: LiveExtractionErrorPayload?
}

final class YTDLPExtractorEngine: ExtractorEngine, @unchecked Sendable {
    private let python: PythonEngine
    private let authentication: AccountAuthentication?
    private let contract: LiveExtractorContract

    init(python: PythonEngine, contract: LiveExtractorContract = .bundled, authentication: AccountAuthentication? = nil) {
        self.python = python
        self.authentication = authentication
        self.contract = contract
    }

    func versions() async throws -> ExtractorVersions {
        let response = try await python.execute(
            requestID: PythonRequestIDAllocator.next(),
            requestJSON: #"{"action":"runtime_versions"}"#
        )
        let envelope = try JSONDecoder().decode(
            BridgeEnvelope<RuntimeVersionPayload>.self,
            from: Data(response.utf8)
        )
        return ExtractorVersions(
            openSSL: envelope.data.openSSLVersion,
            python: envelope.data.pythonVersion,
            ytDLP: envelope.data.ytDLPVersion,
            ejs: envelope.data.ejsVersion
        )
    }

    private struct RuntimeVersionPayload: Decodable {
        let openSSLVersion: String?
        let pythonVersion: String
        let ytDLPVersion: String
        let ejsVersion: String
        enum CodingKeys: String, CodingKey {
            case openSSLVersion = "openssl_version"
            case pythonVersion = "python_version"
            case ytDLPVersion = "yt_dlp_version"
            case ejsVersion = "ejs_version"
        }
    }

    func analyze(url: URL) async throws -> MediaMetadata {
        try await analyzeWithEvidence(url: url, retainForDownload: true).metadata
    }

    func analyzeForDownload(url: URL, allowRecent: Bool) async throws -> DownloadAnalysis {
        let result = try await analyzeWithEvidence(url: url,
            retainForDownload: true, reuseRecent: allowRecent)
        return DownloadAnalysis(metadata: result.metadata, reuseToken: result.reuseToken)
    }

    func analyzeWithEvidence(
        url: URL,
        requestID: UInt64? = nil,
        retainForDownload: Bool = false,
        reuseRecent: Bool = false
    ) async throws -> LiveMetadataExtraction {
        let normalizedURL = try Self.normalizedYouTubeURL(url)
        let request = LiveExtractionRequest(
            url: normalizedURL.absoluteString,
            retainForDownload: retainForDownload && authentication == nil,
            reuseRecentExtraction: reuseRecent && authentication == nil
        )
        let requestJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            requestJSON = String(
                decoding: try encoder.encode(request),
                as: UTF8.self
            )
        } catch {
            throw ExtractionError.invalidResponse(
                "Could not encode the typed extraction request."
            )
        }

        do {
            let activeRequestID =
                requestID ?? PythonRequestIDAllocator.next()
            let response = try await python.executeAuthenticated(
                requestID: activeRequestID,
                requestJSON: requestJSON, authentication: authentication
            )
            return try Self.decodeAndValidateExtractionResponse(
                response,
                requestedURL: normalizedURL,
                contract: contract
            )
        } catch is CancellationError {
            throw ExtractionError.cancelled
        } catch let error as PythonBridgeError {
            if case .cancelled = error {
                throw ExtractionError.cancelled
            }
            throw ExtractionError.extractorFailure(
                code: "python_bridge_failure",
                message: "The embedded extractor could not complete.",
                retryable: true
            )
        }
    }

    func cancel(requestID: UInt64) {
        python.cancel(requestID: requestID)
    }

    static func normalizedYouTubeURL(_ url: URL) throws -> URL {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = url.host()?.lowercased()
        else {
            throw ExtractionError.invalidURL
        }

        let normalizedHost = host.hasPrefix("www.")
            ? String(host.dropFirst(4))
            : host
        let supportedHosts: Set<String> = [
            "youtube.com",
            "m.youtube.com",
            "music.youtube.com",
            "youtu.be",
        ]
        guard supportedHosts.contains(normalizedHost) else {
            throw ExtractionError.unsupportedSite
        }
        guard LiveExtractionValidator.youtubeVideoID(from: url) != nil else {
            throw ExtractionError.invalidURL
        }

        guard
            let videoID = LiveExtractionValidator.youtubeVideoID(from: url),
            var components = URLComponents(
                string: "https://www.youtube.com/watch"
            )
        else {
            throw ExtractionError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
        ]
        guard let normalized = components.url else {
            throw ExtractionError.invalidURL
        }
        return normalized
    }

    static func decodeExtractionResponse(
        _ response: String
    ) throws -> LiveMetadataExtraction {
        guard response.utf8.count <= 8 * 1_024 * 1_024 else {
            throw ExtractionError.invalidResponse(
                "The typed JSON response exceeded its size limit."
            )
        }
        let envelope: LiveExtractionEnvelope
        do {
            envelope = try JSONDecoder().decode(
                LiveExtractionEnvelope.self,
                from: Data(response.utf8)
            )
        } catch let error as DecodingError {
            throw ExtractionError.invalidResponse(
                decodingFailureMessage(error)
            )
        } catch {
            throw ExtractionError.invalidResponse(
                "The typed JSON response did not match its schema."
            )
        }

        guard envelope.action == "extract_metadata" else {
            throw ExtractionError.invalidResponse(
                "The response action did not match the request."
            )
        }
        if envelope.ok {
            guard let extraction = envelope.data else {
                throw ExtractionError.invalidResponse(
                    "A successful response did not contain metadata."
                )
            }
            if let violation = SubtitleMetadataContract.violation(
                in: extraction.metadata.subtitles
            ) {
                throw ExtractionError.invalidResponse(
                    "The subtitle metadata failed the \(violation) contract."
                )
            }
            if let violation = responseBoundsViolation(extraction) {
                throw ExtractionError.invalidResponse(
                    "The sanitized metadata exceeded the \(violation) limit."
                )
            }
            return extraction
        }

        guard let error = envelope.error else {
            throw ExtractionError.invalidResponse(
                "A failed response did not contain a typed error."
            )
        }
        throw ExtractionError.extractorFailure(
            code: error.code,
            message: safeMessage(error.message),
            retryable: error.retryable
        )
    }

    static func decodeAndValidateExtractionResponse(
        _ response: String,
        requestedURL: URL,
        contract: LiveExtractorContract = .bundled
    ) throws -> LiveMetadataExtraction {
        let extraction = try decodeExtractionResponse(response)
        let validation = LiveExtractionValidator.validate(
            extraction,
            requestedURL: requestedURL,
            contract: contract
        )
        guard
            validation.identityIsValid,
            validation.thumbnailIsValid,
            validation.formatsAreValid,
            validation.providerPathIsValid
        else {
            let reportedDigest =
                extraction.providerEvidence.formatInventorySHA256
            let computedDigest = LiveExtractionValidator
                .formatInventorySHA256(for: extraction.metadata.formats)
            let digestMatches = computedDigest == reportedDigest
            throw ExtractionError.invalidResponse(
                "The typed metadata and pinned extractor evidence did not "
                    + "verify "
                    + "(identity=\(validation.identityIsValid), "
                    + "thumbnails=\(validation.thumbnailIsValid), "
                    + "formats=\(validation.formatsAreValid), "
                    + "provider=\(validation.providerPathIsValid), "
                    + "inventory=\(digestMatches))."
            )
        }
        return extraction
    }

    private static func safeMessage(_ message: String) -> String {
        let singleLine = message
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
            !singleLine.isEmpty,
            !singleLine.localizedCaseInsensitiveContains("traceback"),
            !singleLine.localizedCaseInsensitiveContains("cookie"),
            !singleLine.localizedCaseInsensitiveContains("authorization"),
            !singleLine.localizedCaseInsensitiveContains("token="),
            !singleLine.localizedCaseInsensitiveContains("sig="),
            !singleLine.localizedCaseInsensitiveContains("http://"),
            !singleLine.localizedCaseInsensitiveContains("https://")
        else {
            return "The extractor failed. Technical details were redacted."
        }
        return String(singleLine.prefix(512))
    }

    private static func decodingFailureMessage(
        _ error: DecodingError
    ) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "<root>" : String(value.prefix(512))
        }

        switch error {
        case let .keyNotFound(key, context):
            return "Missing field \(key.stringValue) at "
                + "\(path(context.codingPath))."
        case let .typeMismatch(_, context):
            return "Field type mismatch at \(path(context.codingPath))."
        case let .valueNotFound(_, context):
            return "Missing required value at \(path(context.codingPath))."
        case let .dataCorrupted(context):
            return "Corrupt JSON value at \(path(context.codingPath))."
        @unknown default:
            return "The typed JSON response did not match its schema."
        }
    }

    private static func responseBoundsViolation(
        _ extraction: LiveMetadataExtraction
    ) -> String? {
        let metadata = extraction.metadata
        let checks: [(isValid: Bool, field: String)] = [
            (metadata.videoID.utf8.count <= 32, "video ID"),
            (metadata.title.utf8.count <= 512, "title"),
            ((metadata.channel?.utf8.count ?? 0) <= 512, "channel"),
            ((metadata.uploader?.utf8.count ?? 0) <= 512, "uploader"),
            (
                (metadata.description?.utf8.count ?? 0) <= 100_000,
                "description"
            ),
            (
                metadata.canonicalURL.absoluteString.utf8.count <= 4_096,
                "canonical URL"
            ),
            (metadata.thumbnails.count <= 100, "thumbnail count"),
            (
                metadata.thumbnails.allSatisfy {
                    $0.url.absoluteString.utf8.count <= 4_096
                },
                "thumbnail URL"
            ),
            (metadata.chapters.count <= 10_000, "chapter count"),
            (metadata.subtitles.count <= 1_000, "subtitle count"),
            (metadata.formats.count <= 2_000, "format count"),
            (
                extraction.providerEvidence.formatInventorySHA256.utf8.count
                    == 64,
                "format-inventory digest"
            ),
            (
                metadata.formats.allSatisfy {
                    $0.formatID.utf8.count <= 256 &&
                        $0.sourceType.utf8.count <= 128
                },
                "format text"
            ),
        ]
        return checks.first { !$0.isValid }?.field
    }
}
