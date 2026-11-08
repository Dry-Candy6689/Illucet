import Foundation

struct DASHLocalStreamAssemblyInput: Sendable {
    let plan: ResolvedDASHFragmentPlan
    let stagingResult: DASHFragmentStagingResult
    let destinationDirectoryURL: URL
    let verificationClass: MediaVerificationClass

    init(
        plan: ResolvedDASHFragmentPlan,
        stagingResult: DASHFragmentStagingResult,
        destinationDirectoryURL: URL,
        verificationClass: MediaVerificationClass = .fastStructural
    ) {
        self.plan = plan
        self.stagingResult = stagingResult
        self.destinationDirectoryURL = destinationDirectoryURL
        self.verificationClass = verificationClass
    }
}

struct DASHLocalStreamAssemblyResult: Sendable {
    let videoID: String
    let formatID: String
    let fileExtension: String
    let fileURL: URL
    let byteCount: Int64
    let probe: MediaProbeResult
}

protocol DASHLocalStreamAssembling: Sendable {
    func assemble(
        _ input: DASHLocalStreamAssemblyInput
    ) async throws -> DASHLocalStreamAssemblyResult
}

typealias DASHLocalStreamCopyCheckpoint =
    @Sendable (_ copiedBytes: Int64) async throws -> Void

final class DASHLocalStreamAssembler:
    DASHLocalStreamAssembling,
    @unchecked Sendable
{
    static let copyBufferBytes = 1 * 1_024 * 1_024

    private let mediaProcessor: any MediaProcessor
    private let destinationRoots: StreamTransferDestinationRoots
    private let fileManager: FileManager
    private let copyCheckpoint: DASHLocalStreamCopyCheckpoint

    init(
        mediaProcessor: any MediaProcessor,
        destinationRoots: StreamTransferDestinationRoots? = nil,
        fileManager: FileManager = .default,
        copyCheckpoint: @escaping DASHLocalStreamCopyCheckpoint = { _ in }
    ) {
        self.mediaProcessor = mediaProcessor
        self.destinationRoots = destinationRoots ?? .live(
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.copyCheckpoint = copyCheckpoint
    }

    func assemble(
        _ input: DASHLocalStreamAssemblyInput
    ) async throws -> DASHLocalStreamAssemblyResult {
        try Task.checkCancellation()
        let expectedBytes = try validate(input)
        let outputURL = input.destinationDirectoryURL.appending(
            path: "illucet-dash-assembled-\(UUID().uuidString)."
                + input.plan.fileExtension,
            directoryHint: .notDirectory
        )
        let partialURL = input.destinationDirectoryURL.appending(
            path: ".illucet-dash-assembly-\(UUID().uuidString).partial."
                + input.plan.fileExtension,
            directoryHint: .notDirectory
        )
        try validateDestination(outputURL)
        try validateDestination(partialURL)
        guard
            outputURL.standardizedFileURL != partialURL.standardizedFileURL,
            !fileManager.fileExists(atPath: outputURL.path),
            !fileManager.fileExists(atPath: partialURL.path)
        else {
            throw DASHLocalStreamAssemblyError.invalidDestination
        }

        do {
            try fileManager.createDirectory(
                at: input.destinationDirectoryURL,
                withIntermediateDirectories: true
            )
            try validateDirectory(input.destinationDirectoryURL)
            guard fileManager.createFile(
                atPath: partialURL.path,
                contents: nil
            ) else {
                throw DASHLocalStreamAssemblyError.couldNotAssemble
            }

            let output = try FileHandle(forWritingTo: partialURL)
            var assembledBytes: Int64 = 0
            do {
                for fragment in input.stagingResult.fragments {
                    try Task.checkCancellation()
                    let copied = try await append(
                        fragment.fileURL,
                        to: output
                    )
                    guard copied == fragment.byteCount else {
                        throw DASHLocalStreamAssemblyError
                            .fragmentByteCountMismatch(
                                position: fragment.position,
                                expected: fragment.byteCount,
                                actual: copied
                            )
                    }
                    let addition = assembledBytes.addingReportingOverflow(
                        copied
                    )
                    guard !addition.overflow else {
                        throw DASHLocalStreamAssemblyError.byteCountOverflow
                    }
                    assembledBytes = addition.partialValue
                    try validateFragment(fragment)
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            guard
                assembledBytes == expectedBytes,
                try exactRegularFileSize(partialURL) == expectedBytes
            else {
                throw DASHLocalStreamAssemblyError.aggregateByteCountMismatch
            }
            try Task.checkCancellation()

            let probe: MediaProbeResult
            do {
                probe = try await mediaProcessor.probe(
                    partialURL,
                    verificationClass: input.verificationClass
                )
                try Task.checkCancellation()
                try MediaOutputVerifier.verify(
                    probe,
                    requirements: verificationRequirements(for: input)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw DASHLocalStreamAssemblyError.nativeValidationFailed
            }

            guard
                probe.fileURL.standardizedFileURL
                    == partialURL.standardizedFileURL,
                probe.fileSize == expectedBytes
            else {
                throw DASHLocalStreamAssemblyError.nativeValidationFailed
            }
            for fragment in input.stagingResult.fragments {
                try validateFragment(fragment)
            }
            guard try exactRegularFileSize(partialURL) == expectedBytes else {
                throw DASHLocalStreamAssemblyError.aggregateByteCountMismatch
            }
            try Task.checkCancellation()

            do {
                try fileManager.moveItem(at: partialURL, to: outputURL)
            } catch {
                throw DASHLocalStreamAssemblyError.couldNotPublish
            }
            guard try exactRegularFileSize(outputURL) == expectedBytes else {
                throw DASHLocalStreamAssemblyError.couldNotPublish
            }
            try Task.checkCancellation()
            return DASHLocalStreamAssemblyResult(
                videoID: input.plan.videoID,
                formatID: input.plan.formatID,
                fileExtension: input.plan.fileExtension,
                fileURL: outputURL,
                byteCount: expectedBytes,
                probe: relocated(probe, to: outputURL)
            )
        } catch {
            try? fileManager.removeItem(at: partialURL)
            try? fileManager.removeItem(at: outputURL)
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func validate(
        _ input: DASHLocalStreamAssemblyInput
    ) throws -> Int64 {
        guard
            input.destinationDirectoryURL.isFileURL,
            YTDLPStreamResolver.isValidDASHFragmentPlan(input.plan),
            input.stagingResult.videoID == input.plan.videoID,
            input.stagingResult.formatID == input.plan.formatID,
            input.stagingResult.fragments.count == input.plan.fragments.count,
            input.stagingResult.fragments.enumerated().allSatisfy({
                $0.offset == $0.element.position
            }),
            Set(input.stagingResult.fragments.map {
                $0.fileURL.standardizedFileURL
            }).count == input.stagingResult.fragments.count
        else {
            throw DASHLocalStreamAssemblyError.invalidInput
        }

        var totalBytes: Int64 = 0
        for (planned, staged) in zip(
            input.plan.fragments,
            input.stagingResult.fragments
        ) {
            guard
                planned.position == staged.position,
                staged.fileURL.lastPathComponent == String(
                    format: "fragment-%06d.part",
                    staged.position
                ),
                staged.byteCount >= 0,
                planned.expectedBytes.map({ $0 == staged.byteCount }) ?? true
            else {
                throw DASHLocalStreamAssemblyError.invalidInput
            }
            let addition = totalBytes.addingReportingOverflow(
                staged.byteCount
            )
            guard !addition.overflow else {
                throw DASHLocalStreamAssemblyError.byteCountOverflow
            }
            totalBytes = addition.partialValue
        }
        for staged in input.stagingResult.fragments {
            try validateFragment(staged)
        }
        guard totalBytes > 0 else {
            throw DASHLocalStreamAssemblyError.aggregateByteCountMismatch
        }
        if let expectedBytes = input.plan.expectedBytes,
           totalBytes != expectedBytes {
            throw DASHLocalStreamAssemblyError.aggregateByteCountMismatch
        }
        return totalBytes
    }

    private func validateFragment(_ fragment: StagedDASHFragment) throws {
        do {
            let identity = try destinationRoots.identity(
                for: fragment.fileURL
            )
            let canonical = try destinationRoots.URL(for: identity)
            guard
                canonical.standardizedFileURL
                    == fragment.fileURL.standardizedFileURL,
                (try? exactRegularFileSize(fragment.fileURL))
                    == fragment.byteCount
            else {
                throw DASHLocalStreamAssemblyError.invalidFragment(
                    position: fragment.position
                )
            }
        } catch {
            throw DASHLocalStreamAssemblyError.invalidFragment(
                position: fragment.position
            )
        }
    }

    private func validateDestination(_ URL: URL) throws {
        do {
            let identity = try destinationRoots.identity(for: URL)
            let canonical = try destinationRoots.URL(for: identity)
            guard canonical.standardizedFileURL == URL.standardizedFileURL else {
                throw DASHLocalStreamAssemblyError.invalidDestination
            }
        } catch let error as DASHLocalStreamAssemblyError {
            throw error
        } catch {
            throw DASHLocalStreamAssemblyError.invalidDestination
        }
    }

    private func validateDirectory(_ URL: URL) throws {
        let values = try URL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DASHLocalStreamAssemblyError.invalidDestination
        }
    }

    private func exactRegularFileSize(_ URL: URL) throws -> Int64 {
        let values = try URL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size >= 0
        else {
            throw DASHLocalStreamAssemblyError.couldNotAssemble
        }
        return Int64(size)
    }

    private func append(
        _ sourceURL: URL,
        to output: FileHandle
    ) async throws -> Int64 {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            await Task.yield()
            guard let data = try input.read(
                upToCount: Self.copyBufferBytes
            ), !data.isEmpty else {
                return copied
            }
            try output.write(contentsOf: data)
            let addition = copied.addingReportingOverflow(
                Int64(data.count)
            )
            guard !addition.overflow else {
                throw DASHLocalStreamAssemblyError.byteCountOverflow
            }
            copied = addition.partialValue
            try await copyCheckpoint(copied)
        }
    }

    private func verificationRequirements(
        for input: DASHLocalStreamAssemblyInput
    ) -> MediaVerificationRequirements {
        MediaVerificationRequirements(
            expectedContainer: container(for: input.plan.fileExtension),
            expectedFileExtension: input.plan.fileExtension,
            expectedVideoStreams: input.plan.hasVideo ? 1 ... Int.max : 0 ... 0,
            expectedAudioStreams: input.plan.hasAudio ? 1 ... Int.max : 0 ... 0,
            expectedSubtitleStreams: nil,
            expectedVideoCodec: nil,
            expectedAudioCodec: nil,
            expectedDimensions: nil,
            expectedFrameRate: nil,
            frameRateTolerance: 0.05,
            expectedHDR: nil,
            expectedAudioSampleRate: nil,
            expectedAudioChannelCount: nil,
            expectedDurationSeconds: nil,
            durationToleranceSeconds: 0.5,
            expectedAudioBitRate: nil,
            audioBitRateToleranceFraction: 0.08,
            expectedChapterCount: nil,
            requireArtwork: nil,
            requireMetadataKeys: [],
            expectedMetadataValues: [:],
            forbiddenMetadataKeys: [],
            requiredVerificationClass: input.verificationClass
        )
    }

    private func container(for fileExtension: String) -> MediaContainer {
        switch fileExtension {
        case "m4a": .m4a
        case "mp4": .mp4
        case "webm": .webM
        default: .automatic
        }
    }

    private func relocated(
        _ probe: MediaProbeResult,
        to fileURL: URL
    ) -> MediaProbeResult {
        MediaProbeResult(
            fileURL: fileURL,
            formatNames: probe.formatNames,
            formatLongName: probe.formatLongName,
            durationSeconds: probe.durationSeconds,
            startTimeSeconds: probe.startTimeSeconds,
            bitRate: probe.bitRate,
            fileSize: probe.fileSize,
            metadata: probe.metadata,
            streams: probe.streams,
            chapters: probe.chapters,
            verificationEvidence: probe.verificationEvidence
        )
    }
}

enum DASHLocalStreamAssemblyError: LocalizedError, Equatable, Sendable {
    case invalidInput
    case invalidDestination
    case invalidFragment(position: Int)
    case fragmentByteCountMismatch(
        position: Int,
        expected: Int64,
        actual: Int64
    )
    case byteCountOverflow
    case aggregateByteCountMismatch
    case couldNotAssemble
    case nativeValidationFailed
    case couldNotPublish

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "The staged DASH assembly input is invalid."
        case .invalidDestination:
            "The DASH assembly destination is not app controlled."
        case let .invalidFragment(position):
            "DASH fragment \(position) is not an accepted app-controlled regular file."
        case let .fragmentByteCountMismatch(position, expected, actual):
            "DASH fragment \(position) has \(actual) bytes; expected \(expected)."
        case .byteCountOverflow:
            "The staged DASH byte total is invalid."
        case .aggregateByteCountMismatch:
            "The assembled DASH byte total is invalid."
        case .couldNotAssemble:
            "The accepted DASH fragments could not be assembled."
        case .nativeValidationFailed:
            "The assembled DASH stream did not pass native validation."
        case .couldNotPublish:
            "The validated DASH stream could not be published privately."
        }
    }
}
