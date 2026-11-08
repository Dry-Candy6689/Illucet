import Foundation

protocol PlaylistAnalyzing: Sendable {
    func analyze(
        url: URL,
        maximumEntries: Int
    ) async throws -> PlaylistAnalysis
    func cancel(requestID: UInt64)
}

enum PlaylistAnalysisError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedSite
    case invalidLimit
    case cancelled
    case extractorFailure(code: String, message: String, retryable: Bool)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The URL does not identify a supported YouTube playlist."
        case .unsupportedSite:
            "Playlist analysis currently supports YouTube URLs only."
        case .invalidLimit:
            "The playlist item limit must be between 1 and 500."
        case .cancelled:
            "Playlist analysis was cancelled."
        case let .extractorFailure(_, message, _):
            message
        case let .invalidResponse(message):
            "The extractor returned an invalid playlist: \(message)"
        }
    }
}

struct PlaylistURLIntent: Equatable, Sendable {
    let analysisURL: URL
    let canonicalURL: URL
    let playlistID: String
    let kind: PlaylistKind
    let referencedVideoID: String?
}

enum YouTubeMediaURLIntent: Equatable, Sendable {
    case video(canonicalURL: URL, videoID: String)
    case playlist(PlaylistURLIntent)
}

enum YouTubeURLIntentClassifier {
    private static let supportedHosts: Set<String> = [
        "youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "youtube-nocookie.com",
    ]

    static func classify(_ url: URL) throws -> YouTubeMediaURLIntent {
        guard url.absoluteString.utf8.count <= 4_096,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil
                  || components.port == 80
                  || components.port == 443,
              let rawHost = components.host?.lowercased()
        else {
            throw PlaylistAnalysisError.invalidURL
        }
        let host = rawHost.hasPrefix("www.")
            ? String(rawHost.dropFirst(4))
            : rawHost
        guard supportedHosts.contains(host) else {
            throw PlaylistAnalysisError.unsupportedSite
        }

        if host != "youtu.be", !(components.queryItems ?? []).contains(where: { $0.name == "list" }), let creator = creatorIntent(components) {
            return .playlist(creator)
        }

        let queryItems = components.queryItems ?? []
        guard queryItems.count <= 64 else {
            throw PlaylistAnalysisError.invalidURL
        }
        let playlistID = queryItems
            .first { $0.name == "list" }?
            .value
        guard let playlistID else {
            do {
                let canonical = try YTDLPExtractorEngine
                    .normalizedYouTubeURL(url)
                guard let videoID = LiveExtractionValidator
                    .youtubeVideoID(from: canonical)
                else {
                    throw PlaylistAnalysisError.invalidURL
                }
                return .video(
                    canonicalURL: canonical,
                    videoID: videoID
                )
            } catch ExtractionError.unsupportedSite {
                throw PlaylistAnalysisError.unsupportedSite
            } catch {
                throw PlaylistAnalysisError.invalidURL
            }
        }
        guard isValidPlaylistID(playlistID) else {
            throw PlaylistAnalysisError.invalidURL
        }

        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        let isShortsPath = pathParts.first == "shorts"
        let referencedVideoID: String?
        if host == "youtu.be" {
            guard let first = pathParts.first,
                  isValidVideoID(first)
            else {
                throw PlaylistAnalysisError.invalidURL
            }
            referencedVideoID = first
        } else if components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) == "playlist" {
            referencedVideoID = nil
        } else if components.path == "/watch"
                    || components.path == "/watch/" {
            let candidate = queryItems
                .first { $0.name == "v" }?
                .value
            if let candidate, !isValidVideoID(candidate) {
                throw PlaylistAnalysisError.invalidURL
            }
            referencedVideoID = candidate
        } else if pathParts.count >= 2,
                  ["embed", "live", "shorts", "v"].contains(pathParts[0]),
                  isValidVideoID(pathParts[1]) {
            referencedVideoID = pathParts[1]
        } else {
            throw PlaylistAnalysisError.invalidURL
        }

        let kind: PlaylistKind
        if playlistID == "WL" || playlistID == "LL" {
            kind = .privateCollection
        } else if playlistID.hasPrefix("RD") {
            kind = .mix
        } else if isShortsPath {
            kind = .shorts
        } else {
            kind = .playlist
        }
        guard var canonicalComponents = URLComponents(
            string: "https://www.youtube.com/playlist"
        ) else {
            throw PlaylistAnalysisError.invalidURL
        }
        canonicalComponents.queryItems = [
            URLQueryItem(name: "list", value: playlistID),
        ]
        guard let canonicalURL = canonicalComponents.url else {
            throw PlaylistAnalysisError.invalidURL
        }

        var analysisURL = canonicalURL
        if let referencedVideoID {
            guard var analysisComponents = URLComponents(
                string: "https://www.youtube.com/watch"
            ) else {
                throw PlaylistAnalysisError.invalidURL
            }
            analysisComponents.queryItems = [
                URLQueryItem(name: "v", value: referencedVideoID),
                URLQueryItem(name: "list", value: playlistID),
            ]
            guard let value = analysisComponents.url else {
                throw PlaylistAnalysisError.invalidURL
            }
            analysisURL = value
        }
        return .playlist(
            PlaylistURLIntent(
                analysisURL: analysisURL,
                canonicalURL: canonicalURL,
                playlistID: playlistID,
                kind: kind,
                referencedVideoID: referencedVideoID
            )
        )
    }

    private static func creatorIntent(_ components: URLComponents) -> PlaylistURLIntent? {
        let parts = components.path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        let baseCount = first.hasPrefix("@") ? 1 : 2
        guard first.hasPrefix("@") || ["channel", "c", "user"].contains(first),
              parts.count == baseCount || parts.count == baseCount + 1,
              parts.prefix(baseCount).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy { isSafeIdentifierByte($0) || $0 == 64 || $0 == 46 } })
        else { return nil }
        let tab = parts.count > baseCount ? parts[baseCount] : "videos"
        let kind: PlaylistKind
        switch tab {
        case "videos": kind = .creatorUploads
        case "shorts": kind = .creatorShorts
        case "streams": kind = .creatorReplays
        default: return nil
        }
        let path = parts.prefix(baseCount).joined(separator: "/") + "/" + tab
        guard let canonical = URL(string: "https://www.youtube.com/" + path) else { return nil }
        return PlaylistURLIntent(analysisURL: canonical, canonicalURL: canonical,
            playlistID: path, kind: kind, referencedVideoID: nil)
    }

    static func playlistIntent(from url: URL) throws -> PlaylistURLIntent {
        guard case let .playlist(intent) = try classify(url) else {
            throw PlaylistAnalysisError.invalidURL
        }
        return intent
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy(isSafeIdentifierByte)
    }

    private static func isValidPlaylistID(_ value: String) -> Bool {
        (2 ... 128).contains(value.utf8.count)
            && value.utf8.allSatisfy(isSafeIdentifierByte)
    }

    private static func isSafeIdentifierByte(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
            || byte == 45
            || byte == 95
    }
}

struct PlaylistAnalysisRequest: Encodable, Equatable, Sendable {
    var detailedEntries: Bool? = nil
    let action = "extract_playlist"
    let url: String
    let maximumEntries: Int
    let download = false

    private enum CodingKeys: String, CodingKey {
        case action
        case url
        case maximumEntries = "maximum_entries"
        case detailedEntries = "detailed_entries"
        case download
    }
}

private struct PlaylistAnalysisErrorPayload: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

private struct PlaylistAnalysisEnvelope: Decodable {
    let ok: Bool
    let action: String
    let data: PlaylistAnalysis?
    let error: PlaylistAnalysisErrorPayload?
}

final class YTDLPPlaylistAnalyzer: PlaylistAnalyzing, @unchecked Sendable {
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let maximumEntries = 500

    private let python: PythonEngine
    private let authentication: AccountAuthentication?

    init(python: PythonEngine, authentication: AccountAuthentication? = nil) {
        self.python = python
        self.authentication = authentication
    }

    func analyze(url: URL, maximumEntries: Int) async throws -> PlaylistAnalysis {
        try await analyze(url: url, maximumEntries: maximumEntries, detailed: false)
    }

    func analyze(url: URL, maximumEntries: Int, detailed: Bool) async throws -> PlaylistAnalysis {
        guard (1 ... Self.maximumEntries).contains(maximumEntries) else {
            throw PlaylistAnalysisError.invalidLimit
        }
        let intent = try YouTubeURLIntentClassifier.playlistIntent(from: url)
        let request = PlaylistAnalysisRequest(
            detailedEntries: detailed ? true : nil,
            url: intent.analysisURL.absoluteString,
            maximumEntries: maximumEntries
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
            throw PlaylistAnalysisError.invalidResponse(
                "Could not encode the typed playlist request."
            )
        }

        do {
            let response = try await python.executeAuthenticated(
                requestID: PythonRequestIDAllocator.next(),
                requestJSON: requestJSON, authentication: authentication
            )
            return try Self.decodeAndValidateResponse(
                response,
                expectedIntent: intent,
                maximumEntries: maximumEntries
            )
        } catch is CancellationError {
            throw PlaylistAnalysisError.cancelled
        } catch let error as PythonBridgeError {
            if case .cancelled = error {
                throw PlaylistAnalysisError.cancelled
            }
            throw PlaylistAnalysisError.extractorFailure(
                code: "python_bridge_failure",
                message: "The embedded playlist extractor could not complete.",
                retryable: true
            )
        }
    }

    func cancel(requestID: UInt64) {
        python.cancel(requestID: requestID)
    }

    static func decodeAndValidateResponse(
        _ response: String,
        expectedIntent: PlaylistURLIntent,
        maximumEntries: Int
    ) throws -> PlaylistAnalysis {
        guard response.utf8.count <= maximumResponseBytes else {
            throw PlaylistAnalysisError.invalidResponse(
                "The typed JSON response exceeded its size limit."
            )
        }
        let envelope: PlaylistAnalysisEnvelope
        do {
            envelope = try JSONDecoder().decode(
                PlaylistAnalysisEnvelope.self,
                from: Data(response.utf8)
            )
        } catch let error as DecodingError {
            throw PlaylistAnalysisError.invalidResponse(
                decodingFailureMessage(error)
            )
        } catch {
            throw PlaylistAnalysisError.invalidResponse(
                "The typed JSON response did not match its schema."
            )
        }
        guard envelope.action == "extract_playlist" else {
            throw PlaylistAnalysisError.invalidResponse(
                "The response action did not match the request."
            )
        }
        guard envelope.ok else {
            guard let error = envelope.error else {
                throw PlaylistAnalysisError.invalidResponse(
                    "A failed response did not contain a typed error."
                )
            }
            throw PlaylistAnalysisError.extractorFailure(
                code: String(error.code.prefix(128)),
                message: safeMessage(error.message),
                retryable: error.retryable
            )
        }
        guard let analysis = envelope.data else {
            throw PlaylistAnalysisError.invalidResponse(
                "A successful response did not contain playlist metadata."
            )
        }
        guard validate(
            analysis,
            expectedIntent: expectedIntent,
            maximumEntries: maximumEntries
        ) else {
            throw PlaylistAnalysisError.invalidResponse(
                "The playlist identity or bounded entry inventory did not verify."
            )
        }
        return analysis
    }

    private static func validate(
        _ analysis: PlaylistAnalysis,
        expectedIntent: PlaylistURLIntent,
        maximumEntries: Int
    ) -> Bool {
        guard (1 ... Self.maximumEntries).contains(maximumEntries),
              analysis.canonicalURL == expectedIntent.canonicalURL,
              analysis.playlistID == expectedIntent.playlistID,
              analysis.referencedVideoID
                  == expectedIntent.referencedVideoID,
              analysis.kind == expectedIntent.kind
                  || (
                      expectedIntent.kind == .playlist
                          && analysis.kind == .shorts
                  ),
              !analysis.title.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              analysis.title.utf8.count <= 512,
              (analysis.creator?.utf8.count ?? 0) <= 512,
              analysis.entries.count <= maximumEntries,
              analysis.reportedItemCount.map({ $0 >= 0 }) != false,
              analysis.estimatedTotalBytes.map({ $0 >= 0 }) != false,
              analysis.thumbnailURL.map(isSafeThumbnailURL) != false
        else {
            return false
        }
        let entryIDs = analysis.entries.map(\.id)
        let indexes = analysis.entries.map(\.index)
        guard Set(entryIDs).count == entryIDs.count,
              Set(indexes).count == indexes.count,
              indexes == indexes.sorted(),
              indexes.allSatisfy({ $0 > 0 }),
              analysis.entries.allSatisfy(validateEntry)
        else {
            return false
        }
        if let reported = analysis.reportedItemCount,
           !analysis.isTruncated,
           reported < analysis.entries.count {
            return false
        }
        return true
    }

    private static func validateEntry(_ entry: PlaylistEntry) -> Bool {
        guard !entry.id.isEmpty,
              entry.id.utf8.count <= 400,
              !entry.title.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              entry.title.utf8.count <= 512,
              (entry.creator?.utf8.count ?? 0) <= 512,
              entry.durationSeconds.map({
                  $0.isFinite && $0 >= 0
              }) != false,
              entry.estimatedBytes.map({ $0 >= 0 }) != false,
              entry.height.map({ $0 > 0 && $0 <= 65_536 }) != false,
              entry.uploadDate.map({ $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }) != false,
              entry.thumbnailURL.map(isSafeThumbnailURL) != false
        else {
            return false
        }
        if let videoID = entry.videoID,
           !isValidVideoID(videoID) {
            return false
        }
        if entry.availability.isDownloadable {
            guard let videoID = entry.videoID,
                  entry.canonicalURL == URL(
                      string:
                          "https://www.youtube.com/watch?v=\(videoID)"
                  )
            else {
                return false
            }
        } else if entry.canonicalURL != nil {
            return false
        }
        return true
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (48 ... 57).contains($0)
                || (65 ... 90).contains($0)
                || (97 ... 122).contains($0)
                || $0 == 45
                || $0 == 95
        }
    }

    private static func isSafeThumbnailURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == "https",
        components.user == nil,
        components.password == nil,
        let host = components.host?.lowercased(),
        !host.isEmpty,
        components.port == nil
            || components.port == 80
            || components.port == 443,
        components.query == nil,
        components.fragment == nil
        else {
            return false
        }
        return host.hasSuffix(".ytimg.com")
            || host.hasSuffix(".ggpht.com")
    }

    private static func safeMessage(_ message: String) -> String {
        let singleLine = message
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !singleLine.isEmpty,
              !singleLine.localizedCaseInsensitiveContains("traceback"),
              !singleLine.localizedCaseInsensitiveContains("cookie"),
              !singleLine.localizedCaseInsensitiveContains("authorization"),
              !singleLine.localizedCaseInsensitiveContains("token="),
              !singleLine.localizedCaseInsensitiveContains("sig="),
              !singleLine.localizedCaseInsensitiveContains("http://"),
              !singleLine.localizedCaseInsensitiveContains("https://")
        else {
            return "The playlist extractor failed. Details were redacted."
        }
        return String(singleLine.prefix(512))
    }

    private static func decodingFailureMessage(
        _ error: DecodingError
    ) -> String {
        let path: ([any CodingKey]) -> String = { codingPath in
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
}
