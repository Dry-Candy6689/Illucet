import Foundation
import Testing
@testable import Illucet

struct FragmentResumeTests {
    @Test func pauseBarrierWaitsForAcquisitionAndEveryControlBeforeFinalizing() {
        var barrier = FragmentPauseBarrier()
        barrier.acknowledgeAcquisition()
        #expect({ !barrier.claimFinalization() }())
        barrier.requestCancellation()
        barrier.acknowledgeControl()
        #expect({ !barrier.claimFinalization() }())
        barrier.acknowledgeControl()
        #expect(barrier.cancellationRequested)
        #expect({ barrier.claimFinalization() }())
        #expect({ !barrier.claimFinalization() }())
    }

    @Test func pauseBarrierDoesNotAdmitResumeWhileTransportCancellationIsPending() {
        var barrier = FragmentPauseBarrier()
        barrier.acknowledgeControl()
        #expect({ !barrier.claimFinalization() }())
        barrier.acknowledgeAcquisition()
        #expect({ barrier.claimFinalization() }())
    }

    @Test(arguments: [403, 410])
    func expiryRefreshIsBoundedAndTyped(_ status: Int) async throws {
        var refreshes = 0
        var acquisitions = 0
        await #expect(throws: FragmentRecoveryError.expiryRefreshExhausted) {
            let _: Int = try await FragmentURLRecovery.run(initial: 0, refresh: {
                refreshes += 1
                return refreshes
            }, acquire: { _ in
                acquisitions += 1
                throw StreamDownloadError.HTTPFailure(statusCode: status)
            })
        }
        #expect(refreshes == 2)
        #expect(acquisitions == 3)
        #expect(DownloadRetryPolicy().classify(FragmentRecoveryError.expiryRefreshExhausted) == .permanent)
    }

    @Test(arguments: [401, 404, 429, 500, 503])
    func nonExpiryDoesNotReresolve(_ status: Int) async throws {
        var refreshes = 0
        await #expect(throws: StreamDownloadError.HTTPFailure(statusCode: status)) {
            let _: Int = try await FragmentURLRecovery.run(initial: 0, refresh: {
                refreshes += 1
                return refreshes
            }, acquire: { _ in throw StreamDownloadError.HTTPFailure(statusCode: status) })
        }
        #expect(refreshes == 0)
    }

    @Test func refreshFailureUsesSameBudget() async throws {
        var refreshes = 0
        await #expect(throws: FragmentRecoveryError.expiryRefreshExhausted) {
            let _: Int = try await FragmentURLRecovery.run(initial: 0, refresh: {
                refreshes += 1
                throw StreamDownloadError.HTTPFailure(statusCode: 410)
            }, acquire: { _ in throw StreamDownloadError.HTTPFailure(statusCode: 403) })
        }
        #expect(refreshes == 2)
    }

    @Test func refreshedPlanIsPassedToAcquisitionAndMismatchStops() async throws {
        var acquisitions: [String] = []
        let result = try await FragmentURLRecovery.run(initial: "expired", refresh: { "fresh" }, acquire: { plan in
            acquisitions.append(plan)
            if plan == "expired" { throw StreamDownloadError.HTTPFailure(statusCode: 403) }
            return plan
        })
        #expect(result == "fresh")
        #expect(acquisitions == ["expired", "fresh"])
        acquisitions = []
        await #expect(throws: HLSPlaylistResolutionError.identityMismatch) {
            let _: String = try await FragmentURLRecovery.run(initial: "expired", refresh: {
                throw HLSPlaylistResolutionError.identityMismatch
            }, acquire: { plan in
                acquisitions.append(plan)
                throw StreamDownloadError.HTTPFailure(statusCode: 410)
            })
        }
        #expect(acquisitions == ["expired"])
    }

    @Test func cancellationNeverRefreshes() async throws {
        var refreshes = 0
        await #expect(throws: CancellationError.self) {
            let _: Int = try await FragmentURLRecovery.run(initial: 0, refresh: {
                refreshes += 1
                return refreshes
            }, acquire: { _ in throw CancellationError() })
        }
        #expect(refreshes == 0)
    }

    @Test func durableCompletedFileRequiresFreshValidatorAndLocalDigest() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let saved = try fixture.checkpoint()
        try saved.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote,
                         validator: fixture.validator)
        let relaunched = try fixture.checkpoint()
        let networking = ResumeValidatorFixture(status: 200, headers: ["ETag": "\"stable-object\""])
        let service = fixture.service(networking)
        defer { service.session.invalidateAndCancel() }
        let restored = try await service.restoreFragment(checkpoint: relaunched, position: 0,
            remoteURL: fixture.remote, headers: ["User-Agent": "fixture"], destination: fixture.destination,
            jobID: fixture.jobID, expectedBytes: 4)
        #expect(restored == 4)
        #expect(try Data(contentsOf: fixture.destination) == Data("data".utf8))
        let requests = await networking.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "HEAD")
        #expect(requests.first?.value(forHTTPHeaderField: "User-Agent") == "fixture")
        #expect(requests.first?.httpShouldHandleCookies == false)
        let manifest = try String(contentsOf: saved.directory.appending(path: "checkpoint.json"), encoding: .utf8)
        for secret in ["https", "signature", "stable-object", "User-Agent", "Authorization"] {
            #expect(!manifest.contains(secret))
        }
    }

    @Test func changedURLWithSameETagCannotReuse() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        let networking = ResumeValidatorFixture(status: 200, headers: ["ETag": "\"stable-object\""])
        let service = fixture.service(networking)
        defer { service.session.invalidateAndCancel() }
        let changed = URL(string: "https://media.googlevideo.com/one?signature=changed")!
        let restored = try await service.restoreFragment(checkpoint: checkpoint, position: 0,
            remoteURL: changed, headers: [:], destination: fixture.destination, jobID: fixture.jobID, expectedBytes: 4)
        #expect(restored == nil)
        #expect(checkpoint.restartReason == .planChanged)
        #expect(await networking.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test(arguments: ["W/\"stable-object\"", "\"different\"", "", "not-an-etag"])
    func weakMissingOrChangedValidatorRestarts(_ tag: String) async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        let networking = ResumeValidatorFixture(status: 200, headers: ["ETag": tag])
        let service = fixture.service(networking)
        defer { service.session.invalidateAndCancel() }
        let restored = try await service.restoreFragment(checkpoint: checkpoint, position: 0,
            remoteURL: fixture.remote, headers: [:], destination: fixture.destination, jobID: fixture.jobID, expectedBytes: 4)
        #expect(restored == nil)
        #expect(checkpoint.resource(at: 0) == nil)
    }

    @Test func corruptSameLengthCompletedBytesAreNotAccepted() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        try Data("evil".utf8).write(to: checkpoint.directory.appending(path: "completed-0.media"))
        let networking = ResumeValidatorFixture(status: 200, headers: ["ETag": "\"stable-object\""])
        let service = fixture.service(networking)
        defer { service.session.invalidateAndCancel() }
        let restored = try await service.restoreFragment(checkpoint: checkpoint, position: 0,
            remoteURL: fixture.remote, headers: [:], destination: fixture.destination, jobID: fixture.jobID, expectedBytes: 4)
        #expect(restored == nil)
        #expect(checkpoint.restartReason == .corruptResource)
    }

    @Test func planChangeAndPartialOrphansAreDiscarded() throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        let orphan = checkpoint.directory.appending(path: ".partial.inflight")
        try Data("partial".utf8).write(to: orphan)
        let relaunched = try fixture.checkpoint(plan: "different-sequence-or-init")
        #expect(relaunched.resource(at: 0) == nil)
        #expect(relaunched.restartReason == .planChanged)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: checkpoint.directory.appending(path: "completed-0.media").path))
    }

    @Test func checkpointSymlinkIsRejectedWithoutReadingTarget() throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        let manifest = checkpoint.directory.appending(path: "checkpoint.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: fixture.completed)
        #expect(throws: FragmentRecoveryError.invalidCheckpoint) { _ = try fixture.checkpoint() }
        #expect(try Data(contentsOf: fixture.completed) == Data("data".utf8))
    }

    @Test func unavailableHEADRestartsWithoutAcceptingCachedBytes() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        let service = fixture.service(UnavailableResumeValidator())
        defer { service.session.invalidateAndCancel() }
        let result = try await service.restoreFragment(checkpoint: checkpoint, position: 0,
            remoteURL: fixture.remote, headers: [:], destination: fixture.destination,
            jobID: fixture.jobID, expectedBytes: 4)
        #expect(result == nil)
        #expect(checkpoint.restartReason == .validatorUnavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func sourceLeaseRejectsConcurrentWriterAndReleases() throws {
        let id = UUID()
        let lease = try FragmentSourceLeases.shared.acquire(jobID: id, formatID: "exact")
        #expect(throws: FragmentRecoveryError.sourceAlreadyActive) {
            _ = try FragmentSourceLeases.shared.acquire(jobID: id, formatID: "exact")
        }
        FragmentSourceLeases.shared.release(lease)
        let next = try FragmentSourceLeases.shared.acquire(jobID: id, formatID: "exact")
        FragmentSourceLeases.shared.release(next)
    }

    @Test(arguments: [403, 410])
    func validatorExpiryPropagatesTypedFailureWithoutDeletingCompletedFile(_ status: Int) async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let checkpoint = try fixture.checkpoint()
        try checkpoint.accept(position: 0, fileURL: fixture.completed, remoteURL: fixture.remote, validator: fixture.validator)
        let service = fixture.service(ResumeValidatorFixture(status: status, headers: [:]))
        defer { service.session.invalidateAndCancel() }
        await #expect(throws: StreamDownloadError.HTTPFailure(statusCode: status)) {
            _ = try await service.restoreFragment(checkpoint: checkpoint, position: 0,
                remoteURL: fixture.remote, headers: [:], destination: fixture.destination, jobID: fixture.jobID, expectedBytes: 4)
        }
        #expect(checkpoint.resource(at: 0) != nil)
    }
}

private struct ResumeFixture {
    let root: URL
    let roots: StreamTransferDestinationRoots
    let jobID = UUID()
    let completed: URL
    let destination: URL
    let remote = URL(string: "https://media.googlevideo.com/one?signature=secret")!
    let validator = FragmentResumeCheckpoint.strongValidator(["ETag": "\"stable-object\""])!

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "fragment-resume-\(UUID())", directoryHint: .isDirectory)
        roots = StreamTransferDestinationRoots(temporaryDirectory: root.appending(path: "tmp"),
                                               applicationSupportDirectory: root.appending(path: "support"))
        try FileManager.default.createDirectory(at: roots.temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roots.applicationSupportDirectory, withIntermediateDirectories: true)
        completed = roots.temporaryDirectory.appending(path: "complete.media")
        destination = roots.temporaryDirectory.appending(path: "restored.media")
        try Data("data".utf8).write(to: completed)
    }
    func checkpoint(plan: String = "exact-plan") throws -> FragmentResumeCheckpoint {
        try FragmentResumeCheckpoint(roots: roots, jobID: jobID, formatID: "exact-format", planDigest: plan)
    }
    func service(_ networking: any HLSPlaylistNetworking) -> StreamDownloadService {
        StreamDownloadService(sessionIdentifier: "resume-\(UUID())", configuration: .ephemeral,
            destinationRoots: roots, fragmentValidatorNetworking: networking)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor ResumeValidatorFixture: HLSPlaylistNetworking {
    let status: Int
    let headers: [String: String]
    private(set) var requests: [URLRequest] = []
    init(status: Int, headers: [String: String]) { self.status = status; self.headers = headers }
    func response(for request: URLRequest, maximumBytes: Int) async throws -> HLSPlaylistHTTPResponse {
        requests.append(request)
        return HLSPlaylistHTTPResponse(statusCode: status, headers: headers, body: Data())
    }
}

private struct UnavailableResumeValidator: HLSPlaylistNetworking {
    func response(for request: URLRequest, maximumBytes: Int) async throws -> HLSPlaylistHTTPResponse {
        throw URLError(.timedOut)
    }
}
