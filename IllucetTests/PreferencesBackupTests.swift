import Foundation
import Testing
@testable import Illucet

struct PreferencesBackupTests {
    @Test func customPreferencesRoundTripWithoutAccounts() throws {
        var settings = AppSettings.defaults
        settings.appearance = .dark
        settings.experience.skipDownloadReview = true
        settings.clipboard = ClipboardPreferences(enabled: true, explained: true)
        var presets = QuickStartPresetLibrary.defaults
        presets[0].name = "My video"
        presets[0].configuration.accountID = UUID()
        settings.sharedLinks = SharedLinkPreferences(behavior: .presetConfirmation, preferredPresetID: presets[0].id)
        let data = try PreferencesBackup(settings: settings, presets: presets).encoded()
        let restored = try PreferencesBackup.decode(data)
        #expect(restored.settings.appearance == .dark)
        #expect(restored.settings.experience.skipDownloadReview)
        #expect(restored.settings.clipboard?.enabled == true)
        #expect(restored.settings.clipboard?.explained == false)
        #expect(restored.settings.sharedLinks?.preferredPresetID == presets[0].id)
        #expect(restored.presets[0].name == "My video")
        #expect(restored.presets[0].configuration.accountID == nil)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "settings", "presets"])
    }

    @Test func accentAndOLEDPreferencesRoundTripAndRejectInvalidComponents() throws {
        var settings = AppSettings.defaults
        #expect(settings.accentColor == nil)
        #expect(settings.oledDarkBackground == nil)
        settings.accentColor = .init(red: 0, green: 0, blue: 0)
        settings.oledDarkBackground = true
        let restored = try PreferencesBackup.decode(PreferencesBackup(settings: settings, presets: []).encoded())
        #expect(restored.settings.accentColor == settings.accentColor)
        #expect(restored.settings.oledDarkBackground == true)
        #expect(settings.accentColor?.luminance == 0)
        #expect(AppAccentColor(red: 1, green: 1, blue: 1).luminance == 1)
        settings.accentColor = .init(red: -0.1, green: 0, blue: 1)
        #expect(throws: (any Error).self) {
            try PreferencesBackup.decode(PreferencesBackup(settings: settings, presets: []).encoded())
        }
    }

    @Test func olderBackupUsesDefaultsForMissingSettings() throws {
        let data = try PreferencesBackup(settings: .defaults, presets: []).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["settings"] = ["appearance": "Dark"]
        let restored = try PreferencesBackup.decode(JSONSerialization.data(withJSONObject: object))
        #expect(restored.settings.appearance == .dark)
        #expect(restored.settings.maximumSimultaneousDownloads == AppSettings.defaults.maximumSimultaneousDownloads)
        #expect(restored.presets.isEmpty)
    }

    @Test func invalidOrFutureBackupsAreRejected() throws {
        let data = try PreferencesBackup(settings: .defaults, presets: QuickStartPresetLibrary.defaults).encoded()
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var future = original
        future["version"] = 999
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(JSONSerialization.data(withJSONObject: future)) }
        var wrong = original
        wrong["format"] = "unrelated"
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(JSONSerialization.data(withJSONObject: wrong)) }
        var settings = AppSettings.defaults
        settings.maximumSimultaneousDownloads = -1
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(PreferencesBackup(settings: settings, presets: []).encoded()) }
        let preset = QuickStartPresetLibrary.defaults[0]
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(PreferencesBackup(settings: .defaults, presets: [preset, preset]).encoded()) }
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(Data(repeating: 0, count: PreferencesBackup.maximumBytes + 1)) }
        #expect(throws: (any Error).self) { try PreferencesBackup.decode(Data("{broken".utf8)) }
    }

    #if DEBUG
    @Test @MainActor func exportTimestampRequiresSuccessAndStaysLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let model = IllucetAppModel(persistence: persistence, fixtureModeOverride: true)
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.lastPreferencesExportAt == nil)
        #expect(try !model.completePreferencesExport(.failure(CocoaError(.userCancelled))))
        #expect(throws: CocoaError.self) {
            try model.completePreferencesExport(.failure(CocoaError(.fileWriteNoPermission)))
        }
        #expect(model.lastPreferencesExportAt == nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try model.completePreferencesExport(.success(root.appendingPathComponent("export.json")), at: date)
        await model.persistImmediately()
        let restored = try await IllucetPersistence(rootURL: root).load()
        #expect(restored.lastPreferencesExportAt == date)
        let backup = PreferencesBackup(settings: model.settings, presets: model.quickStartPresets)
        #expect(!String(decoding: try backup.encoded(), as: UTF8.self).contains("lastPreferencesExportAt"))
        try await model.importPreferences(backup)
        #expect(model.lastPreferencesExportAt == date)
        #expect(model.snapshot.lastPreferencesExportAt == date)
        #expect(try !model.completePreferencesExport(.failure(CocoaError(.userCancelled))))
        #expect(model.lastPreferencesExportAt == date)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        object.removeValue(forKey: "lastPreferencesExportAt")
        let legacy = try JSONDecoder().decode(IllucetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.lastPreferencesExportAt == nil)
    }

    @Test @MainActor func failedSaveDoesNotApplyImportedPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let model = IllucetAppModel(persistence: persistence, fixtureModeOverride: true)
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.startupState == .ready)
        model.saveTask?.cancel()
        let before = model.settings
        let presets = model.quickStartPresets
        let stateURL = await persistence.persistedStateURL
        // An unwritable state destination must leave the active preferences alone.
        if FileManager.default.fileExists(atPath: stateURL.path) { try FileManager.default.removeItem(at: stateURL) }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        var imported = before
        imported.appearance = .dark
        imported.experience.skipDownloadReview.toggle()
        await #expect(throws: (any Error).self) {
            try await model.importPreferences(PreferencesBackup(settings: imported, presets: []))
        }
        #expect(model.settings == before)
        #expect(model.quickStartPresets == presets)
        model.saveTask?.cancel()
    }

    @Test @MainActor func importPreservesMediaStateAndPersistsPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let model = IllucetAppModel(persistence: persistence, fixtureModeOverride: true)
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.startupState == .ready)
        let jobs = model.jobs, history = model.history, recent = model.recentLinks
        let bookmark = model.snapshot.filesFolderBookmark
        let updates = model.updateStatus
        var settings = model.settings
        settings.experience.skipVideoDetails = true
        settings.appearance = .dark
        var presets = model.quickStartPresets
        presets[0].name = "Imported preset"
        try await model.importPreferences(PreferencesBackup(settings: settings, presets: presets))
        #expect(model.settings.appearance == .dark)
        #expect(model.settings.experience.skipVideoDetails)
        #expect(model.quickStartPresets[0].name == "Imported preset")
        #expect(model.jobs == jobs)
        #expect(model.history == history)
        #expect(model.recentLinks == recent)
        #expect(model.snapshot.filesFolderBookmark == bookmark)
        #expect(model.updateStatus == updates)
        model.saveTask?.cancel()
        let restored = try await IllucetPersistence(rootURL: root).load()
        #expect(restored.settings.appearance == .dark)
        #expect(restored.quickStartPresets[0].name == "Imported preset")
        var invalid = settings
        invalid.automaticRetryCount = -2
        let before = model.settings
        await #expect(throws: (any Error).self) { try await model.importPreferences(PreferencesBackup(settings: invalid, presets: presets)) }
        #expect(model.settings == before)
    }
    #endif
}
