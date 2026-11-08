import Foundation
import CryptoKit

enum ExportReceiptState: String, Codable, Sendable { case notStarted, committing, committed, outcomeUnknown }
enum ExportReceiptDestination: String, Codable, Sendable { case files, photos, share }

struct ExportPublicationReceipt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let destination: ExportReceiptDestination
    var state: ExportReceiptState = .notStarted
    var fileURLs: [URL] = []
    var photoIdentifiers: [String] = []
    var failureCode: String?

    var summary: String {
        let name = destination == .photos ? "Photos" : destination == .share ? "Share" : "Files"
        switch state {
        case .committed: return destination == .share ? "Share: prepared" : "\(name): saved"
        case .committing, .outcomeUnknown: return "\(name): check existing copies before downloading again"
        case .notStarted:
            if failureCode == "photos_permission_denied" { return "Photos: permission denied. Allow access in Settings, then retry export." }
            return failureCode == nil ? "\(name): not saved" : "\(name): save failed. Retry export."
        }
    }
}

struct ExportPublicationItem: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case primary, thumbnail, subtitle, chapter, metadata, package }
    let sourceURL: URL
    let filename: String
    let role: Role
    let assetKind: ExportAssetKind
    var handling: DuplicateHandling
    var subtitle: PreparedSubtitleIdentity?
    var chapter: MediaChapter?
    var metadataKind: MetadataSidecarKind?
    var digest: String = ""

    struct PreparedSubtitleIdentity: Codable, Equatable, Sendable {
        let selection: SubtitleTrackSelection
        let kind: SubtitleSidecarKind
    }
}

struct ExportPublicationPlan: Codable, Equatable, Sendable {
    var items: [ExportPublicationItem]
    let probe: MediaProbeResult?
    let destination: ExportDestination
    let folderBookmark: Data?
    var directory = false

    /// Snapshot small, separately cleaned subtitle inputs; keep large verified media in place.
    func prepared(jobID: UUID, root: URL, fileManager: FileManager = .default) throws -> Self {
        var plan = self
        guard !items.isEmpty, items.count <= 1_001 else { throw ExportPublicationError.inputsUnavailable }
        for index in plan.items.indices {
            if plan.items[index].role == .subtitle {
                _ = try Self.digest(plan.items[index].sourceURL, root: root)
                let folder = root.appending(path: "PublicationInputs", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appending(path: "\(index).\(plan.items[index].sourceURL.pathExtension)")
                if target != plan.items[index].sourceURL {
                    if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                    try fileManager.copyItem(at: plan.items[index].sourceURL, to: target)
                    let old = plan.items[index]
                    plan.items[index] = ExportPublicationItem(sourceURL: target, filename: old.filename,
                        role: old.role, assetKind: old.assetKind, handling: old.handling,
                        subtitle: old.subtitle, chapter: old.chapter, metadataKind: old.metadataKind)
                }
            }
            plan.items[index].digest = try Self.digest(plan.items[index].sourceURL, root: root)
        }
        return plan
    }

    func validate(root: URL) throws {
        guard !items.isEmpty, items.count <= 1_001 else { throw ExportPublicationError.inputsUnavailable }
        for item in items {
            guard !item.digest.isEmpty, !item.filename.isEmpty,
                  item.filename == FilenameSystem.sanitizeComponent(item.filename),
                  try Self.digest(item.sourceURL, root: root) == item.digest else {
                throw ExportPublicationError.inputsUnavailable
            }
        }
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ url: URL, root: URL) throws -> String {
        let path = url.standardizedFileURL
        let rootPath = root.standardizedFileURL
        guard let rootFacts = try? rootPath.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootFacts.isDirectory == true, rootFacts.isSymbolicLink != true else { throw ExportPublicationError.inputsUnavailable }
        guard path.isFileURL, path.path.hasPrefix(rootPath.path + "/"),
              path.resolvingSymlinksInPath().path.hasPrefix(rootPath.resolvingSymlinksInPath().path + "/") else {
            throw ExportPublicationError.inputsUnavailable
        }
        var cursor = path
        while cursor != rootPath {
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ExportPublicationError.inputsUnavailable }
            cursor.deleteLastPathComponent()
        }
        let facts = try path.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if facts.isRegularFile == true { return try fileDigest(path) }
        guard facts.isDirectory == true,
              let entries = FileManager.default.enumerator(at: path,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw ExportPublicationError.inputsUnavailable
        }
        var records: [String] = []
        for case let entry as URL in entries {
            guard records.count < 10_010 else { throw ExportPublicationError.inputsUnavailable }
            let value = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard value.isSymbolicLink != true else { throw ExportPublicationError.inputsUnavailable }
            if value.isRegularFile == true {
                records.append(String(entry.path.dropFirst(path.path.count)) + ":" + (try fileDigest(entry)))
            } else if value.isDirectory == true {
                records.append(String(entry.path.dropFirst(path.path.count)) + "/")
            } else { throw ExportPublicationError.inputsUnavailable }
        }
        return SHA256.hash(data: Data(records.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ExportPublicationError: LocalizedError, Sendable {
    case persistenceUnavailable, inputsUnavailable, outcomeUnknown
    case destinationFailed(ExportReceiptDestination, String)
    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable: "Export progress could not be saved. Your prepared output has been kept. Retry export."
        case .inputsUnavailable: "The retained export inputs are unavailable or changed. Start a new download."
        case .outcomeUnknown: "A save may have completed before Illucet stopped. Check the destination before downloading again."
        case let .destinationFailed(destination, code):
            destination == .photos && code == "photos_permission_denied"
                ? "Photos permission is unavailable. Your Files copy, if saved, has been kept. Allow Photos access in Settings, then retry export."
                : "The \(destination.rawValue) save failed. Known completed destinations have been kept. Retry export."
        }
    }
}
