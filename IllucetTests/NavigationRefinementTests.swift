import Foundation
import Testing
import UIKit
@testable import Illucet

struct NavigationRefinementTests {
    private func dated<T: Codable>(_ value: T, at date: Double) throws -> T {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["id"] = UUID().uuidString
        json["createdAt"] = date
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test(arguments: [true, false])
    func activeWorkPrecedesBothDateOrdersWithoutChangingScheduling(newestFirst: Bool) throws {
        var transfer = try dated(DeveloperFixtures.failedThumbnailOnlyJob, at: 100)
        transfer.state = .running; transfer.stage = .downloadingAudio; transfer.priority = 50
        var processing = try dated(transfer, at: 400)
        processing.stage = .merging
        var waiting = try dated(transfer, at: 500)
        waiting.stage = .waitingForTransfer
        var completed = try dated(transfer, at: 200)
        completed.state = .completed
        let jobs = [waiting, completed, processing, transfer]
        let result = BatchQueueOrdering.activeFirstEntries(jobs: jobs, batches: [], packaging: [], newestFirst: newestFirst)
        let active = [transfer, processing], remaining = [completed, waiting]
        let expected = (newestFirst ? Array(active.reversed()) + Array(remaining.reversed()) : active + remaining).map { "job.\($0.id.uuidString)" }
        #expect(result.map(\.id) == expected)
        #expect(jobs.map(\.priority) == [50, 50, 50, 50])
        transfer.state = .completed
        let after = BatchQueueOrdering.activeFirstEntries(jobs: [waiting, completed, processing, transfer], batches: [], packaging: [], newestFirst: newestFirst)
        #expect(after.first?.id == "job.\(processing.id.uuidString)")
    }

    @Test(arguments: DownloadStage.allCases)
    func allWorkingStagesArePinnedButWaitingStagesAreNot(stage: DownloadStage) {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.stage = stage
        let waiting: Set<DownloadStage> = [.waiting, .waitingForTransfer, .waitingForProcessing,
            .waitingForBackgroundTime, .waitingToRetry, .complete]
        #expect(job.isWorkingInQueue == !waiting.contains(stage))
        job.state = .paused
        #expect(!job.isWorkingInQueue)
    }

    @Test(arguments: [true, false])
    func playlistsStayGroupedAndFinalPackagingRemainsActive(newestFirst: Bool) throws {
        var batch = try dated(DeveloperFixtures.completedBatch, at: 100)
        batch.state = .running
        var child = try dated(DeveloperFixtures.failedThumbnailOnlyJob, at: 400)
        child.state = .running; child.stage = .converting
        child.batchMembership = .init(batchID: batch.id, playlistID: batch.playlistID,
            entryID: "child", playlistTitle: batch.title, playlistIndex: 1,
            playlistItemCount: 1, filenameIndexWidth: 2, relativeOutputDirectory: nil)
        let terminal = try dated(DeveloperFixtures.failedThumbnailOnlyJob, at: 300)
        let expected = ["batch.\(batch.id.uuidString)", "job.\(terminal.id.uuidString)"]
        #expect(BatchQueueOrdering.activeFirstEntries(jobs: [terminal, child], batches: [batch],
            packaging: [], newestFirst: newestFirst).map(\.id) == expected)
        child.state = .completed; batch.state = .completed
        #expect(BatchQueueOrdering.activeFirstEntries(jobs: [terminal, child], batches: [batch],
            packaging: [batch.id], newestFirst: newestFirst).map(\.id) == expected)
    }

    @Test @MainActor func tabReselectionRespectsSettingsDepthAndPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel() }
        let downloadState = try #require(model.tabScrollStates[.download])
        #expect(downloadState.request == nil)
        model.selectTab(.settings)
        #expect(downloadState.request == nil)
        model.selectTab(.download)
        #expect(model.tabScrollStates[.download] === downloadState)
        #expect(downloadState.request == nil)
        model.selectTab(.download)
        #expect(downloadState.request?.animated == true)
        model.selectTab(.settings)
        #expect(downloadState.request == nil)
        let settingsState = try #require(model.tabScrollStates[.settings])
        model.settingsNavigationPath = [.accounts]
        model.selectTab(.settings)
        #expect(model.settingsNavigationPath.isEmpty)
        #expect(settingsState.request == nil)
        model.selectTab(.settings)
        #expect(settingsState.request != nil)
        settingsState.request = nil
        model.settings.tapTabToScrollToTop = false
        model.settingsNavigationPath = [.accounts]
        model.selectTab(.settings)
        #expect(model.settingsNavigationPath.isEmpty)
        model.selectTab(.settings)
        #expect(settingsState.request == nil)
    }

    @Test func navigationPreferenceRoundTripsAndOldSettingsKeepDefault() throws {
        var settings = AppSettings.defaults
        settings.tapTabToScrollToTop = false
        let backup = PreferencesBackup(settings: settings, presets: QuickStartPresetLibrary.defaults)
        #expect(try PreferencesBackup.decode(backup.encoded()).settings.tapTabToScrollToTop == false)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "tapTabToScrollToTop")
        let older = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.tapTabToScrollToTop ?? true)
    }

    @Test @MainActor func alternateIconsAndBothPreviewsArePackaged() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        #expect(Set(alternates.keys) == ["AppIconOrange", "AppIconPurple", "AppIconPink"])
        for choice in AppIconChoice.allCases {
            for appearance in ["Light", "Dark"] {
                #expect(UIImage(named: "IconPreview" + choice.rawValue + appearance) != nil)
            }
        }
    }
}
