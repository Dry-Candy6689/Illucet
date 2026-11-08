import Foundation
import Photos

struct ExportPreflight: Equatable, Sendable {
    let desiredURL: URL?
    let hasCollision: Bool
}

struct ExportResult: Equatable, Sendable {
    let fileURL: URL?
    let photoAssetLocalIdentifiers: [String]
    let shareRequest: SharePresentationRequest?
    let outcome: ExportOutcome

    var skippedDuplicate: Bool {
        outcome == .duplicateSkipped
    }
}

struct ExportFileTransactionItem: Equatable, Sendable {
    let sourceURL: URL
    let filename: String
}

struct FilesFolderBookmark: Equatable, Sendable {
    let data: Data
    let displayName: String
}

struct FilesFolderAccess: Equatable, Sendable {
    let folderURL: URL
    let displayName: String
}

struct FilesFolderResolvedSelection: Equatable, Sendable {
    let bookmarkData: Data
    let selectionIdentity: String
    let displayName: String

    init(selection: FilesFolderBookmark, access: FilesFolderAccess) {
        bookmarkData = selection.data
        selectionIdentity = FilesFolderDisplayIdentity.selectionIdentity(
            for: access.folderURL
        )
        displayName = access.displayName
    }
}

enum FilesFolderDisplayIdentity {
    static let neutralName = "Selected Files folder"
    static let maximumAliasLength = 64

    static func presentedName(
        alias: String?,
        resolved: String
    ) -> String {
        normalizedAlias(alias) ?? normalized(resolved) ?? neutralName
    }

    static func normalizedAlias(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let singleLine = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let normalized = singleLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumAliasLength))
    }

    static func boundedAliasInput(_ candidate: String) -> String {
        let singleLine = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(maximumAliasLength))
    }

    static func shouldOfferAlias(for resolved: String) -> Bool {
        normalized(resolved)?.caseInsensitiveCompare("Documents")
            == .orderedSame
    }

    static func representsSameFolder(_ left: URL, _ right: URL) -> Bool {
        selectionIdentity(for: left) == selectionIdentity(for: right)
    }

    static func selectionIdentity(for folderURL: URL) -> String {
        folderURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func resolve(
        userVisiblePathComponents: [String]?,
        localizedName: String?,
        resourceName: String?,
        lastPathComponent: String
    ) -> String {
        let userVisibleName = userVisiblePathComponents?
            .last.flatMap(normalized)
        if let userVisibleName {
            return userVisibleName
        }

        let resourceCandidates = [
            localizedName,
            resourceName,
        ].compactMap(normalized)
        if let resourceName = resourceCandidates.first {
            return resourceName
        }

        return normalized(lastPathComponent) ?? neutralName
    }

    private static func normalized(_ candidate: String?) -> String? {
        let trimmed = candidate?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}

enum ExportFileTransactionOutcome: Equatable, Sendable {
    case committed([URL])
    case duplicateSkipped
}

enum ExportFileTransactionEvent: Equatable, Sendable {
    case willStage(Int)
    case didStage(Int)
    case stagingComplete
    case willCommit(Int)
    case didCommit(Int)
}

protocol PhotoLibraryExporting: Sendable {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String
    func saveAsset(at fileURL: URL, kind: ExportAssetKind, originalFilename: String) async throws -> String
}

extension PhotoLibraryExporting {
    func saveAsset(at fileURL: URL, kind: ExportAssetKind, originalFilename: String) async throws -> String {
        try await saveAsset(at: fileURL, kind: kind)
    }
}

struct SystemPhotoLibraryExporter: PhotoLibraryExporting {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String {
        try await saveAsset(at: fileURL, kind: kind, originalFilename: fileURL.lastPathComponent)
    }

    func saveAsset(at fileURL: URL, kind: ExportAssetKind, originalFilename: String) async throws -> String {
        if kind == .audio {
            throw IllucetError.photosIncompatible
        }
        if kind == .video {
            let compatibleVideoExtensions: Set<String> = [
                "mp4", "mov", "m4v",
            ]
            guard compatibleVideoExtensions.contains(
                fileURL.pathExtension.lowercased()
            ) else {
                throw IllucetError.photosIncompatible
            }
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw IllucetError.photosPermissionDenied
        }

        let identifier = PhotoIdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = FilenameSystem.sanitizeComponent(originalFilename)
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: kind == .video ? .video : .photo, fileURL: fileURL, options: options)
                identifier.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            throw IllucetError.photosIncompatible
        }
        guard let value = identifier.value, !value.isEmpty else {
            // performChanges succeeded: absence of a usable identifier is not proof
            // that nothing was saved, so this outcome must never be replayed blindly.
            throw ExportPublicationError.outcomeUnknown
        }
        return value
    }
}

private final class PhotoIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    func set(_ value: String?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

struct ExportSecurityScope: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void

    static let system = Self(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

actor ExportManager {
    private struct TransactionPlan {
        let item: ExportFileTransactionItem
        let handling: DuplicateHandling
        let targetURL: URL
        let targetExistedAtPreflight: Bool
        let stagedURL: URL
        let backupURL: URL
    }

    private static let maximumTransactionItems = 1_001

    private let fileManager: FileManager
    private let photoLibrary: any PhotoLibraryExporting
    private let securityScope: ExportSecurityScope
    private let documentsRootURL: URL?
    private let shareRootURL: URL?
    private let transactionObserver:
        (@Sendable (ExportFileTransactionEvent) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        photoLibrary: any PhotoLibraryExporting = SystemPhotoLibraryExporter(),
        documentsRootURL: URL? = nil,
        shareRootURL: URL? = nil,
        transactionObserver:
            (@Sendable (ExportFileTransactionEvent) throws -> Void)? = nil,
        securityScope: ExportSecurityScope = .system
    ) {
        self.fileManager = fileManager
        self.photoLibrary = photoLibrary
        self.securityScope = securityScope
        self.documentsRootURL = documentsRootURL
        self.shareRootURL = shareRootURL
        self.transactionObserver = transactionObserver
    }

    func bookmark(for folderURL: URL) throws -> Data {
        try bookmarkSelection(for: folderURL).data
    }

    func bookmarkSelection(for folderURL: URL) throws -> FilesFolderBookmark {
        guard folderURL.hasDirectoryPath else {
            throw IllucetError.filesDestinationUnavailable
        }
        let scopedAccess = folderURL.startAccessingSecurityScopedResource()
        guard scopedAccess || fileManager.isWritableFile(atPath: folderURL.path)
        else {
            throw IllucetError.filesDestinationUnavailable
        }
        defer {
            if scopedAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        let displayName = folderDisplayName(for: folderURL)
        let data = try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return FilesFolderBookmark(data: data, displayName: displayName)
    }

    func testFolderAccess(bookmark: Data) throws -> URL {
        try testFolderAccessDetail(bookmark: bookmark).folderURL
    }

    func testFolderAccessDetail(bookmark: Data) throws -> FilesFolderAccess {
        let folder = try resolveFolder(bookmark)
        let scopedAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        let testURL = folder.appending(path: ".illucet-access-test")
        do {
            try Data().write(to: testURL, options: .atomic)
            try fileManager.removeItem(at: testURL)
            return FilesFolderAccess(
                folderURL: folder,
                displayName: folderDisplayName(for: folder)
            )
        } catch {
            throw IllucetError.filesDestinationUnavailable
        }
    }

    private func folderDisplayName(for folderURL: URL) -> String {
        let userVisiblePathComponents = fileManager.componentsToDisplay(
            forPath: folderURL.path
        )
        let values = try? folderURL.resourceValues(
            forKeys: [.localizedNameKey, .nameKey]
        )
        return FilesFolderDisplayIdentity.resolve(
            userVisiblePathComponents: userVisiblePathComponents,
            localizedName: values?.localizedName,
            resourceName: values?.name,
            lastPathComponent: folderURL.lastPathComponent
        )
    }

    func preflight(
        destination: ExportDestination,
        filename: String,
        fileExtension: String,
        folderBookmark: Data?,
        relativeDirectory: String? = nil
    ) throws -> ExportPreflight {
        switch destination {
        case .appDocuments:
            return try preflight(
                in: outputDirectory(
                    beneath: outputDirectory(),
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                fileExtension: fileExtension
            )
        case .filesFolder, .filesAndPhotos:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            let scopedAccess = folder.startAccessingSecurityScopedResource()
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            defer {
                if scopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            return try preflight(
                in: outputDirectory(
                    beneath: folder,
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                fileExtension: fileExtension
            )
        case .photos, .share:
            return ExportPreflight(desiredURL: nil, hasCollision: false)
        case .askEveryTime:
            throw IllucetError.filesDestinationUnavailable
        }
    }

    func export(
        sourceURL: URL,
        destination: ExportDestination,
        filename: String,
        folderBookmark: Data?,
        duplicateHandling: DuplicateHandling,
        videoID: String,
        jobID: UUID,
        title: String,
        assetKind: ExportAssetKind,
        relativeDirectory: String? = nil
    ) async throws -> ExportResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw IllucetError.filesDestinationUnavailable
        }
        switch destination {
        case .appDocuments:
            guard let copied = try copy(
                sourceURL,
                to: outputDirectory(
                    beneath: outputDirectory(),
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [],
                shareRequest: nil,
                outcome: .file
            )
        case .filesFolder:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            let scopedAccess = folder.startAccessingSecurityScopedResource()
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            defer {
                if scopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            guard let copied = try copy(
                sourceURL,
                to: outputDirectory(
                    beneath: folder,
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [],
                shareRequest: nil,
                outcome: .file
            )
        case .photos:
            let identifier = try await photoLibrary.saveAsset(
                at: sourceURL,
                kind: assetKind,
                originalFilename: FilenameSystem.sanitizeComponent(filename) + "." + sourceURL.pathExtension
            )
            return ExportResult(
                fileURL: nil,
                photoAssetLocalIdentifiers: [identifier],
                shareRequest: nil,
                outcome: .photos
            )
        case .filesAndPhotos:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            let scopedAccess = folder.startAccessingSecurityScopedResource()
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            defer {
                if scopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            guard let copied = try copy(
                sourceURL,
                to: outputDirectory(
                    beneath: folder,
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            let identifier: String
            do {
                identifier = try await photoLibrary.saveAsset(
                    at: copied,
                    kind: assetKind,
                    originalFilename: FilenameSystem.sanitizeComponent(filename) + "." + copied.pathExtension
                )
            } catch {
                throw ExportError.filesSavedPhotosFailed(
                    fileURL: copied,
                    reason: String(error.localizedDescription.prefix(256))
                )
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [identifier],
                shareRequest: nil,
                outcome: .filesAndPhotos
            )
        case .share:
            let staged = try stageShare(
                sourceURL,
                filename: filename,
                jobID: jobID
            )
            let request = SharePresentationRequest(
                jobID: jobID,
                title: title,
                fileURLs: [staged]
            )
            return ExportResult(
                fileURL: staged,
                photoAssetLocalIdentifiers: [],
                shareRequest: request,
                outcome: .sharePending
            )
        case .askEveryTime:
            throw IllucetError.filesDestinationUnavailable
        }
    }

    func exportFileTransaction(
        items: [ExportFileTransactionItem],
        destination: ExportDestination,
        folderBookmark: Data?,
        duplicateHandling: [DuplicateHandling],
        videoID: String,
        relativeDirectory: String? = nil
    ) throws -> ExportFileTransactionOutcome {
        guard !items.isEmpty,
              items.count <= Self.maximumTransactionItems,
              items.count == duplicateHandling.count
        else {
            throw IllucetError.filesDestinationUnavailable
        }

        let root: URL
        var scopedFolder: URL?
        var scopedAccess = false
        defer {
            if scopedAccess, let scopedFolder {
                securityScope.stopAccessing(scopedFolder)
            }
        }
        switch destination {
        case .appDocuments:
            root = try outputDirectory(
                beneath: outputDirectory(),
                relativeDirectory: relativeDirectory
            )
        case .filesFolder:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            scopedFolder = folder
            scopedAccess = securityScope.startAccessing(folder)
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            root = try outputDirectory(
                beneath: folder,
                relativeDirectory: relativeDirectory
            )
        default:
            throw IllucetError.filesDestinationUnavailable
        }

        let transactionRoot = root.appending(
            path: ".illucet-export-transaction-\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )
        let stagedRoot = transactionRoot.appending(
            path: "staged",
            directoryHint: .isDirectory
        )
        let backupRoot = transactionRoot.appending(
            path: "backups",
            directoryHint: .isDirectory
        )
        var reservedTargets: Set<String> = []
        var plans: [TransactionPlan] = []
        for (index, pair) in zip(items, duplicateHandling).enumerated() {
            let (item, handling) = pair
            let values = try item.sourceURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize != nil
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            let desired = try desiredURL(
                in: root,
                filename: item.filename,
                fileExtension: item.sourceURL.pathExtension
            )
            guard let target = try resolvedTransactionCollision(
                desiredURL: desired,
                videoID: videoID,
                handling: handling,
                reservedTargets: reservedTargets
            ) else {
                return .duplicateSkipped
            }
            let targetKey = target.standardizedFileURL.path
            guard reservedTargets.insert(targetKey).inserted else {
                throw IllucetError.filesDestinationUnavailable
            }
            plans.append(
                TransactionPlan(
                    item: item,
                    handling: handling,
                    targetURL: target,
                    targetExistedAtPreflight:
                        fileManager.fileExists(atPath: target.path),
                    stagedURL: stagedRoot.appending(path: "\(index).partial"),
                    backupURL: backupRoot.appending(path: "\(index).backup")
                )
            )
        }

        try fileManager.createDirectory(
            at: stagedRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: true
        )
        if destination == .appDocuments {
            try BackgroundFileProtection.protect(root, under: root, fileManager: fileManager)
            try BackgroundFileProtection.protect(stagedRoot, under: root, fileManager: fileManager)
        }
        var committed: Set<Int> = []
        var backedUp: Set<Int> = []
        do {
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                try transactionObserver?(.willStage(index))
                try fileManager.copyItem(
                    at: plan.item.sourceURL,
                    to: plan.stagedURL
                )
                guard try verifiedCopy(
                    plan.stagedURL,
                    matches: plan.item.sourceURL
                ) else {
                    throw IllucetError.filesDestinationUnavailable
                }
                try transactionObserver?(.didStage(index))
            }
            try Task.checkCancellation()
            try transactionObserver?(.stagingComplete)

            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                try transactionObserver?(.willCommit(index))
                let targetExists = fileManager.fileExists(
                    atPath: plan.targetURL.path
                )
                guard targetExists == plan.targetExistedAtPreflight else {
                    throw IllucetError.filesDestinationUnavailable
                }
                if targetExists {
                    guard plan.handling == .overwrite else {
                        throw IllucetError.filesDestinationUnavailable
                    }
                    try fileManager.moveItem(
                        at: plan.targetURL,
                        to: plan.backupURL
                    )
                    backedUp.insert(index)
                }
                try fileManager.moveItem(
                    at: plan.stagedURL,
                    to: plan.targetURL
                )
                committed.insert(index)
                if destination == .appDocuments {
                    try BackgroundFileProtection.protect(plan.targetURL, under: root, fileManager: fileManager)
                }
                try transactionObserver?(.didCommit(index))
            }
            for plan in plans {
                guard try verifiedCopy(
                    plan.targetURL,
                    matches: plan.item.sourceURL
                ) else {
                    throw IllucetError.filesDestinationUnavailable
                }
            }
        } catch {
            let affected = committed.union(backedUp).sorted(by: >)
            var rollbackFailed = false
            for index in affected {
                let plan = plans[index]
                do {
                    if committed.contains(index),
                       fileManager.fileExists(atPath: plan.targetURL.path) {
                        try fileManager.removeItem(at: plan.targetURL)
                    }
                    if backedUp.contains(index),
                       fileManager.fileExists(atPath: plan.backupURL.path) {
                        try fileManager.moveItem(
                            at: plan.backupURL,
                            to: plan.targetURL
                        )
                    }
                } catch {
                    rollbackFailed = true
                }
            }
            if !rollbackFailed {
                try? fileManager.removeItem(at: transactionRoot)
            }
            if rollbackFailed {
                throw IllucetError.filesDestinationUnavailable
            }
            throw error
        }
        // All finals are verified and committed. A partially failed recursive
        // backup cleanup cannot safely roll back: some originals may already
        // be gone. Retain any remaining backup folder and keep the new outputs.
        try? fileManager.removeItem(at: transactionRoot)
        return .committed(plans.map(\.targetURL))
    }

    func exportDirectory(
        sourceURL: URL,
        destination: ExportDestination,
        filename: String,
        folderBookmark: Data?,
        duplicateHandling: DuplicateHandling,
        videoID: String,
        relativeDirectory: String? = nil
    ) throws -> ExportResult {
        let values = try sourceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw IllucetError.filesDestinationUnavailable
        }
        let root: URL
        var scopedFolder: URL?
        var scopedAccess = false
        defer {
            if scopedAccess, let scopedFolder {
                securityScope.stopAccessing(scopedFolder)
            }
        }
        switch destination {
        case .appDocuments:
            root = try outputDirectory(
                beneath: outputDirectory(),
                relativeDirectory: relativeDirectory
            )
        case .filesFolder:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            scopedFolder = folder
            scopedAccess = securityScope.startAccessing(folder)
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            root = try outputDirectory(
                beneath: folder,
                relativeDirectory: relativeDirectory
            )
        default:
            throw IllucetError.filesDestinationUnavailable
        }
        let sanitized = FilenameSystem.sanitizeComponent(filename)
        guard !sanitized.isEmpty else {
            throw IllucetError.filesDestinationUnavailable
        }
        let desired = root.appending(
            path: sanitized,
            directoryHint: .isDirectory
        )
        guard let target = try resolvedDirectoryCollision(
            desiredURL: desired,
            videoID: videoID,
            handling: duplicateHandling
        ) else {
            return duplicateSkippedResult()
        }
        let partial = root.appending(
            path: ".\(sanitized).\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: partial)
            if fileManager.fileExists(atPath: target.path),
               duplicateHandling == .overwrite {
                _ = try fileManager.replaceItemAt(target, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: target)
            }
            return ExportResult(
                fileURL: target,
                photoAssetLocalIdentifiers: [],
                shareRequest: nil,
                outcome: .file
            )
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    func finishShare(
        jobID: UUID,
        state: ShareCompletionState
    ) throws {
        guard state == .completed || state == .cancelled else { return }
        let directory = shareDirectory(for: jobID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func exportCompanionImage(
        sourceURL: URL,
        filename: String,
        destination: ExportDestination,
        mediaFileURL: URL?,
        folderBookmark: Data?,
        duplicateHandling: DuplicateHandling,
        videoID: String,
        jobID: UUID,
        relativeDirectory: String? = nil
    ) async throws -> ExportResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw IllucetError.filesDestinationUnavailable
        }
        switch destination {
        case .appDocuments:
            guard let mediaFileURL else {
                throw IllucetError.filesDestinationUnavailable
            }
            guard let copied = try copy(
                sourceURL,
                to: mediaFileURL.deletingLastPathComponent(),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [],
                shareRequest: nil,
                outcome: .file
            )
        case .filesFolder:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            let scopedAccess = folder.startAccessingSecurityScopedResource()
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            defer {
                if scopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            guard let copied = try copy(
                sourceURL,
                to: outputDirectory(
                    beneath: folder,
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [],
                shareRequest: nil,
                outcome: .file
            )
        case .photos:
            let identifier = try await photoLibrary.saveAsset(
                at: sourceURL,
                kind: .image,
                originalFilename: FilenameSystem.sanitizeComponent(filename) + "." + sourceURL.pathExtension
            )
            return ExportResult(
                fileURL: nil,
                photoAssetLocalIdentifiers: [identifier],
                shareRequest: nil,
                outcome: .photos
            )
        case .filesAndPhotos:
            guard let folderBookmark else {
                throw IllucetError.filesDestinationUnavailable
            }
            let folder = try resolveFolder(folderBookmark)
            let scopedAccess = folder.startAccessingSecurityScopedResource()
            guard scopedAccess || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw IllucetError.filesDestinationUnavailable
            }
            defer {
                if scopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            guard let copied = try copy(
                sourceURL,
                to: outputDirectory(
                    beneath: folder,
                    relativeDirectory: relativeDirectory
                ),
                filename: filename,
                duplicateHandling: duplicateHandling,
                videoID: videoID
            ) else {
                return duplicateSkippedResult()
            }
            let identifier: String
            do {
                identifier = try await photoLibrary.saveAsset(
                    at: copied,
                    kind: .image,
                    originalFilename: FilenameSystem.sanitizeComponent(filename) + "." + copied.pathExtension
                )
            } catch {
                throw ExportError.filesSavedPhotosFailed(
                    fileURL: copied,
                    reason: String(error.localizedDescription.prefix(256))
                )
            }
            return ExportResult(
                fileURL: copied,
                photoAssetLocalIdentifiers: [identifier],
                shareRequest: nil,
                outcome: .filesAndPhotos
            )
        case .share:
            let staged = try stageShareCompanion(
                sourceURL,
                filename: filename,
                jobID: jobID
            )
            return ExportResult(
                fileURL: staged,
                photoAssetLocalIdentifiers: [],
                shareRequest: pendingShareRequest(
                    jobID: jobID,
                    title: filename
                ),
                outcome: .sharePending
            )
        case .askEveryTime:
            throw IllucetError.filesDestinationUnavailable
        }
    }

    func pendingShareRequest(
        jobID: UUID,
        title: String
    ) -> SharePresentationRequest? {
        let directory = shareDirectory(for: jobID)
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        let files = contents.filter {
            (try? $0.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return nil }
        return SharePresentationRequest(
            jobID: jobID,
            title: title,
            fileURLs: files
        )
    }

    func stageShareFileTransaction(
        items: [ExportFileTransactionItem],
        jobID: UUID,
        title: String
    ) throws -> SharePresentationRequest {
        guard !items.isEmpty,
              items.count <= Self.maximumTransactionItems
        else {
            throw IllucetError.filesDestinationUnavailable
        }
        let finalDirectory = shareDirectory(for: jobID)
        let parent = finalDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let transactionID = UUID().uuidString
        let stagedDirectory = parent.appending(
            path: ".\(jobID.uuidString).\(transactionID).partial",
            directoryHint: .isDirectory
        )
        let backupDirectory = parent.appending(
            path: ".\(jobID.uuidString).\(transactionID).backup",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        var filenames: [String] = []
        var reserved: Set<String> = []
        do {
            for item in items {
                try Task.checkCancellation()
                let values = try item.sourceURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true
                else {
                    throw IllucetError.filesDestinationUnavailable
                }
                let target = try desiredURL(
                    in: stagedDirectory,
                    filename: item.filename,
                    fileExtension: item.sourceURL.pathExtension
                )
                guard reserved.insert(
                    target.lastPathComponent.precomposedStringWithCanonicalMapping
                        .lowercased()
                ).inserted else {
                    throw IllucetError.filesDestinationUnavailable
                }
                try fileManager.copyItem(at: item.sourceURL, to: target)
                guard try verifiedCopy(target, matches: item.sourceURL) else {
                    throw IllucetError.filesDestinationUnavailable
                }
                filenames.append(target.lastPathComponent)
            }
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.moveItem(
                    at: finalDirectory,
                    to: backupDirectory
                )
            }
            do {
                try fileManager.moveItem(
                    at: stagedDirectory,
                    to: finalDirectory
                )
            } catch {
                if fileManager.fileExists(atPath: backupDirectory.path) {
                    try? fileManager.moveItem(
                        at: backupDirectory,
                        to: finalDirectory
                    )
                }
                throw error
            }
            try? fileManager.removeItem(at: backupDirectory)
            return SharePresentationRequest(
                jobID: jobID,
                title: title,
                fileURLs: filenames.map {
                    finalDirectory.appending(path: $0)
                }
            )
        } catch {
            try? fileManager.removeItem(at: stagedDirectory)
            if !fileManager.fileExists(atPath: finalDirectory.path),
               fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.moveItem(
                    at: backupDirectory,
                    to: finalDirectory
                )
            }
            throw error
        }
    }

    func exportSubtitleSidecars(
        sourceURLs: [URL],
        filenames: [String],
        destination: ExportDestination,
        mediaFileURL: URL?,
        folderBookmark: Data?,
        jobID: UUID
    ) throws -> [URL] {
        guard
            !sourceURLs.isEmpty,
            sourceURLs.count == filenames.count,
            let mediaFileURL
        else {
            throw SubtitlePipelineError.exportFailed
        }
        let directory = mediaFileURL.deletingLastPathComponent()
        var scopedFolder: URL?
        let stopAccessing: Bool
        switch destination {
        case .appDocuments:
            stopAccessing = false
        case .filesFolder, .filesAndPhotos:
            guard let folderBookmark else {
                throw SubtitlePipelineError.exportFailed
            }
            let folder = try resolveFolder(folderBookmark)
            let standardizedFolder = folder.standardizedFileURL
            let standardizedDirectory = directory.standardizedFileURL
            guard standardizedDirectory == standardizedFolder
                || standardizedDirectory.path.hasPrefix(
                    standardizedFolder.path + "/"
                )
            else {
                throw SubtitlePipelineError.exportFailed
            }
            scopedFolder = folder
            stopAccessing = folder.startAccessingSecurityScopedResource()
            guard stopAccessing || fileManager.isWritableFile(atPath: folder.path)
            else {
                throw SubtitlePipelineError.exportFailed
            }
        case .share:
            guard directory.standardizedFileURL
                == shareDirectory(for: jobID).standardizedFileURL
            else {
                throw SubtitlePipelineError.exportFailed
            }
            stopAccessing = false
        case .photos:
            throw SubtitlePipelineError.photosOnlyDestination
        case .askEveryTime:
            throw SubtitlePipelineError.exportFailed
        }
        defer {
            if stopAccessing {
                scopedFolder?.stopAccessingSecurityScopedResource()
            }
        }

        var published: [URL] = []
        do {
            for (source, filename) in zip(sourceURLs, filenames) {
                guard fileManager.fileExists(atPath: source.path) else {
                    throw SubtitlePipelineError.exportFailed
                }
                let target = directory.appending(path: filename)
                guard target.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL,
                    !fileManager.fileExists(atPath: target.path)
                else {
                    throw SubtitlePipelineError.sidecarCollision
                }
                let partial = target.appendingPathExtension(
                    "\(UUID().uuidString).partial"
                )
                do {
                    try fileManager.copyItem(at: source, to: partial)
                    try fileManager.moveItem(at: partial, to: target)
                } catch {
                    try? fileManager.removeItem(at: partial)
                    throw SubtitlePipelineError.exportFailed
                }
                published.append(target)
            }
            return published
        } catch {
            for URL in published {
                try? fileManager.removeItem(at: URL)
            }
            throw error
        }
    }

    func discardPendingShare(jobID: UUID) throws {
        let directory = shareDirectory(for: jobID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func outputDirectory() throws -> URL {
        let root = documentsRootURL ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "Downloads",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    /// Serialized with exports so cleanup cannot remove a transaction mid-commit.
    /// Only the app's Downloads directory is owned by this operation.
    func deleteAppDownloads() throws -> Int {
        let root = try outputDirectory()
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let children = try fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)
        var removed = 0
        for child in children {
            // Removing a symlink unlinks it; never traverse its target.
            try fileManager.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    private func preflight(
        in directory: URL,
        filename: String,
        fileExtension: String
    ) throws -> ExportPreflight {
        let desired = try desiredURL(
            in: directory,
            filename: filename,
            fileExtension: fileExtension
        )
        return ExportPreflight(
            desiredURL: desired,
            hasCollision: fileManager.fileExists(atPath: desired.path)
        )
    }

    private func outputDirectory(
        beneath root: URL,
        relativeDirectory: String?
    ) throws -> URL {
        guard let relativeDirectory else {
            return root
        }
        let sanitized = FilenameSystem.sanitizeComponent(
            relativeDirectory
        )
        guard !sanitized.isEmpty, sanitized == relativeDirectory else {
            throw IllucetError.filesDestinationUnavailable
        }
        let standardizedRoot = root.standardizedFileURL
        let directory = standardizedRoot.appending(
            path: sanitized,
            directoryHint: .isDirectory
        ).standardizedFileURL
        guard directory.path.hasPrefix(
            standardizedRoot.path + "/"
        ) else {
            throw IllucetError.filesDestinationUnavailable
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func resolveFolder(_ bookmark: Data) throws -> URL {
        var stale = false
        let URL: URL
        do {
            URL = try Foundation.URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw IllucetError.filesDestinationUnavailable
        }
        guard !stale, URL.hasDirectoryPath else {
            throw IllucetError.filesDestinationUnavailable
        }
        return URL
    }

    private func copy(
        _ source: URL,
        to directory: URL,
        filename: String,
        duplicateHandling: DuplicateHandling,
        videoID: String
    ) throws -> URL? {
        let desired = try desiredURL(
            in: directory,
            filename: filename,
            fileExtension: source.pathExtension
        )
        guard let target = try FilenameSystem.resolvedCollisionURL(
            desiredURL: desired,
            videoID: videoID,
            handling: duplicateHandling,
            fileManager: fileManager
        ) else {
            return nil
        }
        let partial = target.appendingPathExtension(
            "\(UUID().uuidString).partial"
        )
        do {
            try fileManager.copyItem(at: source, to: partial)
            if fileManager.fileExists(atPath: target.path),
               duplicateHandling == .overwrite {
                _ = try fileManager.replaceItemAt(
                    target,
                    withItemAt: partial
                )
            } else {
                try fileManager.moveItem(at: partial, to: target)
            }
            return target
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func resolvedTransactionCollision(
        desiredURL: URL,
        videoID: String,
        handling: DuplicateHandling,
        reservedTargets: Set<String>
    ) throws -> URL? {
        func available(_ URL: URL) -> Bool {
            !fileManager.fileExists(atPath: URL.path)
                && !reservedTargets.contains(URL.standardizedFileURL.path)
        }
        if available(desiredURL) {
            return desiredURL
        }
        switch handling {
        case .ask:
            throw ExportError.duplicateDecisionRequired(desiredURL)
        case .skip:
            return nil
        case .overwrite:
            guard !reservedTargets.contains(
                desiredURL.standardizedFileURL.path
            ) else {
                throw IllucetError.filesDestinationUnavailable
            }
            return desiredURL
        case .addVideoID:
            let suffix = FilenameSystem.sanitizeComponent(videoID)
            guard !suffix.isEmpty else {
                throw IllucetError.filesDestinationUnavailable
            }
            let stem = desiredURL.deletingPathExtension().lastPathComponent
            let identified = desiredURL.deletingLastPathComponent()
                .appending(path: "\(stem)-\(suffix)")
                .appendingPathExtension(desiredURL.pathExtension)
            if available(identified) {
                return identified
            }
            return try resolvedTransactionCollision(
                desiredURL: identified,
                videoID: videoID,
                handling: .addNumber,
                reservedTargets: reservedTargets
            )
        case .addNumber:
            let stem = desiredURL.deletingPathExtension().lastPathComponent
            let directory = desiredURL.deletingLastPathComponent()
            for index in 2 ... 9_999 {
                let candidate = directory
                    .appending(path: "\(stem) \(index)")
                    .appendingPathExtension(desiredURL.pathExtension)
                if available(candidate) {
                    return candidate
                }
            }
            throw IllucetError.filesDestinationUnavailable
        }
    }

    private func verifiedCopy(
        _ candidate: URL,
        matches source: URL
    ) throws -> Bool {
        let candidateValues = try candidate.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        let sourceValues = try source.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard candidateValues.isRegularFile == true,
              candidateValues.isSymbolicLink != true,
              candidateValues.fileSize == sourceValues.fileSize
        else {
            return false
        }
        return fileManager.contentsEqual(
            atPath: candidate.path,
            andPath: source.path
        )
    }

    private func resolvedDirectoryCollision(
        desiredURL: URL,
        videoID: String,
        handling: DuplicateHandling
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: desiredURL.path) else {
            return desiredURL
        }
        switch handling {
        case .ask:
            throw ExportError.duplicateDecisionRequired(desiredURL)
        case .skip:
            return nil
        case .overwrite:
            return desiredURL
        case .addVideoID:
            let suffix = FilenameSystem.sanitizeComponent(videoID)
            guard !suffix.isEmpty else {
                throw IllucetError.filesDestinationUnavailable
            }
            return try resolvedDirectoryCollision(
                desiredURL: desiredURL.deletingLastPathComponent().appending(
                    path: "\(desiredURL.lastPathComponent)-\(suffix)",
                    directoryHint: .isDirectory
                ),
                videoID: videoID,
                handling: .addNumber
            )
        case .addNumber:
            for index in 2 ... 9_999 {
                let candidate = desiredURL.deletingLastPathComponent()
                    .appending(
                        path: "\(desiredURL.lastPathComponent) \(index)",
                        directoryHint: .isDirectory
                    )
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            throw IllucetError.filesDestinationUnavailable
        }
    }

    private func desiredURL(
        in directory: URL,
        filename: String,
        fileExtension: String
    ) throws -> URL {
        let sanitized = FilenameSystem.sanitizeComponent(filename)
        let sanitizedExtension = FilenameSystem.sanitizeComponent(
            fileExtension.lowercased()
        )
        guard !sanitized.isEmpty, !sanitizedExtension.isEmpty else {
            throw IllucetError.filesDestinationUnavailable
        }
        return directory
            .appending(path: sanitized)
            .appendingPathExtension(sanitizedExtension)
    }

    private func stageShare(
        _ source: URL,
        filename: String,
        jobID: UUID
    ) throws -> URL {
        let directory = shareDirectory(for: jobID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = try desiredURL(
            in: directory,
            filename: filename,
            fileExtension: source.pathExtension
        )
        let partial = target.appendingPathExtension("partial")
        do {
            try fileManager.copyItem(at: source, to: partial)
            try fileManager.moveItem(at: partial, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func stageShareCompanion(
        _ source: URL,
        filename: String,
        jobID: UUID
    ) throws -> URL {
        let directory = shareDirectory(for: jobID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = try desiredURL(
            in: directory,
            filename: filename,
            fileExtension: source.pathExtension
        )
        let partial = target.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.copyItem(at: source, to: partial)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: partial, to: target)
            return target
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func shareDirectory(for jobID: UUID) -> URL {
        let root = shareRootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: AppIdentity.storageDirectoryName,
            directoryHint: .isDirectory
        ).appending(
            path: "PendingShares",
            directoryHint: .isDirectory
        )
        return root.appending(
            path: jobID.uuidString,
            directoryHint: .isDirectory
        )
    }

    private func duplicateSkippedResult() -> ExportResult {
        ExportResult(
            fileURL: nil,
            photoAssetLocalIdentifiers: [],
            shareRequest: nil,
            outcome: .duplicateSkipped
        )
    }
}

enum ExportError: LocalizedError, Sendable {
    case duplicateDecisionRequired(URL)
    case filesSavedPhotosFailed(fileURL: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .duplicateDecisionRequired:
            "A file with this name already exists. Choose how Illucet should handle it."
        case let .filesSavedPhotosFailed(_, reason):
            "The file was saved to Files, but Photos import failed. \(reason)"
        }
    }
}
