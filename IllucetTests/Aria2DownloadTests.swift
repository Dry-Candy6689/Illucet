import CryptoKit
import Foundation
import Network
import Testing
@testable import Illucet

@Suite(.serialized)
struct Aria2DownloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLUCET_ARIA2_TLS_FIXTURE_CONFIG"] != nil))
    func validatesTLSWithoutChangingSystemTrust() async throws {
        struct Fixture: Decodable { let port: UInt16; let certificate: URL; let sha256: String; let bytes: Int64 }
        let path = try #require(ProcessInfo.processInfo.environment["ILLUCET_ARIA2_TLS_FIXTURE_CONFIG"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(filePath: path)))
        let source = stream(URL(string: "https://127.0.0.1:\(fixture.port)/payload")!)
        for trustFixture in [true, false] {
            let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appending(path: "tls")
            let downloader = NativeAria2Downloader(certificateURL: trustFixture ? fixture.certificate : nil)
            do {
                let output = try await downloader.download(source, jobID: id, destinationURL: destination,
                    expectedBytes: fixture.bytes, speedLimit: nil) { _ in }
                #expect(trustFixture, "An untrusted certificate must not be accepted")
                let hash = SHA256.hash(data: try Data(contentsOf: output)).map { String(format: "%02x", $0) }.joined()
                #expect(hash == fixture.sha256)
            } catch {
                #expect(!trustFixture, "The explicitly trusted fixture must download")
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
            #expect(try privateStages(root).isEmpty)
        }
    }

    @Test func preservesSettingsAndRestrictsEligibleTransports() throws {
        var preferences = EnginePreferences()
        #expect(preferences.download == .automatic)
        preferences.download = .aria2
        #expect(try JSONDecoder().decode(EnginePreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
        let direct = stream(URL(string: "https://media.example/file")!)
        #expect(Aria2TransferPolicy.permits(stream: direct, accountID: nil))
        #expect(!Aria2TransferPolicy.permits(stream: direct, accountID: UUID()))
        for headers in [["Cookie": "session=fixture"], ["Authorization": "fixture"], ["Referer": "a\r\nInjected: b"]] {
            #expect(!Aria2TransferPolicy.permits(stream: stream(direct.URL, headers: headers), accountID: nil))
        }
        #expect(!Aria2TransferPolicy.permits(stream: stream(direct.URL, protocolName: "m3u8_native"), accountID: nil))
    }

    @Test func ignoresExternalConfigurationThatWouldExportTransportData() async throws {
        let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath()
        let container = FileManager.default.temporaryDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
        try #require(home.path == container.path, "Use only the isolated app container for the configuration fixture")
        let configurationDirectory = home.appending(path: ".aria2")
        let configuration = configurationDirectory.appending(path: "aria2.conf")
        try #require(!FileManager.default.fileExists(atPath: configuration.path), "Never overwrite an existing configuration")
        let createdDirectory = !FileManager.default.fileExists(atPath: configurationDirectory.path)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: configuration)
            if createdDirectory { try? FileManager.default.removeItem(at: configurationDirectory) }
        }
        let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "must-not-log.txt"), session = root.appending(path: "must-not-export.txt")
        try Data("log=\(log.path)\nlog-level=debug\nsave-session=\(session.path)\nforce-save=true\n".utf8).write(to: configuration)
        let server = try Aria2LoopbackServer(); defer { server.stop() }
        let port = try await server.start()
        _ = try await NativeAria2Downloader.shared.download(stream(URL(string: "http://127.0.0.1:\(port)/file")!),
            jobID: id, destinationURL: root.appending(path: "output"), expectedBytes: Int64(Aria2LoopbackServer.payload.count),
            speedLimit: nil) { _ in }
        await NativeAria2Downloader.shared.cancel(jobID: id) // Drain final session teardown too.
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(!FileManager.default.fileExists(atPath: session.path))
    }

    @Test(arguments: ["file", "ignore"])
    func transfersExactBytesAndCleansPrivateStages(route: String) async throws {
        let server = try Aria2LoopbackServer(); defer { server.stop() }
        let port = try await server.start()
        let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appending(path: ".aria2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data("unfinished".utf8).write(to: orphan.appending(path: "payload"))
        let destination = root.appending(path: "complete.bin")
        let result = try await NativeAria2Downloader.shared.download(stream(URL(string: "http://127.0.0.1:\(port)/\(route)")!),
            jobID: id, destinationURL: destination, expectedBytes: Int64(Aria2LoopbackServer.payload.count),
            speedLimit: nil) { _ in }
        #expect(result == destination)
        #expect(SHA256.hash(data: try Data(contentsOf: result)) == SHA256.hash(data: Aria2LoopbackServer.payload))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try privateStages(root).isEmpty)
        if route == "file" { #expect(server.rangeRequests > 0) }
    }

    @Test func simultaneousFilesShareOneLibraryWorker() async throws {
        let server = try Aria2LoopbackServer(); defer { server.stop() }
        let port = try await server.start()
        let a = UUID(), b = UUID(); let first = try directory(a), second = try directory(b)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let source = stream(URL(string: "http://127.0.0.1:\(port)/file")!)
        async let left = NativeAria2Downloader.shared.download(source, jobID: a, destinationURL: first.appending(path: "left"),
            expectedBytes: Int64(Aria2LoopbackServer.payload.count), speedLimit: nil) { _ in }
        async let right = NativeAria2Downloader.shared.download(source, jobID: b, destinationURL: second.appending(path: "right"),
            expectedBytes: Int64(Aria2LoopbackServer.payload.count), speedLimit: nil) { _ in }
        for file in try await [left, right] {
            #expect(SHA256.hash(data: try Data(contentsOf: file)) == SHA256.hash(data: Aria2LoopbackServer.payload))
        }
    }

    @Test(arguments: ["forbidden", "truncated", "wrong-length"])
    func failedTransfersNeverPublishPartialFiles(route: String) async throws {
        let server = try Aria2LoopbackServer(); defer { server.stop() }
        let port = try await server.start()
        let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "output")
        do {
            _ = try await NativeAria2Downloader.shared.download(stream(URL(string: "http://127.0.0.1:\(port)/\(route)")!),
                jobID: id, destinationURL: destination,
                expectedBytes: Int64(Aria2LoopbackServer.payload.count + (route == "wrong-length" ? 1 : 0)),
                speedLimit: nil) { _ in }
            Issue.record("An incomplete or rejected response must fail")
        } catch { #expect(error is Aria2TransferError) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try privateStages(root).isEmpty)
    }

    @Test func cancellationWaitsForNativeTeardownAndRemovesPartialData() async throws {
        let server = try Aria2LoopbackServer(); defer { server.stop() }
        let port = try await server.start()
        let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "cancelled")
        let received = Aria2ObservedBytes()
        let source = stream(URL(string: "http://127.0.0.1:\(port)/slow")!)
        let task = Task {
            try await NativeAria2Downloader.shared.download(source, jobID: id, destinationURL: destination,
                expectedBytes: Int64(Aria2LoopbackServer.payload.count), speedLimit: 131_072) { received.record($0.totalBytesWritten) }
        }
        let deadline = Date().addingTimeInterval(10)
        while received.value == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(received.value > 0)
        task.cancel()
        await NativeAria2Downloader.shared.cancel(jobID: id)
        #expect(try privateStages(root).isEmpty)
        do { _ = try await task.value; Issue.record("A cancelled transfer must not succeed") }
        catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try privateStages(root).isEmpty)
    }

    @Test func rejectsDestinationsOutsideTheExactJobRoot() async throws {
        let id = UUID(); let root = try directory(id); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            _ = try await NativeAria2Downloader.shared.download(stream(URL(string: "https://media.example/file")!),
                jobID: id, destinationURL: outside, expectedBytes: nil, speedLimit: nil) { _ in }
            Issue.record("Outside output must be rejected before networking")
        } catch { #expect(!FileManager.default.fileExists(atPath: outside.path)) }
    }

    private func directory(_ id: UUID) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Illucet-" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func privateStages(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aria2-") }
    }
    private func stream(_ url: URL, headers: [String: String] = [:], protocolName: String = "http") -> ResolvedStream {
        .init(formatID: "fixture", URL: url, HTTPHeaders: headers, fileExtension: "bin", protocolName: protocolName,
              sourceType: "direct_http", hasVideo: false, hasAudio: false, expectedBytes: nil)
    }
}

private final class Aria2ObservedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    var value: Int64 { lock.withLock { bytes } }
    func record(_ value: Int64) { lock.withLock { bytes = value } }
}

private final class Aria2LoopbackServer: @unchecked Sendable {
    static let payload = Data((0..<(8 * 1_048_576)).map { UInt8($0 % 251) })
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Illucet.aria2.fixture")
    private let lock = NSLock()
    private var ranges = 0
    var rangeRequests: Int { lock.withLock { ranges } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
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
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let route = request.split(separator: " ").dropFirst().first ?? ""
                    if route == "/forbidden" {
                        connection.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() }); return
                    }
                    let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
                    let numbers = range?.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false) ?? []
                    let start = route == "/ignore" ? 0 : numbers.first.flatMap { Int($0) } ?? 0
                    let end = route == "/ignore" ? Self.payload.count - 1 : numbers.last.flatMap { Int($0) } ?? Self.payload.count - 1
                    guard start >= 0, end >= start, end < Self.payload.count else { connection.cancel(); return }
                    let partial = range != nil && route != "/ignore"
                    if partial { self.lock.withLock { self.ranges += 1 } }
                    let contentRange = partial ? "Content-Range: bytes \(start)-\(end)/\(Self.payload.count)\r\n" : ""
                    let header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Length: \(end-start+1)\r\nAccept-Ranges: bytes\r\n\(contentRange)Connection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                        guard error == nil else { connection.cancel(); return }
                        self.send(connection, position: start,
                            end: route == "/truncated" ? min(end, start + 65_535) : end,
                            delay: route == "/slow" ? 10 : 1)
                    })
                }
            }
            listener.start(queue: queue)
        }
    }
    private func send(_ connection: NWConnection, position: Int, end: Int, delay: Int) {
        guard position <= end else { connection.cancel(); return }
        let next = min(position + 16_384, end + 1)
        connection.send(content: Self.payload.subdata(in: position..<next), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { self.send(connection, position: next, end: end, delay: delay) }
        })
    }
    func stop() { listener.cancel() }
}
