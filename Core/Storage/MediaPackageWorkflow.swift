import Foundation

struct MediaPackageResult: Equatable, Sendable {
    let folderURL: URL
    let fileCount: Int
    let totalBytes: UInt64
    let relativePaths: [String]
}

struct MediaPackageZIPResult: Equatable, Sendable {
    let archiveURL: URL
    let writeResult: ZIPArchiveWriteResult
}

enum MediaPackageWorkflowError: Error, Equatable {
    case invalidPackage
    case duplicatePath(String)
    case verificationFailed
}

final class MediaPackageWorkflow: @unchecked Sendable {
    private struct PackageInfo: Codable {
        let schemaVersion: Int
        let videoID: String
        let title: String
        let channel: String?
        let uploader: String?
        let durationSeconds: Double?
        let uploadDate: String?
        let mediaFilename: String
        let subtitleCount: Int
        let chapterCount: Int
    }

    private struct ManifestEntry: Codable, Equatable {
        let path: String
        let size: UInt64
        let crc32: UInt32
    }

    private struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let entries: [ManifestEntry]
        let totalBytes: UInt64
    }

    private let writer: ZIPArchiveWriter
    private let fileManager: FileManager

    init(
        writer: ZIPArchiveWriter = ZIPArchiveWriter(),
        fileManager: FileManager = .default
    ) {
        self.writer = writer
        self.fileManager = fileManager
    }

    func buildFolder(
        mediaURL: URL,
        thumbnailURL: URL?,
        subtitles: [PreparedSubtitleSidecar],
        chapterSplits: [ChapterSplitOutput],
        chapters: [MediaChapter],
        metadata: MediaMetadata,
        packageName: String,
        temporaryRoot: URL,
        durationSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> MediaPackageResult {
        guard fileManager.fileExists(atPath: mediaURL.path),
              subtitles.count <= SubtitleSelectionPlanner.maximumSelections,
              chapters.count <= ChapterWorkflow.maximumChapterCount
        else {
            throw MediaPackageWorkflowError.invalidPackage
        }
        let safeName = FilenameSystem.sanitizeComponent(packageName)
        guard !safeName.isEmpty else {
            throw MediaPackageWorkflowError.invalidPackage
        }
        let staging = temporaryRoot.appending(
            path: ".package-partial-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let final = temporaryRoot.appending(
            path: "\(safeName) Package",
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: final.path) else {
            throw MediaPackageWorkflowError.invalidPackage
        }
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        do {
            var used: Set<String> = []
            var copied = 0
            let totalWork = max(
                1,
                5 + (thumbnailURL == nil ? 0 : 1)
                    + subtitles.count + chapterSplits.count
            )
            func copy(_ source: URL, path: String) throws {
                try Self.validate(relativePath: path)
                guard used.insert(path).inserted else {
                    throw MediaPackageWorkflowError.duplicatePath(path)
                }
                let destination = staging.appending(path: path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                copied += 1
                progress(Double(copied) / Double(totalWork))
            }
            try copy(
                mediaURL,
                path: "media/\(mediaURL.lastPathComponent)"
            )
            if let thumbnailURL {
                try copy(
                    thumbnailURL,
                    path: "thumbnail/\(thumbnailURL.lastPathComponent)"
                )
            }
            let subtitleNames = try SubtitleFilenamePlanner.filenames(
                mediaURL: mediaURL,
                sidecars: subtitles
            )
            for (subtitle, name) in zip(subtitles, subtitleNames) {
                try copy(
                    subtitle.temporaryURL,
                    path: "subtitles/\(name)"
                )
            }
            for split in chapterSplits {
                try copy(
                    split.fileURL,
                    path: "chapters/\(split.filename).\(split.fileURL.pathExtension)"
                )
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let info = PackageInfo(
                schemaVersion: 1,
                videoID: metadata.videoID,
                title: metadata.title,
                channel: metadata.channel,
                uploader: metadata.uploader,
                durationSeconds: durationSeconds ?? metadata.durationSeconds,
                uploadDate: metadata.uploadDate,
                mediaFilename: mediaURL.lastPathComponent,
                subtitleCount: subtitles.count,
                chapterCount: chapters.count
            )
            try write(
                encoder.encode(info),
                path: "metadata/info.json",
                staging: staging,
                used: &used
            )
            copied += 1
            progress(Double(copied) / Double(totalWork))
            let description = String(
                (metadata.description ?? "").prefix(1_048_576)
            )
            try write(
                Data(description.utf8),
                path: "metadata/description.txt",
                staging: staging,
                used: &used
            )
            copied += 1
            progress(Double(copied) / Double(totalWork))
            try write(
                encoder.encode(chapters),
                path: "metadata/chapters.json",
                staging: staging,
                used: &used
            )
            copied += 1
            progress(Double(copied) / Double(totalWork))

            let entries = try Self.regularFiles(
                beneath: staging,
                fileManager: fileManager
            ).map { source -> ManifestEntry in
                let size = try Self.fileSize(source.fileURL)
                return ManifestEntry(
                    path: source.archivePath,
                    size: size,
                    crc32: try Self.fileCRC32(source.fileURL)
                )
            }
            let totalBytes = try entries.reduce(UInt64(0)) {
                let (sum, overflow) = $0.addingReportingOverflow($1.size)
                guard !overflow else {
                    throw MediaPackageWorkflowError.invalidPackage
                }
                return sum
            }
            try write(
                encoder.encode(
                    Manifest(
                        schemaVersion: 1,
                        entries: entries,
                        totalBytes: totalBytes
                    )
                ),
                path: "manifest.json",
                staging: staging,
                used: &used
            )
            copied += 1
            progress(Double(copied) / Double(totalWork))
            try fileManager.moveItem(at: staging, to: final)
            let finalized = try Self.regularFiles(
                beneath: final,
                fileManager: fileManager
            )
            let finalizedBytes = try finalized.reduce(UInt64(0)) {
                let size = try Self.fileSize($1.fileURL)
                let (sum, overflow) = $0.addingReportingOverflow(size)
                guard !overflow else {
                    throw MediaPackageWorkflowError.invalidPackage
                }
                return sum
            }
            guard finalized.count == entries.count + 1,
                  finalized.contains(where: {
                      $0.archivePath == "manifest.json"
                  })
            else {
                throw MediaPackageWorkflowError.verificationFailed
            }
            progress(1)
            return MediaPackageResult(
                folderURL: final,
                fileCount: finalized.count,
                totalBytes: finalizedBytes,
                relativePaths: finalized.map(\.archivePath)
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: final)
            throw error
        }
    }

    func zipFinalizedFolder(
        _ package: MediaPackageResult,
        to archiveURL: URL,
        progress: @escaping @Sendable (ZIPArchiveProgress) -> Void
    ) async throws -> MediaPackageZIPResult {
        let sources = try Self.regularFiles(
            beneath: package.folderURL,
            fileManager: fileManager
        )
        try Self.verifyFinalizedPackage(
            package,
            sources: sources
        )
        let result = try await writer.write(
            sources: sources,
            to: archiveURL,
            progress: progress
        )
        guard result.entryCount == package.fileCount else {
            try? fileManager.removeItem(at: archiveURL)
            throw MediaPackageWorkflowError.verificationFailed
        }
        return MediaPackageZIPResult(
            archiveURL: archiveURL,
            writeResult: result
        )
    }

    private func write(
        _ data: Data,
        path: String,
        staging: URL,
        used: inout Set<String>
    ) throws {
        try Self.validate(relativePath: path)
        guard used.insert(path).inserted else {
            throw MediaPackageWorkflowError.duplicatePath(path)
        }
        let destination = staging.appending(path: path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .withoutOverwriting)
    }

    private static func regularFiles(
        beneath root: URL,
        fileManager: FileManager
    ) throws -> [ZIPArchiveSource] {
        guard root.hasDirectoryPath,
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ],
                  options: []
              )
        else {
            throw MediaPackageWorkflowError.invalidPackage
        }
        var result: [ZIPArchiveSource] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw MediaPackageWorkflowError.invalidPackage
            }
            guard values.isRegularFile == true else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw MediaPackageWorkflowError.invalidPackage
            }
            let relative = String(path.dropFirst(prefix.count))
            try validate(relativePath: relative)
            result.append(
                ZIPArchiveSource(
                    archivePath: relative,
                    fileURL: fileURL
                )
            )
        }
        return result.sorted { $0.archivePath < $1.archivePath }
    }

    private static func validate(relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw MediaPackageWorkflowError.invalidPackage
        }
    }

    private static func fileSize(_ URL: URL) throws -> UInt64 {
        let values = try URL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL.path
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = attributes[.size] as? NSNumber
        else {
            throw MediaPackageWorkflowError.invalidPackage
        }
        return size.uint64Value
    }

    private static func fileCRC32(_ URL: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: URL)
        defer { try? input.close() }
        var CRC = CRC32Accumulator()
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576),
                  !data.isEmpty
            else {
                break
            }
            CRC.update(data)
        }
        return CRC.finalized
    }

    private static func verifyFinalizedPackage(
        _ package: MediaPackageResult,
        sources: [ZIPArchiveSource]
    ) throws {
        guard sources.count == package.fileCount,
              sources.map(\.archivePath) == package.relativePaths,
              let manifestSource = sources.first(where: {
                  $0.archivePath == "manifest.json"
              })
        else {
            throw MediaPackageWorkflowError.verificationFailed
        }
        let sizes = try sources.map { source in
            try fileSize(source.fileURL)
        }
        let actualTotal = try sizes.reduce(UInt64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else {
                throw MediaPackageWorkflowError.verificationFailed
            }
            return sum
        }
        guard actualTotal == package.totalBytes,
              let manifestSize = try? fileSize(manifestSource.fileURL),
              manifestSize <= 8 * 1_024 * 1_024
        else {
            throw MediaPackageWorkflowError.verificationFailed
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(
                contentsOf: manifestSource.fileURL,
                options: [.mappedIfSafe]
            )
        )
        let expected = try zip(sources, sizes).compactMap {
            source, size -> ManifestEntry? in
            guard source.archivePath != "manifest.json" else {
                return nil
            }
            return ManifestEntry(
                path: source.archivePath,
                size: size,
                crc32: try fileCRC32(source.fileURL)
            )
        }
        let expectedTotal = try expected.reduce(UInt64(0)) {
            total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow else {
                throw MediaPackageWorkflowError.verificationFailed
            }
            return sum
        }
        guard manifest.schemaVersion == 1,
              manifest.entries == expected,
              manifest.totalBytes == expectedTotal
        else {
            throw MediaPackageWorkflowError.verificationFailed
        }
    }
}
