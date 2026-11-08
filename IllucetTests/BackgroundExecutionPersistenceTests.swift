import Foundation
import Testing
@testable import Illucet

struct BackgroundExecutionPersistenceTests {
    @Test
    func protectionIsRestoredAfterAtomicReplacementAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned")
        let outside = root.appendingPathComponent("private.txt")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let file = owned.appendingPathComponent("media.mp4")
        let manager = ProtectionRecordingFileManager()
        try Data("before".utf8).write(to: file, options: [.atomic, .completeFileProtection])
        try BackgroundFileProtection.protect(file, under: owned, fileManager: manager)
        #expect(manager.appliedProtection(to: file) == .completeUntilFirstUserAuthentication)
        try verifyProtectionWhenAvailable(file, expected: .completeUntilFirstUserAuthentication)
        try Data("after".utf8).write(to: file, options: [.atomic, .completeFileProtection])
        try BackgroundFileProtection.protect(file, under: owned, fileManager: manager)
        #expect(manager.applicationCount(to: file) == 2)
        try verifyProtectionWhenAvailable(file, expected: .completeUntilFirstUserAuthentication)
        try Data("unrelated".utf8).write(to: outside, options: .completeFileProtection)
        let link = owned.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: BackgroundFileProtection.Failure.self) { try BackgroundFileProtection.protect(link, under: owned, fileManager: manager) }
        #expect(throws: BackgroundFileProtection.Failure.self) { try BackgroundFileProtection.protect(outside, under: owned, fileManager: manager) }
        #expect(manager.applicationCount(to: outside) == 0)
        #expect(manager.applicationCount(to: link) == 0)
        try verifyProtectionWhenAvailable(outside, expected: .complete)
    }

    @Test(arguments: [false, true]) @MainActor
    func eventDeliveryWaitsOnlyForItsAcknowledgements(injectFailure: Bool) async throws {
        let writes = NativeTransferAcknowledgements()
        let current = NativeWriteGate(), future = NativeWriteGate()
        writes.enqueue(taskID: 1) {
            await current.wait()
            if injectFailure { throw NativeTransferCheckpointError.persistenceUnavailable }
        }
        let barrier = writes.captureDeliveryBarrier()
        writes.enqueue(taskID: 2) { await future.wait() }
        let identifier = "test.native-ack." + UUID().uuidString
        var completions = 0
        BackgroundSessionEventBroker.shared.register(sessionIdentifier: identifier) { completions += 1 }
        let delivery = Task { @MainActor in
            await barrier()
            BackgroundSessionEventBroker.shared.finishEvents(sessionIdentifier: identifier)
        }
        await Task.yield()
        #expect(completions == 0)
        await current.release()
        await delivery.value
        #expect(completions == 1)
        #expect(!(await future.released))
        if injectFailure {
            await #expect(throws: NativeTransferCheckpointError.self) { try await writes.wait(taskID: 1) }
        } else { try await writes.wait(taskID: 1) }
        await future.release()
        try await writes.wait(taskID: 2)
    }

    @Test
    func unconsumedAcknowledgementFailureSurvivesMoreThan128Completions() async throws {
        let writes = NativeTransferAcknowledgements()
        for id in 0..<160 {
            writes.enqueue(taskID: id) {
                if id == 0 { throw NativeTransferCheckpointError.persistenceUnavailable }
            }
        }
        await writes.captureDeliveryBarrier()()
        await #expect(throws: NativeTransferCheckpointError.self) { try await writes.wait(taskID: 0) }
        for id in 1..<160 { try await writes.wait(taskID: id) }
    }

    @Test(arguments: [false, true])
    func earlyReceiptsWaitForARealWriterOrReportStartupFailure(reject: Bool) async throws {
        let writer = NativeReceiptWriter()
        let receipt = NativeFileReceipt(identity: .init(root: .temporary, relativePath: "Illucet-job/137.mp4"),
            taskIdentifier: 1, formatID: "137", byteCount: 7, recordedAt: .now)
        let gate = NativeWriteGate()
        let early = Task { try await writer.write(jobID: UUID(), attempt: nil, receipt: receipt) }
        if reject {
            writer.reject()
            await #expect(throws: NativeTransferCheckpointError.self) { try await early.value }
        } else {
            writer.install { _, _, _ in await gate.release() }
            try await early.value
            #expect(await gate.released)
        }
    }

    @Test
    func nativeReceiptIsMetadataOnlyAndVersionEightStillDecodes() throws {
        let receipt = NativeFileReceipt(identity: .init(root: .temporary, relativePath: "Illucet-job/137.mp4"),
            taskIdentifier: 17, formatID: "137", byteCount: 7, recordedAt: .now)
        let data = try JSONEncoder.illucetEncoder.encode(receipt)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for secret in ["https", "cookie", "authorization", "signature", "headers"] { #expect(!text.contains(secret)) }
        var snapshot = IllucetSnapshot.empty
        snapshot.schemaVersion = 8
        var job = DeveloperFixtures.sponsorBlockAppliedJob
        job.transferRecoveryCount = 2
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .transferring)
        job.pipelineCheckpoint?.nativeFileReceipts = [receipt]
        snapshot.jobs = [job]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.illucetEncoder.encode(snapshot)) as? [String: Any])
        var jobs = try #require(object["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "transferRecoveryCount")
        var checkpoint = try #require(jobs[0]["pipelineCheckpoint"] as? [String: Any])
        checkpoint.removeValue(forKey: "nativeFileReceipts")
        jobs[0]["pipelineCheckpoint"] = checkpoint; object["jobs"] = jobs
        let restored = try JSONDecoder.illucetDecoder.decode(IllucetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.schemaVersion == 8)
        #expect(restored.jobs.first?.selectedFormatIDs == job.selectedFormatIDs)
        #expect(restored.jobs.first?.transferRecoveryCount == nil)
        #expect(restored.jobs.first?.pipelineCheckpoint?.nativeFileReceipts == nil)
    }

}

// Simulator filesystems may omit NSFileProtectionKey entirely. Always verify
// the real setAttributes request; physical-device runs additionally read it back.
final class ProtectionRecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, FileProtectionType)] = []
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if let value = attributes[.protectionKey] as? FileProtectionType {
            lock.withLock { requests.append((path, value)) }
        }
    }
    func appliedProtection(to url: URL) -> FileProtectionType? {
        lock.withLock { requests.last { $0.0 == url.path }?.1 }
    }
    func applicationCount(to url: URL) -> Int {
        lock.withLock { requests.count { $0.0 == url.path } }
    }
}

func verifyProtectionWhenAvailable(_ url: URL, expected: FileProtectionType) throws {
    let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
    if let raw { #expect((raw as? String) == expected.rawValue) }
    #if !targetEnvironment(simulator)
    #expect(raw != nil)
    #endif
}

private actor NativeWriteGate {
    private(set) var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}
