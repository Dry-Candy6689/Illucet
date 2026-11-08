import Foundation
import Network
import Testing
@testable import Illucet

struct BandwidthTransportTests {
    @Test(arguments: [false, true])
    func handoffBalancesOwnedSuspensionBeforeNativeStateChanges(userPaused: Bool) {
        let task = BandwidthDelayedStateTask()
        let limiter = TransferBandwidthLimiter()
        let id = UUID()
        limiter.configure(global: 16_384)
        limiter.throttle(task, bytes: 16_384_000, jobID: id)
        #expect(task.suspendCalls == 1)
        if userPaused { #expect(limiter.pause(task)) }
        #expect(task.suspendCalls == 1)
        limiter.setForegroundActive(false)
        #expect(task.resumeCalls == (userPaused ? 0 : 1))
        limiter.setForegroundActive(true)
        limiter.setForegroundActive(false)
        #expect(task.resumeCalls == (userPaused ? 0 : 1))
        limiter.complete(task)
    }

    @Test(arguments: [false, true])
    func nativeDownloadWaitsForItsStagingAcknowledgement(injectFailure: Bool) async throws {
        let server = try LocalBandwidthServer()
        defer { server.stop() }
        let port = try await server.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = StreamDownloadService(sessionIdentifier: "test.receipt." + UUID().uuidString, configuration: .ephemeral)
        defer { service.session.invalidateAndCancel() }
        let gate = BandwidthReceiptGate()
        service.setAcknowledgementHandler { _, _, _ in
            await gate.wait()
            if injectFailure { throw NativeTransferCheckpointError.persistenceUnavailable }
        }
        let stream = ResolvedStream(formatID: "137", URL: URL(string: "http://127.0.0.1:\(port)/fixture")!, HTTPHeaders: [:],
            fileExtension: "mp4", protocolName: "http", sourceType: "direct_http", hasVideo: true, hasAudio: false,
            expectedBytes: Int64(LocalBandwidthServer.byteCount), httpChunkSize: 1_048_576)
        let finished = BandwidthAdmissionFlag()
        let transfer = Task {
            defer { Task { await finished.mark() } }
            return try await service.download(stream, jobID: UUID(), destinationURL: root.appendingPathComponent("137.mp4"),
                verifiedExpectedBytes: Int64(LocalBandwidthServer.byteCount), progress: { _ in })
        }
        for _ in 0..<200 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        #expect(!(await finished.value))
        await gate.release()
        if injectFailure {
            await #expect(throws: NativeTransferCheckpointError.self) { try await transfer.value }
        } else {
            let result = try await transfer.value
            #expect(try result.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == LocalBandwidthServer.byteCount)
        }
    }

    @Test(arguments: [false, true])
    func losingForegroundReleasesOnlyLimiterSuspension(userPaused: Bool) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FrozenBandwidthURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://bandwidth.invalid/" + UUID().uuidString)!
        let task = session.dataTask(with: url)
        task.resume()
        for _ in 0..<100 where !FrozenBandwidthURLProtocol.hasStarted(url) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(FrozenBandwidthURLProtocol.hasStarted(url))
        for _ in 0..<100 where task.state != .running { try await Task.sleep(for: .milliseconds(5)) }
        try #require(task.state == .running)
        let limiter = TransferBandwidthLimiter()
        let jobID = UUID()
        limiter.configure(global: 16_384)
        limiter.throttle(task, bytes: 16_384_000, jobID: jobID)
        #expect(task.state == .suspended)
        if userPaused { #expect(limiter.pause(task)); _ = limiter.pauseAdmission(jobID: jobID) }
        limiter.setForegroundActive(false)
        if !userPaused {
            for _ in 0..<100 where task.state != .running { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(task.state == (userPaused ? .suspended : .running))
        #expect(!limiter.isThrottled(task))
        task.cancel()
        limiter.complete(task)
    }

    @Test
    func backgroundAdmissionIgnoresOldRateDeadlineWithoutAClockWakeup() async throws {
        let timerEntered = BandwidthAdmissionFlag()
        let limiter = TransferBandwidthLimiter(admissionSleeper: { _ in
            await timerEntered.mark()
            try await Task.sleep(for: .seconds(3_600)) // Never fires during the test.
        })
        let jobID = UUID()
        limiter.configure(global: 16_384)
        _ = limiter.reserve(bytes: 16_384_000, jobID: jobID, now: ProcessInfo.processInfo.systemUptime)
        let entered = BandwidthAdmissionFlag()
        let admission = Task { try await limiter.waitForAdmission(jobID: jobID); await entered.mark() }
        for _ in 0..<100 where !(await timerEntered.value) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await timerEntered.value)
        #expect(!(await entered.value))
        limiter.setForegroundActive(false)
        for _ in 0..<100 where !(await entered.value) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await entered.value)
        admission.cancel()
        _ = try? await admission.value
    }
    @Test func pauseBeforeAnyRequestStillHoldsTheNextAdmission() async throws {
        let limiter = TransferBandwidthLimiter()
        let jobID = UUID()
        #expect(limiter.pauseAdmission(jobID: jobID) == 0)
        let entered = BandwidthAdmissionFlag()
        let task = Task { try await limiter.waitForAdmission(jobID: jobID); await entered.mark() }
        // The paused path must suspend rather than finish immediately.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await entered.value == false)
        _ = limiter.resumeAdmission(jobID: jobID)
        try await task.value
        #expect(await entered.value)
    }

    @Test func limiterSlowsAnActualLocalTransfer() async throws {
        let server = try LocalBandwidthServer()
        defer { server.stop() }
        let port = try await server.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = StreamTransferDestinationRoots(temporaryDirectory: root, applicationSupportDirectory: root.appendingPathComponent("support"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 35
        let service = StreamDownloadService(sessionIdentifier: "test.bandwidth." + UUID().uuidString,
            configuration: configuration, destinationRoots: roots)
        defer { service.session.invalidateAndCancel() }
        service.bandwidthLimiter.configure(global: 1_048_576)
        let stream = ResolvedStream(formatID: "137", URL: URL(string: "http://127.0.0.1:\(port)/fixture")!, HTTPHeaders: [:],
            fileExtension: "mp4", protocolName: "http", sourceType: "direct_http", hasVideo: true, hasAudio: false,
            expectedBytes: Int64(LocalBandwidthServer.byteCount), httpChunkSize: nil)
        let start = ContinuousClock.now
        let result = try await service.download(stream, jobID: UUID(), destinationURL: root.appendingPathComponent("137.mp4"),
            verifiedExpectedBytes: Int64(LocalBandwidthServer.byteCount), progress: { _ in })
        #expect(try result.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == LocalBandwidthServer.byteCount)
        #expect(result.requestedRangeCount == 8)
        #expect(start.duration(to: .now) >= .seconds(6))
    }
}

private final class FrozenBandwidthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: Set<URL> = []
    static func hasStarted(_ url: URL) -> Bool { lock.withLock { started.contains(url) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if let url = request.url { _ = Self.lock.withLock { Self.started.insert(url) } } }
    override func stopLoading() {}
}

private final class BandwidthDelayedStateTask: URLSessionDataTask, @unchecked Sendable {
    private let lock = NSLock()
    private var suspends = 0
    private var resumes = 0
    override var taskIdentifier: Int { 42 }
    // Simulate URLSession's delayed state observation after suspend().
    override var state: URLSessionTask.State { .running }
    override var countOfBytesReceived: Int64 { 0 }
    override func suspend() { lock.withLock { suspends += 1 } }
    override func resume() { lock.withLock { resumes += 1 } }
    var suspendCalls: Int { lock.withLock { suspends } }
    var resumeCalls: Int { lock.withLock { resumes } }
}

private final class LocalBandwidthServer: @unchecked Sendable {
    static let byteCount = 8 * 1_048_576
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Illucet.bandwidth.fixture")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { requestData, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    let request = String(decoding: requestData ?? Data(), as: UTF8.self)
                    let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
                    let numbers = rangeLine?.dropFirst("range: bytes=".count).split(separator: "-").compactMap { Int($0) } ?? []
                    guard numbers.count == 2, numbers[0] >= 0, numbers[1] >= numbers[0], numbers[1] < Self.byteCount else { connection.cancel(); return }
                    let count = numbers[1] - numbers[0] + 1
                    let header = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: \(count)\r\nContent-Range: bytes \(numbers[0])-\(numbers[1])/\(Self.byteCount)\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: header, completion: .contentProcessed { error in
                        if error == nil { self.send(connection, remaining: count) }
                        else { connection.cancel() }
                    })
                }
            }
            listener.start(queue: queue)
        }
    }
    private func send(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        let amount = min(16_384, remaining)
        connection.send(content: Data(repeating: 65, count: amount), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { self.send(connection, remaining: remaining - amount) }
        })
    }
    func stop() { listener.cancel() }
}

private actor BandwidthAdmissionFlag {
    private(set) var value = false
    func mark() { value = true }
}

private actor BandwidthReceiptGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
