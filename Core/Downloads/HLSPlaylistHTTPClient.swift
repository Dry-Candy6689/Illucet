import Foundation

struct HLSPlaylistHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var redirectLocation: String? {
        headers.first { $0.key.lowercased() == "location" }?.value
    }
}

protocol HLSPlaylistNetworking: Sendable {
    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> HLSPlaylistHTTPResponse
}

struct HLSPlaylistSessionPolicy: Equatable, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let maximumRedirects: Int
    let acceptsCookies: Bool
    let usesCredentialStorage: Bool
    let usesURLCache: Bool
    let usesDefaultTLSVerification: Bool

    static let secure = Self(
        requestTimeout: 15,
        resourceTimeout: 45,
        maximumRedirects: 4,
        acceptsCookies: false,
        usesCredentialStorage: false,
        usesURLCache: false,
        usesDefaultTLSVerification: true
    )
}

final class URLSessionHLSPlaylistHTTPClient:
    HLSPlaylistNetworking,
    @unchecked Sendable
{
    let policy: HLSPlaylistSessionPolicy

    init(policy: HLSPlaylistSessionPolicy = .secure) {
        self.policy = policy
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> HLSPlaylistHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.timeoutIntervalForResource = policy.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        return try await BoundedHLSPlaylistRequest.perform(
            request: request,
            configuration: configuration,
            maximumBytes: maximumBytes
        )
    }
}

final class BoundedHLSPlaylistRequest:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<
        HLSPlaylistHTTPResponse,
        Error
    >?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var cancellationRequested = false
    private var boundedError: HLSPlaylistTransportError?

    private init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int
    ) {
        self.request = request
        self.configuration = configuration
        self.maximumBytes = maximumBytes
    }

    static func perform(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int
    ) async throws -> HLSPlaylistHTTPResponse {
        guard maximumBytes > 0 else {
            throw HLSPlaylistTransportError.responseTooLarge
        }
        let operation = BoundedHLSPlaylistRequest(
            request: request,
            configuration: configuration,
            maximumBytes: maximumBytes
        )
        return try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }

    private func start() async throws -> HLSPlaylistHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                // onCancel also runs for a task cancelled before perform starts.
                // Retain that signal until there is a URLSession task to cancel.
                guard !cancellationRequested else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }
    }

    private func cancel() {
        lock.withLock {
            cancellationRequested = true
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.withLock { self.response = response }
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let HTTPResponse = response as? HTTPURLResponse else {
            lock.withLock { boundedError = .HTTPFailure }
            completionHandler(.cancel)
            return
        }
        // Error bodies are irrelevant; retain the status without reading HTML
        // that would otherwise mask a retryable server failure as oversized.
        if HTTPResponse.statusCode >= 400 {
            lock.withLock { self.response = HTTPResponse }
            completionHandler(.cancel)
            return
        }
        let exceeds = request.httpMethod != "HEAD"
            && HTTPResponse.expectedContentLength > Int64(maximumBytes)
        lock.withLock {
            self.response = HTTPResponse
            if exceeds { boundedError = .responseTooLarge }
        }
        completionHandler(exceeds ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock {
            guard data.count <= maximumBytes - self.data.count else {
                boundedError = .responseTooLarge
                return true
            }
            self.data.append(data)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion: (
            CheckedContinuation<HLSPlaylistHTTPResponse, Error>?,
            Result<HLSPlaylistHTTPResponse, Error>
        ) = lock.withLock {
            guard !finished else {
                return (nil, .failure(HLSPlaylistTransportError.HTTPFailure))
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            if cancellationRequested {
                return (continuation, .failure(CancellationError()))
            }
            if let boundedError {
                return (continuation, .failure(boundedError))
            }
            if let response, response.statusCode >= 400 {
                return (
                    continuation,
                    .failure(StreamDownloadError.HTTPFailure(statusCode: response.statusCode))
                )
            }
            if let error {
                let failure: any Error
                if let URLFailure = error as? URLError {
                    failure = URLFailure.code == .cancelled
                        ? CancellationError()
                        : URLError(URLFailure.code)
                } else {
                    failure = HLSPlaylistTransportError.HTTPFailure
                }
                return (continuation, .failure(failure))
            }
            guard let response else {
                return (
                    continuation,
                    .failure(HLSPlaylistTransportError.HTTPFailure)
                )
            }
            let headers = response.allHeaderFields.reduce(
                into: [String: String]()
            ) { result, entry in
                guard let key = entry.key as? String,
                      let value = entry.value as? String
                else { return }
                result[key] = value
            }
            return (
                continuation,
                .success(
                    HLSPlaylistHTTPResponse(
                        statusCode: response.statusCode,
                        headers: headers,
                        body: data
                    )
                )
            )
        }
        session.finishTasksAndInvalidate()
        guard let continuation = completion.0 else { return }
        continuation.resume(with: completion.1)
    }
}

enum HLSPlaylistTransportError: LocalizedError, Equatable, Sendable {
    case unsafeDestination
    case invalidHeaders
    case HTTPFailure
    case expiredTransport
    case tooManyRedirects
    case responseTooLarge
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unsafeDestination:
            "The HLS playlist destination is not allowed."
        case .invalidHeaders:
            "The HLS playlist request headers are invalid."
        case .HTTPFailure:
            "The HLS playlist request failed."
        case .expiredTransport:
            "The HLS playlist URL expired or became unavailable."
        case .tooManyRedirects:
            "The HLS playlist redirected too many times."
        case .responseTooLarge:
            "The HLS playlist exceeds Illucet's safety limit."
        case .emptyResponse:
            "The HLS playlist response was empty."
        }
    }
}
