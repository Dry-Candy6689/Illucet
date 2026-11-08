import Foundation
import Testing
@testable import Illucet

struct SharingAndCreatorTests {
    @Test @MainActor
    func sharedInboxOffersEachLinkOnceAndRetainsManualRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedLinkInbox(directory: root.appendingPathComponent("inbox"))
        try inbox.save(DeveloperFixtures.RickURL)
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root.appendingPathComponent("state")), fixtureModeOverride: true)
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.startupState == .ready)
        model.presentsOnboarding = false
        model.settings.sharedLinks = SharedLinkPreferences()
        model.URLText = "draft"
        model.refreshSharedLinks(inbox: inbox)
        #expect(try inbox.pending().first?.presentedAt == nil)
        model.URLText = ""
        model.refreshSharedLinks(inbox: inbox)
        #expect(model.presentsSharedLinkChoice)
        model.applySharedLinkBehavior(.fill, rememberChoice: true)
        #expect(model.settings.sharedLinks?.behavior == .fill)
        await model.persistImmediately()
        let restored = try await IllucetPersistence(rootURL: root.appendingPathComponent("state")).load()
        #expect(restored.settings.sharedLinks?.behavior == .fill)
        model.URLText = ""
        let reopened = SharedLinkInbox(directory: inbox.directory)
        model.refreshSharedLinks(inbox: reopened)
        #expect(model.pendingSharedLink == nil)
        #expect(model.URLText.isEmpty)
        let saved = try #require(reopened.pending().first)
        #expect(saved.presentedAt != nil)
        model.openSavedSharedLink(saved, inbox: reopened)
        #expect(model.URLText == saved.url.absoluteString)
        #expect(!model.presentsSharedLinkChoice)
        model.URLText = ""
        try reopened.save(DeveloperFixtures.RickURL)
        model.refreshSharedLinks(inbox: reopened)
        #expect(model.URLText == saved.url.absoluteString)
        #expect(try reopened.pending().count == 2)
    }

    @Test @MainActor
    func sharedChoiceCanBeUsedOnceWithoutChangingSavedPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        model.settings.sharedLinks = SharedLinkPreferences()
        model.receiveSharedLink(DeveloperFixtures.RickURL)
        model.applySharedLinkBehavior(.fill)
        #expect(model.settings.sharedLinks?.behavior == .ask)
    }

    @Test func clipboardNeverOverwritesInputOrAcceptsUnsupportedContent() {
        let link = "https://youtu.be/dQw4w9WgXcQ"
        #expect(LinkIntakePolicy.clipboardURL(link, currentInput: "typed draft") == nil)
        #expect(LinkIntakePolicy.clipboardURL(nil, currentInput: "") == nil)
        #expect(LinkIntakePolicy.clipboardURL("https://example.com", currentInput: "") == nil)
        #expect(LinkIntakePolicy.clipboardURL(link, currentInput: "  ") != nil)
        #expect(!ClipboardPreferences().enabled)
        #expect(!ClipboardPreferences().checkAtStartup)
    }

    @Test func creatorTabsStayBoundedAndDistinct() throws {
        for (tab, kind) in [("videos", PlaylistKind.creatorUploads), ("shorts", .creatorShorts), ("streams", .creatorReplays)] {
            let url = try #require(URL(string: "https://youtube.com/@IllucetFixture/" + tab))
            let intent = try YouTubeURLIntentClassifier.playlistIntent(from: url)
            #expect(intent.kind == kind)
            #expect(intent.playlistID == "@IllucetFixture/" + tab)
            #expect(intent.referencedVideoID == nil)
        }
        #expect(throws: Error.self) { try YouTubeURLIntentClassifier.classify(URL(string: "https://youtube.com/channel/UC123?list=PLFixture_123")!) }
        #expect(throws: Error.self) { try YouTubeURLIntentClassifier.classify(URL(string: "https://youtube.com/@fixture/playlists")!) }
    }

    @Test func filtersExcludeUnknownValuesAndKeepSearchIndependent() throws {
        var entry = try #require(DeveloperFixtures.playlist.entries.first)
        var filter = CollectionFilter()
        #expect(filter.matches(entry))
        filter.query = "definitely-no-match"
        #expect(!filter.matches(entry))
        filter.query = ""
        filter.minimumHeight = 720
        #expect(!filter.matches(entry))
        entry.height = 1080
        #expect(filter.matches(entry))
        filter.uploadedAfter = "2026-01-01"
        #expect(!filter.matches(entry))
        entry.uploadDate = "2026-05-01"
        #expect(filter.matches(entry))
        filter.shorts = .no
        #expect(!filter.matches(entry))
        entry.isShort = false
        #expect(filter.matches(entry))
        filter.maximumSeconds = 0
        #expect(!filter.matches(entry))
    }

    @Test func cookieImportAcceptsHttpOnlyWithoutSavingOtherDomains() throws {
        let text = "# Netscape HTTP Cookie File\n#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t2000000000\tLOGIN_INFO\tfixture\n.youtube.com\tTRUE\t/\tTRUE\t2000000000\tSAPISID\tfixture\n.example.com\tTRUE\t/\tTRUE\t2000000000\tOTHER\tprivate\n"
        let values = try CookieFileImport.parse(Data(text.utf8), now: Date(timeIntervalSince1970: 100))
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.domain == ".youtube.com" })
        #expect(throws: AccountError.self) { try CookieFileImport.parse(Data(text.utf8), now: Date(timeIntervalSince1970: 2100000000)) }
        #expect(throws: AccountError.self) { try CookieFileImport.parse(Data("LOGIN_INFO=secret".utf8)) }
        #expect(throws: AccountError.self) { try CookieFileImport.parse(Data(repeating: 65, count: CookieFileImport.maximumBytes + 1)) }
        #expect(throws: AccountError.self) { try CookieFileImport.parse(Data((text + ".youtube.com\tinvalid\n").utf8)) }
    }

    @Test func sidecarsContainSafeMetadataAndChecksumActualBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media.mp4")
        try Data("abc".utf8).write(to: media)
        let extras = try MetadataSidecarWriter.prepare(kinds: Set(MetadataSidecarKind.allCases), metadata: DeveloperFixtures.media, mediaURL: media, root: root)
        #expect(extras.count == 5)
        #expect(extras.allSatisfy { !$0.url.pathExtension.isEmpty })
        let exporter = ExportManager(documentsRootURL: root.appendingPathComponent("published"))
        let items = [ExportFileTransactionItem(sourceURL: media, filename: "fixture")] + extras.map {
            ExportFileTransactionItem(sourceURL: $0.url, filename: $0.kind == .info ? "fixture.info" : $0.kind == .description ? "fixture.description" : "fixture")
        }
        let exported = try await exporter.exportFileTransaction(items: items, destination: .appDocuments,
            folderBookmark: nil, duplicateHandling: Array(repeating: .addNumber, count: items.count), videoID: DeveloperFixtures.media.videoID)
        guard case .committed(let files) = exported else { Issue.record("Expected complete sidecar transaction"); return }
        #expect(Set(files.map(\.lastPathComponent)) == ["fixture.mp4", "fixture.info.json", "fixture.description.txt", "fixture.url", "fixture.nfo", "fixture.sha256"])
        let checksum = try String(contentsOf: #require(extras.first { $0.kind == .sha256 }).url, encoding: .utf8)
        #expect(checksum.trimmingCharacters(in: .whitespacesAndNewlines) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let info = try Data(contentsOf: #require(extras.first { $0.kind == .info }).url)
        let object = try #require(JSONSerialization.jsonObject(with: info) as? [String: Any])
        #expect(object["formats"] == nil)
        #expect(object["cookies"] == nil)
        #expect(object["source"] as? String == "https://www.youtube.com/watch?v=\(DeveloperFixtures.media.videoID)")
        // A retry can safely regenerate the same sidecars.
        _ = try MetadataSidecarWriter.prepare(kinds: [.info], metadata: DeveloperFixtures.media, mediaURL: media, root: root)
    }

    @Test func bulkRemovalAttemptsAllOwnedFilesAndRetainsPartialFailures() {
        var one = HistoryRecord(job: job())
        one.fileURL = URL(fileURLWithPath: "/tmp/one.mp4")
        one.metadataSidecars = [.init(kind: .info, localURL: URL(fileURLWithPath: "/tmp/one.info.json"))]
        var two = HistoryRecord(job: job())
        two.fileURL = URL(fileURLWithPath: "/tmp/two.mp4")
        var attempted: [URL] = []
        let result = HistoryFileRemoval.remove(records: [one, two]) { url in
            attempted.append(url)
            if url == one.fileURL { throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(attempted.count == 3)
        #expect(result.removedRecordIDs == [two.id])
        #expect(result.failedRecordIDs == [one.id])
        #expect(result.failedFileCount == 1)
    }

    @Test func bulkDeletionSupportsOwnedPackagesAndDoesNotFollowSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("link"), withDestinationURL: outside)
        var record = HistoryRecord(job: job())
        record.packageURL = package
        #expect(HistoryFileRemoval.remove(records: [record]).removedRecordIDs == [record.id])
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func bandwidthReservationsCombineGlobalAndJobBudgets() {
        let limiter = TransferBandwidthLimiter()
        let one = UUID(), two = UUID()
        limiter.configure(global: 65_536, jobID: one, perJob: 32_768)
        #expect(limiter.reserve(bytes: 32_768, jobID: one, now: 100) == 101)
        #expect(limiter.reserve(bytes: 32_768, jobID: two, now: 100) == 101)
        #expect(limiter.reserve(bytes: 32_768, jobID: one, now: 100) == 102)
        limiter.configure(global: nil)
        limiter.finish(jobID: one)
        #expect(limiter.reserve(bytes: 1_000_000, jobID: one, now: 100) == 100)
    }

    @Test func oldSettingsAndConfigurationDecodeWithNewFeaturesOff() throws {
        let encoder = JSONEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(AppSettings.defaults)) as? [String: Any])
        object.removeValue(forKey: "clipboard")
        object.removeValue(forKey: "waitForCharging")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.clipboard == nil)
        #expect(old.waitForCharging == nil)
        let configuration = try JSONDecoder().decode(DownloadConfiguration.self, from: encoder.encode(DownloadConfiguration.standard))
        #expect(configuration.metadataSidecars == nil)
        #expect(configuration.speedLimitBytesPerSecond == nil)
    }

    @Test func perJobWiFiRestrictionSurvivesGlobalCellularApproval() {
        var job = job()
        job.configuration.wifiOnly = true
        job.networkAuthorization = .continueOnce
        var settings = AppSettings.defaults
        settings.askBeforeCellular = false
        let cellular = NetworkPathSnapshot(isSatisfied: true, interface: .cellular, isExpensive: true, isConstrained: false)
        #expect(DownloadScheduler.networkDecision(for: job, settings: settings, network: cellular) == .waitForWiFi)
        #expect(!DownloadScheduler.streamNetworkPolicy(for: job, settings: settings).allowsExpensiveAccess)
    }

    #if DEBUG
    // Native fixture generation is compiled only into Debug builds.
    @Test func retainedMediaConversionPreservesOriginalAndPublishesVerifiedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try NativeMediaFixtures.generate(in: root)
        let originalBytes = try Data(contentsOf: fixtures.audio)
        var record = HistoryRecord(job: job())
        record.fileURL = fixtures.audio
        let workflow = RetainedMediaReprocessor(processor: NativeFFmpegMediaProcessor(),
            exporter: ExportManager(documentsRootURL: root.appendingPathComponent("outputs")))
        for format in RetainedAudioFormat.allCases {
            let converted = try await workflow.convert(record: record, format: format, progress: { _ in })
            #expect(converted.id != record.id)
            #expect(converted.probe?.audioStreamCount == 1)
            #expect(converted.probe?.videoStreamCount == 0)
            #expect(converted.fileURL?.pathExtension == format.fileExtension)
            #expect(try Data(contentsOf: #require(converted.fileURL)).count > 0)
            #expect(try Data(contentsOf: fixtures.audio) == originalBytes)
        }
    }
    #endif

    @Test func sharedInboxSurvivesReopenAndIsolatesCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedLinkInbox(directory: root)
        let url = try #require(SharedLinkParser.webpageURL(in: "Look https://youtu.be/dQw4w9WgXcQ?si=tracking"))
        #expect(url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        try inbox.save(url)
        try Data("broken".utf8).write(to: root.appendingPathComponent("corrupt.json"))
        let reopened = SharedLinkInbox(directory: root)
        let saved = try reopened.pending()
        #expect(saved.count == 1)
        #expect(saved.first?.url == url)
        try reopened.remove(try #require(saved.first).id)
        #expect(try reopened.pending().isEmpty)
        #expect(SharedLinkParser.canonicalURL(URL(string: "https://youtube.com/watchbad?v=dQw4w9WgXcQ")!) == nil)
        #expect(SharedLinkParser.canonicalURL(URL(string: "https://user:secret@youtube.com/watch?v=dQw4w9WgXcQ")!) == nil)
        #expect(SharedLinkParser.canonicalURL(URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!) == nil)
    }

    @Test func throttlingPreservesUserPauseAndCancelledTask() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // No request starts: tasks remain suspended until explicitly cancelled.
        let task = session.downloadTask(with: URL(string: "http://127.0.0.1:9/fixture")!)
        let limiter = TransferBandwidthLimiter()
        let id = UUID()
        limiter.configure(global: 16_384)
        limiter.throttle(task, bytes: 2_048, jobID: id)
        #expect(limiter.pause(task))
        try await Task.sleep(for: .milliseconds(300))
        #expect(task.state == .suspended)
        #expect(!limiter.isThrottled(task))
        task.cancel()
        limiter.complete(task)
        #expect(!limiter.resume(task, jobID: id))
        let cancelled = session.downloadTask(with: URL(string: "http://127.0.0.1:9/fixture")!)
        limiter.throttle(cancelled, bytes: 2_048, jobID: id)
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(cancelled.state != .running)
        #expect(!limiter.isThrottled(cancelled))
    }

    @Test @MainActor func sharedRoutesPreserveDraftAndMissingPresetOpensOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.startupState == .ready)
        model.settings.sharedLinks = SharedLinkPreferences(behavior: .presetImmediate, preferredPresetID: UUID())
        model.URLText = "a typed draft"
        model.receiveSharedLink(DeveloperFixtures.RickURL)
        #expect(model.URLText == "a typed draft")
        #expect(model.presentsSharedLinkChoice)
        #expect(!model.isAnalyzing)
        model.applySharedLinkBehavior(.fill)
        #expect(model.URLText == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(!model.presentsSharedLinkChoice)
        #expect(model.pendingSharedLink == nil)
        model.URLText = ""
        model.receiveSharedLink(DeveloperFixtures.RickURL)
        for _ in 0..<200 where model.isAnalyzing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.presentsConfiguration)
        #expect(model.jobs.isEmpty)
        #expect(!model.opensFullOptionsAfterAnalysis)
        model.saveTask?.cancel()
        model.sponsorBlockPreviewTask?.cancel()
    }

    @Test @MainActor func foregroundShortcutActionWritesValidatedDurableLink() async throws {
        let inbox = try SharedLinkInbox.live()
        let before = Set(try inbox.pending().map(\.id))
        var intent = OpenSharedLinkIntent()
        intent.link = DeveloperFixtures.RickURL
        _ = try await intent.perform()
        let additions = try inbox.pending().filter { !before.contains($0.id) && $0.url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }
        defer { for item in additions { try? inbox.remove(item.id) } }
        #expect(additions.count == 1)
        intent.link = URL(string: "https://example.com/private")!
        await #expect(throws: SharedLinkIntentError.self) { _ = try await intent.perform() }
    }

    @Test func rateAdmissionWaitSupportsPauseResumeAndCancellation() async throws {
        let limiter = TransferBandwidthLimiter()
        let id = UUID()
        limiter.configure(global: 16_384)
        _ = limiter.reserve(bytes: 4_096, jobID: id, now: ProcessInfo.processInfo.systemUptime)
        let waiting = Task { try await limiter.waitForAdmission(jobID: id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(limiter.pauseAdmission(jobID: id) == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(limiter.resumeAdmission(jobID: id) == 1)
        try await waiting.value
        _ = limiter.reserve(bytes: 16_384, jobID: id, now: ProcessInfo.processInfo.systemUptime)
        let cancelled = Task { try await limiter.waitForAdmission(jobID: id) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    private func job() -> DownloadJob {
        DownloadJob(id: UUID(), sourceURL: DeveloperFixtures.RickURL, videoID: "dQw4w9WgXcQ", title: "Fixture", channel: nil, thumbnailURL: nil,
            createdAt: .now, updatedAt: .now, configuration: .standard, state: .completed, stage: .complete, progress: .zero,
            priority: 0, retryCount: 0, maximumRetries: 2, errorCode: nil, errorMessage: nil, outputURL: nil,
            outputProbe: nil, selectedFormatIDs: [], extractorVersion: "fixture")
    }
}
