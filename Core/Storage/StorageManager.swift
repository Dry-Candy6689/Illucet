import Foundation

struct TemporaryCleanupResult: Equatable, Sendable {
    let removedDirectories: Int
    let removedBytes: Int64
    let protectedDirectories: Int
    var protectedBytes: Int64 = 0
    var failedPaths: [String] = []
}

actor StorageManager {
    private let fileManager: FileManager

    private let documentsURL: URL
    private let temporaryURL: URL
    private let applicationSupportURL: URL
    private let capacity: @Sendable (URL) -> Int64

    init(fileManager: FileManager = .default, documentsURL: URL? = nil, temporaryURL: URL? = nil,
         applicationSupportURL: URL? = nil,
         capacity: @escaping @Sendable (URL) -> Int64 = { url in
             (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                 .volumeAvailableCapacityForImportantUsage) ?? 0
         }) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.temporaryURL = temporaryURL ?? fileManager.temporaryDirectory
        self.applicationSupportURL = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.storageDirectoryName)
        self.capacity = capacity
    }

    // Capacity checks must not wait behind a full usage traversal on this actor.
    nonisolated func availableCapacity() -> Int64 { max(0, capacity(documentsURL)) }

    func snapshot() -> StorageSnapshot {
        let documents = documentUsage()
        return StorageSnapshot(availableBytes: availableCapacity(),
            appDocumentsBytes: documents.total,
            temporaryBytes: directorySize(temporaryURL),
            mediaBytes: documents.media,
            breakdown: StorageUsageBreakdown(
                savedDownloadsBytes: directorySize(documentsURL.appending(path: "Downloads")),
                activityLogBytes: directorySize(applicationSupportURL.appending(path: "Diagnostics.json")),
                otherDocuments: entries(in: documentsURL).filter { $0.relativePath != "Downloads" },
                temporaryEntries: temporaryEntries()))
    }

    nonisolated func preflight(requiredBytes: Int64, reserveBytes: Int64) throws {
        try StorageByteArithmetic.validateBudget(requiredBytes: requiredBytes,
            reserveBytes: reserveBytes, availableBytes: availableCapacity())
    }

    @discardableResult
    func clearTemporaryFiles(
        olderThan cutoff: Date? = nil,
        excludingJobIDs: Set<UUID> = [],
        onlyJobIDs: Set<UUID>? = nil,
        excludingPaths: Set<String> = [],
        orphanedBefore: Date? = nil
    ) throws -> TemporaryCleanupResult {
        let root = temporaryURL
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let protectedNames = Set(
            excludingJobIDs.map { "Illucet-\($0.uuidString)" }
        ).union(excludingPaths)
        var removedDirectories = 0
        var removedBytes: Int64 = 0
        var protectedDirectories = 0
        var protectedBytes: Int64 = 0
        var failedPaths: [String] = []
        for child in children {
            let owned = Self.cleanupJobID(child.lastPathComponent) != nil || Self.isDiagnosticTemporary(child.lastPathComponent)
            // Manual cleanup may reclaim old URLSession/FileDocument leftovers,
            // only when no recoverable job could still own a network temp file.
            let orphan = excludingJobIDs.isEmpty && onlyJobIDs == nil
                && orphanedBefore.map { isStaleSystemTemporary(child, before: $0) } == true
            guard owned || orphan else { continue }
            if let onlyJobIDs {
                guard let jobID = UUID(uuidString: String(child.lastPathComponent.dropFirst("Illucet-".count))),
                      onlyJobIDs.contains(jobID) else { continue }
            }
            if protectedNames.contains(child.lastPathComponent) {
                protectedDirectories += 1
                protectedBytes = StorageByteArithmetic.adding(protectedBytes, directorySize(child))
                continue
            }
            if let cutoff {
                let modified = try? child.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if let modified, modified >= cutoff { continue }
            }
            let bytes = directorySize(child)
            do {
                try fileManager.removeItem(at: child)
                removedBytes = StorageByteArithmetic.adding(removedBytes, bytes)
                removedDirectories += 1
            } catch { failedPaths.append(child.lastPathComponent) }
        }
        return TemporaryCleanupResult(
            removedDirectories: removedDirectories,
            removedBytes: removedBytes,
            protectedDirectories: protectedDirectories,
            protectedBytes: protectedBytes, failedPaths: failedPaths
        )
    }

    /// Explicit "Delete Illucet files" also covers files placed in Documents
    /// outside Downloads. Preferences and History live in Application Support.
    func deleteOtherDocuments() throws -> Int {
        let values = try documentsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let children = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        var removed = 0
        for child in children where child.lastPathComponent != "Downloads" {
            // removeItem unlinks symlinks, without following them outside Documents.
            try fileManager.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    private func isStaleSystemTemporary(_ url: URL, before cutoff: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
            values.isSymbolicLink == false, let modified = values.contentModificationDate,
            modified < cutoff else { return false }
        let name = url.lastPathComponent
        if values.isRegularFile == true {
            return name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp")
        }
        guard values.isDirectory == true, UUID(uuidString: name) != nil,
              let children = try? fileManager.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        // FileDocument stages preferences in a UUID directory. Do not interpret
        // arbitrary folders, imported files or links as disposable exports.
        return children.allSatisfy { child in
            guard child.lastPathComponent == "Illucet-Preferences.json",
                  let info = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink == false,
                  let size = info.fileSize, size <= PreferencesBackup.maximumBytes,
                  let data = try? Data(contentsOf: child),
                  (try? PreferencesBackup.decode(data)) != nil else { return false }
            return true
        }
    }

    func touchTemporaryFiles(for jobID: UUID, at date: Date = .now) {
        let root = temporaryRoot(for: jobID)
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: root.path
        )
    }

    func temporaryFilesExist(for jobID: UUID) -> Bool {
        fileManager.fileExists(atPath: temporaryRoot(for: jobID).path)
    }

    private func temporaryRoot(for jobID: UUID) -> URL {
        temporaryURL.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func directorySize(_ root: URL) -> Int64 { usage(root).total }

    private func documentUsage() -> (total: Int64, media: Int64) { usage(documentsURL) }

    private func entries(in root: URL) -> [StorageUsageEntry] {
        guard let children = try? fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [] }
        return children.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
            return StorageUsageEntry(relativePath: child.lastPathComponent, byteCount: directorySize(child))
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private func temporaryEntries() -> [StorageUsageEntry] {
        entries(in: temporaryURL).map { entry in
            var result = entry
            result.jobID = Self.cleanupJobID(entry.relativePath)
            result.isCleanupCandidate = result.jobID != nil || Self.isDiagnosticTemporary(entry.relativePath)
            return result
        }
    }

    private static func cleanupJobID(_ name: String) -> UUID? {
        guard name.hasPrefix("Illucet-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("Illucet-".count)))
    }

    private static func isDiagnosticTemporary(_ name: String) -> Bool {
        let prefix = "Illucet-Diagnostics-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func usage(_ root: URL) -> (total: Int64, media: Int64) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let mediaExtensions: Set<String> = ["mp4", "mov", "mkv", "webm", "m4a", "mp3", "opus", "ogg", "flac", "wav"]
        guard let rootValues = try? root.resourceValues(forKeys: keys), rootValues.isSymbolicLink != true else { return (0, 0) }
        if rootValues.isRegularFile == true {
            let bytes = Int64(max(0, rootValues.fileSize ?? 0))
            return (bytes, mediaExtensions.contains(root.pathExtension.lowercased()) ? bytes : 0)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().pathComponents
        var total: Int64 = 0, media: Int64 = 0
        var pending = [root]
        while let candidate = pending.popLast() {
            // Fresh URLs avoid carrying cached pre-rename resource attributes.
            let directory = URL(fileURLWithPath: candidate.path, isDirectory: true)
            guard let values = try? directory.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  directory.resolvingSymlinksInPath().pathComponents.starts(with: resolvedRoot),
                  let children = try? fileManager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: Array(keys), options: []) else { continue }
            for url in children {
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                      SavedOutputResolver.relativePath(url, under: root) != nil,
                      url.resolvingSymlinksInPath().pathComponents.starts(with: resolvedRoot) else { continue }
                if values.isDirectory == true { pending.append(url); continue }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(max(0, values.fileSize ?? 0))
                total = StorageByteArithmetic.adding(total, bytes)
                if mediaExtensions.contains(url.pathExtension.lowercased()) { media = StorageByteArithmetic.adding(media, bytes) }
            }
        }
        return (total, media)
    }
}
