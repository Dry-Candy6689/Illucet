import Foundation
import Testing
@testable import Illucet

struct RefinementTests {
    @Test func oldGlobalQuickStartMigratesWithoutChangingSavedOutputChoices() throws {
        var snapshot = IllucetSnapshot.empty
        snapshot.settings.experience.instantQuickStart = true
        snapshot.settings.automaticRetryCount = 8
        snapshot.quickStartPresets[0].configuration.thumbnailBehavior = .none
        let restored = IllucetAppPersistedState.restoring(snapshot)
        #expect(!restored.settings.experience.instantQuickStart)
        #expect(restored.quickStartPresets.allSatisfy { $0.launchBehavior == .immediate })
        #expect(restored.quickStartPresets[0].configuration.thumbnailBehavior == .none)
        #expect(restored.settings.automaticRetryCount == 5)
        let backup = try PreferencesBackup.decode(PreferencesBackup(settings: snapshot.settings, presets: snapshot.quickStartPresets).encoded())
        #expect(backup.settings.automaticRetryCount == 5)
        #expect(!backup.settings.experience.instantQuickStart)
        #expect(backup.presets.allSatisfy { $0.launchBehavior == .immediate })
        #expect(AppSettings.defaults.automaticRetryCount == 1)
        #expect(AppSettings.defaults.thumbnailBehavior == .includeVideoThumbnail)
    }

    @Test func oldAppealDisplayDoesNotMeanTheUserConfirmedDisabling() throws {
        var local = PipLocalState()
        local.disableAppealShown = true
        let data = try JSONEncoder().encode(local)
        let restored = try JSONDecoder().decode(PipLocalState.self, from: data)
        #expect(restored.disableConfirmed != true)
        var snapshot = IllucetSnapshot.empty
        snapshot.firstRunState.pip = restored
        #expect(IllucetAppPersistedState.restoring(snapshot).firstRunState.pip?.disableConfirmed != true)
        snapshot.settings.pipPreferences.enabled = false
        #expect(IllucetAppPersistedState.restoring(snapshot).firstRunState.pip?.disableConfirmed == true)
    }

    @Test(arguments: [DownloadStage.downloadingVideo, .downloadingAudio, .downloadingThumbnail,
                      .downloadingSubtitles, .verifyingSources, .preparing, .waitingForTransfer])
    func allTransferStagesCountTowardTheManualStartPrompt(stage: DownloadStage) {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .running
        job.stage = stage
        #expect(TransferAdmissionPolicy.requestsTransfer(job))
        job.state = .paused
        #expect(!TransferAdmissionPolicy.requestsTransfer(job))
        job.state = .running
        job.stage = .converting
        #expect(!TransferAdmissionPolicy.requestsTransfer(job))
    }

    @Test func explicitTransferExceptionCannotIncreaseTheProcessingLimitOrAdmitOtherJobs() async throws {
        let scheduler = DownloadScheduler(transferPermits: AsyncPermitPool(limit: 2), processingPermits: AsyncPermitPool(limit: 1))
        let first = UUID(), second = UUID(), exception = UUID(), waiting = UUID()
        try await scheduler.acquireTransfer(jobID: first)
        try await scheduler.acquireTransfer(jobID: second)
        try await scheduler.acquireTransfer(jobID: exception, allowsOverLimit: true)
        #expect(await scheduler.transferSnapshot().activeCount == 3)
        #expect(await scheduler.transferSnapshot().limit == 2)
        #expect(await scheduler.processingSnapshot().limit == 1)
        let pending = Task { try await scheduler.acquireTransfer(jobID: waiting) }
        for _ in 0..<100 where await scheduler.transferSnapshot().waitingCount == 0 { await Task.yield() }
        #expect(await scheduler.transferSnapshot().waitingCount == 1)
        await scheduler.releaseTransfer(jobID: first)
        #expect(await scheduler.transferSnapshot().activeCount == 2)
        #expect(await scheduler.transferSnapshot().waitingCount == 1)
        await scheduler.releaseTransfer(jobID: exception)
        try await pending.value
        #expect(await scheduler.transferSnapshot().activeCount == 2)
        await scheduler.releaseTransfer(jobID: second)
        await scheduler.releaseTransfer(jobID: waiting)
        #expect(await scheduler.transferSnapshot().activeCount == 0)
    }

    @Test func selectionPrunesIneligibleWorkAndStaysIndependentBetweenPages() {
        let a = SelectionItem.job(UUID()), b = SelectionItem.job(UUID())
        var queue = InlineSelectionState(), history = InlineSelectionState()
        queue.update([a, b]); queue.begin(a)
        #expect(queue.isActive && queue.selected == [a])
        #expect(!history.isActive)
        queue.selectAll(); #expect(queue.allSelected)
        queue.update([b]); #expect(queue.selected == [b])
        queue.selectAll(); #expect(queue.isActive && queue.selected.isEmpty)
        history.update([.history(UUID())]); history.selectAll()
        queue.cancel(); #expect(history.allSelected)
    }

    @Test func highlightIsAnOptInPointAndCannotRemoveContent() throws {
        var policy = SponsorBlockPolicy.disabled
        policy.setEnabled(true)
        #expect(policy.categoryDefaultAction(for: .highlight) == .keep)
        #expect(SponsorBlockCategory.highlight.editableActions == [.keep, .markAsChapter])
        policy.setDefaultAction(.markAsChapter, for: .highlight)
        policy.replaceSelection(videoID: "test", queriedCategories: policy.requestedDiscoveryCategories,
            segments: [SponsorBlockSegment(segmentID: "point", category: .highlight, startSeconds: 60, endSeconds: 60,
                description: nil, submittedVideoDuration: 100, serverAction: .pointOfInterest, votes: 4, isLocked: false)])
        let plan = try SponsorBlockPlanner.makePlan(policy: policy, videoID: "test", analyzedDuration: 100)
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].startSeconds == plan.entries[0].endSeconds)
        policy.selectionSnapshot?.segments[0].actionOverride = .remove
        #expect(throws: SponsorBlockPlanningError.invalidSegmentRange) {
            try SponsorBlockPlanner.makePlan(policy: policy, videoID: "test", analyzedDuration: 100)
        }
    }

    @Test func highlightMapsThroughCutsAndPreservesCreatorChapterNames() throws {
        let plan = SponsorBlockPlan(videoID: "test", entries: [
            SponsorBlockPlanEntry(sourceSegmentIDs: ["point"], categories: [.highlight], startSeconds: 60, endSeconds: 60, action: .markAsChapter)
        ])
        let timeline = try SponsorBlockTimeline.compose(sourceDurationSeconds: 100, manualTrim: nil,
            requestedRemovals: [MediaTimeRange(startSeconds: 20, endSeconds: 30)])
        let chapters = try SponsorBlockChapterMerger.merge(creatorChapters: [
            ExtractedChapter(title: "Opening", startTimeSeconds: 0, endTimeSeconds: 50),
            ExtractedChapter(title: "Main", startTimeSeconds: 50, endTimeSeconds: 100)
        ], includeCreatorChapters: true, creatorDurationSeconds: 100, plan: plan, timeline: timeline)
        #expect(timeline.finalDurationSeconds == 90)
        #expect(chapters.chapters.contains { $0.title == "Main · Highlight" && $0.startSeconds == 50 })
        #expect(chapters.chapters.first?.title == "Opening")
        let removed = try SponsorBlockTimeline.compose(sourceDurationSeconds: 100, manualTrim: nil,
            requestedRemovals: [MediaTimeRange(startSeconds: 55, endSeconds: 65)])
        let missing = try SponsorBlockChapterMerger.merge(creatorChapters: [], includeCreatorChapters: false, plan: plan, timeline: removed)
        #expect(missing.chapters.isEmpty)
    }

    @Test func mascotStaysBesideTheTargetWithoutCoveringDialogue() {
        let size = CGSize(width: 402, height: 780)
        for focus in [CGRect(x: 20, y: 140, width: 362, height: 180), CGRect(x: 20, y: 500, width: 362, height: 60)] {
            let placement = PipGuidePlacement(size: size, focus: focus, dialogueHeight: 180, mascotSize: 96)
            #expect(!placement.mascot.intersects(focus))
            #expect(!placement.mascot.intersects(placement.dialogue))
            #expect(CGRect(origin: .zero, size: size).contains(placement.mascot))
            #expect(min(abs(placement.mascot.minY - focus.maxY), abs(placement.mascot.maxY - focus.minY)) <= 12)
        }
    }
}
