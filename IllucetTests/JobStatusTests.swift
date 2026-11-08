import Foundation
import Testing
import UIKit
@testable import Illucet

@Suite("status and notifications")
struct JobStatusTests {
    @Test func systemTaskProgressUsesPercentAndUnknownPreparationIsIndeterminate() {
        let progress = Progress(totalUnitCount: 1000)
        JobStatusPresentation.updateSystemProgress(progress, stage: "Preparing download", fraction: nil)
        #expect(progress.isIndeterminate)
        #expect(progress.localizedAdditionalDescription == "Preparing download")
        JobStatusPresentation.updateSystemProgress(progress, stage: "Downloading video", fraction: 0.425)
        #expect(progress.totalUnitCount == 100 && progress.completedUnitCount == 42)
        #expect(progress.localizedAdditionalDescription == "42% complete")
        JobStatusPresentation.updateSystemProgress(progress, stage: "Open Illucet to continue", fraction: nil)
        #expect(progress.isIndeterminate && progress.completedUnitCount == 0)
        #expect(progress.localizedDescription == "Open Illucet to continue")
        JobStatusPresentation.updateSystemProgress(progress, stage: "Converting", fraction: .nan)
        #expect(progress.isIndeterminate)
        JobStatusPresentation.updateSystemProgress(progress, stage: "Download completed", fraction: 1)
        #expect(progress.completedUnitCount == 100)
    }

    @Test func islandShowsActualFailurePauseAndForegroundHandoffInsteadOfZero() throws {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.stage = .downloadingVideo
        job.progress.totalBytes = 1000; job.progress.bytesDownloaded = 0
        let running = LiveActivityController.state(job)
        #expect(running.compactLabel(isStale: false) == "…")
        #expect(running.compactLabel(isStale: true) == "Open")
        #expect(running.statusText(isStale: true) == "Open Illucet to check progress")
        for (state, label, phase) in [(DownloadJobState.failed, "Failed", DownloadActivityAttributes.Phase.failed),
                                     (.paused, "Paused", .paused), (.completed, "Done", .completed),
                                     (.waitingForPower, "Wait", .waiting)] {
            job.state = state
            let content = LiveActivityController.state(job)
            #expect(content.phase == phase)
            #expect(content.compactLabel(isStale: false) == label)
            #expect(content.symbolName(isStale: false) != "arrow.down.circle")
        }
        job.state = .needsAttention; job.errorCode = "background_processing_expired"
        let handoff = LiveActivityController.state(job)
        #expect(handoff.compactLabel(isStale: false) == "Open")
        #expect(handoff.stage == "Open Illucet to continue" && handoff.fraction == nil)
        #expect(!handoff.showsTimeRemaining)
        let legacy = Data(#"{"stage":"Downloading video","fraction":0,"terminal":false}"#.utf8)
        #expect(try JSONDecoder().decode(DownloadActivityAttributes.ContentState.self, from: legacy).phase == nil)
    }

    @Test func liveActivityFocusesRunningJobAheadOfAnOlderPausedOrDeferredJob() {
        var old = DeveloperFixtures.failedThumbnailOnlyJob
        old.state = .needsAttention; old.errorCode = "background_processing_expired"
        var running = DownloadJob(id: UUID(), sourceURL: old.sourceURL, videoID: old.videoID,
            title: "New download", createdAt: old.createdAt.addingTimeInterval(10), updatedAt: .now,
            configuration: .standard, state: .running, stage: .downloadingVideo, progress: .zero,
            priority: 0, retryCount: 0, maximumRetries: 2, selectedFormatIDs: [])
        #expect(LiveActivityController.focusedJob(in: [old, running])?.id == running.id)
        old.state = .paused
        #expect(LiveActivityController.focusedJob(in: [old, running])?.id == running.id)
        running.state = .failed; old.state = .completed
        #expect(LiveActivityController.focusedJob(in: [old, running]) == nil)
    }

    @Test func notificationObservationIgnoresAnOlderSnapshot() async {
        let sink = NotificationRecorder()
        let service = UserNotificationService(deliver: { await sink.add($0) })
        var running = DeveloperFixtures.failedThumbnailOnlyJob
        running.state = .running; running.updatedAt = .now
        var waiting = running
        waiting.state = .needsAttention; waiting.errorCode = "background_processing_expired"
        waiting.updatedAt = running.updatedAt.addingTimeInterval(1)
        var settings = AppSettings.defaults; settings.notifyNeedsAttention = true
        await service.observe(job: running, settings: settings)
        await service.observe(job: waiting, settings: settings)
        await service.observe(job: running, settings: settings)
        await service.observe(job: waiting, settings: settings)
        #expect(await sink.messages.count == 1)
    }

    @Test func queueBadgeReflectsActualActivityAndAttentionTakesPriority() {
        func badge(_ jobs: [DownloadJob], pending: Bool = false, completed: Bool = false) -> QueueTabBadge? {
            QueueTabBadge.resolve(jobs: jobs, batches: [], packaging: [], hasPendingAction: pending, hasNewCompletion: completed)
        }
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        for state in DownloadJobState.allCases {
            job.state = state; job.stage = .downloadingThumbnail
            let expected: QueueTabBadge? = switch state {
            case .failed, .needsAttention, .waitingForCellularApproval: .attention
            case .running: .downloading
            case .paused: .paused
            case .queued, .waitingForNetwork, .waitingForWiFi, .waitingForRetry, .waitingForPower: .waiting
            case .cancelled, .completed: nil
            }
            #expect(badge([job]) == expected)
        }
        job.state = .running
        for stage in [DownloadStage.waitingForTransfer, .waitingForProcessing, .waitingForBackgroundTime, .waitingToRetry] {
            job.stage = stage
            #expect(badge([job]) == .waiting)
        }
        job.stage = .converting
        #expect(badge([job]) == .processing)
        job.stage = .downloadingVideo
        let failed = DeveloperFixtures.failedThumbnailOnlyJob
        #expect(badge([job, failed]) == .attention)
        #expect(badge([failed, job]) == .attention)
        #expect(badge([job], pending: true) == .attention)
        #expect(badge([], completed: true) == .completed)
        #expect(badge([]) == nil)
        #expect(badge([job], completed: true) == .downloading)
    }

    @Test func queueBadgeIncludesBatchPackagingPausesAndFailures() {
        var batch = DeveloperFixtures.completedBatch
        func badge() -> QueueTabBadge? {
            QueueTabBadge.resolve(jobs: [], batches: [batch], packaging: [], hasPendingAction: false, hasNewCompletion: false)
        }
        batch.state = .paused
        #expect(badge() == .paused)
        batch.state = .queued
        #expect(badge() == .waiting)
        batch.state = .running
        #expect(badge() == .processing)
        batch.state = .completedWithFailures
        #expect(badge() == .attention)
        batch.state = .completed; batch.destinationStructure = .zipArchive
        batch.packageURL = nil; batch.packageErrorMessage = nil
        #expect(badge() == .processing)
        batch.packageErrorMessage = "Fixture package failure"
        #expect(badge() == .attention)
        batch.packageErrorMessage = nil; batch.packageURL = URL(fileURLWithPath: "/tmp/fixture.zip")
        #expect(badge() == nil)
    }

    @Test @MainActor func queueCompletionDotAcknowledgesEveryNavigationPathAndIgnoresRestoredJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: root), fixtureModeOverride: true)
        await model.startupTask?.value
        defer { model.saveTask?.cancel(); model.sponsorBlockPreviewTask?.cancel() }
        model.jobs = []; model.batches = []; model.selectedTab = .download
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .completed
        model.startupState = .loading
        model.jobs = [job]
        model.startupState = .ready
        #expect(model.queueTabBadge == nil)
        job.state = .running; job.stage = .downloadingThumbnail
        model.jobs = [job]
        #expect(model.queueTabBadge == .downloading)
        job.state = .completed; job.stage = .complete
        model.jobs = [job]
        #expect(model.queueTabBadge == .completed)
        model.selectTab(.queue)
        #expect(model.queueTabBadge == nil)
        model.selectedTab = .download
        model.jobs = [job]
        #expect(model.queueTabBadge == nil)
        job.state = .running; model.jobs = [job]
        job.state = .completed; model.jobs = [job]
        #expect(model.queueTabBadge == .completed)
        model.selectedTab = .queue // Deep links and programmatic selection also acknowledge.
        model.selectedTab = .history
        #expect(model.queueTabBadge == nil)
        var batch = DeveloperFixtures.completedBatch
        batch.state = .running; model.batches = [batch]
        batch.state = .completed; batch.destinationStructure = .selectedFolder
        model.batches = [batch]
        #expect(model.queueTabBadge == .completed)
        model.batches = []
        #expect(model.queueTabBadge == nil)
    }

    @Test func statusNeverLeaksTransferMetricsIntoProcessingOrPause() {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        job.stage = .downloadingVideo
        job.progress.totalBytes = 1000
        job.progress.bytesDownloaded = 500
        job.progress.sampleCount = 3
        job.progress.smoothedBytesPerSecond = 100
        job.progress.downloadETASeconds = 5
        job.progress.overallETASeconds = 999
        #expect(JobStatusPresentation(job: job).fraction == 0.5)
        #expect(JobStatusPresentation(job: job).remaining == "Transfer: ≈ 5s left")
        job.stage = .converting
        job.progress.processingFraction = 0.2
        #expect(JobStatusPresentation(job: job).fraction == 0.2)
        #expect(JobStatusPresentation(job: job).speed == nil)
        #expect(JobStatusPresentation(job: job).remaining == nil)
        job.progress.processingETASeconds = 20
        #expect(JobStatusPresentation(job: job).remaining == "Processing: ≈ 20s left")
        job.state = .paused
        #expect(JobStatusPresentation(job: job).fraction == nil)
        #expect(JobStatusPresentation(job: job).remaining == nil)
    }

    @Test func completedTransferUsesFullRangeThenProcessingStartsItsOwnRange() {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.stage = .downloadingVideo
        job.progress.totalBytes = 1_000; job.progress.bytesDownloaded = 1_000
        job.progress.overallFraction = 0.78
        #expect(JobStatusPresentation(job: job).fraction == 1)
        job.stage = .converting; job.progress.processingFraction = 0
        #expect(JobStatusPresentation(job: job).fraction == 0)
        job.progress.processingFraction = 0.65
        #expect(JobStatusPresentation(job: job).fraction == 0.65)
        job.progress.processingFraction = nil
        #expect(JobStatusPresentation(job: job).fraction == nil)
    }

    @Test func foregroundDeferralNotifiesAttentionOnceWithActionableText() async {
        let sink = NotificationRecorder()
        let service = UserNotificationService(deliver: { await sink.add($0) })
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        var settings = AppSettings.defaults; settings.notifyNeedsAttention = true
        await service.observe(job: job, settings: settings)
        job.state = .needsAttention; job.errorCode = "playback_requires_foreground"
        await service.observe(job: job, settings: settings)
        await service.observe(job: job, settings: settings)
        let messages = await sink.messages
        #expect(messages.count == 1)
        #expect(messages.first?.title == "Illucet needs attention")
        #expect(messages.first?.body.contains("Open Illucet to continue") == true)
    }

    @Test @MainActor func backgroundAndInactivePlaybackRequireForeground() throws {
        try ApplePlaybackVerifier.requireForeground(.active)
        #expect(throws: ApplePlaybackVerifierError.requiresForeground) {
            try ApplePlaybackVerifier.requireForeground(.active, interrupted: true)
        }
        #expect(throws: ApplePlaybackVerifierError.requiresForeground) {
            try ApplePlaybackVerifier.requireForeground(.background)
        }
        #expect(throws: ApplePlaybackVerifierError.requiresForeground) {
            try ApplePlaybackVerifier.requireForeground(.inactive)
        }
    }

    @Test func foregroundResumeIsTypedAndNeverResumesManualPauseOrRealFailure() throws {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .needsAttention
        job.errorCode = "background_processing_expired"
        #expect(job.resumesOnForeground)
        job.foregroundResumeReason = .processingTime
        let decoded = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.resumesOnForeground)
        #expect(JobStatusPresentation(job: decoded).stage == "Open Illucet to continue")
        #expect(JobStatusPresentation(job: decoded).fraction == nil)
        for state in [DownloadJobState.paused, .failed, .cancelled, .completed] {
            job.state = state
            #expect(!job.resumesOnForeground)
        }
        job.state = .needsAttention; job.foregroundResumeReason = nil; job.errorCode = "missing_output"
        #expect(!job.resumesOnForeground)
    }

    @Test func invalidProgressRemainsUnknown() {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.stage = .converting
        job.progress.processingFraction = .nan
        job.progress.processingETASeconds = .infinity
        #expect(JobStatusPresentation(job: job).fraction == nil)
        #expect(JobStatusPresentation(job: job).remaining == nil)
    }

    @Test func remainingTimeUsesCoarseReadableUnits() {
        #expect(JobStatusPresentation.remainingDuration(.infinity) == "Unknown")
        #expect(JobStatusPresentation.remainingDuration(.nan) == "Unknown")
        #expect(JobStatusPresentation.remainingDuration(178) == "3m")
        #expect(JobStatusPresentation.remainingDuration(173) == "3m")
        #expect(JobStatusPresentation.remainingDuration(164) == "2m 45s")
        #expect(JobStatusPresentation.remainingDuration(58) == "1m")
        #expect(JobStatusPresentation.remainingDuration(3_601) == "1h 1m")
    }

    @Test func eventPreferencesAndTransitionDeduplication() async {
        let sink = NotificationRecorder()
        let service = UserNotificationService(deliver: { await sink.add($0) })
        var settings = AppSettings.defaults
        settings.notifyNeedsAttention = true
        settings.notifyLowStorage = true
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running; job.errorMessage = "https://secret.test/?token=private"
        await service.observe(job: job, settings: settings)
        job.state = .needsAttention
        await service.observe(job: job, settings: settings)
        await service.observe(job: job, settings: settings)
        job.state = .failed; job.errorCode = "insufficient_storage"; job.retryExhausted = true
        settings.notifyRetryExhausted = false
        await service.observe(job: job, settings: settings)
        let messages = await sink.messages
        #expect(messages.count == 2)
        #expect(messages.map(\.title) == ["Illucet needs attention", "Not enough storage"])
        #expect(messages.allSatisfy { !$0.body.contains("private") && !$0.body.contains("secret.test") })
    }

    @Test func processingNotificationWaitsForVerifiedExportBoundary() {
        var enabled = AppSettings.defaults
        enabled.notifyProcessingComplete = true
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        job.pipelineCheckpoint = .init(phase: .outputVerified, processedFileURL: URL(filePath: "/tmp/fixture"))
        var ready = job
        ready.pipelineCheckpoint?.phase = .exporting
        #expect(JobNotificationPolicy.events(previous: job, job: ready, settings: enabled) == [.processingComplete])
        #expect(JobNotificationPolicy.events(previous: ready, job: ready, settings: enabled).isEmpty)
        #expect(JobNotificationPolicy.events(previous: nil, job: ready, settings: enabled).isEmpty)
        var disabled = AppSettings.defaults; disabled.notifyProcessingComplete = false
        #expect(JobNotificationPolicy.events(previous: job, job: ready, settings: disabled).isEmpty)
    }

    @Test func batchCompletionWaitsForPackageAndSuppressesRestoredHistory() async {
        let sink = NotificationRecorder()
        let service = UserNotificationService(deliver: { await sink.add($0) })
        var settings = AppSettings.defaults
        settings.notifyPlaylistComplete = true
        var batch = DownloadBatch(analysis: DeveloperFixtures.playlist, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .zipArchive, continueOnError: true,
            skipArchivedItems: false, numberFilenames: true, filenameIndexWidth: 2,
            entries: Array(DeveloperFixtures.playlist.entries.prefix(2)))
        await service.observe(batch: batch, settings: settings)
        batch.state = .completed
        await service.observe(batch: batch, settings: settings)
        #expect(await sink.messages.isEmpty)
        batch.packageURL = URL(filePath: "/tmp/package.zip")
        await service.observe(batch: batch, settings: settings)
        await service.observe(batch: batch, settings: settings)
        #expect(await sink.messages.count == 1)
        let restored = UserNotificationService(deliver: { await sink.add($0) })
        await restored.observe(batch: batch, settings: settings)
        #expect(await sink.messages.count == 1)
        let disabled = UserNotificationService(deliver: { await sink.add($0) })
        batch.state = .running
        await disabled.observe(batch: batch, settings: settings)
        batch.state = .completed
        settings.notifyPlaylistComplete = false
        await disabled.observe(batch: batch, settings: settings)
        #expect(await sink.messages.count == 1)
    }

    @Test func notificationDefaultsAreOffAndExplicitOptInPreservesEventChoices() throws {
        var settings = AppSettings.defaults
        #expect(!settings.hasNotificationEventsEnabled)
        #expect(settings.notifyPlaylistComplete == false && settings.notifyRetryExhausted == false)
        settings.enableRecommendedNotificationEventsIfNeeded()
        #expect(settings.notifyDownloadComplete && settings.notifyFailure && settings.notifyNeedsAttention)
        #expect(!settings.notifyProcessingComplete)
        settings.notifyFailure = false
        let chosen = settings
        settings.enableRecommendedNotificationEventsIfNeeded()
        #expect(settings == chosen)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(chosen))
        #expect(decoded == chosen)
    }

    @Test func exhaustedRetriesRequireTypedTransientFailure() {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.maximumRetries = 2; job.retryCount = 2
        let policy = DownloadRetryController()
        #expect(policy.exhausted(error: URLError(.timedOut), job: job))
        #expect(!policy.exhausted(error: URLError(.userAuthenticationRequired), job: job))
        #expect(!policy.exhausted(error: CancellationError(), job: job))
        job.retryCount = 1
        #expect(!policy.exhausted(error: URLError(.timedOut), job: job))
    }

    @Test func completionAndFailureMessagesContainOnlySafeJobFacts() async {
        let sink = NotificationRecorder()
        let service = UserNotificationService(deliver: { await sink.add($0) })
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.errorMessage = "https://secret.test/?token=private"
        await service.notifyFailure(job: job)
        #expect(await service.routeCompletion(job: job, notifyWhenBackgrounded: true) == nil)
        let messages = await sink.messages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.jobID == job.id && !$0.body.contains("token=") })
    }

    @Test func completionRoutesToExactlyOnePresentationChannel() async {
        let sink = NotificationRecorder()
        let time = Date(timeIntervalSince1970: 123)
        let foreground = UserNotificationService(foregroundCompletionTime: { time }) { await sink.add($0) }
        let background = UserNotificationService(deliver: { await sink.add($0) })
        let job = DeveloperFixtures.failedThumbnailOnlyJob
        #expect(await foreground.routeCompletion(job: job, notifyWhenBackgrounded: true) == time)
        #expect(await sink.messages.isEmpty)
        #expect(await background.routeCompletion(job: job, notifyWhenBackgrounded: false) == nil)
        #expect(await sink.messages.isEmpty)
        #expect(await background.routeCompletion(job: job, notifyWhenBackgrounded: true) == nil)
        #expect(await sink.messages.map(\.title) == ["Download complete"])
    }

    @Test func legacySettingsDecodeWithNewPreferencesEnabled() throws {
        let data = try JSONEncoder().encode(AppSettings.defaults)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "notifyPlaylistComplete")
        object.removeValue(forKey: "notifyRetryExhausted")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.notifyPlaylistComplete ?? true)
        #expect(restored.notifyRetryExhausted ?? true)
    }
}

private actor NotificationRecorder {
    var messages: [JobNotificationMessage] = []
    func add(_ message: JobNotificationMessage) { messages.append(message) }
}
