import Foundation
import Testing
@testable import Illucet

struct ShortcutDownloadTests {
    @Test func admissionMessageReportsFailurePauseAndRetryTruthfully() {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        #expect(DownloadSharedLinkIntent.admissionMessage(job) == "Download failed — open Illucet for details")
        job.state = .paused
        #expect(DownloadSharedLinkIntent.admissionMessage(job) == "Download paused")
        job.state = .waitingForRetry
        #expect(DownloadSharedLinkIntent.admissionMessage(job) == "Queued — waiting to retry")
        job.state = .needsAttention; job.errorCode = "background_processing_expired"
        #expect(DownloadSharedLinkIntent.admissionMessage(job) == "Open Illucet to continue")
    }
    @Test func preferenceMigrationPreservesReviewChoicesAndDefaultsToDownloading() throws {
        #expect(ShortcutPreferences.migrating(nil).behavior == .download)
        for behavior in [SharedLinkBehavior.fill, .analyze, .options, .presetConfirmation] {
            #expect(ShortcutPreferences.migrating(.init(behavior: behavior)).behavior == .options)
        }
        let id = UUID()
        #expect(ShortcutPreferences.migrating(.init(behavior: .presetImmediate, preferredPresetID: id))
            == ShortcutPreferences(behavior: .download, preferredPresetID: id))
        var settings = AppSettings.defaults
        settings.shortcutPreferences = .init(behavior: .options, preferredPresetID: id, backgroundFirst: false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.shortcutPreferences == settings.shortcutPreferences)
    }

    @Test func canonicalInputFiltersUnsupportedAndDeduplicatesTrackingVariants() {
        let values = ["https://example.com/private", "https://youtu.be/dQw4w9WgXcQ?si=tracking",
                      "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://user:secret@youtube.com/watch?v=dQw4w9WgXcQ"]
        #expect(DownloadSharedLinkIntent.canonicalLinks(values.compactMap(URL.init(string:))) == [DeveloperFixtures.RickURL])
    }

    @Test @MainActor func shortcutRequestIsDurableWithoutBeingReplayedByLegacyInbox() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedLinkInbox(directory: root.appendingPathComponent("inbox"))
        let request = try inbox.save(DeveloperFixtures.RickURL, shortcut: true)
        #expect(try inbox.pending() == [request])
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.URLText = ""
        model.refreshSharedLinks(inbox: inbox)
        #expect(model.pendingSharedLink == nil)
        #expect(!model.isAnalyzing)
        #expect(try inbox.pending().first?.presentedAt == nil)
        model.saveTask?.cancel()
    }

    @Test func deferredRequestRetainsIdentityAndClaimsForegroundOnlyOnce() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SharedLinkInbox(directory: root)
        let request = try inbox.save(DeveloperFixtures.RickURL, shortcut: true)
        try inbox.deferUntilForeground(request.id, automatic: true, message: "Open Illucet to continue.")
        let saved = try #require(inbox.pending().first)
        #expect(saved.id == request.id && saved.url == request.url)
        #expect(saved.resumeOnForeground == true && saved.presentedAt == nil)
        try inbox.markPresented(request.id)
        #expect(try inbox.pending().first?.presentedAt != nil)
        #expect(try inbox.pending().count == 1)
    }

    @Test @MainActor func admittedRequestPersistsOnceKeepsDraftAndHonorsCharging() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.settings.shortcuts = .init()
        model.settings.waitForCharging = true
        model.settings.sponsorBlock = .disabled
        model.settings.defaultDestination = .appDocuments
        model.URLText = "my unfinished draft"
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        guard case let .admitted(first) = try await model.submitShortcut(request) else {
            Issue.record("Expected a real queued job"); return
        }
        #expect(first.id == request.id)
        #expect(first.state == .waitingForPower)
        #expect(model.URLText == "my unfinished draft")
        #expect(!model.presentsConfiguration)
        #expect(model.firstRunState.pip?.analyzedFirstVideo == true)
        #expect(model.firstRunState.pip?.startedFirstDownload == true)
        #expect(model.firstRunState.pip?.downloadScreensHintShown != true)
        guard case let .admitted(second) = try await model.submitShortcut(request) else {
            Issue.record("Expected the same request to find its job"); return
        }
        #expect(second.id == first.id)
        let saved = try await model.persistence.load()
        #expect(saved.jobs.filter { $0.id == request.id }.count == 1)
        #expect(await model.coordinator.currentJobs().count == 1)
        #expect(DownloadSharedLinkIntent.admissionMessage(first) == "Queued — waiting for charging")
        model.saveTask?.cancel()
    }

    @Test @MainActor func missingPresetAndAskRequireForegroundWithoutEnqueueOrDraftMutation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.URLText = "keep me"
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        for preferences in [ShortcutPreferences(behavior: .ask), ShortcutPreferences(preferredPresetID: UUID())] {
            model.settings.shortcuts = preferences
            guard case .foreground = try await model.submitShortcut(request) else {
                Issue.record("Expected a required choice"); return
            }
            #expect(model.URLText == "keep me")
            #expect(await model.coordinator.currentJobs().isEmpty)
        }
        model.saveTask?.cancel()
    }

    @Test @MainActor func cancelledPreparationNeverAdmitsAJob() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        let task = Task { try await model.submitShortcut(SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await model.coordinator.currentJobs().isEmpty)
        model.saveTask?.cancel()
    }

    @Test @MainActor func optionsKeepRequestIdentityAndRejectDifferentSourceReplay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.settings.waitForCharging = true
        model.settings.sponsorBlock = .disabled
        model.settings.defaultDestination = .appDocuments
        await model.coordinator.configure(settings: model.settings, folderBookmark: nil)
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        model.URLText = ""
        model.openShortcutOptions(.init(request: request, reason: "Review options", prepared: .init(
            metadata: DeveloperFixtures.media, configuration: model.settings.configuration(), version: nil)))
        #expect(model.activeShortcutRequest?.id == request.id)
        #expect(model.presentsConfiguration)
        let job = try await model.enqueueShortcut(metadata: DeveloperFixtures.media,
            configuration: model.configuration, version: nil, request: request)
        #expect(job.id == request.id)
        let mismatched = SharedLink(id: request.id, url: URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!,
                                   createdAt: .now, isShortcutRequest: true)
        await #expect(throws: IllucetError.self) { try await model.submitShortcut(mismatched) }
        #expect(await model.coordinator.currentJobs().count == 1)
        model.saveTask?.cancel()
    }

    @Test func backupClearsMissingShortcutPreset() throws {
        var settings = AppSettings.defaults
        settings.shortcuts = .init(preferredPresetID: UUID())
        let decoded = try PreferencesBackup.decode(PreferencesBackup(settings: settings, presets: []).encoded())
        #expect(decoded.settings.shortcuts?.preferredPresetID == nil)
        #expect(decoded.settings.shortcutPreferences.behavior == .download)
    }

    @Test @MainActor func optionsUseSelectedPresetWithoutStartingItsImmediateAction() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        var config = model.settings.configuration()
        config.mode = .audioOnly
        config.sponsorBlock = .disabled
        config.accountID = UUID()
        var preset = QuickStartPreset(name: "Shortcut audio", systemImage: "music.note", configuration: config)
        preset.launchBehavior = .immediate
        model.quickStartPresets = [preset]
        model.settings.shortcuts = .init(behavior: .options, preferredPresetID: preset.id)
        model.URLText = ""
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        model.openShortcutOptions(.init(request: request, reason: "Review options"))
        for _ in 0..<100 where model.isAnalyzing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isAnalyzing)
        #expect(model.presentsConfiguration)
        #expect(model.configuration.mode == .audioOnly)
        #expect(model.configuration.accountID == config.accountID)
        #expect(!model.presentsQuickStartConfirmation)
        #expect(await model.coordinator.currentJobs().isEmpty)
        model.saveTask?.cancel()
    }

    @Test @MainActor func foregroundChoiceWaitsForOnboardingAndKeepsDraft() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.settings.shortcuts = .init(behavior: .options)
        model.presentsOnboarding = true
        model.URLText = "unfinished draft"
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        model.presentShortcutHandoff(.init(request: request, reason: "Finish setup"))
        #expect(model.shortcutHandoff == nil)
        #expect(model.deferredShortcutHandoffs.count == 1)
        model.presentsOnboarding = false
        model.presentDeferredShortcutHandoff()
        #expect(model.shortcutHandoff?.id == request.id)
        #expect(model.URLText == "unfinished draft")
        #expect(!model.presentsConfiguration)
        model.saveTask?.cancel()
    }

    @Test @MainActor func failedDurableSaveDoesNotStartOrKeepQueueAdmission() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root)
        try await model.waitForShortcutStartup()
        model.saveTask?.cancel()
        model.settings.sponsorBlock = .disabled
        model.settings.defaultDestination = .appDocuments
        model.saveTask?.cancel()
        let directory = root.appendingPathComponent("state")
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory)
        let request = SharedLink(id: UUID(), url: DeveloperFixtures.RickURL, createdAt: .now, isShortcutRequest: true)
        let configuration = try QuickStartPreset(name: "Test", systemImage: "arrow.down",
            configuration: model.settings.configuration()).resolvedConfiguration(metadata: DeveloperFixtures.media)
        await #expect(throws: CocoaError.self) {
            try await model.enqueueShortcut(metadata: DeveloperFixtures.media,
                configuration: configuration, version: nil, request: request)
        }
        #expect(await model.coordinator.currentJob(request.id) == nil)
        model.saveTask?.cancel()
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutTests-" + UUID().uuidString) }
    @MainActor private func makeModel(_ root: URL) -> IllucetAppModel {
        IllucetAppModel(persistence: IllucetPersistence(rootURL: root.appendingPathComponent("state")), fixtureModeOverride: true)
    }
}
