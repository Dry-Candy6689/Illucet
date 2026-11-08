import Foundation
import Testing
@testable import Illucet

struct PlaylistSelectionAndArchiveTests {
    @Test
    func draftRequiresExplicitSelectionAndAppliesPerItemOverrides()
        throws {
        var configuration = DownloadConfiguration.standard
        configuration.maximumPlaylistItems = 10
        var draft = PlaylistBatchDraft(
            analysis: DeveloperFixtures.playlist,
            configuration: configuration
        )

        #expect(draft.selection.mode == .referencedVideo)
        #expect(draft.selectedEntries.map(\.videoID) == ["dQw4w9WgXcQ"])

        draft.selectAllLoadedEntries()
        #expect(draft.selectedEntries.count == 3)
        #expect(
            draft.selectedEntries.allSatisfy {
                $0.availability.isDownloadable
            }
        )

        let second = try #require(draft.selectedEntries.dropFirst().first)
        draft.setOverrideMode(.audioOnly, for: second.id)
        #expect(draft.itemOverrides[second.id]?.mode == .audioOnly)
        #expect(
            draft.itemOverrides[second.id]?.selectedFormatIDs.isEmpty
                == true
        )
        draft.setOverrideMode(nil, for: second.id)
        #expect(draft.itemOverrides[second.id] == nil)
    }

    @Test
    func selectionModesRespectLimitsAndTruncatedInventories() throws {
        var configuration = DownloadConfiguration.standard
        configuration.maximumPlaylistItems = 2
        var draft = PlaylistBatchDraft(
            analysis: DeveloperFixtures.playlist,
            configuration: configuration
        )
        draft.selectAllLoadedEntries()
        #expect(throws: PlaylistModelError.self) {
            try draft.resolvedEntries()
        }

        let truncated = PlaylistAnalysis(
            canonicalURL: DeveloperFixtures.playlist.canonicalURL,
            playlistID: DeveloperFixtures.playlist.playlistID,
            kind: DeveloperFixtures.playlist.kind,
            referencedVideoID: nil,
            title: DeveloperFixtures.playlist.title,
            creator: DeveloperFixtures.playlist.creator,
            thumbnailURL: DeveloperFixtures.playlist.thumbnailURL,
            reportedItemCount: 50,
            estimatedTotalBytes: nil,
            entries: Array(DeveloperFixtures.playlist.entries.prefix(3)),
            isTruncated: true
        )
        var truncatedDraft = PlaylistBatchDraft(
            analysis: truncated,
            configuration: .standard
        )
        truncatedDraft.selection = .entirePlaylist
        #expect(throws: PlaylistModelError.self) {
            try truncatedDraft.resolvedEntries()
        }
        truncatedDraft.selectAllLoadedEntries()
        #expect(try truncatedDraft.resolvedEntries().count == 3)
    }

    @Test
    func ZIPWriterStreamsMultipleFilesAndWritesVerifiedDirectory()
        async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let first = try fixture.file(
            named: "01 Alpha.mp4",
            data: Data("alpha".utf8)
        )
        let second = try fixture.file(
            named: "02 Café.mp3",
            data: Data("bravo-charlie".utf8)
        )
        let archive = fixture.root.appending(path: "Package.zip")
        let writer = ZIPArchiveWriter()

        let result = try await writer.write(
            sources: [
                ZIPArchiveSource(
                    archivePath: "01 Alpha.mp4",
                    fileURL: first
                ),
                ZIPArchiveSource(
                    archivePath: "02 Café.mp3",
                    fileURL: second
                ),
            ],
            to: archive
        )
        let bytes = try Data(contentsOf: archive)

        #expect(result.entryCount == 2)
        #expect(result.sourceBytes == 18)
        #expect(result.archiveBytes == UInt64(bytes.count))
        #expect(bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        #expect(bytes.range(of: Data("01 Alpha.mp4".utf8)) != nil)
        #expect(bytes.range(of: Data("02 Café.mp3".utf8)) != nil)
        #expect(Data(bytes.suffix(22).prefix(4))
            == Data([0x50, 0x4b, 0x05, 0x06]))
    }

    @Test
    func ZIPWriterRejectsTraversalAndDuplicatePaths() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let source = try fixture.file(
            named: "source.bin",
            data: Data([1, 2, 3])
        )
        let writer = ZIPArchiveWriter()

        await #expect(throws: ZIPArchiveWriterError.self) {
            try await writer.write(
                sources: [
                    ZIPArchiveSource(
                        archivePath: "../escape.bin",
                        fileURL: source
                    ),
                ],
                to: fixture.root.appending(path: "unsafe.zip")
            )
        }
        await #expect(throws: ZIPArchiveWriterError.self) {
            try await writer.write(
                sources: [
                    ZIPArchiveSource(
                        archivePath: "same.bin",
                        fileURL: source
                    ),
                    ZIPArchiveSource(
                        archivePath: "same.bin",
                        fileURL: source
                    ),
                ],
                to: fixture.root.appending(path: "duplicate.zip")
            )
        }
    }

    @Test
    func batchPackageIsCreatedOnlyFromCompletedChildOutputs()
        async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        let exportRoot = fixture.root.appending(
            path: "Exports",
            directoryHint: .isDirectory
        )
        let exporter = ExportManager(documentsRootURL: exportRoot)
        let service = BatchPackageService(
            exporter: exporter,
            temporaryRootURL: fixture.root.appending(
                path: "Working",
                directoryHint: .isDirectory
            )
        )
        var configuration = DownloadConfiguration.standard
        configuration.destination = .appDocuments
        var batch = DownloadBatch(
            analysis: DeveloperFixtures.playlist,
            selection: .entirePlaylist,
            configuration: configuration,
            destinationStructure: .zipArchive,
            continueOnError: true,
            skipArchivedItems: false,
            numberFilenames: true,
            filenameIndexWidth: 2,
            entries: Array(DeveloperFixtures.playlist.entries.prefix(2))
        )
        let firstURL = try fixture.file(
            named: "01 First.mp4",
            data: Data("first".utf8)
        )
        let secondURL = try fixture.file(
            named: "02 Second.mp4",
            data: Data("second".utf8)
        )
        let firstJob = fixtureJob(
            item: batch.items[0],
            batch: batch,
            outputURL: firstURL
        )
        let secondJob = fixtureJob(
            item: batch.items[1],
            batch: batch,
            outputURL: secondURL
        )
        batch.items[0].jobID = firstJob.id
        batch.items[0].state = .completed
        batch.items[1].jobID = secondJob.id
        batch.items[1].state = .completed

        await #expect(throws: BatchPackageServiceError.self) {
            try await service.createAndExport(
                batch: batch,
                jobs: [firstJob, secondJob],
                filesFolderBookmark: nil,
                duplicateHandling: .addNumber
            )
        }

        batch.state = .completed
        batch.progress = BatchProgressAggregator.progress(
            items: batch.items,
            jobsByID: [
                firstJob.id: firstJob,
                secondJob.id: secondJob,
            ]
        )
        let result = try await service.createAndExport(
            batch: batch,
            jobs: [firstJob, secondJob],
            filesFolderBookmark: nil,
            duplicateHandling: .addNumber
        )
        let packageURL = try #require(result.packageURL)
        let bytes = try Data(contentsOf: packageURL)

        #expect(result.entryCount == 2)
        #expect(result.outcome == .file)
        #expect(packageURL.pathExtension == "zip")
        #expect(bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        #expect(bytes.range(of: Data("01 First.mp4".utf8)) != nil)
        #expect(bytes.range(of: Data("02 Second.mp4".utf8)) != nil)
    }

    @Test
    func reorderingIndividualJobsPreservesBatchChildSlots() throws {
        var configuration = DownloadConfiguration.standard
        configuration.destination = .appDocuments
        let batch = DownloadBatch(
            analysis: DeveloperFixtures.playlist,
            selection: .referencedVideo,
            configuration: configuration,
            destinationStructure: .selectedFolder,
            continueOnError: true,
            skipArchivedItems: false,
            numberFilenames: true,
            filenameIndexWidth: 2,
            entries: [DeveloperFixtures.playlist.entries[0]]
        )
        let placeholder = FileManager.default.temporaryDirectory
            .appending(path: "ordering.mp4")
        var first = fixtureJob(
            item: batch.items[0],
            batch: batch,
            outputURL: placeholder
        )
        first.batchMembership = nil
        first.state = .queued
        var child = fixtureJob(
            item: batch.items[0],
            batch: batch,
            outputURL: placeholder
        )
        child.state = .queued
        var second = fixtureJob(
            item: batch.items[0],
            batch: batch,
            outputURL: placeholder
        )
        second.batchMembership = nil
        second.state = .queued
        var terminal = fixtureJob(
            item: batch.items[0],
            batch: batch,
            outputURL: placeholder
        )
        terminal.batchMembership = nil

        let reordered = try #require(
            BatchQueueOrdering.reorderUnbatchedJobs(
                in: [first, child, second, terminal],
                fromOffsets: IndexSet(integer: 0),
                toOffset: 2
            )
        )

        #expect(reordered == [second.id, child.id, first.id])
    }

    private func fixtureJob(
        item: DownloadBatchItem,
        batch: DownloadBatch,
        outputURL: URL
    ) -> DownloadJob {
        let membership = BatchJobMembership(
            batchID: batch.id,
            playlistID: batch.playlistID,
            entryID: item.id,
            playlistTitle: batch.title,
            playlistIndex: item.playlistIndex,
            playlistItemCount: batch.items.count,
            filenameIndexWidth: batch.filenameIndexWidth,
            relativeOutputDirectory: "\(batch.title) Package"
        )
        var progress = JobProgress.zero
        progress.overallFraction = 1
        var job = DownloadJob(
            id: UUID(),
            sourceURL: item.sourceURL ?? DeveloperFixtures.RickURL,
            videoID: item.videoID ?? "Unknown0000_",
            title: item.title,
            channel: "Fixture",
            thumbnailURL: item.thumbnailURL,
            createdAt: .now,
            updatedAt: .now,
            configuration: batch.configuration,
            state: .completed,
            stage: .complete,
            progress: progress,
            priority: item.playlistIndex,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: outputURL,
            outputProbe: nil,
            selectedFormatIDs: ["fixture"],
            extractorVersion: "fixture"
        )
        job.batchMembership = membership
        return job
    }
}

private struct PackageFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part6-Package-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func file(named name: String, data: Data) throws -> URL {
        let URL = root.appending(path: name)
        try data.write(to: URL, options: .atomic)
        return URL
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
