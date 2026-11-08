import Foundation
import Testing
@testable import Illucet

struct SavedOutputAccessTests {
    @Test(arguments: ["/var/mobile", "/private/var/mobile", "/Users/test/Library/Developer/CoreSimulator/Devices/81314000-0000-0000-0000-000000000001/data"])
    func legacyContainerRelocationPreservesTheWholeRelativePath(prefix: String) throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let relative = "Application/Chapter 1/saved.jpg"
        let target = try fixture.write(relative, under: fixture.downloads)
        let old = URL(fileURLWithPath: prefix + "/Containers/Data/Application/\(UUID())/Documents/Downloads/" + relative)
        let record = fixture.record(old)
        let session = fixture.resolver().open(record)
        #expect(session.urls[old] == target)
        #expect(try session.read(old) { try Data(contentsOf: $0) } == Data([1, 2, 3]))
        let removed = HistoryFileRemoval.remove(records: [record], resolver: fixture.resolver())
        #expect(removed.removedRecordIDs == [record.id])
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func relativeReferencesSurviveAnotherRelocationAndOldSnapshotsMigrate() throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let original = try fixture.write("nested/saved.jpg", under: fixture.downloads)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.configuration.destination = .appDocuments; job.state = .completed; job.outputURL = original
        job.outputReferences = fixture.resolver().references(for: [original])
        let record = HistoryRecord(job: job)
        let encoded = try JSONEncoder.illucetEncoder.encode(record)
        let restored = try JSONDecoder.illucetDecoder.decode(HistoryRecord.self, from: encoded)
        let nextDocuments = fixture.root.appending(path: "NewContainer/Documents")
        let relocated = try fixture.write("Downloads/nested/saved.jpg", under: nextDocuments)
        let resolver = SavedOutputResolver(documentsURL: nextDocuments, temporaryURL: fixture.temporary)
        #expect(resolver.open(restored).urls[original] == relocated)
        try FileManager.default.removeItem(at: relocated)
        let missing = resolver.open(restored)
        #expect(missing.urls[original] == nil)
        #expect(missing.failures[original] == .missing)
        #expect(FileManager.default.fileExists(atPath: original.path))
        var snapshot = IllucetSnapshot.empty
        snapshot.schemaVersion = 9
        job.outputReferences = nil
        snapshot.jobs = [job]; snapshot.history = [HistoryRecord(job: job)]
        let decoded = try JSONDecoder.illucetDecoder.decode(IllucetSnapshot.self, from: JSONEncoder.illucetEncoder.encode(snapshot))
        let migrated = IllucetAppPersistedState.restoring(decoded, resolver: fixture.resolver())
        #expect(migrated.jobs[0].outputReferences?.files.first?.location == .downloads("nested/saved.jpg"))
        #expect(migrated.history[0].outputReferences == migrated.jobs[0].outputReferences)
        #expect(migrated.history[0].id == snapshot.history[0].id)
        #expect(migrated.history[0].configuration == OutputCapabilityMatrix.normalized(snapshot.history[0].configuration))
        #expect(migrated.applying(to: decoded).schemaVersion == 10)
    }

    @Test
    func unrelatedPathsTraversalAndEverySymlinkAreRejected() throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let keep = try fixture.write("keep.jpg", under: fixture.external)
        _ = try fixture.write("keep.jpg", under: fixture.downloads)
        let fm = FileManager.default
        let link = fixture.downloads.appending(path: "link.jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: keep)
        let directoryLink = fixture.downloads.appending(path: "linked")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: fixture.external)
        for url in [keep, link, directoryLink.appending(path: "keep.jpg"),
                    URL(fileURLWithPath: "/tmp/CoreSimulator/Devices/\(UUID())/data/Containers/Data/Application/\(UUID())/Documents/Downloads/keep.jpg"),
                    URL(fileURLWithPath: "/unrelated/Containers/Data/Application/\(UUID())/Documents/Downloads/keep.jpg")] {
            let session = fixture.resolver().open(fixture.record(url))
            #expect(session.urls[url] == nil)
        }
        var forged = fixture.record(keep)
        forged.outputReferences = .init(files: [.init(recordedURL: keep, location: .downloads("../External/keep.jpg"))])
        #expect(fixture.resolver().open(forged).failures[keep] == .unavailable)
        let result = HistoryFileRemoval.remove(records: [fixture.record(link)], resolver: fixture.resolver())
        #expect(result.failedFileCount == 1)
        #expect(fm.fileExists(atPath: keep.path))
    }

    @Test
    func externalAuthorizationOutlivesEachReaderAndIgnoresANewDefaultFolder() throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let original = try fixture.write("nested/saved.jpg", under: fixture.external)
        let extra = try fixture.write("nested/saved.info.json", under: fixture.external)
        let spy = AccessScopeSpy()
        let resolver = fixture.resolver(spy: spy)
        var record = fixture.record(original, destination: .filesFolder)
        record.metadataSidecars = [.init(kind: .info, localURL: extra)]
        record.outputReferences = resolver.references(for: record.ownedFileURLs, folderBookmark: Data("original".utf8))
        var session: SavedOutputAccessSession? = resolver.open(record, fallbackBookmark: Data("other".utf8))
        #expect(session?.urls[original] == original)
        #expect(session?.urls[extra] == extra)
        #expect(throws: SavedOutputAccessFailure.authorizationRequired) {
            try session?.read(original) { _ -> Data in throw CocoaError(.fileReadNoPermission) }
        }
        #expect(spy.starts == 1 && spy.stops == 0)
        var player: SavedOutputAccessSession? = session
        var share: SavedOutputAccessSession? = session
        session = nil
        #expect(try player?.read(original) { try Data(contentsOf: $0) } == Data([1, 2, 3]))
        player = nil
        #expect(spy.stops == 0)
        #expect(try share?.read(extra) { try Data(contentsOf: $0) } == Data([1, 2, 3]))
        share = nil
        #expect(spy.stops == 1)
        let encoded = try JSONEncoder.illucetEncoder.encode(record)
        let restored = try JSONDecoder.illucetDecoder.decode(HistoryRecord.self, from: encoded)
        let result = HistoryFileRemoval.remove(records: [restored], folderBookmark: Data("other".utf8), resolver: resolver)
        #expect(result.removedRecordIDs == [record.id])
        #expect(spy.starts == 2 && spy.stops == 2)
    }

    @Test(arguments: ["denied", "stale", "invalid", "missing"])
    func unavailableExternalAccessIsActionableAndAlwaysBalanced(scenario: String) throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let original = try fixture.write("saved.jpg", under: fixture.external)
        let spy = AccessScopeSpy(grants: scenario != "denied")
        let resolver = fixture.resolver(spy: spy)
        var record = fixture.record(original, destination: .filesFolder)
        let key = ["stale", "invalid"].contains(scenario) ? scenario : "original"
        record.outputReferences = .init(files: [.init(recordedURL: original, location: .external("saved.jpg"))],
            folderBookmark: Data(key.utf8), folderURL: fixture.external)
        if scenario == "missing" { try FileManager.default.removeItem(at: original) }
        let session = resolver.open(record)
        #expect(session.urls[original] == nil)
        #expect(session.failures[original] == (scenario == "missing" ? .missing : .authorizationRequired))
        #expect(spy.stops == (scenario == "missing" ? 1 : 0))
        #expect(spy.starts == (["stale", "invalid"].contains(scenario) ? 0 : 1))
    }

    @Test
    func reauthorizationRequiresTheOriginalFolderAndRetainsRelativeIdentity() throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let original = try fixture.write("nested/saved.jpg", under: fixture.external)
        _ = try fixture.write("nested/saved.jpg", under: fixture.other)
        var record = fixture.record(original, destination: .filesFolder)
        let resolver = fixture.resolver()
        record.outputReferences = resolver.references(for: [original], folderBookmark: Data("stale".utf8))
        #expect(throws: SavedOutputAccessFailure.self) {
            try resolver.reauthorizedReferences(for: record, folderURL: fixture.other, bookmark: Data("other".utf8), previousBookmark: nil)
        }
        record.outputReferences = try resolver.reauthorizedReferences(for: record, folderURL: fixture.external,
            bookmark: Data("original".utf8), previousBookmark: nil)
        #expect(record.outputReferences?.files.first?.location == .external("nested/saved.jpg"))
        #expect(resolver.open(record).urls[original] == original)
    }

    @Test
    func publicationCapturesItsOwnBookmarkAndVarAliasesRetainIdentity() throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let output = try fixture.write("saved.jpg", under: fixture.external)
        let bookmark = try fixture.external.bookmarkData(options: .minimalBookmark)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.configuration.destination = .filesFolder
        job.pipelineCheckpoint = .init(phase: .exporting)
        job.pipelineCheckpoint?.publicationReceipts = [.init(id: "files", destination: .files, state: .committed, fileURLs: [output])]
        let plan = ExportPublicationPlan(items: [.init(sourceURL: output, filename: "saved", role: .primary,
            assetKind: .image, handling: .addNumber)], probe: nil, destination: .filesFolder, folderBookmark: bookmark)
        let projected = DownloadPublicationWorkflow.project(job, plan: plan)
        #expect(projected.outputReferences?.folderBookmark == bookmark)
        #expect(projected.outputReferences?.files.first?.location == .external("saved.jpg"))
        #expect(SavedOutputResolver.relativePath(URL(fileURLWithPath: "/private/var/mobile/Documents/output.jpg"),
            under: URL(fileURLWithPath: "/var/mobile/Documents")) == "output.jpg")
        #expect(SavedOutputResolver.relativePath(URL(string: "file://untrusted/var/mobile/Documents/output.jpg")!,
            under: URL(fileURLWithPath: "/var/mobile/Documents")) == nil)
    }

    @Test @MainActor
    func aLateStorageScanCannotReplaceANewerMeasurement() async throws {
        let fixture = try AccessFixture()
        defer { fixture.cleanup() }
        let gate = StorageMeasurementGate()
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: fixture.root.appending(path: "State")),
            fixtureModeOverride: true, storageSnapshot: { await gate.snapshot() })
        defer { model.saveTask?.cancel(); model.storageRefreshTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(10)) }
        await gate.arm()
        model.storageRefreshedAt = nil
        let old = Task { await model.refreshStorage() }
        for _ in 0..<100 where await gate.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.storageSummary == "Calculating…")
        let newest = Task { await model.refreshStorage() }
        for _ in 0..<100 where await gate.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await gate.release(2, bytes: 508_040)
        await newest.value
        #expect(model.storage.appDocumentsBytes == 508_040)
        await gate.release(1, bytes: 0)
        await old.value
        #expect(model.storage.appDocumentsBytes == 508_040)
        #expect(!model.isRefreshingStorage)
    }

    @Test
    func hiddenOwnedPayloadsCountWithoutFollowingLinks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "D5-usage-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let documents = root.appending(path: "Documents")
        let temporary = root.appending(path: "tmp")
        let jobID = UUID()
        let parts = temporary.appending(path: "Illucet-\(jobID)/.140.illucet-ranges-audio")
        try fm.createDirectory(at: parts, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_621_440).write(to: parts.appending(path: "0.part"))
        try Data(repeating: 2, count: 17).write(to: documents.appending(path: ".retained.mp4"))
        let outside = root.appending(path: "outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 199).write(to: outside.appending(path: "keep.mp4"))
        try fm.createSymbolicLink(at: temporary.appending(path: "external"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: documents.appending(path: "external.mp4"), withDestinationURL: outside.appending(path: "keep.mp4"))
        let store = StorageManager(documentsURL: documents, temporaryURL: temporary)
        let usage = await store.snapshot()
        #expect(usage.temporaryBytes == 2_621_440)
        #expect(usage.appDocumentsBytes == 17)
        #expect(usage.mediaBytes == 17)
        let protected = try await store.clearTemporaryFiles(excludingJobIDs: [jobID])
        #expect(protected.protectedDirectories == 1 && protected.removedBytes == 0)
        #expect(await store.snapshot().temporaryBytes == 2_621_440)
        let removed = try await store.clearTemporaryFiles()
        #expect(removed.removedBytes == 2_621_440)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "keep.mp4").path))
    }

    @Test(arguments: ["history", "publication"]) @MainActor
    func completedPublicationRefreshesUsageWithoutOpeningStorage(entryPoint: String) async throws {
        let fm = FileManager.default
        let stateRoot = fm.temporaryDirectory.appending(path: "D5-state-\(UUID())")
        let documents = stateRoot.appending(path: "Documents")
        let output = documents.appending(path: "Downloads/D5-usage-\(UUID()).jpg")
        defer { try? fm.removeItem(at: stateRoot); try? fm.removeItem(at: output) }
        let model = IllucetAppModel(persistence: IllucetPersistence(rootURL: stateRoot), fixtureModeOverride: true,
            storageManager: StorageManager(documentsURL: documents, temporaryURL: stateRoot.appending(path: "tmp")))
        defer { model.saveTask?.cancel() }
        for _ in 0..<200 where model.startupState.blocksInteraction { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!model.startupState.blocksInteraction)
        await model.refreshStorage()
        let before = model.storage.appDocumentsBytes
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_801).write(to: output)
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .completed; job.outputURL = output
        if entryPoint == "publication" { try await model.persistPublicationCheckpoint(job) }
        else { model.handle(.addHistory(HistoryRecord(job: job))) }
        for _ in 0..<100 where model.storage.appDocumentsBytes < before + 50_801 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.storage.appDocumentsBytes >= before + 50_801)
    }
}

private struct AccessFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "D5-access-\(UUID())")
    var documents: URL { root.appending(path: "Documents") }
    var downloads: URL { documents.appending(path: "Downloads") }
    var temporary: URL { root.appending(path: "tmp") }
    var external: URL { root.appending(path: "External") }
    var other: URL { root.appending(path: "Other") }
    init() throws {
        for url in [downloads, temporary, external, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func write(_ relative: String, under parent: URL) throws -> URL {
        let url = parent.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        return url
    }
    func record(_ url: URL, destination: ExportDestination = .appDocuments) -> HistoryRecord {
        var job = DeveloperFixtures.failedThumbnailOnlyJob
        job.state = .completed; job.outputURL = url; job.configuration.destination = destination
        return HistoryRecord(job: job)
    }
    func resolver(spy: AccessScopeSpy = .init()) -> SavedOutputResolver {
        SavedOutputResolver(documentsURL: documents, temporaryURL: temporary, pendingSharesURL: root.appending(path: "PendingShares"),
            resolveBookmark: { data in
                switch String(decoding: data, as: UTF8.self) {
                case "original": .init(url: external, stale: false)
                case "stale": .init(url: external, stale: true)
                case "other": .init(url: other, stale: false)
                default: throw SavedOutputAccessFailure.authorizationRequired
                }
            }, securityScope: .init(startAccessing: { _ in spy.start() }, stopAccessing: { _ in spy.stop() }))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class AccessScopeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0, stopped = 0
    let grants: Bool
    init(grants: Bool = true) { self.grants = grants }
    func start() -> Bool { lock.withLock { started += 1 }; return grants }
    func stop() { lock.withLock { stopped += 1 } }
    var starts: Int { lock.withLock { started } }
    var stops: Int { lock.withLock { stopped } }
}

private actor StorageMeasurementGate {
    private var armed = false
    private(set) var count = 0
    private var waiters: [Int: CheckedContinuation<StorageSnapshot, Never>] = [:]
    func arm() { armed = true }
    func snapshot() async -> StorageSnapshot {
        guard armed else { return .empty }
        count += 1
        let id = count
        return await withCheckedContinuation { waiters[id] = $0 }
    }
    func release(_ id: Int, bytes: Int64) {
        waiters.removeValue(forKey: id)?.resume(returning: .init(availableBytes: 100_000_000, appDocumentsBytes: bytes, temporaryBytes: 0, mediaBytes: bytes))
    }
}
