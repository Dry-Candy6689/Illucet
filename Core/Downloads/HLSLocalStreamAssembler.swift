import Foundation

struct HLSLocalStreamAssemblyInput: Sendable {
    let selection: ResolvedHLSPlaylistSelection
    let stagingResult: HLSResourceStagingResult
    let verificationClass: MediaVerificationClass
    let jobLocalDestinationURL: URL?
    let jobTemporaryRootURL: URL?

    init(
        selection: ResolvedHLSPlaylistSelection,
        stagingResult: HLSResourceStagingResult,
        verificationClass: MediaVerificationClass = .fastStructural,
        jobLocalDestinationURL: URL? = nil,
        jobTemporaryRootURL: URL? = nil
    ) {
        self.selection = selection
        self.stagingResult = stagingResult
        self.verificationClass = verificationClass
        self.jobLocalDestinationURL = jobLocalDestinationURL
        self.jobTemporaryRootURL = jobTemporaryRootURL
    }
}

struct HLSLocalStreamAssemblyResult: Sendable {
    let videoID: String
    let formatID: String
    let assemblyDirectoryURL: URL
    let fileURL: URL
    let byteCount: Int64
    let probe: MediaProbeResult
}

protocol HLSLocalStreamAssembling: Sendable {
    func assemble(
        _ input: HLSLocalStreamAssemblyInput
    ) async throws -> HLSLocalStreamAssemblyResult
}

typealias HLSLocalStreamCopyCheckpoint =
    @Sendable (_ copiedBytes: Int64) async throws -> Void

final class HLSLocalStreamAssembler:
    HLSLocalStreamAssembling,
    @unchecked Sendable
{
    static let copyBufferBytes = 1 * 1_024 * 1_024

    private struct FileIdentity: Hashable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    private struct ResourceInspection {
        let byteCount: Int64
        let identity: FileIdentity
    }

    private struct ValidatedInput {
        let byteCount: Int64
        let stagingIdentity: StreamTransferDestinationIdentity
        let resourceIdentities: [Int: FileIdentity]
    }

    private let mediaProcessor: any MediaProcessor
    private let destinationRoots: StreamTransferDestinationRoots
    private let fileManager: FileManager
    private let copyCheckpoint: HLSLocalStreamCopyCheckpoint

    init(
        mediaProcessor: any MediaProcessor,
        destinationRoots: StreamTransferDestinationRoots? = nil,
        fileManager: FileManager = .default,
        copyCheckpoint: @escaping HLSLocalStreamCopyCheckpoint = { _ in }
    ) {
        self.mediaProcessor = mediaProcessor
        self.destinationRoots = destinationRoots ?? .live(
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.copyCheckpoint = copyCheckpoint
    }

    func assemble(
        _ input: HLSLocalStreamAssemblyInput
    ) async throws -> HLSLocalStreamAssemblyResult {
        try Task.checkCancellation()
        guard (input.jobLocalDestinationURL == nil)
                == (input.jobTemporaryRootURL == nil)
        else {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
        let validated = try validate(input)
        let assemblyDirectoryURL = destinationRoots.temporaryDirectory
            .appending(path: "HLS-Assembly", directoryHint: .isDirectory)
            .appending(
                path: "assembly-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        let partialURL = assemblyDirectoryURL.appending(
            path: ".assembled.partial",
            directoryHint: .notDirectory
        )
        let outputURL = assemblyDirectoryURL.appending(
            path: "assembled.media",
            directoryHint: .notDirectory
        )

        try validateAssemblyDestination(
            directoryURL: assemblyDirectoryURL,
            partialURL: partialURL,
            outputURL: outputURL
        )
        var publishedJobLocalURL: URL?

        do {
            try fileManager.createDirectory(
                at: assemblyDirectoryURL,
                withIntermediateDirectories: true
            )
            try validateAssemblyDirectory(assemblyDirectoryURL)
            guard fileManager.createFile(
                atPath: partialURL.path,
                contents: nil
            ) else {
                throw HLSLocalStreamAssemblyError.couldNotAssemble
            }

            let output = try FileHandle(forWritingTo: partialURL)
            var assembledBytes: Int64 = 0
            do {
                for event in input.stagingResult.events {
                    try Task.checkCancellation()
                    switch event {
                    case .discontinuity:
                        try output.synchronize()
                    case let .initialization(_, resource),
                         let .media(_, resource, _):
                        let copied = try await append(
                            resource.fileURL,
                            to: output
                        )
                        guard copied == resource.byteCount else {
                            throw HLSLocalStreamAssemblyError
                                .resourceByteCountMismatch(
                                    position: resource.position,
                                    expected: resource.byteCount,
                                    actual: copied
                                )
                        }
                        let addition = assembledBytes.addingReportingOverflow(
                            copied
                        )
                        guard !addition.overflow else {
                            throw HLSLocalStreamAssemblyError.byteCountOverflow
                        }
                        assembledBytes = addition.partialValue
                        try revalidate(
                            resource,
                            stagingIdentity: validated.stagingIdentity,
                            expectedIdentity: validated.resourceIdentities[
                                resource.position
                            ]
                        )
                    }
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            guard
                assembledBytes == validated.byteCount,
                try inspectRegularFile(partialURL).byteCount
                    == validated.byteCount
            else {
                throw HLSLocalStreamAssemblyError.aggregateByteCountMismatch
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
                throw HLSLocalStreamAssemblyError.nativeValidationFailed
            }

            guard
                probe.fileURL.standardizedFileURL
                    == partialURL.standardizedFileURL,
                probe.fileSize == validated.byteCount
            else {
                throw HLSLocalStreamAssemblyError.nativeValidationFailed
            }
            try revalidateResources(input, validated: validated)
            guard
                try inspectRegularFile(partialURL).byteCount
                    == validated.byteCount
            else {
                throw HLSLocalStreamAssemblyError.aggregateByteCountMismatch
            }
            try Task.checkCancellation()

            do {
                try fileManager.moveItem(at: partialURL, to: outputURL)
            } catch {
                throw HLSLocalStreamAssemblyError.couldNotPublish
            }
            guard
                try inspectRegularFile(outputURL).byteCount
                    == validated.byteCount
            else {
                throw HLSLocalStreamAssemblyError.couldNotPublish
            }

            let finalURL: URL
            if let destinationURL = input.jobLocalDestinationURL,
               let temporaryRootURL = input.jobTemporaryRootURL {
                finalURL = try publishJobLocalSource(
                    outputURL,
                    byteCount: validated.byteCount,
                    probe: probe,
                    destinationURL: destinationURL,
                    temporaryRootURL: temporaryRootURL
                )
                publishedJobLocalURL = finalURL
                guard discardAssemblyDirectory(assemblyDirectoryURL) else {
                    throw HLSLocalStreamAssemblyError.couldNotCleanAssembly
                }
            } else {
                finalURL = outputURL
            }
            try Task.checkCancellation()

            return HLSLocalStreamAssemblyResult(
                videoID: input.selection.videoID,
                formatID: input.selection.formatID,
                assemblyDirectoryURL: assemblyDirectoryURL,
                fileURL: finalURL,
                byteCount: validated.byteCount,
                probe: relocated(probe, to: finalURL)
            )
        } catch {
            if let publishedJobLocalURL,
               fileManager.fileExists(atPath: publishedJobLocalURL.path) {
                try? fileManager.removeItem(at: publishedJobLocalURL)
            }
            let cleanupSucceeded = discardAssemblyDirectory(
                assemblyDirectoryURL
            )
            guard
                cleanupSucceeded,
                (publishedJobLocalURL.map {
                    !fileManager.fileExists(atPath: $0.path)
                } ?? true)
            else {
                throw HLSLocalStreamAssemblyError.couldNotCleanAssembly
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func validate(
        _ input: HLSLocalStreamAssemblyInput
    ) throws -> ValidatedInput {
        guard
            isValidSelection(input.selection),
            input.stagingResult.videoID == input.selection.videoID,
            input.stagingResult.formatID == input.selection.formatID,
            input.stagingResult.events.count
                == input.selection.resourcePlan.events.count,
            hasValidDiscontinuityTopology(
                input.selection.resourcePlan.events
            )
        else {
            throw HLSLocalStreamAssemblyError.invalidInput
        }

        let stagingIdentity = try validateStagingDirectory(
            input.stagingResult.stagingDirectoryURL
        )
        var expectedNames: Set<String> = []
        var stagedResources: [StagedHLSResource] = []
        var totalBytes: Int64 = 0

        for (planned, staged) in zip(
            input.selection.resourcePlan.events,
            input.stagingResult.events
        ) {
            switch (planned, staged) {
            case let (
                .initialization(plannedPosition, plannedResource),
                .initialization(stagedPosition, stagedResource)
            ):
                guard
                    plannedPosition == stagedPosition,
                    matches(plannedResource, staged: stagedResource)
                else {
                    throw HLSLocalStreamAssemblyError.invalidInput
                }
                try appendValidatedResource(
                    stagedResource,
                    expectedNames: &expectedNames,
                    stagedResources: &stagedResources,
                    totalBytes: &totalBytes
                )
            case let (
                .media(
                    plannedPosition,
                    plannedResource,
                    plannedInitialization
                ),
                .media(
                    stagedPosition,
                    stagedResource,
                    stagedInitialization
                )
            ):
                guard
                    plannedPosition == stagedPosition,
                    plannedInitialization == stagedInitialization,
                    matches(plannedResource, staged: stagedResource)
                else {
                    throw HLSLocalStreamAssemblyError.invalidInput
                }
                try appendValidatedResource(
                    stagedResource,
                    expectedNames: &expectedNames,
                    stagedResources: &stagedResources,
                    totalBytes: &totalBytes
                )
            case let (
                .discontinuity(plannedPosition),
                .discontinuity(stagedPosition)
            ):
                guard plannedPosition == stagedPosition else {
                    throw HLSLocalStreamAssemblyError.invalidInput
                }
            default:
                throw HLSLocalStreamAssemblyError.invalidInput
            }
        }

        guard totalBytes > 0 else {
            throw HLSLocalStreamAssemblyError.aggregateByteCountMismatch
        }
        let directoryContents: Set<String>
        do {
            directoryContents = Set(
                try fileManager.contentsOfDirectory(
                    atPath: input.stagingResult.stagingDirectoryURL.path
                )
            )
        } catch {
            throw HLSLocalStreamAssemblyError.invalidStagingDirectory
        }
        guard directoryContents == expectedNames else {
            throw HLSLocalStreamAssemblyError.invalidStagingDirectory
        }

        var fileIdentities: Set<FileIdentity> = []
        var resourceIdentities: [Int: FileIdentity] = [:]
        for resource in stagedResources {
            let inspection = try validateResource(
                resource,
                stagingIdentity: stagingIdentity
            )
            guard
                fileIdentities.insert(inspection.identity).inserted,
                resourceIdentities.updateValue(
                    inspection.identity,
                    forKey: resource.position
                ) == nil
            else {
                throw HLSLocalStreamAssemblyError.invalidInput
            }
        }

        return ValidatedInput(
            byteCount: totalBytes,
            stagingIdentity: stagingIdentity,
            resourceIdentities: resourceIdentities
        )
    }

    private func appendValidatedResource(
        _ resource: StagedHLSResource,
        expectedNames: inout Set<String>,
        stagedResources: inout [StagedHLSResource],
        totalBytes: inout Int64
    ) throws {
        let filename = deterministicFilename(for: resource)
        guard
            resource.position >= 0,
            resource.fileURL.lastPathComponent == filename,
            resource.byteRange.map({ $0.length == resource.byteCount })
                ?? true,
            expectedNames.insert(filename).inserted
        else {
            throw HLSLocalStreamAssemblyError.invalidInput
        }
        guard resource.byteCount > 0 else {
            throw HLSLocalStreamAssemblyError.aggregateByteCountMismatch
        }
        let addition = totalBytes.addingReportingOverflow(resource.byteCount)
        guard !addition.overflow else {
            throw HLSLocalStreamAssemblyError.byteCountOverflow
        }
        totalBytes = addition.partialValue
        stagedResources.append(resource)
    }

    private func matches(
        _ planned: HLSMediaResource,
        staged: StagedHLSResource
    ) -> Bool {
        planned.position == staged.position
            && planned.kind == staged.kind
            && planned.byteRange == staged.byteRange
    }

    private func validateStagingDirectory(
        _ URL: URL
    ) throws -> StreamTransferDestinationIdentity {
        do {
            let identity = try destinationRoots.identity(for: URL)
            let expectedURL = destinationRoots.applicationSupportDirectory
                .appending(
                    path: identity.relativePath,
                    directoryHint: .isDirectory
                )
            guard
                identity.root == .applicationSupport,
                expectedURL.standardizedFileURL.path
                    == URL.standardizedFileURL.path,
                isValidStagingRelativePath(identity.relativePath)
            else {
                throw HLSLocalStreamAssemblyError.invalidStagingDirectory
            }
            try validateRegularDirectory(URL)
            return identity
        } catch let error as HLSLocalStreamAssemblyError {
            throw error
        } catch {
            throw HLSLocalStreamAssemblyError.invalidStagingDirectory
        }
    }

    private func validateResource(
        _ resource: StagedHLSResource,
        stagingIdentity: StreamTransferDestinationIdentity
    ) throws -> ResourceInspection {
        do {
            let identity = try destinationRoots.identity(
                for: resource.fileURL
            )
            let expectedRelativePath = stagingIdentity.relativePath
                + "/" + deterministicFilename(for: resource)
            let expectedResourceURL = destinationRoots
                .applicationSupportDirectory.appending(
                    path: expectedRelativePath,
                    directoryHint: .notDirectory
                )
            let expectedStagingURL = destinationRoots
                .applicationSupportDirectory.appending(
                    path: stagingIdentity.relativePath,
                    directoryHint: .isDirectory
                )
            guard
                identity.root == .applicationSupport,
                identity.relativePath == expectedRelativePath,
                expectedResourceURL.standardizedFileURL.path
                    == resource.fileURL.standardizedFileURL.path,
                resource.fileURL.deletingLastPathComponent()
                    .standardizedFileURL.path
                    == expectedStagingURL.standardizedFileURL.path
            else {
                throw HLSLocalStreamAssemblyError.invalidResource(
                    position: resource.position
                )
            }
            let inspection = try inspectRegularFile(resource.fileURL)
            guard inspection.byteCount == resource.byteCount else {
                throw HLSLocalStreamAssemblyError.resourceByteCountMismatch(
                    position: resource.position,
                    expected: resource.byteCount,
                    actual: inspection.byteCount
                )
            }
            return inspection
        } catch let error as HLSLocalStreamAssemblyError {
            throw error
        } catch {
            throw HLSLocalStreamAssemblyError.invalidResource(
                position: resource.position
            )
        }
    }

    private func revalidate(
        _ resource: StagedHLSResource,
        stagingIdentity: StreamTransferDestinationIdentity,
        expectedIdentity: FileIdentity?
    ) throws {
        let inspection = try validateResource(
            resource,
            stagingIdentity: stagingIdentity
        )
        guard
            let expectedIdentity,
            inspection.identity == expectedIdentity
        else {
            throw HLSLocalStreamAssemblyError.invalidResource(
                position: resource.position
            )
        }
    }

    private func revalidateResources(
        _ input: HLSLocalStreamAssemblyInput,
        validated: ValidatedInput
    ) throws {
        for event in input.stagingResult.events {
            guard let resource = event.resource else { continue }
            try revalidate(
                resource,
                stagingIdentity: validated.stagingIdentity,
                expectedIdentity: validated.resourceIdentities[
                    resource.position
                ]
            )
        }
    }

    private func inspectRegularFile(_ URL: URL) throws -> ResourceInspection {
        guard
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil
        else {
            throw HLSLocalStreamAssemblyError.couldNotAssemble
        }
        let attributes = try fileManager.attributesOfItem(atPath: URL.path)
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber,
            size.int64Value >= 0,
            let systemNumber = attributes[.systemNumber] as? NSNumber,
            let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else {
            throw HLSLocalStreamAssemblyError.couldNotAssemble
        }
        return ResourceInspection(
            byteCount: size.int64Value,
            identity: FileIdentity(
                systemNumber: systemNumber.uint64Value,
                fileNumber: fileNumber.uint64Value
            )
        )
    }

    private func publishJobLocalSource(
        _ sourceURL: URL,
        byteCount: Int64,
        probe: MediaProbeResult,
        destinationURL: URL,
        temporaryRootURL: URL
    ) throws -> URL {
        do {
            let rootIdentity = try destinationRoots.identity(
                for: temporaryRootURL
            )
            let destinationIdentity = try destinationRoots.identity(
                for: destinationURL
            )
            let canonicalRoot = try destinationRoots.URL(for: rootIdentity)
            let canonicalDestination = try destinationRoots.URL(
                for: destinationIdentity
            )
            guard
                rootIdentity.root == .temporary,
                destinationIdentity.root == .temporary,
                destinationIdentity.relativePath
                    == rootIdentity.relativePath
                        + "/" + destinationURL.lastPathComponent,
                canonicalDestination.deletingLastPathComponent().path
                    == canonicalRoot.path,
                destinationURL.deletingLastPathComponent().standardizedFileURL.path
                    == temporaryRootURL.standardizedFileURL.path,
                isValidJobTemporaryRoot(rootIdentity.relativePath),
                !fileManager.fileExists(atPath: destinationURL.path),
                probe.fileSize == byteCount
            else {
                throw HLSLocalStreamAssemblyError.invalidDestination
            }
            try validateRegularDirectory(temporaryRootURL)
            let source = try inspectRegularFile(sourceURL)
            guard
                source.byteCount == byteCount,
                let rootSystemNumber = try fileManager
                    .attributesOfItem(atPath: temporaryRootURL.path)[
                        .systemNumber
                    ] as? NSNumber,
                source.identity.systemNumber
                    == rootSystemNumber.uint64Value
            else {
                throw HLSLocalStreamAssemblyError.invalidDestination
            }

            do {
                try fileManager.moveItem(
                    at: sourceURL,
                    to: destinationURL
                )
            } catch {
                throw HLSLocalStreamAssemblyError.couldNotPublish
            }
            do {
                let published = try inspectRegularFile(destinationURL)
                guard
                    published.byteCount == byteCount,
                    published.identity == source.identity
                else {
                    throw HLSLocalStreamAssemblyError.couldNotPublish
                }
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
            return destinationURL
        } catch let error as HLSLocalStreamAssemblyError {
            throw error
        } catch {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
    }

    private func isValidJobTemporaryRoot(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard
            components.count == 1,
            components[0].hasPrefix("Illucet-")
        else {
            return false
        }
        let value = components[0].dropFirst("Illucet-".count)
        guard let uuid = UUID(uuidString: String(value)) else { return false }
        return uuid.uuidString == value
    }

    private func validateAssemblyDestination(
        directoryURL: URL,
        partialURL: URL,
        outputURL: URL
    ) throws {
        do {
            let directoryIdentity = try destinationRoots.identity(
                for: directoryURL
            )
            let partialIdentity = try destinationRoots.identity(
                for: partialURL
            )
            let outputIdentity = try destinationRoots.identity(for: outputURL)
            guard
                directoryIdentity.root == .temporary,
                partialIdentity.root == .temporary,
                outputIdentity.root == .temporary,
                directoryIdentity.relativePath.hasPrefix(
                    "HLS-Assembly/assembly-"
                ),
                partialIdentity.relativePath
                    == directoryIdentity.relativePath + "/.assembled.partial",
                outputIdentity.relativePath
                    == directoryIdentity.relativePath + "/assembled.media",
                partialIdentity != outputIdentity,
                !fileManager.fileExists(atPath: directoryURL.path)
            else {
                throw HLSLocalStreamAssemblyError.invalidDestination
            }
        } catch let error as HLSLocalStreamAssemblyError {
            throw error
        } catch {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
    }

    private func validateAssemblyDirectory(_ URL: URL) throws {
        do {
            try validateRegularDirectory(URL)
            let parent = URL.deletingLastPathComponent()
            try validateRegularDirectory(parent)
        } catch {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
    }

    private func validateRegularDirectory(_ URL: URL) throws {
        guard
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil
        else {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
        let values = try URL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HLSLocalStreamAssemblyError.invalidDestination
        }
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
            let addition = copied.addingReportingOverflow(Int64(data.count))
            guard !addition.overflow else {
                throw HLSLocalStreamAssemblyError.byteCountOverflow
            }
            copied = addition.partialValue
            try await copyCheckpoint(copied)
        }
    }

    private func verificationRequirements(
        for input: HLSLocalStreamAssemblyInput
    ) -> MediaVerificationRequirements {
        MediaVerificationRequirements(
            expectedContainer: nil,
            expectedFileExtension: nil,
            expectedVideoStreams:
                input.selection.hasVideo ? 1 ... Int.max : 0 ... 0,
            expectedAudioStreams:
                input.selection.hasAudio ? 1 ... Int.max : 0 ... 0,
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

    private func discardAssemblyDirectory(_ URL: URL) -> Bool {
        if fileManager.fileExists(atPath: URL.path) {
            try? fileManager.removeItem(at: URL)
        }
        return !fileManager.fileExists(atPath: URL.path)
    }

    private func deterministicFilename(
        for resource: StagedHLSResource
    ) -> String {
        let role = resource.kind == .initialization ? "init" : "media"
        return String(
            format: "resource-%06d-%@.part",
            resource.position,
            role
        )
    }

    private func isValidSelection(
        _ selection: ResolvedHLSPlaylistSelection
    ) -> Bool {
        selection.videoID.utf8.count == 11
            && selection.videoID.utf8.allSatisfy({
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
                    || $0 == 95
            })
            && !selection.formatID.isEmpty
            && selection.formatID.utf8.count <= 256
            && ["m3u8", "m3u8_native"].contains(selection.protocolName)
            && selection.sourceType == "hls"
            && ["m4a", "mp4", "webm"].contains(selection.fileExtension)
            && (selection.hasVideo || selection.hasAudio)
            && HLSPlaylistSecurity.areAllowedHeaders(selection.HTTPHeaders)
            && HLSPlaylistSecurity.isAllowedPlaylistURL(
                selection.mediaPlaylistURL
            )
            && (0...HLSPlaylistSessionPolicy.secure.maximumRedirects)
                .contains(selection.redirectCount)
            && selection.route == .directMedia
            && selection.playlistRequestCount == 1
            && selection.masterVariantCount == 0
            && selection.mediaSegmentCount
                == selection.resourcePlan.mediaSegmentCount
            && HLSPlaylistParser.isValidMediaResourcePlan(
                selection.resourcePlan
            )
    }

    private func hasValidDiscontinuityTopology(
        _ events: [HLSMediaPlaylistEvent]
    ) -> Bool {
        var hasMediaBeforeBoundary = false
        var boundaryAwaitingMedia = false
        for event in events {
            switch event {
            case .initialization:
                continue
            case .media:
                hasMediaBeforeBoundary = true
                boundaryAwaitingMedia = false
            case .discontinuity:
                guard
                    hasMediaBeforeBoundary,
                    !boundaryAwaitingMedia
                else {
                    return false
                }
                boundaryAwaitingMedia = true
            }
        }
        return !boundaryAwaitingMedia
    }

    private func isValidStagingRelativePath(_ relativePath: String) -> Bool {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            components.count == 2,
            components[0] == "HLS-Staging"
        else {
            return false
        }
        let name = components[1]
        guard name.hasPrefix("task-") else { return false }
        let UUIDs = name.dropFirst("task-".count)
        guard UUIDs.utf8.count == 73 else { return false }
        let separator = UUIDs.index(UUIDs.startIndex, offsetBy: 36)
        guard UUIDs[separator] == "-" else { return false }
        let first = UUIDs[..<separator]
        let second = UUIDs[UUIDs.index(after: separator)...]
        return isCanonicalLowercaseUUID(first)
            && isCanonicalLowercaseUUID(second)
    }

    private func isCanonicalLowercaseUUID(_ value: Substring) -> Bool {
        guard let uuid = UUID(uuidString: String(value)) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

enum HLSLocalStreamAssemblyError: LocalizedError, Equatable, Sendable {
    case invalidInput
    case invalidStagingDirectory
    case invalidDestination
    case invalidResource(position: Int)
    case resourceByteCountMismatch(
        position: Int,
        expected: Int64,
        actual: Int64
    )
    case byteCountOverflow
    case aggregateByteCountMismatch
    case couldNotAssemble
    case nativeValidationFailed
    case couldNotPublish
    case couldNotCleanAssembly

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "The staged HLS assembly input is invalid."
        case .invalidStagingDirectory:
            "The HLS staging directory is not an accepted task-owned location."
        case .invalidDestination:
            "The private HLS assembly destination is not app controlled."
        case let .invalidResource(position):
            "HLS resource \(position) is not an accepted app-controlled regular file."
        case let .resourceByteCountMismatch(position, expected, actual):
            "HLS resource \(position) has \(actual) bytes; expected \(expected)."
        case .byteCountOverflow:
            "The staged HLS byte total is invalid."
        case .aggregateByteCountMismatch:
            "The assembled HLS byte total is invalid."
        case .couldNotAssemble:
            "The accepted HLS resources could not be assembled."
        case .nativeValidationFailed:
            "The assembled HLS stream did not pass native validation."
        case .couldNotPublish:
            "The validated HLS stream could not be published privately."
        case .couldNotCleanAssembly:
            "Rejected private HLS assembly bytes could not be removed."
        }
    }
}
