import Foundation
import Testing
@testable import Illucet

@Suite @MainActor
struct DownloadAdmissionTests {
    @Test(arguments: [false, true])
    func rapidAndDelayedSubmissionAdmitOneJobPerReview(subtitlesOnly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await readyModel(root: root)
        if subtitlesOnly { model.selectSubtitlesOnly() }
        model.confirmDownload()
        #expect(model.isStartingDownload) // Claimed before a Task can run.
        model.confirmDownload()
        try await waitUntil { !model.isStartingDownload }
        #expect(await model.coordinator.currentJobs().count == 1)
        model.confirmDownload() // A late tap on the dismissed review is still stale.
        #expect(!model.isStartingDownload)
        #expect(await model.coordinator.currentJobs().count == 1)
        model.openConfiguration() // An intentional new review may download the same URL.
        model.confirmDownload()
        try await waitUntil { !model.isStartingDownload }
        #expect(await model.coordinator.currentJobs().count == 2)
        for job in await model.coordinator.currentJobs() { await model.coordinator.cancel(job.id) }
    }

    @Test
    func failedSubmissionReleasesClaimAndQuickStartSharesTheGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await readyModel(root: root)
        model.configuration.destination = .filesFolder // No bookmark; return to the picker.
        model.confirmDownload()
        #expect(model.isStartingDownload)
        try await waitUntil { !model.isStartingDownload }
        #expect(await model.coordinator.currentJobs().isEmpty)
        model.configuration.destination = .appDocuments
        model.activeQuickStartPreset = try #require(model.quickStartPresets.first)
        model.confirmQuickStartDownload()
        #expect(model.isStartingDownload)
        model.confirmDownload()
        model.confirmQuickStartDownload()
        try await waitUntil { !model.isStartingDownload }
        #expect(await model.coordinator.currentJobs().count == 1)
        model.activeQuickStartPreset = model.quickStartPresets.first
        await model.launchQuickStart() // The async entry point rejects the consumed review too.
        #expect(await model.coordinator.currentJobs().count == 1)
        for job in await model.coordinator.currentJobs() { await model.coordinator.cancel(job.id) }
    }

    private func readyModel(root: URL) async throws -> IllucetAppModel {
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        try await waitUntil { model.startupState == .ready }
        model.analyzedMetadata = DeveloperFixtures.media
        var config = DownloadConfiguration.standard
        config.selectedVideoFormatID = "18"
        config.selectedAudioFormatID = nil
        config.thumbnailBehavior = .none
        config.preserveChapters = false
        config.writeChapters = false
        config.waitForCharging = true
        config.destination = .appDocuments
        model.configuration = OutputCapabilityMatrix.normalized(config)
        model.settings.minimumFreeSpaceReserveBytes = 0
        await model.coordinator.updatePowerState(connected: false)
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AdmissionFailure.timeout
    }
}

private enum AdmissionFailure: Error { case timeout }
