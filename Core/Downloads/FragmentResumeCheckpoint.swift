import CryptoKit
import Foundation

/// Reasons for deliberately restarting instead of trusting completed counts.
enum FragmentResumeRestartReason: String, Sendable {
    case planChanged, encryptedResources, validatorUnavailable
    case validatorChanged, corruptResource, invalidCheckpoint
}

protocol FragmentCheckpointManaging: Sendable {
    func discardFragmentCheckpoints(jobID: UUID, formatID: String?) throws
}

typealias FragmentResumeEventHandler = @Sendable (UUID, String, FragmentResumeRestartReason) -> Void

enum FragmentRecoveryError: LocalizedError, Equatable {
    case expiryRefreshExhausted, sourceAlreadyActive, invalidCheckpoint

    var errorDescription: String? {
        switch self {
        case .expiryRefreshExhausted:
            "The selected fragment URLs expired after two refresh attempts."
        case .sourceAlreadyActive:
            "This fragmented source already has an active writer."
        case .invalidCheckpoint:
            "The fragment checkpoint could not be verified safely."
        }
    }
}

enum FragmentURLRecovery {
    static func isExpired(_ error: any Error) -> Bool {
        guard let failure = error as? StreamDownloadError else { return false }
        switch failure {
        case .forbiddenHTTPFailure(statusCode: 403), .goneHTTPFailure(statusCode: 410): return true
        default: return false
        }
    }

    /// Refresh only typed 403/410 failures; all callers retain their original
    /// selected source facts when implementing `refresh`.
    static func run<Plan, Output>(
        initial: Plan,
        refresh: () async throws -> Plan,
        beforeRefresh: () async throws -> Void = {},
        acquire: (Plan) async throws -> Output
    ) async throws -> Output {
        var current = initial
        var refreshes = 0
        var needsRefresh = false
        while true {
            try Task.checkCancellation()
            do {
                if needsRefresh {
                    refreshes += 1
                    try await beforeRefresh()
                    current = try await refresh()
                }
                return try await acquire(current)
            } catch {
                try Task.checkCancellation()
                guard isExpired(error) else { throw error }
                guard refreshes < 2 else {
                    throw FragmentRecoveryError.expiryRefreshExhausted
                }
                needsRefresh = true
            }
        }
    }
}

/// One coordinator-owned barrier covers acquisition shutdown, permit release,
/// and every overlapping job-wide transport cancellation. It stays present
/// across suspension points; a single caller can claim final cleanup/admission.
struct FragmentPauseBarrier {
    let id = UUID()
    private(set) var acquisitionFinished = false
    private(set) var pendingControls = 1
    private(set) var cancellationRequested = false
    private(set) var finalizationClaimed = false

    mutating func requestCancellation() {
        cancellationRequested = true
        pendingControls += 1
    }

    mutating func acknowledgeControl() {
        guard pendingControls > 0 else { return }
        pendingControls -= 1
    }

    mutating func acknowledgeAcquisition() { acquisitionFinished = true }

    mutating func claimFinalization() -> Bool {
        guard acquisitionFinished, pendingControls == 0, !finalizationClaimed else { return false }
        finalizationClaimed = true
        return true
    }
}

/// A lease spans download, validator checks and checkpoint publication. This is
/// separate from individual URLSession task ownership and covers both transports.
final class FragmentSourceLeases: @unchecked Sendable {
    static let shared = FragmentSourceLeases()
    private let lock = NSLock()
    private var active: Set<String> = []

    func acquire(jobID: UUID, formatID: String) throws -> String {
        let key = jobID.uuidString + ":" + formatID
        lock.lock()
        defer { lock.unlock() }
        guard active.insert(key).inserted else {
            throw FragmentRecoveryError.sourceAlreadyActive
        }
        return key
    }

    func hasActiveSource(jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.contains { $0.hasPrefix(jobID.uuidString + ":") }
    }

    func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        active.remove(key)
    }
}

/// Only SHA-256 fingerprints of transport identity are retained. A URL digest is
/// a binding, NOT content proof: reuse additionally requires a fresh strong ETag
/// response from that exact resource and a verified local digest.
final class FragmentResumeCheckpoint {
    struct Resource: Codable, Equatable {
        let position: Int
        let byteCount: Int64
        let localDigest: String
        let validatorDigest: String
        let URLDigest: String
    }

    private struct Manifest: Codable {
        let version: Int
        let jobID: UUID
        let sourceDigest: String
        let planDigest: String
        var resources: [Resource]
    }

    let directory: URL
    private let fileManager: FileManager
    private var manifest: Manifest
    private(set) var restartReason: FragmentResumeRestartReason?
    var onRestart: ((FragmentResumeRestartReason) -> Void)?

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ fields: [String]) -> String {
        // JSON framing avoids collisions from arbitrary delimiters in IDs.
        digest((try? JSONEncoder().encode(fields)) ?? Data())
    }

    static func strongValidator(_ headers: [String: String]) -> String? {
        let values = headers.filter { $0.key.lowercased() == "etag" }.map(\.value)
        guard values.count == 1, let value = values.first,
              value.utf8.count >= 2, value.utf8.count <= 1024,
              value.first == "\"", value.last == "\"",
              !value.dropFirst().dropLast().contains("\""),
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 != 0x7f })
        else { return nil }
        return digest(Data(value.utf8))
    }

    init(
        roots: StreamTransferDestinationRoots,
        jobID: UUID,
        formatID: String,
        planDigest: String,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let sourceDigest = Self.fingerprint([formatID])
        directory = roots.applicationSupportDirectory
            .appending(path: "Fragment-Checkpoints", directoryHint: .isDirectory)
            .appending(path: jobID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: sourceDigest, directoryHint: .isDirectory)
        _ = try roots.identity(for: directory)
        // Validate each ancestor before creating descendants, including existing
        // directories. Never follow a checkpoint-controlled symbolic link.
        for folder in [directory.deletingLastPathComponent().deletingLastPathComponent(),
                       directory.deletingLastPathComponent(), directory] {
            if fileManager.fileExists(atPath: folder.path) {
                try Self.requireDirectory(folder)
            } else {
                guard (try? fileManager.destinationOfSymbolicLink(atPath: folder.path)) == nil else {
                    throw FragmentRecoveryError.invalidCheckpoint
                }
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                try Self.requireDirectory(folder)
            }
        }
        manifest = Manifest(version: 1, jobID: jobID, sourceDigest: sourceDigest,
                            planDigest: planDigest, resources: [])
        let manifestURL = directory.appending(path: "checkpoint.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            if let bytes = try? Self.readRegular(manifestURL, maximumBytes: 2 * 1024 * 1024),
               let saved = try? JSONDecoder().decode(Manifest.self, from: bytes),
               saved.version == 1, saved.jobID == jobID,
               saved.sourceDigest == sourceDigest,
               saved.resources.count <= 4096,
               Set(saved.resources.map(\.position)).count == saved.resources.count,
               saved.resources.allSatisfy({ $0.position >= 0 && $0.byteCount > 0 }) {
                if saved.planDigest == planDigest {
                    manifest = saved
                } else {
                    restartReason = .planChanged
                }
            } else {
                restartReason = .invalidCheckpoint
            }
        }
        // Orphans can be left between file publication and the atomic manifest
        // write. They are never accepted and are removed before any new writer.
        let accepted = Set(manifest.resources.map { Self.filename($0.position) })
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if child.lastPathComponent != "checkpoint.json" && !accepted.contains(child.lastPathComponent) {
                try fileManager.removeItem(at: child)
            }
        }
        try save()
    }

    func resource(at position: Int) -> Resource? {
        manifest.resources.first { $0.position == position }
    }

    func restore(_ resource: Resource, to destination: URL) throws -> Bool {
        let source = directory.appending(path: Self.filename(resource.position))
        guard let facts = try? Self.fileFacts(source),
              facts.bytes == resource.byteCount,
              facts.digest == resource.localDigest else {
            try reject(resource, reason: .corruptResource)
            return false
        }
        guard !fileManager.fileExists(atPath: destination.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw FragmentRecoveryError.invalidCheckpoint
        }
        try fileManager.copyItem(at: source, to: destination)
        let copied = try Self.fileFacts(destination)
        guard copied.bytes == resource.byteCount && copied.digest == resource.localDigest else {
            try? fileManager.removeItem(at: destination)
            throw FragmentRecoveryError.invalidCheckpoint
        }
        return true
    }

    func accept(position: Int, fileURL: URL, remoteURL: URL, validator: String?) throws {
        try Task.checkCancellation()
        guard let validator else { return }
        let facts = try Self.fileFacts(fileURL)
        let target = directory.appending(path: Self.filename(position))
        let inflight = directory.appending(path: ".completed-\(position).inflight")
        try? fileManager.removeItem(at: inflight)
        try fileManager.copyItem(at: fileURL, to: inflight)
        let copied = try Self.fileFacts(inflight)
        guard copied == facts else { throw FragmentRecoveryError.invalidCheckpoint }
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: inflight, to: target)
        manifest.resources.removeAll { $0.position == position }
        manifest.resources.append(Resource(position: position, byteCount: facts.bytes,
            localDigest: facts.digest, validatorDigest: validator,
            URLDigest: Self.fingerprint([remoteURL.absoluteString])))
        try save()
    }

    func reject(_ resource: Resource, reason: FragmentResumeRestartReason) throws {
        restartReason = reason
        onRestart?(reason)
        manifest.resources.removeAll { $0.position == resource.position }
        try save()
        let target = directory.appending(path: Self.filename(resource.position))
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }

    private func save() throws {
        try Self.requireDirectory(directory)
        let destination = directory.appending(path: "checkpoint.json")
        guard (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw FragmentRecoveryError.invalidCheckpoint
        }
        try JSONEncoder().encode(manifest).write(to: destination, options: .atomic)
    }

    static func discard(jobID: UUID, formatID: String?, roots: StreamTransferDestinationRoots,
                        fileManager: FileManager = .default) throws {
        let base = roots.applicationSupportDirectory.appending(path: "Fragment-Checkpoints", directoryHint: .isDirectory)
        let job = base.appending(path: jobID.uuidString.lowercased(), directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: base.path) else { return }
        try requireDirectory(base)
        guard fileManager.fileExists(atPath: job.path) else { return }
        try requireDirectory(job)
        let target = formatID.map { job.appending(path: fingerprint([$0]), directoryHint: .isDirectory) } ?? job
        _ = try roots.identity(for: target)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try requireDirectory(target)
        try fileManager.removeItem(at: target)
    }

    private static func filename(_ position: Int) -> String { "completed-\(position).media" }

    private static func requireDirectory(_ URL: URL) throws {
        let values = try URL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FragmentRecoveryError.invalidCheckpoint
        }
    }

    private static func readRegular(_ URL: URL, maximumBytes: Int) throws -> Data {
        let values = try URL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else {
            throw FragmentRecoveryError.invalidCheckpoint
        }
        return try Data(contentsOf: URL)
    }

    static func fileFacts(_ URL: URL) throws -> (bytes: Int64, digest: String) {
        let values = try URL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw FragmentRecoveryError.invalidCheckpoint }
        let handle = try FileHandle(forReadingFrom: URL)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            let addition = count.addingReportingOverflow(Int64(data.count))
            guard !addition.overflow else { throw FragmentRecoveryError.invalidCheckpoint }
            count = addition.partialValue
            hash.update(data: data)
        }
        guard count == Int64(size) else { throw FragmentRecoveryError.invalidCheckpoint }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
