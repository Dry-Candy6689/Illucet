import Foundation
import CoreFoundation

protocol StreamResolver: Sendable {
    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet
    func resolve(url: URL, formatIDs: [String], reuseToken: String?) async throws -> ResolvedStreamSet
}

extension StreamResolver {
    func resolve(url: URL, formatIDs: [String], reuseToken: String?) async throws -> ResolvedStreamSet {
        try await resolve(url: url, formatIDs: formatIDs)
    }
}

protocol DASHFragmentResolving: Sendable {
    func resolveDASHFragments(
        url: URL,
        formatID: String
    ) async throws -> ResolvedDASHFragmentPlan
}

struct ResolvedDASHFragment: Identifiable, Sendable {
    var id: Int { position }
    let position: Int
    let URL: URL
    let expectedBytes: Int64?

    init(
        position: Int,
        URL: URL,
        expectedBytes: Int64? = nil
    ) {
        self.position = position
        self.URL = URL
        self.expectedBytes = expectedBytes
    }
}

struct ResolvedDASHFragmentPlan: Sendable {
    let videoID: String
    let formatID: String
    let protocolName: String
    let sourceType: String
    let fileExtension: String
    let hasVideo: Bool
    let hasAudio: Bool
    let HTTPHeaders: [String: String]
    let expectedBytes: Int64?
    let fragments: [ResolvedDASHFragment]
    let resolvedAt: Date
    let availableAt: Date?

    init(
        videoID: String,
        formatID: String,
        protocolName: String,
        sourceType: String,
        fileExtension: String,
        hasVideo: Bool,
        hasAudio: Bool,
        HTTPHeaders: [String: String],
        expectedBytes: Int64? = nil,
        fragments: [ResolvedDASHFragment],
        resolvedAt: Date,
        availableAt: Date? = nil
    ) {
        self.videoID = videoID
        self.formatID = formatID
        self.protocolName = protocolName
        self.sourceType = sourceType
        self.fileExtension = fileExtension
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.HTTPHeaders = HTTPHeaders
        self.expectedBytes = expectedBytes
        self.fragments = fragments
        self.resolvedAt = resolvedAt
        self.availableAt = availableAt
    }
}

struct ResolvedStreamSet: Sendable {
    let videoID: String
    let streams: [ResolvedStream]
    let resolvedAt: Date
}

struct ResolvedStream: Identifiable, Sendable {
    var id: String { formatID }
    let formatID: String
    let URL: URL
    let HTTPHeaders: [String: String]
    let fileExtension: String?
    let protocolName: String
    let sourceType: String
    let hasVideo: Bool
    let hasAudio: Bool
    let expectedBytes: Int64?
    let httpChunkSize: Int64?
    let availableAt: Date?

    init(
        formatID: String,
        URL: URL,
        HTTPHeaders: [String: String],
        fileExtension: String?,
        protocolName: String,
        sourceType: String,
        hasVideo: Bool,
        hasAudio: Bool,
        expectedBytes: Int64?,
        httpChunkSize: Int64? = nil,
        availableAt: Date? = nil
    ) {
        self.formatID = formatID
        self.URL = URL
        self.HTTPHeaders = HTTPHeaders
        self.fileExtension = fileExtension
        self.protocolName = protocolName
        self.sourceType = sourceType
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.expectedBytes = expectedBytes
        self.httpChunkSize = httpChunkSize
        self.availableAt = availableAt
    }
}

private struct StreamResolutionRequest: Encodable {
    let action = "resolve_streams"
    let URL: String
    let formatIDs: [String]
    var reuseToken: String? = nil

    enum CodingKeys: String, CodingKey {
        case action
        case URL = "url"
        case formatIDs = "format_ids"
        case reuseToken = "reuse_token"
    }
}

private struct DASHFragmentResolutionRequest: Encodable {
    let action = "resolve_dash_fragment_plan"
    let URL: String
    let formatID: String

    enum CodingKeys: String, CodingKey {
        case action
        case URL = "url"
        case formatID = "format_id"
    }
}

private struct DASHFragmentResolutionEnvelope: Decodable {
    let ok: Bool
    let action: String
    let data: DASHFragmentResolutionPayload?
    let error: StreamResolutionFailure?
}

private struct DASHFragmentResolutionPayload: Decodable {
    let videoID: String
    let formatID: String
    let protocolName: String
    let sourceType: String
    let fileExtension: String
    let hasVideo: Bool
    let hasAudio: Bool
    let expectedBytes: Int64?
    let HTTPHeaders: [String: String]
    let fragmentCount: Int
    let fragments: [DASHFragmentPayload]
    let availableAt: Double?

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case formatID = "format_id"
        case protocolName = "protocol"
        case sourceType = "source_type"
        case fileExtension = "extension"
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
        case expectedBytes = "expected_bytes"
        case HTTPHeaders = "http_headers"
        case fragmentCount = "fragment_count"
        case fragments
        case availableAt = "available_at"
    }
}

private struct DASHFragmentPayload: Decodable {
    let position: Int
    let URL: String
    let expectedBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case position
        case URL = "url"
        case expectedBytes = "expected_bytes"
    }
}
private struct StreamResolutionEnvelope: Decodable {
    let ok: Bool
    let action: String
    let data: StreamResolutionPayload?
    let error: StreamResolutionFailure?
}

private struct StreamResolutionPayload: Decodable {
    let videoID: String
    let streams: [ResolvedStreamPayload]

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case streams
    }
}

private struct ResolvedStreamPayload: Decodable {
    let formatID: String
    let URL: String
    let HTTPHeaders: [String: String]
    let fileExtension: String?
    let protocolName: String
    let sourceType: String
    let hasVideo: Bool
    let hasAudio: Bool
    let expectedBytes: Int64?
    let httpChunkSize: Int64?
    let availableAt: Double?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case URL = "url"
        case HTTPHeaders = "http_headers"
        case fileExtension = "extension"
        case protocolName = "protocol"
        case sourceType = "source_type"
        case hasVideo = "has_video"
        case hasAudio = "has_audio"
        case expectedBytes = "expected_bytes"
        case httpChunkSize = "http_chunk_size"
        case availableAt = "available_at"
    }
}

private struct StreamResolutionFailure: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

struct StreamResolutionFailureDetails: Equatable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
}

final class YTDLPStreamResolver:
    StreamResolver,
    DASHFragmentResolving,
    @unchecked Sendable
{
    static let maximumHTTPChunkSize: Int64 = 256 * 1_024 * 1_024
    static let maximumDASHFragmentCount = 2_048
    static let maximumDASHFragmentResponseBytes = 8 * 1_024 * 1_024

    private let python: PythonEngine
    private let authentication: AccountAuthentication?

    init(python: PythonEngine, authentication: AccountAuthentication? = nil) {
        self.python = python
        self.authentication = authentication
    }

    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet {
        try await resolve(url: url, formatIDs: formatIDs, reuseToken: nil)
    }

    func resolve(url: URL, formatIDs: [String], reuseToken: String?) async throws -> ResolvedStreamSet {
        let normalized = try YTDLPExtractorEngine.normalizedYouTubeURL(url)
        let uniqueIDs = Array(Set(formatIDs)).sorted()
        guard
            !uniqueIDs.isEmpty,
            uniqueIDs.count <= 3,
            uniqueIDs.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 256
            })
        else {
            throw StreamResolutionError.invalidSelection
        }
        let request = StreamResolutionRequest(
            URL: normalized.absoluteString,
            formatIDs: uniqueIDs,
            reuseToken: authentication == nil ? reuseToken : nil
        )
        let JSON = String(
            decoding: try JSONEncoder().encode(request),
            as: UTF8.self
        )
        let response: String
        do {
            response = try await python.executeAuthenticated(
                requestID: PythonRequestIDAllocator.next(),
                requestJSON: JSON, authentication: authentication
            )
        } catch let error as AccountError {
            throw error
        } catch is CancellationError {
            throw StreamResolutionError.cancelled
        } catch {
            throw StreamResolutionError.bridgeUnavailable
        }
        return try Self.decodeResolutionResponse(
            response,
            normalizedURL: normalized,
            formatIDs: uniqueIDs
        )
    }

    func resolveDASHFragments(
        url: URL,
        formatID: String
    ) async throws -> ResolvedDASHFragmentPlan {
        let normalized = try YTDLPExtractorEngine.normalizedYouTubeURL(url)
        guard
            !formatID.isEmpty,
            formatID.utf8.count <= 256
        else {
            throw DASHFragmentResolutionError.invalidSelection
        }
        let request = DASHFragmentResolutionRequest(
            URL: normalized.absoluteString,
            formatID: formatID
        )
        let JSON = String(
            decoding: try JSONEncoder().encode(request),
            as: UTF8.self
        )
        let response: String
        do {
            response = try await python.executeAuthenticated(
                requestID: PythonRequestIDAllocator.next(),
                requestJSON: JSON, authentication: authentication
            )
        } catch let error as AccountError {
            throw error
        } catch is CancellationError {
            throw DASHFragmentResolutionError.cancelled
        } catch {
            throw DASHFragmentResolutionError.bridgeUnavailable
        }
        let plan = try Self.decodeDASHFragmentPlanResponse(
            response,
            normalizedURL: normalized,
            formatID: formatID
        )
        // Keep preparation waits out of transfer liveness accounting. Python
        // has released the interpreter before this cancellable native wait.
        try await MediaAvailability.waitUntilReady(plan.availableAt)
        return plan
    }

    static func decodeResolutionResponse(
        _ response: String,
        normalizedURL: URL,
        formatIDs: [String]
    ) throws -> ResolvedStreamSet {
        guard response.utf8.count <= 128 * 1_024 else {
            throw StreamResolutionError.invalidResponse
        }
        let responseData = Data(response.utf8)
        guard Self.hasStrictHTTPChunkSizeTypes(in: responseData) else {
            throw StreamResolutionError.invalidResponse
        }
        let envelope: StreamResolutionEnvelope
        do {
            envelope = try JSONDecoder().decode(
                StreamResolutionEnvelope.self,
                from: responseData
            )
        } catch {
            throw StreamResolutionError.invalidResponse
        }
        guard envelope.action == "resolve_streams" else {
            throw StreamResolutionError.invalidResponse
        }
        guard envelope.ok else {
            let failure = envelope.error
            throw StreamResolutionError.resolverFailure(
                code: failure?.code ?? "unknown",
                details: StreamResolutionFailureDetails(
                    code: failure?.code ?? "unknown",
                    message: Self.safeMessage(failure?.message),
                    retryable: failure?.retryable ?? false
                )
            )
        }
        guard
            let payload = envelope.data,
            payload.streams.count == formatIDs.count,
            Set(payload.streams.map(\.formatID)) == Set(formatIDs)
        else {
            throw StreamResolutionError.invalidResponse
        }
        let requestedID = LiveExtractionValidator.youtubeVideoID(
            from: normalizedURL
        )
        guard payload.videoID == requestedID else {
            throw StreamResolutionError.invalidResponse
        }
        let streams = try payload.streams.map { raw -> ResolvedStream in
            guard
                let URL = Foundation.URL(string: raw.URL),
                Self.isAllowedMediaURL(URL),
                ["direct_http"].contains(raw.sourceType),
                ["http", "https"].contains(raw.protocolName.lowercased())
            else {
                throw StreamResolutionError.unsupportedProtocol(
                    raw.sourceType
                )
            }
            guard raw.HTTPHeaders.allSatisfy(Self.isAllowedHeader) else {
                throw StreamResolutionError.invalidResponse
            }
            guard
                raw.httpChunkSize.map({
                    (1...Self.maximumHTTPChunkSize).contains($0)
                }) ?? true
            else {
                throw StreamResolutionError.invalidResponse
            }
            let availableAt: Date?
            do { availableAt = try MediaAvailability.date(timestamp: raw.availableAt) }
            catch { throw StreamResolutionError.invalidResponse }
            return ResolvedStream(
                formatID: raw.formatID,
                URL: URL,
                HTTPHeaders: raw.HTTPHeaders,
                fileExtension: raw.fileExtension,
                protocolName: raw.protocolName,
                sourceType: raw.sourceType,
                hasVideo: raw.hasVideo,
                hasAudio: raw.hasAudio,
                expectedBytes: raw.expectedBytes,
                httpChunkSize: raw.httpChunkSize,
                availableAt: availableAt
            )
        }
        return ResolvedStreamSet(
            videoID: payload.videoID,
            streams: streams,
            resolvedAt: .now
        )
    }

    static func decodeDASHFragmentPlanResponse(
        _ response: String,
        normalizedURL: URL,
        formatID: String
    ) throws -> ResolvedDASHFragmentPlan {
        guard
            response.utf8.count <= maximumDASHFragmentResponseBytes,
            !formatID.isEmpty,
            formatID.utf8.count <= 256
        else {
            throw DASHFragmentResolutionError.invalidResponse
        }
        let responseData = Data(response.utf8)
        guard hasStrictDASHFragmentSchema(in: responseData) else {
            throw DASHFragmentResolutionError.invalidResponse
        }
        let envelope: DASHFragmentResolutionEnvelope
        do {
            envelope = try JSONDecoder().decode(
                DASHFragmentResolutionEnvelope.self,
                from: responseData
            )
        } catch {
            throw DASHFragmentResolutionError.invalidResponse
        }
        guard envelope.action == "resolve_dash_fragment_plan" else {
            throw DASHFragmentResolutionError.invalidResponse
        }
        guard envelope.ok else {
            let failure = envelope.error
            throw DASHFragmentResolutionError.resolverFailure(
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
            payload.formatID == formatID,
            payload.fragmentCount == payload.fragments.count,
            (1...maximumDASHFragmentCount).contains(
                payload.fragmentCount
            ),
            payload.fragments.enumerated().allSatisfy({
                $0.offset == $0.element.position
            }),
            payload.videoID == LiveExtractionValidator.youtubeVideoID(
                from: normalizedURL
            )
        else {
            throw DASHFragmentResolutionError.invalidResponse
        }
        let fragments = try payload.fragments.map { raw in
            guard
                let URL = Foundation.URL(string: raw.URL),
                isAllowedDASHFragmentURL(URL)
            else {
                throw DASHFragmentResolutionError.invalidResponse
            }
            return ResolvedDASHFragment(
                position: raw.position,
                URL: URL,
                expectedBytes: raw.expectedBytes
            )
        }
        let availableAt: Date?
        do { availableAt = try MediaAvailability.date(timestamp: payload.availableAt) }
        catch { throw DASHFragmentResolutionError.invalidResponse }
        let plan = ResolvedDASHFragmentPlan(
            videoID: payload.videoID,
            formatID: payload.formatID,
            protocolName: payload.protocolName,
            sourceType: payload.sourceType,
            fileExtension: payload.fileExtension,
            hasVideo: payload.hasVideo,
            hasAudio: payload.hasAudio,
            HTTPHeaders: payload.HTTPHeaders,
            expectedBytes: payload.expectedBytes,
            fragments: fragments,
            resolvedAt: .now,
            availableAt: availableAt
        )
        guard isValidDASHFragmentPlan(plan) else {
            throw DASHFragmentResolutionError.invalidResponse
        }
        return plan
    }

    static func isValidDASHFragmentPlan(
        _ plan: ResolvedDASHFragmentPlan
    ) -> Bool {
        guard
            plan.videoID.utf8.count == 11,
            plan.videoID.utf8.allSatisfy({
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
                    || $0 == 95
            }),
            !plan.formatID.isEmpty,
            plan.formatID.utf8.count <= 256,
            plan.protocolName == "http_dash_segments",
            plan.sourceType == "dash",
            ["m4a", "mp4", "webm"].contains(plan.fileExtension),
            plan.hasVideo || plan.hasAudio,
            plan.expectedBytes.map({ $0 >= 0 }) ?? true,
            (1...maximumDASHFragmentCount).contains(
                plan.fragments.count
            ),
            plan.fragments.enumerated().allSatisfy({
                $0.offset == $0.element.position
                    && isAllowedDASHFragmentURL($0.element.URL)
                    && ($0.element.expectedBytes.map({ $0 >= 0 }) ?? true)
            }),
            plan.HTTPHeaders.count <= 6,
            Set(plan.HTTPHeaders.keys.map { $0.lowercased() }).count
                == plan.HTTPHeaders.count,
            plan.HTTPHeaders.allSatisfy(isAllowedHeader)
        else {
            return false
        }
        return true
    }

    private static func hasStrictDASHFragmentSchema(
        in responseData: Data
    ) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData)
                as? [String: Any]
        else {
            return false
        }
        let allowedRootKeys: Set<String> = ["ok", "action", "data", "error"]
        guard Set(root.keys).isSubset(of: allowedRootKeys) else {
            return false
        }
        guard let payload = root["data"] as? [String: Any] else {
            return true
        }
        let allowedPayloadKeys: Set<String> = [
            "video_id", "format_id", "protocol", "source_type",
            "extension", "has_video", "has_audio", "expected_bytes", "http_headers",
            "fragment_count", "fragments",
        ]
        guard
            Set(payload.keys).subtracting(["available_at"]) == allowedPayloadKeys,
            isStrictInteger(payload["fragment_count"]),
            isOptionalStrictByteCount(payload["expected_bytes"]),
            let fragments = payload["fragments"] as? [[String: Any]]
        else {
            return false
        }
        let allowedFragmentKeys: Set<String> = [
            "position", "url", "expected_bytes",
        ]
        return fragments.enumerated().allSatisfy { offset, fragment in
            Set(fragment.keys) == allowedFragmentKeys
                && isStrictInteger(fragment["position"])
                && (fragment["position"] as? NSNumber)?.intValue == offset
                && isOptionalStrictByteCount(fragment["expected_bytes"])
        }
    }

    private static func isOptionalStrictByteCount(_ value: Any?) -> Bool {
        if value is NSNull {
            return true
        }
        guard
            isStrictInteger(value),
            let number = value as? NSNumber,
            let exact = Int64(number.stringValue)
        else {
            return false
        }
        return exact >= 0
    }

    private static func isStrictInteger(_ value: Any?) -> Bool {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else {
            return false
        }
        return true
    }

    private static func isAllowedDASHFragmentURL(_ URL: URL) -> Bool {
        isAllowedMediaURL(URL) && (URL.port == nil || URL.port == 443)
    }

    private static func hasStrictHTTPChunkSizeTypes(
        in responseData: Data
    ) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData)
                as? [String: Any],
            let payload = root["data"] as? [String: Any],
            let streams = payload["streams"] as? [[String: Any]]
        else {
            // The typed decoder below remains authoritative for the complete
            // response schema. This bounded raw check exists only because
            // JSONDecoder accepts an integral JSON float such as 1.0 as Int64.
            return true
        }

        for stream in streams {
            guard let rawValue = stream["http_chunk_size"] else {
                continue
            }
            if rawValue is NSNull {
                continue
            }
            guard
                let number = rawValue as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                !CFNumberIsFloatType(number)
            else {
                return false
            }
        }
        return true
    }

    static func isAllowedMediaURL(_ URL: URL) -> Bool {
        guard
            URL.scheme == "https",
            URL.user == nil,
            URL.password == nil,
            URL.absoluteString.utf8.count <= 16_384,
            let host = URL.host()?.lowercased()
        else { return false }
        return host == "googlevideo.com"
            || host.hasSuffix(".googlevideo.com")
    }

    static func isAllowedHeader(
        key: String,
        value: String
    ) -> Bool {
        let names: Set<String> = [
            "accept", "accept-language", "origin", "referer", "user-agent",
            "sec-fetch-mode",
        ]
        return names.contains(key.lowercased())
            && (key.lowercased() != "sec-fetch-mode" || value == "navigate")
            && key.utf8.count <= 64
            && value.utf8.count <= 1_024
            && !value.contains("\r")
            && !value.contains("\n")
    }

    private static func safeMessage(_ message: String?) -> String {
        guard
            let message,
            !message.localizedCaseInsensitiveContains("http"),
            !message.localizedCaseInsensitiveContains("cookie"),
            !message.localizedCaseInsensitiveContains("token"),
            !message.localizedCaseInsensitiveContains("signature")
        else {
            return "The selected stream could not be resolved."
        }
        return String(
            message.components(separatedBy: .newlines)[0].prefix(256)
        )
    }
}

enum StreamResolutionError: LocalizedError, Equatable, Sendable {
    case invalidSelection
    case invalidResponse
    case bridgeUnavailable
    case unsupportedProtocol(String)
    case resolverFailure(
        code: String,
        details: StreamResolutionFailureDetails
    )
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "Choose at least one available media format."
        case .invalidResponse: "The extractor returned an invalid stream resolution response."
        case .bridgeUnavailable: "The embedded extractor is unavailable."
        case let .unsupportedProtocol(sourceType):
            "\(sourceType.uppercased()) delivery is not supported by the direct transfer pipeline."
        case let .resolverFailure(_, details): details.message
        case .cancelled: "Stream resolution was cancelled."
        }
    }
}

enum DASHFragmentResolutionError: LocalizedError, Equatable, Sendable {
    case invalidSelection
    case invalidResponse
    case bridgeUnavailable
    case resolverFailure(
        code: String,
        details: StreamResolutionFailureDetails
    )
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "Choose one exact available DASH format."
        case .invalidResponse:
            "The extractor returned an invalid DASH fragment plan."
        case .bridgeUnavailable: "The embedded extractor is unavailable."
        case let .resolverFailure(_, details): details.message
        case .cancelled: "DASH fragment resolution was cancelled."
        }
    }
}
