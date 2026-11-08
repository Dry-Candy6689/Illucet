import Foundation

struct AcquiredMediaSource: Equatable, Sendable {
    let selection: SelectedSourceFact
    let fileURL: URL
}

struct DownloadConversionResult: Sendable {
    let job: DownloadJob
    let fileURL: URL
    let probe: MediaProbeResult
}

/// Executes only the bounded media assembly/conversion portion of one durable
/// download pipeline. Codec and verification policy comes from the immutable
/// output plan and request builder.
final class DownloadConversionWorkflow: @unchecked Sendable {
    private let mediaProcessor: any MediaProcessor

    init(mediaProcessor: any MediaProcessor) {
        self.mediaProcessor = mediaProcessor
    }

    func createOutput(
        job initialJob: DownloadJob,
        metadata: MediaMetadata,
        plan: OutputPlan,
        sources: [AcquiredMediaSource],
        artworkURL: URL?,
        temporaryRoot: URL,
        outputURL: URL,
        settings: AppSettings,
        context: DownloadPipelineContext
    ) async throws -> DownloadConversionResult {
        var job = initialJob
        let video = sources.first { $0.selection.hasVideo }
        let audioOnly = sources.first {
            $0.selection.hasAudio && !$0.selection.hasVideo
        }
        let combined = sources.first {
            $0.selection.hasVideo && $0.selection.hasAudio
        }
        let builder = MediaConversionRequestBuilder(
            plan: plan,
            configuration: job.configuration,
            metadata: metadata,
            settings: settings
        )
        let activeJobID = job.id

        switch plan.strategy {
        case .remuxCombinedStreamCopy:
            guard let combined else { throw IllucetError.noCompatibleFormat }
            job = try await context.update(
                job,
                state: .running,
                stage: .merging
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .remux(inputURL: combined.fileURL),
                    destination: outputURL
                ),
                expectedStage: .merging,
                context: context
            )
            return try conversionResult(job: job, result: result)

        case .mergeStreamCopy:
            guard let video, let audioOnly else {
                throw IllucetError.noCompatibleFormat
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .merging
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .merge(
                        videoURL: video.fileURL,
                        audioURL: audioOnly.fileURL
                    ),
                    destination: outputURL
                ),
                expectedStage: .merging,
                context: context
            )
            return try conversionResult(job: job, result: result)

        case .extractOriginalAudio:
            guard let input = audioOnly?.fileURL ?? combined?.fileURL else {
                throw IllucetError.noCompatibleFormat
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .merging
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .extractAudio(inputURL: input),
                    destination: outputURL
                ),
                expectedStage: .merging,
                context: context
            )
            return try conversionResult(job: job, result: result)

        case .transcodeAudio:
            guard let input = audioOnly?.fileURL ?? combined?.fileURL else {
                throw IllucetError.noCompatibleFormat
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .converting
            )
            let transcode = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .transcodeAudio(inputURL: input),
                    destination: outputURL,
                    role: plan.requireArtwork ? .audioStage : .final,
                    requireArtwork: false
                ),
                expectedStage: .converting,
                context: context
            )
            return try await attachArtworkIfNeeded(
                job: job,
                builder: builder,
                mediaURL: outputURL,
                existingResult: transcode,
                artworkURL: artworkURL,
                temporaryRoot: temporaryRoot,
                context: context
            )

        case .copyVideoOnly:
            guard let video else { throw IllucetError.noCompatibleFormat }
            job = try await context.update(
                job,
                state: .running,
                stage: .merging
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .removeAudio(inputURL: video.fileURL),
                    destination: outputURL
                ),
                expectedStage: .merging,
                context: context
            )
            return try conversionResult(job: job, result: result)

        case .transcodeVideo:
            guard let video else { throw IllucetError.noCompatibleFormat }
            job = try await context.update(
                job,
                state: .running,
                stage: .converting
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .transcodeVideo(inputURL: video.fileURL),
                    destination: outputURL
                ),
                expectedStage: .converting,
                context: context
            )
            return try conversionResult(job: job, result: result)

        case .assembleConvertedStreams:
            guard
                let video,
                let sourceAudio = audioOnly?.fileURL ?? combined?.fileURL
            else {
                throw IllucetError.noCompatibleFormat
            }
            var videoURL = video.fileURL
            var audioURL = sourceAudio
            if plan.needsVideoConversion {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .converting
                )
                videoURL = temporaryRoot.appending(
                    path: "video-stage.\(plan.fileExtension)"
                )
                _ = try await process(
                    builder.request(
                        operationID: activeJobID,
                        operation: .transcodeVideo(inputURL: video.fileURL),
                        destination: videoURL,
                        role: .videoStage
                    ),
                    expectedStage: .converting,
                    context: context
                )
            }
            if plan.needsAudioConversion {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .converting
                )
                audioURL = temporaryRoot.appending(
                    path: "audio-stage.\(plan.fileExtension)"
                )
                _ = try await process(
                    builder.request(
                        operationID: activeJobID,
                        operation: .transcodeAudio(
                            inputURL: sourceAudio
                        ),
                        destination: audioURL,
                        role: .audioStage
                    ),
                    expectedStage: .converting,
                    context: context
                )
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .merging
            )
            let result = try await process(
                builder.request(
                    operationID: activeJobID,
                    operation: .merge(
                        videoURL: videoURL,
                        audioURL: audioURL
                    ),
                    destination: outputURL
                ),
                expectedStage: .merging,
                context: context
            )
            return try conversionResult(job: job, result: result)
        }
    }

    /// Video covers are attached after timeline, subtitle and chapter work so
    /// those operations never discard a requested cover or change its media.
    func includeVideoThumbnail(
        mediaURL: URL,
        inputProbe: MediaProbeResult,
        artworkURL: URL,
        destination: URL,
        plan: OutputPlan,
        operationID: UUID,
        fastStart: Bool,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        guard plan.container == .mp4, inputProbe.videoStreamCount > 0 else {
            throw MediaProcessorError.invalidRequest("Embedded video thumbnails require MP4 video.")
        }
        let video = inputProbe.streams.first { $0.kind == .video && !$0.disposition.attachedPicture }
        let audio = inputProbe.streams.first { $0.kind == .audio }
        let request = MediaProcessingRequest(
            operationID: operationID,
            operation: .attachArtwork(mediaURL: mediaURL, artworkURL: artworkURL),
            destinationURL: destination,
            output: MediaOutputSpecification(
                container: .mp4, video: .copy, audio: .copy, dynamicRange: .preserve,
                subtitleCodec: nil, fastStart: fastStart,
                preserveMetadata: true, preserveChapters: true
            ),
            metadata: .empty, chapters: [], trimming: nil, overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: .mp4, expectedFileExtension: "mp4",
                expectedVideoStreams: inputProbe.videoStreamCount ... inputProbe.videoStreamCount,
                expectedAudioStreams: inputProbe.audioStreamCount ... inputProbe.audioStreamCount,
                expectedSubtitleStreams: inputProbe.subtitleStreamCount ... inputProbe.subtitleStreamCount,
                expectedVideoCodec: OutputConversionPlanner.mediaCodec(video?.codecName),
                expectedAudioCodec: OutputConversionPlanner.mediaCodec(audio?.codecName),
                expectedDimensions: video?.video.map { MediaDimensions(width: $0.width, height: $0.height) },
                expectedFrameRate: video?.video?.averageFrameRate?.doubleValue,
                frameRateTolerance: 0.12, expectedHDR: video?.video?.isHDR,
                expectedAudioSampleRate: audio?.audio?.sampleRate, expectedAudioChannelCount: audio?.audio?.channelCount,
                expectedDurationSeconds: inputProbe.durationSeconds, durationToleranceSeconds: 0.1,
                expectedAudioBitRate: nil, audioBitRateToleranceFraction: 0.08,
                expectedChapterCount: inputProbe.chapters.count ... inputProbe.chapters.count,
                requireArtwork: true, requireMetadataKeys: [],
                expectedMetadataValues: inputProbe.metadata.filter { ["title", "artist", "date", "description", "comment"].contains($0.key) },
                forbiddenMetadataKeys: [], requiredVerificationClass: .fastStructural
            )
        )
        let result = try await mediaProcessor.process(request, progress: progress)
        guard let probe = result.probes.first,
              probe.chapters.count == inputProbe.chapters.count,
              zip(probe.chapters, inputProbe.chapters).allSatisfy({ actual, expected in
                  actual.title == expected.title && abs(actual.startSeconds - expected.startSeconds) < 0.01
                      && abs(actual.endSeconds - expected.endSeconds) < 0.01
              }) else {
            throw MediaProcessorError.verificationMismatch("Chapter markers changed while adding the video thumbnail.")
        }
        return result
    }

    private func attachArtworkIfNeeded(
        job initialJob: DownloadJob,
        builder: MediaConversionRequestBuilder,
        mediaURL: URL,
        existingResult: MediaProcessingResult,
        artworkURL: URL?,
        temporaryRoot: URL,
        context: DownloadPipelineContext
    ) async throws -> DownloadConversionResult {
        guard builder.plan.requireArtwork else {
            return try conversionResult(
                job: initialJob,
                result: existingResult
            )
        }
        guard let artworkURL else {
            throw OutputCompatibilityError.invalidFormatSelection
        }
        let job = try await context.update(
            initialJob,
            state: .running,
            stage: .embeddingMetadata
        )
        let embedded = temporaryRoot.appending(
            path: "output-artwork.\(builder.plan.fileExtension)"
        )
        let result = try await process(
            builder.request(
                operationID: job.id,
                operation: .attachArtwork(
                    mediaURL: mediaURL,
                    artworkURL: artworkURL
                ),
                destination: embedded,
                requireArtwork: true
            ),
            expectedStage: .embeddingMetadata,
            context: context
        )
        return try conversionResult(job: job, result: result)
    }

    private func process(
        _ request: MediaProcessingRequest,
        expectedStage: DownloadStage,
        context: DownloadPipelineContext
    ) async throws -> MediaProcessingResult {
        try await context.reportingProcessingProgress(
            operationID: request.operationID,
            expectedStage: expectedStage
        ) { progress in
            try await mediaProcessor.process(
                request,
                progress: progress
            )
        }
    }

    private func conversionResult(
        job: DownloadJob,
        result: MediaProcessingResult
    ) throws -> DownloadConversionResult {
        guard
            let fileURL = result.outputURLs.first,
            let probe = result.probes.first
        else {
            throw MediaProcessorError.probeFailure(
                "Media processing returned no verified output."
            )
        }
        return DownloadConversionResult(
            job: job,
            fileURL: fileURL,
            probe: probe
        )
    }
}
