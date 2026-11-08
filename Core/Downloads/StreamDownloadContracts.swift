import Foundation

struct StreamTransferProgress: Sendable {
    let jobID: UUID
    let streamID: String
    let bytesWritten: Int64
    let totalBytesWritten: Int64
    let totalBytesExpected: Int64?
    let instantaneousBytesPerSecond: Double?
    let verifiedReusableBytes: Int64
    let networkBytesReceived: Int64

    init(
        jobID: UUID,
        streamID: String,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpected: Int64?,
        instantaneousBytesPerSecond: Double?,
        verifiedReusableBytes: Int64 = 0,
        networkBytesReceived: Int64? = nil
    ) {
        self.jobID = jobID
        self.streamID = streamID
        self.bytesWritten = bytesWritten
        self.totalBytesWritten = totalBytesWritten
        self.totalBytesExpected = totalBytesExpected
        self.instantaneousBytesPerSecond = instantaneousBytesPerSecond
        self.verifiedReusableBytes = max(0, verifiedReusableBytes)
        self.networkBytesReceived = max(
            0,
            networkBytesReceived ?? totalBytesWritten
        )
    }
}

typealias StreamTransferProgressHandler =
    @Sendable (StreamTransferProgress) -> Void

struct DASHFragmentTransferProgress: Sendable {
    let jobID: UUID
    let formatID: String
    let fragmentPosition: Int
    let completedFragmentCount: Int
    let completedBytesBeforeFragment: Int64
    let fragmentCount: Int
    let fragmentProgress: StreamTransferProgress
    var verifiedReusableBytesBeforeFragment: Int64 = 0
}

typealias DASHFragmentTransferProgressHandler =
    @Sendable (DASHFragmentTransferProgress) -> Void

typealias DASHFragmentRetrySleeper =
    @Sendable (_ delaySeconds: Double) async throws -> Void

struct DASHFragmentRetryPolicy: Equatable, Sendable {
    static let absoluteMaximumRetries = 5

    let maximumRetries: Int
    let initialDelaySeconds: Double
    let multiplier: Double
    let maximumDelaySeconds: Double

    init(
        maximumRetries: Int = 2,
        initialDelaySeconds: Double = 1,
        multiplier: Double = 2,
        maximumDelaySeconds: Double = 8
    ) {
        self.maximumRetries = min(
            max(0, maximumRetries),
            Self.absoluteMaximumRetries
        )
        let boundedInitial = initialDelaySeconds.isFinite
            ? max(0, initialDelaySeconds)
            : 1
        self.initialDelaySeconds = boundedInitial
        self.multiplier = multiplier.isFinite ? max(1, multiplier) : 2
        self.maximumDelaySeconds = maximumDelaySeconds.isFinite
            ? max(boundedInitial, maximumDelaySeconds)
            : max(boundedInitial, 8)
    }

    func delay(forRetryNumber retryNumber: Int) -> Double {
        guard retryNumber > 1 else {
            return initialDelaySeconds
        }
        let candidate = initialDelaySeconds
            * pow(multiplier, Double(retryNumber - 1))
        guard candidate.isFinite else {
            return maximumDelaySeconds
        }
        return min(maximumDelaySeconds, candidate)
    }

    func permitsRetry(of error: any Error) -> Bool {
        if let transfer = error as? StreamDownloadError {
            switch transfer {
            case .networkFailure, .transientHTTPFailure:
                return true
            case .cancelled, .couldNotCommitFile,
                 .unauthorizedHTTPFailure, .forbiddenHTTPFailure,
                 .goneHTTPFailure, .permanentHTTPFailure,
                 .invalidPartialContent, .rangeAssemblyFailure:
                return false
            }
        }
        if let fragment = error as? DASHFragmentDownloadError,
           case .fragmentByteCountMismatch = fragment {
            return true
        }
        return false
    }
}

struct StagedDASHFragment: Identifiable, Sendable {
    var id: Int { position }
    let position: Int
    let fileURL: URL
    let byteCount: Int64
}

struct DASHFragmentStagingResult: Sendable {
    let videoID: String
    let formatID: String
    let fragments: [StagedDASHFragment]
}

struct HLSResourceTransferProgress: Sendable {
    let jobID: UUID
    let formatID: String
    let resourcePosition: Int
    let completedResourceCount: Int
    let resourceCount: Int
    let completedBytes: Int64
    var verifiedReusableBytes: Int64 = 0
}

typealias HLSResourceTransferProgressHandler =
    @Sendable (HLSResourceTransferProgress) -> Void

struct StagedHLSResource: Equatable, Sendable {
    let position: Int
    let kind: HLSMediaResourceKind
    let fileURL: URL
    let byteCount: Int64
    let byteRange: HLSMediaByteRange?
}

enum StagedHLSPlaylistEvent: Equatable, Sendable {
    case initialization(
        eventPosition: Int,
        resource: StagedHLSResource
    )
    case media(
        eventPosition: Int,
        resource: StagedHLSResource,
        initializationEventPosition: Int?
    )
    case discontinuity(eventPosition: Int)

    var resource: StagedHLSResource? {
        switch self {
        case let .initialization(_, resource),
             let .media(_, resource, _):
            resource
        case .discontinuity:
            nil
        }
    }
}

struct HLSResourceStagingResult: Equatable, Sendable {
    let videoID: String
    let formatID: String
    let stagingDirectoryURL: URL
    let events: [StagedHLSPlaylistEvent]
}

struct StreamTransferNetworkPolicy: Equatable, Sendable {
    let allowsExpensiveAccess: Bool
    let allowsConstrainedAccess: Bool

    static let unrestricted = Self(
        allowsExpensiveAccess: true,
        allowsConstrainedAccess: true
    )
}

enum StreamTaskControlAction: String, Equatable, Sendable {
    case pause
    case resume
    case cancel
}

struct StreamTaskControlResult: Equatable, Sendable {
    let action: StreamTaskControlAction
    let matchedTaskCount: Int
    let affectedTaskCount: Int
    let acknowledgedTaskCount: Int

    var fullyAcknowledged: Bool {
        matchedTaskCount == acknowledgedTaskCount
    }
}

protocol StreamDownloading: Sendable {
    func setForegroundActive(_ active: Bool) async
    func nativeTaskSnapshot() async -> [StreamTransferRegistration]
    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        verifiedExpectedBytes: Int64?,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> StreamDownloadResult

    func setAdmissionPaused(_ paused: Bool, jobID: UUID) async
    func cancel(jobID: UUID) async -> StreamTaskControlResult
    func pause(jobID: UUID) async -> StreamTaskControlResult
    func resume(jobID: UUID) async -> StreamTaskControlResult

    func reconcileBackgroundTasks() async -> [
        StreamTransferRegistration
    ]

    func setNetworkPolicy(
        _ policy: StreamTransferNetworkPolicy,
        jobID: UUID
    ) async
}

protocol DASHFragmentDownloading: Sendable {
    func downloadDASHFragments(
        _ plan: ResolvedDASHFragmentPlan,
        jobID: UUID,
        stagingDirectoryURL: URL,
        progress: @escaping DASHFragmentTransferProgressHandler
    ) async throws -> DASHFragmentStagingResult
}

protocol HLSResourceDownloading: Sendable {
    func downloadHLSResources(
        _ selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        progress: @escaping HLSResourceTransferProgressHandler
    ) async throws -> HLSResourceStagingResult
}

enum BackgroundTransferTaskIdentity: Equatable, Sendable {
    case stream(StreamTransferDescriptor)
    case hlsResource(HLSResourceTransferDescriptor)
    case invalidHLSResource
}

extension StreamDownloading {
    func setForegroundActive(_ active: Bool) async {}
    func nativeTaskSnapshot() async -> [StreamTransferRegistration] { await reconcileBackgroundTasks() }
    func setAdmissionPaused(_ paused: Bool, jobID: UUID) async {}
    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        verifiedExpectedBytes: Int64?,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> StreamDownloadResult {
        let URL = try await download(
            stream,
            jobID: jobID,
            destinationURL: destinationURL,
            progress: progress
        )
        return StreamDownloadResult(
            fileURL: URL,
            strategy: .oneGET,
            plannedRangeCount: 0,
            requestedRangeCount: 0,
            verifiedReusableBytes: 0,
            networkBytesReceived: 0
        )
    }

    func reconcileBackgroundTasks() async -> [
        StreamTransferRegistration
    ] {
        []
    }

    func setNetworkPolicy(
        _ policy: StreamTransferNetworkPolicy,
        jobID: UUID
    ) async {}
}

/// A connection hint for YouTube's media CDN, never a source-identity decision.
/// URLSession still races/falls back to TCP when QUIC is unavailable.
enum MediaTransportProtocolPolicy {
    static func assumesHTTP3Capable(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }
}

struct StreamDownloadServiceHooks: Sendable {
    let beforeWaiterRegistration:
        (@Sendable (URLSessionDownloadTask, StreamTransferDescriptor) -> Void)?

    let didFinishCollecting: (@Sendable (URLSessionTaskMetrics) -> Void)?

    init(
        beforeWaiterRegistration: (@Sendable (URLSessionDownloadTask, StreamTransferDescriptor) -> Void)?,
        didFinishCollecting: (@Sendable (URLSessionTaskMetrics) -> Void)? = nil
    ) {
        self.beforeWaiterRegistration = beforeWaiterRegistration
        self.didFinishCollecting = didFinishCollecting
    }

    static let none = StreamDownloadServiceHooks(beforeWaiterRegistration: nil)
}

enum HLSResourceRedirectValidation {
    static func redirectedRequest(
        destinationURL: URL,
        HTTPHeaders: [String: String],
        byteRange: HLSMediaByteRange?,
        timeoutInterval: TimeInterval,
        allowsExpensiveAccess: Bool,
        allowsConstrainedAccess: Bool,
        visitedURLs: inout Set<String>,
        redirectCount: inout Int,
        maximumRedirects: Int
    ) throws -> URLRequest {
        guard redirectCount < maximumRedirects else {
            throw HLSResourceStagingError.tooManyRedirects
        }
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(destinationURL),
            HLSPlaylistSecurity.areAllowedHeaders(HTTPHeaders),
            visitedURLs.insert(destinationURL.absoluteString).inserted
        else {
            throw HLSResourceStagingError.unsafeRedirect
        }
        var request = URLRequest(url: destinationURL)
        request.assumesHTTP3Capable = MediaTransportProtocolPolicy.assumesHTTP3Capable(destinationURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.allowsExpensiveNetworkAccess = allowsExpensiveAccess
        request.allowsConstrainedNetworkAccess = allowsConstrainedAccess
        for (name, value) in HTTPHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let byteRange {
            guard let range = byteRange.streamRange else {
                throw HLSResourceStagingError.invalidPlan
            }
            request.setValue(
                range.HTTPHeaderValue,
                forHTTPHeaderField: "Range"
            )
        }
        redirectCount += 1
        return request
    }
}

enum StreamDownloadError: LocalizedError, Equatable, Sendable {
    case networkFailure
    case couldNotCommitFile
    case cancelled
    case unauthorizedHTTPFailure(statusCode: Int)
    case forbiddenHTTPFailure(statusCode: Int)
    case goneHTTPFailure(statusCode: Int)
    case transientHTTPFailure(statusCode: Int)
    case permanentHTTPFailure(statusCode: Int)
    case invalidPartialContent
    case rangeAssemblyFailure

    static func HTTPFailure(statusCode: Int) -> Self {
        switch statusCode {
        case 401: .unauthorizedHTTPFailure(statusCode: statusCode)
        case 403: .forbiddenHTTPFailure(statusCode: statusCode)
        case 410: .goneHTTPFailure(statusCode: statusCode)
        case 429, 500 ... 599: .transientHTTPFailure(statusCode: statusCode)
        default: .permanentHTTPFailure(statusCode: statusCode)
        }
    }

    var diagnosticCode: String {
        switch self {
        case .networkFailure: "stream_network_failure"
        case .couldNotCommitFile: "stream_commit_failed"
        case .cancelled: "cancelled"
        case let .unauthorizedHTTPFailure(statusCode):
            "http_\(statusCode)_unauthorized"
        case let .forbiddenHTTPFailure(statusCode):
            "http_\(statusCode)_forbidden"
        case let .goneHTTPFailure(statusCode):
            "http_\(statusCode)_gone"
        case let .transientHTTPFailure(statusCode):
            "http_\(statusCode)_transient"
        case let .permanentHTTPFailure(statusCode):
            statusCode == 0
                ? "invalid_http_response"
                : "http_\(statusCode)_permanent"
        case .invalidPartialContent: "invalid_partial_content"
        case .rangeAssemblyFailure: "range_assembly_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .networkFailure: "The direct media transfer failed."
        case .couldNotCommitFile:
            "The downloaded stream could not be committed to temporary storage."
        case .cancelled: "The media transfer was cancelled."
        case let .unauthorizedHTTPFailure(statusCode):
            "The media server requires authorization (HTTP \(statusCode))."
        case let .forbiddenHTTPFailure(statusCode):
            "The media server denied access to the selected stream (HTTP \(statusCode))."
        case let .goneHTTPFailure(statusCode):
            "The selected stream is no longer available (HTTP \(statusCode))."
        case let .transientHTTPFailure(statusCode):
            "The media server temporarily failed (HTTP \(statusCode))."
        case let .permanentHTTPFailure(statusCode):
            statusCode == 0
                ? "The media server returned an invalid response."
                : "The media server rejected the transfer (HTTP \(statusCode))."
        case .invalidPartialContent:
            "The media server returned invalid partial-content bytes."
        case .rangeAssemblyFailure:
            "The verified media ranges could not be assembled."
        }
    }
}

enum DASHFragmentDownloadError: LocalizedError, Equatable, Sendable {
    case invalidPlan
    case invalidStagingDestination
    case couldNotStageFragment
    case couldNotDiscardRejectedBytes
    case fragmentByteCountMismatch(
        position: Int,
        expected: Int64,
        actual: Int64
    )
    case aggregateByteCountMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The ordered DASH fragment plan is invalid."
        case .invalidStagingDestination:
            "The DASH fragment staging location is not app controlled."
        case .couldNotStageFragment:
            "A DASH fragment could not be committed to staging."
        case .couldNotDiscardRejectedBytes:
            "Rejected DASH fragment bytes could not be removed from staging."
        case let .fragmentByteCountMismatch(position, expected, actual):
            "DASH fragment \(position) has \(actual) bytes; expected \(expected)."
        case let .aggregateByteCountMismatch(expected, actual):
            "The staged DASH fragments have \(actual) bytes; expected \(expected)."
        }
    }
}

enum HLSResourceStagingError: LocalizedError, Equatable, Sendable {
    case invalidPlan
    case invalidStagingDestination
    case networkFailure
    case unsafeRedirect
    case tooManyRedirects
    case invalidHTTPResponse
    case invalidContentLength
    case invalidPartialContent
    case couldNotStageResource
    case couldNotCleanStaging

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The ordered HLS resource plan is invalid."
        case .invalidStagingDestination:
            "The HLS resource staging location is not app controlled."
        case .networkFailure:
            "The HLS resource transfer failed."
        case .unsafeRedirect:
            "The HLS resource redirected to an unsafe destination."
        case .tooManyRedirects:
            "The HLS resource redirected too many times."
        case .invalidHTTPResponse:
            "The HLS resource server returned an invalid response."
        case .invalidContentLength:
            "The HLS resource response length is malformed."
        case .invalidPartialContent:
            "The HLS resource server returned invalid partial content."
        case .couldNotStageResource:
            "An HLS resource could not be committed to staging."
        case .couldNotCleanStaging:
            "Rejected HLS staging bytes could not be removed."
        }
    }
}
