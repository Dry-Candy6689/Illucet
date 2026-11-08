import CryptoKit
import Foundation

struct SponsorBlockHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

enum SponsorBlockTransportError: Error, Equatable, Sendable {
    case responseTooLarge(maximumBytes: Int)
}

protocol SponsorBlockHTTPTransport: Sendable {
    func response(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> SponsorBlockHTTPResponse
}

enum SponsorBlockURLSessionPolicy {
    static let approvedHost = "sponsor.ajay.app"

    static func configuration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func redirectRequest(
        for request: URLRequest
    ) -> URLRequest? {
        guard let URL = request.url,
              URL.scheme?.lowercased() == "https",
              URL.host?.caseInsensitiveCompare(approvedHost) == .orderedSame,
              URL.port == nil || URL.port == 443,
              URL.user == nil,
              URL.password == nil
        else {
            return nil
        }
        return request
    }
}

private final class SponsorBlockRedirectDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            SponsorBlockURLSessionPolicy.redirectRequest(for: request)
        )
    }
}

actor SponsorBlockURLSessionTransport: SponsorBlockHTTPTransport {
    private let session: URLSession

    init(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) {
        let configuration = SponsorBlockURLSessionPolicy.configuration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout
        )
        session = URLSession(
            configuration: configuration,
            delegate: SponsorBlockRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func response(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> SponsorBlockHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let HTTPResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if HTTPResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw SponsorBlockTransportError.responseTooLarge(
                maximumBytes: maximumResponseBytes
            )
        }
        var data = Data()
        if HTTPResponse.expectedContentLength > 0 {
            data.reserveCapacity(
                min(
                    maximumResponseBytes,
                    Int(HTTPResponse.expectedContentLength)
                )
            )
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw SponsorBlockTransportError.responseTooLarge(
                    maximumBytes: maximumResponseBytes
                )
            }
            data.append(byte)
        }
        return SponsorBlockHTTPResponse(data: data, response: HTTPResponse)
    }
}

protocol SponsorBlockServing: Sendable {
    func segments(
        videoID: String,
        categories: Set<SponsorBlockCategory>
    ) async throws -> [SponsorBlockSegment]
}

enum SponsorBlockServiceError: LocalizedError, Equatable, Sendable {
    case invalidVideoIdentity
    case invalidRequest
    case timedOut
    case responseTooLarge(maximumBytes: Int)
    case transportFailure
    case requestRejected(statusCode: Int)
    case forbidden
    case rateLimited
    case serviceUnavailable(statusCode: Int)
    case HTTPFailure(statusCode: Int)
    case malformedResponse
    case invalidSegment

    var errorDescription: String? {
        switch self {
        case .invalidVideoIdentity:
            "The analyzed video identity cannot be used for SponsorBlock."
        case .invalidRequest:
            "Illucet could not construct a valid SponsorBlock request."
        case .timedOut:
            "SponsorBlock took too long to respond. Try again."
        case let .responseTooLarge(maximumBytes):
            "SponsorBlock returned more than the allowed \(maximumBytes.formatted(.byteCount(style: .file))) response."
        case .transportFailure:
            "Illucet could not reach SponsorBlock. Check the connection and try again."
        case let .requestRejected(statusCode):
            "SponsorBlock rejected Illucet's request (HTTP \(statusCode)). Review the selected categories and try again."
        case .forbidden:
            "SponsorBlock refused this request (HTTP 403). The service or current network may be denying access. Try again later or on another network."
        case .rateLimited:
            "SponsorBlock is limiting requests (HTTP 429). Wait before retrying."
        case let .serviceUnavailable(statusCode):
            "SponsorBlock is temporarily unavailable (HTTP \(statusCode)). Try again later."
        case let .HTTPFailure(statusCode):
            "SponsorBlock returned unexpected HTTP \(statusCode). Try again later."
        case .malformedResponse:
            "SponsorBlock returned an unreadable response."
        case .invalidSegment:
            "SponsorBlock returned an invalid segment range."
        }
    }
}

struct SponsorBlockServiceConfiguration: Equatable, Sendable {
    var requestTimeout: TimeInterval = 12
    var resourceTimeout: TimeInterval = 20
    var maximumResponseBytes = 512 * 1_024
    var maximumCacheEntries = 32
    var cacheTTL: TimeInterval = 5 * 60
    var maximumSegments = 1_024
    var hashPrefixLength = 4
}

actor SponsorBlockService: SponsorBlockServing {
    private struct CacheKey: Hashable, Sendable {
        let videoID: String
        let categories: [SponsorBlockCategory]
    }

    private struct CacheEntry: Sendable {
        let segments: [SponsorBlockSegment]
        let expiresAt: Date
        var accessOrder: UInt64
    }

    private struct Candidate: Decodable {
        let videoID: String
        let segments: [LossyDecodable<APISegment>]
        private enum CodingKeys: String, CodingKey { case videoID, segments }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            videoID = try values.decode(String.self, forKey: .videoID)
            // Hash buckets grow with the service. Only decode segments for our exact video.
            segments = videoID == decoder.userInfo[Self.exactVideoKey] as? String
                ? try values.decode([LossyDecodable<APISegment>].self, forKey: .segments) : []
        }
        static let exactVideoKey = CodingUserInfoKey(rawValue: "exactVideoID")!
    }

    private struct LossyDecodable<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct APISegment: Decodable {
        let segment: [Double]
        let UUID: String
        let category: SponsorBlockCategory
        let videoDuration: Double
        let actionType: SponsorBlockServerAction
        let locked: Int
        let votes: Int
        let description: String
    }

    private static let APIBaseURL = URL(
        string: "https://sponsor.ajay.app"
    )!

    private let transport: any SponsorBlockHTTPTransport
    private let configuration: SponsorBlockServiceConfiguration
    private let now: @Sendable () -> Date
    private let diagnostics: SponsorBlockDiagnosticLogger?
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0

    init(
        transport: any SponsorBlockHTTPTransport,
        configuration: SponsorBlockServiceConfiguration = .init(),
        diagnostics: SponsorBlockDiagnosticLogger? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.now = now
    }

    static func live(
        configuration: SponsorBlockServiceConfiguration = .init(),
        diagnostics: SponsorBlockDiagnosticLogger? = nil
    ) -> SponsorBlockService {
        SponsorBlockService(
            transport: SponsorBlockURLSessionTransport(
                requestTimeout: configuration.requestTimeout,
                resourceTimeout: configuration.resourceTimeout
            ),
            configuration: configuration,
            diagnostics: diagnostics
        )
    }

    func segments(
        videoID: String,
        categories: Set<SponsorBlockCategory>
    ) async throws -> [SponsorBlockSegment] {
        guard !categories.isEmpty else { return [] }
        guard !videoID.isEmpty,
              videoID.utf8.count <= 512,
              !videoID.contains(where: { $0.isWhitespace })
        else {
            throw SponsorBlockServiceError.invalidVideoIdentity
        }
        let orderedCategories = SponsorBlockCategory.stableOrder.filter {
            categories.contains($0)
        }
        await diagnostics?.record(
            event: "lookup_started",
            detail: "category_count=\(orderedCategories.count)"
        )
        let key = CacheKey(
            videoID: videoID,
            categories: orderedCategories
        )
        let currentDate = now()
        removeExpiredEntries(at: currentDate)
        if var cached = cache[key], cached.expiresAt > currentDate {
            accessCounter &+= 1
            cached.accessOrder = accessCounter
            cache[key] = cached
            await diagnostics?.record(
                event: "lookup_cache_hit",
                detail: "segment_count=\(cached.segments.count)"
            )
            return cached.segments
        }

        let request = try makeRequest(
            videoID: videoID,
            categories: orderedCategories
        )
        let HTTPResponse: SponsorBlockHTTPResponse
        do {
            HTTPResponse = try await transport.response(
                for: request,
                maximumResponseBytes: configuration.maximumResponseBytes
            )
        } catch let error as SponsorBlockTransportError {
            await diagnostics?.record(
                .warning,
                event: "lookup_failed",
                detail: "classification=response_too_large"
            )
            switch error {
            case let .responseTooLarge(maximumBytes):
                throw SponsorBlockServiceError.responseTooLarge(
                    maximumBytes: maximumBytes
                )
            }
        } catch let error as URLError where error.code == .timedOut {
            await diagnostics?.record(
                .warning,
                event: "lookup_failed",
                detail: "classification=timeout"
            )
            throw SponsorBlockServiceError.timedOut
        } catch is CancellationError {
            await diagnostics?.record(
                event: "lookup_cancelled"
            )
            throw CancellationError()
        } catch {
            await diagnostics?.record(
                .warning,
                event: "lookup_failed",
                detail: "classification=transport"
            )
            throw SponsorBlockServiceError.transportFailure
        }

        let statusCode = HTTPResponse.response.statusCode
        await diagnostics?.record(
            event: "response_classified",
            detail: "status_class=\(Self.statusClass(statusCode)), response_bytes=\(HTTPResponse.data.count)"
        )
        if statusCode == 404 {
            await diagnostics?.record(
                event: "response_validated",
                detail: "segment_count=0"
            )
            return []
        }
        guard (200..<300).contains(statusCode) else {
            await diagnostics?.record(
                .warning,
                event: "lookup_failed",
                detail: "classification=\(Self.errorClassification(forHTTPStatus: statusCode))"
            )
            throw Self.serviceError(forHTTPStatus: statusCode)
        }
        guard HTTPResponse.data.count <= configuration.maximumResponseBytes
        else {
            await diagnostics?.record(
                .warning,
                event: "response_validation_failed",
                detail: "classification=response_too_large"
            )
            throw SponsorBlockServiceError.responseTooLarge(
                maximumBytes: configuration.maximumResponseBytes
            )
        }
        let result: [SponsorBlockSegment]
        do {
            result = try decode(
                HTTPResponse.data,
                exactVideoID: videoID,
                categories: categories
            )
        } catch let error as SponsorBlockServiceError {
            await diagnostics?.record(
                .warning,
                event: "response_validation_failed",
                detail: "classification=\(Self.errorClassification(error))"
            )
            throw error
        }
        await diagnostics?.record(
            event: "response_validated",
            detail: "segment_count=\(result.count)"
        )
        insert(result, for: key, at: currentDate)
        return result
    }

    private func makeRequest(
        videoID: String,
        categories: [SponsorBlockCategory]
    ) throws -> URLRequest {
        let prefix = Self.hashPrefix(
            for: videoID,
            length: configuration.hashPrefixLength
        )
        var components = URLComponents(
            url: Self.APIBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.path = "/api/skipSegments/\(prefix)"
        let categoryData = try JSONEncoder().encode(
            categories.map(\.rawValue)
        )
        guard let categoryJSON = String(
            data: categoryData,
            encoding: .utf8
        ) else {
            throw SponsorBlockServiceError.invalidRequest
        }
        components?.queryItems = [
            URLQueryItem(name: "categories", value: categoryJSON),
            URLQueryItem(name: "actionTypes", value: categories.contains(.highlight) ? "[\"skip\",\"poi\"]" : "[\"skip\"]"),
        ]
        guard let URL = components?.url,
              URL.scheme == "https",
              URL.host == Self.APIBaseURL.host
        else {
            throw SponsorBlockServiceError.invalidRequest
        }
        var request = URLRequest(
            url: URL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    private static func serviceError(
        forHTTPStatus statusCode: Int
    ) -> SponsorBlockServiceError {
        switch statusCode {
        case 403:
            .forbidden
        case 429:
            .rateLimited
        case 400..<500:
            .requestRejected(statusCode: statusCode)
        case 500..<600:
            .serviceUnavailable(statusCode: statusCode)
        default:
            .HTTPFailure(statusCode: statusCode)
        }
    }

    private static func statusClass(_ statusCode: Int) -> String {
        switch statusCode {
        case 200..<300: "success"
        case 400..<500: "client_error"
        case 500..<600: "server_error"
        default: "unexpected"
        }
    }

    private static func errorClassification(
        forHTTPStatus statusCode: Int
    ) -> String {
        switch statusCode {
        case 403: "forbidden"
        case 404: "not_found"
        case 429: "rate_limited"
        case 400..<500: "request_rejected"
        case 500..<600: "service_unavailable"
        default: "http_failure"
        }
    }

    private static func errorClassification(
        _ error: SponsorBlockServiceError
    ) -> String {
        switch error {
        case .malformedResponse: "malformed_response"
        case .invalidSegment: "invalid_segment"
        case .responseTooLarge: "response_too_large"
        case .invalidVideoIdentity: "invalid_video_identity"
        case .invalidRequest: "invalid_request"
        case .timedOut: "timeout"
        case .transportFailure: "transport"
        case .requestRejected: "request_rejected"
        case .forbidden: "forbidden"
        case .rateLimited: "rate_limited"
        case .serviceUnavailable: "service_unavailable"
        case .HTTPFailure: "http_failure"
        }
    }

    private func decode(
        _ data: Data,
        exactVideoID: String,
        categories: Set<SponsorBlockCategory>
    ) throws -> [SponsorBlockSegment] {
        let decodedCandidates: [LossyDecodable<Candidate>]
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[Candidate.exactVideoKey] = exactVideoID
            decodedCandidates = try decoder.decode(
                [LossyDecodable<Candidate>].self,
                from: data
            )
        } catch {
            throw SponsorBlockServiceError.malformedResponse
        }
        let candidates = decodedCandidates.compactMap(\.value)
        let exactMatches = candidates.filter {
            $0.videoID == exactVideoID
        }
        guard exactMatches.count <= 1 else {
            throw SponsorBlockServiceError.malformedResponse
        }
        guard let candidate = exactMatches.first else { return [] }
        guard candidate.segments.count <= configuration.maximumSegments else {
            throw SponsorBlockServiceError.malformedResponse
        }
        var seen = Set<String>()
        var result: [SponsorBlockSegment] = []
        for decodedValue in candidate.segments {
            guard let value = decodedValue.value else { continue }
            guard value.segment.count == 2,
                  value.UUID.utf8.count > 0,
                  value.UUID.utf8.count <= 160,
                  categories.contains(value.category),
                  value.locked == 0 || value.locked == 1,
                  value.description.utf8.count <= 1_024
            else {
                continue
            }
            guard seen.insert(value.UUID).inserted else {
                throw SponsorBlockServiceError.malformedResponse
            }
            let start = value.segment[0]
            let end = value.segment[1]
            guard start.isFinite,
                  end.isFinite,
                  value.videoDuration.isFinite,
                  start >= 0,
                  (value.category == .highlight
                    ? value.actionType == .pointOfInterest && end == start
                    : value.actionType == .skip && end > start),
                  value.videoDuration >= 0,
                  value.videoDuration == 0
                    || (start < value.videoDuration
                        && end <= value.videoDuration
                            + SponsorBlockTiming
                                .maximumEndBoundaryDifferenceSeconds)
            else {
                throw SponsorBlockServiceError.invalidSegment
            }
            let trimmedDescription = value.description.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            result.append(SponsorBlockSegment(
                segmentID: value.UUID,
                category: value.category,
                startSeconds: start,
                endSeconds: end,
                description: trimmedDescription.isEmpty
                    ? nil
                    : trimmedDescription,
                submittedVideoDuration: value.videoDuration,
                serverAction: value.actionType,
                votes: value.votes,
                isLocked: value.locked == 1
            ))
        }
        let highlight = result.filter { $0.category == .highlight }.sorted {
            if $0.votes != $1.votes { return $0.votes > $1.votes }
            if $0.isLocked != $1.isLocked { return $0.isLocked }
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.segmentID < $1.segmentID
        }.first
        result.removeAll { $0.category == .highlight && $0.segmentID != highlight?.segmentID }
        return result.sorted {
            if $0.startSeconds != $1.startSeconds {
                return $0.startSeconds < $1.startSeconds
            }
            if $0.endSeconds != $1.endSeconds {
                return $0.endSeconds < $1.endSeconds
            }
            return $0.segmentID < $1.segmentID
        }
    }

    private func removeExpiredEntries(at date: Date) {
        cache = cache.filter { $0.value.expiresAt > date }
    }

    private func insert(
        _ segments: [SponsorBlockSegment],
        for key: CacheKey,
        at date: Date
    ) {
        guard configuration.maximumCacheEntries > 0,
              configuration.cacheTTL > 0
        else {
            return
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(
            segments: segments,
            expiresAt: date.addingTimeInterval(configuration.cacheTTL),
            accessOrder: accessCounter
        )
        while cache.count > configuration.maximumCacheEntries,
              let evictionKey = cache.min(by: { lhs, rhs in
                  if lhs.value.accessOrder != rhs.value.accessOrder {
                      return lhs.value.accessOrder < rhs.value.accessOrder
                  }
                  if lhs.key.videoID != rhs.key.videoID {
                      return lhs.key.videoID < rhs.key.videoID
                  }
                  return lhs.key.categories.map(\.rawValue)
                      .lexicographicallyPrecedes(
                          rhs.key.categories.map(\.rawValue)
                      )
              })?.key {
            cache.removeValue(forKey: evictionKey)
        }
    }

    static func hashPrefix(for videoID: String, length: Int = 4) -> String {
        let digest = SHA256.hash(data: Data(videoID.utf8))
        let hexadecimal = digest.map {
            String(format: "%02x", $0)
        }.joined()
        return String(hexadecimal.prefix(max(1, min(64, length))))
    }
}

struct SponsorBlockStaticService: SponsorBlockServing {
    let availableSegments: [SponsorBlockSegment]

    func segments(
        videoID: String,
        categories: Set<SponsorBlockCategory>
    ) async throws -> [SponsorBlockSegment] {
        availableSegments.filter { categories.contains($0.category) }
    }
}
