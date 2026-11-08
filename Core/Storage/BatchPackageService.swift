import Foundation

struct BatchPackageResult: Equatable, Sendable {
    let packageURL: URL?
    let outcome: ExportOutcome
    let entryCount: Int
    let sourceBytes: UInt64
    let archiveBytes: UInt64
}

enum BatchPackageServiceError: LocalizedError, Equatable, Sendable {
    case batchNotFinal
    case notZIPBatch
    case unsupportedDestination
    case missingCompletedOutput(String)
    case duplicateSkipped

    var errorDescription: String? {
        switch self {
        case .batchNotFinal:
            "The batch is still active. ZIP packaging starts only after every item reaches a final state."
        case .notZIPBatch:
            "This batch was not configured to create a ZIP archive."
        case .unsupportedDestination:
            "ZIP batches can be saved only in Illucet or a selected Files folder."
        case let .missingCompletedOutput(title):
            "The completed output for \(title) is no longer available."
        case .duplicateSkipped:
            "The ZIP was skipped because an archive with the same name already exists."
        }
    }
}

actor BatchPackageService {
    private let writer: ZIPArchiveWriter
    private let exporter: ExportManager
    private let fileManager: FileManager
    private let temporaryRootURL: URL?

    init(
        writer: ZIPArchiveWriter = ZIPArchiveWriter(),
        exporter: ExportManager,
        fileManager: FileManager = .default,
        temporaryRootURL: URL? = nil
    ) {
        self.writer = writer
        self.exporter = exporter
        self.fileManager = fileManager
        self.temporaryRootURL = temporaryRootURL
    }

    func createAndExport(
        batch: DownloadBatch,
        jobs: [DownloadJob],
        filesFolderBookmark: Data?,
        duplicateHandling: DuplicateHandling
    ) async throws -> BatchPackageResult {
        guard batch.state == .completed else {
            throw BatchPackageServiceError.batchNotFinal
        }
        guard batch.destinationStructure == .zipArchive else {
            throw BatchPackageServiceError.notZIPBatch
        }
        guard [
            ExportDestination.appDocuments,
            .filesFolder,
        ].contains(batch.configuration.destination) else {
            throw BatchPackageServiceError.unsupportedDestination
        }

        let scopedFolder = try filesFolderBookmark.map(resolveFolder)
        let scopedAccess = scopedFolder?
            .startAccessingSecurityScopedResource() ?? false
        defer {
            if scopedAccess {
                scopedFolder?.stopAccessingSecurityScopedResource()
            }
        }

        let sources = try packageSources(batch: batch, jobs: jobs)
        let operationRoot = (temporaryRootURL
            ?? fileManager.temporaryDirectory.appending(
                path: AppIdentity.storageDirectoryName,
                directoryHint: .isDirectory
            ).appending(
                path: "BatchPackages",
                directoryHint: .isDirectory
            ))
            .appending(
                path: "\(batch.id.uuidString)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try fileManager.createDirectory(
            at: operationRoot,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: operationRoot) }

        let archiveName = FilenameSystem.sanitizeComponent(
            "\(batch.title) Playlist"
        )
        let archiveURL = operationRoot.appending(
            path: archiveName.isEmpty
                ? "Playlist Package.zip"
                : "\(archiveName).zip"
        )
        let writeResult = try await writer.write(
            sources: sources,
            to: archiveURL
        )
        try Task.checkCancellation()
        let exportResult = try await exporter.export(
            sourceURL: archiveURL,
            destination: batch.configuration.destination,
            filename: archiveURL.deletingPathExtension()
                .lastPathComponent,
            folderBookmark: filesFolderBookmark,
            duplicateHandling: duplicateHandling,
            videoID: batch.playlistID,
            jobID: batch.id,
            title: batch.title,
            assetKind: .image
        )
        guard !exportResult.skippedDuplicate else {
            throw BatchPackageServiceError.duplicateSkipped
        }
        return BatchPackageResult(
            packageURL: exportResult.fileURL,
            outcome: exportResult.outcome,
            entryCount: writeResult.entryCount,
            sourceBytes: writeResult.sourceBytes,
            archiveBytes: writeResult.archiveBytes
        )
    }

    private func packageSources(
        batch: DownloadBatch,
        jobs: [DownloadJob]
    ) throws -> [ZIPArchiveSource] {
        let jobsByID = Dictionary(
            uniqueKeysWithValues: jobs.map { ($0.id, $0) }
        )
        var usedPaths: Set<String> = []
        var sources: [ZIPArchiveSource] = []
        for item in batch.items where item.state == .completed {
            guard let jobID = item.jobID,
                  let job = jobsByID[jobID],
                  job.state == .completed,
                  let outputURL = job.outputURL,
                  fileManager.fileExists(atPath: outputURL.path)
            else {
                throw BatchPackageServiceError.missingCompletedOutput(
                    item.title
                )
            }
            var path = outputURL.lastPathComponent
            if usedPaths.contains(path) {
                path = "\(String(format: "%0\(batch.filenameIndexWidth)d", item.playlistIndex)) \(path)"
            }
            guard usedPaths.insert(path).inserted else {
                throw ZIPArchiveWriterError.duplicateArchivePath(path)
            }
            sources.append(
                ZIPArchiveSource(
                    archivePath: path,
                    fileURL: outputURL
                )
            )
        }
        guard !sources.isEmpty else {
            throw ZIPArchiveWriterError.noSources
        }
        return sources
    }

    private func resolveFolder(_ bookmark: Data) throws -> URL {
        var stale = false
        let URL = try Foundation.URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, URL.hasDirectoryPath else {
            throw IllucetError.filesDestinationUnavailable
        }
        return URL
    }
}
