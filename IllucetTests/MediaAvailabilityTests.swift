import Foundation
import Testing
@testable import Illucet

@Suite(.serialized)
struct MediaAvailabilityTests {
    @Test
    func foregroundRequestWaitsAndProducesTheSameBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service(background: false)
        defer { service.session.invalidateAndCancel() }
        AvailabilityURLProtocol.state.reset()
        let deadline = Date.now.addingTimeInterval(0.2)
        let output = try await service.download(fixture.stream(deadline), jobID: fixture.jobID,
            destinationURL: fixture.destination) { _ in }
        let started = try #require(AvailabilityURLProtocol.state.dates.first)
        #expect(started >= deadline)
        #expect(try Data(contentsOf: output) == AvailabilityURLProtocol.body)
    }

    @Test
    func cancellationDuringAvailabilityWaitSendsNoRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service(background: false)
        defer { service.session.invalidateAndCancel() }
        AvailabilityURLProtocol.state.reset()
        let operation = Task {
            try await service.download(fixture.stream(.now.addingTimeInterval(30)), jobID: fixture.jobID,
                destinationURL: fixture.destination) { _ in }
        }
        try await Task.sleep(for: .milliseconds(20))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(AvailabilityURLProtocol.state.dates.isEmpty)
        #expect((await service.nativeTaskSnapshot()).isEmpty)
    }

    @Test
    func backgroundTaskCarriesDeadlineBeforeItIsResumed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service(background: true)
        defer { service.session.invalidateAndCancel() }
        let deadline = Date.now.addingTimeInterval(30)
        let prepared = try await service.prepareTransferTask(fixture.stream(deadline), jobID: fixture.jobID,
            destinationIdentity: fixture.roots.identity(for: fixture.destination), mediaRole: .video,
            expectedTotalBytes: nil, byteRange: nil, rangeChunkBytes: nil, stagingDestination: nil)
        #expect(service.session.configuration.identifier != nil)
        #expect(prepared.task.earliestBeginDate == deadline)
        #expect(prepared.task.state == .suspended)
        await service.cancelPreparedTransfers([prepared])
    }

    @Test
    func malformedDeadlinesCannotCreateRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service(background: false)
        defer { service.session.invalidateAndCancel() }
        AvailabilityURLProtocol.state.reset()
        await #expect(throws: MediaAvailability.InvalidDeadline.self) {
            try await service.download(fixture.stream(.now.addingTimeInterval(1_200)), jobID: fixture.jobID,
                destinationURL: fixture.destination) { _ in }
        }
        #expect(AvailabilityURLProtocol.state.dates.isEmpty)
    }

    private struct Fixture {
        let jobID = UUID()
        let root: URL
        let roots: StreamTransferDestinationRoots
        var destination: URL { roots.temporaryDirectory.appending(path: "media.mp4") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "Illucet-Availability-\(UUID())")
            roots = .init(temporaryDirectory: root.appending(path: "Temporary"),
                          applicationSupportDirectory: root.appending(path: "Support"))
            try FileManager.default.createDirectory(at: roots.temporaryDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: roots.applicationSupportDirectory, withIntermediateDirectories: true)
        }

        func service(background: Bool) -> StreamDownloadService {
            let configuration: URLSessionConfiguration?
            if background { configuration = nil }
            else {
                let foreground = URLSessionConfiguration.ephemeral
                foreground.protocolClasses = [AvailabilityURLProtocol.self]
                configuration = foreground
            }
            return StreamDownloadService(sessionIdentifier: "tests.illucet.availability.\(UUID())",
                                         configuration: configuration, destinationRoots: roots)
        }

        func stream(_ deadline: Date?) -> ResolvedStream {
            .init(formatID: "137", URL: URL(string: "https://availability.illucet.test/media")!,
                  HTTPHeaders: [:], fileExtension: "mp4", protocolName: "https", sourceType: "direct_http",
                  hasVideo: true, hasAudio: false, expectedBytes: nil, availableAt: deadline)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class AvailabilityURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("availability fixture".utf8)
    static let state = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Date] = []
        var dates: [Date] { lock.withLock { values } }
        func reset() { lock.withLock { values = [] } }
        func record() { lock.withLock { values.append(.now) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "availability.illucet.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
