import Foundation
import Testing
@testable import Illucet

struct OutputCorrectnessTests {
    @Test
    func analyzedSourceAvailabilityAcceptsCombinedAndSeparateStreams() {
        let combined = SourceModeAvailability(
            analyzedMetadata: DeveloperFixtures.metadata(
                formats: DeveloperFixtures.media.formats.filter {
                    $0.formatID == "18"
                }
            )
        )
        let separate = SourceModeAvailability(
            analyzedMetadata: DeveloperFixtures.metadata(
                formats: DeveloperFixtures.media.formats.filter {
                    ["137", "140"].contains($0.formatID)
                }
            )
        )

        for availability in [combined, separate] {
            #expect(availability.status(for: .videoAndAudio) == .available)
            #expect(availability.status(for: .audioOnly) == .available)
            #expect(availability.status(for: .videoOnly) == .available)
        }
    }

    @Test
    func analyzedSourceAvailabilityExplainsMissingRequiredStreams() {
        let videoOnly = SourceModeAvailability(
            analyzedMetadata: DeveloperFixtures.videoOnlyMedia
        )
        #expect(videoOnly.status(for: .videoOnly) == .available)
        #expect(!videoOnly.status(for: .audioOnly).permitsSelection)
        #expect(
            videoOnly.status(for: .videoAndAudio).unavailableReason?
                .contains("no usable audio stream") == true
        )

        let audioOnly = SourceModeAvailability(
            analyzedMetadata: DeveloperFixtures.audioOnlyMedia
        )
        #expect(audioOnly.status(for: .audioOnly) == .available)
        #expect(!audioOnly.status(for: .videoOnly).permitsSelection)
        #expect(
            audioOnly.status(for: .videoAndAudio).unavailableReason?
                .contains("no usable video stream") == true
        )

        let noStreams = SourceModeAvailability(
            analyzedMetadata: DeveloperFixtures.metadata(formats: [])
        )
        for mode in DownloadMode.allCases {
            #expect(!noStreams.status(for: mode).permitsSelection)
            #expect(noStreams.status(for: mode).unavailableReason != nil)
        }
    }

    @Test
    func absentAnalysisRemainsUnverifiedInsteadOfClaimingNoStreams() {
        let availability = SourceModeAvailability(analyzedMetadata: nil)

        for mode in DownloadMode.allCases {
            #expect(availability.status(for: mode) == .unverified)
            #expect(availability.status(for: mode).permitsSelection)
            #expect(availability.status(for: mode).unavailableReason == nil)
        }
    }

    @Test
    func effectiveOutputIdentityUsesTheFullRequestAndStableVocabulary() {
        var configuration = DownloadConfiguration.standard
        for mode in DownloadMode.allCases {
            configuration.mode = mode
            #expect(
                configuration.effectiveOutputIdentity
                    == mode.effectiveOutputIdentity
            )
            #expect(
                configuration.effectiveOutputIdentity.systemImage
                    == mode.systemImage
            )
        }

        configuration.mode = .videoAndAudio
        configuration.thumbnailBehavior = .thumbnailOnly
        #expect(configuration.effectiveOutputIdentity == .thumbnailOnly)
        #expect(
            EffectiveOutputIdentity.thumbnailOnly.rawValue
                == "Thumbnail Only"
        )
        #expect(
            EffectiveOutputIdentity.subtitlesOnly.rawValue
                == "Subtitles Only"
        )
        #expect(
            EffectiveOutputIdentity.subtitlesOnly.systemImage
                == "captions.bubble"
        )
        #expect(
            EffectiveOutputIdentity.implementedRequestCases.contains(
                .subtitlesOnly
            )
        )
    }

    @Test
    func effectiveOutputTransitionsCanonicalizeSpecialAndOrdinaryRequests()
        throws
    {
        var contradictory = DownloadConfiguration.standard
        contradictory.requestKind = .subtitlesOnly
        contradictory.thumbnailBehavior = .thumbnailOnly
        contradictory.selectedVideoFormatID = "137"
        contradictory.selectedAudioFormatID = "140"

        let restoredData = try JSONEncoder().encode(contradictory)
        let restored = try JSONDecoder().decode(
            DownloadConfiguration.self,
            from: restoredData
        )
        let normalizedRestore = OutputCapabilityMatrix.normalized(restored)
        #expect(normalizedRestore.effectiveOutputIdentity == .subtitlesOnly)
        #expect(normalizedRestore.requestKind == .subtitlesOnly)
        #expect(normalizedRestore.thumbnailBehavior == .none)
        #expect(normalizedRestore.selectedFormatIDs.isEmpty)

        let thumbnailOnly =
            OutputCapabilityMatrix.selectingThumbnailBehavior(
                .thumbnailOnly,
                in: normalizedRestore
            )
        #expect(thumbnailOnly.effectiveOutputIdentity == .thumbnailOnly)
        #expect(thumbnailOnly.requestKind == nil)
        #expect(thumbnailOnly.thumbnailBehavior == .thumbnailOnly)
        #expect(thumbnailOnly.selectedFormatIDs.isEmpty)

        let audioOnly = OutputCapabilityMatrix.selectingMode(
            .audioOnly,
            in: thumbnailOnly
        )
        #expect(audioOnly.effectiveOutputIdentity == .audioOnly)
        #expect(audioOnly.requestKind == nil)
        #expect(audioOnly.thumbnailBehavior != .thumbnailOnly)

        let subtitlesOnly = OutputCapabilityMatrix.selectingSubtitlesOnly(
            in: audioOnly
        )
        #expect(subtitlesOnly.effectiveOutputIdentity == .subtitlesOnly)
        #expect(subtitlesOnly.thumbnailBehavior == .none)

        let ordinaryThumbnail =
            OutputCapabilityMatrix.selectingThumbnailBehavior(
                .separate,
                in: subtitlesOnly
            )
        #expect(ordinaryThumbnail.effectiveOutputIdentity == .audioOnly)
        #expect(ordinaryThumbnail.requestKind == nil)
        #expect(ordinaryThumbnail.thumbnailBehavior == .separate)

        let queued = fixtureJob(
            state: .queued,
            configuration: ordinaryThumbnail
        )
        #expect(queued.effectiveOutputIdentity == .audioOnly)
        #expect(HistoryRecord(job: queued).effectiveOutputIdentity == .audioOnly)
    }

    @Test
    func onlyTransferAndRestorationStagesPresentTransferMetrics() {
        let expected: Set<DownloadStage> = [
            .downloadingVideo,
            .downloadingAudio,
            .downloadingThumbnail,
            .downloadingSubtitles,
            .restoring,
        ]

        #expect(
            Set(DownloadStage.allCases.filter(\.presentsTransferMetrics))
                == expected
        )
        #expect(!DownloadStage.verifyingSources.presentsTransferMetrics)
        #expect(!DownloadStage.merging.presentsTransferMetrics)
        #expect(!DownloadStage.converting.presentsTransferMetrics)
        #expect(!DownloadStage.savingFiles.presentsTransferMetrics)
        #expect(!DownloadStage.savingPhotos.presentsTransferMetrics)
        #expect(!DownloadStage.cleaningUp.presentsTransferMetrics)
    }

    @Test
    func terminalThumbnailOnlyJobsAndHistoryKeepTheirRequestedIdentity() {
        var configuration = DownloadConfiguration.standard
        configuration.mode = .videoAndAudio
        configuration.thumbnailBehavior = .thumbnailOnly
        let jobs = [
            fixtureJob(state: .failed, configuration: configuration),
            fixtureJob(state: .cancelled, configuration: configuration),
        ]
        let records = jobs.map(HistoryRecord.init(job:))

        #expect(jobs.allSatisfy {
            $0.effectiveOutputIdentity == .thumbnailOnly
        })
        #expect(records.allSatisfy { $0.mode == .videoAndAudio })
        #expect(records.allSatisfy {
            $0.effectiveOutputIdentity == .thumbnailOnly
        })
        #expect(records.filter {
            $0.effectiveOutputIdentity == .thumbnailOnly
        }.count == 2)
        #expect(records.filter {
            $0.effectiveOutputIdentity == .videoAndAudio
        }.isEmpty)
    }

    @Test
    func capabilityMatrixExposesOnlyImplementedChoices() {
        #expect(
            OutputCapabilityMatrix.enabledAudioCodecs(for: .audioOnly)
                == [
                    .automatic,
                    .original,
                    .aac,
                    .mp3,
                    .flac,
                    .alac,
                    .opus,
                    .vorbis,
                    .wav,
                ]
        )
        #expect(
            OutputCapabilityMatrix.enabledAudioCodecs(for: .videoAndAudio)
                == OutputCapabilityMatrix.enabledAudioCodecs(
                    for: .audioOnly
                )
        )
        #expect(
            OutputCapabilityMatrix.enabledVideoCodecs(for: .videoOnly)
                == [.automatic, .h264, .hevc]
        )
        #expect(
            OutputCapabilityMatrix.enabledContainers(
                for: .videoAndAudio,
                audioCodec: .automatic
            ) == [.automatic]
        )
        #expect(
            OutputCapabilityMatrix.enabledSubtitleDeliveries == [
                .none,
                .sidecarVTT,
                .sidecarSRT,
                .embed,
                .burnIn,
            ]
        )
        #expect(
            OutputCapabilityMatrix.enabledBundleStyles
                == [.mediaOnly, .mediaAndThumbnail, .packageFolder, .zip]
        )
        #expect(
            OutputCapabilityMatrix.enabledFrameRates
                == [.preserve, .fps24, .fps30, .fps60]
        )
        #expect(
            OutputCapabilityMatrix.enabledSampleRates
                == [.preserve, .hz44100, .hz48000]
        )
        #expect(
            OutputCapabilityMatrix.enabledChannelChoices
                == [.preserve, .mono, .stereo]
        )
    }

    @Test
    func unsupportedPersistedConfigurationNormalizesClosed() {
        var value = DownloadConfiguration.standard
        value.mode = .audioOnly
        value.audioCodec = .flac
        value.container = .mkv
        value.frameRate = .fps60
        value.sampleRate = .hz44100
        value.channels = .mono
        value.loudnessNormalization = true
        value.thumbnailBehavior = .embed
        value.subtitleDelivery = .burnIn
        value.splitChapters = true
        value.bundleStyle = .zip
        value.playlistBehavior = .entirePlaylist
        value.trimStartSeconds = 2

        let normalized = OutputCapabilityMatrix.normalized(value)

        #expect(normalized.audioCodec == .flac)
        #expect(normalized.container == .mkv)
        #expect(normalized.frameRate == .preserve)
        #expect(normalized.sampleRate == .hz44100)
        #expect(normalized.channels == .mono)
        #expect(normalized.loudnessNormalization)
        #expect(normalized.audioBitrateKbps == nil)
        #expect(normalized.audioRateControl == nil)
        #expect(normalized.thumbnailBehavior == .separate)
        #expect(normalized.subtitleDelivery == .none)
        #expect(!normalized.splitChapters)
        #expect(normalized.bundleStyle == .zip)
        #expect(normalized.playlistBehavior == .referencedVideo)
        #expect(normalized.trimStartSeconds == nil)
    }

    @Test
    func autoCombinedPlanUsesRealMP4ForH264AndAAC() throws {
        var value = compatibleConfiguration()
        value.selectedVideoFormatID = "137"
        value.selectedAudioFormatID = "140"

        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )

        #expect(plan.container == .mp4)
        #expect(plan.fileExtension == "mp4")
        #expect(plan.strategy == .mergeStreamCopy)
        #expect(plan.expectedVideoCodec == .h264)
        #expect(plan.expectedAudioCodec == .aac)
        #expect(!plan.needsConversion)
    }

    @Test
    func autoOriginalOpusAudioKeepsWebMExtension() throws {
        var value = baseConfiguration(mode: .audioOnly)
        value.audioCodec = .original
        value.selectedAudioFormatID = "251"

        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )

        #expect(plan.container == .webM)
        #expect(plan.fileExtension == "webm")
        #expect(plan.strategy == .extractOriginalAudio)
        #expect(plan.expectedAudioCodec == .opus)
    }

    @Test
    func MP3PlanRequiresActualMP3AndRequestedBitrate() throws {
        var value = baseConfiguration(mode: .audioOnly)
        value.audioCodec = .mp3
        value.container = .mp3
        value.audioBitrateKbps = 320
        value.selectedAudioFormatID = "140"
        value.thumbnailBehavior = .embed
        value = OutputCapabilityMatrix.normalized(value)

        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )

        #expect(plan.container == .mp3)
        #expect(plan.fileExtension == "mp3")
        #expect(plan.strategy == .transcodeAudio)
        #expect(plan.expectedAudioCodec == .mp3)
        #expect(plan.expectedAudioBitRate == 320_000)
        #expect(plan.requireArtwork)
    }

    @Test
    func videoOnlyStreamCopyKeepsCodecAndRequiresZeroAudio() throws {
        var value = baseConfiguration(mode: .videoOnly)
        value.selectedVideoFormatID = "137"

        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )

        #expect(plan.strategy == .copyVideoOnly)
        #expect(plan.expectedVideoCodec == .h264)
        #expect(plan.expectedAudioStreams == 0 ... 0)
        #expect(plan.fileExtension == "mp4")
    }

    @Test
    func H264ConversionPlanDoesNotPretendToPreserveAV1() throws {
        var value = compatibleConfiguration()
        value.selectedVideoFormatID = "401"
        value.selectedAudioFormatID = "140"

        let plan = try OutputCapabilityMatrix.makePlan(
            configuration: value,
            metadata: DeveloperFixtures.media
        )

        #expect(plan.strategy == .assembleConvertedStreams)
        #expect(plan.sourceVideoCodec == .av1)
        #expect(plan.expectedVideoCodec == .h264)
        #expect(plan.expectedAudioCodec == .aac)
    }

    @Test
    func incompatibleExplicitMP4SelectionFailsBeforeDownload() {
        var value = baseConfiguration(mode: .videoAndAudio)
        value.container = .mp4
        value.selectedVideoFormatID = "401"
        value.selectedAudioFormatID = "251"

        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.makePlan(
                configuration: value,
                metadata: DeveloperFixtures.media
            )
        }
    }

    @Test
    func verifierChecksContainerExtensionAndRequestedProperties() throws {
        let probe = validProbe(fileExtension: "mp4")
        try MediaOutputVerifier.verify(
            probe,
            requirements: verificationRequirements()
        )

        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(container: .webM)
            )
        }
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(
                    fileExtension: "mkv"
                )
            )
        }
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(frameRate: 60)
            )
        }
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(sampleRate: 44_100)
            )
        }
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(channelCount: 1)
            )
        }
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                probe,
                requirements: verificationRequirements(chapters: 1 ... 1)
            )
        }
        let structuralProbe = validProbe(
            fileExtension: "mp4",
            verificationClass: .fastStructural
        )
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                structuralProbe,
                requirements: verificationRequirements()
            )
        }
        let boundedProbe = validProbe(
            fileExtension: "mp4",
            verificationClass: .boundedStrong
        )
        try MediaOutputVerifier.verify(
            boundedProbe,
            requirements: verificationRequirements(
                requiredVerificationClass: .boundedStrong
            )
        )
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(
                boundedProbe,
                requirements: verificationRequirements()
            )
        }
    }

    @Test
    func compatibleVideoAndAudioVerificationRejectsMissingAudio() {
        let valid = validProbe(fileExtension: "mp4")
        let videoOnlyProbe = MediaProbeResult(
            fileURL: valid.fileURL,
            formatNames: valid.formatNames,
            formatLongName: valid.formatLongName,
            durationSeconds: valid.durationSeconds,
            startTimeSeconds: valid.startTimeSeconds,
            bitRate: valid.bitRate,
            fileSize: valid.fileSize,
            metadata: valid.metadata,
            streams: valid.streams.filter { $0.kind != .audio },
            chapters: valid.chapters,
            verificationEvidence: valid.verificationEvidence
        )

        do {
            try MediaOutputVerifier.verify(
                videoOnlyProbe,
                requirements: verificationRequirements()
            )
            Issue.record(
                "Compatible Video + Audio verification accepted an output without an audio stream."
            )
        } catch let error as MediaProcessorError {
            #expect(
                error == .verificationMismatch(
                    "Expected 1...1 audio streams; found 0."
                )
            )
        } catch {
            Issue.record("Unexpected verification error: \(error)")
        }
    }

    @Test
    func sourceProbeMustMatchExtractorContainerCodecsAndStreams() throws {
        var value = baseConfiguration(mode: .videoAndAudio)
        value.selectedVideoFormatID = "18"
        value.selectedAudioFormatID = "18"
        let probe = validProbe(fileExtension: "mp4")

        try OutputCapabilityMatrix.validateSourceProbes(
            configuration: value,
            metadata: DeveloperFixtures.media,
            probesByFormatID: ["18": probe]
        )

        let mismatched = MediaProbeResult(
            fileURL: probe.fileURL,
            formatNames: ["matroska", "webm"],
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
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.validateSourceProbes(
                configuration: value,
                metadata: DeveloperFixtures.media,
                probesByFormatID: ["18": mismatched]
            )
        }
    }

    @Test(arguments: ["m3u8", "m3u8_native"])
    func HLSMPEGTransportStreamsKeepExactCodecsAndFinalContainerChecks(
        protocolName: String
    ) throws {
        var configuration = baseConfiguration(mode: .videoAndAudio)
        configuration.selectedVideoFormatID = "18"
        configuration.selectedAudioFormatID = "18"
        let original = validProbe(fileExtension: "mp4")
        let transportProbe = MediaProbeResult(
            fileURL: original.fileURL,
            formatNames: ["mpegts"],
            formatLongName: "MPEG-TS",
            durationSeconds: original.durationSeconds,
            startTimeSeconds: original.startTimeSeconds,
            bitRate: original.bitRate,
            fileSize: original.fileSize,
            metadata: original.metadata,
            streams: original.streams,
            chapters: original.chapters,
            verificationEvidence: original.verificationEvidence
        )
        var encoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DeveloperFixtures.media)
        ) as? [String: Any])
        var formats = try #require(encoded["formats"] as? [[String: Any]])
        let index = try #require(formats.firstIndex { $0["format_id"] as? String == "18" })
        formats[index]["source_type"] = "hls"
        formats[index]["protocol"] = protocolName
        encoded["formats"] = formats
        func metadata() throws -> MediaMetadata {
            try JSONDecoder().decode(MediaMetadata.self, from: JSONSerialization.data(withJSONObject: encoded))
        }
        try OutputCapabilityMatrix.validateSourceProbes(
            configuration: configuration, metadata: metadata(),
            probesByFormatID: ["18": transportProbe]
        )
        // Source transport acceptance must not relax final MP4 validation.
        #expect(throws: MediaProcessorError.self) {
            try MediaOutputVerifier.verify(transportProbe, requirements: verificationRequirements())
        }
        // Direct HTTP MPEG-TS cannot masquerade as a selected MP4 file.
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.validateSourceProbes(
                configuration: configuration, metadata: DeveloperFixtures.media,
                probesByFormatID: ["18": transportProbe]
            )
        }
        formats[index]["video_codec"] = "vp9"
        encoded["formats"] = formats
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.validateSourceProbes(
                configuration: configuration, metadata: metadata(),
                probesByFormatID: ["18": transportProbe]
            )
        }
    }

    @Test(arguments: [
        "direct-mpegts", "dash-mpegts", "hls-webm-mpegts",
        "hls-non-mpegts", "hls-mixed-matroska", "hls-mixed-mp4",
        "hls-missing-video", "hls-missing-audio",
    ])
    func HLSTransportContainerExceptionRejectsUnrelatedSourcesAndProbeMismatches(
        scenario: String
    ) throws {
        var configuration = baseConfiguration(mode: .videoAndAudio)
        configuration.selectedVideoFormatID = "18"
        configuration.selectedAudioFormatID = "18"
        var encoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(DeveloperFixtures.media)
        ) as? [String: Any])
        var formats = try #require(encoded["formats"] as? [[String: Any]])
        let index = try #require(formats.firstIndex {
            $0["format_id"] as? String == "18"
        })
        formats[index]["source_type"] = "hls"
        formats[index]["protocol"] = "m3u8_native"
        var formatNames = ["mpegts"]
        let original = validProbe(fileExtension: "mp4")
        var streams = original.streams
        switch scenario {
        case "direct-mpegts":
            formats[index]["source_type"] = "direct_http"
            formats[index]["protocol"] = "https"
        case "dash-mpegts":
            formats[index]["source_type"] = "dash"
            formats[index]["protocol"] = "http_dash_segments"
        case "hls-webm-mpegts":
            formats[index]["extension"] = "webm"
            formats[index]["container"] = "webm"
        case "hls-non-mpegts":
            formatNames = ["matroska"]
        case "hls-mixed-matroska":
            formatNames = ["mpegts", "matroska"]
        case "hls-mixed-mp4":
            // The ordinary MP4 matcher must not accidentally accept this after
            // the exact MPEG-TS transport exception declines it.
            formatNames = ["mpegts", "mp4"]
        case "hls-missing-video":
            streams.removeAll { $0.kind == .video }
        case "hls-missing-audio":
            streams.removeAll { $0.kind == .audio }
        default:
            Issue.record("Unknown source-probe scenario: \(scenario)")
            return
        }
        encoded["formats"] = formats
        let metadata = try JSONDecoder().decode(
            MediaMetadata.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        let probe = MediaProbeResult(
            fileURL: original.fileURL,
            formatNames: formatNames,
            formatLongName: original.formatLongName,
            durationSeconds: original.durationSeconds,
            startTimeSeconds: original.startTimeSeconds,
            bitRate: original.bitRate,
            fileSize: original.fileSize,
            metadata: original.metadata,
            streams: streams,
            chapters: original.chapters,
            verificationEvidence: original.verificationEvidence
        )
        #expect(throws: OutputCompatibilityError.self) {
            try OutputCapabilityMatrix.validateSourceProbes(
                configuration: configuration,
                metadata: metadata,
                probesByFormatID: ["18": probe]
            )
        }
    }

    @Test
    func nativeRemuxVerifiesBeforePublishingAndCleansPartials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part1-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtures = try generateFixtures(in: root)
        let combined = root.appending(path: "combined.mp4")
        try merge(
            video: fixtures.video,
            audio: fixtures.audio,
            output: combined
        )
        let processor = NativeFFmpegMediaProcessor()
        let output = root.appending(path: "remuxed.mp4")
        let request = MediaProcessingRequest(
            operationID: UUID(),
            operation: .remux(inputURL: combined),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: .mp4,
                video: .copy,
                audio: .copy,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: verificationRequirements(
                videoCodec: MediaCodec(rawValue: "mpeg4"),
                duration: 2,
                requiredVerificationClass: .fastStructural
            )
        )

        let result = try await processor.process(request) { _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(result.usedStreamCopy)
        #expect(result.probes.first?.formatNames.contains("mp4") == true)
        #expect(result.probes.first?.videoStreamCount == 1)
        #expect(result.probes.first?.audioStreamCount == 1)
        #expect(
            result.probes.first?.verificationEvidence?.verificationClass
                == .fastStructural
        )
        #expect(
            result.probes.first?.verificationEvidence?.fullDecodePerformed
                == false
        )
        #expect(try partialFiles(in: root).isEmpty)

        let rejected = root.appending(path: "rejected.mp4")
        let wrong = MediaProcessingRequest(
            operationID: UUID(),
            operation: .remux(inputURL: combined),
            destinationURL: rejected,
            output: request.output,
            metadata: request.metadata,
            chapters: request.chapters,
            trimming: request.trimming,
            overwriteExisting: false,
            verification: verificationRequirements(
                container: .webM,
                videoCodec: MediaCodec(rawValue: "mpeg4"),
                requiredVerificationClass: .fastStructural
            )
        )
        do {
            _ = try await processor.process(wrong) { _ in }
            Issue.record("A container mismatch was incorrectly published.")
        } catch is MediaProcessorError {
            #expect(!FileManager.default.fileExists(atPath: rejected.path))
            #expect(try partialFiles(in: root).isEmpty)
        }
    }

    @Test
    func nativeEnabledOutputMatrixProducesVerifiedPlayableFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part1-Matrix-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()

        let merged = root.appending(path: "combined.mp4")
        let mergeResult = try await processor.process(
            processingRequest(
                operation: .merge(
                    videoURL: fixtures.video,
                    audioURL: fixtures.audio
                ),
                destination: merged,
                container: .mp4,
                video: .copy,
                audio: .copy,
                verification: verificationRequirements(
                    videoCodec: MediaCodec(rawValue: "mpeg4"),
                    audioBitRate: nil
                )
            )
        ) { _ in }
        #expect(mergeResult.usedStreamCopy)

        let originalAudio = root.appending(path: "original-audio.m4a")
        let audioResult = try await processor.process(
            processingRequest(
                operation: .extractAudio(inputURL: fixtures.incompatible),
                destination: originalAudio,
                container: .m4a,
                video: .remove,
                audio: .copy,
                verification: verificationRequirements(
                    container: .m4a,
                    fileExtension: "m4a",
                    videoStreams: 0 ... 0,
                    videoCodec: nil,
                    dimensions: nil,
                    frameRate: nil,
                    audioBitRate: nil
                )
            )
        ) { _ in }
        #expect(audioResult.usedStreamCopy)

        let mp3 = root.appending(path: "audio-128k.mp3")
        let mp3Settings = AudioEncodingSettings(
            codec: .mp3,
            bitRate: 128_000,
            sampleRate: nil,
            channelLayout: .preserve,
            loudnessNormalization: nil
        )
        let mp3Result = try await processor.process(
            processingRequest(
                operation: .transcodeAudio(inputURL: fixtures.audio),
                destination: mp3,
                container: .mp3,
                video: .remove,
                audio: .encode(mp3Settings),
                verification: verificationRequirements(
                    container: .mp3,
                    fileExtension: "mp3",
                    videoStreams: 0 ... 0,
                    videoCodec: nil,
                    audioCodec: .mp3,
                    dimensions: nil,
                    frameRate: nil
                )
            )
        ) { _ in }
        #expect(!mp3Result.usedStreamCopy)

        let videoOnly = root.appending(path: "video-only.mp4")
        let videoOnlyResult = try await processor.process(
            processingRequest(
                operation: .removeAudio(inputURL: fixtures.video),
                destination: videoOnly,
                container: .mp4,
                video: .copy,
                audio: .remove,
                verification: verificationRequirements(
                    audioStreams: 0 ... 0,
                    videoCodec: MediaCodec(rawValue: "mpeg4"),
                    audioCodec: nil,
                    sampleRate: nil,
                    channelCount: nil,
                    audioBitRate: nil
                )
            )
        ) { _ in }
        #expect(videoOnlyResult.usedStreamCopy)

        let compatible = root.appending(path: "compatible-h264.mp4")
        let compatibleResult = try await processor.process(
            processingRequest(
                operation: .transcodeVideo(inputURL: fixtures.incompatible),
                destination: compatible,
                container: .mp4,
                video: .encode(
                    VideoEncodingSettings(
                        codec: .h264,
                        bitRate: nil,
                        dimensions: MediaDimensions(width: 320, height: 180),
                        frameRate: 30,
                        pixelFormat: "nv12",
                        profile: nil,
                        level: nil,
                        acceleration: .preferVideoToolbox
                    )
                ),
                audio: .copy,
                verification: verificationRequirements(
                    videoCodec: .h264,
                    audioBitRate: nil
                )
            )
        ) { _ in }
        #expect(!compatibleResult.usedStreamCopy)

        let artwork = root.appending(path: "audio-artwork.mp3")
        let artworkResult = try await processor.process(
            processingRequest(
                operation: .attachArtwork(
                    mediaURL: mp3,
                    artworkURL: fixtures.artwork
                ),
                destination: artwork,
                container: .mp3,
                video: .copy,
                audio: .copy,
                verification: verificationRequirements(
                    container: .mp3,
                    fileExtension: "mp3",
                    videoStreams: 0 ... 0,
                    videoCodec: nil,
                    audioCodec: .mp3,
                    dimensions: nil,
                    frameRate: nil,
                    requireArtwork: true
                )
            )
        ) { _ in }
        #expect(!artworkResult.usedStreamCopy)

        let outputs = [
            merged,
            originalAudio,
            mp3,
            videoOnly,
            compatible,
            artwork,
        ]
        let decoded = try await ApplePlaybackVerifier(requiresPlayerPlayback: false).verify(fileURL: merged)
        #expect(decoded.decodedSamples.count == 2)
        #expect(!decoded.playerItemBecameReady)
        #expect(decoded.playbackAdvanceSeconds == 0)
        let playbackVerifier = ApplePlaybackVerifier()
        for output in outputs {
            let evidence = try await playbackVerifier.verify(fileURL: output)
            #expect(evidence.playbackAdvanceSeconds >= 0.2)
        }

        #expect(outputs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(try partialFiles(in: root).isEmpty)
    }

    private func baseConfiguration(
        mode: DownloadMode
    ) -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = mode
        value.preset = .custom
        value.selectedVideoFormatID = nil
        value.selectedAudioFormatID = nil
        value.videoCodec = .automatic
        value.audioCodec = mode == .audioOnly ? .original : .automatic
        value.container = .automatic
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.preserveChapters = false
        value.writeChapters = false
        value.bundleStyle = .mediaOnly
        return OutputCapabilityMatrix.normalized(value)
    }

    private func fixtureJob(
        state: DownloadJobState,
        configuration: DownloadConfiguration
    ) -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.RickURL,
            videoID: DeveloperFixtures.media.videoID,
            title: "Output truth fixture",
            channel: DeveloperFixtures.media.channel,
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: state,
            stage: .downloadingThumbnail,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: state == .failed ? "fixture_failure" : nil,
            errorMessage: state == .failed ? "Fixture failure." : nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
    }

    private func compatibleConfiguration() -> DownloadConfiguration {
        var value = baseConfiguration(mode: .videoAndAudio)
        value.preset = .compatible
        value.videoCodec = .h264
        value.container = .mp4
        return value
    }

    private func validProbe(
        fileExtension: String,
        verificationClass: MediaVerificationClass = .strongFullDecode
    ) -> MediaProbeResult {
        MediaProbeResult(
            fileURL: URL(filePath: "/tmp/output.\(fileExtension)"),
            formatNames: ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"],
            formatLongName: "QuickTime / MOV",
            durationSeconds: 2,
            startTimeSeconds: 0,
            bitRate: 1_400_000,
            fileSize: 350_000,
            metadata: ["title": "Fixture"],
            streams: [
                MediaStreamProbe(
                    index: 0,
                    kind: .video,
                    codecName: "h264",
                    codecLongName: "H.264",
                    codecProfile: nil,
                    codecTag: nil,
                    durationSeconds: 2,
                    bitRate: 1_200_000,
                    timeBase: nil,
                    disposition: MediaStreamDisposition(
                        isDefault: true,
                        forced: false,
                        attachedPicture: false
                    ),
                    metadata: [:],
                    video: VideoStreamProbe(
                        width: 320,
                        height: 180,
                        pixelFormat: "yuv420p",
                        averageFrameRate: MediaRational(
                            numerator: 30,
                            denominator: 1
                        ),
                        realFrameRate: nil,
                        colorSpace: nil,
                        colorTransfer: nil,
                        colorPrimaries: nil,
                        colorRange: nil,
                        fieldOrder: nil,
                        isHDR: false
                    ),
                    audio: nil,
                    subtitle: nil,
                    decodedFrames: verificationClass == .fastStructural
                        ? 0
                        : 3,
                    decodedSampleWindows:
                        verificationClass == .boundedStrong ? 3 : 0
                ),
                MediaStreamProbe(
                    index: 1,
                    kind: .audio,
                    codecName: "aac",
                    codecLongName: "AAC",
                    codecProfile: nil,
                    codecTag: nil,
                    durationSeconds: 2,
                    bitRate: 128_000,
                    timeBase: nil,
                    disposition: MediaStreamDisposition(
                        isDefault: true,
                        forced: false,
                        attachedPicture: false
                    ),
                    metadata: [:],
                    video: nil,
                    audio: AudioStreamProbe(
                        sampleFormat: "fltp",
                        sampleRate: 48_000,
                        channelCount: 2,
                        channelLayout: "stereo",
                        bitsPerSample: nil
                    ),
                    subtitle: nil,
                    decodedFrames: verificationClass == .fastStructural
                        ? 0
                        : 3,
                    decodedSampleWindows:
                        verificationClass == .boundedStrong ? 3 : 0
                ),
            ],
            chapters: [],
            verificationEvidence: MediaProbeEvidence(
                verificationClass: verificationClass,
                fullDecodePerformed:
                    verificationClass == .strongFullDecode,
                packetsInspected: 64,
                inspectedPacketBytes: 128 * 1_024,
                tailInspectionAttempted:
                    verificationClass != .strongFullDecode,
                tailInspectionSucceeded:
                    verificationClass != .strongFullDecode,
                tailInspectionReachedEOF:
                    verificationClass != .strongFullDecode
            )
        )
    }

    private func verificationRequirements(
        container: MediaContainer = .mp4,
        fileExtension: String = "mp4",
        videoStreams: ClosedRange<Int> = 1 ... 1,
        audioStreams: ClosedRange<Int> = 1 ... 1,
        videoCodec: MediaCodec? = .h264,
        audioCodec: MediaCodec? = .aac,
        dimensions: MediaDimensions? = MediaDimensions(
            width: 320,
            height: 180
        ),
        frameRate: Double? = 30,
        sampleRate: Int? = 48_000,
        channelCount: Int? = 2,
        audioBitRate: Int64? = 128_000,
        chapters: ClosedRange<Int> = 0 ... 0,
        duration: Double = 2,
        requireArtwork: Bool = false,
        requiredVerificationClass: MediaVerificationClass =
            .strongFullDecode
    ) -> MediaVerificationRequirements {
        MediaVerificationRequirements(
            expectedContainer: container,
            expectedFileExtension: fileExtension,
            expectedVideoStreams: videoStreams,
            expectedAudioStreams: audioStreams,
            expectedSubtitleStreams: 0 ... 0,
            expectedVideoCodec: videoCodec,
            expectedAudioCodec: audioCodec,
            expectedDimensions: dimensions,
            expectedFrameRate: frameRate,
            frameRateTolerance: 0.05,
            expectedHDR: nil,
            expectedAudioSampleRate: sampleRate,
            expectedAudioChannelCount: channelCount,
            expectedDurationSeconds: duration,
            durationToleranceSeconds: 0.1,
            expectedAudioBitRate: audioBitRate,
            audioBitRateToleranceFraction: 0.15,
            expectedChapterCount: chapters,
            requireArtwork: requireArtwork,
            requireMetadataKeys: [],
            expectedMetadataValues: [:],
            forbiddenMetadataKeys: [],
            requiredVerificationClass: requiredVerificationClass
        )
    }

    private func processingRequest(
        operation: MediaProcessingOperation,
        destination: URL,
        container: MediaContainer,
        video: VideoOutputPolicy,
        audio: AudioOutputPolicy,
        verification: MediaVerificationRequirements
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: operation,
            destinationURL: destination,
            output: MediaOutputSpecification(
                container: container,
                video: video,
                audio: audio,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: true,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: verification
        )
    }

    private func generateFixtures(
        in root: URL
    ) throws -> (
        video: URL,
        audio: URL,
        incompatible: URL,
        artwork: URL
    ) {
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "incompatible.mkv")
        let artwork = root.appending(path: "artwork.jpg")
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

    private func merge(
        video: URL,
        audio: URL,
        output: URL
    ) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                output.path.withCString { outputPath in
                    illucet_ffmpeg_merge_stream_copy(
                        videoPath,
                        audioPath,
                        outputPath,
                        nil,
                        &rawError
                    )
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "Fixture merge failed."
            )
        }
    }

    private func partialFiles(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.contains("illucet-partial")
        }
    }
}
