import Foundation

enum StreamTransferMediaRole: String, Codable, Equatable, Hashable, Sendable {
    case video
    case audio
    case videoAudio = "video_audio"

    init?(stream: ResolvedStream) {
        switch (stream.hasVideo, stream.hasAudio) {
        case (true, true):
            self = .videoAudio
        case (true, false):
            self = .video
        case (false, true):
            self = .audio
        case (false, false):
            return nil
        }
    }
}

struct StreamByteRange: Codable, Equatable, Hashable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 {
        end - start + 1
    }

    var HTTPHeaderValue: String {
        "bytes=\(start)-\(end)"
    }

    func validate(totalBytes: Int64) throws {
        guard
            totalBytes > 0,
            start >= 0,
            end >= start,
            end < totalBytes
        else {
            throw StreamRangeTransferError.invalidRangePlan
        }
    }
}

struct StreamContentRange: Equatable, Sendable {
    let range: StreamByteRange
    let totalBytes: Int64

    static func parse(_ rawValue: String?) throws -> Self {
        guard let rawValue else {
            throw StreamRangeTransferError.invalidContentRange
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 128 else {
            throw StreamRangeTransferError.invalidContentRange
        }
        let components = value.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard
            components.count == 2,
            components[0].lowercased() == "bytes"
        else {
            throw StreamRangeTransferError.invalidContentRange
        }
        let valueAndTotal = components[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            valueAndTotal.count == 2,
            valueAndTotal[1] != "*",
            let total = decimal(valueAndTotal[1]),
            total > 0
        else {
            throw StreamRangeTransferError.invalidContentRange
        }
        let bounds = valueAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            bounds.count == 2,
            let start = decimal(bounds[0]),
            let end = decimal(bounds[1])
        else {
            throw StreamRangeTransferError.invalidContentRange
        }
        let range = StreamByteRange(start: start, end: end)
        do {
            try range.validate(totalBytes: total)
        } catch {
            throw StreamRangeTransferError.invalidContentRange
        }
        return Self(range: range, totalBytes: total)
    }

    private static func decimal(_ value: Substring) -> Int64? {
        guard
            !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            return nil
        }
        return Int64(value)
    }
}

struct StreamRangePlan: Equatable, Sendable {
    static let minimumChunkBytes: Int64 = 64 * 1_024
    static let maximumRangeCount = 128

    let totalBytes: Int64
    let chunkBytes: Int64
    let ranges: [StreamByteRange]

    init?(
        expectedTotalBytes: Int64?,
        suggestedChunkBytes: Int64?
    ) {
        guard
            let totalBytes = expectedTotalBytes,
            let suggestedChunkBytes,
            totalBytes > 0,
            suggestedChunkBytes >= Self.minimumChunkBytes,
            suggestedChunkBytes
                <= YTDLPStreamResolver.maximumHTTPChunkSize
        else {
            return nil
        }
        let minimumBoundedChunk =
            ((totalBytes - 1) / Int64(Self.maximumRangeCount)) + 1
        let chunkBytes = max(
            suggestedChunkBytes,
            minimumBoundedChunk
        )
        guard chunkBytes <= YTDLPStreamResolver.maximumHTTPChunkSize else {
            return nil
        }
        let rangeCount = ((totalBytes - 1) / chunkBytes) + 1
        guard
            rangeCount >= 1,
            rangeCount <= Int64(Self.maximumRangeCount)
        else {
            return nil
        }
        var generated: [StreamByteRange] = []
        generated.reserveCapacity(Int(rangeCount))
        var start: Int64 = 0
        while start < totalBytes {
            let remaining = totalBytes - start
            let length = min(chunkBytes, remaining)
            let end = start + length - 1
            generated.append(StreamByteRange(start: start, end: end))
            start = end + 1
        }
        guard
            (try? Self.validateCoverage(
                generated,
                totalBytes: totalBytes
            )) != nil
        else {
            return nil
        }
        self.totalBytes = totalBytes
        self.chunkBytes = chunkBytes
        ranges = generated
    }

    static func validateCoverage(
        _ ranges: [StreamByteRange],
        totalBytes: Int64
    ) throws {
        guard
            totalBytes > 0,
            !ranges.isEmpty,
            ranges.count <= maximumRangeCount
        else {
            throw StreamRangeTransferError.invalidRangePlan
        }
        var expectedStart: Int64 = 0
        for range in ranges {
            try range.validate(totalBytes: totalBytes)
            guard range.start == expectedStart else {
                throw StreamRangeTransferError.invalidRangePlan
            }
            expectedStart = range.end + 1
        }
        guard expectedStart == totalBytes else {
            throw StreamRangeTransferError.invalidRangePlan
        }
    }
}

struct StreamRangeChunk: Equatable, Sendable {
    let range: StreamByteRange
    let fileURL: URL
}

enum StreamRangeStaging {
    static func directory(
        for destinationURL: URL,
        role: StreamTransferMediaRole,
        totalBytes: Int64
    ) -> URL {
        destinationURL.deletingLastPathComponent().appending(
            path:
                ".\(destinationURL.lastPathComponent).illucet-ranges"
                + "-\(role.rawValue)-\(totalBytes)",
            directoryHint: .isDirectory
        )
    }

    static func chunkURL(
        in directory: URL,
        range: StreamByteRange
    ) -> URL {
        directory.appending(
            path: String(
                format: "%020lld-%020lld.part",
                range.start,
                range.end
            ),
            directoryHint: .notDirectory
        )
    }

    static func assemblyURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appending(
            path:
                ".\(destinationURL.lastPathComponent).illucet-assembly-"
                + UUID().uuidString,
            directoryHint: .notDirectory
        )
    }
}

enum StreamRangeAssembler {
    static let copyBufferBytes = 1 * 1_024 * 1_024

    static func assemble(
        plan: StreamRangePlan,
        chunks: [StreamRangeChunk],
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard chunks.map(\.range) == plan.ranges else {
            throw StreamRangeTransferError.invalidRangePlan
        }
        try StreamRangePlan.validateCoverage(
            chunks.map(\.range),
            totalBytes: plan.totalBytes
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StreamRangeTransferError.destinationAlreadyExists
        }
        let assemblyURL = StreamRangeStaging.assemblyURL(
            for: destinationURL
        )
        guard fileManager.createFile(
            atPath: assemblyURL.path,
            contents: nil,
            attributes: BackgroundFileProtection.attributes
        ) else {
            throw StreamRangeTransferError.assemblyFailed
        }
        do {
            let assembledBytes = try writeAssembly(
                chunks: chunks,
                to: assemblyURL,
                fileManager: fileManager
            )
            guard
                assembledBytes == plan.totalBytes,
                try fileSize(assemblyURL, fileManager: fileManager)
                    == plan.totalBytes
            else {
                throw StreamRangeTransferError.invalidFinalLength
            }
            try fileManager.moveItem(
                at: assemblyURL,
                to: destinationURL
            )
        } catch {
            try? fileManager.removeItem(at: assemblyURL)
            throw error
        }
    }

    private static func writeAssembly(
        chunks: [StreamRangeChunk],
        to assemblyURL: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        let output = try FileHandle(forWritingTo: assemblyURL)
        defer { try? output.close() }
        var assembledBytes: Int64 = 0
        for chunk in chunks {
            let size = try fileSize(
                chunk.fileURL,
                fileManager: fileManager
            )
            guard size == chunk.range.length else {
                throw StreamRangeTransferError.invalidChunkLength
            }
            let copied = try append(
                chunk.fileURL,
                to: output
            )
            guard copied == chunk.range.length else {
                throw StreamRangeTransferError.invalidChunkLength
            }
            assembledBytes += copied
        }
        try output.synchronize()
        return assembledBytes
    }

    private static func append(
        _ sourceURL: URL,
        to output: FileHandle
    ) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var copied: Int64 = 0
        while let data = try input.read(
            upToCount: copyBufferBytes
        ), !data.isEmpty {
            try output.write(contentsOf: data)
            copied += Int64(data.count)
        }
        return copied
    }

    private static func fileSize(
        _ URL: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(
            atPath: URL.path
        )
        guard let number = attributes[.size] as? NSNumber else {
            throw StreamRangeTransferError.invalidChunkLength
        }
        return number.int64Value
    }
}

enum StreamTransferStrategy: String, Equatable, Sendable {
    case oneGET = "one_get"
    case boundedRanges = "bounded_ranges"
    case rangeIgnoredFullResponse = "range_ignored_full_response"
}

struct StreamDownloadResult: Equatable, Sendable {
    let fileURL: URL
    let strategy: StreamTransferStrategy
    let plannedRangeCount: Int
    let requestedRangeCount: Int
    let verifiedReusableBytes: Int64
    let networkBytesReceived: Int64
}

enum StreamRangeTransferError: LocalizedError, Equatable, Sendable {
    case invalidRangePlan
    case invalidContentRange
    case invalidChunkLength
    case invalidFinalLength
    case destinationAlreadyExists
    case assemblyFailed

    var errorDescription: String? {
        switch self {
        case .invalidRangePlan:
            "The byte-range plan is invalid."
        case .invalidContentRange:
            "The media server returned an invalid Content-Range."
        case .invalidChunkLength:
            "A staged byte range has an invalid length."
        case .invalidFinalLength:
            "The assembled stream length is invalid."
        case .destinationAlreadyExists:
            "The stream destination already exists."
        case .assemblyFailed:
            "The verified byte ranges could not be assembled."
        }
    }
}
