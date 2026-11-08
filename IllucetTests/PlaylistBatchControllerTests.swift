import Foundation
import Testing
@testable import Illucet

struct PlaylistBatchControllerTests {
    @Test
    func aggregatorUsesTruthfulCountsUnknownTotalsAndTerminalState() {
        let batchID = UUID()
        let first = fixtureItem(index: 1)
        var second = fixtureItem(index: 2)
        second.estimatedBytes = nil
        let firstMembership = membership(
            batchID: batchID,
            item: first,
            itemCount: 2
        )
        let secondMembership = membership(
            batchID: batchID,
            item: second,
            itemCount: 2
        )
        let firstJob = fixtureJob(
            membership: firstMembership,
            state: .completed,
            bytes: 1_000,
            total: 1_000,
            fraction: 1
        )
        let secondJob = fixtureJob(
            membership: secondMembership,
            state: .running,
            bytes: 500,
            total: nil,
            fraction: 0.25
        )
        let items = [
            BatchProgressAggregator.updatedItem(first, from: firstJob),
            BatchProgressAggregator.updatedItem(second, from: secondJob),
        ]

        let progress = BatchProgressAggregator.progress(
            items: items,
            jobsByID: [
                firstJob.id: firstJob,
                secondJob.id: secondJob,
            ]
        )

        #expect(progress.totalItems == 2)
        #expect(progress.completedItems == 1)
        #expect(progress.activeItems == 1)
        #expect(progress.bytesDownloaded == 1_500)
        #expect(progress.totalBytes == nil)
        #expect(progress.overallFraction == 0.625)
        #expect(
            BatchProgressAggregator.state(
                items: items,
                explicitState: nil
            ) == .running
        )
    }

    @Test
    func restorationReattachesMembershipWithoutDuplicatingChildren() {
        let analysis = fixtureAnalysis
        let entries = analysis.entries
        let batchID = UUID()
        var batch = DownloadBatch(
            id: batchID,
            analysis: analysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .playlistSubfolder,
            continueOnError: true,
            skipArchivedItems: true,
            numberFilenames: true,
            filenameIndexWidth: 2,
            entries: entries
        )
        batch.state = .running
        let restoredJob = fixtureJob(
            membership: membership(
                batchID: batchID,
                item: batch.items[0],
                itemCount: batch.items.count
            ),
            state: .completed
        )
        batch.items[0].jobID = nil
        batch.items[0].state = .running
        batch.items[1].jobID = UUID()
        batch.items[1].state = .running
        let archived = DownloadArchiveEntry.youtube(
            videoID: try! #require(batch.items[2].videoID),
            completedAt: Date(timeIntervalSince1970: 50)
        )

        let result = BatchRestoration.reconcile(
            batches: [batch],
            jobs: [restoredJob],
            archive: [archived],
            now: Date(timeIntervalSince1970: 100)
        )
        let restored = try! #require(result.batches.first)

        #expect(restored.items[0].jobID == restoredJob.id)
        #expect(restored.items[0].state == .completed)
        #expect(restored.items[1].state == .needsAttention)
        #expect(restored.items[2].state == .archivedSkipped)
        #expect(!result.resumableBatchIDs.contains(batchID))
        #expect(
            result.archive.contains {
                $0.videoID == restoredJob.videoID
            }
        )
    }

    @Test
    func controllerExpandsItemsOnceAndArchivesVerifiedCompletion()
        async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .playlistSubfolder,
            skipArchivedItems: true
        )
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }
        let originalJobs = await harness.enqueuedJobs

        var completed = originalJobs[0]
        completed.state = .completed
        completed.stage = .complete
        completed.progress.overallFraction = 1
        completed.outputURL = FileManager.default.temporaryDirectory
            .appending(path: "completed.mp4")
        await controller.receive(completed)

        let current = try #require(
            await controller.currentBatches().first {
                $0.id == batch.id
            }
        )
        let archive = await controller.currentArchive()

        #expect(current.items[0].state == .completed)
        #expect(current.progress.completedItems == 1)
        #expect(archive.map(\.videoID).contains(completed.videoID))
        #expect(Set(originalJobs.map(\.id)).count == 3)
        #expect(
            originalJobs.allSatisfy {
                $0.batchMembership?.batchID == batch.id
            }
        )
    }

    @Test
    func duplicateSkippedChildDoesNotEnterDownloadArchive()
        async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .selectedFolder,
            skipArchivedItems: true
        )
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }
        var skipped = try #require(await harness.enqueuedJobs.first)
        skipped.state = .completed
        skipped.stage = .complete
        skipped.exportOutcome = .duplicateSkipped
        await controller.receive(skipped)

        let current = try #require(
            await controller.currentBatches().first {
                $0.id == batch.id
            }
        )
        let item = try #require(
            current.items.first { $0.jobID == skipped.id }
        )
        let archive = await controller.currentArchive()

        #expect(item.state == .skipped)
        #expect(!archive.contains { $0.videoID == skipped.videoID })
    }

    @Test
    func stopOnErrorCancelsExpansionBeforeAnotherChildIsEnqueued()
        async throws {
        let harness = BatchControllerHarness(slowAfterFirstLoad: true)
        let controller = makeController(harness: harness)
        var configuration = DownloadConfiguration.standard
        configuration.continuePlaylistOnError = false
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: configuration,
            destinationStructure: .selectedFolder,
            skipArchivedItems: false
        )
        try await waitUntil {
            let counts = await harness.counts()
            return counts.loads >= 2 && counts.enqueued == 1
        }
        var failed = try #require(await harness.enqueuedJobs.first)
        failed.state = .failed
        failed.errorCode = "fixture_failure"
        failed.errorMessage = "Fixture failure"

        await controller.receive(failed)
        try await Task.sleep(for: .milliseconds(100))
        let current = try #require(
            await controller.currentBatches().first {
                $0.id == batch.id
            }
        )

        #expect(current.state == .failed)
        #expect(await harness.enqueuedJobs.count == 1)
        #expect(
            current.items.dropFirst().allSatisfy {
                $0.state == .cancelled
            }
        )
    }

    @Test
    func retryFailedRecreatesOnlyTheItemThatNeverGotAJob()
        async throws {
        let secondID = try #require(fixtureAnalysis.entries[1].videoID)
        let harness = BatchControllerHarness(
            initiallyFailingVideoIDs: [secondID]
        )
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .selectedFolder,
            skipArchivedItems: false
        )
        try await waitUntil {
            let current = await controller.currentBatches()
                .first { $0.id == batch.id }
            return current?.items.allSatisfy {
                $0.state != .pendingAnalysis && $0.state != .analyzing
            } == true
        }
        #expect(await harness.enqueuedJobs.count == 2)
        await harness.allow(videoID: secondID)

        await controller.retryFailed(batch.id)
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }
        let jobs = await harness.enqueuedJobs

        #expect(jobs.map(\.videoID).filter { $0 == secondID }.count == 1)
        #expect(Set(jobs.map(\.videoID)).count == 3)
        #expect(await harness.retriedJobIDs.isEmpty)
    }

    @Test
    func retryAfterStopOnErrorRestartsEveryStoppedItem() async throws {
        let firstID = try #require(fixtureAnalysis.entries[0].videoID)
        let harness = BatchControllerHarness(
            initiallyFailingVideoIDs: [firstID]
        )
        let controller = makeController(harness: harness)
        var configuration = DownloadConfiguration.standard
        configuration.continuePlaylistOnError = false
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: configuration,
            destinationStructure: .selectedFolder,
            skipArchivedItems: false
        )
        try await waitUntil {
            await controller.currentBatches()
                .first { $0.id == batch.id }?.state == .failed
        }
        let stopped = try #require(
            await controller.currentBatches().first {
                $0.id == batch.id
            }
        )
        #expect(
            stopped.items.dropFirst().allSatisfy {
                $0.state == .cancelled
                    && $0.errorCode == "stopped_after_failure"
            }
        )

        await harness.allow(videoID: firstID)
        await controller.retryFailed(batch.id)
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }

        #expect(Set(await harness.enqueuedJobs.map(\.videoID)).count == 3)
    }

    @Test
    func dismissCompletedItemsPreservesBatchSummaryAndReturnsChildIDs()
        async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .selectedFolder,
            skipArchivedItems: false
        )
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }
        var completed = try #require(await harness.enqueuedJobs.first)
        completed.state = .completed
        completed.stage = .complete
        completed.progress.overallFraction = 1
        await controller.receive(completed)

        let removed = await controller.dismissCompletedItems(batch.id)
        let current = try #require(
            await controller.currentBatches().first {
                $0.id == batch.id
            }
        )
        let item = try #require(
            current.items.first { $0.id == completed.playlistItemID }
        )

        #expect(removed == [completed.id])
        #expect(item.state == .completed)
        #expect(item.jobID == nil)
        #expect(item.isDismissedFromQueue == true)
        #expect(current.progress.completedItems == 1)
    }

    @Test
    func pauseResumeAndCancelUseChildCommandsWithoutFakeProcessingPause()
        async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .selectedFolder,
            skipArchivedItems: false
        )
        try await waitUntil {
            await harness.enqueuedJobs.count == 3
        }
        let jobs = await harness.enqueuedJobs

        await controller.pause(batch.id)
        #expect(Set(await harness.pausedJobIDs) == Set(jobs.map(\.id)))
        #expect(
            await controller.currentBatches()
                .first { $0.id == batch.id }?.state == .paused
        )

        for var job in jobs {
            job.state = .paused
            await controller.receive(job)
        }
        await controller.resume(batch.id)
        #expect(Set(await harness.resumedJobIDs) == Set(jobs.map(\.id)))

        await controller.cancel(batch.id)
        #expect(Set(await harness.cancelledJobIDs) == Set(jobs.map(\.id)))
        #expect(
            await controller.currentBatches()
                .first { $0.id == batch.id }?.state == .cancelled
        )
    }

    @Test func deletingAFailedPlaylistRowKeepsItsOutcomeAndExcludesItFromRetryAll() async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(analysis: fixtureAnalysis, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .selectedFolder, skipArchivedItems: false)
        try await waitUntil { await harness.enqueuedJobs.count == 3 }
        var failed = try #require(await harness.enqueuedJobs.first)
        failed.state = .failed
        await controller.receive(failed)
        let itemID = try #require(failed.playlistItemID)
        let removed = await controller.dismissTerminalItems(batch.id, itemIDs: [itemID])
        #expect(removed == [failed.id])
        await controller.retryFailed(batch.id)
        let current = try #require(await controller.currentBatches().first { $0.id == batch.id })
        let item = try #require(current.items.first { $0.id == itemID })
        #expect(item.state == .failed && item.isDismissedFromQueue == true && item.jobID == nil)
        #expect(await harness.enqueuedJobs.count == 3)
    }

    @Test
    func individualChildRetryReactivatesParentAndSurvivesRestoration() async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(analysis: fixtureAnalysis, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .selectedFolder, skipArchivedItems: false)
        try await waitUntil { await harness.enqueuedJobs.count == 3 }
        let children = await harness.enqueuedJobs
        await controller.cancel(batch.id)
        let stopped = try #require(await controller.currentBatches().first { $0.id == batch.id })
        await controller.receive(children[0]) // An old queued snapshot is not a retry.
        #expect(await controller.currentBatches().first?.state == .cancelled)
        var retried = children[0]
        retried.retryRequestID = UUID()
        retried.state = .queued
        retried.updatedAt = .now
        await controller.receive(retried)
        let active = try #require(await controller.currentBatches().first { $0.id == batch.id })
        #expect(!active.state.isTerminal)
        #expect(await controller.remove(batch.id).isEmpty)
        let restoredStopped = BatchRestoration.reconcile(batches: [stopped], jobs: [retried], archive: [])
        #expect(restoredStopped.batches.first?.state.isTerminal == false)
        let restored = BatchRestoration.reconcile(batches: [active], jobs: [retried], archive: [])
        #expect(restored.batches.first?.state.isTerminal == false)
        retried.state = .completed; retried.updatedAt = .now
        await controller.receive(retried)
        #expect(await controller.currentBatches().first?.state == .completedWithFailures)
        #expect(await harness.enqueuedJobs.count == 3)
    }

    @Test
    func pausedAdmissionSurvivesRestoreWithUnpausableChildAndSkippedSiblings() throws {
        let batchID = UUID()
        var batch = DownloadBatch(id: batchID, analysis: fixtureAnalysis, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .selectedFolder, continueOnError: true,
            skipArchivedItems: true, numberFilenames: false, filenameIndexWidth: 2, entries: fixtureAnalysis.entries)
        var child = fixtureJob(membership: membership(batchID: batchID, item: batch.items[0], itemCount: 3), state: .running)
        child.stage = .converting
        batch.items[0].jobID = child.id
        batch.items[0].state = .running
        batch.items[1].state = .skipped
        batch.items[2].state = .archivedSkipped
        batch.admissionPaused = true
        batch.state = .running
        let result = BatchRestoration.reconcile(batches: [batch], jobs: [child], archive: [])
        #expect(result.batches.first?.state == .running)
        #expect(result.batches.first?.admissionPaused == true)
        #expect(result.batches.first?.items[1].state == .skipped)
        #expect(result.batches.first?.items[2].state == .archivedSkipped)
        #expect(result.resumableBatchIDs.isEmpty)
        let data = try JSONEncoder.illucetEncoder.encode(result.batches)
        #expect(try JSONDecoder.illucetDecoder.decode([DownloadBatch].self, from: data).first?.admissionPaused == true)
    }

    @Test
    func finishingUnpausableChildrenCompletesAnAdmissionPausedBatch() async throws {
        let harness = BatchControllerHarness()
        let controller = makeController(harness: harness)
        let batch = try await controller.createBatch(analysis: fixtureAnalysis, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .selectedFolder, skipArchivedItems: false)
        try await waitUntil { await harness.enqueuedJobs.count == 3 }
        var children = await harness.enqueuedJobs
        for index in children.indices {
            children[index].state = .running
            children[index].stage = .converting
            children[index].updatedAt = .now
            await controller.receive(children[index])
        }
        await controller.pause(batch.id)
        #expect(await controller.currentBatches().first?.state == .running)
        for index in children.indices {
            children[index].state = .completed
            children[index].updatedAt = .now
            await controller.receive(children[index])
        }
        let finished = try #require(await controller.currentBatches().first)
        #expect(finished.state == .completed)
        #expect(finished.admissionPaused != true)
        var oldSnapshot = finished
        oldSnapshot.state = .running
        oldSnapshot.admissionPaused = true
        let restored = BatchRestoration.reconcile(batches: [oldSnapshot], jobs: children, archive: [])
        #expect(restored.batches.first?.state == .completed)
        #expect(restored.batches.first?.admissionPaused != true)
    }

    @Test
    func schemaSevenDecodesWithoutNewAdmissionAndRetryFields() throws {
        let batch = DownloadBatch(analysis: fixtureAnalysis, selection: .entirePlaylist,
            configuration: .standard, destinationStructure: .selectedFolder, continueOnError: true,
            skipArchivedItems: true, numberFilenames: false, filenameIndexWidth: 2, entries: fixtureAnalysis.entries)
        let child = fixtureJob(membership: membership(batchID: batch.id, item: batch.items[0], itemCount: 3), state: .paused)
        var snapshot = IllucetSnapshot.empty
        snapshot.schemaVersion = 7
        snapshot.jobs = [child]
        snapshot.batches = [batch]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.illucetEncoder.encode(snapshot)) as? [String: Any])
        var jobs = try #require(object["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "retryRequestID")
        var batches = try #require(object["batches"] as? [[String: Any]])
        batches[0].removeValue(forKey: "admissionPaused")
        batches[0].removeValue(forKey: "stoppedRetryRequests")
        object["jobs"] = jobs
        object["batches"] = batches
        let decoded = try JSONDecoder.illucetDecoder.decode(IllucetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.schemaVersion == 7)
        #expect(decoded.jobs.first?.state == .paused)
        #expect(decoded.jobs.first?.retryRequestID == nil)
        #expect(decoded.batches.first?.admissionPaused == nil)
        #expect(decoded.batches.first?.stoppedRetryRequests == nil)
    }

    @Test
    func relativeBatchDirectoryIsCreatedAndTraversalIsRejected()
        async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part6-Export-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.mp4")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: source)
        let exporter = ExportManager(documentsRootURL: root)

        let result = try await exporter.export(
            sourceURL: source,
            destination: .appDocuments,
            filename: "Item 1",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "Batch00001_",
            jobID: UUID(),
            title: "Item 1",
            assetKind: .video,
            relativeDirectory: "Fixture Playlist"
        )

        #expect(
            result.fileURL?.deletingLastPathComponent().lastPathComponent
                == "Fixture Playlist"
        )
        await #expect(throws: IllucetError.self) {
            try await exporter.export(
                sourceURL: source,
                destination: .appDocuments,
                filename: "Unsafe",
                folderBookmark: nil,
                duplicateHandling: .addNumber,
                videoID: "Batch00001_",
                jobID: UUID(),
                title: "Unsafe",
                assetKind: .video,
                relativeDirectory: "../Escape"
            )
        }
    }

    private func makeController(
        harness: BatchControllerHarness
    ) -> DownloadBatchController {
        let factory = PlaylistChildJobFactory(
            loadMetadata: { URL in
                try await harness.load(URL)
            },
            enqueue: { metadata, configuration, version, membership in
                await harness.enqueue(
                    metadata: metadata,
                    configuration: configuration,
                    version: version,
                    membership: membership
                )
            }
        )
        return DownloadBatchController(
            childFactory: factory,
            commands: DownloadBatchJobCommands(
                pause: { await harness.pause($0) },
                resume: { await harness.resume($0) },
                cancel: { await harness.cancel($0) },
                retry: { await harness.retry($0) }
            ),
            extractorVersion: { "fixture" }
        )
    }

    private var fixtureAnalysis: PlaylistAnalysis {
        PlaylistAnalysis(
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/playlist?list=PLBatchFixture"
            )!,
            playlistID: "PLBatchFixture",
            kind: .playlist,
            referencedVideoID: nil,
            title: "Fixture Playlist",
            creator: "Fixture Creator",
            thumbnailURL: nil,
            reportedItemCount: 3,
            estimatedTotalBytes: 6_000,
            entries: (1 ... 3).map(fixtureEntry),
            isTruncated: false
        )
    }

    private func fixtureEntry(index: Int) -> PlaylistEntry {
        let videoID = String(format: "Batch%05d_", index)
        return PlaylistEntry(
            index: index,
            videoID: videoID,
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/watch?v=\(videoID)"
            ),
            title: "Item \(index)",
            creator: "Fixture Creator",
            durationSeconds: Double(index * 10),
            thumbnailURL: nil,
            estimatedBytes: Int64(index * 1_000),
            availability: .available
        )
    }

    private func fixtureItem(index: Int) -> DownloadBatchItem {
        DownloadBatchItem(entry: fixtureEntry(index: index))
    }

    private func membership(
        batchID: UUID,
        item: DownloadBatchItem,
        itemCount: Int
    ) -> BatchJobMembership {
        BatchJobMembership(
            batchID: batchID,
            playlistID: "PLBatchFixture",
            entryID: item.id,
            playlistTitle: "Fixture Playlist",
            playlistIndex: item.playlistIndex,
            playlistItemCount: itemCount,
            filenameIndexWidth: 2,
            relativeOutputDirectory: "Fixture Playlist"
        )
    }

    private func fixtureJob(
        membership: BatchJobMembership,
        state: DownloadJobState,
        bytes: Int64 = 0,
        total: Int64? = nil,
        fraction: Double? = 0
    ) -> DownloadJob {
        var progress = JobProgress.zero
        progress.bytesDownloaded = bytes
        progress.totalBytes = total
        progress.overallFraction = fraction
        var job = DownloadJob(
            id: UUID(),
            sourceURL: URL(
                string:
                    "https://www.youtube.com/watch?"
                    + "v=Batch\(String(format: "%05d", membership.playlistIndex))_"
            )!,
            videoID: "Batch\(String(format: "%05d", membership.playlistIndex))_",
            title: "Item \(membership.playlistIndex)",
            channel: "Fixture Creator",
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: .standard,
            state: state,
            stage: state == .completed ? .complete : .waiting,
            progress: progress,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
        job.batchMembership = membership
        job.playlistItemID = membership.entryID
        return job
    }
}

private actor BatchControllerHarness {
    private let slowAfterFirstLoad: Bool
    private var failingVideoIDs: Set<String>
    private(set) var loadCount = 0
    private(set) var enqueuedJobs: [DownloadJob] = []
    private(set) var pausedJobIDs: [UUID] = []
    private(set) var resumedJobIDs: [UUID] = []
    private(set) var cancelledJobIDs: [UUID] = []
    private(set) var retriedJobIDs: [UUID] = []

    init(
        slowAfterFirstLoad: Bool = false,
        initiallyFailingVideoIDs: Set<String> = []
    ) {
        self.slowAfterFirstLoad = slowAfterFirstLoad
        failingVideoIDs = initiallyFailingVideoIDs
    }

    func load(_ URL: URL) async throws -> MediaMetadata {
        loadCount += 1
        if slowAfterFirstLoad && loadCount > 1 {
            try await Task.sleep(for: .seconds(60))
        }
        let videoID = try #require(
            LiveExtractionValidator.youtubeVideoID(from: URL)
        )
        if failingVideoIDs.contains(videoID) {
            throw BatchHarnessError.fixtureFailure
        }
        return MediaMetadata(
            canonicalURL: URL,
            videoID: videoID,
            title: "Analyzed \(videoID)",
            channel: "Fixture Creator",
            uploader: "Fixture Creator",
            durationSeconds: 10,
            uploadDate: "2026-07-28",
            description: nil,
            isLive: false,
            liveStatus: "not_live",
            thumbnails: [],
            chapters: [],
            subtitles: [],
            formats: []
        )
    }

    func enqueue(
        metadata: MediaMetadata,
        configuration: DownloadConfiguration,
        version: String?,
        membership: BatchJobMembership
    ) -> DownloadJob {
        var job = DownloadJob(
            id: UUID(),
            sourceURL: metadata.canonicalURL,
            videoID: metadata.videoID,
            title: metadata.title,
            channel: metadata.channel,
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .queued,
            stage: .waiting,
            progress: .zero,
            priority: enqueuedJobs.count,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: version
        )
        job.batchMembership = membership
        job.playlistItemID = membership.entryID
        enqueuedJobs.append(job)
        return job
    }

    func allow(videoID: String) {
        failingVideoIDs.remove(videoID)
    }

    func counts() -> (loads: Int, enqueued: Int) {
        (loadCount, enqueuedJobs.count)
    }

    func pause(_ jobID: UUID) {
        pausedJobIDs.append(jobID)
    }

    func resume(_ jobID: UUID) {
        resumedJobIDs.append(jobID)
    }

    func cancel(_ jobID: UUID) {
        cancelledJobIDs.append(jobID)
    }

    func retry(_ jobID: UUID) {
        retriedJobIDs.append(jobID)
    }
}

private enum BatchHarnessError: Error {
    case fixtureFailure
    case timeout
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for an asynchronous batch condition.")
    throw BatchHarnessError.timeout
}
