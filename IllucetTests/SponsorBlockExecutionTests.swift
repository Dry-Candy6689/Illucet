import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Illucet

@Suite("SponsorBlock execution")
struct SponsorBlockExecutionTests {
    @Test
    func creatorChaptersValidateBeforeMappingToMeasuredMediaDuration() throws {
        let timeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: 11.72,
            manualTrim: nil,
            requestedRemovals: [MediaTimeRange(startSeconds: 4, endSeconds: 6)]
        )
        let chapters = [
            ExtractedChapter(title: "Opening", startTimeSeconds: 0, endTimeSeconds: 4),
            ExtractedChapter(title: "Main", startTimeSeconds: 4, endTimeSeconds: 12),
        ]
        let plan = SponsorBlockPlan(videoID: "fixture", entries: [])
        let result = try SponsorBlockChapterMerger.merge(
            creatorChapters: chapters,
            includeCreatorChapters: true,
            creatorDurationSeconds: 12,
            plan: plan,
            timeline: timeline
        )
        #expect(result.chapters == [
            MediaChapter(title: "Opening", startSeconds: 0, endSeconds: 4),
            MediaChapter(title: "Main", startSeconds: 4, endSeconds: 9.72),
        ])
        #expect(throws: ChapterWorkflowError.invalidChapterData) {
            try SponsorBlockChapterMerger.merge(
                creatorChapters: chapters,
                includeCreatorChapters: true,
                creatorDurationSeconds: 10,
                plan: plan,
                timeline: timeline
            )
        }
        #expect(!ChapterWorkflowError.invalidChapterData.localizedDescription.contains("error 0"))
        #expect(ChapterWorkflowError.verificationFailed.localizedDescription.contains("not exported"))
    }

    @Test
    func timelineComposesTrimRemovalsAndMapsSourceTimeDeterministically()
        throws
    {
        let timeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: 20,
            manualTrim: MediaTrimRange(
                startSeconds: 2,
                endSeconds: 18
            ),
            requestedRemovals: [
                MediaTimeRange(startSeconds: 0, endSeconds: 3),
                MediaTimeRange(startSeconds: 5, endSeconds: 7),
                MediaTimeRange(startSeconds: 6, endSeconds: 9),
                MediaTimeRange(startSeconds: 17, endSeconds: 20),
            ]
        )

        #expect(
            timeline.keptSourceRanges == [
                MediaTimeRange(startSeconds: 3, endSeconds: 5),
                MediaTimeRange(startSeconds: 9, endSeconds: 17),
            ]
        )
        #expect(timeline.finalDurationSeconds == 10)
        #expect(timeline.finalTime(forSourceTime: 3) == 0)
        #expect(timeline.finalTime(forSourceTime: 10) == 3)
        #expect(timeline.finalTime(forSourceTime: 6) == nil)
        #expect(
            timeline.transformed(
                MediaTimeRange(startSeconds: 4, endSeconds: 12)
            ) == MediaTimeRange(startSeconds: 1, endSeconds: 5)
        )

        #expect(throws: SponsorBlockExecutionError.removesAllContent) {
            try SponsorBlockTimeline.compose(
                sourceDurationSeconds: 5,
                manualTrim: nil,
                requestedRemovals: [
                    MediaTimeRange(startSeconds: 0, endSeconds: 5),
                ]
            )
        }
    }

    @Test
    func trailingRemovalReconcilesBoundedProbeDurationDrift() throws {
        let sourceDuration = 563.36254
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "middle",
                    start: 416.566,
                    end: 426.568,
                    action: .remove
                ),
                planEntry(
                    id: "trailing",
                    start: 524.6,
                    end: 563,
                    action: .remove
                ),
            ]
        )
        let removals = SponsorBlockExecutionWorkflow.requestedRemovalRanges(
            sponsorPlan: plan,
            sourceDurationSeconds: sourceDuration
        )
        #expect(removals.last?.endSeconds == sourceDuration)
        let timeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: sourceDuration,
            manualTrim: nil,
            requestedRemovals: removals
        )
        #expect(
            timeline.keptSourceRanges == [
                MediaTimeRange(startSeconds: 0, endSeconds: 416.566),
                MediaTimeRange(startSeconds: 426.568, endSeconds: 524.6),
            ]
        )

        let outsideBound = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "not-trailing",
                    start: 524.6,
                    end: 562.8,
                    action: .remove
                ),
            ]
        )
        #expect(
            SponsorBlockExecutionWorkflow.requestedRemovalRanges(
                sponsorPlan: outsideBound,
                sourceDurationSeconds: sourceDuration
            ).first?.endSeconds == 562.8
        )
    }

    @Test
    func chapterMergeUsesFinalTimelineAndResolvesCreatorCollisions() throws {
        let timeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: 12,
            manualTrim: MediaTrimRange(startSeconds: 1, endSeconds: 11),
            requestedRemovals: [
                MediaTimeRange(startSeconds: 4, endSeconds: 6),
            ]
        )
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "sponsor",
                    category: .sponsor,
                    start: 2,
                    end: 5,
                    action: .markAsChapter
                ),
                planEntry(
                    id: "removed-mark",
                    category: .intro,
                    start: 4.2,
                    end: 5.8,
                    action: .markAsChapter
                ),
            ]
        )
        let merged = try SponsorBlockChapterMerger.merge(
            creatorChapters: [
                ExtractedChapter(
                    title: "Opening",
                    startTimeSeconds: 0,
                    endTimeSeconds: 4
                ),
                ExtractedChapter(
                    title: "Main",
                    startTimeSeconds: 4,
                    endTimeSeconds: 12
                ),
            ],
            includeCreatorChapters: true,
            plan: plan,
            timeline: timeline
        )

        #expect(merged.sponsorBlockChapterCount == 1)
        #expect(merged.chapters.first?.startSeconds == 0)
        #expect(merged.chapters.last?.endSeconds == 8)
        #expect(
            merged.chapters.contains {
                $0.title.hasPrefix("SponsorBlock: Sponsor")
            }
        )
        #expect(
            zip(merged.chapters, merged.chapters.dropFirst()).allSatisfy {
                $0.endSeconds <= $1.startSeconds + 0.002
            }
        )
        #expect(Set(merged.chapters.map(\.title)).count == merged.chapters.count)
    }

    @Test
    func chapterMergeCountsFinalSponsorBlockIntervalsAfterCollisionResolution()
        throws
    {
        let timeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: 10,
            manualTrim: nil,
            requestedRemovals: []
        )
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "overlap-one",
                    start: 2,
                    end: 5,
                    action: .markAsChapter
                ),
                planEntry(
                    id: "overlap-two",
                    start: 2,
                    end: 5,
                    action: .markAsChapter
                ),
            ]
        )

        let merged = try SponsorBlockChapterMerger.merge(
            creatorChapters: [],
            includeCreatorChapters: false,
            plan: plan,
            timeline: timeline
        )

        #expect(
            merged.chapters == [
                MediaChapter(
                    title: "Content",
                    startSeconds: 0,
                    endSeconds: 2
                ),
                MediaChapter(
                    title: "SponsorBlock: Sponsor",
                    startSeconds: 2,
                    endSeconds: 5
                ),
                MediaChapter(
                    title: "Content (2)",
                    startSeconds: 5,
                    endSeconds: 10
                ),
            ]
        )
        #expect(merged.sponsorBlockChapterCount == 1)
    }

    @Test
    func lookupFailureBlocksRequiredRemovalButAllowsTruthfulFallback() throws {
        var required = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        required.replaceSelection(
            videoID: "fixture",
            queriedCategories: required.requestedDiscoveryCategories,
            segments: [
                SponsorBlockSegment(
                    segmentID: "required",
                    category: .sponsor,
                    startSeconds: 1,
                    endSeconds: 2,
                    description: nil,
                    submittedVideoDuration: 20,
                    serverAction: .skip,
                    votes: 1,
                    isLocked: false
                ),
            ]
        )
        required.markLookupUnavailable()
        #expect(throws: SponsorBlockPlanningError.requiredLookupUnavailable) {
            try SponsorBlockPlanner.validateLaunch(
                policy: required,
                videoID: "fixture",
                analyzedDuration: 20
            )
        }

        var optional = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        optional.setAction(.markAsChapter, for: .sponsor)
        optional.replaceSelection(
            videoID: "fixture",
            queriedCategories: optional.requestedDiscoveryCategories,
            segments: [
                SponsorBlockSegment(
                    segmentID: "optional",
                    category: .sponsor,
                    startSeconds: 1,
                    endSeconds: 2,
                    description: nil,
                    submittedVideoDuration: 20,
                    serverAction: .skip,
                    votes: 1,
                    isLocked: false
                ),
            ]
        )
        optional.markLookupUnavailable()
        let plan = try SponsorBlockPlanner.validateLaunch(
            policy: optional,
            videoID: "fixture",
            analyzedDuration: 20
        )
        #expect(plan.entries.isEmpty)
        let record = SponsorBlockApplicationRecord.fallback(
            mode: optional.removalMode,
            reason: .lookupUnavailable
        )
        #expect(record.status == .fallback)
        #expect(record.fallbackReason == .lookupUnavailable)
    }

    @Test
    func durableSnapshotAndCheckpointRoundTripWithoutRefetchOrDoubleCut()
        throws
    {
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor],
            removalMode: .fastKeyframe
        )
        policy.replaceSelection(
            videoID: "fixture",
            queriedCategories: [.sponsor],
            segments: [
                SponsorBlockSegment(
                    segmentID: "durable",
                    category: .sponsor,
                    startSeconds: 1,
                    endSeconds: 2,
                    description: nil,
                    submittedVideoDuration: 10,
                    serverAction: .skip,
                    votes: 1,
                    isLocked: false
                ),
            ]
        )
        let restoredPolicy = try JSONDecoder().decode(
            SponsorBlockPolicy.self,
            from: JSONEncoder().encode(policy)
        )
        let plan = try SponsorBlockPlanner.validateLaunch(
            policy: restoredPolicy,
            videoID: "fixture",
            analyzedDuration: 10
        )
        var application = SponsorBlockApplicationRecord.requested(
            plan: plan,
            mode: restoredPolicy.removalMode
        )
        #expect(
            SponsorBlockCheckpointPlanner.shouldExecute(
                plan: plan,
                application: application,
                checkpoint: nil
            )
        )
        var checkpoint = DownloadPipelineCheckpoint(
            phase: .sponsorBlockVerified
        )
        checkpoint.sponsorBlockEditVerified = true
        checkpoint.sponsorBlockFinalDurationSeconds = 9
        checkpoint.sponsorBlockChapters = []
        let restoredCheckpoint = try JSONDecoder().decode(
            DownloadPipelineCheckpoint.self,
            from: JSONEncoder().encode(checkpoint)
        )
        var rangeEditCalls = 0
        let executeIfNeeded: (DownloadPipelineCheckpoint?) -> Void = {
            checkpoint in
            if SponsorBlockCheckpointPlanner.shouldExecute(
                plan: plan,
                application: application,
                checkpoint: checkpoint
            ) {
                rangeEditCalls += 1
            }
        }
        executeIfNeeded(nil)
        executeIfNeeded(restoredCheckpoint)
        #expect(rangeEditCalls == 1)
        #expect(
            !SponsorBlockCheckpointPlanner.shouldExecute(
                plan: plan,
                application: application,
                checkpoint: restoredCheckpoint
            )
        )
        application.status = .applied
        #expect(
            SponsorBlockCheckpointPlanner.usesTimeline(
                plan: plan,
                application: application
            )
        )
        #expect(
            !SponsorBlockCheckpointPlanner.shouldExecute(
                plan: plan,
                application: application,
                checkpoint: nil
            )
        )
    }

    @Test
    func applicationRecordAndHistoryRoundTripActualTruth() throws {
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "remove",
                    category: .sponsor,
                    start: 1.1,
                    end: 2.2,
                    action: .remove
                ),
                planEntry(
                    id: "chapter",
                    category: .intro,
                    start: 4,
                    end: 5,
                    action: .markAsChapter
                ),
            ]
        )
        var application = SponsorBlockApplicationRecord.requested(
            plan: plan,
            mode: .fastKeyframe
        )
        application.status = .applied
        application.actualRemovalMode = .fastKeyframe
        application.actualRemovalRanges = [
            MediaTimeRange(startSeconds: 1, endSeconds: 2.4),
        ]
        application.removedSegmentCount = 1
        application.removedDurationSeconds = 1.4
        application.sponsorBlockChapterCount = 1

        var job = testJob()
        job.sponsorBlockApplication = application
        let history = HistoryRecord(job: job)
        let restored = try JSONDecoder().decode(
            HistoryRecord.self,
            from: JSONEncoder().encode(history)
        )
        #expect(restored.sponsorBlockApplication == application)
        #expect(
            restored.sponsorBlockApplication?.requestedRemovalRanges
                != restored.sponsorBlockApplication?.actualRemovalRanges
        )

        var legacyJobObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(job)
            ) as? [String: Any]
        )
        legacyJobObject.removeValue(forKey: "sponsorBlockApplication")
        let legacyJob = try JSONDecoder().decode(
            DownloadJob.self,
            from: JSONSerialization.data(withJSONObject: legacyJobObject)
        )
        #expect(legacyJob.sponsorBlockApplication == nil)

        var legacyHistoryObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(history)
            ) as? [String: Any]
        )
        legacyHistoryObject.removeValue(forKey: "sponsorBlockApplication")
        let legacyHistory = try JSONDecoder().decode(
            HistoryRecord.self,
            from: JSONSerialization.data(
                withJSONObject: legacyHistoryObject
            )
        )
        #expect(legacyHistory.sponsorBlockApplication == nil)
    }

    @Test
    func accurateH264VideoRateIsSourceRelative() async throws {
        let root = try makeRoot("AccurateH264Rate")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source-h264.mp4")
        let legacyOutput = root.appending(path: "legacy-highest-quality.mp4")
        let output = root.appending(path: "output-h264.mp4")
        let dimensions = MediaDimensions(width: 1920, height: 1080)
        let keptRanges = [
            MediaTimeRange(startSeconds: 0, endSeconds: 2.4),
            MediaTimeRange(startSeconds: 3.1, endSeconds: 6),
        ]
        try await writeDetailedVideo(
            to: source,
            codec: .h264,
            dimensions: dimensions,
            bitRate: 900_000
        )
        let processor = NativeFFmpegMediaProcessor()
        let sourceProbe = try await processor.probeFullyDecoding(source)
        let sourceVideo = try #require(sourceProbe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        })
        let sourceVideoBitRate = try #require(sourceVideo.bitRate)
        let resolvedVideoBitRate = try #require(
            SourceRelativeVideoBitRate.resolve(
                inputProbe: sourceProbe,
                expectedCodec: .h264,
                expectedDimensions: dimensions,
                expectedFrameRate: 30
            )
        )
        #expect(resolvedVideoBitRate == sourceVideoBitRate)
        #expect(
            SourceRelativeVideoBitRate.resolve(
                inputProbe: sourceProbe,
                expectedCodec: .hevc,
                expectedDimensions: dimensions,
                expectedFrameRate: 30
            ) == nil
        )
        #expect(
            SourceRelativeVideoBitRate.resolve(
                inputProbe: sourceProbe,
                expectedCodec: .h264,
                expectedDimensions: MediaDimensions(
                    width: dimensions.width / 2,
                    height: dimensions.height / 2
                ),
                expectedFrameRate: 30
            ) == nil
        )
        #expect(
            SourceRelativeVideoBitRate.resolve(
                inputProbe: sourceProbe,
                expectedCodec: .h264,
                expectedDimensions: dimensions,
                expectedFrameRate: 60
            ) == nil
        )
        try await exportLegacyHighestQuality(
            input: source,
            output: legacyOutput,
            keptRanges: keptRanges
        )
        let legacyProbe = try await processor.probeFullyDecoding(legacyOutput)
        let legacyVideo = try #require(legacyProbe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        })
        let legacyVideoBitRate = try #require(legacyVideo.bitRate)
        let result = try await processor.process(
            processingRequest(
                input: source,
                output: output,
                mode: .accurate,
                keptRanges: keptRanges,
                videoCodec: .h264,
                audioStreams: 0 ... 0,
                expectedDuration: 5.3,
                dimensions: dimensions,
                videoBitRate: resolvedVideoBitRate
            )
        ) { _ in }
        let outputProbe = try #require(result.probes.first)
        let outputVideo = try #require(outputProbe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        })
        let outputVideoBitRate = try #require(outputVideo.bitRate)
        let sourceDuration = try #require(sourceProbe.durationSeconds)
        let legacyDuration = try #require(legacyProbe.durationSeconds)
        let outputDuration = try #require(outputProbe.durationSeconds)
        let legacyNormalizedFileSizeRatio =
            (Double(legacyProbe.fileSize) / legacyDuration)
                / (Double(sourceProbe.fileSize) / sourceDuration)
        let normalizedFileSizeRatio =
            (Double(outputProbe.fileSize) / outputDuration)
                / (Double(sourceProbe.fileSize) / sourceDuration)
        print(
            "R3 Accurate H.264 characterization: "
                + "sourceVideoBitRate=\(sourceVideoBitRate), "
                + "legacyVideoBitRate=\(legacyVideoBitRate), "
                + "outputVideoBitRate=\(outputVideoBitRate), "
                + "sourceFileSize=\(sourceProbe.fileSize), "
                + "legacyFileSize=\(legacyProbe.fileSize), "
                + "outputFileSize=\(outputProbe.fileSize), "
                + "sourceDuration=\(sourceDuration), "
                + "legacyDuration=\(legacyDuration), "
                + "outputDuration=\(outputDuration), "
                + "sourceCodec=\(sourceVideo.codecName ?? "nil"), "
                + "outputCodec=\(outputVideo.codecName ?? "nil"), "
                + "sourceVideo=\(String(describing: sourceVideo.video)), "
                + "outputVideo=\(String(describing: outputVideo.video)), "
                + "sourceAudioBitRate=nil, outputAudioBitRate=nil, "
                + "legacyNormalizedFileSizeRatio="
                + "\(legacyNormalizedFileSizeRatio), "
                + "normalizedFileSizeRatio=\(normalizedFileSizeRatio)"
        )
        #expect(legacyVideoBitRate > sourceVideoBitRate * 2)
        #expect(legacyNormalizedFileSizeRatio > 2)
        #expect(MediaCodec.h264.matches(probeCodec: sourceVideo.codecName))
        #expect(MediaCodec.h264.matches(probeCodec: outputVideo.codecName))
        #expect(outputVideoBitRate <= sourceVideoBitRate * 2)
        #expect(normalizedFileSizeRatio <= 2.25)
        #expect(outputVideo.video?.width == sourceVideo.video?.width)
        #expect(outputVideo.video?.height == sourceVideo.video?.height)
        #expect(
            outputVideo.video?.averageFrameRate?.doubleValue
                == sourceVideo.video?.averageFrameRate?.doubleValue
        )
        #expect(outputVideo.video?.isHDR == sourceVideo.video?.isHDR)
        #expect(outputProbe.audioStreamCount == 0)
        #expect(abs(outputDuration - 5.3) <= 0.08)
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func accurateHEVCVideoRateIsSourceRelative() async throws {
        let root = try makeRoot("AccurateHEVCRate")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source-hevc.mp4")
        let output = root.appending(path: "output-hevc.mp4")
        let dimensions = MediaDimensions(width: 1920, height: 1080)
        try await writeDetailedVideo(
            to: source,
            codec: .hevc,
            dimensions: dimensions,
            bitRate: 1_200_000,
            textureBlockSize: 8
        )
        let processor = NativeFFmpegMediaProcessor()
        let sourceProbe = try await processor.probeFullyDecoding(source)
        let sourceVideo = try #require(sourceProbe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        })
        let sourceVideoBitRate = try #require(sourceVideo.bitRate)
        let resolvedVideoBitRate = try #require(
            SourceRelativeVideoBitRate.resolve(
                inputProbe: sourceProbe,
                expectedCodec: .hevc,
                expectedDimensions: dimensions,
                expectedFrameRate: 30
            )
        )
        let result = try await processor.process(
            processingRequest(
                input: source,
                output: output,
                mode: .accurate,
                keptRanges: [
                    MediaTimeRange(startSeconds: 0, endSeconds: 2.4),
                    MediaTimeRange(startSeconds: 3.1, endSeconds: 6),
                ],
                videoCodec: .hevc,
                audioStreams: 0 ... 0,
                expectedDuration: 5.3,
                dimensions: dimensions,
                videoBitRate: resolvedVideoBitRate
            )
        ) { _ in }
        let outputProbe = try #require(result.probes.first)
        let outputVideo = try #require(outputProbe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        })
        let outputVideoBitRate = try #require(outputVideo.bitRate)
        let sourceDuration = try #require(sourceProbe.durationSeconds)
        let outputDuration = try #require(outputProbe.durationSeconds)
        let normalizedFileSizeRatio =
            (Double(outputProbe.fileSize) / outputDuration)
                / (Double(sourceProbe.fileSize) / sourceDuration)
        print(
            "R3 Accurate HEVC characterization: "
                + "sourceVideoBitRate=\(sourceVideoBitRate), "
                + "outputVideoBitRate=\(outputVideoBitRate), "
                + "sourceFileSize=\(sourceProbe.fileSize), "
                + "outputFileSize=\(outputProbe.fileSize), "
                + "sourceDuration=\(sourceDuration), "
                + "outputDuration=\(outputDuration), "
                + "normalizedFileSizeRatio=\(normalizedFileSizeRatio)"
        )
        #expect(MediaCodec.hevc.matches(probeCodec: sourceVideo.codecName))
        #expect(MediaCodec.hevc.matches(probeCodec: outputVideo.codecName))
        #expect(outputVideoBitRate <= sourceVideoBitRate * 2)
        #expect(normalizedFileSizeRatio <= 2.25)
        #expect(outputVideo.video?.width == sourceVideo.video?.width)
        #expect(outputVideo.video?.height == sourceVideo.video?.height)
        #expect(
            outputVideo.video?.averageFrameRate?.doubleValue
                == sourceVideo.video?.averageFrameRate?.doubleValue
        )
        #expect(outputVideo.video?.isHDR == sourceVideo.video?.isHDR)
        #expect(outputProbe.audioStreamCount == 0)
        #expect(abs(outputDuration - 5.3) <= 0.08)
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func automatic137Plus140AccurateRequestResolvesVerifiedAACFacts()
        async throws
    {
        let root = try makeRoot("AccurateAutomaticAACFacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source.mp4")
        try merge(video: fixtures.video, audio: fixtures.audio, output: source)

        var productionConfiguration = configuration(mode: .videoAndAudio)
        productionConfiguration.preset = .custom
        productionConfiguration.selectedVideoFormatID = "137"
        productionConfiguration.selectedAudioFormatID = "140"
        productionConfiguration.videoCodec = .automatic
        productionConfiguration.audioCodec = .automatic
        productionConfiguration.container = .automatic
        productionConfiguration.bundleStyle = .mediaOnly
        productionConfiguration = OutputCapabilityMatrix.normalized(
            productionConfiguration
        )
        let productionPlan = try OutputCapabilityMatrix.makePlan(
            configuration: productionConfiguration,
            metadata: DeveloperFixtures.media
        )
        let processor = NativeFFmpegMediaProcessor()
        let inputProbe = try await processor.probeFullyDecoding(source)
        let audioStreams = inputProbe.streams.filter { $0.kind == .audio }
        let inputAudio = try #require(audioStreams.first)

        #expect(productionPlan.strategy == .mergeStreamCopy)
        #expect(productionPlan.expectedAudioCodec == .aac)
        #expect(productionPlan.audioEncodingSettings == nil)
        #expect(productionPlan.expectedSampleRate == nil)
        #expect(productionPlan.expectedChannelCount == nil)
        #expect(productionPlan.expectedAudioBitRate == nil)
        #expect(audioStreams.count == 1)
        #expect(MediaCodec.aac.matches(probeCodec: inputAudio.codecName))
        #expect((inputAudio.audio?.sampleRate ?? 0) > 0)
        #expect((inputAudio.audio?.channelCount ?? 0) > 0)

        let capture = R9RequestCaptureProcessor()
        do {
            _ = try await SponsorBlockExecutionWorkflow(
                mediaProcessor: capture
            ).execute(
                mediaURL: source,
                inputProbe: inputProbe,
                sponsorPlan: SponsorBlockPlan(
                    videoID: "fixture",
                    entries: [
                        planEntry(
                            id: "r9-reproduction",
                            start: 0.5,
                            end: 0.8,
                            action: .remove
                        ),
                    ]
                ),
                policy: removalPolicy(mode: .accurate),
                configuration: productionConfiguration,
                outputPlan: productionPlan,
                metadata: metadata(),
                settings: settings(),
                destinationURL: root.appending(path: "accurate.mp4"),
                operationID: UUID(),
                progress: { _ in }
            )
            Issue.record("The R9 request capture unexpectedly completed.")
        } catch R9RequestCaptureError.captured {
            // Expected: the capture processor stops before native execution.
        } catch {
            Issue.record("The R9 request capture failed unexpectedly: \(error)")
        }

        let request = try #require(await capture.capturedRequest())
        let requestAudio: AudioEncodingSettings
        if case let .encode(settings) = request.output.audio {
            requestAudio = settings
        } else {
            Issue.record("The Accurate request did not encode AAC audio.")
            return
        }
        #expect(requestAudio.codec == .aac)
        #expect(requestAudio.bitRate == inputAudio.bitRate)
        #expect(requestAudio.sampleRate == inputAudio.audio?.sampleRate)
        #expect(requestAudio.channelLayout == .preserve)
        #expect(
            request.verification.expectedAudioSampleRate
                == inputAudio.audio?.sampleRate
        )
        #expect(
            request.verification.expectedAudioChannelCount
                == inputAudio.audio?.channelCount
        )

        let planAudioCodec = productionPlan.expectedAudioCodec?.rawValue
            ?? "nil"
        let probeAudioCodec = inputAudio.codecName ?? "nil"
        print(
            "R9 pre-repair plan "
                + "strategy=\(productionPlan.strategy.rawValue) "
                + "expectedAudioCodec=\(planAudioCodec) "
                + "audioEncodingSettings=\(String(describing: productionPlan.audioEncodingSettings)) "
                + "expectedSampleRate=\(String(describing: productionPlan.expectedSampleRate)) "
                + "expectedChannelCount=\(String(describing: productionPlan.expectedChannelCount)) "
                + "expectedAudioBitRate=\(String(describing: productionPlan.expectedAudioBitRate))"
        )
        print(
            "R9 pre-repair merged probe "
                + "codec=\(probeAudioCodec) "
                + "sampleRate=\(String(describing: inputAudio.audio?.sampleRate)) "
                + "channelCount=\(String(describing: inputAudio.audio?.channelCount)) "
                + "bitRate=\(String(describing: inputAudio.bitRate))"
        )
        print(
            "R9 repaired request "
                + "audioCodec=\(requestAudio.codec.rawValue) "
                + "audioBitRate=\(String(describing: requestAudio.bitRate)) "
                + "audioSampleRate=\(String(describing: requestAudio.sampleRate)) "
                + "audioChannelLayout=\(requestAudio.channelLayout.rawValue) "
                + "verificationSampleRate=\(String(describing: request.verification.expectedAudioSampleRate)) "
                + "verificationChannelCount=\(String(describing: request.verification.expectedAudioChannelCount))"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: request.destinationURL.path
            )
        )
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func accurateAACFactsFailClosedWhenProbeFactsAreUnknownOrInvalid()
        async throws
    {
        let root = try makeRoot("AccurateUnknownAACFacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source.mp4")
        try merge(video: fixtures.video, audio: fixtures.audio, output: source)

        var productionConfiguration = configuration(mode: .videoAndAudio)
        productionConfiguration.preset = .custom
        productionConfiguration.selectedVideoFormatID = "137"
        productionConfiguration.selectedAudioFormatID = "140"
        productionConfiguration.videoCodec = .automatic
        productionConfiguration.audioCodec = .automatic
        productionConfiguration.container = .automatic
        productionConfiguration.bundleStyle = .mediaOnly
        productionConfiguration = OutputCapabilityMatrix.normalized(
            productionConfiguration
        )
        let productionPlan = try OutputCapabilityMatrix.makePlan(
            configuration: productionConfiguration,
            metadata: DeveloperFixtures.media
        )
        let inputProbe = try await NativeFFmpegMediaProcessor()
            .probeFullyDecoding(source)
        let inputAudio = try #require(inputProbe.streams.first {
            $0.kind == .audio
        })
        let missingSampleRate = replacingAudioProbe(
            inputAudio,
            sampleRate: nil,
            channelCount: inputAudio.audio?.channelCount
        )
        let invalidChannelCount = replacingAudioProbe(
            inputAudio,
            sampleRate: inputAudio.audio?.sampleRate,
            channelCount: 0
        )
        let mismatchedCodec = replacingAudioProbe(
            inputAudio,
            codecName: "opus",
            sampleRate: inputAudio.audio?.sampleRate,
            channelCount: inputAudio.audio?.channelCount
        )
        let invalidProbes = [
            replacingStreams(in: inputProbe, audioStreams: [missingSampleRate]),
            replacingStreams(in: inputProbe, audioStreams: [invalidChannelCount]),
            replacingStreams(in: inputProbe, audioStreams: [mismatchedCodec]),
            replacingStreams(
                in: inputProbe,
                audioStreams: [inputAudio, inputAudio]
            ),
        ]
        let expectedError = MediaProcessorError.invalidRequest(
            "Accurate video removal requires known AAC audio facts."
        )

        for (index, invalidProbe) in invalidProbes.enumerated() {
            let capture = R9RequestCaptureProcessor()
            await #expect(throws: expectedError) {
                try await SponsorBlockExecutionWorkflow(
                    mediaProcessor: capture
                ).execute(
                    mediaURL: source,
                    inputProbe: invalidProbe,
                    sponsorPlan: SponsorBlockPlan(
                        videoID: "fixture",
                        entries: [
                            planEntry(
                                id: "r9-invalid-\(index)",
                                start: 0.5,
                                end: 0.8,
                                action: .remove
                            ),
                        ]
                    ),
                    policy: removalPolicy(mode: .accurate),
                    configuration: productionConfiguration,
                    outputPlan: productionPlan,
                    metadata: metadata(),
                    settings: settings(),
                    destinationURL: root.appending(
                        path: "invalid-\(index).mp4"
                    ),
                    operationID: UUID(),
                    progress: { _ in }
                )
            }
            #expect(await capture.capturedRequest() == nil)
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func accurateAVRemovalProducesVerifiedSynchronizedOutput() async throws {
        let root = try makeRoot("AccurateAV")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source.mp4")
        try merge(video: fixtures.video, audio: fixtures.audio, output: source)
        let processor = NativeFFmpegMediaProcessor()
        let probe = try await processor.probeFullyDecoding(source)
        let sourceMetadata = metadata()
        var preservationSettings = settings()
        preservationSettings.preserveMetadata = true
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(id: "one", start: 0.21, end: 0.48, action: .remove),
                planEntry(id: "two", start: 1.12, end: 1.4, action: .remove),
            ]
        )
        let result = try await SponsorBlockExecutionWorkflow(
            mediaProcessor: processor
        ).execute(
            mediaURL: source,
            inputProbe: probe,
            sponsorPlan: plan,
            policy: removalPolicy(mode: .accurate),
            configuration: configuration(mode: .videoAndAudio),
            outputPlan: videoPlan(mode: .videoAndAudio),
            metadata: sourceMetadata,
            settings: preservationSettings,
            destinationURL: root.appending(path: "accurate.mp4"),
            operationID: UUID(),
            progress: { _ in }
        )

        #expect(abs((result.probe.durationSeconds ?? 0) - 1.45) <= 0.08)
        #expect(
            result.probe.verificationEvidence?.verificationClass
                == .boundedStrong
        )
        #expect(
            result.probe.verificationEvidence?.fullDecodePerformed == false
        )
        #expect(result.probe.streams.filter {
            ($0.kind == .video && !$0.disposition.attachedPicture)
                || $0.kind == .audio
        }.allSatisfy {
            ($0.decodedFrames ?? 0) > 0
                && ($0.decodedSampleWindows ?? 0) == 3
        })
        #expect(result.probe.videoStreamCount == 1)
        #expect(result.probe.audioStreamCount == 1)
        #expect(
            result.probe.streams.contains {
                $0.kind == .video && MediaCodec.h264.matches(
                    probeCodec: $0.codecName
                )
            }
        )
        try result.probe.verifyAudioVideoSync(toleranceSeconds: 0.08)
        #expect(result.actualRemovalRanges == result.requestedRemovalRanges)
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: sourceMetadata,
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
        #expect(metadataPolicy.expectedValues["artist"] == "Channel Artist")
        for (key, expected) in metadataPolicy.expectedValues {
            #expect(result.probe.metadata[key] == expected)
        }
        #expect(
            result.probe.metadata["comment"]?.contains(
                sourceMetadata.canonicalURL.absoluteString
            ) == true
        )
        #expect(
            result.probe.metadata["comment"]?.contains(
                sourceMetadata.videoID
            ) == true
        )
        let fastProbe = try await processor.probe(
            result.fileURL,
            verificationClass: .fastStructural
        )
        let fullProbe = try await processor.probeFullyDecoding(result.fileURL)
        let classedProbes: [(MediaProbeResult, MediaVerificationClass)] = [
            (fastProbe, .fastStructural),
            (result.probe, .boundedStrong),
            (fullProbe, .strongFullDecode),
        ]
        for (probe, verificationClass) in classedProbes {
            #expect(
                probe.metadata["description"]
                    == sourceMetadata.description
            )
            for (key, expected) in metadataPolicy.expectedValues {
                #expect(probe.metadata[key] == expected)
            }
            #expect(probe.metadata["[169]des"] == nil)
            #expect(
                probe.verificationEvidence?.verificationClass
                    == verificationClass
            )
        }
        #expect(
            fastProbe.verificationEvidence?.fullDecodePerformed == false
        )
        #expect(
            result.probe.verificationEvidence?.fullDecodePerformed == false
        )
        #expect(
            fullProbe.verificationEvidence?.fullDecodePerformed == true
        )
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func fastProductionRemovalRepublishesRequiredMetadata() async throws {
        let root = try makeRoot("FastProductionMetadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "h264.mp4")
        try await writeH264Video(to: video)
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source-h264.mp4")
        try merge(video: video, audio: fixtures.audio, output: source)
        let processor = NativeFFmpegMediaProcessor()
        let sourceMetadata = metadata()
        var preservationSettings = settings()
        preservationSettings.preserveMetadata = true
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(
                    id: "physical-regression",
                    start: 0.55,
                    end: 1.45,
                    action: .remove
                ),
            ]
        )

        let result = try await SponsorBlockExecutionWorkflow(
            mediaProcessor: processor
        ).execute(
            mediaURL: source,
            inputProbe: try await processor.probeFullyDecoding(source),
            sponsorPlan: plan,
            policy: removalPolicy(mode: .fastKeyframe),
            configuration: configuration(mode: .videoAndAudio),
            outputPlan: videoPlan(mode: .videoAndAudio),
            metadata: sourceMetadata,
            settings: preservationSettings,
            destinationURL: root.appending(path: "fast-production.mp4"),
            operationID: UUID(),
            progress: { _ in }
        )

        let policy = ConversionMetadataPolicy(
            metadata: sourceMetadata,
            preserve: true,
            container: .mp4
        )
        #expect(result.actualMode == .fastKeyframe)
        #expect(
            result.probe.verificationEvidence?.verificationClass
                == .fastStructural
        )
        #expect(!result.actualRemovalRanges.isEmpty)
        for (key, expected) in policy.expectedValues {
            #expect(result.probe.metadata[key] == expected)
        }
        let fullyDecoded = try await processor.probeFullyDecoding(
            result.fileURL
        )
        try fullyDecoded.verifyAudioVideoSync(toleranceSeconds: 0.08)
        #expect(fullyDecoded.videoStreamCount == 1)
        #expect(fullyDecoded.audioStreamCount == 1)
        for (key, expected) in policy.expectedValues {
            #expect(fullyDecoded.metadata[key] == expected)
        }
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func accurateVideoOnlyAndAudioOnlyPathsAreVerified() async throws {
        let root = try makeRoot("AccurateSingleStream")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let processor = NativeFFmpegMediaProcessor()
        let plan = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(id: "cut", start: 0.33, end: 0.72, action: .remove),
            ]
        )
        let workflow = SponsorBlockExecutionWorkflow(mediaProcessor: processor)
        let video = try await workflow.execute(
            mediaURL: fixtures.video,
            inputProbe: try await processor.probeFullyDecoding(fixtures.video),
            sponsorPlan: plan,
            policy: removalPolicy(mode: .accurate),
            configuration: configuration(mode: .videoOnly),
            outputPlan: videoPlan(mode: .videoOnly),
            metadata: metadata(),
            settings: settings(),
            destinationURL: root.appending(path: "video-only.mp4"),
            operationID: UUID(),
            progress: { _ in }
        )
        #expect(video.probe.videoStreamCount == 1)
        #expect(video.probe.audioStreamCount == 0)

        let audio = try await workflow.execute(
            mediaURL: fixtures.audio,
            inputProbe: try await processor.probeFullyDecoding(fixtures.audio),
            sponsorPlan: plan,
            policy: removalPolicy(mode: .accurate),
            configuration: configuration(mode: .audioOnly),
            outputPlan: audioPlan(),
            metadata: metadata(),
            settings: settings(),
            destinationURL: root.appending(path: "audio-only.m4a"),
            operationID: UUID(),
            progress: { _ in }
        )
        #expect(audio.probe.videoStreamCount == 0)
        #expect(audio.probe.audioStreamCount == 1)
        #expect(MediaCodec.aac.matches(probeCodec: audio.probe.streams.first {
            $0.kind == .audio
        }?.codecName))
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func preCancelledRangeEditPublishesNoOutput() async throws {
        let root = try makeRoot("Cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let output = root.appending(path: "cancelled.mp4")
        let processor = NativeFFmpegMediaProcessor()
        let request = processingRequest(
            input: fixtures.video,
            output: output,
            mode: .accurate,
            keptRanges: [
                MediaTimeRange(startSeconds: 0, endSeconds: 0.5),
                MediaTimeRange(startSeconds: 1, endSeconds: 2),
            ],
            videoCodec: MediaCodec(rawValue: "mpeg4"),
            audioStreams: 0 ... 0,
            expectedDuration: 1.5
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.process(request) { _ in }
        }
        await #expect(throws: MediaProcessorError.cancelled) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func fastModeUsesProvenH264KeyframesAndRecordsActualRanges() async throws {
        let root = try makeRoot("Fast")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "h264.mp4")
        try await writeH264Video(to: video)
        let fixtures = try generateFixtures(in: root)
        let source = root.appending(path: "source-h264.mp4")
        try merge(video: video, audio: fixtures.audio, output: source)
        let sourceAudioProbe = try nativeFullProbe(fixtures.audio)
        let mergedProbe = try nativeFullProbe(source)
        let sourceAAC = try #require(
            sourceAudioProbe.streams.first { $0.type == "audio" }
        )
        let mergedAAC = try #require(
            mergedProbe.streams.first { $0.type == "audio" }
        )
        #expect(sourceAudioProbe.packetsInspected == 95)
        #expect(mergedProbe.packetsInspected == 155)
        #expect(mergedAAC.packetSHA256 == sourceAAC.packetSHA256)
        let output = root.appending(path: "fast.mp4")
        let processor = NativeFFmpegMediaProcessor()
        let requestedKept = [
            MediaTimeRange(startSeconds: 0, endSeconds: 0.55),
            MediaTimeRange(startSeconds: 1.45, endSeconds: 2),
        ]
        let result = try await processor.process(
            processingRequest(
                input: source,
                output: output,
                mode: .fastKeyframe,
                keptRanges: requestedKept,
                videoCodec: .h264,
                audioStreams: 1 ... 1,
                expectedDuration: 1.1
            )
        ) { _ in }
        let applied = try #require(result.appliedTimeRanges)
        #expect(applied != requestedKept)
        #expect(result.usedStreamCopy)
        let probe = try #require(result.probes.first)
        #expect(MediaCodec.h264.matches(probeCodec: probe.streams.first {
            $0.kind == .video
        }?.codecName))
        try probe.verifyAudioVideoSync(toleranceSeconds: 0.08)
        #expect(try partialFiles(in: root).isEmpty)
    }

    @Test
    func unsupportedFastAndArtworkIntersectionsFailClosed() throws {
        var fastConfiguration = configuration(mode: .audioOnly)
        let removal = SponsorBlockPlan(
            videoID: "fixture",
            entries: [
                planEntry(id: "cut", start: 1, end: 2, action: .remove),
            ]
        )
        #expect(throws: SponsorBlockPlanningError.unsupportedExecutionPath) {
            try SponsorBlockExecutionSupport.validate(
                plan: removal,
                policy: removalPolicy(mode: .fastKeyframe),
                configuration: fastConfiguration,
                outputPlan: audioPlan()
            )
        }
        fastConfiguration.mode = .videoAndAudio
        let artworkPlan = OutputPlan(
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
            requireArtwork: true,
            requiresApplePlayback: true
        )
        #expect(throws: SponsorBlockPlanningError.unsupportedExecutionPath) {
            try SponsorBlockExecutionSupport.validate(
                plan: removal,
                policy: removalPolicy(mode: .accurate),
                configuration: fastConfiguration,
                outputPlan: artworkPlan
            )
        }
    }

    @Test
    func packageWritesTransformedChaptersInsteadOfSourceMetadata() throws {
        let root = try makeRoot("Package")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "media.mp4")
        try Data("media".utf8).write(to: media)
        let chapters = [
            MediaChapter(title: "Content", startSeconds: 0, endSeconds: 2),
            MediaChapter(
                title: "SponsorBlock: Sponsor",
                startSeconds: 2,
                endSeconds: 3
            ),
        ]
        let package = try MediaPackageWorkflow().buildFolder(
            mediaURL: media,
            thumbnailURL: nil,
            subtitles: [],
            chapterSplits: [],
            chapters: chapters,
            metadata: metadata(),
            packageName: "Fixture",
            temporaryRoot: root,
            durationSeconds: 3,
            progress: { _ in }
        )
        let data = try Data(
            contentsOf: package.folderURL.appending(
                path: "metadata/chapters.json"
            )
        )
        #expect(try JSONDecoder().decode([MediaChapter].self, from: data) == chapters)
    }

    private func planEntry(
        id: String,
        category: SponsorBlockCategory = .sponsor,
        start: Double,
        end: Double,
        action: SponsorBlockAction
    ) -> SponsorBlockPlanEntry {
        SponsorBlockPlanEntry(
            sourceSegmentIDs: [id],
            categories: [category],
            startSeconds: start,
            endSeconds: end,
            action: action
        )
    }

    private func removalPolicy(
        mode: SponsorBlockRemovalMode
    ) -> SponsorBlockPolicy {
        SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor],
            removalMode: mode
        )
    }

    private func configuration(mode: DownloadMode) -> DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = mode
        value.thumbnailBehavior = .none
        value.preserveChapters = false
        value.writeChapters = false
        value.splitChapters = false
        value.subtitleDelivery = .none
        return value
    }

    private func settings() -> AppSettings {
        var value = AppSettings.defaults
        value.preserveMetadata = false
        return value
    }

    private func videoPlan(mode: DownloadMode) -> OutputPlan {
        OutputPlan(
            mode: mode,
            containerChoice: .mp4,
            container: .mp4,
            fileExtension: "mp4",
            strategy: .transcodeVideo,
            sourceVideoCodec: MediaCodec(rawValue: "mpeg4"),
            sourceAudioCodec: mode == .videoOnly ? nil : .aac,
            videoEncodingCodec: .h264,
            videoEncodingFrameRate: 30,
            audioEncodingSettings: nil,
            expectedVideoCodec: .h264,
            expectedAudioCodec: mode == .videoOnly ? nil : .aac,
            expectedDimensions: MediaDimensions(width: 320, height: 180),
            expectedFrameRate: 30,
            expectedHDR: false,
            expectedSampleRate: mode == .videoOnly ? nil : 48_000,
            expectedChannelCount: mode == .videoOnly ? nil : 2,
            expectedAudioBitRate: nil,
            expectedVideoStreams: 1 ... 1,
            expectedAudioStreams: mode == .videoOnly ? 0 ... 0 : 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: true
        )
    }

    private func audioPlan() -> OutputPlan {
        OutputPlan(
            mode: .audioOnly,
            containerChoice: .m4a,
            container: .m4a,
            fileExtension: "m4a",
            strategy: .transcodeAudio,
            sourceVideoCodec: nil,
            sourceAudioCodec: .aac,
            videoEncodingCodec: nil,
            videoEncodingFrameRate: nil,
            audioEncodingSettings: AudioEncodingSettings(
                codec: .aac,
                bitRate: 128_000,
                sampleRate: 48_000,
                channelLayout: .stereo,
                loudnessNormalization: nil
            ),
            expectedVideoCodec: nil,
            expectedAudioCodec: .aac,
            expectedDimensions: nil,
            expectedFrameRate: nil,
            expectedHDR: nil,
            expectedSampleRate: 48_000,
            expectedChannelCount: 2,
            expectedAudioBitRate: 128_000,
            expectedVideoStreams: 0 ... 0,
            expectedAudioStreams: 1 ... 1,
            requireArtwork: false,
            requiresApplePlayback: true
        )
    }

    private func metadata() -> MediaMetadata {
        let base = DeveloperFixtures.media
        return MediaMetadata(
            canonicalURL: base.canonicalURL,
            videoID: "fixture",
            title: base.title,
            channel: "Channel Artist",
            uploader: "Fallback Uploader",
            durationSeconds: 2,
            uploadDate: base.uploadDate,
            description: base.description,
            isLive: false,
            liveStatus: nil,
            thumbnails: [],
            chapters: [],
            subtitles: [],
            formats: base.formats
        )
    }

    private func replacingAudioProbe(
        _ stream: MediaStreamProbe,
        codecName: String? = nil,
        sampleRate: Int?,
        channelCount: Int?
    ) -> MediaStreamProbe {
        var replacement = MediaStreamProbe(
            index: stream.index,
            kind: stream.kind,
            codecName: codecName ?? stream.codecName,
            codecLongName: stream.codecLongName,
            codecProfile: stream.codecProfile,
            codecTag: stream.codecTag,
            durationSeconds: stream.durationSeconds,
            bitRate: stream.bitRate,
            timeBase: stream.timeBase,
            disposition: stream.disposition,
            metadata: stream.metadata,
            video: stream.video,
            audio: AudioStreamProbe(
                sampleFormat: stream.audio?.sampleFormat,
                sampleRate: sampleRate,
                channelCount: channelCount,
                channelLayout: stream.audio?.channelLayout,
                bitsPerSample: stream.audio?.bitsPerSample
            ),
            subtitle: stream.subtitle
        )
        replacement.decodedFrames = stream.decodedFrames
        replacement.decodedSampleWindows = stream.decodedSampleWindows
        return replacement
    }

    private func replacingStreams(
        in probe: MediaProbeResult,
        audioStreams: [MediaStreamProbe]
    ) -> MediaProbeResult {
        var replacement = MediaProbeResult(
            fileURL: probe.fileURL,
            formatNames: probe.formatNames,
            formatLongName: probe.formatLongName,
            durationSeconds: probe.durationSeconds,
            startTimeSeconds: probe.startTimeSeconds,
            bitRate: probe.bitRate,
            fileSize: probe.fileSize,
            metadata: probe.metadata,
            streams: probe.streams.filter { $0.kind != .audio }
                + audioStreams,
            chapters: probe.chapters
        )
        replacement.verificationEvidence = probe.verificationEvidence
        return replacement
    }

    private func processingRequest(
        input: URL,
        output: URL,
        mode: SponsorBlockRemovalMode,
        keptRanges: [MediaTimeRange],
        videoCodec: MediaCodec,
        audioStreams: ClosedRange<Int>,
        expectedDuration: Double,
        dimensions: MediaDimensions = MediaDimensions(width: 320, height: 180),
        videoBitRate: Int64? = nil
    ) -> MediaProcessingRequest {
        MediaProcessingRequest(
            operationID: UUID(),
            operation: .removeRanges(
                mediaURL: input,
                mode: mode,
                keptRanges: keptRanges
            ),
            destinationURL: output,
            output: MediaOutputSpecification(
                container: .mp4,
                video: mode == .accurate
                    ? .encode(
                        VideoEncodingSettings(
                            codec: videoCodec,
                            bitRate: videoBitRate,
                            dimensions: dimensions,
                            frameRate: 30,
                            pixelFormat: nil,
                            profile: nil,
                            level: nil,
                            acceleration: .automatic
                        )
                    )
                    : .copy,
                audio: audioStreams.contains(1) ? .copy : .remove,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: true,
                preserveMetadata: false,
                preserveChapters: false
            ),
            metadata: .empty,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: .mp4,
                expectedFileExtension: "mp4",
                expectedVideoStreams: 1 ... 1,
                expectedAudioStreams: audioStreams,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: videoCodec,
                expectedAudioCodec: audioStreams.contains(1) ? .aac : nil,
                expectedDimensions: dimensions,
                expectedFrameRate: 30,
                frameRateTolerance: 0.12,
                expectedHDR: false,
                expectedAudioSampleRate: audioStreams.contains(1) ? 48_000 : nil,
                expectedAudioChannelCount: audioStreams.contains(1) ? 2 : nil,
                expectedDurationSeconds: expectedDuration,
                durationToleranceSeconds: mode == .accurate ? 0.08 : 1,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.2,
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: [],
                expectedMetadataValues: [:],
                forbiddenMetadataKeys: [],
                requiredVerificationClass: mode == .accurate
                    ? .boundedStrong
                    : .fastStructural
            )
        )
    }

    private func testJob() -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sourceURL: URL(string: "https://example.com/watch?v=fixture")!,
            videoID: "fixture",
            title: "Fixture",
            channel: "Channel",
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: .standard,
            state: .completed,
            stage: .complete,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 0,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part9-\(name)-\(UUID().uuidString)",
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

    private func merge(video: URL, audio: URL, output: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        var request = IllucetStreamCopyRequest(
            mode: ILLUCET_STREAM_COPY_MERGE,
            container: ILLUCET_MEDIA_CONTAINER_MP4,
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

    private func nativeFullProbe(_ fileURL: URL) throws -> FFmpegStage0Probe {
        var rawResult: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(rawResult)
            illucet_ffmpeg_string_free(rawError)
        }
        let status = fileURL.path.withCString {
            illucet_ffmpeg_probe_json($0, nil, &rawResult, &rawError)
        }
        guard status == ILLUCET_FFMPEG_OK, let rawResult else {
            throw MediaProcessorError.nativeFailure(
                rawError.map { String(cString: $0) }
                    ?? "Native full probe failed."
            )
        }
        return try JSONDecoder().decode(
            FFmpegStage0Probe.self,
            from: Data(String(cString: rawResult).utf8)
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

    private func writeDetailedVideo(
        to URL: URL,
        codec: AVVideoCodecType,
        dimensions: MediaDimensions,
        bitRate: Int,
        textureBlockSize: Int = 16
    ) async throws {
        let writer = try AVAssetWriter(outputURL: URL, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ]
        if codec == .h264 {
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [
                bitRate / 8,
                1,
            ]
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: compression,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create the detailed video fixture."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not start the detailed video fixture."
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MediaProcessorError.nativeFailure(
                "Could not allocate the detailed video fixture."
            )
        }
        var texture = [UInt8](
            repeating: 255,
            count: dimensions.width * dimensions.height * 4
        )
        for y in 0 ..< dimensions.height {
            for x in 0 ..< dimensions.width {
                var state = UInt32(
                    (x / textureBlockSize) &* 65_537
                        ^ (y / textureBlockSize) &* 257
                )
                state = state &* 1_664_525 &+ 1_013_904_223
                let offset = (y * dimensions.width + x) * 4
                texture[offset] = UInt8(truncatingIfNeeded: state >> 8)
                texture[offset + 1] = UInt8(truncatingIfNeeded: state >> 16)
                texture[offset + 2] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        for frameIndex in 0 ..< 180 {
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
                throw MediaProcessorError.nativeFailure(
                    "Could not allocate a detailed fixture frame."
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let textureBytesPerRow = dimensions.width * 4
                texture.withUnsafeBytes { textureBytes in
                    guard let textureBase = textureBytes.baseAddress else {
                        return
                    }
                    for y in 0 ..< dimensions.height {
                        let sourceY = (
                            y + frameIndex * 4
                        ) % dimensions.height
                        memcpy(
                            base.advanced(by: y * bytesPerRow),
                            textureBase.advanced(
                                by: sourceY * textureBytesPerRow
                            ),
                            textureBytesPerRow
                        )
                    }
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
                throw writer.error ?? MediaProcessorError.nativeFailure(
                    "Could not append a detailed fixture frame."
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not finish the detailed video fixture."
            )
        }
    }

    private func exportLegacyHighestQuality(
        input: URL,
        output: URL,
        keptRanges: [MediaTimeRange]
    ) async throws {
        let asset = AVURLAsset(url: input)
        let sourceTrack = try #require(
            try await asset.loadTracks(withMediaType: .video).first
        )
        let composition = AVMutableComposition()
        let destinationTrack = try #require(
            composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        )
        var cursor = CMTime.zero
        for range in keptRanges {
            let sourceRange = CMTimeRange(
                start: CMTime(
                    seconds: range.startSeconds,
                    preferredTimescale: 600
                ),
                duration: CMTime(
                    seconds: range.durationSeconds,
                    preferredTimescale: 600
                )
            )
            try destinationTrack.insertTimeRange(
                sourceRange,
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + sourceRange.duration
        }
        let preferredTransform = try await sourceTrack.load(
            .preferredTransform
        )
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let transformed = CGRect(
            origin: .zero,
            size: naturalSize
        ).applying(preferredTransform)
        let normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformed.minX,
                y: -transformed.minY
            )
        )
        var layerConfiguration =
            AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: destinationTrack
            )
        layerConfiguration.setTransform(normalizedTransform, at: .zero)
        let instruction = AVVideoCompositionInstruction(
            configuration: .init(
                layerInstructions: [
                    AVVideoCompositionLayerInstruction(
                        configuration: layerConfiguration
                    ),
                ],
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: composition.duration
                )
            )
        )
        let exporter = try #require(
            AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            )
        )
        exporter.videoComposition = AVVideoComposition(
            configuration: .init(
                frameDuration: CMTime(value: 1, timescale: 30),
                instructions: [instruction],
                renderSize: CGSize(
                    width: abs(transformed.width),
                    height: abs(transformed.height)
                )
            )
        )
        try await exporter.export(to: output, as: .mp4)
    }

    private func writeH264Video(to URL: URL) async throws {
        let writer = try AVAssetWriter(outputURL: URL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 400_000,
                    AVVideoMaxKeyFrameIntervalKey: 12,
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
            throw MediaProcessorError.nativeFailure(
                "Could not create the H.264 fixture."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not start the H.264 fixture."
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MediaProcessorError.nativeFailure(
                "Could not allocate the H.264 fixture."
            )
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
                throw MediaProcessorError.nativeFailure(
                    "Could not allocate a fixture frame."
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    base,
                    Int32((frameIndex * 3) % 180),
                    CVPixelBufferGetDataSize(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: 30
                )
            ) else {
                throw writer.error ?? MediaProcessorError.nativeFailure(
                    "Could not append a fixture frame."
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not finish the H.264 fixture."
            )
        }
    }

    private func partialFiles(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("illucet-partial") }
    }
}

private enum R9RequestCaptureError: Error {
    case captured
}

private actor R9RequestCaptureProcessor: MediaProcessor {
    private var request: MediaProcessingRequest?

    func process(
        _ request: MediaProcessingRequest,
        progress _: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        self.request = request
        throw R9RequestCaptureError.captured
    }

    func probe(
        _ fileURL: URL,
        verificationClass _: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        throw MediaProcessorError.probeFailure(
            "R9 request capture does not probe \(fileURL.lastPathComponent)."
        )
    }

    func cancel(operationID _: UUID) async {}

    func capturedRequest() -> MediaProcessingRequest? {
        request
    }
}
