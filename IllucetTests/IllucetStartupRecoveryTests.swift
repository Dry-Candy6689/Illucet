import Foundation
import Testing
@testable import Illucet

@MainActor
struct IllucetStartupRecoveryTests {
    @Test
    func futureSchemaBlocksNewWorkAndRetryKeepsTheOriginalFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let stateURL = await persistence.persistedStateURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = IllucetSnapshot.currentSchemaVersion + 1
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": future,
            "unknownFutureData": "Preserve this exactly",
        ])
        try original.write(to: stateURL)
        let model = IllucetAppModel(persistence: persistence)
        defer { stopObservation(model) }
        try await waitForPreparation(model)

        #expect(model.startupState == .blocked(.unsupportedSchemaVersion(future)))
        #expect(model.startupState.blocksInteraction)
        #expect(model.alert == nil)
        model.URLText = DeveloperFixtures.RickURL.absoluteString
        model.analyze()
        #expect(!model.isAnalyzing)
        #expect(model.analyzedMetadata == nil)
        model.analyzedMetadata = DeveloperFixtures.media
        model.confirmDownload()
        #expect(model.jobs.isEmpty)
        #expect(await model.coordinator.currentJobs().isEmpty)

        // External share/deep-link entry also remains deferred behind recovery.
        model.URLText = "keep current input"
        let link = try #require(URL(
            string: "\(AppIdentity.URLScheme)://add?url=https%3A%2F%2Fyoutu.be%2FjNQXAC9IVRw"
        ))
        model.receiveDeepLink(link)
        #expect(model.URLText == "keep current input")
        #expect(!model.isAnalyzing)
        await model.persistImmediately()
        #expect(try Data(contentsOf: stateURL) == original)

        model.retryStartupRecovery()
        #expect(model.startupState == .loading)
        model.retryStartupRecovery()
        try await waitForPreparation(model)
        #expect(model.startupState == .blocked(.unsupportedSchemaVersion(future)))
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) == [stateURL])
    }

    @Test
    func retryRestoresExistingStateAndUnblocksOnlyAfterPreparationSucceeds()
        async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let stateURL = await persistence.persistedStateURL
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let model = IllucetAppModel(persistence: persistence)
        defer { stopObservation(model) }
        try await waitForPreparation(model)
        #expect(model.startupState == .blocked(.stateUnavailable))

        try FileManager.default.removeItem(at: stateURL)
        var original = IllucetSnapshot.empty
        original.settings.automaticallyCleanTemporaryFiles = false
        original.firstRunState.completeWithoutNotifications()
        original.filesFolderAlias = "Original folder label"
        original.recentLinks = [RecentLink(
            url: DeveloperFixtures.RickURL,
            title: "Restored link",
            thumbnailURL: nil
        )]
        try JSONEncoder.illucetEncoder.encode(original).write(to: stateURL)

        model.retryStartupRecovery()
        #expect(model.startupState == .loading)
        #expect(model.startupState.blocksInteraction)
        model.retryStartupRecovery()
        try await waitForPreparation(model)

        #expect(model.startupState == .ready)
        #expect(model.startupState.recoveryError == nil)
        #expect(!model.startupState.blocksInteraction)
        #expect(model.alert == nil)
        #expect(model.recentLinks.map(\.title) == ["Restored link"])
        #expect(model.snapshot.filesFolderAlias == "Original folder label")
        await model.persistImmediately()
        let saved = try await IllucetPersistence(rootURL: root).load()
        #expect(saved.recentLinks.map(\.title) == ["Restored link"])
        #expect(saved.filesFolderAlias == "Original folder label")
        model.retryStartupRecovery()
        #expect(model.startupState == .ready)
    }

    private func waitForPreparation(_ model: IllucetAppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isPreparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isPreparing, "Startup did not finish its current attempt.")
    }

    private func stopObservation(_ model: IllucetAppModel) {
        model.updateTask?.cancel()
        model.batchUpdateTask?.cancel()
        model.saveTask?.cancel()
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Startup-Recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
