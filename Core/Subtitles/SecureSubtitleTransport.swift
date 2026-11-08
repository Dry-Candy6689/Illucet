import Foundation
import Network

struct SubtitleIPAddress: Hashable, Sendable {
    private enum Family: Hashable, Sendable {
        case IPv4
        case IPv6
    }

    private let family: Family
    private let bytes: Data

    init?(_ value: String) {
        if let address = IPv4Address(value) {
            family = .IPv4
            bytes = address.rawValue
        } else if let address = IPv6Address(value) {
            family = .IPv6
            bytes = address.rawValue
        } else {
            return nil
        }
    }

    var isPublic: Bool {
        switch family {
        case .IPv4:
            isPublicIPv4([UInt8](bytes))
        case .IPv6:
            isPublicIPv6([UInt8](bytes))
        }
    }

    private func isPublicIPv4(_ value: [UInt8]) -> Bool {
        guard value.count == 4 else { return false }
        let first = value[0]
        let second = value[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 {
            return false
        }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 {
            if second == 168 { return false }
            if second == 0 {
                if value[2] == 0 {
                    return value[3] == 9 || value[3] == 10
                }
                if value[2] == 2 { return false }
            }
            if second == 88 && value[2] == 99 { return false }
        }
        if first == 198 {
            if second == 18 || second == 19 { return false }
            if second == 51 && value[2] == 100 { return false }
        }
        if first == 203 && second == 0 && value[2] == 113 { return false }
        return true
    }

    private func isPublicIPv6(_ value: [UInt8]) -> Bool {
        guard value.count == 16 else { return false }
        if value.allSatisfy({ $0 == 0 }) { return false }
        if value.dropLast().allSatisfy({ $0 == 0 }) && value.last == 1 {
            return false
        }
        if value[0] == 0xff { return false }
        if value[0] == 0xfe && (value[1] & 0xc0) == 0x80 { return false }
        if (value[0] & 0xfe) == 0xfc { return false }
        if value.prefix(10).allSatisfy({ $0 == 0 })
            && value[10] == 0xff && value[11] == 0xff {
            return false
        }
        if value[0] == 0x00 && value[1] == 0x64
            && value[2] == 0xff && value[3] == 0x9b {
            return false
        }
        if value[0] == 0x01 && value[1] == 0x00
            && value[2...7].allSatisfy({ $0 == 0 }) {
            return false
        }
        if value[0] == 0x20 && value[1] == 0x01
            && value[2] <= 0x01 {
            return false
        }
        if value[0] == 0x20 && value[1] == 0x01
            && value[2] == 0x0d && value[3] == 0xb8 {
            return false
        }
        if value[0] == 0x20 && value[1] == 0x02 { return false }
        if value[0] == 0x3f && value[1] == 0xff { return false }
        if value[0] == 0x5f { return false }
        // Current globally routable unicast space. This deliberately fails
        // closed for non-global and future-reserved ranges.
        return (value[0] & 0xe0) == 0x20
    }
}

protocol SubtitleDNSResolving: Sendable {
    func addresses(for host: String) async throws -> Set<SubtitleIPAddress>
}

struct SystemSubtitleDNSResolver: SubtitleDNSResolving {
    func addresses(for host: String) async throws -> Set<SubtitleIPAddress> {
        try await Task.detached(priority: .utility) {
            var buffer = [CChar](repeating: 0, count: 4_096)
            var count: Int = 0
            let status = host.withCString { hostPointer in
                illucet_resolve_host(
                    hostPointer,
                    &buffer,
                    buffer.count,
                    &count
                )
            }
            let text = String(
                decoding: buffer.prefix { $0 != 0 }.map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self
            )
            return try Self.addresses(
                nativeStatus: status,
                output: text,
                addressCount: count
            )
        }.value
    }

    static func addresses(
        nativeStatus: Int32,
        output: String,
        addressCount: Int
    ) throws -> Set<SubtitleIPAddress> {
        guard nativeStatus == 0, addressCount > 0 else {
            throw SubtitlePipelineError.DNSResolutionFailed
        }
        let addresses = Set(output.split(separator: "\n").compactMap {
            SubtitleIPAddress(String($0))
        })
        guard addresses.count == addressCount else {
            throw SubtitlePipelineError.DNSResolutionFailed
        }
        return addresses
    }
}

#if DEBUG
struct NativeSubtitleDNSInspection: Sendable {
    let status: Int32
    let output: String
    let addressCount: Int
}

extension SystemSubtitleDNSResolver {
    static func inspectNumericAnswerChainForTesting(
        _ answers: [String],
        outputCapacity: Int = 4_096
    ) -> NativeSubtitleDNSInspection {
        var buffer = [CChar](
            repeating: 0,
            count: max(outputCapacity, 0)
        )
        var count = 0
        let chain = answers.joined(separator: "\n")
        let status = chain.withCString { chainPointer in
            illucet_test_inspect_numeric_answer_chain(
                chainPointer,
                &buffer,
                buffer.count,
                &count
            )
        }
        let text = String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        return NativeSubtitleDNSInspection(
            status: status,
            output: text,
            addressCount: count
        )
    }
}
#endif

struct SubtitleHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var redirectLocation: String? {
        headers.first { $0.key.lowercased() == "location" }?.value
    }
}

protocol SubtitleHTTPNetworking: Sendable {
    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> SubtitleHTTPResponse
}

struct SubtitleSessionPolicy: Equatable, Sendable {
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

final class URLSessionSubtitleHTTPClient:
    SubtitleHTTPNetworking,
    @unchecked Sendable
{
    let policy: SubtitleSessionPolicy

    init(policy: SubtitleSessionPolicy = .secure) {
        self.policy = policy
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> SubtitleHTTPResponse {
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
        return try await BoundedSubtitleRequest.perform(
            request: request,
            configuration: configuration,
            maximumBytes: maximumBytes
        )
    }
}

final class BoundedSubtitleRequest:
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
    private var continuation: CheckedContinuation<SubtitleHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var cancellationRequested = false
    private var boundedError: SubtitlePipelineError?

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
    ) async throws -> SubtitleHTTPResponse {
        let operation = BoundedSubtitleRequest(
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

    private func start() async throws -> SubtitleHTTPResponse {
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
        let exceeds = HTTPResponse.expectedContentLength > Int64(maximumBytes)
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
            guard self.data.count <= maximumBytes - data.count else {
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
            CheckedContinuation<SubtitleHTTPResponse, Error>?,
            Result<SubtitleHTTPResponse, Error>
        ) = lock.withLock {
            guard !finished else {
                return (nil, .failure(SubtitlePipelineError.HTTPFailure))
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
            if let error {
                return (
                    continuation,
                    .failure(
                        (error as NSError).code == NSURLErrorCancelled
                            ? CancellationError()
                            : SubtitlePipelineError.HTTPFailure
                    )
                )
            }
            guard let response else {
                return (
                    continuation,
                    .failure(SubtitlePipelineError.HTTPFailure)
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
                    SubtitleHTTPResponse(
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

protocol SubtitleTransporting: Sendable {
    func download(from URL: URL) async throws -> Data
}

struct SecureSubtitleTransport: SubtitleTransporting {
    static let maximumURLBytes = 4_096
    static let maximumSubtitleBytes = WebVTTProcessor.maximumInputBytes

    private let resolver: any SubtitleDNSResolving
    private let networking: any SubtitleHTTPNetworking
    private let policy: SubtitleSessionPolicy

    init(
        resolver: any SubtitleDNSResolving,
        networking: any SubtitleHTTPNetworking,
        policy: SubtitleSessionPolicy = .secure
    ) {
        self.resolver = resolver
        self.networking = networking
        self.policy = policy
    }

    func download(from URL: URL) async throws -> Data {
        var current = URL
        var redirects = 0
        var observed: [String: Set<SubtitleIPAddress>] = [:]
        var visited: Set<String> = []

        while true {
            try Task.checkCancellation()
            let components = try validatedComponents(current)
            guard let host = components.host?.lowercased() else {
                throw SubtitlePipelineError.unsafeDestination
            }
            let visitKey = current.absoluteString
            guard visited.insert(visitKey).inserted else {
                throw SubtitlePipelineError.tooManyRedirects
            }
            let before = try await validatedAddresses(host: host)
            try verifyStable(before, host: host, observed: &observed)

            var request = URLRequest(url: current)
            request.httpMethod = "GET"
            request.timeoutInterval = policy.requestTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("text/vtt, text/plain;q=0.9", forHTTPHeaderField: "Accept")
            let response = try await networking.response(
                for: request,
                maximumBytes: Self.maximumSubtitleBytes
            )

            let after = try await validatedAddresses(host: host)
            guard !before.isDisjoint(with: after) else {
                throw SubtitlePipelineError.DNSAnswerChanged
            }
            try verifyStable(after, host: host, observed: &observed)

            if (200...299).contains(response.statusCode) {
                guard response.body.count <= Self.maximumSubtitleBytes else {
                    throw SubtitlePipelineError.responseTooLarge
                }
                guard !response.body.isEmpty else {
                    throw SubtitlePipelineError.unusableResponse(.emptyBody)
                }
                return response.body
            }
            if [401, 403, 404, 410].contains(response.statusCode) {
                throw SubtitlePipelineError.expiredTransport
            }
            if (300...399).contains(response.statusCode) {
                guard redirects < policy.maximumRedirects,
                      let location = response.redirectLocation,
                      location.utf8.count <= Self.maximumURLBytes,
                      let redirected = Foundation.URL(
                          string: location,
                          relativeTo: current
                      )?
                        .absoluteURL
                else {
                    throw SubtitlePipelineError.tooManyRedirects
                }
                guard redirected.scheme?.lowercased() == "https" else {
                    throw SubtitlePipelineError.insecureRedirect
                }
                current = redirected
                redirects += 1
                continue
            }
            throw SubtitlePipelineError.HTTPFailure
        }
    }

    private func validatedComponents(_ URL: URL) throws -> URLComponents {
        let raw = URL.absoluteString
        guard
            raw.utf8.count <= Self.maximumURLBytes,
            raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.contains("\\"),
            !raw.unicodeScalars.contains(where: {
                $0.value < 0x20 || CharacterSet.whitespacesAndNewlines.contains($0)
            }),
            let components = URLComponents(
                url: URL,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty,
            components.port != 0,
            host.lowercased() != "localhost",
            !host.lowercased().hasSuffix(".localhost"),
            !host.lowercased().hasSuffix(".local")
        else {
            throw SubtitlePipelineError.unsafeDestination
        }
        return components
    }

    private func validatedAddresses(
        host: String
    ) async throws -> Set<SubtitleIPAddress> {
        let values: Set<SubtitleIPAddress>
        if let literal = SubtitleIPAddress(host) {
            values = [literal]
        } else {
            values = try await resolver.addresses(for: host)
        }
        guard !values.isEmpty, values.allSatisfy(\.isPublic) else {
            throw SubtitlePipelineError.unsafeDestination
        }
        return values
    }

    private func verifyStable(
        _ current: Set<SubtitleIPAddress>,
        host: String,
        observed: inout [String: Set<SubtitleIPAddress>]
    ) throws {
        if let previous = observed[host],
           previous.isDisjoint(with: current) {
            throw SubtitlePipelineError.DNSAnswerChanged
        }
        if observed[host] == nil { observed[host] = current }
    }
}
