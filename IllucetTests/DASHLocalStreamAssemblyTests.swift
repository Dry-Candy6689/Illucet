import Foundation
import Testing
@testable import Illucet

@Suite("P10.3 checkpoint A DASH local stream assembly", .serialized)
struct DASHLocalStreamAssemblyTests {
    @Test
    func assemblesExactOrderAndExplicitRepeatedEntries() async throws {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let parts = [Data("init".utf8), Data("media".utf8), Data("init".utf8)]
        let staged = try fixture.stage(parts)
        let plan = fixture.plan(
            byteCounts: parts.map { Int64($0.count) },
            repeatedEntries: true
        )
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: AssemblyProbeProcessor(role: .video),
            destinationRoots: fixture.roots
        )

        #expect(plan.fragments[0].URL == plan.fragments[2].URL)
        let result = try await assembler.assemble(
            DASHLocalStreamAssemblyInput(
                plan: plan,
                stagingResult: staged,
                destinationDirectoryURL: fixture.outputDirectory
            )
        )

        #expect(result.videoID == plan.videoID)
        #expect(result.formatID == plan.formatID)
        #expect(result.fileExtension == "mp4")
        #expect(result.byteCount == 13)
        #expect(result.probe.fileURL == result.fileURL)
        #expect(result.probe.videoStreamCount == 1)
        #expect(try Data(contentsOf: result.fileURL) == parts.reduce(Data(), +))
        #expect(staged.fragments.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(
            try fixture.outputFiles().map(\.lastPathComponent)
                == [result.fileURL.lastPathComponent]
        )
        #expect(
            !result.fileURL.lastPathComponent.localizedCaseInsensitiveContains(
                "sig"
            )
        )
    }

    @Test
    func rejectsGapsReorderingAndOverflowBeforeCreatingOutput() async throws {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let staged = try fixture.stage([Data("a".utf8), Data("b".utf8)])
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: AssemblyProbeProcessor(role: .video),
            destinationRoots: fixture.roots
        )
        let valid = fixture.plan(byteCounts: [1, 1])
        let gap = ResolvedDASHFragmentPlan(
            videoID: valid.videoID,
            formatID: valid.formatID,
            protocolName: valid.protocolName,
            sourceType: valid.sourceType,
            fileExtension: valid.fileExtension,
            hasVideo: valid.hasVideo,
            hasAudio: valid.hasAudio,
            HTTPHeaders: valid.HTTPHeaders,
            fragments: [
                valid.fragments[0],
                ResolvedDASHFragment(
                    position: 2,
                    URL: valid.fragments[1].URL,
                    expectedBytes: 1
                ),
            ],
            resolvedAt: .now
        )
        await #expect(throws: DASHLocalStreamAssemblyError.invalidInput) {
            _ = try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: gap,
                    stagingResult: staged,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }

        let reordered = DASHFragmentStagingResult(
            videoID: staged.videoID,
            formatID: staged.formatID,
            fragments: Array(staged.fragments.reversed())
        )
        await #expect(throws: DASHLocalStreamAssemblyError.invalidInput) {
            _ = try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: valid,
                    stagingResult: reordered,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }

        let overflowing = DASHFragmentStagingResult(
            videoID: staged.videoID,
            formatID: staged.formatID,
            fragments: [
                StagedDASHFragment(
                    position: 0,
                    fileURL: staged.fragments[0].fileURL,
                    byteCount: Int64.max
                ),
                StagedDASHFragment(
                    position: 1,
                    fileURL: staged.fragments[1].fileURL,
                    byteCount: 1
                ),
            ]
        )
        let overflowPlan = fixture.plan(
            byteCounts: [Int64.max, 1],
            aggregateBytes: nil
        )
        await #expect(
            throws: DASHLocalStreamAssemblyError.byteCountOverflow
        ) {
            _ = try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: overflowPlan,
                    stagingResult: overflowing,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }

        let aggregateMismatch = ResolvedDASHFragmentPlan(
            videoID: valid.videoID,
            formatID: valid.formatID,
            protocolName: valid.protocolName,
            sourceType: valid.sourceType,
            fileExtension: valid.fileExtension,
            hasVideo: valid.hasVideo,
            hasAudio: valid.hasAudio,
            HTTPHeaders: valid.HTTPHeaders,
            expectedBytes: 3,
            fragments: valid.fragments,
            resolvedAt: .now
        )
        await #expect(
            throws: DASHLocalStreamAssemblyError.aggregateByteCountMismatch
        ) {
            _ = try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: aggregateMismatch,
                    stagingResult: staged,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }
        #expect(try fixture.outputFiles().isEmpty)
    }

    @Test
    func rejectsOutsideSymlinkMissingDirectoryAndMutatedFragments()
        async throws
    {
        for kind in DASHInvalidFragmentKind.allCases {
            let fixture = try DASHAssemblyFixture()
            defer { fixture.cleanup() }
            var staged = try fixture.stage([Data("accepted".utf8)])
            let plan = fixture.plan(
                byteCounts: [nil],
                aggregateBytes: nil
            )
            let originalURL = staged.fragments[0].fileURL
            switch kind {
            case .outside:
                let outside = fixture.root.appending(
                    path: "fragment-000000.part"
                )
                try Data("accepted".utf8).write(to: outside)
                staged = fixture.stagingResult(
                    URLs: [outside],
                    byteCounts: [8]
                )
            case .symlink:
                let target = fixture.stagingDirectory.appending(
                    path: "target.part"
                )
                try Data("accepted".utf8).write(to: target)
                try FileManager.default.removeItem(at: originalURL)
                try FileManager.default.createSymbolicLink(
                    at: originalURL,
                    withDestinationURL: target
                )
            case .missing:
                try FileManager.default.removeItem(at: originalURL)
            case .directory:
                try FileManager.default.removeItem(at: originalURL)
                try FileManager.default.createDirectory(
                    at: originalURL,
                    withIntermediateDirectories: false
                )
            case .mutatedLength:
                try Data("accepted-mutated".utf8).write(
                    to: originalURL,
                    options: .atomic
                )
            }
            let assembler = DASHLocalStreamAssembler(
                mediaProcessor: AssemblyProbeProcessor(role: .video),
                destinationRoots: fixture.roots
            )

            await #expect(
                throws: DASHLocalStreamAssemblyError.invalidFragment(
                    position: 0
                )
            ) {
                _ = try await assembler.assemble(
                    DASHLocalStreamAssemblyInput(
                        plan: plan,
                        stagingResult: staged,
                        destinationDirectoryURL: fixture.outputDirectory
                    )
                )
            }
            #expect(try fixture.outputFiles().isEmpty)
        }
    }

    @Test
    func rejectsInvalidDestinationWithoutPublishingOutput() async throws {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let staged = try fixture.stage([Data("accepted".utf8)])
        let plan = fixture.plan(byteCounts: [8])
        let outside = fixture.root.appending(
            path: "Outside-Assembly",
            directoryHint: .isDirectory
        )
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: AssemblyProbeProcessor(role: .video),
            destinationRoots: fixture.roots
        )

        await #expect(
            throws: DASHLocalStreamAssemblyError.invalidDestination
        ) {
            _ = try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: plan,
                    stagingResult: staged,
                    destinationDirectoryURL: outside
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func cancellationDuringProbeRemovesPartialAndPreservesFragments()
        async throws
    {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let staged = try fixture.stage([Data("accepted".utf8)])
        let processor = CancellingAssemblyProbeProcessor()
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: processor,
            destinationRoots: fixture.roots
        )
        let operation = Task {
            try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: fixture.plan(byteCounts: [8]),
                    stagingResult: staged,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }
        try await waitUntil { await processor.probeStarted }

        operation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(try fixture.outputFiles().isEmpty)
        #expect(staged.fragments.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    @Test
    func cancellationDuringStreamingCopyRemovesPartialAndPreservesFragments()
        async throws
    {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let bytes = Data(
            repeating: 0x5A,
            count: DASHLocalStreamAssembler.copyBufferBytes * 2
        )
        let staged = try fixture.stage([bytes])
        let checkpoint = CancellingCopyCheckpoint()
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: AssemblyProbeProcessor(role: .video),
            destinationRoots: fixture.roots,
            copyCheckpoint: checkpoint.wait
        )
        let operation = Task {
            try await assembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: fixture.plan(
                        byteCounts: [Int64(bytes.count)]
                    ),
                    stagingResult: staged,
                    destinationDirectoryURL: fixture.outputDirectory
                )
            )
        }
        try await waitUntil { await checkpoint.copyStarted }

        operation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(try fixture.outputFiles().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: staged.fragments[0].fileURL.path
        ))
    }

    @Test
    func fragmentedMP4AssemblyPassesNativeFullDecode() async throws {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appending(path: "source-fragmented.mp4")
        try generateDASHFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let parts = try fragmentedParts(sourceData)
        let staged = try fixture.stage(parts)
        let plan = fixture.plan(
            byteCounts: parts.map { Int64($0.count) }
        )
        let assembler = DASHLocalStreamAssembler(
            mediaProcessor: NativeFFmpegMediaProcessor(),
            destinationRoots: fixture.roots
        )

        let result = try await assembler.assemble(
            DASHLocalStreamAssemblyInput(
                plan: plan,
                stagingResult: staged,
                destinationDirectoryURL: fixture.outputDirectory,
                verificationClass: .strongFullDecode
            )
        )

        #expect(try Data(contentsOf: result.fileURL) == sourceData)
        #expect(result.probe.videoStreamCount == 1)
        #expect(result.probe.audioStreamCount == 0)
        #expect(result.probe.formatNames.contains("mp4"))
        #expect(
            result.probe.verificationEvidence?.verificationClass
                == .strongFullDecode
        )
        #expect(result.probe.verificationEvidence?.fullDecodePerformed == true)
    }

    @Test
    func nativeProbeRejectsTruncatedCorruptAndWrongRoleAssemblies()
        async throws
    {
        let fixture = try DASHAssemblyFixture()
        defer { fixture.cleanup() }
        let fragmented = fixture.root.appending(path: "fragmented.mp4")
        try generateDASHFixture(at: fragmented)
        let fragmentedData = try Data(contentsOf: fragmented)
        let fragmentedParts = try fragmentedParts(fragmentedData)

        let standard = try generateStandardFixtures(in: fixture.root)
        let cases: [(String, Data, String)] = [
            ("truncated", fragmentedParts[0], "mp4"),
            ("corrupt", Data(repeating: 0xA5, count: 1_024), "mp4"),
            ("wrong-role", try Data(contentsOf: standard.audio), "m4a"),
        ]
        let processor = NativeFFmpegMediaProcessor()
        for (index, item) in cases.enumerated() {
            let caseFixture = try DASHAssemblyFixture(
                beneath: fixture.root,
                name: "Case-\(index)"
            )
            let staged = try caseFixture.stage([item.1])
            let plan = caseFixture.plan(
                byteCounts: [Int64(item.1.count)],
                fileExtension: item.2,
                hasVideo: true,
                hasAudio: false
            )
            let assembler = DASHLocalStreamAssembler(
                mediaProcessor: processor,
                destinationRoots: caseFixture.roots
            )

            await #expect(
                throws: DASHLocalStreamAssemblyError.nativeValidationFailed
            ) {
                _ = try await assembler.assemble(
                    DASHLocalStreamAssemblyInput(
                        plan: plan,
                        stagingResult: staged,
                        destinationDirectoryURL: caseFixture.outputDirectory,
                        verificationClass: .strongFullDecode
                    )
                )
            }
            #expect(try caseFixture.outputFiles().isEmpty)
            #expect(FileManager.default.fileExists(
                atPath: staged.fragments[0].fileURL.path
            ))
            _ = item.0
        }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 2_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the assembly probe.")
    }

    private func fragmentedParts(_ data: Data) throws -> [Data] {
        let marker = Data("moof".utf8)
        let range = try #require(data.range(of: marker))
        let markerOffset = data.distance(
            from: data.startIndex,
            to: range.lowerBound
        )
        let splitOffset = markerOffset - 4
        #expect(splitOffset > 0)
        return [
            data.subdata(in: 0 ..< splitOffset),
            data.subdata(in: splitOffset ..< data.count),
        ]
    }

    private func generateDASHFixture(at URL: URL) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = URL.path.withCString {
            illucet_ffmpeg_generate_dash_fixture($0, nil, &rawError)
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "Fragmented fixture generation failed."
            )
        }
    }

    private func generateStandardFixtures(
        in root: URL
    ) throws -> (video: URL, audio: URL, incompatible: URL, artwork: URL) {
        let video = root.appending(path: "fixture-video.mp4")
        let audio = root.appending(path: "fixture-audio.m4a")
        let incompatible = root.appending(path: "fixture-incompatible.mkv")
        let artwork = root.appending(path: "fixture-artwork.jpg")
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(
                            videoPath,
                            audioPath,
                            incompatiblePath,
                            artworkPath,
                            nil,
                            &rawError
                        )
                    }
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "Fixture generation failed."
            )
        }
        return (video, audio, incompatible, artwork)
    }
}

private enum DASHInvalidFragmentKind: CaseIterable {
    case outside
    case symlink
    case missing
    case directory
    case mutatedLength
}

private struct DASHAssemblyFixture {
    let root: URL
    let roots: StreamTransferDestinationRoots
    let stagingDirectory: URL
    let outputDirectory: URL

    init(
        beneath parent: URL = FileManager.default.temporaryDirectory,
        name: String = "Illucet-DASH-Assembly-\(UUID().uuidString)"
    ) throws {
        root = parent.appending(path: name, directoryHint: .isDirectory)
        let temporary = root.appending(
            path: "Temporary",
            directoryHint: .isDirectory
        )
        let support = root.appending(
            path: "ApplicationSupport",
            directoryHint: .isDirectory
        )
        roots = StreamTransferDestinationRoots(
            temporaryDirectory: temporary,
            applicationSupportDirectory: support
        )
        stagingDirectory = support.appending(
            path: "Fragments",
            directoryHint: .isDirectory
        )
        outputDirectory = temporary.appending(
            path: "Assembled",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func stage(_ parts: [Data]) throws -> DASHFragmentStagingResult {
        var URLs: [URL] = []
        for (position, part) in parts.enumerated() {
            let URL = stagingDirectory.appending(
                path: String(format: "fragment-%06d.part", position)
            )
            try part.write(to: URL)
            URLs.append(URL)
        }
        return stagingResult(
            URLs: URLs,
            byteCounts: parts.map { Int64($0.count) }
        )
    }

    func stagingResult(
        URLs: [URL],
        byteCounts: [Int64]
    ) -> DASHFragmentStagingResult {
        DASHFragmentStagingResult(
            videoID: "AbCdEf123_-",
            formatID: "137-dashy",
            fragments: zip(URLs, byteCounts).enumerated().map {
                StagedDASHFragment(
                    position: $0.offset,
                    fileURL: $0.element.0,
                    byteCount: $0.element.1
                )
            }
        )
    }

    func plan(
        byteCounts: [Int64?],
        aggregateBytes: Int64? = nil,
        fileExtension: String = "mp4",
        hasVideo: Bool = true,
        hasAudio: Bool = false,
        repeatedEntries: Bool = false
    ) -> ResolvedDASHFragmentPlan {
        let total: Int64? = aggregateBytes ?? exactSum(byteCounts)
        let repeated = URL(
            string: "https://rr1---sn.example.googlevideo.com/init?sig=repeated"
        )!
        return ResolvedDASHFragmentPlan(
            videoID: "AbCdEf123_-",
            formatID: "137-dashy",
            protocolName: "http_dash_segments",
            sourceType: "dash",
            fileExtension: fileExtension,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            HTTPHeaders: ["User-Agent": "Illucet-DASH-Test"],
            expectedBytes: total,
            fragments: byteCounts.enumerated().map { position, count in
                ResolvedDASHFragment(
                    position: position,
                    URL: repeatedEntries
                            && (position == 0 || position == byteCounts.count - 1)
                        ? repeated
                        : URL(
                            string:
                                "https://rr1---sn.example.googlevideo.com/"
                                + "fragment-\(position)?sig=fixture"
                        )!,
                    expectedBytes: count
                )
            },
            resolvedAt: .now
        )
    }

    func outputFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: outputDirectory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        )
    }

    private func exactSum(_ byteCounts: [Int64?]) -> Int64? {
        var result: Int64 = 0
        for count in byteCounts {
            guard let count else { return nil }
            let addition = result.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}

private actor AssemblyProbeProcessor: MediaProcessor {
    enum Role: Sendable {
        case video
        case audio
    }

    let role: Role

    init(role: Role) {
        self.role = role
    }

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        _ = request
        _ = progress
        throw MediaProcessorError.invalidRequest("Probe-only test processor.")
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        let size = try #require(
            try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let kind: MediaStreamKind = role == .video ? .video : .audio
        return MediaProbeResult(
            fileURL: fileURL,
            formatNames: fileURL.pathExtension == "webm"
                ? ["matroska", "webm"]
                : ["mov", "mp4", "m4a"],
            formatLongName: nil,
            durationSeconds: 1,
            startTimeSeconds: 0,
            bitRate: nil,
            fileSize: Int64(size),
            metadata: [:],
            streams: [Self.stream(kind: kind)],
            chapters: [],
            verificationEvidence: MediaProbeEvidence(
                verificationClass: verificationClass,
                fullDecodePerformed: verificationClass == .strongFullDecode,
                packetsInspected: 1,
                inspectedPacketBytes: Int64(size),
                tailInspectionAttempted:
                    verificationClass != .strongFullDecode,
                tailInspectionSucceeded:
                    verificationClass != .strongFullDecode,
                tailInspectionReachedEOF:
                    verificationClass != .strongFullDecode
            )
        )
    }

    func cancel(operationID: UUID) async {
        _ = operationID
    }

    private static func stream(kind: MediaStreamKind) -> MediaStreamProbe {
        MediaStreamProbe(
            index: 0,
            kind: kind,
            codecName: kind == .video ? "h264" : "aac",
            codecLongName: nil,
            codecProfile: nil,
            codecTag: nil,
            durationSeconds: 1,
            bitRate: nil,
            timeBase: nil,
            disposition: MediaStreamDisposition(
                isDefault: true,
                forced: false,
                attachedPicture: false
            ),
            metadata: [:],
            video: kind == .video
                ? VideoStreamProbe(
                    width: 16,
                    height: 16,
                    pixelFormat: "yuv420p",
                    averageFrameRate: nil,
                    realFrameRate: nil,
                    colorSpace: nil,
                    colorTransfer: nil,
                    colorPrimaries: nil,
                    colorRange: nil,
                    fieldOrder: nil,
                    isHDR: false
                )
                : nil,
            audio: kind == .audio
                ? AudioStreamProbe(
                    sampleFormat: nil,
                    sampleRate: 48_000,
                    channelCount: 2,
                    channelLayout: "stereo",
                    bitsPerSample: nil
                )
                : nil,
            subtitle: nil,
            decodedFrames: 1,
            decodedSampleWindows: 3
        )
    }
}

private actor CancellingAssemblyProbeProcessor: MediaProcessor {
    private(set) var probeStarted = false

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        _ = request
        _ = progress
        throw MediaProcessorError.invalidRequest("Probe-only test processor.")
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        _ = fileURL
        _ = verificationClass
        probeStarted = true
        try await Task.sleep(for: .seconds(30))
        throw MediaProcessorError.probeFailure("Unexpected wakeup.")
    }

    func cancel(operationID: UUID) async {
        _ = operationID
    }
}

private actor CancellingCopyCheckpoint {
    private(set) var copyStarted = false

    func wait(_ copiedBytes: Int64) async throws {
        _ = copiedBytes
        copyStarted = true
        try await Task.sleep(for: .seconds(30))
    }
}
