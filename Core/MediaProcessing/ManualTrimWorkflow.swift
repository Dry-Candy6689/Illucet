import Foundation

struct ManualTrimResult: Equatable, Sendable {
    let fileURL: URL
    let probe: MediaProbeResult
    let range: MediaTrimRange
    let mode: MediaTrimMode
}

final class ManualTrimWorkflow: @unchecked Sendable {
    private let mediaProcessor: any MediaProcessor

    init(mediaProcessor: any MediaProcessor) {
        self.mediaProcessor = mediaProcessor
    }

    func trim(
        mediaURL: URL,
        inputProbe: MediaProbeResult,
        plan: OutputPlan,
        range: MediaTrimRange,
        mode: MediaTrimMode,
        metadata: MediaMetadata,
        settings: AppSettings,
        destinationURL: URL,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> ManualTrimResult {
        guard [.mp4, .mov].contains(plan.container),
              let codec = plan.expectedVideoCodec,
              [.h264, .hevc].contains(codec),
              inputProbe.subtitleStreamCount == 0,
              inputProbe.chapters.isEmpty
        else {
            throw MediaProcessorError.invalidRequest(
                "Trimming supports chapter-free, subtitle-free H.264/HEVC MP4/MOV output."
            )
        }
        let sourceDuration = inputProbe.durationSeconds
            ?? metadata.durationSeconds
        guard let sourceDuration,
              sourceDuration.isFinite,
              sourceDuration > 0,
              range.startSeconds.isFinite,
              range.startSeconds >= 0,
              range.startSeconds < sourceDuration,
              range.endSeconds?.isFinite != false,
              range.endSeconds.map({
                  $0 > range.startSeconds && $0 <= sourceDuration + 0.05
              }) ?? true
        else {
            throw MediaProcessorError.invalidRequest(
                "The manual trim range is invalid."
            )
        }
        let end = min(range.endSeconds ?? sourceDuration, sourceDuration)
        let expectedDuration = end - range.startSeconds
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        let request = MediaProcessingRequest(
            operationID: operationID,
            operation: .trim(mediaURL: mediaURL, mode: mode),
            destinationURL: destinationURL,
            output: MediaOutputSpecification(
                container: plan.container,
                video: mode == .accurate
                    ? .encode(
                        VideoEncodingSettings(
                            codec: codec,
                            bitRate: SourceRelativeVideoBitRate.resolve(
                                inputProbe: inputProbe,
                                expectedCodec: plan.expectedVideoCodec,
                                expectedDimensions: plan.expectedDimensions,
                                expectedFrameRate: plan.expectedFrameRate
                            ),
                            dimensions: plan.expectedDimensions,
                            frameRate: plan.expectedFrameRate,
                            pixelFormat: nil,
                            profile: nil,
                            level: nil,
                            acceleration: .automatic
                        )
                    )
                    : .copy,
                audio: plan.expectedAudioStreams.contains(1)
                    ? .copy
                    : .remove,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: settings.fastStartMP4,
                preserveMetadata: settings.preserveMetadata,
                preserveChapters: false
            ),
            metadata: metadataPolicy.tags,
            chapters: [],
            trimming: MediaTrimRange(
                startSeconds: range.startSeconds,
                endSeconds: end
            ),
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: plan.container,
                expectedFileExtension: plan.fileExtension,
                expectedVideoStreams: plan.expectedVideoStreams,
                expectedAudioStreams: plan.expectedAudioStreams,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: codec,
                expectedAudioCodec: plan.expectedAudioCodec,
                expectedDimensions: plan.expectedDimensions,
                expectedFrameRate: plan.expectedFrameRate,
                frameRateTolerance: 0.12,
                expectedHDR: plan.expectedHDR,
                expectedAudioSampleRate: plan.expectedSampleRate,
                expectedAudioChannelCount: plan.expectedChannelCount,
                expectedDurationSeconds: expectedDuration,
                durationToleranceSeconds: mode == .accurate ? 0.08 : 1.0,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.08,
                expectedChapterCount: 0 ... 0,
                requireArtwork: plan.requireArtwork,
                requireMetadataKeys: metadataPolicy.requiredKeys,
                expectedMetadataValues: metadataPolicy.expectedValues,
                forbiddenMetadataKeys: metadataPolicy.forbiddenKeys,
                requiredVerificationClass: mode == .accurate
                    ? .boundedStrong
                    : .fastStructural
            )
        )
        let result = try await mediaProcessor.process(
            request,
            progress: progress
        )
        guard let probe = result.probes.first else {
            throw MediaProcessorError.verificationMismatch(
                "The trimmed output had no probe result."
            )
        }
        return ManualTrimResult(
            fileURL: destinationURL,
            probe: probe,
            range: request.trimming!,
            mode: mode
        )
    }
}
