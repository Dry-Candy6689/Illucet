import Foundation
import Testing
@testable import Illucet

@Suite("P10.5 checkpoint B HLS local stream assembly", .serialized)
struct HLSLocalStreamAssemblyTests {
    @Test
    func assemblesExactEventsRangesBoundariesAndExplicitRepeats()
        async throws
    {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection()
        let parts = ["init", "aaaa", "next", "bbbb"].map {
            Data($0.utf8)
        }
        let staged = try fixture.stage(selection, parts: parts)
        let assembler = HLSLocalStreamAssembler(
            mediaProcessor: HLSAssemblyProbeProcessor(role: .video),
            destinationRoots: fixture.roots
        )

        let plannedResources = selection.resourcePlan.events.compactMap(
            \.resource
        )
        #expect(plannedResources[0].URL == plannedResources[2].URL)
        #expect(plannedResources[1].URL == plannedResources[3].URL)
        #expect(selection.resourcePlan.events[2]
            == .discontinuity(eventPosition: 2))

        let result = try await assembler.assemble(
            HLSLocalStreamAssemblyInput(
                selection: selection,
                stagingResult: staged
            )
        )

        #expect(result.videoID == selection.videoID)
        #expect(result.formatID == selection.formatID)
        #expect(result.byteCount == 16)
        #expect(result.fileURL.pathExtension == "media")
        #expect(result.probe.fileURL == result.fileURL)
        #expect(result.probe.videoStreamCount == 1)
        #expect(try Data(contentsOf: result.fileURL) == parts.reduce(Data(), +))
        #expect(result.fileURL.deletingLastPathComponent()
            == result.assemblyDirectoryURL)
        #expect(result.assemblyDirectoryURL.deletingLastPathComponent()
            == fixture.roots.temporaryDirectory.appending(
                path: "HLS-Assembly",
                directoryHint: .isDirectory
            ))
        #expect(staged.events.compactMap(\.resource).allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(try fixture.assemblyFiles() == [result.fileURL])
        for forbidden in ["sig", "token", "authorization", "cookie"] {
            #expect(!result.fileURL.path.lowercased().contains(forbidden))
        }
    }

    @Test
    func validatedAssemblyPublishesExactBytesIntoJobLocalSourceLifecycle()
        async throws
    {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection()
        let parts = ["init", "aaaa", "next", "bbbb"].map {
            Data($0.utf8)
        }
        let staged = try fixture.stage(selection, parts: parts)
        let jobID = UUID()
        let jobRoot = fixture.roots.temporaryDirectory.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: jobRoot,
            withIntermediateDirectories: false
        )
        let destination = jobRoot.appending(
            path: "\(selection.formatID).\(selection.fileExtension)"
        )

        let result = try await fixture.assembler().assemble(
            HLSLocalStreamAssemblyInput(
                selection: selection,
                stagingResult: staged,
                jobLocalDestinationURL: destination,
                jobTemporaryRootURL: jobRoot
            )
        )

        #expect(result.fileURL == destination)
        #expect(result.probe.fileURL == destination)
        #expect(result.probe.fileSize == result.byteCount)
        #expect(try Data(contentsOf: destination) == parts.reduce(Data(), +))
        let values = try destination.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink != true)
        #expect(!FileManager.default.fileExists(
            atPath: result.assemblyDirectoryURL.path
        ))
        #expect(try fixture.assemblyFiles().isEmpty)
    }

    @Test
    func jobLocalPublicationRejectsNonJobRootAndCleansPrivateAssembly()
        async throws
    {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection(
            playlist: HLSAssemblyFixture.singleMediaPlaylist
        )
        let staged = try fixture.stage(
            selection,
            parts: [Data("accepted".utf8)]
        )
        let invalidRoot = fixture.roots.temporaryDirectory.appending(
            path: "not-a-job-root",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: invalidRoot,
            withIntermediateDirectories: false
        )
        let destination = invalidRoot.appending(path: "source.mp4")

        await #expect(
            throws: HLSLocalStreamAssemblyError.invalidDestination
        ) {
            _ = try await fixture.assembler().assemble(
                HLSLocalStreamAssemblyInput(
                    selection: selection,
                    stagingResult: staged,
                    jobLocalDestinationURL: destination,
                    jobTemporaryRootURL: invalidRoot
                )
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try fixture.assemblyFiles().isEmpty)
        #expect(staged.events.compactMap(\.resource).allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    @Test
    func rejectsSelectionIdentityAndEventMutationsBeforeOutputCreation()
        async throws
    {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection()
        let staged = try fixture.stage(
            selection,
            parts: ["init", "aaaa", "next", "bbbb"].map {
                Data($0.utf8)
            }
        )
        let assembler = fixture.assembler()

        var cases: [HLSResourceStagingResult] = [
            fixture.replacing(staged, videoID: "WrongID123_"),
            fixture.replacing(staged, formatID: "wrong-format"),
            fixture.replacing(staged, events: Array(staged.events.dropLast())),
            fixture.replacing(
                staged,
                events: staged.events + [
                    .discontinuity(eventPosition: staged.events.count),
                ]
            ),
            fixture.replacing(staged, events: Array(staged.events.reversed())),
        ]

        if case let .initialization(eventPosition, resource) = staged.events[0]
        {
            cases.append(
                fixture.replacing(
                    staged,
                    events: fixture.replacingEvent(
                        in: staged.events,
                        at: 0,
                        with: .initialization(
                            eventPosition: eventPosition + 1,
                            resource: resource
                        )
                    )
                )
            )
            cases.append(
                fixture.replacing(
                    staged,
                    events: fixture.replacingResource(
                        in: staged.events,
                        at: 0,
                        with: fixture.replacing(resource, kind: .media)
                    )
                )
            )
        }
        if case let .media(eventPosition, resource, initialization) =
            staged.events[1]
        {
            cases.append(
                fixture.replacing(
                    staged,
                    events: fixture.replacingEvent(
                        in: staged.events,
                        at: 1,
                        with: .media(
                            eventPosition: eventPosition,
                            resource: resource,
                            initializationEventPosition:
                                initialization == nil ? 0 : nil
                        )
                    )
                )
            )
            cases.append(
                fixture.replacing(
                    staged,
                    events: fixture.replacingResource(
                        in: staged.events,
                        at: 1,
                        with: fixture.replacing(
                            resource,
                            position: resource.position + 1
                        )
                    )
                )
            )
            cases.append(
                fixture.replacing(
                    staged,
                    events: fixture.replacingResource(
                        in: staged.events,
                        at: 1,
                        with: fixture.replacing(
                            resource,
                            byteRange: HLSMediaByteRange(
                                offset: 8,
                                length: 4
                            ),
                            replaceByteRange: true
                        )
                    )
                )
            )
        }

        for item in cases {
            await #expect(throws: HLSLocalStreamAssemblyError.invalidInput) {
                _ = try await assembler.assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: item
                    )
                )
            }
        }
        #expect(try fixture.assemblyFiles().isEmpty)
    }

    @Test
    func rejectsMalformedDiscontinuityTopologyBeforeOutputCreation()
        async throws
    {
        for playlist in HLSAssemblyFixture.malformedBoundaryPlaylists {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection(playlist: playlist)
            let resourceCount = selection.resourcePlan.events.compactMap(
                \.resource
            ).count
            let staged = try fixture.stage(
                selection,
                parts: Array(repeating: Data("data".utf8), count: resourceCount)
            )

            await #expect(throws: HLSLocalStreamAssemblyError.invalidInput) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
            #expect(try fixture.assemblyFiles().isEmpty)
        }
    }

    @Test
    func rejectsInvalidStagingFilesDirectoriesAndDeterministicNames()
        async throws
    {
        for kind in HLSInvalidStagingKind.allCases {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection()
            var staged = try fixture.stage(
                selection,
                parts: ["init", "aaaa", "next", "bbbb"].map {
                    Data($0.utf8)
                }
            )
            let resource = try #require(staged.events[0].resource)
            let originalURL = resource.fileURL

            switch kind {
            case .outsideRoot:
                let outside = fixture.root.appending(
                    path: originalURL.lastPathComponent
                )
                try Data("init".utf8).write(to: outside)
                staged = fixture.replacing(
                    staged,
                    events: fixture.replacingResource(
                        in: staged.events,
                        at: 0,
                        with: fixture.replacing(resource, fileURL: outside)
                    )
                )
            case .wrongStagingDirectory:
                let wrong = fixture.roots.applicationSupportDirectory
                    .appending(path: "Not-HLS-Staging", directoryHint: .isDirectory)
                    .appending(path: "task-wrong", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: wrong,
                    withIntermediateDirectories: true
                )
                for event in staged.events {
                    guard let item = event.resource else { continue }
                    try FileManager.default.moveItem(
                        at: item.fileURL,
                        to: wrong.appending(path: item.fileURL.lastPathComponent)
                    )
                }
                staged = fixture.relocating(staged, to: wrong)
            case .symlink:
                let target = fixture.root.appending(path: "symlink-target")
                try Data("init".utf8).write(to: target)
                try FileManager.default.removeItem(at: originalURL)
                try FileManager.default.createSymbolicLink(
                    at: originalURL,
                    withDestinationURL: target
                )
            case .directory:
                try FileManager.default.removeItem(at: originalURL)
                try FileManager.default.createDirectory(
                    at: originalURL,
                    withIntermediateDirectories: false
                )
            case .missing:
                try FileManager.default.removeItem(at: originalURL)
            case .mutatedByteCount:
                try FileHandle(forWritingTo: originalURL).closeAfterAppending(
                    Data("!".utf8)
                )
            case .wrongFilename:
                let wrong = originalURL.deletingLastPathComponent()
                    .appending(path: "resource-wrong.part")
                try FileManager.default.moveItem(at: originalURL, to: wrong)
                staged = fixture.replacing(
                    staged,
                    events: fixture.replacingResource(
                        in: staged.events,
                        at: 0,
                        with: fixture.replacing(resource, fileURL: wrong)
                    )
                )
            case .extraFile:
                try Data("extra".utf8).write(
                    to: fixture.stagingDirectory.appending(path: "extra.part")
                )
            }

            await #expect(throws: HLSLocalStreamAssemblyError.self) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
            #expect(try fixture.assemblyFiles().isEmpty)
        }
    }

    @Test
    func rejectsDuplicatePathsAndHardLinkedResourceIdentity() async throws {
        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection()
            var staged = try fixture.stage(
                selection,
                parts: Array(repeating: Data("same".utf8), count: 4)
            )
            let first = try #require(staged.events[0].resource)
            let second = try #require(staged.events[1].resource)
            staged = fixture.replacing(
                staged,
                events: fixture.replacingResource(
                    in: staged.events,
                    at: 1,
                    with: fixture.replacing(second, fileURL: first.fileURL)
                )
            )

            await #expect(throws: HLSLocalStreamAssemblyError.invalidInput) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
        }

        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection()
            let staged = try fixture.stage(
                selection,
                parts: Array(repeating: Data("same".utf8), count: 4)
            )
            let first = try #require(staged.events[0].resource)
            let second = try #require(staged.events[1].resource)
            try FileManager.default.removeItem(at: second.fileURL)
            try FileManager.default.linkItem(
                at: first.fileURL,
                to: second.fileURL
            )

            await #expect(throws: HLSLocalStreamAssemblyError.invalidInput) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
            #expect(try fixture.assemblyFiles().isEmpty)
        }
    }

    @Test
    func rejectsZeroAggregateAndInt64Overflow() async throws {
        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection(
                playlist: HLSAssemblyFixture.singleMediaPlaylist
            )
            let staged = try fixture.stage(selection, parts: [Data()])

            await #expect(
                throws: HLSLocalStreamAssemblyError
                    .aggregateByteCountMismatch
            ) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
        }

        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection(
                playlist: HLSAssemblyFixture.twoMediaPlaylist
            )
            let staged = try fixture.stage(
                selection,
                parts: [Data("a".utf8), Data("b".utf8)]
            )
            let overflowing = fixture.replacingByteCounts(
                staged,
                with: [Int64.max, 1]
            )

            await #expect(
                throws: HLSLocalStreamAssemblyError.byteCountOverflow
            ) {
                _ = try await fixture.assembler().assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: overflowing
                    )
                )
            }
            #expect(try fixture.assemblyFiles().isEmpty)
        }
    }

    @Test
    func cancellationDuringCopyAndProbeCleansOnlyPrivateAssembly()
        async throws
    {
        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection(
                playlist: HLSAssemblyFixture.singleMediaPlaylist
            )
            let bytes = Data(
                repeating: 0x5A,
                count: HLSLocalStreamAssembler.copyBufferBytes * 2
            )
            let staged = try fixture.stage(selection, parts: [bytes])
            let checkpoint = HLSCancellingCopyCheckpoint()
            let assembler = HLSLocalStreamAssembler(
                mediaProcessor: HLSAssemblyProbeProcessor(role: .video),
                destinationRoots: fixture.roots,
                copyCheckpoint: checkpoint.wait
            )
            let operation = Task {
                try await assembler.assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
            try await waitUntil { await checkpoint.copyStarted }

            operation.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await operation.value
            }
            #expect(try fixture.assemblyFiles().isEmpty)
            #expect(staged.events.compactMap(\.resource).allSatisfy {
                FileManager.default.fileExists(atPath: $0.fileURL.path)
            })
        }

        do {
            let fixture = try HLSAssemblyFixture()
            defer { fixture.cleanup() }
            let selection = try fixture.selection(
                playlist: HLSAssemblyFixture.singleMediaPlaylist
            )
            let staged = try fixture.stage(
                selection,
                parts: [Data("accepted".utf8)]
            )
            let processor = HLSCancellingProbeProcessor()
            let assembler = HLSLocalStreamAssembler(
                mediaProcessor: processor,
                destinationRoots: fixture.roots
            )
            let operation = Task {
                try await assembler.assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged
                    )
                )
            }
            try await waitUntil { await processor.probeStarted }

            operation.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await operation.value
            }
            #expect(try fixture.assemblyFiles().isEmpty)
            #expect(staged.events.compactMap(\.resource).allSatisfy {
                FileManager.default.fileExists(atPath: $0.fileURL.path)
            })
        }
    }

    @Test
    func mutationDuringProbeFailsClosedAndCleansPrivateOutput() async throws {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection(
            playlist: HLSAssemblyFixture.singleMediaPlaylist
        )
        let staged = try fixture.stage(
            selection,
            parts: [Data("accepted".utf8)]
        )
        let stagedURL = try #require(staged.events[0].resource?.fileURL)
        let processor = HLSMutatingProbeProcessor(stagedURL: stagedURL)

        await #expect(
            throws: HLSLocalStreamAssemblyError.resourceByteCountMismatch(
                position: 0,
                expected: 8,
                actual: 9
            )
        ) {
            _ = try await HLSLocalStreamAssembler(
                mediaProcessor: processor,
                destinationRoots: fixture.roots
            ).assemble(
                HLSLocalStreamAssemblyInput(
                    selection: selection,
                    stagingResult: staged
                )
            )
        }
        #expect(try fixture.assemblyFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test
    func fragmentedHLSAssemblyPassesNativeStrongFullDecode() async throws {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appending(path: "source-fragmented.mp4")
        try generateHLSFragmentedFixture(at: source)
        let sourceData = try Data(contentsOf: source)
        let parts = try fragmentedHLSParts(sourceData)
        let selection = try fixture.selection(
            playlist: HLSAssemblyFixture.fragmentedPlaylist
        )
        let staged = try fixture.stage(selection, parts: parts)

        let result = try await HLSLocalStreamAssembler(
            mediaProcessor: NativeFFmpegMediaProcessor(),
            destinationRoots: fixture.roots
        ).assemble(
            HLSLocalStreamAssemblyInput(
                selection: selection,
                stagingResult: staged,
                verificationClass: .strongFullDecode
            )
        )

        #expect(try Data(contentsOf: result.fileURL) == sourceData)
        #expect(result.byteCount == Int64(sourceData.count))
        #expect(result.fileURL.pathExtension == "media")
        #expect(result.probe.videoStreamCount == 1)
        #expect(result.probe.audioStreamCount == 0)
        #expect(result.probe.formatNames.contains("mp4"))
        #expect(result.probe.verificationEvidence?.verificationClass
            == .strongFullDecode)
        #expect(result.probe.verificationEvidence?.fullDecodePerformed == true)
    }

    @Test
    func nativeProbeRejectsTruncatedCorruptAndWrongRoleAssemblies()
        async throws
    {
        let parent = try HLSAssemblyFixture()
        defer { parent.cleanup() }
        let fragmented = parent.root.appending(path: "fragmented.mp4")
        try generateHLSFragmentedFixture(at: fragmented)
        let fragmentedData = try Data(contentsOf: fragmented)
        let initializationOnly = try fragmentedHLSParts(fragmentedData)[0]
        let standard = try generateHLSStandardFixtures(in: parent.root)
        let cases: [(String, Data)] = [
            ("truncated", initializationOnly),
            ("corrupt", Data(repeating: 0xA5, count: 1_024)),
            ("wrong-role", try Data(contentsOf: standard.audio)),
        ]

        for (index, item) in cases.enumerated() {
            let fixture = try HLSAssemblyFixture(
                beneath: parent.root,
                name: "Invalid-\(index)"
            )
            let selection = try fixture.selection(
                playlist: HLSAssemblyFixture.singleMediaPlaylist
            )
            let staged = try fixture.stage(selection, parts: [item.1])

            await #expect(
                throws: HLSLocalStreamAssemblyError.nativeValidationFailed
            ) {
                _ = try await HLSLocalStreamAssembler(
                    mediaProcessor: NativeFFmpegMediaProcessor(),
                    destinationRoots: fixture.roots
                ).assemble(
                    HLSLocalStreamAssemblyInput(
                        selection: selection,
                        stagingResult: staged,
                        verificationClass: .strongFullDecode
                    )
                )
            }
            #expect(try fixture.assemblyFiles().isEmpty)
            #expect(staged.events.compactMap(\.resource).allSatisfy {
                FileManager.default.fileExists(atPath: $0.fileURL.path)
            })
            _ = item.0
        }
    }

    @Test
    func rejectsSymlinkedPrivateAssemblyRoot() async throws {
        let fixture = try HLSAssemblyFixture()
        defer { fixture.cleanup() }
        let selection = try fixture.selection(
            playlist: HLSAssemblyFixture.singleMediaPlaylist
        )
        let staged = try fixture.stage(
            selection,
            parts: [Data("accepted".utf8)]
        )
        let outside = fixture.root.appending(
            path: "Outside-Assembly",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.roots.temporaryDirectory.appending(
                path: "HLS-Assembly",
                directoryHint: .isDirectory
            ),
            withDestinationURL: outside
        )

        await #expect(
            throws: HLSLocalStreamAssemblyError.invalidDestination
        ) {
            _ = try await fixture.assembler().assemble(
                HLSLocalStreamAssemblyInput(
                    selection: selection,
                    stagingResult: staged
                )
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: outside.path
        ).isEmpty)
        #expect(staged.events.compactMap(\.resource).allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 2_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for HLS assembly cancellation.")
    }
}

private enum HLSInvalidStagingKind: CaseIterable {
    case outsideRoot
    case wrongStagingDirectory
    case symlink
    case directory
    case missing
    case mutatedByteCount
    case wrongFilename
    case extraFile
}

private struct HLSAssemblyFixture {
    static let mediaURL = URL(
        string: "https://rr1---sn.example.googlevideo.com/hls/media.m3u8?sig=playlist"
    )!

    static let orderedPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-MAP:URI="shared.mp4?sig=init",BYTERANGE="4@0"
    #EXTINF:6,
    #EXT-X-BYTERANGE:4@0
    shared.mp4?sig=media
    #EXT-X-DISCONTINUITY
    #EXT-X-MAP:URI="shared.mp4?sig=init",BYTERANGE="4@4"
    #EXTINF:6,
    #EXT-X-BYTERANGE:4@4
    shared.mp4?sig=media
    #EXT-X-ENDLIST
    """

    static let singleMediaPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXTINF:6,
    segment?sig=media
    #EXT-X-ENDLIST
    """

    static let twoMediaPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXTINF:6,
    one?sig=media
    #EXTINF:6,
    two?sig=media
    #EXT-X-ENDLIST
    """

    static let fragmentedPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:1
    #EXT-X-MAP:URI="init?sig=private"
    #EXTINF:1,
    media?sig=private
    #EXT-X-ENDLIST
    """

    static let malformedBoundaryPlaylists = [
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        one?sig=media
        #EXT-X-ENDLIST
        """,
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        one?sig=media
        #EXT-X-DISCONTINUITY
        #EXT-X-ENDLIST
        """,
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        one?sig=media
        #EXT-X-DISCONTINUITY
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        two?sig=media
        #EXT-X-ENDLIST
        """,
    ]

    let root: URL
    let roots: StreamTransferDestinationRoots
    let stagingDirectory: URL

    init(
        beneath parent: URL = FileManager.default.temporaryDirectory,
        name: String = "Illucet-HLS-Assembly-\(UUID().uuidString)"
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
        stagingDirectory = support
            .appending(path: "HLS-Staging", directoryHint: .isDirectory)
            .appending(
                path:
                    "task-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())",
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

    func assembler(
        mediaProcessor: any MediaProcessor = HLSAssemblyProbeProcessor(
            role: .video
        )
    ) -> HLSLocalStreamAssembler {
        HLSLocalStreamAssembler(
            mediaProcessor: mediaProcessor,
            destinationRoots: roots
        )
    }

    func selection(
        playlist: String = Self.orderedPlaylist,
        hasVideo: Bool = true,
        hasAudio: Bool = false
    ) throws -> ResolvedHLSPlaylistSelection {
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: Self.mediaURL
        )
        let plan: HLSMediaResourcePlan
        guard case let .media(parsed) = document else {
            throw HLSLocalStreamAssemblyError.invalidInput
        }
        plan = parsed
        return ResolvedHLSPlaylistSelection(
            videoID: "AbCdEf123_-",
            formatID: "hls-private-720",
            protocolName: "m3u8_native",
            sourceType: "hls",
            fileExtension: "mp4",
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            HTTPHeaders: ["User-Agent": "Illucet-HLS-Test"],
            mediaPlaylistURL: Self.mediaURL,
            route: .directMedia,
            playlistRequestCount: 1,
            redirectCount: 0,
            masterVariantCount: 0,
            mediaSegmentCount: plan.mediaSegmentCount,
            resourcePlan: plan,
            resolvedAt: .now
        )
    }

    func stage(
        _ selection: ResolvedHLSPlaylistSelection,
        parts: [Data]
    ) throws -> HLSResourceStagingResult {
        let resources = selection.resourcePlan.events.compactMap(\.resource)
        guard resources.count == parts.count else {
            throw HLSLocalStreamAssemblyError.invalidInput
        }
        var stagedByPosition: [Int: StagedHLSResource] = [:]
        for (resource, part) in zip(resources, parts) {
            let role = resource.kind == .initialization ? "init" : "media"
            let URL = stagingDirectory.appending(
                path: String(
                    format: "resource-%06d-%@.part",
                    resource.position,
                    role
                )
            )
            try part.write(to: URL)
            stagedByPosition[resource.position] = StagedHLSResource(
                position: resource.position,
                kind: resource.kind,
                fileURL: URL,
                byteCount: Int64(part.count),
                byteRange: resource.byteRange
            )
        }
        let events: [StagedHLSPlaylistEvent] = try selection.resourcePlan.events.map { event in
            switch event {
            case let .initialization(eventPosition, resource):
                return .initialization(
                    eventPosition: eventPosition,
                    resource: try requiredStaged(
                        position: resource.position,
                        stagedByPosition: stagedByPosition
                    )
                )
            case let .media(eventPosition, resource, initialization):
                return .media(
                    eventPosition: eventPosition,
                    resource: try requiredStaged(
                        position: resource.position,
                        stagedByPosition: stagedByPosition
                    ),
                    initializationEventPosition: initialization
                )
            case let .discontinuity(eventPosition):
                return .discontinuity(eventPosition: eventPosition)
            }
        }
        return HLSResourceStagingResult(
            videoID: selection.videoID,
            formatID: selection.formatID,
            stagingDirectoryURL: stagingDirectory,
            events: events
        )
    }

    func replacing(
        _ result: HLSResourceStagingResult,
        videoID: String? = nil,
        formatID: String? = nil,
        stagingDirectoryURL: URL? = nil,
        events: [StagedHLSPlaylistEvent]? = nil
    ) -> HLSResourceStagingResult {
        HLSResourceStagingResult(
            videoID: videoID ?? result.videoID,
            formatID: formatID ?? result.formatID,
            stagingDirectoryURL:
                stagingDirectoryURL ?? result.stagingDirectoryURL,
            events: events ?? result.events
        )
    }

    func replacing(
        _ resource: StagedHLSResource,
        position: Int? = nil,
        kind: HLSMediaResourceKind? = nil,
        fileURL: URL? = nil,
        byteCount: Int64? = nil,
        byteRange: HLSMediaByteRange? = nil,
        replaceByteRange: Bool = false
    ) -> StagedHLSResource {
        StagedHLSResource(
            position: position ?? resource.position,
            kind: kind ?? resource.kind,
            fileURL: fileURL ?? resource.fileURL,
            byteCount: byteCount ?? resource.byteCount,
            byteRange: replaceByteRange ? byteRange : resource.byteRange
        )
    }

    func replacingEvent(
        in events: [StagedHLSPlaylistEvent],
        at index: Int,
        with replacement: StagedHLSPlaylistEvent
    ) -> [StagedHLSPlaylistEvent] {
        var result = events
        result[index] = replacement
        return result
    }

    func replacingResource(
        in events: [StagedHLSPlaylistEvent],
        at index: Int,
        with resource: StagedHLSResource
    ) -> [StagedHLSPlaylistEvent] {
        let replacement: StagedHLSPlaylistEvent
        switch events[index] {
        case let .initialization(eventPosition, _):
            replacement = .initialization(
                eventPosition: eventPosition,
                resource: resource
            )
        case let .media(eventPosition, _, initialization):
            replacement = .media(
                eventPosition: eventPosition,
                resource: resource,
                initializationEventPosition: initialization
            )
        case .discontinuity:
            return events
        }
        return replacingEvent(in: events, at: index, with: replacement)
    }

    func relocating(
        _ result: HLSResourceStagingResult,
        to directory: URL
    ) -> HLSResourceStagingResult {
        let events = result.events.map { event in
            guard let resource = event.resource else { return event }
            return replacingEventResource(
                event,
                resource: replacing(
                    resource,
                    fileURL: directory.appending(
                        path: resource.fileURL.lastPathComponent
                    )
                )
            )
        }
        return replacing(
            result,
            stagingDirectoryURL: directory,
            events: events
        )
    }

    func replacingByteCounts(
        _ result: HLSResourceStagingResult,
        with byteCounts: [Int64]
    ) -> HLSResourceStagingResult {
        var next = 0
        let events = result.events.map { event in
            guard let resource = event.resource else { return event }
            let replacement = replacing(
                resource,
                byteCount: byteCounts[next]
            )
            next += 1
            return replacingEventResource(event, resource: replacement)
        }
        return replacing(result, events: events)
    }

    func assemblyFiles() throws -> [URL] {
        let root = roots.temporaryDirectory.appending(
            path: "HLS-Assembly",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return try directories.flatMap {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: nil
            )
        }.sorted { $0.path < $1.path }
    }

    private func requiredStaged(
        position: Int,
        stagedByPosition: [Int: StagedHLSResource]
    ) throws -> StagedHLSResource {
        guard let resource = stagedByPosition[position] else {
            throw HLSLocalStreamAssemblyError.invalidInput
        }
        return resource
    }

    private func replacingEventResource(
        _ event: StagedHLSPlaylistEvent,
        resource: StagedHLSResource
    ) -> StagedHLSPlaylistEvent {
        switch event {
        case let .initialization(eventPosition, _):
            .initialization(
                eventPosition: eventPosition,
                resource: resource
            )
        case let .media(eventPosition, _, initialization):
            .media(
                eventPosition: eventPosition,
                resource: resource,
                initializationEventPosition: initialization
            )
        case .discontinuity:
            event
        }
    }
}

private enum HLSAssemblyProbeRole: Sendable {
    case video
    case audio
}

private actor HLSAssemblyProbeProcessor: MediaProcessor {
    let role: HLSAssemblyProbeRole

    init(role: HLSAssemblyProbeRole) {
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
        try makeHLSProbe(
            fileURL: fileURL,
            verificationClass: verificationClass,
            role: role
        )
    }

    func cancel(operationID: UUID) async {
        _ = operationID
    }
}

private actor HLSCancellingProbeProcessor: MediaProcessor {
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

private actor HLSMutatingProbeProcessor: MediaProcessor {
    let stagedURL: URL

    init(stagedURL: URL) {
        self.stagedURL = stagedURL
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
        try FileHandle(forWritingTo: stagedURL).closeAfterAppending(
            Data("!".utf8)
        )
        return try makeHLSProbe(
            fileURL: fileURL,
            verificationClass: verificationClass,
            role: .video
        )
    }

    func cancel(operationID: UUID) async {
        _ = operationID
    }
}

private actor HLSCancellingCopyCheckpoint {
    private(set) var copyStarted = false

    func wait(_ copiedBytes: Int64) async throws {
        _ = copiedBytes
        copyStarted = true
        try await Task.sleep(for: .seconds(30))
    }
}

private func makeHLSProbe(
    fileURL: URL,
    verificationClass: MediaVerificationClass,
    role: HLSAssemblyProbeRole
) throws -> MediaProbeResult {
    let size = try #require(
        try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    )
    let kind: MediaStreamKind = role == .video ? .video : .audio
    return MediaProbeResult(
        fileURL: fileURL,
        formatNames: ["mov", "mp4"],
        formatLongName: nil,
        durationSeconds: 1,
        startTimeSeconds: 0,
        bitRate: nil,
        fileSize: Int64(size),
        metadata: [:],
        streams: [hlsProbeStream(kind: kind)],
        chapters: [],
        verificationEvidence: MediaProbeEvidence(
            verificationClass: verificationClass,
            fullDecodePerformed: verificationClass == .strongFullDecode,
            packetsInspected: 1,
            inspectedPacketBytes: Int64(size),
            tailInspectionAttempted: verificationClass != .strongFullDecode,
            tailInspectionSucceeded: verificationClass != .strongFullDecode,
            tailInspectionReachedEOF: verificationClass != .strongFullDecode
        )
    )
}

private func hlsProbeStream(kind: MediaStreamKind) -> MediaStreamProbe {
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

private func fragmentedHLSParts(_ data: Data) throws -> [Data] {
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

private func generateHLSFragmentedFixture(at URL: URL) throws {
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

private func generateHLSStandardFixtures(
    in root: URL
) throws -> (video: URL, audio: URL) {
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
    return (video, audio)
}

private extension FileHandle {
    func closeAfterAppending(_ data: Data) throws {
        try seekToEnd()
        try write(contentsOf: data)
        try close()
    }
}
