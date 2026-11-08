import AVFoundation
import Foundation
import Testing
@testable import Illucet

struct IllucetApplicationTests {
    @Test
    func filtersFormatsByPrimaryMode() {
        let metadata = DeveloperFixtures.media
        let audio = FormatSelection.formats(for: .audioOnly, in: metadata)
        let video = FormatSelection.formats(for: .videoOnly, in: metadata)
        let combined = FormatSelection.formats(
            for: .videoAndAudio,
            in: metadata
        )

        #expect(audio.allSatisfy { $0.hasAudio })
        #expect(video.allSatisfy { $0.hasVideo })
        #expect(combined.count == metadata.formats.count)
    }

    @Test
    func sortsAvailableResolutionDescendingAndUnique() {
        #expect(
            FormatSelection.availableResolutions(
                in: DeveloperFixtures.media
            ) == [2_160, 1_080, 360]
        )
    }

    @Test
    func pResolutionIsOrientationIndependentWithSafeFallbacks() {
        #expect(videoFormat(id: "a", width: 1_920, height: 1_080).pResolution == 1_080)
        #expect(videoFormat(id: "b", width: 1_080, height: 1_920).pResolution == 1_080)
        #expect(videoFormat(id: "c", width: 1_280, height: 720).pResolution == 720)
        #expect(videoFormat(id: "d", width: 720, height: 1_280).pResolution == 720)
        #expect(videoFormat(id: "e", width: 480, height: nil).pResolution == 480)
        #expect(videoFormat(id: "f", width: nil, height: 360).pResolution == 360)
        #expect(videoFormat(id: "g", width: 0, height: -1).pResolution == nil)
    }

    @Test
    func portraitFormatsDeduplicateFilterAndRankByPResolution() throws {
        let metadata = mediaMetadata(formats: [
            videoFormat(
                id: "landscape-1080",
                width: 1_920,
                height: 1_080,
                videoBitrateKbps: 4_000
            ),
            videoFormat(
                id: "portrait-1080",
                width: 1_080,
                height: 1_920,
                videoBitrateKbps: 5_000
            ),
            videoFormat(
                id: "portrait-720",
                width: 720,
                height: 1_280,
                videoBitrateKbps: 3_000
            ),
        ])

        #expect(FormatSelection.availableResolutions(in: metadata) == [1_080, 720])
        #expect(
            FormatSelection.bestVideo(in: metadata)?.formatID
                == "portrait-1080"
        )
        let capped = try #require(
            FormatSelection.bestVideo(
                in: metadata,
                maximumResolution: 720
            )
        )
        #expect(capped.formatID == "portrait-720")
        #expect(capped.width == 720)
        #expect(capped.height == 1_280)

        var configuration = DownloadConfiguration.standard
        configuration.mode = .videoOnly
        configuration.preset = .custom
        configuration.maximumResolution = 720
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )
        #expect(configuration.selectedVideoFormatID == "portrait-720")
    }

    @Test
    func selectsAppleCompatibleVideoAndAudio() throws {
        let video = try #require(
            FormatSelection.bestVideo(
                in: DeveloperFixtures.media,
                appleCompatible: true
            )
        )
        let audio = try #require(
            FormatSelection.bestAudio(
                in: DeveloperFixtures.media,
                appleCompatible: true
            )
        )

        #expect(video.formatID == "137")
        #expect(audio.formatID == "140")
    }

    @Test
    func smallPresetDoesNotSelectAbove720p() {
        var configuration = DownloadConfiguration.standard
        configuration.preset = .small
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: DeveloperFixtures.media
        )
        let selected = DeveloperFixtures.media.formats.first {
            $0.formatID == configuration.selectedVideoFormatID
        }
        #expect((selected?.pResolution ?? 0) <= 720)
    }

    @Test
    func automaticVideoAndAudioUsesRolePurePairInsteadOfCombinedHalves() {
        let metadata = mediaMetadata(formats: [
            testFormat(
                id: "combined-high",
                hasVideo: true,
                hasAudio: true,
                height: 1_080,
                videoBitrateKbps: 8_000,
                audioBitrateKbps: 256
            ),
            testFormat(
                id: "video-only",
                hasVideo: true,
                hasAudio: false,
                height: 1_080,
                videoBitrateKbps: 9_000
            ),
            testFormat(
                id: "audio-only",
                hasVideo: false,
                hasAudio: true,
                audioBitrateKbps: 128
            ),
        ])
        var configuration = DownloadConfiguration.standard
        configuration.preset = .best

        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )

        #expect(configuration.selectedVideoFormatID == "video-only")
        #expect(configuration.selectedAudioFormatID == "audio-only")
        #expect(configuration.formatSelectionProvenance == .automatic)
    }

    @Test
    func automaticVideoAndAudioKeepsPreferredCombinedQualityCoherent() {
        let metadata = mediaMetadata(formats: [
            testFormat(
                id: "combined-high",
                hasVideo: true,
                hasAudio: true,
                height: 1_080,
                videoBitrateKbps: 8_000,
                audioBitrateKbps: 256
            ),
            testFormat(
                id: "video-only-lower",
                hasVideo: true,
                hasAudio: false,
                height: 720,
                videoBitrateKbps: 4_000
            ),
            testFormat(
                id: "audio-only",
                hasVideo: false,
                hasAudio: true,
                audioBitrateKbps: 128
            ),
        ])
        var configuration = DownloadConfiguration.standard
        configuration.preset = .best

        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )

        #expect(configuration.selectedVideoFormatID == "combined-high")
        #expect(configuration.selectedAudioFormatID == nil)
    }

    @Test
    func automaticVideoAndAudioUsesIntentionalCombinedSourceCoherently() {
        let combined = testFormat(
            id: "combined",
            hasVideo: true,
            hasAudio: true,
            height: 360,
            videoBitrateKbps: 600,
            audioBitrateKbps: 96
        )
        let videoOnly = testFormat(
            id: "video-only",
            hasVideo: true,
            hasAudio: false,
            height: 360,
            videoBitrateKbps: 500
        )
        let metadataWithoutPureAudio = mediaMetadata(
            formats: [videoOnly, combined]
        )
        var configuration = DownloadConfiguration.standard
        configuration.preset = .best

        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadataWithoutPureAudio
        )

        #expect(configuration.selectedVideoFormatID == combined.formatID)
        #expect(configuration.selectedAudioFormatID == nil)

        let rolePurePair = mediaMetadata(formats: [
            videoOnly,
            testFormat(
                id: "audio-only",
                hasVideo: false,
                hasAudio: true,
                audioBitrateKbps: 128
            ),
            combined,
        ])
        configuration.preset = .small
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: rolePurePair
        )
        #expect(configuration.selectedVideoFormatID == combined.formatID)
        #expect(configuration.selectedAudioFormatID == nil)
    }

    @Test
    func automaticSingleRoleModesPreferPureSourcesAndBoundFallbacks() {
        let combined = testFormat(
            id: "combined",
            hasVideo: true,
            hasAudio: true,
            height: 1_080,
            videoBitrateKbps: 8_000,
            audioBitrateKbps: 256
        )
        let videoOnly = testFormat(
            id: "video-only",
            hasVideo: true,
            hasAudio: false,
            height: 720,
            videoBitrateKbps: 3_000
        )
        let audioOnly = testFormat(
            id: "audio-only",
            hasVideo: false,
            hasAudio: true,
            audioBitrateKbps: 128
        )
        let rolePureMetadata = mediaMetadata(
            formats: [combined, videoOnly, audioOnly]
        )

        var audioConfiguration = DownloadConfiguration.standard
        audioConfiguration.mode = .audioOnly
        audioConfiguration.preset = .best
        FormatSelection.applyAutomaticSelection(
            to: &audioConfiguration,
            metadata: rolePureMetadata
        )
        #expect(audioConfiguration.selectedVideoFormatID == nil)
        #expect(audioConfiguration.selectedAudioFormatID == audioOnly.formatID)

        var videoConfiguration = DownloadConfiguration.standard
        videoConfiguration.mode = .videoOnly
        videoConfiguration.preset = .best
        FormatSelection.applyAutomaticSelection(
            to: &videoConfiguration,
            metadata: rolePureMetadata
        )
        #expect(videoConfiguration.selectedVideoFormatID == videoOnly.formatID)
        #expect(videoConfiguration.selectedAudioFormatID == nil)

        let combinedOnly = mediaMetadata(formats: [combined])
        FormatSelection.applyAutomaticSelection(
            to: &audioConfiguration,
            metadata: combinedOnly
        )
        FormatSelection.applyAutomaticSelection(
            to: &videoConfiguration,
            metadata: combinedOnly
        )
        #expect(audioConfiguration.selectedAudioFormatID == combined.formatID)
        #expect(videoConfiguration.selectedVideoFormatID == combined.formatID)
    }

    @Test
    func automaticSelectionProvenancePersistsAndLegacyIDsRemainExact()
        throws
    {
        var configuration = DownloadConfiguration.standard
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: DeveloperFixtures.media
        )
        let encoded = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(
            DownloadConfiguration.self,
            from: encoded
        )
        #expect(restored.formatSelectionProvenance == .automatic)
        #expect(restored.shouldRefreshAutomaticFormatSelection)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "formatSelectionProvenance")
        let legacy = try JSONDecoder().decode(
            DownloadConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacy.formatSelectionProvenance == nil)
        #expect(legacy.selectedFormatIDs == configuration.selectedFormatIDs)
        #expect(!legacy.shouldRefreshAutomaticFormatSelection)
    }

    @Test
    func automaticSelectionSupportsHLSAndDASHWhilePreferringDirectTies()
        throws
    {
        let directVideo = videoFormat(
            id: "direct-video",
            width: 640,
            height: 360,
            videoBitrateKbps: 500
        )
        let directAudio = MediaFormat(
            formatID: "direct-audio",
            formatNote: "medium",
            extension: "m4a",
            container: "m4a_dash",
            videoCodec: nil,
            audioCodec: "mp4a.40.2",
            width: nil,
            height: nil,
            resolution: "audio only",
            framesPerSecond: nil,
            dynamicRange: nil,
            isHDR: false,
            audioBitrateKbps: 128,
            videoBitrateKbps: nil,
            totalBitrateKbps: 128,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: false,
            hasAudio: true,
            protocolName: "https",
            sourceType: "direct_http",
            language: nil
        )
        let HLSManifest = MediaFormat(
            formatID: "hls-manifest-combined",
            formatNote: "360p",
            extension: "mp4",
            container: "mp4",
            videoCodec: "avc1.42001E",
            audioCodec: "mp4a.40.2",
            width: 640,
            height: 360,
            resolution: "640x360",
            framesPerSecond: 30,
            dynamicRange: "SDR",
            isHDR: false,
            audioBitrateKbps: 192,
            videoBitrateKbps: 2_000,
            totalBitrateKbps: 2_192,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: true,
            hasAudio: true,
            protocolName: "m3u8_native",
            sourceType: "hls",
            language: nil
        )
        let DASHManifest = MediaFormat(
            formatID: "dash-video",
            formatNote: "360p DASH",
            extension: "mp4",
            container: "mp4_dash",
            videoCodec: "avc1.42001E",
            audioCodec: nil,
            width: 640,
            height: 360,
            resolution: "640x360",
            framesPerSecond: 30,
            dynamicRange: "SDR",
            isHDR: false,
            audioBitrateKbps: nil,
            videoBitrateKbps: 2_000,
            totalBitrateKbps: 2_000,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: true,
            hasAudio: false,
            protocolName: "http_dash_segments",
            sourceType: "dash",
            language: nil
        )
        let metadata = mediaMetadata(
            formats: [HLSManifest, DASHManifest, directVideo, directAudio]
        )
        var configuration = DownloadConfiguration.standard
        configuration.mode = .videoAndAudio
        configuration.preset = .custom
        configuration.maximumResolution = 360

        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )

        #expect(configuration.selectedVideoFormatID == DASHManifest.formatID)
        #expect(configuration.selectedAudioFormatID == directAudio.formatID)
        #expect(
            FormatSelection.formats(for: .videoAndAudio, in: metadata)
                .contains {
                    $0.formatID == HLSManifest.formatID
                }
        )
        #expect(
            FormatSelection.formats(for: .videoAndAudio, in: metadata)
                .contains { $0.formatID == DASHManifest.formatID }
        )

        configuration.mode = .audioOnly
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )
        #expect(configuration.selectedVideoFormatID == nil)
        #expect(configuration.selectedAudioFormatID == directAudio.formatID)

        configuration.mode = .videoOnly
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: metadata
        )
        #expect(configuration.selectedVideoFormatID == DASHManifest.formatID)
        #expect(configuration.selectedAudioFormatID == nil)

        let directTie = videoFormat(
            id: "direct-tie",
            width: 640,
            height: 360,
            videoBitrateKbps: 2_000
        )
        let tied = mediaMetadata(
            formats: [DASHManifest, HLSManifest, directTie]
        )
        configuration.mode = .videoOnly
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: tied
        )
        #expect(configuration.selectedVideoFormatID == directTie.formatID)

        let HLSOnly = mediaMetadata(formats: [HLSManifest])
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: HLSOnly
        )
        #expect(
            configuration.selectedVideoFormatID == HLSManifest.formatID
        )
        #expect(configuration.selectedAudioFormatID == nil)

        configuration.selectedVideoFormatID = HLSManifest.formatID
        configuration.formatSelectionProvenance = .manual
        let selected = try FormatSelection.selectedSourceFacts(
            configuration: configuration,
            metadata: HLSOnly
        )
        #expect(selected.count == 1)
        #expect(selected[0].formatID == HLSManifest.formatID)
        #expect(selected[0].transport == .HLSResources)
        #expect(selected[0].fileExtension == "mp4")
        #expect(selected[0].protocolName == "m3u8_native")
        #expect(selected[0].sourceType == "hls")
    }

    @Test
    func HLSSelectionTransportRejectsUnsupportedAnalyzedFacts() {
        let supported = HLSFormat()
        #expect(FormatSelection.supportedTransport(supported) == .HLSResources)
        let unsupported = [
            HLSFormat(protocolName: "https"),
            HLSFormat(sourceType: "direct_http"),
            HLSFormat(fileExtension: "ts"),
            HLSFormat(hasVideo: false, hasAudio: false),
        ]
        #expect(unsupported.allSatisfy {
            FormatSelection.supportedTransport($0) == nil
        })
        #expect(
            FormatSelection.supportedTransport(
                videoFormat(
                    id: "direct-still-supported",
                    width: 640,
                    height: 360
                )
            ) == .directHTTP
        )
        let DASH = MediaFormat(
            formatID: "dash-still-supported",
            formatNote: supported.formatNote,
            extension: supported.extension,
            container: supported.container,
            videoCodec: supported.videoCodec,
            audioCodec: nil,
            width: supported.width,
            height: supported.height,
            resolution: supported.resolution,
            framesPerSecond: supported.framesPerSecond,
            dynamicRange: supported.dynamicRange,
            isHDR: supported.isHDR,
            audioBitrateKbps: nil,
            videoBitrateKbps: supported.videoBitrateKbps,
            totalBitrateKbps: supported.videoBitrateKbps,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: true,
            hasAudio: false,
            protocolName: "http_dash_segments",
            sourceType: "dash",
            language: nil
        )
        #expect(FormatSelection.supportedTransport(DASH) == .DASHFragments)
    }

    @Test
    func estimatesCombinedStreamStorageWithSafetyMargin() throws {
        var configuration = DownloadConfiguration.standard
        configuration.selectedVideoFormatID = "137"
        configuration.selectedAudioFormatID = "140"
        let download = try #require(
            FormatSelection.estimatedDownloadBytes(
                configuration: configuration,
                metadata: DeveloperFixtures.media
            )
        )
        let temporary = try #require(
            FormatSelection.estimatedTemporaryBytes(
                configuration: configuration,
                metadata: DeveloperFixtures.media
            )
        )

        #expect(download == 124_500_000)
        #expect(temporary > download * 2)
    }

    @Test
    func warnsWithoutClaimingUpscaledAudioQuality() {
        var configuration = DownloadConfiguration.standard
        configuration.mode = .audioOnly
        configuration.audioCodec = .mp3
        configuration.audioBitrateKbps = 320
        configuration.selectedAudioFormatID = "140"

        let warning = FormatSelection.sourceQualityWarning(
            configuration: configuration,
            metadata: DeveloperFixtures.media
        )

        #expect(warning?.contains("will not gain quality") == true)
        #expect(warning?.contains("129 kbps") == true)
    }

    @Test
    func rollingSpeedRequiresThreeSamplesForETA() {
        var estimator = RollingSpeedEstimator(smoothing: 0.5)
        _ = estimator.add(bytes: 1_000, elapsedSeconds: 1)
        _ = estimator.add(bytes: 1_000, elapsedSeconds: 1)
        #expect(estimator.eta(remainingBytes: 10_000) == nil)
        _ = estimator.add(bytes: 1_000, elapsedSeconds: 1)
        #expect(estimator.eta(remainingBytes: 10_000) == 10)
    }

    @Test
    func rollingSpeedIgnoresCallbackFrequencyAndWaitsForRealTime() {
        var frequent = RollingSpeedEstimator()
        var sparse = RollingSpeedEstimator()
        frequent.record(totalBytes: 50_000, at: 0)
        sparse.record(totalBytes: 50_000, at: 0)
        for second in 1...4 {
            for tick in 1...100 {
                frequent.record(totalBytes: 50_000 + Int64((second - 1) * 1_000 + tick * 10),
                    at: Double(second - 1) + Double(tick) / 100)
            }
            sparse.record(totalBytes: 50_000 + Int64(second * 1_000), at: Double(second))
            #expect(frequent.smoothedBytesPerSecond == sparse.smoothedBytesPerSecond)
            #expect(frequent.sampleCount == second)
            if second < 3 { #expect(frequent.eta(remainingBytes: 10_000) == nil) }
        }
        #expect(frequent.eta(remainingBytes: 10_000) == 10)
        frequent.record(totalBytes: 54_000, at: 5)
        #expect((frequent.smoothedBytesPerSecond ?? 0) < 1_000)
        frequent.record(totalBytes: 0, at: 6)
        #expect(frequent.sampleCount == 0)
        #expect(frequent.eta(remainingBytes: 10_000) == nil)
    }

    @Test
    func rollingSpeedRejectsInvalidTimeAndSmoothsBriefBursts() {
        var estimator = RollingSpeedEstimator()
        _ = estimator.add(bytes: 1_000, elapsedSeconds: 1)
        _ = estimator.add(bytes: 1_000, elapsedSeconds: .nan)
        _ = estimator.add(bytes: 1_000, elapsedSeconds: .infinity)
        #expect(estimator.sampleCount == 1)
        estimator.record(totalBytes: 0, at: 0)
        estimator.record(totalBytes: 10_000, at: 0.01)
        #expect(estimator.smoothedBytesPerSecond == 1_000)
        estimator.record(totalBytes: 10_000, at: 1)
        #expect(abs((estimator.smoothedBytesPerSecond ?? 0) - 2_980) < 0.001)
    }

    @Test
    func filenameRendererPreservesUnicodeAndRemovesIllegalCharacters() {
        let rendered = FilenameSystem.render(
            template: "{title} / {video_id}",
            metadata: DeveloperFixtures.media,
            configuration: .standard,
            format: DeveloperFixtures.media.formats.first
        )
        #expect(!rendered.contains("/"))
        #expect(rendered.contains("Rick Astley"))
        #expect(rendered.contains("dQw4w9WgXcQ"))
    }

    @Test
    func numberedCollisionDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Collision-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Example.mp4")
        try Data([1]).write(to: original)

        let result = try FilenameSystem.resolvedCollisionURL(
            desiredURL: original,
            videoID: "fixture",
            handling: .addNumber
        )

        #expect(result?.lastPathComponent == "Example 2.mp4")
        #expect(try Data(contentsOf: original) == Data([1]))
    }

    @Test
    func diagnosticRedactionRemovesSignedURLAndCredentials() {
        let value = DiagnosticRedactor.redact(
            "GET https://media.example/video?sig=secret "
                + "Authorization=Bearer-secret cookie=session"
        )
        #expect(!value.contains("media.example"))
        #expect(!value.contains("secret"))
        #expect(!value.contains("session"))
        #expect(value.contains("[URL REDACTED]"))
    }

    @Test
    @MainActor
    func sponsorBlockSelectionDiagnosticsAreOptInAndObservational()
        async throws
    {
        let submittedVideoDuration = try #require(
            DeveloperFixtures.media.durationSeconds
        )
        let segment = SponsorBlockSegment(
            segmentID: "selection-segment-identity",
            category: .sponsor,
            startSeconds: 1,
            endSeconds: 2,
            description: nil,
            submittedVideoDuration: submittedVideoDuration,
            serverAction: .skip,
            votes: 1,
            isLocked: false
        )
        let model = IllucetAppModel(
            sponsorBlockService: SponsorBlockStaticService(
                availableSegments: [segment]
            )
        )
        await model.diagnostics.clear()
        defer {
            model.sponsorBlockPreviewTask?.cancel()
            Task { await model.diagnostics.clear() }
        }
        model.analyzedMetadata = DeveloperFixtures.media
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        model.configuration.sponsorBlock = policy

        model.beginSponsorBlockPreview()
        try await waitForSponsorBlockPreview(model)
        let disabledSelection: [SponsorBlockSegmentSelection]? =
            model.configuration.sponsorBlock.selectionSnapshot?.segments
        #expect(await model.diagnostics.allEntries().isEmpty)

        policy.clearSelection()
        model.configuration.sponsorBlock = policy
        await model.sponsorBlockDiagnostics.setEnabled(true)
        model.beginSponsorBlockPreview()
        try await waitForSponsorBlockPreview(model)
        #expect(
            model.configuration.sponsorBlock.selectionSnapshot?.segments
                == disabledSelection
        )
        let entries = await model.diagnostics.allEntries().filter {
            $0.subsystem == "sponsorblock"
        }
        #expect(
            entries.map { $0.event } == ["segment_selection_completed"]
        )
        let text = entries.compactMap { $0.detail }.joined(separator: "\n")
        #expect(text.contains("category_count=\(SponsorBlockCategory.allCases.count)"))
        #expect(text.contains("segment_count=1"))
        #expect(!text.contains(segment.segmentID))
        #expect(!text.contains(DeveloperFixtures.media.videoID))
    }

    @Test
    func transportDiagnosticsPersistOnlyTypedAllowlistedFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-TransportDiagnostics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = ResolvedStream(
            formatID: "137\nunsafe",
            URL: URL(
                string:
                    "https://rr1---sn-fixture.googlevideo.com/media"
                    + "?sig=signed-query-secret&token=query-token-secret"
            )!,
            HTTPHeaders: [
                "Authorization": "Bearer header-secret",
                "Cookie": "session=cookie-secret",
            ],
            fileExtension: "mp4",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 1_024,
            httpChunkSize: 10 * 1_024 * 1_024
        )
        let facts = StreamTransportDiagnosticFacts(stream: stream)
        #expect(facts.formatID == "137_unsafe")
        #expect(facts.hostname == "rr1---sn-fixture.googlevideo.com")
        #expect(
            StreamTransportDiagnosticFacts(
                stream: ResolvedStream(
                    formatID: "137",
                    URL: stream.URL,
                    HTTPHeaders: stream.HTTPHeaders,
                    fileExtension: stream.fileExtension,
                    protocolName: stream.protocolName,
                    sourceType: stream.sourceType,
                    hasVideo: stream.hasVideo,
                    hasAudio: stream.hasAudio,
                    expectedBytes: stream.expectedBytes,
                    httpChunkSize:
                        YTDLPStreamResolver.maximumHTTPChunkSize + 1
                )
            ).httpChunkSize == nil
        )
        #expect(
            facts.resolutionDetail
                == "format_id=137_unsafe, role=video, "
                + "expected_bytes=1024, source_type=direct_http, "
                + "protocol=https, host=rr1---sn-fixture.googlevideo.com, "
                + "http_chunk_size=10485760, challenge_resolved=true"
        )

        let diagnostics = DiagnosticStore(rootURL: root)
        await diagnostics.record(
            .info,
            subsystem: "transport",
            event: "stream_resolved",
            detail: facts.resolutionDetail
        )
        await diagnostics.record(
            .info,
            subsystem: "transport",
            event: "stream_transfer_completed",
            detail: facts.completionDetail(
                actualBytes: 1_024,
                rollingBytesPerSecond: 12_345.4,
                reusedSource: false,
                transferStrategy: .boundedRanges,
                plannedRangeCount: 3,
                requestedRangeCount: 2,
                verifiedReusableBytes: 512,
                networkBytesReceived: 1_536
            )
        )

        let persisted = try String(
            contentsOf: root.appending(path: "Diagnostics.json"),
            encoding: .utf8
        )
        let reportURL = try await diagnostics.exportReport(
            environment: [:],
            jobs: []
        )
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(
                at: reportURL.deletingLastPathComponent()
            )
        }
        for output in [persisted, report] {
            #expect(output.contains("http_chunk_size=10485760"))
            #expect(output.contains("expected_bytes_match=true"))
            #expect(output.contains("strategy=bounded_ranges"))
            #expect(output.contains("planned_ranges=3"))
            #expect(output.contains("requested_ranges=2"))
            #expect(output.contains("verified_reusable_bytes=512"))
            #expect(output.contains("network_bytes_received=1536"))
            #expect(output.contains("rolling_bytes_per_second=12345"))
            #expect(!output.contains("signed-query-secret"))
            #expect(!output.contains("query-token-secret"))
            #expect(!output.contains("header-secret"))
            #expect(!output.contains("cookie-secret"))
            #expect(!output.contains("Authorization"))
            #expect(!output.contains("Cookie"))
            #expect(!output.contains("/media"))
        }
    }

    @Test
    func legacyJobProgressDefaultsVerifiedReusableBytesToUnknown() throws {
        let encoded = try JSONEncoder().encode(JobProgress.zero)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "verifiedReusableBytes")
        let legacy = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(
            JobProgress.self,
            from: legacy
        )

        #expect(decoded.bytesDownloaded == 0)
        #expect(decoded.verifiedReusableBytes == nil)
    }

    @Test
    func persistencePreservesRunningJobForCoordinatorReconciliation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-State-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = IllucetPersistence(rootURL: root)
        var job = fixtureJob
        job.state = .running
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .transferring
        )
        var snapshot = IllucetSnapshot.empty
        snapshot.jobs = [job]
        try await persistence.save(snapshot)

        let reloaded = IllucetPersistence(rootURL: root)
        let result = try await reloaded.load()

        #expect(result.jobs.first?.state == .running)
        #expect(
            result.jobs.first?.pipelineCheckpoint?.phase
                == .transferring
        )
        #expect(result.jobs.first?.errorCode == nil)
    }

    @Test
    func persistedJobHistoryAndCheckpointExcludeResolvedTransportSecrets()
        throws
    {
        let signedMediaURL = URL(
            string:
                "https://rr1---sn-fixture.googlevideo.com/media"
                + "?sig=signed-media-secret&token=query-token-secret"
        )!
        let resolvedStream = ResolvedStream(
            formatID: "137",
            URL: signedMediaURL,
            HTTPHeaders: [
                "Authorization": "Bearer header-secret",
                "Cookie": "session=cookie-secret",
            ],
            fileExtension: "mp4",
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: true,
            hasAudio: false,
            expectedBytes: 1_024,
            httpChunkSize: 10 * 1_024 * 1_024
        )
        var job = fixtureJob
        job.state = .completed
        job.stage = .complete
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .complete,
            sourceFiles: [
                resolvedStream.formatID: URL(
                    fileURLWithPath: "/tmp/Illucet/137.mp4"
                ),
            ]
        )
        var snapshot = IllucetSnapshot.empty
        snapshot.jobs = [job]
        snapshot.history = [HistoryRecord(job: job)]

        let encoded = String(
            decoding: try JSONEncoder.illucetEncoder.encode(snapshot),
            as: UTF8.self
        )
        #expect(encoded.contains("137.mp4"))
        #expect(!encoded.contains(signedMediaURL.absoluteString))
        #expect(!encoded.contains("signed-media-secret"))
        #expect(!encoded.contains("query-token-secret"))
        #expect(!encoded.contains("header-secret"))
        #expect(!encoded.contains("cookie-secret"))
        #expect(!encoded.contains("http_chunk_size"))
        #expect(!encoded.contains("httpChunkSize"))
        #expect(!encoded.contains("HTTPHeaders"))
        #expect(!encoded.contains("downloader_options"))
    }

    @Test
    func outputModeRequiresExplicitZeroAudioForVideoOnly() {
        var configuration = DownloadConfiguration.standard
        configuration.mode = .videoOnly
        #expect(configuration.explicitlyRemovesAudio)
        #expect(!DownloadConfiguration.standard.explicitlyRemovesAudio)
    }

    @Test @MainActor
    func historyPlaybackAudioSessionLifecycleUsesMediaSemantics() throws {
        let session = RecordingHistoryPlaybackAudioSession()
        let owner = HistoryPlaybackAudioSessionOwner(session: session)

        try owner.playbackDidStart()
        try owner.playbackDidStart()
        #expect(owner.playbackRequested)
        #expect(owner.isActive)
        #expect(session.events == [
            .category(
                AVAudioSession.Category.playback.rawValue,
                AVAudioSession.Mode.moviePlayback.rawValue,
                0
            ),
            .active(true, 0),
        ])

        try owner.playbackDidStop()
        try owner.playbackDidStop()
        #expect(!owner.playbackRequested)
        #expect(!owner.isActive)
        #expect(session.events.last == .active(
            false,
            AVAudioSession.SetActiveOptions
                .notifyOthersOnDeactivation.rawValue
        ))
        #expect(session.events.count == 3)
    }

    @Test @MainActor
    func historyPlaybackAudioSessionFailureIsNonfatalAndTyped() {
        let session = RecordingHistoryPlaybackAudioSession()
        session.failActivation = true
        let owner = HistoryPlaybackAudioSessionOwner(session: session)

        do {
            try owner.playbackDidStart()
            Issue.record("Expected playback audio-session activation to fail")
        } catch let error as HistoryPlaybackAudioSessionError {
            #expect(
                error == .activation("Fixture audio-session failure")
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(owner.playbackRequested)
        #expect(!owner.isActive)
        do {
            try owner.playbackDidStart()
            try owner.playbackDidStop()
        } catch {
            Issue.record("Failed playback must still release cleanly: \(error)")
        }
        #expect(session.events.count == 2)
    }

    @Test @MainActor
    func historyPlaybackAudioSessionRetriesFailedCooperativeRelease() throws {
        let session = RecordingHistoryPlaybackAudioSession()
        let owner = HistoryPlaybackAudioSessionOwner(session: session)

        try owner.playbackDidStart()
        session.failDeactivation = true
        do {
            try owner.playbackDidStop()
            Issue.record("Expected playback audio-session release to fail")
        } catch let error as HistoryPlaybackAudioSessionError {
            #expect(
                error == .deactivation("Fixture audio-session failure")
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!owner.playbackRequested)
        #expect(owner.isActive)

        session.failDeactivation = false
        try owner.playbackDidStop()
        #expect(!owner.isActive)
        #expect(session.events.suffix(2) == [
            .active(
                false,
                AVAudioSession.SetActiveOptions
                    .notifyOthersOnDeactivation.rawValue
            ),
            .active(
                false,
                AVAudioSession.SetActiveOptions
                    .notifyOthersOnDeactivation.rawValue
            ),
        ])
    }

    private func videoFormat(
        id: String,
        width: Int?,
        height: Int?,
        videoBitrateKbps: Double = 1_000
    ) -> MediaFormat {
        MediaFormat(
            formatID: id,
            formatNote: nil,
            extension: "mp4",
            container: "mp4_dash",
            videoCodec: "avc1.640028",
            audioCodec: nil,
            width: width,
            height: height,
            resolution: width.flatMap { width in
                height.map { "\(width)x\($0)" }
            },
            framesPerSecond: 30,
            dynamicRange: "SDR",
            isHDR: false,
            audioBitrateKbps: nil,
            videoBitrateKbps: videoBitrateKbps,
            totalBitrateKbps: videoBitrateKbps,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: true,
            hasAudio: false,
            protocolName: "https",
            sourceType: "direct_http",
            language: nil
        )
    }

    private func HLSFormat(
        fileExtension: String = "mp4",
        protocolName: String = "m3u8_native",
        sourceType: String = "hls",
        hasVideo: Bool = true,
        hasAudio: Bool = true
    ) -> MediaFormat {
        MediaFormat(
            formatID: "hls-analyzed",
            formatNote: "360p",
            extension: fileExtension,
            container: "mp4",
            videoCodec: hasVideo ? "avc1.42001E" : nil,
            audioCodec: hasAudio ? "mp4a.40.2" : nil,
            width: hasVideo ? 640 : nil,
            height: hasVideo ? 360 : nil,
            resolution: hasVideo ? "640x360" : "audio only",
            framesPerSecond: hasVideo ? 30 : nil,
            dynamicRange: hasVideo ? "SDR" : nil,
            isHDR: false,
            audioBitrateKbps: hasAudio ? 128 : nil,
            videoBitrateKbps: hasVideo ? 500 : nil,
            totalBitrateKbps: 628,
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            protocolName: protocolName,
            sourceType: sourceType,
            language: nil
        )
    }

    private func testFormat(
        id: String,
        hasVideo: Bool,
        hasAudio: Bool,
        height: Int? = nil,
        videoBitrateKbps: Double? = nil,
        audioBitrateKbps: Double? = nil
    ) -> MediaFormat {
        MediaFormat(
            formatID: id,
            formatNote: height.map { "\($0)p" },
            extension: hasVideo ? "mp4" : "m4a",
            container: hasVideo ? "mp4" : "m4a_dash",
            videoCodec: hasVideo ? "avc1.640028" : nil,
            audioCodec: hasAudio ? "mp4a.40.2" : nil,
            width: height.map { $0 * 16 / 9 },
            height: height,
            resolution: height.map { "\($0 * 16 / 9)x\($0)" },
            framesPerSecond: hasVideo ? 30 : nil,
            dynamicRange: hasVideo ? "SDR" : nil,
            isHDR: false,
            audioBitrateKbps: audioBitrateKbps,
            videoBitrateKbps: videoBitrateKbps,
            totalBitrateKbps: (videoBitrateKbps ?? 0)
                + (audioBitrateKbps ?? 0),
            exactFileSizeBytes: nil,
            approximateFileSizeBytes: nil,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            protocolName: "https",
            sourceType: "direct_http",
            language: nil
        )
    }

    private func mediaMetadata(formats: [MediaFormat]) -> MediaMetadata {
        let base = DeveloperFixtures.media
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
            chapters: base.chapters,
            subtitles: base.subtitles,
            formats: formats
        )
    }

    private var fixtureJob: DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.RickURL,
            videoID: DeveloperFixtures.media.videoID,
            title: DeveloperFixtures.media.title,
            channel: DeveloperFixtures.media.channel,
            thumbnailURL: DeveloperFixtures.media.thumbnails.first?.url,
            createdAt: .now,
            updatedAt: .now,
            configuration: .standard,
            state: .queued,
            stage: .waiting,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: ["137", "140"],
            extractorVersion: "fixture"
        )
    }

    @MainActor
    private func waitForSponsorBlockPreview(
        _ model: IllucetAppModel
    ) async throws {
        for _ in 0 ..< 1_000 {
            switch model.sponsorBlockPreviewState {
            case .loaded, .empty, .failed:
                return
            case .idle, .loading:
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        Issue.record("SponsorBlock preview did not finish.")
    }
}

@MainActor
private final class RecordingHistoryPlaybackAudioSession:
    HistoryPlaybackAudioSessionControlling
{
    enum Event: Equatable {
        case category(String, String, UInt)
        case active(Bool, UInt)
    }

    var failActivation = false
    var failDeactivation = false
    private(set) var events: [Event] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        events.append(.category(
            category.rawValue,
            mode.rawValue,
            options.rawValue
        ))
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        events.append(.active(active, options.rawValue))
        if active ? failActivation : failDeactivation {
            throw RecordingHistoryPlaybackAudioSessionError.failure
        }
    }
}

private enum RecordingHistoryPlaybackAudioSessionError: LocalizedError {
    case failure

    var errorDescription: String? {
        "Fixture audio-session failure"
    }
}
