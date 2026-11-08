import Foundation
import Testing
@testable import Illucet

@Suite(.serialized)
struct ExtractorUpdateServiceTests {
    @Test
    func activeProfileSurvivesPersistenceAndLegacySnapshotsStillDecode() throws {
        var status = UpdateStatus.initial
        status.activeChannel = .nightly
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(UpdateStatus.self, from: data).activeProfileLabel == "Installed Nightly")
        #expect(status.reconciledWithBundledRuntime.activeChannel == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "activeChannel")
        let restored = try JSONDecoder().decode(UpdateStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.activeChannel == nil)
        #expect(restored.activeProfileLabel == "Bundled (\(DependencyVersions.extractorProfile.capitalized))")
    }

    @Test(arguments: UpdateChannel.allCases)
    func checksTheSelectedOfficialChannel(channel: UpdateChannel) async throws {
        let tag = channel == .stable ? "2026.10.06" : "2026.10.06.230001"
        let session = session(responding: .release(tag, channel: channel))
        defer { session.invalidateAndCancel() }
        let service = ExtractorUpdateService(session: session)
        let original = status(active: "2026.10.05")

        let result = await service.check(current: original, channel: channel)

        let request = try #require(UpdateReleaseURLProtocol.requests.first)
        let repository = channel.releaseRepository
        #expect(request.url?.absoluteString
            == "https://api.github.com/repos/yt-dlp/\(repository)/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent")
            == "\(AppIdentity.fallbackDisplayName)/1")
        #expect(result.state == .updateAvailable)
        let offer = try #require(result.availableRelease)
        #expect(offer.version == tag)
        #expect(offer.channel == channel)
        #expect(offer.publishedAt == ISO8601DateFormatter().date(from: "2026-10-06T23:01:00Z"))
        #expect((offer.masterSource != nil) == (channel == .master))
        #expect(result.activeYTDLPVersion == original.activeYTDLPVersion)
        #expect(result.activeEJSVersion == original.activeEJSVersion)
        #expect(result.lastCheckedAt != nil)
        #expect(result.lastSuccessfulUpdateAt == original.lastSuccessfulUpdateAt)
        #expect(result.message == nil)
        #expect(UpdateReleaseURLProtocol.requests.count == 1)
    }

    @Test
    func anOlderChannelCanBeOfferedButRequiresExactConfirmationAndRecheck() async throws {
        let session = session(responding: .release("2026.10.05"))
        defer { session.invalidateAndCancel() }
        let service = ExtractorUpdateService(session: session)
        let original = status(active: "2026.10.05.230001")
        let result = await service.check(current: original, channel: .stable)
        let offer = try #require(result.availableRelease)
        #expect(result.state == .updateAvailable)
        #expect(offer.isOlder(than: result))
        #expect(result.activeYTDLPVersion == original.activeYTDLPVersion)

        let runtime = RuntimeEnvironment()
        await #expect(throws: UpdateError.olderVersionNeedsConfirmation) {
            try await service.install(current: result, channel: .stable, runtime: runtime)
        }
        await #expect(throws: UpdateError.invalidOffer) {
            try await service.install(current: result, channel: .master, confirmedOlderVersion: true, runtime: runtime)
        }
        #expect(UpdateReleaseURLProtocol.requests.count == 1)

        UpdateReleaseURLProtocol.configure(.release("2026.10.06"))
        await #expect(throws: UpdateError.releaseChanged) {
            try await service.install(current: result, channel: .stable, confirmedOlderVersion: true, runtime: runtime)
        }
        #expect(UpdateReleaseURLProtocol.requests.count == 1)
    }

    @Test
    func masterRequiresTheOfficialArchiveAndAnAssetDigest() async {
        for invalidSource in ["missing", "unverified", "other-origin"] {
            let session = session(responding: .release("2026.10.06.230001", channel: .master,
                                                       invalidSource: invalidSource))
            let result = await ExtractorUpdateService(session: session).check(current: .initial, channel: .master)
            #expect(result.state == .failed)
            #expect(result.availableRelease == nil)
            session.invalidateAndCancel()
        }
    }

    @Test
    func nightlyDefaultMigratesOnceAndKeepsLaterChannelChoices() {
        var legacy = IllucetSnapshot.empty
        legacy.settings.updateChannel = .stable
        legacy.firstRunState.migratedNightlyUpdateDefault = nil
        legacy.updateStatus.state = .current
        legacy.updateStatus.lastCheckedChannel = .stable
        legacy.updateStatus.lastCheckedAt = .now
        let migrated = IllucetAppPersistedState.restoring(legacy)
        #expect(AppSettings.defaults.updateChannel == .nightly)
        #expect(migrated.settings.updateChannel == .nightly)
        #expect(migrated.updateStatus.lastCheckedAt == nil)
        #expect(migrated.firstRunState.migratedNightlyUpdateDefault == true)
        var saved = migrated.applying(to: legacy)
        saved.settings.updateChannel = .stable
        #expect(IllucetAppPersistedState.restoring(saved).settings.updateChannel == .stable)
        saved.settings.updateChannel = .master
        #expect(IllucetAppPersistedState.restoring(saved).settings.updateChannel == .master)
    }

    @Test
    func numericNightlyComparisonHandlesEqualOlderAndNewerBuilds() async {
        for (release, expected) in [
            ("2026.10.05.9", UpdateStatus.State.current),
            ("2026.10.05.10", .current),
            ("2026.10.05.11", .updateAvailable),
            ("2026.10.06.1", .updateAvailable),
        ] {
            let session = session(responding: .release(release))
            let service = ExtractorUpdateService(session: session)
            let result = await service.check(
                current: status(active: "2026.10.05.10"),
                channel: .nightly
            )
            session.invalidateAndCancel()

            #expect(result.state == expected)
            #expect(result.availableRelease?.version
                == (expected == .updateAvailable ? release : nil))
        }
    }

    @Test
    func rejectsMalformedOfficialVersionsWithoutReflectingPayloads() async {
        for tag in ["", "latest", "2026.10.06\n", "2026.10.06-signed-secret",
                    "https://unexpected.test/token", "2026.1.1"] {
            let session = session(responding: .release(tag))
            let service = ExtractorUpdateService(session: session)
            let result = await service.check(
                current: status(active: "2026.10.05"),
                channel: .stable
            )
            session.invalidateAndCancel()

            #expect(result.state == .failed)
            #expect(result.availableRelease?.version == nil)
            #expect(result.lastCheckedAt != nil)
            #expect(result.message == "Couldn’t check for updates. Try again.")
        }
    }

    @Test
    func rejectsInvalidResponsesAndDoesNotKeepAStaleOffer() async {
        for response in [
            UpdateReleaseURLProtocol.Response.http(code: 403, body: Data()),
            .http(code: 200, body: Data("{invalid-json".utf8)),
            .http(code: 200, body: Data("{\"name\":\"Missing tag\"}".utf8)),
            .http(code: 200, body: Data(repeating: 32, count: 1_048_577)),
            .http(code: 200, body: Data(), url: "https://other.test/release"),
            .http(code: 200, body: Data(), url: "http://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"),
            .http(code: 200, body: Data(), url: "https://api.github.com/repos/other/other/releases/latest"),
            .failure(.notConnectedToInternet),
        ] {
            let session = session(responding: response)
            let service = ExtractorUpdateService(session: session)
            var original = status(active: "2026.10.05")
            original.availableRelease = .init(channel: .stable, version: "2099.01.01", publishedAt: .now)
            original.state = .updateAvailable
            let result = await service.check(current: original, channel: .stable)
            session.invalidateAndCancel()

            #expect(result.state == .failed)
            #expect(result.availableRelease?.version == nil)
            #expect(result.activeYTDLPVersion == original.activeYTDLPVersion)
            #expect(result.message == "Couldn’t check for updates. Try again.")
        }
    }

    @Test
    func cancellationPreservesTheLastCompletedCheck() async throws {
        let session = session(responding: .pending)
        defer { session.invalidateAndCancel() }
        let service = ExtractorUpdateService(session: session)
        var original = status(active: "2026.10.05")
        original.lastCheckedAt = Date(timeIntervalSince1970: 123)
        original.availableRelease = .init(channel: .nightly, version: "2026.10.06.1", publishedAt: .now)
        original.state = .updateAvailable
        original.message = "Previous completed check"
        let captured = original
        let task = Task {
            await service.check(current: captured, channel: .nightly)
        }
        defer { task.cancel() }
        let deadline = Date.now.addingTimeInterval(3)
        while UpdateReleaseURLProtocol.requests.isEmpty && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(UpdateReleaseURLProtocol.requests.count == 1)
        task.cancel()

        #expect(await task.value == original)
    }

    @Test
    func transportCancellationDoesNotClaimAReleaseFailure() async {
        let session = session(responding: .failure(.cancelled))
        defer { session.invalidateAndCancel() }
        let service = ExtractorUpdateService(session: session)
        let original = status(active: "2026.10.05")

        #expect(await service.check(current: original, channel: .stable)
            == original)
    }

    @Test
    func restoringAnOlderAppSnapshotUsesTheActualBundledVersions() {
        var snapshot = IllucetSnapshot.empty
        snapshot.updateStatus = status(active: "2020.01.01")
        snapshot.updateStatus.bundledYTDLPVersion = "2020.01.01"
        snapshot.updateStatus.activeEJSVersion = "old-ejs"
        snapshot.updateStatus.bundledEJSVersion = "old-ejs"
        snapshot.updateStatus.availableRelease = .init(channel: .stable, version: "2020.01.02", publishedAt: .now)
        snapshot.updateStatus.lastCheckedAt = Date(timeIntervalSince1970: 123)
        snapshot.updateStatus.lastSuccessfulUpdateAt = Date(timeIntervalSince1970: 123)
        snapshot.updateStatus.state = .updateAvailable

        let restored = IllucetAppPersistedState.restoring(snapshot).updateStatus

        #expect(restored == .initial)
        #expect(restored.activeYTDLPVersion == DependencyVersions.ytDLP)
        #expect(restored.activeEJSVersion == DependencyVersions.ejs)
    }

    @Test
    func interruptedChecksResetButCompletedChecksSurviveRestoration() {
        var status = UpdateStatus.initial
        status.state = .checking
        status.message = "Interrupted"
        #expect(status.reconciledWithBundledRuntime == .initial)

        status.state = .installationDisabled
        #expect(status.reconciledWithBundledRuntime == .initial)

        status.state = .current
        status.message = "Completed"
        status.lastCheckedAt = Date(timeIntervalSince1970: 123)
        #expect(status.reconciledWithBundledRuntime == status)
    }


    private func status(active: String) -> UpdateStatus {
        var value = UpdateStatus.initial
        value.activeYTDLPVersion = active
        return value
    }

    private func session(
        responding response: UpdateReleaseURLProtocol.Response
    ) -> URLSession {
        UpdateReleaseURLProtocol.configure(response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateReleaseURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class UpdateReleaseURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response: Sendable {
        case http(code: Int, body: Data, url: String? = nil)
        case failure(URLError.Code)
        case pending

        static func release(_ tag: String, channel: UpdateChannel = .stable, invalidSource: String? = nil) -> Self {
            var assets: [[String: Any]] = []
            if channel == .master && invalidSource != "missing" {
                assets.append([
                    "name": "yt-dlp.tar.gz",
                    "state": "uploaded",
                    "size": 6_000_000,
                    "digest": invalidSource == "unverified" ? "" : "sha256:" + String(repeating: "a", count: 64),
                    "browser_download_url": invalidSource == "other-origin"
                        ? "https://other.test/yt-dlp.tar.gz"
                        : "https://github.com/yt-dlp/yt-dlp-master-builds/releases/download/\(tag)/yt-dlp.tar.gz",
                ])
            }
            return .http(code: 200, body: try! JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "published_at": "2026-10-06T23:01:00Z",
                "draft": false, "prerelease": false, "assets": assets,
            ]))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: Response = .pending
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recordedRequests } }

    static func configure(_ response: Response) {
        lock.withLock {
            Self.response = response
            recordedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.response
        }
        switch response {
        case let .http(code, body, url):
            guard let responseURL = url.flatMap(URL.init(string:)) ?? request.url,
                  let response = HTTPURLResponse(
                    url: responseURL,
                    statusCode: code,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            break
        }
    }

    override func stopLoading() {}
}
