import Foundation
import Testing
import UIKit
@testable import Illucet

struct PipTests {
    @Test @MainActor func notificationTipRequiresPipAndDisabledNotificationsAndAppearsOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = false
        model.firstRunState.pip = .init()
        model.settings = .defaults
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        #expect(!pip.offerNotificationHint(), "No notification hint before a download starts")
        model.firstRunState.pip?.startedFirstDownload = true
        model.settings.pipPreferences.enabled = false
        #expect(!pip.offerNotificationHint())
        #expect(model.firstRunState.pip?.notificationHintShown != true)
        model.settings.pipPreferences.enabled = true
        model.settings.enableRecommendedNotificationEventsIfNeeded()
        model.notificationsAuthorized = true
        #expect(!pip.offerNotificationHint(), "Enabled notifications need no reminder")
        model.notificationsAuthorized = false
        #expect(pip.offerNotificationHint(), "Denied system access can still be explained")
        #expect(pip.showsNotificationSettingsButton)
        pip.showNotificationSettings()
        #expect(model.selectedTab == .settings && model.settingsNavigationPath == [.notifications])
        #expect(!pip.bubbleVisible)
        #expect(!pip.offerNotificationHint(), "The optional reminder is not repeated")
    }
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test @MainActor func selectionHintsAreSeparateOnceOnlyAndRespectDisabledCompanion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = false
        model.firstRunState.pip = .init()
        model.settings.pipPreferences.enabled = false
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        model.selectedTab = .queue
        pip.pageChanged()
        #expect(model.firstRunState.pip?.queueSelectionHintShown != true)
        model.settings.pipPreferences.enabled = true
        pip.pageChanged()
        #expect(!pip.bubbleVisible)
        model.selectedTab = .download
        pip.pageChanged()
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(model.firstRunState.pip?.queueSelectionHintShown != true)
        model.selectedTab = .queue
        pip.pageChanged()
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(pip.bubbleVisible && pip.text.localizedCaseInsensitiveContains("hold"))
        #expect(model.firstRunState.pip?.queueSelectionHintShown == true)
        model.selectedTab = .history
        pip.pageChanged()
        #expect(!pip.bubbleVisible)
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(pip.bubbleVisible && model.firstRunState.pip?.historySelectionHintShown == true)
        pip.dismissBubble()
        model.selectedTab = .queue
        pip.pageChanged()
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(!pip.bubbleVisible)
        let restored = try JSONDecoder().decode(PipLocalState.self,
            from: JSONEncoder().encode(try #require(model.firstRunState.pip)))
        #expect(restored.queueSelectionHintShown == true && restored.historySelectionHintShown == true)
    }

    @Test @MainActor func selectionBubbleDisappearsThreeSecondsAfterTyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = false
        model.firstRunState.pip = .init()
        model.settings.pipPreferences.enabled = true
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        model.selectedTab = .history
        pip.pageChanged()
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(pip.bubbleVisible)
        try await Task.sleep(for: .seconds(4))
        #expect(!pip.bubbleVisible)
        #expect(model.firstRunState.pip?.historySelectionHintShown == true)
    }

    @Test @MainActor func foregroundCompletionsCoalesceAndNeverReplayAfterBackgrounding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.jobs = []
        model.firstRunState.pip = .init()
        model.settings.pipPreferences = .init(frequency: .downloadUpdates)
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        model.jobs = [job]
        pip.observeJobs()
        #expect(pip.text.contains("underway"))

        let another = UUID()
        model.foregroundDownloadCompletions = [job.id: .now]
        pip.receiveDownloadCompletions()
        model.foregroundDownloadCompletions = [job.id: .now, another: .now]
        pip.receiveDownloadCompletions()
        try await Task.sleep(for: .milliseconds(320))
        #expect(pip.bubbleVisible && pip.text.hasPrefix("2 downloads finished"))

        pip.setActive(false)
        // Neither the restored snapshot nor a delayed event from the prior
        // active session is a fresh completion.
        job.state = .completed
        model.jobs = [job]
        model.foregroundDownloadCompletions = [UUID(): Date.now.addingTimeInterval(-1)]
        pip.setActive(true)
        pip.observeJobs()
        try await Task.sleep(for: .milliseconds(320))
        #expect(!pip.bubbleVisible)

        model.settings.pipPreferences.frequency = .occasional
        model.foregroundDownloadCompletions = [UUID(): .now]
        pip.receiveDownloadCompletions()
        try await Task.sleep(for: .milliseconds(320))
        #expect(!pip.bubbleVisible)
    }

    @Test func defaultCompanionAndPortablePreferences() throws {
        #expect(AppSettings.defaults.pipPreferences.enabled)
        #expect(AppSettings.defaults.pipPreferences.frequency == .occasional)
        var settings = AppSettings.defaults
        settings.pipPreferences = .init(enabled: false, frequency: .occasional)
        let backup = PreferencesBackup(settings: settings, presets: QuickStartPresetLibrary.defaults)
        let decoded = try PreferencesBackup.decode(backup.encoded())
        #expect(decoded.settings.pipPreferences == settings.pipPreferences)
        #expect(!String(decoding: try backup.encoded(), as: UTF8.self).contains("recentHints"))
    }

    @Test func occasionalTipsRequireBothTimeAndSeparateSessions() {
        var state = PipLocalState()
        state.guideFinishedAt = now.addingTimeInterval(-4 * 86_400)
        #expect(!state.allowsHint(.occasional, at: now, sessionCount: 0))
        for index in 0..<3 { state.beginSession(at: now.addingTimeInterval(Double(index) * 1_800)) }
        #expect(state.sessionsSinceHint == 3)
        #expect(state.allowsHint(.occasional, at: now, sessionCount: 0))
        state.recordHint("test", at: now)
        state.sessionsSinceHint = 3
        #expect(!state.allowsHint(.occasional, at: now.addingTimeInterval(86_400), sessionCount: 0))
        #expect(state.allowsHint(.occasional, at: now.addingTimeInterval(3 * 86_400), sessionCount: 0))
    }

    @Test func downloadUpdatesRespectTheirHintLimits() {
        var state = PipLocalState()
        state.guideFinishedAt = now.addingTimeInterval(-86_400)
        #expect(state.allowsHint(.downloadUpdates, at: now, sessionCount: 0))
        #expect(!state.allowsHint(.downloadUpdates, at: now, sessionCount: 2))
        state.recordHint("test", at: now)
        #expect(!state.allowsHint(.downloadUpdates, at: now.addingTimeInterval(899), sessionCount: 0))
        #expect(state.allowsHint(.downloadUpdates, at: now.addingTimeInterval(900), sessionCount: 0))
    }

    @Test func repeatedForegroundReturnsDoNotCountAsNewSessions() {
        var state = PipLocalState()
        state.beginSession(at: now)
        state.beginSession(at: now.addingTimeInterval(60))
        #expect(state.sessionsSinceHint == 1)
        state.beginSession(at: now.addingTimeInterval(1_800))
        #expect(state.sessionsSinceHint == 2)
    }

    @Test func hintMemoryExpiresAndStaysLocal() throws {
        var firstRun = FirstRunState.initial
        var state = PipLocalState()
        state.recentHints = ["expired": now.addingTimeInterval(-31 * 86_400), "recent": now.addingTimeInterval(-86_400)]
        state.disableAppealShown = true
        state.recordHint("new", at: now)
        firstRun.pip = state
        firstRun.completeWithoutNotifications(at: now)
        let restored = try JSONDecoder.illucetDecoder.decode(FirstRunState.self, from: JSONEncoder.illucetEncoder.encode(firstRun))
        #expect(restored.pip?.recentHints["expired"] == nil)
        #expect(restored.pip?.recentHints.count == 2)
        #expect(restored.pip?.disableAppealShown == true)
        #expect(!restored.shouldPresentOnboarding)
    }

    @Test func libraryIsVariedAndGuideTargetsActualControls() {
        #expect(PipHint.library.count == 64)
        #expect(Set(PipHint.library.map(\.id)).count == 64)
        #expect(Set(PipHint.library.map(\.text)).count == 64)
        #expect(PipGuideStep.customPresets.anchor == .customPresets)
        #expect(PipGuideStep.colors.anchor == .colors)
        #expect(PipGuideStep.finish.anchor == nil)
    }

    @Test @MainActor func brandedIdentityAndAtlasArePackaged() throws {
        #expect(Bundle.main.bundleIdentifier == "com.local.illucet")
        #expect(AppIdentity.displayName == "Illucet")
        #expect(AppIdentity.URLScheme == "illucet")
        #expect(UIImage(named: "PipAtlas") != nil)
        #expect(UIImage(named: "PipLookUp") != nil)
        #expect(UIImage(named: "PipLookDown") != nil)
        #expect(UIImage(named: "PipEarScratch") != nil)
        let shortcut = try #require(Bundle.main.url(forResource: "Download with Illucet", withExtension: "shortcut"))
        #expect(try Data(contentsOf: shortcut).count > 1_000)
    }

    @Test @MainActor func typingAdvanceAndPokesDoNotChangeTheDraftOrSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        let settings = model.settings
        let draft = model.URLText
        model.presentsOnboarding = true
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: false)
        defer { pip.detach(); model.saveTask?.cancel() }
        #expect(pip.step == .welcome)
        #expect(!pip.finishedTyping)
        pip.advance()
        #expect(pip.step == .welcome)
        #expect(pip.finishedTyping)
        pip.advance()
        #expect(pip.step == .link)
        pip.poke()
        #expect(pip.expression == 9)
        pip.poke()
        #expect(pip.expression == 10)
        pip.poke()
        #expect(pip.text.contains("Stop that"))
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(pip.step == .link)
        #expect(pip.text == PipGuideStep.link.text)
        #expect(model.settings == settings)
        #expect(model.URLText == draft)
        pip.leaveGuide(skipped: true)
        try await Task.sleep(for: .milliseconds(550))
        #expect(pip.step == nil)
        #expect(model.selectedTab == .download)
        #expect(model.firstRunState.onboardingCompleted)
    }

    @Test @MainActor func disabledCompanionCanReplayWithoutBlockingShortcutSetupGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.firstRunState.completeWithoutNotifications()
        model.presentsOnboarding = false
        model.settings.pipPreferences.enabled = false
        model.settings.pipPreferences.frequency = .occasional
        model.replaysPipGuide = true
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        #expect(pip.isGuiding)
        #expect(!model.presentsOnboarding)
        pip.leaveGuide(skipped: false)
        try await Task.sleep(for: .milliseconds(550))
        #expect(!model.settings.pipPreferences.enabled)
        #expect(model.settings.pipPreferences.frequency == .occasional)
        #expect(!model.presentsOnboarding)
        #expect(!model.replaysPipGuide)
    }

    @Test func legacyNeverMigratesToTheOffToggleAndOtherChoicesSurvive() throws {
        let legacy = try JSONDecoder().decode(PipPreferences.self,
            from: Data(#"{"enabled":true,"frequency":"never"}"#.utf8))
        #expect(!legacy.enabled)
        #expect(legacy.frequency == .occasional)
        #expect(PipFrequency.allCases.count == 2)
        let active = try JSONDecoder().decode(PipPreferences.self,
            from: Data(#"{"enabled":true,"frequency":"often"}"#.utf8))
        #expect(active.enabled)
        #expect(active.frequency == .downloadUpdates)
        let quiet = try JSONDecoder().decode(PipPreferences.self,
            from: Data(#"{"enabled":false,"frequency":"medium"}"#.utf8))
        #expect(!quiet.enabled)
        #expect(quiet.frequency == .occasional)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PipPreferences.self, from: Data(#"{"frequency":"unrecognized"}"#.utf8))
        }

        let backup = PreferencesBackup(settings: .defaults, presets: QuickStartPresetLibrary.defaults)
        var json = try #require(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        settings["pip"] = ["enabled": true, "frequency": "never"]
        json["settings"] = settings
        let restored = try PreferencesBackup.decode(JSONSerialization.data(withJSONObject: json))
        #expect(!restored.settings.pipPreferences.enabled)
        #expect(restored.settings.pipPreferences.frequency == .occasional)
    }

    @Test(arguments: [false, true], [false, true])
    func firstDownloadSuggestionOnlyMentionsDisabledSwitches(details: Bool, review: Bool) {
        let preferences = DownloadExperiencePreferences(skipVideoDetails: details, skipDownloadReview: review)
        let suggestion = preferences.pipScreenSkippingSuggestion
        #expect((suggestion == nil) == (details && review))
        if let suggestion {
            #expect(suggestion.contains("Skip video details") == !details)
            #expect(suggestion.contains("Skip download review") == !review)
        }
    }

    @Test @MainActor func finalMessageExitsWithoutAnyAdditionalInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = true
        let draft = model.URLText
        let oldTopRequest = model.downloadTopRequest
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        for _ in 1..<PipGuideStep.allCases.count {
            pip.advance()
            try await waitForSettingsRoute(pip)
        }
        #expect(pip.step == .finish)
        #expect(model.selectedTab == .settings)
        pip.advance()
        try await Task.sleep(for: .milliseconds(270))
        // Ordinary app events must not cancel the separate guide exit task.
        pip.dismissBubble()
        pip.preferencesChanged()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!pip.isLeaving)
        #expect(pip.exitCoverOpacity == 0)
        #expect(!pip.isGuiding)
        #expect(model.selectedTab == .download)
        #expect(model.downloadTopRequest != oldTopRequest)
        #expect(model.firstRunState.onboardingCompleted)
        #expect(model.URLText == draft)
    }

    @Test(arguments: [100, 280]) @MainActor
    func backgroundingDuringGuideExitCannotLeaveAnOpaqueCover(delay: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = true
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: true)
        defer { pip.detach(); model.saveTask?.cancel() }
        pip.leaveGuide(skipped: true)
        try await Task.sleep(for: .milliseconds(delay))
        pip.setActive(false)
        #expect(!pip.isLeaving)
        #expect(pip.exitCoverOpacity == 0)
        #expect(pip.step == nil)
        #expect(model.selectedTab == .download)
        pip.setActive(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pip.exitCoverOpacity == 0)
        #expect(!pip.isGuiding)
    }

    @Test func guideAttentionFollowsTheControlInEveryDirection() {
        let mascot = CGRect(x: 150, y: 300, width: 96, height: 96)
        let targets: [(CGRect, PipGuideAttention)] = [
            (CGRect(x: 0, y: 280, width: 120, height: 130), .left),
            (CGRect(x: 270, y: 280, width: 120, height: 130), .right),
            (CGRect(x: 120, y: 150, width: 240, height: 100), .up),
            (CGRect(x: 120, y: 450, width: 240, height: 100), .down),
            (mascot, .forward)
        ]
        for (target, expected) in targets {
            #expect(PipGuideAttention(target: target, mascot: mascot) == expected)
        }
    }

    @Test @MainActor func finalMessageNeedsOnlyOneTapEvenWhileTyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        model.presentsOnboarding = true
        let pip = PipCoordinator()
        pip.attach(model, active: true, fastText: false)
        defer { pip.detach(); model.saveTask?.cancel() }
        for _ in 1..<PipGuideStep.allCases.count {
            pip.advance()
            pip.advance()
            try await waitForSettingsRoute(pip)
        }
        #expect(pip.step == .finish)
        #expect(!pip.finishedTyping)
        pip.advance()
        try await Task.sleep(for: .milliseconds(550))
        #expect(!pip.isGuiding)
        #expect(!pip.isLeaving)
        #expect(pip.exitCoverOpacity == 0)
        #expect(model.selectedTab == .download)
    }

    @MainActor private func waitForSettingsRoute(_ pip: PipCoordinator) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while pip.navigationCue != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(pip.navigationCue == nil)
    }

    @Test func appearanceStepsPreferLookingAtControlsAboveAndBelow() {
        let size = CGSize(width: 402, height: 780)
        let row = CGRect(x: 20, y: 320, width: 362, height: 60)
        let below = PipGuidePlacement(size: size, focus: row, dialogueHeight: 180, mascotSize: 96, preferredSide: .below)
        #expect(below.mascot.minY > row.maxY)
        #expect(PipGuideAttention(target: row, mascot: below.mascot) == .up)
        let colors = CGRect(x: 20, y: 550, width: 362, height: 140)
        let above = PipGuidePlacement(size: size, focus: colors, dialogueHeight: 180, mascotSize: 96, preferredSide: .above)
        #expect(above.mascot.maxY < colors.minY)
        #expect(PipGuideAttention(target: colors, mascot: above.mascot) == .down)
        #expect(!above.mascot.intersects(above.dialogue))
    }
}
