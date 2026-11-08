import Foundation
import Testing
@testable import Illucet

struct ExportPublicationTests {
    @Test(arguments: [ShareCompletionState.completed, .cancelled, .failed])
    func callbackRecordedBeforeDismissalWins(state: ShareCompletionState) {
        let arbiter = ShareOutcomeArbiter()
        arbiter.recordUIKit(state, error: state == .failed ? "synthetic failure" : nil)
        #expect(arbiter.take(dismissing: true)?.state == state)
        #expect(arbiter.take() == nil)
        #expect(arbiter.take(dismissing: true) == nil)
        arbiter.recordUIKit(.cancelled, error: nil)
        #expect(arbiter.take() == nil)
    }

    @Test(arguments: [ShareCompletionState.completed, .cancelled, .failed])
    func dismissalBeforeCallbackIsUnconfirmedUntilUIKitAnswers(state: ShareCompletionState) {
        let arbiter = ShareOutcomeArbiter()
        #expect(arbiter.take(dismissing: true)?.state == .unconfirmed)
        #expect(arbiter.take(dismissing: true) == nil)
        arbiter.recordUIKit(state, error: nil)
        #expect(arbiter.take()?.state == state)
        #expect(arbiter.take() == nil)
    }

    @Test
    func photosReceivesRequestedFilenameWithActualExtension() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "D2-Naming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = PublicationNameRecorder()
        let exporter = ExportManager(photoLibrary: photo)
        for (ext, kind) in [("jpeg", ExportAssetKind.image), ("mp4", .video)] {
            let source = root.appending(path: "staging.\(ext)")
            try Data([1, 2, 3]).write(to: source)
            _ = try await exporter.export(sourceURL: source, destination: .photos, filename: "Requested name",
                folderBookmark: nil, duplicateHandling: .addNumber, videoID: "fixture", jobID: UUID(),
                title: "Fixture", assetKind: kind)
        }
        #expect(await photo.names == ["Requested name.jpeg", "Requested name.mp4"])
    }

    @Test
    func staleSnapshotCannotEraseAcknowledgedPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "D2-Stale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        _ = try await persistence.load()
        var old = IllucetSnapshot.empty
        var job = DeveloperFixtures.sponsorBlockAppliedJob
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .exporting)
        job.pipelineCheckpoint?.publicationRevision = 1
        old.jobs = [job]; old.history = [HistoryRecord(job: job)]
        try await persistence.save(old)
        job.pipelineCheckpoint?.publicationRevision = 2
        job.pipelineCheckpoint?.publicationReceipts = [.init(id: "photos.0", destination: .photos,
            state: .committed, photoIdentifiers: ["saved-asset"])]
        var latest = old
        latest.jobs = [job]; latest.history = [HistoryRecord(job: job)]
        try await persistence.save(latest)
        try await persistence.save(old)
        let restored = try await IllucetPersistence(rootURL: root).load()
        #expect(restored.jobs.first?.pipelineCheckpoint?.publicationRevision == 2)
        #expect(restored.history.first?.publicationReceipts?.first?.photoIdentifiers == ["saved-asset"])
        var removed = old; removed.jobs = []; removed.history = []
        try await persistence.save(removed)
        #expect(try await persistence.load().jobs.isEmpty)
    }

    @Test
    func olderQueuedSnapshotCannotRemoveANewPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "D2-Generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = IllucetPersistence(rootURL: root)
        _ = try await writer.load()
        var older = IllucetSnapshot.empty; older.writeRevision = 1
        try await writer.save(older)
        var newer = older; newer.writeRevision = 2
        newer.jobs = [DeveloperFixtures.sponsorBlockAppliedJob]
        try await writer.save(newer)
        try await writer.save(older)
        var future = older; future.schemaVersion = IllucetSnapshot.currentSchemaVersion + 1
        await #expect(throws: PersistenceError.self) { try await writer.save(future) }
        #expect(try await IllucetPersistence(rootURL: root).load().jobs.count == 1)
        var removed = newer; removed.writeRevision = 3; removed.jobs = []
        try await writer.save(removed)
        #expect(try await IllucetPersistence(rootURL: root).load().jobs.isEmpty)
    }

    @Test
    func preparedPlanRejectsChangedAndEscapedInputs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "D2-Identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "verified.mp4")
        try Data([1, 2, 3]).write(to: file)
        let plan = try ExportPublicationPlan(items: [.init(sourceURL: file, filename: "Output", role: .primary,
            assetKind: .video, handling: .addNumber)], probe: nil, destination: .appDocuments,
            folderBookmark: nil).prepared(jobID: UUID(), root: root)
        try plan.validate(root: root)
        let encoded = try JSONEncoder.illucetEncoder.encode(plan)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("https://"))
        try Data([3, 2, 1]).write(to: file)
        #expect(throws: ExportPublicationError.self) { try plan.validate(root: root) }
        #expect(throws: ExportPublicationError.self) { try plan.validate(root: root.appending(path: "other")) }
        let alias = root.appendingPathExtension("symlink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(throws: ExportPublicationError.self) { try plan.validate(root: alias) }
    }

    @Test
    func legacyCheckpointAndHistoryDecodeWithoutPublicationState() throws {
        let job = DeveloperFixtures.sponsorBlockAppliedJob
        let checkpoint = DownloadPipelineCheckpoint(phase: .sourcesReady)
        let decoded = try JSONDecoder.illucetDecoder.decode(DownloadPipelineCheckpoint.self,
            from: JSONEncoder.illucetEncoder.encode(checkpoint))
        #expect(decoded.publicationPlan == nil)
        #expect(decoded.publicationReceipts == nil)
        let history = try JSONDecoder.illucetDecoder.decode(HistoryRecord.self,
            from: JSONEncoder.illucetEncoder.encode(HistoryRecord(job: job)))
        #expect(history.publicationReceipts == nil)
    }
}

private actor PublicationNameRecorder: PhotoLibraryExporting {
    private(set) var names: [String] = []
    func saveAsset(at fileURL: URL, kind: ExportAssetKind) async throws -> String { "legacy" }
    func saveAsset(at fileURL: URL, kind: ExportAssetKind, originalFilename: String) async throws -> String {
        names.append(originalFilename)
        return "synthetic-asset"
    }
}
