import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Illucet

private struct C3BBurnInSubtitleDNSResolver: SubtitleDNSResolving {
    func addresses(for host: String) async throws -> Set<SubtitleIPAddress> {
        guard let address = SubtitleIPAddress("1.1.1.1") else {
            throw SubtitlePipelineError.DNSResolutionFailed
        }
        return [address]
    }
}

private actor C3BBurnInSubtitleHTTP: SubtitleHTTPNetworking {
    private var responses: [SubtitleHTTPResponse]
    private(set) var callCount = 0

    init(_ responses: [SubtitleHTTPResponse]) {
        self.responses = responses
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> SubtitleHTTPResponse {
        callCount += 1
        guard !responses.isEmpty else {
            throw SubtitlePipelineError.HTTPFailure
        }
        let response = responses.removeFirst()
        guard response.body.count <= maximumBytes else {
            throw SubtitlePipelineError.responseTooLarge
        }
        return response
    }
}

private actor C3BBurnInSubtitleExtractor: ExtractorEngine {
    private let metadata: MediaMetadata
    private(set) var callCount = 0

    init(metadata: MediaMetadata) {
        self.metadata = metadata
    }

    func versions() async throws -> ExtractorVersions {
        ExtractorVersions(python: "fixture", ytDLP: "fixture", ejs: "fixture")
    }

    func analyze(url: URL) async throws -> MediaMetadata {
        callCount += 1
        return metadata
    }

    nonisolated func cancel(requestID: UInt64) {}
}

@Suite("media features")
struct MediaFeatureTests {
    @Test
    func subtitleContainerCodecMatrixProducesVerifiedEmbeddedTracks() async throws {
        let root = try makeRoot("SubtitleEmbedMatrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let subtitleURL = root.appending(path: "fixture.vtt")
        try Data(
            ("WEBVTT\n\n"
                + "00:00.200 --> 00:00.800\nFirst embedded cue\n\n"
                + "00:01.000 --> 00:01.700\nSecond embedded cue\n").utf8
        ).write(to: subtitleURL, options: .withoutOverwriting)

        let cases: [(
            container: MediaContainer,
            nativeContainer: IllucetMediaContainer,
            subtitleCodec: MediaCodec,
            fileExtension: String,
            videoStreams: ClosedRange<Int>,
            audioStreams: ClosedRange<Int>,
            videoCodec: MediaCodec?,
            audioCodec: MediaCodec?
        )] = [
            (.mp4, ILLUCET_MEDIA_CONTAINER_MP4, .movText, "mp4", 1 ... 1, 1 ... 1, MediaCodec(rawValue: "mpeg4"), .aac),
            (.mov, ILLUCET_MEDIA_CONTAINER_MOV, .movText, "mov", 1 ... 1, 1 ... 1, MediaCodec(rawValue: "mpeg4"), .aac),
            (.matroska, ILLUCET_MEDIA_CONTAINER_MATROSKA, .subRip, "mkv", 1 ... 1, 1 ... 1, MediaCodec(rawValue: "mpeg4"), .aac),
            (.webM, ILLUCET_MEDIA_CONTAINER_WEBM, .webVTT, "webm", 0 ... 0, 1 ... 1, nil, .opus),
        ]

        for item in cases {
            let mediaURL = root.appending(
                path: "media-\(item.fileExtension).\(item.fileExtension)"
            )
            if item.container == .webM {
                try transcodeOpusWebM(
                    input: fixtures.audio,
                    output: mediaURL
                )
            } else {
                try merge(
                    video: fixtures.video,
                    audio: fixtures.audio,
                    output: mediaURL,
                    container: item.nativeContainer
                )
            }
            let output = root.appending(
                path: "embedded-\(item.fileExtension).\(item.fileExtension)"
            )
            let result = try await processor.process(
                MediaProcessingRequest(
                    operationID: UUID(),
                    operation: .embedSubtitles(
                        mediaURL: mediaURL,
                        subtitles: [
                            MediaSubtitleInput(
                                fileURL: subtitleURL,
                                languageCode: "eng",
                                title: "English • Manual • fixture",
                                isAutomatic: false,
                                isDefault: true,
                                isForced: false
                            ),
                        ]
                    ),
                    destinationURL: output,
                    output: MediaOutputSpecification(
                        container: item.container,
                        video: item.videoStreams.contains(1) ? .copy : .remove,
                        audio: .copy,
                        dynamicRange: .preserve,
                        subtitleCodec: item.subtitleCodec,
                        fastStart: true,
                        preserveMetadata: true,
                        preserveChapters: false
                    ),
                    metadata: .empty,
                    chapters: [],
                    trimming: nil,
                    overwriteExisting: false,
                    verification: MediaVerificationRequirements(
                        expectedContainer: item.container,
                        expectedFileExtension: item.fileExtension,
                        expectedVideoStreams: item.videoStreams,
                        expectedAudioStreams: item.audioStreams,
                        expectedSubtitleStreams: 1 ... 1,
                        expectedVideoCodec: item.videoCodec,
                        expectedAudioCodec: item.audioCodec,
                        expectedDimensions: item.videoStreams.contains(1)
                            ? MediaDimensions(width: 320, height: 180)
                            : nil,
                        expectedFrameRate: item.videoStreams.contains(1)
                            ? 30
                            : nil,
                        frameRateTolerance: 0.05,
                        expectedHDR: item.videoStreams.contains(1)
                            ? false
                            : nil,
                        expectedAudioSampleRate: 48_000,
                        expectedAudioChannelCount: 2,
                        expectedDurationSeconds: 2,
                        durationToleranceSeconds: 0.5,
                        expectedAudioBitRate: nil,
                        audioBitRateToleranceFraction: 0.20,
                        expectedChapterCount: 0 ... 0,
                        requireArtwork: false,
                        requireMetadataKeys: [],
                        expectedMetadataValues: [:],
                        forbiddenMetadataKeys: [],
                        requiredVerificationClass: .boundedStrong
                    )
                )
            ) { _ in }

            let probe = try #require(result.probes.first)
            let subtitle = try #require(
                probe.streams.first { $0.kind == .subtitle }
            )
            #expect(item.subtitleCodec.matches(probeCodec: subtitle.codecName))
            #expect(subtitle.subtitle?.languageCode == "eng")
            #expect(subtitle.subtitle?.title == "English • Manual • fixture")
            #expect(subtitle.disposition.isDefault)
            #expect(!subtitle.disposition.forced)
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func embeddingIdentityIsBoundedStableAndContainerCompatible() {
        let selection = SubtitleTrackSelection(
            trackID: "subtitle-111111111111111111111111",
            formatID: "subtitle-format-222222222222222222222222",
            language: "en-US",
            automatic: true
        )
        let identity = SubtitleEmbeddingWorkflow.identity(
            selection,
            codec: .movText,
            isDefault: true
        )

        #expect(identity.languageCode == "eng")
        #expect(identity.title == "en-US • Automatic • 11111111-22222222")
        #expect(identity.isDefault)
        #expect(SubtitleEmbeddingWorkflow.codec(for: .mp4) == .movText)
        #expect(SubtitleEmbeddingWorkflow.codec(for: .mov) == .movText)
        #expect(SubtitleEmbeddingWorkflow.codec(for: .matroska) == .subRip)
        #expect(SubtitleEmbeddingWorkflow.codec(for: .webM) == .webVTT)
        #expect(SubtitleEmbeddingWorkflow.codec(for: .m4a) == nil)
    }

    @Test
    func embeddingWorkflowKeepsTwoExactTrackIdentities() async throws {
        let root = try makeRoot("SubtitleEmbedWorkflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let media = root.appending(path: "media.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: media,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let firstURL = root.appending(path: "first.vtt")
        let secondURL = root.appending(path: "second.vtt")
        try Data(
            "WEBVTT\n\n00:00.100 --> 00:00.700\nFirst\n".utf8
        ).write(to: firstURL, options: .withoutOverwriting)
        try Data(
            "WEBVTT\n\n00:00.900 --> 00:01.500\nSecond\n".utf8
        ).write(to: secondURL, options: .withoutOverwriting)
        let manual = SubtitleTrackSelection(
            trackID: "subtitle-111111111111111111111111",
            formatID: "subtitle-format-111111111111111111111111",
            language: "en",
            automatic: false
        )
        let automatic = SubtitleTrackSelection(
            trackID: "subtitle-222222222222222222222222",
            formatID: "subtitle-format-222222222222222222222222",
            language: "es",
            automatic: true
        )
        var configuration = DownloadConfiguration.standard
        configuration.subtitleDelivery = .embed
        configuration.subtitleSelections = [manual, automatic]
        configuration.thumbnailBehavior = .none
        let metadata = nativeMetadata()
        var settings = AppSettings.defaults
        settings.preserveMetadata = true
        let plan = OutputPlan(
            mode: .videoAndAudio,
            containerChoice: .mp4,
            container: .mp4,
            fileExtension: "mp4",
            strategy: .mergeStreamCopy,
            sourceVideoCodec: MediaCodec(rawValue: "mpeg4"),
            sourceAudioCodec: .aac,
            videoEncodingCodec: nil,
            videoEncodingFrameRate: nil,
            audioEncodingSettings: nil,
            expectedVideoCodec: MediaCodec(rawValue: "mpeg4"),
            expectedAudioCodec: .aac,
            expectedDimensions: MediaDimensions(width: 320, height: 180),
            expectedFrameRate: 30,
            expectedHDR: false,
            expectedSampleRate: 48_000,
            expectedChannelCount: 2,
            expectedAudioBitRate: nil,
            expectedVideoStreams: 1 ... 1,
            expectedAudioStreams: 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: true
        )

        let result = try await SubtitleEmbeddingWorkflow(
            mediaProcessor: NativeFFmpegMediaProcessor()
        ).embed(
            [
                PreparedSubtitleSidecar(
                    selection: manual,
                    kind: .webVTT,
                    temporaryURL: firstURL
                ),
                PreparedSubtitleSidecar(
                    selection: automatic,
                    kind: .webVTT,
                    temporaryURL: secondURL
                ),
            ],
            into: media,
            plan: plan,
            configuration: configuration,
            metadata: metadata,
            settings: settings,
            temporaryRoot: root,
            operationID: UUID(),
            progress: { _ in }
        )

        #expect(result.probe.subtitleStreamCount == 2)
        #expect(result.identities.map(\.selection) == [manual, automatic])
        #expect(result.probe.streams.filter { $0.kind == .subtitle }.map {
            $0.subtitle?.title
        } == result.identities.map { Optional($0.title) })
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func renderingCuesRemoveMarkupAndDecodeEntities() throws {
        let cues = try WebVTTProcessor.renderingCues(
            Data(
                ("WEBVTT\n\n"
                    + "00:00.100 --> 00:01.000\n"
                    + "<v Speaker><b>Hello</b><br>&amp; goodbye</v>\n").utf8
            )
        )
        #expect(cues == [
            SubtitleRenderCue(
                startSeconds: 0.1,
                endSeconds: 1,
                text: "Hello\n& goodbye"
            ),
        ])
    }

    @Test
    func burnInBoundsOneOverlappingTerminalCueToVerifiedMediaDuration()
        throws
    {
        let verifiedDuration = 563.362540
        let exactLiveBoundary = SubtitleRenderCue(
            startSeconds: 561.040,
            endSeconds: 564.720,
            text: "Synthetic terminal cue"
        )
        #expect(
            try SubtitleBurnInWorkflow.boundedEndSeconds(
                for: exactLiveBoundary,
                verifiedMediaDurationSeconds: verifiedDuration,
                extractedDurationSeconds: 563
            ) == verifiedDuration
        )

        let materiallyOutOfRange = SubtitleRenderCue(
            startSeconds: 561.040,
            endSeconds: verifiedDuration
                + SubtitleBurnInWorkflow
                    .maximumVerifiedMediaCueOverrunSeconds
                + 0.001,
            text: "Synthetic rejected cue"
        )
        #expect(throws: SubtitlePipelineError.invalidWebVTT) {
            try SubtitleBurnInWorkflow.boundedEndSeconds(
                for: materiallyOutOfRange,
                verifiedMediaDurationSeconds: verifiedDuration,
                extractedDurationSeconds: 563
            )
        }

        let whollyOutOfRange = SubtitleRenderCue(
            startSeconds: verifiedDuration,
            endSeconds: verifiedDuration + 0.1,
            text: "Synthetic rejected cue"
        )
        #expect(throws: SubtitlePipelineError.invalidWebVTT) {
            try SubtitleBurnInWorkflow.boundedEndSeconds(
                for: whollyOutOfRange,
                verifiedMediaDurationSeconds: verifiedDuration,
                extractedDurationSeconds: 563
            )
        }

        #expect(throws: SubtitlePipelineError.invalidWebVTT) {
            try SubtitleBurnInWorkflow.boundedEndSeconds(
                for: exactLiveBoundary,
                verifiedMediaDurationSeconds: nil,
                extractedDurationSeconds: 563
            )
        }

        let sourceTimelineCue = SubtitleRenderCue(
            startSeconds: 562,
            endSeconds: 563.4,
            text: "Synthetic source timeline cue"
        )
        #expect(
            try SubtitleBurnInWorkflow.boundedEndSeconds(
                for: sourceTimelineCue,
                verifiedMediaDurationSeconds: 513.8,
                extractedDurationSeconds: 563
            ) == sourceTimelineCue.endSeconds
        )
    }

    @Test
    func burnInDurationDecisionDistinguishesEveryBoundedRoute() {
        let accepted = SubtitleRenderCue(
            startSeconds: 1,
            endSeconds: 2,
            text: "Synthetic accepted cue"
        )
        let clipped = SubtitleRenderCue(
            startSeconds: 9,
            endSeconds: 10.4,
            text: "Synthetic clipped cue"
        )

        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: accepted,
                verifiedMediaDurationSeconds: 10,
                extractedDurationSeconds: 10
            ) == SubtitleBurnDurationDecision(
                route: .verifiedDuration,
                outcome: .acceptedVerifiedEnd,
                acceptedEndSeconds: 2
            )
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: clipped,
                verifiedMediaDurationSeconds: 10,
                extractedDurationSeconds: 10
            ) == SubtitleBurnDurationDecision(
                route: .verifiedDuration,
                outcome: .clippedToVerifiedEnd,
                acceptedEndSeconds: 10
            )
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: accepted,
                verifiedMediaDurationSeconds: nil,
                extractedDurationSeconds: 10
            ).route == .verifiedDurationMissing
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: accepted,
                verifiedMediaDurationSeconds: .nan,
                extractedDurationSeconds: nil
            ) == SubtitleBurnDurationDecision(
                route: .verifiedDurationNonFinite,
                outcome: .verifiedDurationNonFinite,
                acceptedEndSeconds: nil
            )
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: accepted,
                verifiedMediaDurationSeconds: 0,
                extractedDurationSeconds: nil
            ) == SubtitleBurnDurationDecision(
                route: .verifiedDurationNonPositive,
                outcome: .verifiedDurationNonPositive,
                acceptedEndSeconds: nil
            )
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: accepted,
                verifiedMediaDurationSeconds: 8,
                extractedDurationSeconds: 10
            ) == SubtitleBurnDurationDecision(
                route: .verifiedExtractedTimelineMismatch,
                outcome: .acceptedExtractedFallback,
                acceptedEndSeconds: 2
            )
        )

        let startsAtEnd = SubtitleRenderCue(
            startSeconds: 10,
            endSeconds: 10.1,
            text: "Synthetic post-media cue"
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: startsAtEnd,
                verifiedMediaDurationSeconds: 10,
                extractedDurationSeconds: 10
            ).outcome == .cueStartsAtOrAfterVerifiedEnd
        )
        let excessive = SubtitleRenderCue(
            startSeconds: 9,
            endSeconds: 11.501,
            text: "Synthetic excessive cue"
        )
        #expect(
            SubtitleBurnInWorkflow.durationDecision(
                for: excessive,
                verifiedMediaDurationSeconds: 10,
                extractedDurationSeconds: 10
            ).outcome == .terminalOverrunBeyondBound
        )
        let fallbackRejected = SubtitleBurnInWorkflow.durationDecision(
            for: SubtitleRenderCue(
                startSeconds: 1,
                endSeconds: 10.501,
                text: "Synthetic fallback rejection"
            ),
            verifiedMediaDurationSeconds: nil,
            extractedDurationSeconds: 10
        )
        #expect(fallbackRejected.route == .verifiedDurationMissing)
        #expect(
            fallbackRejected.outcome == .extractedDurationFallbackRejection
        )
    }

    @Test
    func burnInDiagnosticsAssignIdentityAndRenderingBeforeDuration()
        async throws
    {
        let root = try makeRoot("SubtitleBurnDiagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "media.mp4")
        let otherMedia = root.appending(path: "other.mp4")
        let subtitle = root.appending(path: "subtitle.vtt")
        try Data("media".utf8).write(to: media)
        try Data("media".utf8).write(to: otherMedia)
        try Data("WEBVTT\n\ninvalid cue\n".utf8).write(to: subtitle)
        let selection = SubtitleTrackSelection(
            trackID: "subtitle-aaaaaaaaaaaaaaaaaaaaaaaa",
            formatID: "subtitle-format-bbbbbbbbbbbbbbbbbbbbbbbb",
            language: "en",
            automatic: false
        )
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .none
        configuration.subtitleDelivery = .burnIn
        configuration.subtitleSelections = [selection]
        let prepared = [
            PreparedSubtitleSidecar(
                selection: selection,
                kind: .webVTT,
                temporaryURL: subtitle
            ),
        ]
        let diagnostics = DiagnosticStore(
            rootURL: root.appending(path: "Diagnostics")
        )
        let workflow = SubtitleBurnInWorkflow(
            mediaProcessor: NativeFFmpegMediaProcessor(),
            diagnostics: diagnostics
        )

        await #expect(throws: SubtitlePipelineError.embeddingFailed) {
            try await workflow.burn(
                prepared,
                into: media,
                inputProbe: emptyMediaProbe(fileURL: otherMedia),
                plan: burnInH264Plan(),
                configuration: configuration,
                metadata: nativeMetadata(),
                settings: .defaults,
                temporaryRoot: root,
                operationID: UUID(),
                progress: { _ in }
            )
        }
        var entry = try #require(
            await diagnostics.allEntries().first {
                $0.event == "subtitle_burn_duration_decision"
            }
        )
        #expect(entry.detail?.contains(
            "route=probe_media_file_mismatch"
        ) == true)
        #expect(entry.detail?.contains(
            "outcome=probe_media_file_mismatch"
        ) == true)
        #expect(entry.detail?.contains("probe_media_identity_equal=false") == true)

        await diagnostics.clear()
        await #expect(throws: SubtitlePipelineError.invalidWebVTT) {
            try await workflow.burn(
                prepared,
                into: media,
                inputProbe: emptyMediaProbe(fileURL: media),
                plan: burnInH264Plan(),
                configuration: configuration,
                metadata: nativeMetadata(),
                settings: .defaults,
                temporaryRoot: root,
                operationID: UUID(),
                progress: { _ in }
            )
        }
        entry = try #require(
            await diagnostics.allEntries().first {
                $0.event == "subtitle_burn_duration_decision"
            }
        )
        #expect(entry.detail?.contains("route=rendering_cues_rejected") == true)
        #expect(entry.detail?.contains("outcome=rendering_cues_rejected") == true)
        #expect(entry.detail?.contains("WEBVTT") == false)
    }

    @Test
    func burnInWorkflowProducesVerifiedFullConversion() async throws {
        let root = try makeRoot("SubtitleBurnIn")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let staticVideo = root.appending(path: "static-video.mp4")
        try await writeStaticVideo(to: staticVideo)
        let source = root.appending(path: "source-h264.mp4")
        try merge(
            video: staticVideo,
            audio: fixtures.audio,
            output: source,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let selection = SubtitleTrackSelection(
            trackID: "subtitle-aaaaaaaaaaaaaaaaaaaaaaaa",
            formatID: "subtitle-format-bbbbbbbbbbbbbbbbbbbbbbbb",
            language: "en",
            automatic: false
        )
        let originalURL = URL(
            string: "https://captions.example/original.vtt"
        )!
        let refreshedURL = URL(
            string: "https://captions.example/refreshed.vtt"
        )!
        func subtitleTrack(transportURL: URL) -> MediaSubtitleTrack {
            MediaSubtitleTrack(
                trackID: selection.trackID,
                language: selection.language,
                name: "English",
                automatic: selection.automatic,
                formats: [
                    MediaSubtitleFormat(
                        formatID: selection.formatID,
                        url: transportURL,
                        extension: "vtt",
                        name: "WebVTT"
                    ),
                ]
            )
        }
        let metadata = nativeMetadata(
            subtitles: [subtitleTrack(transportURL: originalURL)]
        )
        let refreshedMetadata = nativeMetadata(
            subtitles: [subtitleTrack(transportURL: refreshedURL)]
        )
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .none
        configuration.subtitleDelivery = .burnIn
        configuration.subtitleSelections = [selection]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        var settings = AppSettings.defaults
        settings.preserveMetadata = true
        let unusableResponse = SubtitleHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"error\":true}".utf8)
        )
        let refreshedBody = """
        WEBVTT
        Kind: captions
        Language: en

        00:00.600 --> 00:01.400 align:start position:0%
        <b>Rendered pixels</b> &amp; background

        """
        let refreshedResponse = SubtitleHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/vtt"],
            body: Data(refreshedBody.utf8)
        )
        let HTTP = C3BBurnInSubtitleHTTP([
            unusableResponse,
            refreshedResponse,
        ])
        let extractor = C3BBurnInSubtitleExtractor(
            metadata: refreshedMetadata
        )
        let sidecarWorkflow = SubtitleSidecarWorkflow(
            transport: SecureSubtitleTransport(
                resolver: C3BBurnInSubtitleDNSResolver(),
                networking: HTTP
            ),
            exporter: ExportManager(documentsRootURL: root)
        )
        let plans = try SubtitleSelectionPlanner.plans(
            configuration: configuration,
            metadata: metadata
        )
        let prepared = try await sidecarWorkflow.prepare(
            plans: plans,
            sourceURL: metadata.canonicalURL,
            expectedVideoID: metadata.videoID,
            extractor: extractor,
            temporaryRoot: root
        )
        defer { sidecarWorkflow.cleanup(prepared) }

        #expect(prepared.count == 1)
        #expect(plans[0].selection == selection)
        #expect(await HTTP.callCount == 2)
        #expect(await extractor.callCount == 1)

        let result = try await SubtitleBurnInWorkflow(
            mediaProcessor: processor
        ).burn(
            prepared,
            into: source,
            inputProbe: try await processor.probe(
                source,
                verificationClass: .fastStructural
            ),
            plan: burnInH264Plan(),
            configuration: configuration,
            metadata: metadata,
            settings: settings,
            temporaryRoot: root,
            operationID: UUID(),
            progress: { _ in }
        )

        #expect(result.renderedCueCount == 1)
        let evidence = try #require(result.probe.verificationEvidence)
        #expect(evidence.verificationClass == MediaVerificationClass.boundedStrong)
        #expect(evidence.fullDecodePerformed == false)
        let primaryStreams = result.probe.streams.filter {
            ($0.kind == .video && !$0.disposition.attachedPicture)
                || $0.kind == .audio
        }
        let primaryStreamsWereDecoded = primaryStreams.allSatisfy {
            ($0.decodedFrames ?? 0) > 0
                && ($0.decodedSampleWindows ?? 0) == 3
        }
        #expect(primaryStreamsWereDecoded)
        #expect(result.probe.videoStreamCount == 1)
        #expect(result.probe.audioStreamCount == 1)
        #expect(result.probe.subtitleStreamCount == 0)
        #expect(abs((result.probe.durationSeconds ?? 0) - 2) <= 0.12)
        let videoCodec = result.probe.streams.first {
            $0.kind == .video
        }?.codecName
        #expect(MediaCodec.h264.matches(probeCodec: videoCodec))
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: true,
            container: .mp4
        )
        let requiredMetadataKeys: Set<String> = [
            "title",
            "artist",
            "comment",
            "date",
            "description",
        ]
        #expect(metadataPolicy.requiredKeys == requiredMetadataKeys)
        #expect(
            Set(metadataPolicy.expectedValues.keys) == requiredMetadataKeys
        )
        for (key, expected) in metadataPolicy.expectedValues {
            #expect(result.probe.metadata[key] == expected)
        }
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        let before = try await decodedFrame(
            from: result.fileURL,
            seconds: 0.2
        )
        let active = try await decodedFrame(
            from: result.fileURL,
            seconds: 1
        )
        let after = try await decodedFrame(
            from: result.fileURL,
            seconds: 1.75
        )
        #expect(before.width == active.width)
        #expect(before.height == active.height)
        #expect(after.width == active.width)
        #expect(after.height == active.height)
        let subtitleRegion = 0.55 ... 0.98
        let controlRegion = 0.05 ... 0.45
        let activeSubtitleChange = pixelChangeRatio(
            before,
            active,
            verticalFraction: subtitleRegion,
            threshold: 24
        )
        let activeControlChange = pixelChangeRatio(
            before,
            active,
            verticalFraction: controlRegion,
            threshold: 24
        )
        let inactiveSubtitleChange = pixelChangeRatio(
            before,
            after,
            verticalFraction: subtitleRegion,
            threshold: 24
        )
        #expect(activeSubtitleChange >= 0.035)
        #expect(activeSubtitleChange >= activeControlChange * 3)
        #expect(inactiveSubtitleChange <= 0.012)
        #expect(activeSubtitleChange >= inactiveSubtitleChange * 4)
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func preCancelledBurnInPublishesNoOutput() async throws {
        let root = try makeRoot("SubtitleBurnCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let subtitle = root.appending(path: "cancel.vtt")
        let media = root.appending(path: "media.mp4")
        try Data("media".utf8).write(to: media)
        try Data(
            "WEBVTT\n\n00:00.100 --> 00:01.000\nCancel\n".utf8
        ).write(to: subtitle)
        let selection = SubtitleTrackSelection(
            trackID: "cancel",
            formatID: "cancel",
            language: "en",
            automatic: false
        )
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .none
        configuration.subtitleDelivery = .burnIn
        configuration.subtitleSelections = [selection]

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubtitleBurnInWorkflow(
                mediaProcessor: NativeFFmpegMediaProcessor()
            ).burn(
                [
                    PreparedSubtitleSidecar(
                        selection: selection,
                        kind: .webVTT,
                        temporaryURL: subtitle
                    ),
                ],
                into: media,
                inputProbe: emptyMediaProbe(fileURL: media),
                plan: burnInH264Plan(),
                configuration: configuration,
                metadata: nativeMetadata(),
                settings: .defaults,
                temporaryRoot: root,
                operationID: UUID(),
                progress: { _ in }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "output-subtitle-burn.mp4").path
        ))
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func chapterWorkflowWritesPreservesAndProbesExactChapters() async throws {
        let root = try makeRoot("Chapters")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let media = root.appending(path: "media.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: media,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let processor = NativeFFmpegMediaProcessor()
        let sourceProbe = try await processor.probeFullyDecoding(media)
        let extracted = [
            ExtractedChapter(
                title: "Opening",
                startTimeSeconds: 0,
                endTimeSeconds: 0.8
            ),
            ExtractedChapter(
                title: "Finish",
                startTimeSeconds: 0.8,
                endTimeSeconds: nil
            ),
        ]
        var configuration = DownloadConfiguration.standard
        configuration.preserveChapters = true
        configuration.writeChapters = true
        configuration.thumbnailBehavior = .none
        var settings = AppSettings.defaults
        settings.preserveMetadata = false
        let metadata = mediaMetadata(chapters: extracted)
        let result = try await ChapterWorkflow(
            mediaProcessor: processor
        ).write(
            metadataChapters: extracted,
            into: media,
            inputProbe: sourceProbe,
            plan: chapterPlan(),
            configuration: configuration,
            metadata: metadata,
            settings: settings,
            temporaryRoot: root,
            operationID: UUID(),
            progress: { _ in }
        )

        #expect(result.chapters == [
            MediaChapter(title: "Opening", startSeconds: 0, endSeconds: 0.8),
            MediaChapter(title: "Finish", startSeconds: 0.8, endSeconds: 2),
        ])
        #expect(result.probe.chapters == result.chapters)
        #expect(result.probe.videoStreamCount == 1)
        #expect(result.probe.audioStreamCount == 1)

        let preservedRoot = root.appending(
            path: "preserved",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: preservedRoot,
            withIntermediateDirectories: true
        )
        configuration.writeChapters = false
        let preserved = try await ChapterWorkflow(
            mediaProcessor: processor
        ).write(
            metadataChapters: [],
            into: result.fileURL,
            inputProbe: result.probe,
            plan: chapterPlan(),
            configuration: configuration,
            metadata: metadata,
            settings: settings,
            temporaryRoot: preservedRoot,
            operationID: UUID(),
            progress: { _ in }
        )
        #expect(preserved.probe.chapters == result.chapters)
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func chapterParserFailsClosedOnOverlapAndMissingFinalBound() {
        #expect(throws: ChapterWorkflowError.invalidChapterData) {
            try ChapterWorkflow.normalized(
                [
                    ExtractedChapter(
                        title: "One",
                        startTimeSeconds: 0,
                        endTimeSeconds: 1.2
                    ),
                    ExtractedChapter(
                        title: "Two",
                        startTimeSeconds: 1,
                        endTimeSeconds: 2
                    ),
                ],
                durationSeconds: 2
            )
        }
        #expect(throws: ChapterWorkflowError.invalidChapterData) {
            try ChapterWorkflow.normalized(
                [
                    ExtractedChapter(
                        title: "Unbounded",
                        startTimeSeconds: 0,
                        endTimeSeconds: nil
                    ),
                ],
                durationSeconds: nil
            )
        }
    }

    @Test
    func manualTrimSupportsAccurateAndFastKeyframeModes() async throws {
        let root = try makeRoot("ManualTrim")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: source,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let processor = NativeFFmpegMediaProcessor()
        let workflow = ManualTrimWorkflow(mediaProcessor: processor)
        let sourceProbe = try await processor.probeFullyDecoding(source)
        var settings = AppSettings.defaults
        settings.preserveMetadata = true
        let metadata = nativeMetadata()
        let accurate = try await workflow.trim(
            mediaURL: source,
            inputProbe: sourceProbe,
            plan: burnInH264Plan(),
            range: MediaTrimRange(startSeconds: 0.25, endSeconds: 1.6),
            mode: .accurate,
            metadata: metadata,
            settings: settings,
            destinationURL: root.appending(path: "accurate.mp4"),
            operationID: UUID(),
            progress: { _ in }
        )
        #expect(abs((accurate.probe.durationSeconds ?? 0) - 1.35) <= 0.08)
        #expect(
            accurate.probe.verificationEvidence?.verificationClass
                == .boundedStrong
        )
        #expect(
            accurate.probe.verificationEvidence?.fullDecodePerformed == false
        )
        #expect(MediaCodec.h264.matches(probeCodec: accurate.probe.streams.first {
            $0.kind == .video
        }?.codecName))
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: true,
            container: .mp4
        )
        let requiredMetadataKeys: Set<String> = [
            "title",
            "artist",
            "comment",
            "date",
            "description",
        ]
        #expect(metadataPolicy.requiredKeys == requiredMetadataKeys)
        #expect(
            Set(metadataPolicy.expectedValues.keys) == requiredMetadataKeys
        )
        for (key, expected) in metadataPolicy.expectedValues {
            #expect(accurate.probe.metadata[key] == expected)
        }

        let fast = try await workflow.trim(
            mediaURL: accurate.fileURL,
            inputProbe: accurate.probe,
            plan: burnInH264Plan(),
            range: MediaTrimRange(startSeconds: 0, endSeconds: 0.8),
            mode: .fastKeyframe,
            metadata: metadata,
            settings: settings,
            destinationURL: root.appending(path: "fast.mp4"),
            operationID: UUID(),
            progress: { _ in }
        )
        #expect((fast.probe.durationSeconds ?? 0) > 0)
        #expect((fast.probe.durationSeconds ?? 0) <= 1.8)
        #expect(MediaCodec.h264.matches(probeCodec: fast.probe.streams.first {
            $0.kind == .video
        }?.codecName))
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func chapterSplitsAreContiguousVerifiedAndComplete() async throws {
        let root = try makeRoot("ChapterSplit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: source,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let processor = NativeFFmpegMediaProcessor()
        let probe = try await processor.probeFullyDecoding(source)
        var settings = AppSettings.defaults
        settings.preserveMetadata = false
        let outputs = try await ChapterSplitWorkflow(
            mediaProcessor: processor
        ).split(
            mediaURL: source,
            inputProbe: probe,
            plan: burnInH264Plan(),
            chapters: [
                MediaChapter(
                    title: "Opening",
                    startSeconds: 0,
                    endSeconds: 0.7
                ),
                MediaChapter(
                    title: "Finish",
                    startSeconds: 0.7,
                    endSeconds: 2
                ),
            ],
            metadata: nativeMetadata(),
            settings: settings,
            temporaryRoot: root,
            progress: { _ in }
        )

        #expect(outputs.count == 2)
        #expect(outputs[0].chapter.startSeconds == 0)
        #expect(outputs[0].chapter.endSeconds == outputs[1].chapter.startSeconds)
        #expect(outputs[1].chapter.endSeconds == 2)
        #expect(outputs.map(\.filename) == [
            "001 - Opening",
            "002 - Finish",
        ])
        #expect(outputs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
                && $0.probe.videoStreamCount == 1
                && $0.probe.audioStreamCount == 1
        })
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func preCancelledChapterSplitRemovesAllPartialOutputs() async throws {
        let root = try makeRoot("ChapterSplitCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "media.mp4")
        try Data("media".utf8).write(to: media)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChapterSplitWorkflow(
                mediaProcessor: NativeFFmpegMediaProcessor()
            ).split(
                mediaURL: media,
                inputProbe: emptyMediaProbe(fileURL: media),
                plan: burnInH264Plan(),
                chapters: [
                    MediaChapter(
                        title: "Only",
                        startSeconds: 0,
                        endSeconds: 2
                    ),
                ],
                metadata: nativeMetadata(),
                settings: .defaults,
                temporaryRoot: root,
                progress: { _ in }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "chapter-splits").path
        ))
    }

    @Test
    func chapterExportTransactionCommitsCompleteVerifiedSet() async throws {
        let root = try makeRoot("ChapterExportCommit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        let exporter = ExportManager(documentsRootURL: fixture.destination)

        let outcome = try await exporter.exportFileTransaction(
            items: fixture.items,
            destination: .appDocuments,
            folderBookmark: nil,
            duplicateHandling: Array(repeating: .addNumber, count: 3),
            videoID: "video-id"
        )

        guard case let .committed(URLs) = outcome else {
            Issue.record("Complete chapter transaction was skipped.")
            return
        }
        #expect(URLs.map(\.lastPathComponent) == [
            "Video.mp4",
            "Video - 001.mp4",
            "Video - 002.mp4",
        ])
        for (source, output) in zip(fixture.items, URLs) {
            #expect(FileManager.default.contentsEqual(
                atPath: source.sourceURL.path,
                andPath: output.path
            ))
        }
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func chapterExportTransactionSkipAtAnyMemberPublishesNothing(
        collisionIndex: Int
    ) async throws {
        let root = try makeRoot("ChapterExportSkip-\(collisionIndex)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        let names = ["Video.mp4", "Video - 001.mp4", "Video - 002.mp4"]
        let collision = fixture.destination.appending(path: names[collisionIndex])
        let original = Data("existing-\(collisionIndex)".utf8)
        try original.write(to: collision)
        let exporter = ExportManager(documentsRootURL: fixture.destination)

        let outcome = try await exporter.exportFileTransaction(
            items: fixture.items,
            destination: .appDocuments,
            folderBookmark: nil,
            duplicateHandling: Array(repeating: .skip, count: 3),
            videoID: "video-id"
        )

        #expect(outcome == .duplicateSkipped)
        #expect(try Data(contentsOf: collision) == original)
        for (index, name) in names.enumerated() where index != collisionIndex {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.destination.appending(path: name).path
            ))
        }
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test
    func chapterExportAskCollisionFailsBeforeStaging() async throws {
        let root = try makeRoot("ChapterExportAsk")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        let collision = fixture.destination.appending(path: "Video - 001.mp4")
        try Data("existing".utf8).write(to: collision)
        let exporter = ExportManager(documentsRootURL: fixture.destination)

        await #expect(throws: ExportError.self) {
            try await exporter.exportFileTransaction(
                items: fixture.items,
                destination: .appDocuments,
                folderBookmark: nil,
                duplicateHandling: Array(repeating: .ask, count: 3),
                videoID: "video-id"
            )
        }
        #expect(try Data(contentsOf: collision) == Data("existing".utf8))
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test
    func chapterExportAskCancelPublishesNoTransactionMember() async throws {
        let root = try makeRoot("ChapterExportAskCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        let collision = fixture.destination.appending(path: "Video - 001.mp4")
        try Data("existing".utf8).write(to: collision)
        let events = ChapterDuplicateEventRecorder()
        let flow = DownloadExportFlow(
            exporter: ExportManager(documentsRootURL: fixture.destination),
            diagnostics: DiagnosticStore(
                rootURL: root.appending(path: "Diagnostics")
            ),
            notifications: UserNotificationService(),
            eventSink: events.record
        )
        var configuration = DownloadConfiguration.standard
        configuration.destination = .appDocuments
        let job = DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.RickURL,
            videoID: "fixture-id",
            title: "Video",
            channel: "Illucet",
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .running,
            stage: .savingFiles,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 3,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
        let task = Task {
            try await flow.exportMediaFileTransaction(
                primarySourceURL: fixture.items[0].sourceURL,
                primaryFilename: fixture.items[0].filename,
                additionalItems: Array(fixture.items.dropFirst()),
                duplicateHandling: .ask,
                job: job,
                folderBookmark: nil
            )
        }
        let request = try await events.waitForRequest()
        await flow.resolveDuplicate(
            requestID: request.id,
            handling: nil
        )

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try visibleFiles(in: fixture.destination) == [collision])
        #expect(try Data(contentsOf: collision) == Data("existing".utf8))
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test(arguments: [1, 2])
    func chapterExportStagingFailurePublishesNothing(
        failureIndex: Int
    ) async throws {
        let root = try makeRoot("ChapterExportStage-\(failureIndex)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        let exporter = ExportManager(
            documentsRootURL: fixture.destination,
            transactionObserver: { event in
                if event == .willStage(failureIndex) {
                    throw ChapterTransactionTestError.injected
                }
            }
        )

        await #expect(throws: ChapterTransactionTestError.self) {
            try await exporter.exportFileTransaction(
                items: fixture.items,
                destination: .appDocuments,
                folderBookmark: nil,
                duplicateHandling: Array(repeating: .addNumber, count: 3),
                videoID: "video-id"
            )
        }
        #expect(try visibleFiles(in: fixture.destination).isEmpty)
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test(arguments: [
        ExportFileTransactionEvent.stagingComplete,
        ExportFileTransactionEvent.didCommit(0),
        ExportFileTransactionEvent.didCommit(1),
    ])
    func chapterExportCancellationRollsBackCompleteSet(
        cancellationPoint: ExportFileTransactionEvent
    ) async throws {
        let root = try makeRoot("ChapterExportCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        let unrelated = fixture.destination.appending(path: "unrelated.txt")
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: unrelated)
        let exporter = ExportManager(
            documentsRootURL: fixture.destination,
            transactionObserver: { event in
                if event == cancellationPoint {
                    throw CancellationError()
                }
            }
        )

        await #expect(throws: CancellationError.self) {
            try await exporter.exportFileTransaction(
                items: fixture.items,
                destination: .appDocuments,
                folderBookmark: nil,
                duplicateHandling: Array(repeating: .addNumber, count: 3),
                videoID: "video-id"
            )
        }
        #expect(try visibleFiles(in: fixture.destination) == [unrelated])
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)
    }

    @Test
    func chapterExportOverwriteFailureRestoresExactOriginals() async throws {
        let root = try makeRoot("ChapterExportOverwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        let names = ["Video.mp4", "Video - 001.mp4", "Video - 002.mp4"]
        let originals = names.enumerated().map {
            Data("original-\($0.offset)".utf8)
        }
        for (name, data) in zip(names, originals) {
            try data.write(to: fixture.destination.appending(path: name))
        }
        let unrelated = fixture.destination.appending(path: "unrelated.bin")
        try Data([9, 8, 7]).write(to: unrelated)
        let exporter = ExportManager(
            documentsRootURL: fixture.destination,
            transactionObserver: { event in
                if event == .didCommit(1) {
                    throw ChapterTransactionTestError.injected
                }
            }
        )

        await #expect(throws: ChapterTransactionTestError.self) {
            try await exporter.exportFileTransaction(
                items: fixture.items,
                destination: .appDocuments,
                folderBookmark: nil,
                duplicateHandling: Array(repeating: .overwrite, count: 3),
                videoID: "video-id"
            )
        }
        for (name, original) in zip(names, originals) {
            #expect(try Data(
                contentsOf: fixture.destination.appending(path: name)
            ) == original)
        }
        #expect(try Data(contentsOf: unrelated) == Data([9, 8, 7]))
        #expect(try hiddenTransactionFiles(in: fixture.destination).isEmpty)

        let retry = try await ExportManager(
            documentsRootURL: fixture.destination
        ).exportFileTransaction(
            items: fixture.items,
            destination: .appDocuments,
            folderBookmark: nil,
            duplicateHandling: Array(repeating: .overwrite, count: 3),
            videoID: "video-id"
        )
        guard case let .committed(retryURLs) = retry else {
            Issue.record("Retry after rollback was skipped.")
            return
        }
        for (source, output) in zip(fixture.items, retryURLs) {
            #expect(FileManager.default.contentsEqual(
                atPath: source.sourceURL.path,
                andPath: output.path
            ))
        }
    }

    @Test(arguments: [
        DuplicateHandling.addNumber,
        DuplicateHandling.addVideoID,
    ])
    func chapterExportCollisionNamingIsSetWideAndDeterministic(
        handling: DuplicateHandling
    ) async throws {
        let root = try makeRoot("ChapterExportNaming")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        for name in ["Video.mp4", "Video - 001.mp4", "Video - 002.mp4"] {
            try Data("existing".utf8).write(
                to: fixture.destination.appending(path: name)
            )
        }
        let exporter = ExportManager(documentsRootURL: fixture.destination)

        let outcome = try await exporter.exportFileTransaction(
            items: fixture.items,
            destination: .appDocuments,
            folderBookmark: nil,
            duplicateHandling: Array(repeating: handling, count: 3),
            videoID: "fixture-id"
        )
        guard case let .committed(URLs) = outcome else {
            Issue.record("Collision naming transaction was skipped.")
            return
        }
        let suffix = handling == .addNumber ? " 2" : "-fixture-id"
        #expect(URLs.map {
            $0.deletingPathExtension().lastPathComponent
        } == [
            "Video\(suffix)",
            "Video - 001\(suffix)",
            "Video - 002\(suffix)",
        ])
    }

    @Test
    func chapterExportSupportsFilesBookmarkAndPlaylistDirectory()
        async throws {
        let root = try makeRoot("ChapterExportFiles")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try chapterTransactionFixture(root)
        let files = root.appending(path: "Files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: files,
            withIntermediateDirectories: true
        )
        let exporter = ExportManager()
        let bookmark = try await exporter.bookmark(for: files)

        let outcome = try await exporter.exportFileTransaction(
            items: fixture.items,
            destination: .filesFolder,
            folderBookmark: bookmark,
            duplicateHandling: Array(repeating: .addNumber, count: 3),
            videoID: "video-id",
            relativeDirectory: "Fixture Playlist"
        )
        guard case let .committed(URLs) = outcome else {
            Issue.record("Files transaction was skipped.")
            return
        }
        #expect(URLs.allSatisfy {
            $0.deletingLastPathComponent().lastPathComponent
                == "Fixture Playlist"
        })
    }

    @Test
    func finalizedPackageFolderAndZIPContainExactArtifacts() async throws {
        let root = try makeRoot("Package")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "video.mp4")
        let thumbnail = root.appending(path: "cover.jpg")
        let subtitle = root.appending(path: "subtitle.vtt")
        let split = root.appending(path: "chapter.mp4")
        try Data("final-media".utf8).write(to: media)
        try Data("thumbnail".utf8).write(to: thumbnail)
        try Data(
            "WEBVTT\n\n00:00.000 --> 00:01.000\nPackage\n".utf8
        ).write(to: subtitle)
        try Data("chapter-media".utf8).write(to: split)
        let selection = SubtitleTrackSelection(
            trackID: "subtitle-111111111111111111111111",
            formatID: "subtitle-format-111111111111111111111111",
            language: "en",
            automatic: false
        )
        let chapters = [
            MediaChapter(title: "Opening", startSeconds: 0, endSeconds: 2),
        ]
        let workflow = MediaPackageWorkflow()
        let folderProgress = PackageProgressRecorder()
        let package = try workflow.buildFolder(
            mediaURL: media,
            thumbnailURL: thumbnail,
            subtitles: [
                PreparedSubtitleSidecar(
                    selection: selection,
                    kind: .webVTT,
                    temporaryURL: subtitle
                ),
            ],
            chapterSplits: [
                ChapterSplitOutput(
                    chapter: chapters[0],
                    filename: "001 - Opening",
                    fileURL: split,
                    probe: emptyMediaProbe(fileURL: split)
                ),
            ],
            chapters: chapters,
            metadata: mediaMetadata(chapters: [
                ExtractedChapter(
                    title: "Opening",
                    startTimeSeconds: 0,
                    endTimeSeconds: 2
                ),
            ]),
            packageName: "Verified Video",
            temporaryRoot: root,
            progress: folderProgress.record
        )

        #expect(package.fileCount == 8)
        #expect(package.relativePaths == [
            "chapters/001 - Opening.mp4",
            "manifest.json",
            "media/video.mp4",
            "metadata/chapters.json",
            "metadata/description.txt",
            "metadata/info.json",
            "subtitles/video.en.manual.vtt",
            "thumbnail/cover.jpg",
        ])
        #expect(folderProgress.values.last == 1)
        let info = try Data(
            contentsOf: package.folderURL.appending(path: "metadata/info.json")
        )
        #expect(info.range(of: Data("canonical_url".utf8)) == nil)
        #expect(info.range(of: Data("https://".utf8)) == nil)

        let ZIPProgress = PackageProgressRecorder()
        let archiveURL = root.appending(path: "Verified Video.zip")
        let ZIP = try await workflow.zipFinalizedFolder(
            package,
            to: archiveURL,
            progress: ZIPProgress.recordZIP
        )
        #expect(ZIP.writeResult.sourceBytes == 1_324)
        #expect(ZIP.writeResult.archiveBytes == 2_414)
        let archive = try Data(contentsOf: ZIP.archiveURL)
        #expect(ZIP.writeResult.entryCount == package.fileCount)
        #expect(ZIPProgress.values.first == 0)
        #expect(ZIPProgress.values.last == 1)
        #expect(ZIPProgress.values == ZIPProgress.values.sorted())
        #expect(archive.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        for path in package.relativePaths {
            #expect(archive.range(of: Data(path.utf8)) != nil)
        }

        let exportRoot = root.appending(
            path: "exports",
            directoryHint: .isDirectory
        )
        let exporter = ExportManager(
            documentsRootURL: exportRoot,
            shareRootURL: root.appending(path: "share")
        )
        let first = try await exporter.exportDirectory(
            sourceURL: package.folderURL,
            destination: .appDocuments,
            filename: "Verified Video Package",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "fixture"
        )
        let second = try await exporter.exportDirectory(
            sourceURL: package.folderURL,
            destination: .appDocuments,
            filename: "Verified Video Package",
            folderBookmark: nil,
            duplicateHandling: .addNumber,
            videoID: "fixture"
        )
        #expect(first.fileURL?.lastPathComponent == "Verified Video Package")
        #expect(second.fileURL?.lastPathComponent == "Verified Video Package 2")
    }

    @Test(arguments: [false, true])
    func completedZIPReadbackValidatesOrdinaryAndZIP64(
        forceZIP64: Bool
    ) async throws {
        let root = try makeRoot("ZIPReadback")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try ZIPMutationFixture.sources(in: root)
        let archive = root.appending(path: "verified.zip")
        let recorder = PackageProgressRecorder()
        let writer = ZIPArchiveWriter(
            forceZIP64ForTesting: forceZIP64
        )

        let result = try await writer.write(
            sources: sources,
            to: archive,
            progress: recorder.recordZIP
        )
        let verification = try await writer.verifyCompletedArchive(
            at: archive,
            expectedSources: sources
        )
        let data = try Data(contentsOf: archive)

        #expect(result == verification)
        #expect(result.entryCount == 2)
        #expect(result.sourceBytes == 11)
        #expect(recorder.values == recorder.values.sorted())
        #expect(data.range(of: ZIPMutationFixture.endSignature) != nil)
        #expect(
            (data.range(of: ZIPMutationFixture.ZIP64EndSignature) != nil)
                == forceZIP64
        )
        #expect(
            (data.range(of: ZIPMutationFixture.ZIP64LocatorSignature) != nil)
                == forceZIP64
        )
    }

    @Test(arguments: ZIPCorruptionCase.allCases)
    func completedZIPReadbackRejectsCorruptionAndDeletesArchive(
        corruption: ZIPCorruptionCase
    ) async throws {
        let root = try makeRoot("ZIPCorruption-\(corruption.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try ZIPMutationFixture.sources(in: root)
        let archive = root.appending(path: "corrupt.zip")
        let writer = ZIPArchiveWriter(
            forceZIP64ForTesting: corruption.requiresZIP64
        )
        _ = try await writer.write(sources: sources, to: archive)
        var data = try Data(contentsOf: archive)
        try ZIPMutationFixture.mutate(&data, corruption: corruption)
        try data.write(to: archive, options: .atomic)

        await #expect(throws: ZIPArchiveWriterError.self) {
            try await writer.verifyCompletedArchive(
                at: archive,
                expectedSources: sources
            )
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test(arguments: PackageMutationCase.allCases)
    func ZIPRejectsFinalizedPackageOrManifestMutation(
        mutation: PackageMutationCase
    ) async throws {
        let root = try makeRoot("PackageMutation-\(mutation.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "video.mp4")
        try Data("final-media".utf8).write(to: media)
        let workflow = MediaPackageWorkflow()
        let package = try workflow.buildFolder(
            mediaURL: media,
            thumbnailURL: nil,
            subtitles: [],
            chapterSplits: [],
            chapters: [],
            metadata: nativeMetadata(),
            packageName: "Mutation",
            temporaryRoot: root,
            progress: { _ in }
        )
        try mutateFinalizedPackage(package.folderURL, mutation: mutation)
        let archive = root.appending(path: "must-not-exist.zip")

        await #expect(throws: MediaPackageWorkflowError.self) {
            try await workflow.zipFinalizedFolder(
                package,
                to: archive,
                progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test
    func preCancelledZIPRemovesIncompleteArchive() async throws {
        let root = try makeRoot("PackageCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "video.mp4")
        try Data(repeating: 7, count: 2 * 1_024 * 1_024).write(to: media)
        let workflow = MediaPackageWorkflow()
        let package = try workflow.buildFolder(
            mediaURL: media,
            thumbnailURL: nil,
            subtitles: [],
            chapterSplits: [],
            chapters: [],
            metadata: nativeMetadata(),
            packageName: "Cancel",
            temporaryRoot: root,
            progress: { _ in }
        )
        let archive = root.appending(path: "cancel.zip")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await workflow.zipFinalizedFolder(
                package,
                to: archive,
                progress: { _ in }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(FileManager.default.fileExists(atPath: package.folderURL.path))
    }

    @Test
    func preCancelledNativeEmbeddingPublishesNoOutput() throws {
        let root = try makeRoot("SubtitleEmbedCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let media = root.appending(path: "media.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: media,
            container: ILLUCET_MEDIA_CONTAINER_MP4
        )
        let subtitle = root.appending(path: "cancel.vtt")
        try Data(
            "WEBVTT\n\n00:00.000 --> 00:01.000\nCancel\n".utf8
        ).write(to: subtitle, options: .withoutOverwriting)
        let output = root.appending(path: "cancelled.mp4")
        let job = try #require(illucet_ffmpeg_job_create(nil, nil))
        defer { illucet_ffmpeg_job_destroy(job) }
        illucet_ffmpeg_job_cancel(job)
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        let metadata = emptyNativeMetadata()
        let status = "eng".withCString { language in
            "English".withCString { title in
                var request = IllucetSubtitleMuxRequest(
                    container: ILLUCET_MEDIA_CONTAINER_MP4,
                    codec: ILLUCET_SUBTITLE_CODEC_MOV_TEXT,
                    fast_start: true,
                    metadata: metadata,
                    language: language,
                    title: title,
                    automatic: false,
                    is_default: true,
                    is_forced: false
                )
                return media.path.withCString { mediaPath in
                    subtitle.path.withCString { subtitlePath in
                        output.path.withCString { outputPath in
                            illucet_ffmpeg_embed_subtitle(
                                mediaPath,
                                subtitlePath,
                                outputPath,
                                &request,
                                job,
                                &error
                            )
                        }
                    }
                }
            }
        }

        #expect(status == ILLUCET_FFMPEG_CANCELLED)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try partialFiles(in: root).isEmpty)
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part8-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func generateFixtures(
        in root: URL
    ) throws -> (video: URL, audio: URL) {
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "incompatible.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
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
                            &error
                        )
                    }
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                error.map { String(cString: $0) }
                    ?? "Fixture generation failed."
            )
        }
        return (video, audio)
    }

    private func merge(
        video: URL,
        audio: URL,
        output: URL,
        container: IllucetMediaContainer
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        var request = IllucetStreamCopyRequest(
            mode: ILLUCET_STREAM_COPY_MERGE,
            container: container,
            fast_start: true,
            metadata: emptyNativeMetadata()
        )
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                output.path.withCString { outputPath in
                    illucet_ffmpeg_stream_copy(
                        videoPath,
                        audioPath,
                        outputPath,
                        &request,
                        nil,
                        &error
                    )
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                error.map { String(cString: $0) }
                    ?? "Fixture merge failed."
            )
        }
    }

    private func writeStaticVideo(to URL: URL) async throws {
        let writer = try AVAssetWriter(outputURL: URL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 400_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        guard writer.canAdd(input) else {
            throw BurnInPixelTestError.fixtureCreation
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? BurnInPixelTestError.fixtureCreation
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw BurnInPixelTestError.fixtureCreation
        }
        for frameIndex in 0 ..< 60 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &optionalBuffer
            ) == kCVReturnSuccess,
                let buffer = optionalBuffer
            else {
                throw BurnInPixelTestError.fixtureCreation
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw BurnInPixelTestError.fixtureCreation
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< 180 {
                let row = base.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0 ..< 320 {
                    let offset = x * 4
                    row[offset] = 48
                    row[offset + 1] = 48
                    row[offset + 2] = 48
                    row[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: 30
                )
            ) else {
                throw writer.error ?? BurnInPixelTestError.fixtureCreation
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? BurnInPixelTestError.fixtureCreation
        }
    }

    private func decodedFrame(
        from URL: URL,
        seconds: Double
    ) async throws -> BurnInPixelFrame {
        let generator = AVAssetImageGenerator(
            asset: AVURLAsset(url: URL)
        )
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(
            value: 1,
            timescale: 120
        )
        generator.requestedTimeToleranceAfter = CMTime(
            value: 1,
            timescale: 120
        )
        let generated = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        )
        let image = generated.image
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            CIImage(cgImage: image),
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return BurnInPixelFrame(
            width: width,
            height: height,
            bytes: bytes
        )
    }

    private func pixelChangeRatio(
        _ first: BurnInPixelFrame,
        _ second: BurnInPixelFrame,
        verticalFraction: ClosedRange<Double>,
        threshold: Int
    ) -> Double {
        guard first.width == second.width,
              first.height == second.height,
              first.bytes.count == second.bytes.count
        else {
            return 0
        }
        let startY = max(
            0,
            min(
                first.height - 1,
                Int(Double(first.height) * verticalFraction.lowerBound)
            )
        )
        let endY = max(
            startY + 1,
            min(
                first.height,
                Int(Double(first.height) * verticalFraction.upperBound)
            )
        )
        var changed = 0
        var compared = 0
        for y in startY ..< endY {
            for x in 0 ..< first.width {
                let offset = (y * first.width + x) * 4
                let delta = abs(
                    Int(first.bytes[offset]) - Int(second.bytes[offset])
                ) + abs(
                    Int(first.bytes[offset + 1])
                        - Int(second.bytes[offset + 1])
                ) + abs(
                    Int(first.bytes[offset + 2])
                        - Int(second.bytes[offset + 2])
                )
                if delta >= threshold * 3 {
                    changed += 1
                }
                compared += 1
            }
        }
        return compared == 0 ? 0 : Double(changed) / Double(compared)
    }

    private func transcodeOpusWebM(
        input: URL,
        output: URL
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        var request = IllucetAudioTranscodeRequest(
            codec: ILLUCET_AUDIO_CODEC_OPUS,
            container: ILLUCET_MEDIA_CONTAINER_WEBM,
            rate_control: ILLUCET_AUDIO_RATE_CONTROL_BITRATE,
            bitrate_bits_per_second: 96_000,
            quality: 0,
            sample_rate: 48_000,
            channels: 2,
            normalize_loudness: false,
            integrated_loudness_lufs: -16,
            loudness_range_lu: 11,
            true_peak_dbtp: -1.5,
            fast_start: false,
            metadata: emptyNativeMetadata()
        )
        let status = input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                illucet_ffmpeg_transcode_audio(
                    inputPath,
                    outputPath,
                    &request,
                    nil,
                    &error
                )
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                error.map { String(cString: $0) }
                    ?? "Opus WebM fixture failed."
            )
        }
    }

    private func burnInH264Plan() -> OutputPlan {
        OutputPlan(
            mode: .videoAndAudio,
            containerChoice: .mp4,
            container: .mp4,
            fileExtension: "mp4",
            strategy: .transcodeVideo,
            sourceVideoCodec: MediaCodec(rawValue: "mpeg4"),
            sourceAudioCodec: .aac,
            videoEncodingCodec: .h264,
            videoEncodingFrameRate: 30,
            audioEncodingSettings: nil,
            expectedVideoCodec: .h264,
            expectedAudioCodec: .aac,
            expectedDimensions: MediaDimensions(width: 320, height: 180),
            expectedFrameRate: 30,
            expectedHDR: false,
            expectedSampleRate: 48_000,
            expectedChannelCount: 2,
            expectedAudioBitRate: nil,
            expectedVideoStreams: 1 ... 1,
            expectedAudioStreams: 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: true
        )
    }

    private func chapterPlan() -> OutputPlan {
        OutputPlan(
            mode: .videoAndAudio,
            containerChoice: .mp4,
            container: .mp4,
            fileExtension: "mp4",
            strategy: .mergeStreamCopy,
            sourceVideoCodec: MediaCodec(rawValue: "mpeg4"),
            sourceAudioCodec: .aac,
            videoEncodingCodec: nil,
            videoEncodingFrameRate: nil,
            audioEncodingSettings: nil,
            expectedVideoCodec: MediaCodec(rawValue: "mpeg4"),
            expectedAudioCodec: .aac,
            expectedDimensions: MediaDimensions(width: 320, height: 180),
            expectedFrameRate: 30,
            expectedHDR: false,
            expectedSampleRate: 48_000,
            expectedChannelCount: 2,
            expectedAudioBitRate: nil,
            expectedVideoStreams: 1 ... 1,
            expectedAudioStreams: 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: true
        )
    }

    private func emptyNativeMetadata() -> IllucetMediaMetadata {
        IllucetMediaMetadata(
            preserve_source_metadata: true,
            title: nil,
            artist: nil,
            date: nil,
            description: nil,
            comment: nil,
            source_url: nil,
            video_id: nil,
            channel: nil
        )
    }

    private func nativeMetadata(
        subtitles: [MediaSubtitleTrack] = []
    ) -> MediaMetadata {
        let base = DeveloperFixtures.media
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: base.videoID,
            title: base.title,
            channel: base.channel,
            uploader: base.uploader,
            durationSeconds: 2,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: false,
            liveStatus: nil,
            thumbnails: [],
            chapters: [],
            subtitles: subtitles,
            formats: base.formats
        )
    }

    private func mediaMetadata(
        chapters: [ExtractedChapter]
    ) -> MediaMetadata {
        let base = nativeMetadata()
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: base.videoID,
            title: base.title,
            channel: base.channel,
            uploader: base.uploader,
            durationSeconds: base.durationSeconds,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: base.isLive,
            liveStatus: base.liveStatus,
            thumbnails: base.thumbnails,
            chapters: chapters,
            subtitles: base.subtitles,
            formats: base.formats
        )
    }

    private func emptyMediaProbe(fileURL: URL) -> MediaProbeResult {
        MediaProbeResult(
            fileURL: fileURL,
            formatNames: ["mov", "mp4"],
            formatLongName: nil,
            durationSeconds: 2,
            startTimeSeconds: 0,
            bitRate: nil,
            fileSize: 5,
            metadata: [:],
            streams: [],
            chapters: []
        )
    }

    private func partialFiles(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains("illucet-partial")
                || $0.pathExtension == "partial"
        }
    }

    private func chapterTransactionFixture(
        _ root: URL
    ) throws -> (
        items: [ExportFileTransactionItem],
        destination: URL
    ) {
        let sources = root.appending(
            path: "Sources",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        let definitions = [
            ("primary.mp4", "Video", "primary"),
            ("chapter-1.mp4", "Video - 001", "chapter-one"),
            ("chapter-2.mp4", "Video - 002", "chapter-two"),
        ]
        let items = try definitions.map { file, name, contents in
            let URL = sources.appending(path: file)
            try Data(contents.utf8).write(to: URL)
            return ExportFileTransactionItem(sourceURL: URL, filename: name)
        }
        return (
            items,
            root.appending(path: "Exports", directoryHint: .isDirectory)
        )
    }

    private func visibleFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }
    }

    private func hiddenTransactionFiles(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".illucet-export-transaction-")
        }
    }

    private func mutateFinalizedPackage(
        _ folder: URL,
        mutation: PackageMutationCase
    ) throws {
        let media = folder.appending(path: "media/video.mp4")
        let manifestURL = folder.appending(path: "manifest.json")
        switch mutation {
        case .addedFile:
            try Data("extra".utf8).write(
                to: folder.appending(path: ".unexpected.bin")
            )
        case .removedFile:
            try FileManager.default.removeItem(
                at: folder.appending(path: "metadata/description.txt")
            )
        case .sameSizeContent:
            var data = try Data(contentsOf: media)
            data[0] ^= 1
            try data.write(to: media, options: .atomic)
        case .changedSize:
            let handle = try FileHandle(forWritingTo: media)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        case .manifestEntry, .manifestSize, .manifestTotal:
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifestURL)
                ) as? [String: Any]
            )
            if mutation == .manifestTotal {
                object["totalBytes"] =
                    ((object["totalBytes"] as? NSNumber)?.uint64Value ?? 0) + 1
            } else {
                var entries = try #require(
                    object["entries"] as? [[String: Any]]
                )
                if mutation == .manifestEntry {
                    entries[0]["path"] = "unexpected/path.bin"
                } else {
                    entries[0]["size"] =
                        ((entries[0]["size"] as? NSNumber)?.uint64Value ?? 0) + 1
                }
                object["entries"] = entries
            }
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: manifestURL, options: .atomic)
        }
    }
}

private enum ChapterTransactionTestError: Error {
    case injected
}

private final class ChapterDuplicateEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: DuplicateConflict?

    func record(_ event: DownloadCoordinatorEvent) {
        guard case let .requestDuplicate(conflict) = event else { return }
        lock.withLock {
            request = conflict
        }
    }

    func waitForRequest() async throws -> DuplicateConflict {
        for _ in 0 ..< 1_000 {
            if let request = lock.withLock({ request }) {
                return request
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ChapterTransactionTestError.injected
    }
}

private struct BurnInPixelFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

private enum BurnInPixelTestError: Error {
    case fixtureCreation
}

enum ZIPCorruptionCase: String, CaseIterable, Sendable {
    case centralName
    case localName
    case archivedData
    case centralCRC
    case centralCompressedSize
    case centralUncompressedSize
    case localHeaderOffset
    case descriptorCRC
    case descriptorSize
    case duplicateName
    case traversalName
    case decomposedUnicodeName
    case EOCDCount
    case EOCDOffset
    case trailingByte
    case truncatedArchive
    case ZIP64Locator
    case ZIP64Count
    case ZIP64Offset

    var requiresZIP64: Bool {
        switch self {
        case .ZIP64Locator, .ZIP64Count, .ZIP64Offset:
            true
        default:
            false
        }
    }
}

enum PackageMutationCase: String, CaseIterable, Sendable {
    case addedFile
    case removedFile
    case sameSizeContent
    case changedSize
    case manifestEntry
    case manifestSize
    case manifestTotal
}

private enum ZIPMutationFixture {
    static let localSignature = Data([0x50, 0x4b, 0x03, 0x04])
    static let centralSignature = Data([0x50, 0x4b, 0x01, 0x02])
    static let endSignature = Data([0x50, 0x4b, 0x05, 0x06])
    static let ZIP64EndSignature = Data([0x50, 0x4b, 0x06, 0x06])
    static let ZIP64LocatorSignature = Data([0x50, 0x4b, 0x06, 0x07])

    static func sources(in root: URL) throws -> [ZIPArchiveSource] {
        let first = root.appending(path: "first.bin")
        let second = root.appending(path: "second.bin")
        try Data("alpha".utf8).write(to: first)
        try Data("bravo!".utf8).write(to: second)
        return [
            ZIPArchiveSource(archivePath: "safe12.bin", fileURL: first),
            ZIPArchiveSource(archivePath: "other1.bin", fileURL: second),
        ]
    }

    static func mutate(
        _ data: inout Data,
        corruption: ZIPCorruptionCase
    ) throws {
        let centrals = ranges(of: centralSignature, in: data)
        let locals = ranges(of: localSignature, in: data)
        let end = try requiredRange(of: endSignature, in: data).lowerBound
        guard centrals.count == 2, locals.count == 2 else {
            throw ZIPMutationTestError.malformedFixture
        }
        let firstCentral = centrals[0].lowerBound
        let secondCentral = centrals[1].lowerBound
        let firstLocal = locals[0].lowerBound
        let secondLocal = locals[1].lowerBound
        let firstNameCount = Int(readUInt16(data, firstLocal + 26))
        let firstExtraCount = Int(readUInt16(data, firstLocal + 28))
        let firstData = firstLocal + 30 + firstNameCount + firstExtraCount
        let firstDescriptor = firstData + 5
        switch corruption {
        case .centralName:
            data[firstCentral + 46] ^= 1
        case .localName:
            data[firstLocal + 30] ^= 1
        case .archivedData:
            data[firstData] ^= 1
        case .centralCRC:
            data[firstCentral + 16] ^= 1
        case .centralCompressedSize:
            data[firstCentral + 20] ^= 1
        case .centralUncompressedSize:
            data[firstCentral + 24] ^= 1
        case .localHeaderOffset:
            writeUInt32(
                &data,
                at: firstCentral + 42,
                value: UInt32.max - 1
            )
        case .descriptorCRC:
            data[firstDescriptor + 4] ^= 1
        case .descriptorSize:
            data[firstDescriptor + 8] ^= 1
        case .duplicateName:
            replace(
                &data,
                at: secondLocal + 30,
                with: Data("safe12.bin".utf8)
            )
            replace(
                &data,
                at: secondCentral + 46,
                with: Data("safe12.bin".utf8)
            )
        case .traversalName:
            let traversal = Data("../bad.bin".utf8)
            replace(&data, at: firstLocal + 30, with: traversal)
            replace(&data, at: firstCentral + 46, with: traversal)
        case .decomposedUnicodeName:
            let decomposed = Data("Cafe\u{301}.bin".utf8)
            guard decomposed.count == firstNameCount else {
                throw ZIPMutationTestError.malformedFixture
            }
            replace(&data, at: firstLocal + 30, with: decomposed)
            replace(&data, at: firstCentral + 46, with: decomposed)
        case .EOCDCount:
            data[end + 10] ^= 1
        case .EOCDOffset:
            data[end + 16] ^= 1
        case .trailingByte:
            data.append(0)
        case .truncatedArchive:
            data.removeLast()
        case .ZIP64Locator:
            let locator = try requiredRange(
                of: ZIP64LocatorSignature,
                in: data
            ).lowerBound
            data[locator + 4] ^= 1
        case .ZIP64Count:
            let ZIP64 = try requiredRange(
                of: ZIP64EndSignature,
                in: data
            ).lowerBound
            data[ZIP64 + 32] ^= 1
        case .ZIP64Offset:
            let ZIP64 = try requiredRange(
                of: ZIP64EndSignature,
                in: data
            ).lowerBound
            data[ZIP64 + 48] ^= 1
        }
    }

    private static func ranges(of needle: Data, in data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let range = data[cursor...].range(of: needle) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }

    private static func requiredRange(
        of needle: Data,
        in data: Data
    ) throws -> Range<Int> {
        guard let range = data.range(of: needle, options: .backwards) else {
            throw ZIPMutationTestError.malformedFixture
        }
        return range
    }

    private static func replace(
        _ data: inout Data,
        at offset: Int,
        with replacement: Data
    ) {
        data.replaceSubrange(
            offset ..< offset + replacement.count,
            with: replacement
        )
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func writeUInt32(
        _ data: inout Data,
        at offset: Int,
        value: UInt32
    ) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

private enum ZIPMutationTestError: Error {
    case malformedFixture
}

private final class PackageProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func recordZIP(_ value: ZIPArchiveProgress) {
        record(value.fraction)
    }
}
