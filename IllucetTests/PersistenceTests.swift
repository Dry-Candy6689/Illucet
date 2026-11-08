import Foundation
import Testing
@testable import Illucet

struct PersistenceTests {
    @Test(arguments: [false, true])
    func legacyAutomaticInstallPreferenceSurvivesSnapshotRoundTrip(value: Bool) throws {
        var snapshot = IllucetSnapshot.empty
        snapshot.settings.automaticUpdateInstallation = value
        let data = try JSONEncoder.illucetEncoder.encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(object["settings"] as? [String: Any])
        #expect(settings["automaticUpdateInstallation"] as? Bool == value)
        let restored = try JSONDecoder.illucetDecoder.decode(IllucetSnapshot.self, from: data)
        #expect(restored.settings == snapshot.settings)
        #expect(restored.schemaVersion == snapshot.schemaVersion)
    }

    @Test
    func selectionModesResolveExplicitItemsInPlaylistOrder() throws {
        let analysis = fixtureAnalysis

        #expect(
            try PlaylistSelection.referencedVideo.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.videoID) == ["Video00002"]
        )
        #expect(
            try PlaylistSelection.entirePlaylist.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.videoID) == [
                "Video00001",
                "Video00002",
                "Video00004",
            ]
        )

        let selected = PlaylistSelection(
            mode: .selected,
            selectedEntryIDs: [
                analysis.entries[3].id,
                analysis.entries[0].id,
            ],
            rangeStart: nil,
            rangeEnd: nil,
            count: nil
        )
        #expect(
            try selected.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.index) == [1, 4]
        )

        let range = PlaylistSelection(
            mode: .range,
            selectedEntryIDs: [],
            rangeStart: 2,
            rangeEnd: 4,
            count: nil
        )
        #expect(
            try range.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.index) == [2, 4]
        )

        let first = PlaylistSelection(
            mode: .first,
            selectedEntryIDs: [],
            rangeStart: nil,
            rangeEnd: nil,
            count: 2
        )
        let last = PlaylistSelection(
            mode: .last,
            selectedEntryIDs: [],
            rangeStart: nil,
            rangeEnd: nil,
            count: 2
        )
        #expect(
            try first.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.index) == [1, 2]
        )
        #expect(
            try last.resolvedEntries(
                in: analysis,
                maximumItems: 20
            ).map(\.index) == [2, 4]
        )
    }

    @Test
    func selectionNeverSilentlyTruncatesOrIncludesUnavailableItems() {
        #expect(throws: PlaylistModelError.itemLimitExceeded(
            selected: 3,
            maximum: 2
        )) {
            try PlaylistSelection.entirePlaylist.resolvedEntries(
                in: fixtureAnalysis,
                maximumItems: 2
            )
        }

        let unavailable = PlaylistSelection(
            mode: .selected,
            selectedEntryIDs: [fixtureAnalysis.entries[2].id],
            rangeStart: nil,
            rangeEnd: nil,
            count: nil
        )
        #expect(throws: PlaylistModelError.selectedItemUnavailable) {
            try unavailable.resolvedEntries(
                in: fixtureAnalysis,
                maximumItems: 20
            )
        }
    }

    @Test
    func schemaThreeSnapshotDefaultsNewCollectionsToEmpty() throws {
        let encoded = try JSONEncoder.illucetEncoder.encode(IllucetSnapshot.empty)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "batches")
        object.removeValue(forKey: "downloadArchive")
        object["schemaVersion"] = 3
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: legacy
        )

        #expect(decoded.schemaVersion == 3)
        #expect(decoded.batches.isEmpty)
        #expect(decoded.downloadArchive.isEmpty)
    }

    @Test
    func schemaFiveSnapshotDefaultsExplicitFilesFolderAliasState() throws {
        let bookmark = Data("legacy-files-folder-bookmark".utf8)
        var snapshot = IllucetSnapshot.empty
        snapshot.schemaVersion = 5
        snapshot.filesFolderBookmark = bookmark
        snapshot.filesFolderSelectionIdentity = "/provider/Documents"
        snapshot.filesFolderDisplayName = "VLC"
        snapshot.filesFolderAlias = "Personal alias"
        snapshot.filesFolderAliasOfferShown = true
        let encoded = try JSONEncoder.illucetEncoder.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "filesFolderAlias")
        object.removeValue(forKey: "filesFolderAliasOfferShown")
        object.removeValue(forKey: "filesFolderSelectionIdentity")
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder.illucetDecoder.decode(
            IllucetSnapshot.self,
            from: legacy
        )

        #expect(decoded.schemaVersion == 5)
        #expect(decoded.filesFolderBookmark == bookmark)
        #expect(decoded.filesFolderSelectionIdentity == nil)
        #expect(decoded.filesFolderDisplayName == "VLC")
        #expect(decoded.filesFolderAlias == nil)
        #expect(!decoded.filesFolderAliasOfferShown)
    }

    @Test
    func schemaSixFilesFolderAliasRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part6-Files-Folder-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = Data("files-folder-bookmark".utf8)
        var snapshot = IllucetSnapshot.empty
        snapshot.filesFolderBookmark = bookmark
        snapshot.filesFolderSelectionIdentity = "/provider/Documents"
        snapshot.filesFolderDisplayName = "Documents"
        snapshot.filesFolderAlias = "VLC"
        snapshot.filesFolderAliasOfferShown = true

        try await IllucetPersistence(rootURL: root).save(snapshot)
        let restored = try await IllucetPersistence(rootURL: root).load()

        #expect(restored.schemaVersion == IllucetSnapshot.currentSchemaVersion)
        #expect(restored.filesFolderBookmark == bookmark)
        #expect(
            restored.filesFolderSelectionIdentity == "/provider/Documents"
        )
        #expect(restored.filesFolderDisplayName == "Documents")
        #expect(restored.filesFolderAlias == "VLC")
        #expect(restored.filesFolderAliasOfferShown)
    }

    @Test
    func unreadableStateBlocksSavingUntilASuccessfulReload() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let stateURL = await persistence.persistedStateURL
        // A directory produces a deterministic read failure without relying on
        // device lock state or filesystem permission behavior in the test host.
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: true
        )

        await #expect(throws: PersistenceError.stateUnavailable) {
            try await persistence.load()
        }
        await #expect(throws: PersistenceError.stateUnavailable) {
            try await persistence.load()
        }
        await #expect(throws: PersistenceError.stateUnavailable) {
            try await persistence.save(.empty)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent) == [stateURL.lastPathComponent])

        try FileManager.default.removeItem(at: stateURL)
        var original = IllucetSnapshot.empty
        original.filesFolderAlias = "Preserved folder"
        original.jobs = [fixtureJob]
        try JSONEncoder.illucetEncoder.encode(original).write(to: stateURL)
        let restored = try await persistence.load()
        #expect(restored.jobs.first?.id == original.jobs.first?.id)
        #expect(restored.filesFolderAlias == "Preserved folder")
        try await persistence.save(restored)
    }

    @Test
    func failedQuarantineKeepsOriginalAndBlocksEverySave() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(
            rootURL: root,
            fileManager: QuarantineFailureFileManager()
        )
        let stateURL = await persistence.persistedStateURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let original = Data("{broken saved state".utf8)
        try original.write(to: stateURL)

        for _ in 0..<2 {
            await #expect(throws: PersistenceError.quarantineFailed) {
                try await persistence.load()
            }
            await #expect(throws: PersistenceError.quarantineFailed) {
                try await persistence.save(.empty)
            }
            #expect(try Data(contentsOf: stateURL) == original)
        }

        try await persistence.reset()
        try await persistence.save(.empty)
        #expect(try await persistence.load() == .empty)
    }

    @Test
    func corruptStateIsRecoverableOnlyAfterPreservingUniqueBackups()
        async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var backups: [URL] = []

        for index in 0..<2 {
            let persistence = IllucetPersistence(rootURL: root)
            let stateURL = await persistence.persistedStateURL
            let corrupt = Data("invalid state \(index)".utf8)
            try corrupt.write(to: stateURL)
            do {
                _ = try await persistence.load()
                Issue.record("Expected corrupt-state recovery.")
            } catch PersistenceError.corruptState(let backup) {
                #expect(try Data(contentsOf: backup) == corrupt)
                #expect(!FileManager.default.fileExists(atPath: stateURL.path))
                backups.append(backup)
            }
            #expect(try await persistence.load() == .empty)
            try await persistence.save(.empty)
        }

        #expect(Set(backups).count == 2)
        for (index, backup) in backups.enumerated() {
            #expect(try Data(contentsOf: backup) == Data(
                "invalid state \(index)".utf8
            ))
        }
    }

    @Test
    func newerSchemaIsPreservedBeforeDecodingItsChangedPayload() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let stateURL = await persistence.persistedStateURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let version = IllucetSnapshot.currentSchemaVersion + 1
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": version,
            "settings": "A payload this app cannot decode",
            "futureData": ["keep": "all unknown fields"],
        ])
        try original.write(to: stateURL)

        await #expect(throws: PersistenceError.unsupportedSchemaVersion(version)) {
            try await persistence.load()
        }
        await #expect(throws: PersistenceError.unsupportedSchemaVersion(version)) {
            try await persistence.save(.empty)
        }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent) == [stateURL.lastPathComponent])
    }

    @Test
    func saveCannotReplaceExistingStateBeforeLoad() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var original = IllucetSnapshot.empty
        original.filesFolderAlias = "Original"
        try await IllucetPersistence(rootURL: root).save(original)
        let persistence = IllucetPersistence(rootURL: root)

        for _ in 0..<2 {
            await #expect(throws: PersistenceError.stateNotLoaded) {
                try await persistence.save(.empty)
            }
        }
        #expect(try await persistence.load() == original)
        try await persistence.save(.empty)
        #expect(try await IllucetPersistence(rootURL: root).load() == .empty)
    }

    @Test
    func unsupportedSnapshotSaveDoesNotChangeDiskOrCache() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        try await persistence.save(.empty)
        var unsupported = IllucetSnapshot.empty
        unsupported.schemaVersion = IllucetSnapshot.currentSchemaVersion + 1

        await #expect(throws: PersistenceError.unsupportedSchemaVersion(
            unsupported.schemaVersion
        )) {
            try await persistence.save(unsupported)
        }
        #expect(try await persistence.load() == .empty)
        #expect(try await IllucetPersistence(rootURL: root).load() == .empty)
    }

    @Test
    func resetOfMissingStateAllowsANewSnapshot() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        try await persistence.reset()
        try await persistence.save(.empty)
        #expect(try await IllucetPersistence(rootURL: root).load() == .empty)
    }

    @Test
    func failedResetPreservesCachedStateAndAnyExistingWriteBlock() async throws {
        let root = persistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var original = IllucetSnapshot.empty
        original.filesFolderAlias = "Keep my data"
        try await IllucetPersistence(rootURL: root).save(original)
        let persistence = IllucetPersistence(
            rootURL: root,
            fileManager: ResetFailureFileManager()
        )
        #expect(try await persistence.load() == original)
        await #expect(throws: CocoaError(.fileWriteNoPermission)) {
            try await persistence.reset()
        }
        #expect(try await persistence.load() == original)
        #expect(try await IllucetPersistence(rootURL: root).load() == original)

        let stateURL = await persistence.persistedStateURL
        let future = IllucetSnapshot.currentSchemaVersion + 1
        let futureData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": future,
            "futureData": "Keep unknown fields too",
        ])
        try futureData.write(to: stateURL)
        let unsupported = IllucetPersistence(
            rootURL: root,
            fileManager: ResetFailureFileManager()
        )
        await #expect(throws: PersistenceError.unsupportedSchemaVersion(future)) {
            try await unsupported.load()
        }
        await #expect(throws: CocoaError(.fileWriteNoPermission)) {
            try await unsupported.reset()
        }
        await #expect(throws: PersistenceError.unsupportedSchemaVersion(future)) {
            try await unsupported.save(.empty)
        }
        #expect(try Data(contentsOf: stateURL) == futureData)
    }

    @Test
    func appModelProjectionPreservesSchemaAndFolderIdentity() {
        let bookmark = Data("projection-bookmark".utf8)
        var snapshot = IllucetSnapshot.empty
        snapshot.schemaVersion = 5
        snapshot.filesFolderBookmark = bookmark
        snapshot.filesFolderSelectionIdentity = "/provider/Documents"
        snapshot.filesFolderDisplayName = "Documents"
        snapshot.filesFolderAlias = "VLC"
        snapshot.filesFolderAliasOfferShown = true
        snapshot.jobs = [fixtureJob]
        snapshot.history = [HistoryRecord(job: fixtureJob)]

        var restored = IllucetAppPersistedState.restoring(snapshot)
        let normalizedConfiguration = OutputCapabilityMatrix.normalized(
            fixtureJob.configuration
        )
        #expect(restored.jobs.first?.configuration == normalizedConfiguration)
        #expect(
            restored.history.first?.configuration == normalizedConfiguration
        )
        restored.jobs = []
        restored.history = []

        let projected = restored.applying(to: snapshot)

        #expect(projected.schemaVersion == IllucetSnapshot.currentSchemaVersion)
        #expect(projected.jobs.isEmpty)
        #expect(projected.history.isEmpty)
        #expect(projected.filesFolderBookmark == bookmark)
        #expect(
            projected.filesFolderSelectionIdentity == "/provider/Documents"
        )
        #expect(projected.filesFolderDisplayName == "Documents")
        #expect(projected.filesFolderAlias == "VLC")
        #expect(projected.filesFolderAliasOfferShown)
    }

    @Test
    func batchArchiveAndChildMembershipRoundTripAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part6-Persistence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        let selected = try PlaylistSelection.entirePlaylist.resolvedEntries(
            in: fixtureAnalysis,
            maximumItems: 20
        )
        let batchID = UUID()
        let batch = DownloadBatch(
            id: batchID,
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .playlistSubfolder,
            continueOnError: true,
            skipArchivedItems: true,
            numberFilenames: true,
            filenameIndexWidth: 3,
            entries: selected,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let membership = BatchJobMembership(
            batchID: batchID,
            playlistID: fixtureAnalysis.playlistID,
            entryID: selected[0].id,
            playlistTitle: fixtureAnalysis.title,
            playlistIndex: selected[0].index,
            playlistItemCount: selected.count,
            filenameIndexWidth: 3,
            relativeOutputDirectory: "Fixture Playlist"
        )
        var job = fixtureJob
        job.batchMembership = membership
        job.playlistItemID = membership.entryID
        let archive = DownloadArchiveEntry.youtube(
            videoID: job.videoID,
            completedAt: Date(timeIntervalSince1970: 2_000),
            batchID: batchID
        )
        var snapshot = IllucetSnapshot.empty
        snapshot.jobs = [job]
        snapshot.batches = [batch]
        snapshot.downloadArchive = [archive]

        try await persistence.save(snapshot)
        let restored = try await IllucetPersistence(rootURL: root).load()

        #expect(restored.schemaVersion == IllucetSnapshot.currentSchemaVersion)
        #expect(restored.batches == [batch])
        #expect(restored.downloadArchive == [archive])
        #expect(restored.jobs.first?.batchMembership == membership)
        #expect(
            restored.jobs.first?.batchMembership?.formattedPlaylistIndex
                == "001"
        )
        #expect(HistoryRecord(job: job).batchMembership == membership)
    }

    @Test
    func archiveIdentityIsSiteAndVideoIDNotHistoryOrFileState() {
        let first = DownloadArchiveEntry.youtube(
            videoID: "Video00001",
            completedAt: Date(timeIntervalSince1970: 1),
            historyRecordID: UUID(),
            batchID: UUID()
        )
        let later = DownloadArchiveEntry.youtube(
            videoID: "Video00001",
            completedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(first.id == "youtube:Video00001")
        #expect(first.id == later.id)
        #expect(first != later)
    }

    private var fixtureAnalysis: PlaylistAnalysis {
        PlaylistAnalysis(
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/playlist?list=PLFixture123"
            )!,
            playlistID: "PLFixture123",
            kind: .playlist,
            referencedVideoID: "Video00002",
            title: "Fixture Playlist",
            creator: "Fixture Creator",
            thumbnailURL: URL(
                string:
                    "https://i.ytimg.com/vi/Video00001/hqdefault.jpg"
            ),
            reportedItemCount: 4,
            estimatedTotalBytes: 42_000,
            entries: [
                entry(index: 1, videoID: "Video00001"),
                entry(index: 2, videoID: "Video00002"),
                PlaylistEntry(
                    index: 3,
                    videoID: nil,
                    canonicalURL: nil,
                    title: "Deleted video",
                    creator: nil,
                    durationSeconds: nil,
                    thumbnailURL: nil,
                    estimatedBytes: nil,
                    availability: .deleted
                ),
                entry(index: 4, videoID: "Video00004"),
            ],
            isTruncated: false
        )
    }

    private func persistenceTestRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Persistence-Recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func entry(index: Int, videoID: String) -> PlaylistEntry {
        PlaylistEntry(
            index: index,
            videoID: videoID,
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/watch?v=\(videoID)"
            ),
            title: "Item \(index)",
            creator: "Fixture Creator",
            durationSeconds: Double(index * 10),
            thumbnailURL: URL(
                string:
                    "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
            ),
            estimatedBytes: Int64(index * 1_000),
            availability: .available
        )
    }

    private var fixtureJob: DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: URL(
                string:
                    "https://www.youtube.com/watch?v=Video00001"
            )!,
            videoID: "Video00001",
            title: "Item 1",
            channel: "Fixture Creator",
            thumbnailURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_500),
            updatedAt: Date(timeIntervalSince1970: 1_500),
            configuration: .standard,
            state: .queued,
            stage: .waiting,
            progress: .zero,
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
    }
}

private final class QuarantineFailureFileManager: FileManager,
    @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class ResetFailureFileManager: FileManager,
    @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
