import Foundation

struct ExactHLSPlaylistRequest: Equatable, Sendable {
    let sourceURL: URL
    let formatID: String
}

enum HLSPlaylistSelectionRoute: Equatable, Sendable {
    case directMedia
}

struct ResolvedHLSPlaylistSelection: Sendable {
    let videoID: String
    let formatID: String
    let protocolName: String
    let sourceType: String
    let fileExtension: String
    let hasVideo: Bool
    let hasAudio: Bool
    let HTTPHeaders: [String: String]
    let mediaPlaylistURL: URL
    let route: HLSPlaylistSelectionRoute
    let playlistRequestCount: Int
    let redirectCount: Int
    let masterVariantCount: Int
    let mediaSegmentCount: Int
    let resourcePlan: HLSMediaResourcePlan
    let resolvedAt: Date
}

protocol HLSPlaylistResolving: Sendable {
    func resolveHLSPlaylist(
        _ request: ExactHLSPlaylistRequest
    ) async throws -> ResolvedHLSPlaylistSelection
}

struct ResolvedHLSPlaylistIdentity: Sendable {
    let videoID: String
    let formatID: String
    let protocolName: String
    let sourceType: String
    let fileExtension: String
    let hasVideo: Bool
    let hasAudio: Bool
    let HTTPHeaders: [String: String]
    let manifestURL: URL
    let mediaPlaylistURL: URL
    let availableAt: Date?

    init(videoID: String, formatID: String, protocolName: String, sourceType: String,
         fileExtension: String, hasVideo: Bool, hasAudio: Bool, HTTPHeaders: [String: String],
         manifestURL: URL, mediaPlaylistURL: URL, availableAt: Date? = nil) {
        self.videoID = videoID
        self.formatID = formatID
        self.protocolName = protocolName
        self.sourceType = sourceType
        self.fileExtension = fileExtension
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.HTTPHeaders = HTTPHeaders
        self.manifestURL = manifestURL
        self.mediaPlaylistURL = mediaPlaylistURL
        self.availableAt = availableAt
    }
}

private struct HLSPlaylistIdentityRequest: Encodable {
    let action = "resolve_hls_playlist_plan"
    let URL: String
    let formatID: String
    let download = false

    enum CodingKeys: String, CodingKey {
        case action
        case URL = "url"
        case formatID = "format_id"
        case download
    }
}

private struct HLSPlaylistIdentityEnvelope: Decodable {
    let ok: Bool
    let action: String
    let data: HLSPlaylistIdentityPayload?
    let error: StreamResolutionFailurePayload?
}

private struct HLSPlaylistIdentityPayload: Decodable {
    let videoID: String
    let formatID: String
    let protocolName: String
    let sourceType: String
    let fileExtension: String
    let hasVideo: Bool
    let hasAudio: Bool
    let HTTPHeaders: [String: String]
    let manifestURL: String
    let mediaPlaylistURL: String
    let availableAt: Double?

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case formatID = "format_id"
        case protocolName = "protocol"
        case sourceType = "source_type"
        case fileExtension = "extension"
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
        case HTTPHeaders = "http_headers"
        case manifestURL = "manifest_url"
        case mediaPlaylistURL = "media_playlist_url"
        case availableAt = "available_at"
    }
}

private struct StreamResolutionFailurePayload: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

final class YTDLPHLSPlaylistResolver:
    HLSPlaylistResolving,
    @unchecked Sendable
{
    static let maximumIdentityResponseBytes = 128 * 1_024

    private let python: PythonEngine
    private let authentication: AccountAuthentication?
    private let networking: any HLSPlaylistNetworking
    private let policy: HLSPlaylistSessionPolicy

    init(
        python: PythonEngine,
        networking: any HLSPlaylistNetworking = URLSessionHLSPlaylistHTTPClient(),
        policy: HLSPlaylistSessionPolicy = .secure,
        authentication: AccountAuthentication? = nil
    ) {
        self.python = python
        self.authentication = authentication
        self.networking = networking
        self.policy = policy
    }

    func resolveHLSPlaylist(
        _ request: ExactHLSPlaylistRequest
    ) async throws -> ResolvedHLSPlaylistSelection {
        let normalized = try YTDLPExtractorEngine.normalizedYouTubeURL(
            request.sourceURL
        )
        guard
            !request.formatID.isEmpty,
            request.formatID.utf8.count <= 256
        else {
            throw HLSPlaylistResolutionError.invalidSelection
        }
        let payload = HLSPlaylistIdentityRequest(
            URL: normalized.absoluteString,
            formatID: request.formatID
        )
        let requestJSON = String(
            decoding: try JSONEncoder().encode(payload),
            as: UTF8.self
        )
        let response: String
        do {
            response = try await python.executeAuthenticated(
                requestID: PythonRequestIDAllocator.next(),
                requestJSON: requestJSON, authentication: authentication
            )
        } catch let error as AccountError {
            throw error
        } catch is CancellationError {
            throw HLSPlaylistResolutionError.cancelled
        } catch {
            throw HLSPlaylistResolutionError.bridgeUnavailable
        }
        let identity = try Self.decodeIdentityResponse(
            response,
            normalizedURL: normalized,
            formatID: request.formatID
        )
        return try await Self.resolveValidatedIdentity(
            identity,
            networking: networking,
            policy: policy
        )
    }

    static func decodeIdentityResponse(
        _ response: String,
        normalizedURL: URL,
        formatID: String
    ) throws -> ResolvedHLSPlaylistIdentity {
        guard
            response.utf8.count <= maximumIdentityResponseBytes,
            !formatID.isEmpty,
            formatID.utf8.count <= 256
        else {
            throw HLSPlaylistResolutionError.invalidResponse
        }
        let data = Data(response.utf8)
        guard hasStrictIdentitySchema(in: data) else {
            throw HLSPlaylistResolutionError.invalidResponse
        }
        let envelope: HLSPlaylistIdentityEnvelope
        do {
            envelope = try JSONDecoder().decode(
                HLSPlaylistIdentityEnvelope.self,
                from: data
            )
        } catch {
            throw HLSPlaylistResolutionError.invalidResponse
        }
        guard envelope.action == "resolve_hls_playlist_plan" else {
            throw HLSPlaylistResolutionError.invalidResponse
        }
        guard envelope.ok else {
            let failure = envelope.error
            throw HLSPlaylistResolutionError.resolverFailure(
                code: failure?.code ?? "unknown",
                details: StreamResolutionFailureDetails(
                    code: failure?.code ?? "unknown",
                    message: safeMessage(failure?.message),
                    retryable: failure?.retryable ?? false
                )
            )
        }
        guard
            let payload = envelope.data,
            payload.videoID == LiveExtractionValidator.youtubeVideoID(
                from: normalizedURL
            ),
            payload.formatID == formatID,
            ["m3u8", "m3u8_native"].contains(payload.protocolName),
            payload.sourceType == "hls",
            ["m4a", "mp4", "webm"].contains(payload.fileExtension),
            payload.hasVideo || payload.hasAudio,
            HLSPlaylistSecurity.areAllowedHeaders(payload.HTTPHeaders),
            let manifestURL = URL(string: payload.manifestURL),
            let mediaPlaylistURL = URL(string: payload.mediaPlaylistURL),
            HLSPlaylistSecurity.isAllowedPlaylistURL(manifestURL),
            HLSPlaylistSecurity.isAllowedPlaylistURL(mediaPlaylistURL)
        else {
            throw HLSPlaylistResolutionError.invalidResponse
        }
        let availableAt: Date?
        do { availableAt = try MediaAvailability.date(timestamp: payload.availableAt) }
        catch { throw HLSPlaylistResolutionError.invalidResponse }
        return ResolvedHLSPlaylistIdentity(
            videoID: payload.videoID,
            formatID: payload.formatID,
            protocolName: payload.protocolName,
            sourceType: payload.sourceType,
            fileExtension: payload.fileExtension,
            hasVideo: payload.hasVideo,
            hasAudio: payload.hasAudio,
            HTTPHeaders: payload.HTTPHeaders,
            manifestURL: manifestURL,
            mediaPlaylistURL: mediaPlaylistURL,
            availableAt: availableAt
        )
    }

    static func resolveValidatedIdentity(
        _ identity: ResolvedHLSPlaylistIdentity,
        networking: any HLSPlaylistNetworking,
        policy: HLSPlaylistSessionPolicy = .secure
    ) async throws -> ResolvedHLSPlaylistSelection {
        guard
            isValid(identity),
            (0...HLSPlaylistSessionPolicy.secure.maximumRedirects)
                .contains(policy.maximumRedirects),
            policy.requestTimeout.isFinite,
            policy.requestTimeout > 0,
            policy.requestTimeout
                <= HLSPlaylistSessionPolicy.secure.requestTimeout,
            policy.resourceTimeout.isFinite,
            policy.resourceTimeout > 0,
            policy.resourceTimeout
                <= HLSPlaylistSessionPolicy.secure.resourceTimeout,
            !policy.acceptsCookies,
            !policy.usesCredentialStorage,
            !policy.usesURLCache,
            policy.usesDefaultTLSVerification
        else {
            throw HLSPlaylistResolutionError.invalidResponse
        }

        try await MediaAvailability.waitUntilReady(identity.availableAt)
        // Python has already resolved the exact requested format to this leaf.
        // Refetching its parent can regenerate signatures and cannot strengthen
        // that identity; never substitute a variant from a refreshed master.
        let leaf = try await fetchPlaylist(
            from: identity.mediaPlaylistURL,
            HTTPHeaders: identity.HTTPHeaders,
            networking: networking,
            maximumRedirects: policy.maximumRedirects,
            requestTimeout: policy.requestTimeout
        )
        let playlist = try HLSPlaylistParser.parse(
            leaf.body,
            finalPlaylistURL: leaf.finalURL
        )
        guard case let .media(plan) = playlist else {
            throw HLSPlaylistResolutionError.recursivePlaylist
        }
        return selection(
            identity: identity,
            finalMediaURL: leaf.finalURL,
            route: .directMedia,
            requestCount: 1,
            redirectCount: leaf.redirectCount,
            variantCount: 0,
            resourcePlan: plan
        )
    }

    private static func selection(
        identity: ResolvedHLSPlaylistIdentity,
        finalMediaURL: URL,
        route: HLSPlaylistSelectionRoute,
        requestCount: Int,
        redirectCount: Int,
        variantCount: Int,
        resourcePlan: HLSMediaResourcePlan
    ) -> ResolvedHLSPlaylistSelection {
        ResolvedHLSPlaylistSelection(
            videoID: identity.videoID,
            formatID: identity.formatID,
            protocolName: identity.protocolName,
            sourceType: identity.sourceType,
            fileExtension: identity.fileExtension,
            hasVideo: identity.hasVideo,
            hasAudio: identity.hasAudio,
            HTTPHeaders: identity.HTTPHeaders,
            mediaPlaylistURL: finalMediaURL,
            route: route,
            playlistRequestCount: requestCount,
            redirectCount: redirectCount,
            masterVariantCount: variantCount,
            mediaSegmentCount: resourcePlan.mediaSegmentCount,
            resourcePlan: resourcePlan,
            resolvedAt: .now
        )
    }

    private static func isValid(
        _ identity: ResolvedHLSPlaylistIdentity
    ) -> Bool {
        identity.videoID.utf8.count == 11
            && identity.videoID.utf8.allSatisfy({
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
                    || $0 == 95
            })
            && !identity.formatID.isEmpty
            && identity.formatID.utf8.count <= 256
            && ["m3u8", "m3u8_native"].contains(identity.protocolName)
            && identity.sourceType == "hls"
            && ["m4a", "mp4", "webm"].contains(identity.fileExtension)
            && (identity.hasVideo || identity.hasAudio)
            && HLSPlaylistSecurity.areAllowedHeaders(identity.HTTPHeaders)
            && HLSPlaylistSecurity.isAllowedPlaylistURL(identity.manifestURL)
            && HLSPlaylistSecurity.isAllowedPlaylistURL(
                identity.mediaPlaylistURL
            )
    }

    private static func fetchPlaylist(
        from initialURL: URL,
        HTTPHeaders: [String: String],
        networking: any HLSPlaylistNetworking,
        maximumRedirects: Int,
        requestTimeout: TimeInterval
    ) async throws -> FetchedHLSPlaylist {
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(initialURL),
            HLSPlaylistSecurity.areAllowedHeaders(HTTPHeaders),
            maximumRedirects >= 0,
            requestTimeout.isFinite,
            requestTimeout > 0,
            requestTimeout <= HLSPlaylistSessionPolicy.secure.requestTimeout
        else {
            throw HLSPlaylistTransportError.unsafeDestination
        }
        var current = initialURL
        var redirectCount = 0
        var visited: Set<String> = []

        while true {
            try Task.checkCancellation()
            guard
                HLSPlaylistSecurity.isAllowedPlaylistURL(current),
                visited.insert(current.absoluteString).inserted
            else {
                throw HLSPlaylistTransportError.tooManyRedirects
            }
            var request = URLRequest(url: current)
            request.httpMethod = "GET"
            request.timeoutInterval = requestTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            for (name, value) in HTTPHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if request.value(forHTTPHeaderField: "Accept") == nil {
                request.setValue(
                    "application/vnd.apple.mpegurl, application/x-mpegURL",
                    forHTTPHeaderField: "Accept"
                )
            }
            let response = try await networking.response(
                for: request,
                maximumBytes: HLSPlaylistParser.maximumManifestBytes
            )
            if response.statusCode == 200 {
                guard !response.body.isEmpty else {
                    throw HLSPlaylistTransportError.emptyResponse
                }
                guard response.body.count
                        <= HLSPlaylistParser.maximumManifestBytes
                else {
                    throw HLSPlaylistTransportError.responseTooLarge
                }
                return FetchedHLSPlaylist(
                    finalURL: current,
                    body: response.body,
                    redirectCount: redirectCount
                )
            }
            if (300...399).contains(response.statusCode) {
                guard
                    redirectCount < maximumRedirects,
                    let location = response.redirectLocation,
                    location.utf8.count <= HLSPlaylistParser.maximumURIBytes,
                    let redirected = URL(
                        string: location,
                        relativeTo: current
                    )?.absoluteURL,
                    HLSPlaylistSecurity.isAllowedPlaylistURL(redirected)
                else {
                    throw HLSPlaylistTransportError.tooManyRedirects
                }
                current = redirected
                redirectCount += 1
                continue
            }
            throw StreamDownloadError.HTTPFailure(statusCode: response.statusCode)
        }
    }

    private static func hasStrictIdentitySchema(in data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return false
        }
        let rootKeys: Set<String> = ["ok", "action", "data", "error"]
        guard Set(root.keys).isSubset(of: rootKeys) else {
            return false
        }
        guard let payload = root["data"] as? [String: Any] else {
            return true
        }
        let payloadKeys: Set<String> = [
            "video_id", "format_id", "protocol", "source_type",
            "extension", "has_video", "has_audio", "http_headers", "manifest_url",
            "media_playlist_url",
        ]
        return Set(payload.keys).subtracting(["available_at"]) == payloadKeys
    }

    private static func safeMessage(_ message: String?) -> String {
        guard
            let message,
            !message.localizedCaseInsensitiveContains("http"),
            !message.localizedCaseInsensitiveContains("cookie"),
            !message.localizedCaseInsensitiveContains("token"),
            !message.localizedCaseInsensitiveContains("signature")
        else {
            return "The selected HLS playlist could not be resolved."
        }
        return String(message.components(separatedBy: .newlines)[0].prefix(256))
    }
}

private struct FetchedHLSPlaylist: Sendable {
    let finalURL: URL
    let body: Data
    let redirectCount: Int
}

enum HLSPlaylistResolutionError: LocalizedError, Equatable, Sendable {
    case invalidSelection
    case invalidResponse
    case bridgeUnavailable
    case resolverFailure(
        code: String,
        details: StreamResolutionFailureDetails
    )
    case identityMismatch
    case recursivePlaylist
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "Choose one exact available HLS format."
        case .invalidResponse:
            "The extractor returned an invalid HLS playlist identity."
        case .bridgeUnavailable:
            "The embedded extractor is unavailable."
        case let .resolverFailure(_, details):
            details.message
        case .identityMismatch:
            "The HLS playlist did not match the exact selected format."
        case .recursivePlaylist:
            "The selected HLS playlist traversal is recursive or unsupported."
        case .cancelled:
            "HLS playlist resolution was cancelled."
        }
    }
}
