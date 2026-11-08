import Foundation

struct ZIPArchiveSource: Equatable, Sendable {
    let archivePath: String
    let fileURL: URL
}

struct ZIPArchiveWriteResult: Equatable, Sendable {
    let entryCount: Int
    let sourceBytes: UInt64
    let archiveBytes: UInt64
}

struct ZIPArchiveProgress: Equatable, Sendable {
    let completedSourceBytes: UInt64
    let totalSourceBytes: UInt64
    let completedEntries: Int
    let totalEntries: Int

    var fraction: Double {
        guard totalSourceBytes > 0 else {
            return totalEntries == 0
                ? 0
                : Double(completedEntries) / Double(totalEntries)
        }
        return min(
            max(
                Double(completedSourceBytes) / Double(totalSourceBytes),
                0
            ),
            1
        )
    }
}

enum ZIPArchiveWriterError: LocalizedError, Equatable, Sendable {
    case noSources
    case tooManyEntries
    case invalidArchivePath(String)
    case duplicateArchivePath(String)
    case missingSource(String)
    case unsupportedSourceSize(String)
    case couldNotCreateArchive
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .noSources:
            "There are no completed files to package."
        case .tooManyEntries:
            "The package contains too many files."
        case let .invalidArchivePath(path):
            "The ZIP entry name is invalid: \(path)"
        case let .duplicateArchivePath(path):
            "Two package files have the same name: \(path)"
        case let .missingSource(path):
            "A completed package file is missing: \(path)"
        case let .unsupportedSourceSize(path):
            "The package file size could not be read: \(path)"
        case .couldNotCreateArchive:
            "Illucet could not create the ZIP archive."
        case .verificationFailed:
            "The completed ZIP archive did not pass structural verification."
        }
    }
}

actor ZIPArchiveWriter {
    private struct CentralEntry {
        let path: String
        let pathData: Data
        let CRC32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
        let usesZIP64: Bool
    }

    private struct EntryRecord {
        let pathData: Data
        let CRC32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
        let usesZIP64: Bool
    }

    private let fileManager: FileManager
    private let forceZIP64: Bool

    init(
        fileManager: FileManager = .default,
        forceZIP64ForTesting: Bool = false
    ) {
        self.fileManager = fileManager
        forceZIP64 = forceZIP64ForTesting
    }

    func write(
        sources: [ZIPArchiveSource],
        to destinationURL: URL,
        progress: @escaping @Sendable (ZIPArchiveProgress) -> Void = { _ in }
    ) throws -> ZIPArchiveWriteResult {
        guard !sources.isEmpty else {
            throw ZIPArchiveWriterError.noSources
        }
        guard sources.count < Int(UInt16.max) else {
            throw ZIPArchiveWriterError.tooManyEntries
        }
        let normalized = try normalizedSources(sources)
        let sourceSizes = try normalized.map(sourceSize)
        let totalSourceBytes = try sourceSizes.reduce(UInt64(0), adding)
        progress(
            ZIPArchiveProgress(
                completedSourceBytes: 0,
                totalSourceBytes: totalSourceBytes,
                completedEntries: 0,
                totalEntries: normalized.count
            )
        )
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.createFile(
                  atPath: destinationURL.path,
                  contents: nil
              ),
              let output = try? FileHandle(forWritingTo: destinationURL)
        else {
            throw ZIPArchiveWriterError.couldNotCreateArchive
        }
        do {
            defer { try? output.close() }
            var records: [EntryRecord] = []
            var offset: UInt64 = 0
            var sourceBytes: UInt64 = 0
            for (index, source) in normalized.enumerated() {
                try Task.checkCancellation()
                let size = sourceSizes[index]
                sourceBytes = try adding(sourceBytes, size)
                let pathData = Data(source.archivePath.utf8)
                let usesZIP64 = forceZIP64
                    || size >= UInt64(UInt32.max)
                    || offset >= UInt64(UInt32.max)
                let localHeader = localHeader(
                    pathData: pathData,
                    size: size,
                    usesZIP64: usesZIP64
                )
                try output.write(contentsOf: localHeader)
                let localHeaderOffset = offset
                offset = try adding(
                    offset,
                    UInt64(localHeader.count)
                )

                let checksum = try stream(
                    source.fileURL,
                    to: output,
                    expectedSize: size
                ) { streamed in
                    progress(
                        ZIPArchiveProgress(
                            completedSourceBytes: sourceBytes - size
                                + streamed,
                            totalSourceBytes: totalSourceBytes,
                            completedEntries: index,
                            totalEntries: normalized.count
                        )
                    )
                }
                offset = try adding(offset, size)
                let descriptor = dataDescriptor(
                    CRC32: checksum,
                    size: size,
                    usesZIP64: usesZIP64
                )
                try output.write(contentsOf: descriptor)
                offset = try adding(
                    offset,
                    UInt64(descriptor.count)
                )
                records.append(
                    EntryRecord(
                        pathData: pathData,
                        CRC32: checksum,
                        size: size,
                        localHeaderOffset: localHeaderOffset,
                        usesZIP64: usesZIP64
                    )
                )
                progress(
                    ZIPArchiveProgress(
                        completedSourceBytes: sourceBytes,
                        totalSourceBytes: totalSourceBytes,
                        completedEntries: index + 1,
                        totalEntries: normalized.count
                    )
                )
            }

            let centralOffset = offset
            for record in records {
                let header = centralDirectoryHeader(record)
                try output.write(contentsOf: header)
                offset = try adding(offset, UInt64(header.count))
            }
            let centralSize = offset - centralOffset
            let ending = endRecords(
                entryCount: UInt64(records.count),
                centralSize: centralSize,
                centralOffset: centralOffset,
                forceZIP64: forceZIP64
            )
            try output.write(contentsOf: ending)
            offset = try adding(offset, UInt64(ending.count))
            try output.synchronize()
            try output.close()
            let verified = try verifyCompletedArchive(
                at: destinationURL,
                expectedSources: normalized
            )
            guard verified.entryCount == records.count,
                  verified.sourceBytes == sourceBytes,
                  verified.archiveBytes == offset
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            return verified
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func normalizedSources(
        _ sources: [ZIPArchiveSource]
    ) throws -> [ZIPArchiveSource] {
        var paths: Set<String> = []
        return try sources.map { source in
            let path = source.archivePath.precomposedStringWithCanonicalMapping
            guard !path.isEmpty,
                  path.utf8.count <= Int(UInt16.max),
                  !path.hasPrefix("/"),
                  !path.hasSuffix("/"),
                  !path.contains("\\"),
                  !path.split(separator: "/").contains("..")
            else {
                throw ZIPArchiveWriterError.invalidArchivePath(
                    source.archivePath
                )
            }
            guard paths.insert(path).inserted else {
                throw ZIPArchiveWriterError.duplicateArchivePath(path)
            }
            guard fileManager.fileExists(atPath: source.fileURL.path) else {
                throw ZIPArchiveWriterError.missingSource(path)
            }
            return ZIPArchiveSource(
                archivePath: path,
                fileURL: source.fileURL
            )
        }
    }

    private func sourceSize(
        _ source: ZIPArchiveSource
    ) throws -> UInt64 {
        let values = try source.fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: source.fileURL.path
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = attributes[.size] as? NSNumber
        else {
            throw ZIPArchiveWriterError.unsupportedSourceSize(
                source.archivePath
            )
        }
        return size.uint64Value
    }

    private func stream(
        _ sourceURL: URL,
        to output: FileHandle,
        expectedSize: UInt64,
        progress: (UInt64) -> Void
    ) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var CRC = CRC32Accumulator()
        var readBytes: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1_048_576),
                  !chunk.isEmpty
            else {
                break
            }
            CRC.update(chunk)
            readBytes = try adding(readBytes, UInt64(chunk.count))
            try output.write(contentsOf: chunk)
            progress(readBytes)
        }
        guard readBytes == expectedSize else {
            throw ZIPArchiveWriterError.unsupportedSourceSize(
                sourceURL.lastPathComponent
            )
        }
        return CRC.finalized
    }

    private func localHeader(
        pathData: Data,
        size: UInt64,
        usesZIP64: Bool
    ) -> Data {
        var extra = Data()
        if usesZIP64 {
            extra.appendLittleEndian(UInt16(0x0001))
            extra.appendLittleEndian(UInt16(16))
            extra.appendLittleEndian(size)
            extra.appendLittleEndian(size)
        }
        extra.append(unicodePathExtra(pathData))
        var data = Data()
        data.appendLittleEndian(UInt32(0x04034b50))
        data.appendLittleEndian(UInt16(usesZIP64 ? 45 : 20))
        data.appendLittleEndian(UInt16(0x0808))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0x0021))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(
            usesZIP64 ? UInt32.max : UInt32(0)
        )
        data.appendLittleEndian(
            usesZIP64 ? UInt32.max : UInt32(0)
        )
        data.appendLittleEndian(UInt16(pathData.count))
        data.appendLittleEndian(UInt16(extra.count))
        data.append(pathData)
        data.append(extra)
        return data
    }

    private func dataDescriptor(
        CRC32: UInt32,
        size: UInt64,
        usesZIP64: Bool
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x08074b50))
        data.appendLittleEndian(CRC32)
        if usesZIP64 {
            data.appendLittleEndian(size)
            data.appendLittleEndian(size)
        } else {
            data.appendLittleEndian(UInt32(size))
            data.appendLittleEndian(UInt32(size))
        }
        return data
    }

    private func centralDirectoryHeader(
        _ record: EntryRecord
    ) -> Data {
        let sizeNeedsZIP64 = record.usesZIP64
        let offsetNeedsZIP64 = record.usesZIP64
        var ZIP64Payload = Data()
        if sizeNeedsZIP64 {
            ZIP64Payload.appendLittleEndian(record.size)
            ZIP64Payload.appendLittleEndian(record.size)
        }
        if offsetNeedsZIP64 {
            ZIP64Payload.appendLittleEndian(record.localHeaderOffset)
        }
        var extra = Data()
        if !ZIP64Payload.isEmpty {
            extra.appendLittleEndian(UInt16(0x0001))
            extra.appendLittleEndian(UInt16(ZIP64Payload.count))
            extra.append(ZIP64Payload)
        }
        extra.append(unicodePathExtra(record.pathData))

        var data = Data()
        data.appendLittleEndian(UInt32(0x02014b50))
        data.appendLittleEndian(UInt16(45))
        data.appendLittleEndian(
            UInt16(record.usesZIP64 ? 45 : 20)
        )
        data.appendLittleEndian(UInt16(0x0808))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0x0021))
        data.appendLittleEndian(record.CRC32)
        data.appendLittleEndian(
            sizeNeedsZIP64 ? UInt32.max : UInt32(record.size)
        )
        data.appendLittleEndian(
            sizeNeedsZIP64 ? UInt32.max : UInt32(record.size)
        )
        data.appendLittleEndian(UInt16(record.pathData.count))
        data.appendLittleEndian(UInt16(extra.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(
            offsetNeedsZIP64
                ? UInt32.max
                : UInt32(record.localHeaderOffset)
        )
        data.append(record.pathData)
        data.append(extra)
        return data
    }

    private func unicodePathExtra(_ pathData: Data) -> Data {
        guard pathData.contains(where: { $0 >= 0x80 }) else {
            return Data()
        }
        var CRC = CRC32Accumulator()
        CRC.update(pathData)
        var payload = Data([1])
        payload.appendLittleEndian(CRC.finalized)
        payload.append(pathData)
        var extra = Data()
        extra.appendLittleEndian(UInt16(0x7075))
        extra.appendLittleEndian(UInt16(payload.count))
        extra.append(payload)
        return extra
    }

    private func endRecords(
        entryCount: UInt64,
        centralSize: UInt64,
        centralOffset: UInt64,
        forceZIP64: Bool
    ) -> Data {
        let needsZIP64 = forceZIP64
            || entryCount >= UInt64(UInt16.max)
            || centralSize >= UInt64(UInt32.max)
            || centralOffset >= UInt64(UInt32.max)
        var data = Data()
        if needsZIP64 {
            let ZIP64Offset = centralOffset + centralSize
            data.appendLittleEndian(UInt32(0x06064b50))
            data.appendLittleEndian(UInt64(44))
            data.appendLittleEndian(UInt16(45))
            data.appendLittleEndian(UInt16(45))
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(entryCount)
            data.appendLittleEndian(entryCount)
            data.appendLittleEndian(centralSize)
            data.appendLittleEndian(centralOffset)
            data.appendLittleEndian(UInt32(0x07064b50))
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(ZIP64Offset)
            data.appendLittleEndian(UInt32(1))
        }
        data.appendLittleEndian(UInt32(0x06054b50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(
            needsZIP64 ? UInt16.max : UInt16(entryCount)
        )
        data.appendLittleEndian(
            needsZIP64 ? UInt16.max : UInt16(entryCount)
        )
        data.appendLittleEndian(
            needsZIP64 ? UInt32.max : UInt32(centralSize)
        )
        data.appendLittleEndian(
            needsZIP64 ? UInt32.max : UInt32(centralOffset)
        )
        data.appendLittleEndian(UInt16(0))
        return data
    }

    func verifyCompletedArchive(
        at archiveURL: URL,
        expectedSources: [ZIPArchiveSource],
        progress: @escaping @Sendable (ZIPArchiveProgress) -> Void = { _ in }
    ) throws -> ZIPArchiveWriteResult {
        do {
            let normalized = try normalizedSources(expectedSources)
            return try readBack(
                archiveURL,
                expectedSources: normalized,
                progress: progress
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: archiveURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw ZIPArchiveWriterError.verificationFailed
        }
    }

    private func readBack(
        _ archiveURL: URL,
        expectedSources: [ZIPArchiveSource],
        progress: @escaping @Sendable (ZIPArchiveProgress) -> Void
    ) throws -> ZIPArchiveWriteResult {
        let values = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: archiveURL.path
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value >= 22
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        let archiveSize = fileSize.uint64Value
        guard archiveSize <= Self.maximumArchiveBytes,
              expectedSources.count < Int(UInt16.max)
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }

        let endOffset = archiveSize - 22
        let end = try read(
            input,
            offset: endOffset,
            count: 22,
            archiveSize: archiveSize
        )
        guard end.readLittleEndianUInt32(at: 0) == 0x06054b50,
              end.readLittleEndianUInt16(at: 4) == 0,
              end.readLittleEndianUInt16(at: 6) == 0,
              end.readLittleEndianUInt16(at: 20) == 0
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        let endDiskCount = end.readLittleEndianUInt16(at: 8)
        let endTotalCount = end.readLittleEndianUInt16(at: 10)
        let endCentralSize = end.readLittleEndianUInt32(at: 12)
        let endCentralOffset = end.readLittleEndianUInt32(at: 16)
        let hasZIP64 = endDiskCount == UInt16.max
            || endTotalCount == UInt16.max
            || endCentralSize == UInt32.max
            || endCentralOffset == UInt32.max

        let entryCount: UInt64
        let centralSize: UInt64
        let centralOffset: UInt64
        let centralEndingOffset: UInt64
        if hasZIP64 {
            guard endDiskCount == UInt16.max,
                  endTotalCount == UInt16.max,
                  endCentralSize == UInt32.max,
                  endCentralOffset == UInt32.max,
                  endOffset >= 20
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let locatorOffset = endOffset - 20
            let locator = try read(
                input,
                offset: locatorOffset,
                count: 20,
                archiveSize: archiveSize
            )
            guard locator.readLittleEndianUInt32(at: 0) == 0x07064b50,
                  locator.readLittleEndianUInt32(at: 4) == 0,
                  locator.readLittleEndianUInt32(at: 16) == 1
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let ZIP64Offset = locator.readLittleEndianUInt64(at: 8)
            let ZIP64 = try read(
                input,
                offset: ZIP64Offset,
                count: 56,
                archiveSize: archiveSize
            )
            guard ZIP64.readLittleEndianUInt32(at: 0) == 0x06064b50,
                  ZIP64.readLittleEndianUInt64(at: 4) == 44,
                  ZIP64.readLittleEndianUInt16(at: 12) == 45,
                  ZIP64.readLittleEndianUInt16(at: 14) == 45,
                  ZIP64.readLittleEndianUInt32(at: 16) == 0,
                  ZIP64.readLittleEndianUInt32(at: 20) == 0,
                  ZIP64.readLittleEndianUInt64(at: 24)
                    == ZIP64.readLittleEndianUInt64(at: 32),
                  try adding(ZIP64Offset, 56) == locatorOffset
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            entryCount = ZIP64.readLittleEndianUInt64(at: 32)
            centralSize = ZIP64.readLittleEndianUInt64(at: 40)
            centralOffset = ZIP64.readLittleEndianUInt64(at: 48)
            centralEndingOffset = ZIP64Offset
        } else {
            guard endDiskCount == endTotalCount else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            entryCount = UInt64(endTotalCount)
            centralSize = UInt64(endCentralSize)
            centralOffset = UInt64(endCentralOffset)
            centralEndingOffset = endOffset
        }
        guard entryCount == UInt64(expectedSources.count),
              entryCount > 0,
              entryCount < UInt64(UInt16.max),
              try adding(centralOffset, centralSize) == centralEndingOffset
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }

        var entries: [CentralEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var centralCursor = centralOffset
        var uniquePaths: Set<String> = []
        for index in 0 ..< Int(entryCount) {
            try Task.checkCancellation()
            let fixed = try read(
                input,
                offset: centralCursor,
                count: 46,
                archiveSize: archiveSize
            )
            guard fixed.readLittleEndianUInt32(at: 0) == 0x02014b50,
                  fixed.readLittleEndianUInt16(at: 4) == 45,
                  fixed.readLittleEndianUInt16(at: 8) == 0x0808,
                  fixed.readLittleEndianUInt16(at: 10) == 0,
                  fixed.readLittleEndianUInt16(at: 12) == 0,
                  fixed.readLittleEndianUInt16(at: 14) == 0x0021,
                  fixed.readLittleEndianUInt16(at: 32) == 0,
                  fixed.readLittleEndianUInt16(at: 34) == 0,
                  fixed.readLittleEndianUInt16(at: 36) == 0,
                  fixed.readLittleEndianUInt32(at: 38) == 0
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let pathCount = Int(fixed.readLittleEndianUInt16(at: 28))
            let extraCount = Int(fixed.readLittleEndianUInt16(at: 30))
            guard pathCount > 0 else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let variableCount = try boundedAdding(pathCount, extraCount)
            let variable = try read(
                input,
                offset: try adding(centralCursor, 46),
                count: variableCount,
                archiveSize: archiveSize
            )
            let pathData = variable.subdata(in: 0 ..< pathCount)
            let extra = variable.subdata(
                in: pathCount ..< variable.count
            )
            guard let path = String(data: pathData, encoding: .utf8),
                  Data(path.utf8) == pathData,
                  path == path.precomposedStringWithCanonicalMapping,
                  try validArchivePath(path),
                  uniquePaths.insert(path).inserted,
                  path == expectedSources[index].archivePath
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let compressed32 = fixed.readLittleEndianUInt32(at: 20)
            let uncompressed32 = fixed.readLittleEndianUInt32(at: 24)
            let offset32 = fixed.readLittleEndianUInt32(at: 42)
            let sizeNeedsZIP64 = compressed32 == UInt32.max
                || uncompressed32 == UInt32.max
            let offsetNeedsZIP64 = offset32 == UInt32.max
            guard (compressed32 == UInt32.max)
                == (uncompressed32 == UInt32.max)
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let ZIP64 = try parseExtra(
                extra,
                pathData: pathData,
                ZIP64ValueCount:
                    (sizeNeedsZIP64 ? 2 : 0) + (offsetNeedsZIP64 ? 1 : 0)
            )
            var ZIP64Index = 0
            let uncompressed: UInt64
            let compressed: UInt64
            if sizeNeedsZIP64 {
                uncompressed = ZIP64[ZIP64Index]
                compressed = ZIP64[ZIP64Index + 1]
                ZIP64Index += 2
            } else {
                uncompressed = UInt64(uncompressed32)
                compressed = UInt64(compressed32)
            }
            let localOffset: UInt64
            if offsetNeedsZIP64 {
                localOffset = ZIP64[ZIP64Index]
            } else {
                localOffset = UInt64(offset32)
            }
            guard compressed == uncompressed,
                  compressed <= Self.maximumArchiveBytes,
                  localOffset < centralOffset,
                  fixed.readLittleEndianUInt16(at: 6)
                    == (sizeNeedsZIP64 || offsetNeedsZIP64 ? 45 : 20)
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            entries.append(
                CentralEntry(
                    path: path,
                    pathData: pathData,
                    CRC32: fixed.readLittleEndianUInt32(at: 16),
                    size: uncompressed,
                    localHeaderOffset: localOffset,
                    usesZIP64: sizeNeedsZIP64 || offsetNeedsZIP64
                )
            )
            centralCursor = try adding(
                centralCursor,
                UInt64(try boundedAdding(46, variableCount))
            )
        }
        guard centralCursor == centralEndingOffset else {
            throw ZIPArchiveWriterError.verificationFailed
        }

        let sourceSizes = try expectedSources.map(sourceSize)
        let totalSourceBytes = try sourceSizes.reduce(UInt64(0), adding)
        guard totalSourceBytes <= Self.maximumArchiveBytes else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        var localCursor: UInt64 = 0
        var verifiedSourceBytes: UInt64 = 0
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard entry.localHeaderOffset == localCursor,
                  entry.size == sourceSizes[index]
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let fixed = try read(
                input,
                offset: localCursor,
                count: 30,
                archiveSize: archiveSize
            )
            let pathCount = Int(fixed.readLittleEndianUInt16(at: 26))
            let extraCount = Int(fixed.readLittleEndianUInt16(at: 28))
            let expectedVersion = entry.usesZIP64 ? UInt16(45) : UInt16(20)
            guard fixed.readLittleEndianUInt32(at: 0) == 0x04034b50,
                  fixed.readLittleEndianUInt16(at: 4) == expectedVersion,
                  fixed.readLittleEndianUInt16(at: 6) == 0x0808,
                  fixed.readLittleEndianUInt16(at: 8) == 0,
                  fixed.readLittleEndianUInt16(at: 10) == 0,
                  fixed.readLittleEndianUInt16(at: 12) == 0x0021,
                  fixed.readLittleEndianUInt32(at: 14) == 0,
                  pathCount == entry.pathData.count
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let variableCount = try boundedAdding(pathCount, extraCount)
            let variable = try read(
                input,
                offset: try adding(localCursor, 30),
                count: variableCount,
                archiveSize: archiveSize
            )
            let pathData = variable.subdata(in: 0 ..< pathCount)
            let extra = variable.subdata(
                in: pathCount ..< variable.count
            )
            guard pathData == entry.pathData else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let compressed32 = fixed.readLittleEndianUInt32(at: 18)
            let uncompressed32 = fixed.readLittleEndianUInt32(at: 22)
            let ZIP64: [UInt64]
            if entry.usesZIP64 {
                guard compressed32 == UInt32.max,
                      uncompressed32 == UInt32.max
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
                ZIP64 = try parseExtra(
                    extra,
                    pathData: pathData,
                    ZIP64ValueCount: 2
                )
                guard ZIP64 == [entry.size, entry.size] else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
            } else {
                guard compressed32 == 0, uncompressed32 == 0 else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
                ZIP64 = try parseExtra(
                    extra,
                    pathData: pathData,
                    ZIP64ValueCount: 0
                )
                guard ZIP64.isEmpty else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
            }
            let dataOffset = try adding(
                localCursor,
                UInt64(try boundedAdding(30, variableCount))
            )
            let dataEnd = try adding(dataOffset, entry.size)
            let descriptorCount = entry.usesZIP64 ? 24 : 16
            let descriptor = try read(
                input,
                offset: dataEnd,
                count: descriptorCount,
                archiveSize: archiveSize
            )
            guard descriptor.readLittleEndianUInt32(at: 0) == 0x08074b50,
                  descriptor.readLittleEndianUInt32(at: 4) == entry.CRC32
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            if entry.usesZIP64 {
                guard descriptor.readLittleEndianUInt64(at: 8) == entry.size,
                      descriptor.readLittleEndianUInt64(at: 16) == entry.size
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
            } else {
                guard descriptor.readLittleEndianUInt32(at: 8)
                        == UInt32(entry.size),
                      descriptor.readLittleEndianUInt32(at: 12)
                        == UInt32(entry.size)
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
            }
            let archiveCRC = try checksum(
                input,
                offset: dataOffset,
                count: entry.size,
                archiveSize: archiveSize
            )
            let sourceCRC = try checksum(expectedSources[index].fileURL)
            guard archiveCRC == entry.CRC32,
                  sourceCRC == entry.CRC32
            else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            localCursor = try adding(dataEnd, UInt64(descriptorCount))
            verifiedSourceBytes = try adding(
                verifiedSourceBytes,
                entry.size
            )
            progress(
                ZIPArchiveProgress(
                    completedSourceBytes: verifiedSourceBytes,
                    totalSourceBytes: totalSourceBytes,
                    completedEntries: index + 1,
                    totalEntries: entries.count
                )
            )
        }
        guard localCursor == centralOffset,
              verifiedSourceBytes == totalSourceBytes
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        return ZIPArchiveWriteResult(
            entryCount: entries.count,
            sourceBytes: verifiedSourceBytes,
            archiveBytes: archiveSize
        )
    }

    private static let maximumArchiveBytes: UInt64 =
        16 * 1_024 * 1_024 * 1_024 * 1_024

    private func read(
        _ input: FileHandle,
        offset: UInt64,
        count: Int,
        archiveSize: UInt64
    ) throws -> Data {
        guard count >= 0,
              count <= 2 * Int(UInt16.max) + 64,
              try adding(offset, UInt64(count)) <= archiveSize
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        try input.seek(toOffset: offset)
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        return data
    }

    private func checksum(
        _ input: FileHandle,
        offset: UInt64,
        count: UInt64,
        archiveSize: UInt64
    ) throws -> UInt32 {
        guard try adding(offset, count) <= archiveSize else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        try input.seek(toOffset: offset)
        var remaining = count
        var CRC = CRC32Accumulator()
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, 1_048_576))
            let data = try input.read(upToCount: requested) ?? Data()
            guard data.count == requested else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            CRC.update(data)
            remaining -= UInt64(data.count)
        }
        return CRC.finalized
    }

    private func checksum(_ sourceURL: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: sourceURL)
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

    private func parseExtra(
        _ data: Data,
        pathData: Data,
        ZIP64ValueCount: Int
    ) throws -> [UInt64] {
        var cursor = 0
        var ZIP64Values: [UInt64]?
        var sawUnicodePath = false
        while cursor < data.count {
            guard data.count - cursor >= 4 else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let identifier = data.readLittleEndianUInt16(at: cursor)
            let payloadCount = Int(
                data.readLittleEndianUInt16(at: cursor + 2)
            )
            cursor = try boundedAdding(cursor, 4)
            let end = try boundedAdding(cursor, payloadCount)
            guard end <= data.count else {
                throw ZIPArchiveWriterError.verificationFailed
            }
            let payload = data.subdata(in: cursor ..< end)
            switch identifier {
            case 0x0001:
                guard ZIP64Values == nil,
                      payloadCount == ZIP64ValueCount * 8,
                      ZIP64ValueCount > 0
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
                ZIP64Values = stride(
                    from: 0,
                    to: payloadCount,
                    by: 8
                ).map {
                    payload.readLittleEndianUInt64(at: $0)
                }
            case 0x7075:
                guard !sawUnicodePath,
                      pathData.contains(where: { $0 >= 0x80 }),
                      payloadCount == pathData.count + 5,
                      payload.first == 1
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
                var pathCRC = CRC32Accumulator()
                pathCRC.update(pathData)
                guard payload.readLittleEndianUInt32(at: 1)
                        == pathCRC.finalized,
                      payload.subdata(in: 5 ..< payload.count) == pathData
                else {
                    throw ZIPArchiveWriterError.verificationFailed
                }
                sawUnicodePath = true
            default:
                throw ZIPArchiveWriterError.verificationFailed
            }
            cursor = end
        }
        guard cursor == data.count,
              (ZIP64Values?.count ?? 0) == ZIP64ValueCount,
              sawUnicodePath
                == pathData.contains(where: { $0 >= 0x80 })
        else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        return ZIP64Values ?? []
    }

    private func validArchivePath(_ path: String) throws -> Bool {
        !path.isEmpty
            && path.utf8.count <= Int(UInt16.max)
            && !path.hasPrefix("/")
            && !path.hasSuffix("/")
            && !path.contains("\\")
            && !path.split(separator: "/").contains("..")
    }

    private func boundedAdding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, result >= 0 else {
            throw ZIPArchiveWriterError.verificationFailed
        }
        return result
    }

    private func adding(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ZIPArchiveWriterError.couldNotCreateArchive
        }
        return result
    }
}

struct CRC32Accumulator {
    private var value: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            var current = (value ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = (current & 1) == 1
                    ? (current >> 1) ^ 0xedb8_8320
                    : current >> 1
            }
            value = (value >> 8) ^ current
        }
    }

    var finalized: UInt32 {
        value ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    func readLittleEndianUInt16(at offset: Int) -> UInt16 {
        guard count >= offset + 2 else { return 0 }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readLittleEndianUInt64(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        return UInt64(readLittleEndianUInt32(at: offset))
            | UInt64(readLittleEndianUInt32(at: offset + 4)) << 32
    }
}
