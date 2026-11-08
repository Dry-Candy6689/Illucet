import Foundation

/// Converts an immutable output plan into typed native processing requests.
/// The durable pipeline runner does not own codec, metadata, or verification
/// policy.
struct MediaConversionRequestBuilder: Sendable {
    enum Role: Sendable {
        case final
        case videoStage
        case audioStage
    }

    let plan: OutputPlan
    let configuration: DownloadConfiguration
    let metadata: MediaMetadata
    let settings: AppSettings

    func request(
        operationID: UUID,
        operation: MediaProcessingOperation,
        destination: URL,
        role: Role = .final,
        requireArtwork: Bool? = nil
    ) throws -> MediaProcessingRequest {
        let policies = try outputPolicies(for: operation)
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        let expectations = expectations(
            for: role,
            requireArtwork: requireArtwork
        )
        return MediaProcessingRequest(
            operationID: operationID,
            operation: operation,
            destinationURL: destination,
            output: MediaOutputSpecification(
                container: plan.container,
                video: policies.video,
                audio: policies.audio,
                dynamicRange: configuration.convertHDRToSDR
                    ? .convertToSDR
                    : .preserve,
                subtitleCodec: nil,
                fastStart: settings.fastStartMP4,
                preserveMetadata: settings.preserveMetadata,
                preserveChapters: false
            ),
            metadata: metadataPolicy.tags,
            chapters: [],
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: plan.container,
                expectedFileExtension: destination.pathExtension,
                expectedVideoStreams: expectations.videoStreams,
                expectedAudioStreams: expectations.audioStreams,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: expectations.videoCodec,
                expectedAudioCodec: expectations.audioCodec,
                expectedDimensions: expectations.dimensions,
                expectedFrameRate: expectations.frameRate,
                frameRateTolerance: 0.12,
                expectedHDR: expectations.HDR,
                expectedAudioSampleRate: expectations.sampleRate,
                expectedAudioChannelCount: expectations.channelCount,
                expectedDurationSeconds: metadata.durationSeconds,
                durationToleranceSeconds: 1.0,
                expectedAudioBitRate: expectations.audioBitRate,
                audioBitRateToleranceFraction:
                    ConversionCapabilityMatrix.bitRateToleranceFraction(
                        for: expectations.audioCodec
                    ),
                expectedChapterCount: 0 ... 0,
                requireArtwork: expectations.requireArtwork,
                requireMetadataKeys: metadataPolicy.requiredKeys,
                expectedMetadataValues: metadataPolicy.expectedValues,
                forbiddenMetadataKeys: metadataPolicy.forbiddenKeys,
                requiredVerificationClass: verificationClass(
                    for: operation,
                    role: role,
                    requireArtwork: requireArtwork
                )
            )
        )
    }

    func finalVerification(
        fileURL: URL,
        requireArtwork: Bool? = nil
    ) -> MediaVerificationRequirements {
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        return MediaVerificationRequirements(
            expectedContainer: plan.container,
            expectedFileExtension: fileURL.pathExtension,
            expectedVideoStreams: plan.expectedVideoStreams,
            expectedAudioStreams: plan.expectedAudioStreams,
            expectedSubtitleStreams: 0 ... 0,
            expectedVideoCodec: plan.expectedVideoCodec,
            expectedAudioCodec: plan.expectedAudioCodec,
            expectedDimensions: plan.expectedDimensions,
            expectedFrameRate: plan.expectedFrameRate,
            frameRateTolerance: 0.12,
            expectedHDR: plan.expectedHDR,
            expectedAudioSampleRate: plan.expectedSampleRate,
            expectedAudioChannelCount: plan.expectedChannelCount,
            expectedDurationSeconds: metadata.durationSeconds,
            durationToleranceSeconds: 1.5,
            expectedAudioBitRate: plan.mode == .audioOnly
                ? plan.expectedAudioBitRate
                : nil,
            audioBitRateToleranceFraction:
                ConversionCapabilityMatrix.bitRateToleranceFraction(
                    for: plan.expectedAudioCodec
                ),
            expectedChapterCount: 0 ... 0,
            requireArtwork: requireArtwork ?? plan.requireArtwork,
            requireMetadataKeys: metadataPolicy.requiredKeys,
            expectedMetadataValues: metadataPolicy.expectedValues,
            forbiddenMetadataKeys: metadataPolicy.forbiddenKeys,
            requiredVerificationClass: plan.needsConversion
                ? .boundedStrong
                : .fastStructural
        )
    }

    private func verificationClass(
        for operation: MediaProcessingOperation,
        role: Role,
        requireArtwork: Bool?
    ) -> MediaVerificationClass {
        switch role {
        case .videoStage, .audioStage:
            return .boundedStrong
        case .final:
            break
        }
        switch operation {
        case .transcodeAudio:
            if plan.requireArtwork, requireArtwork == false {
                return .boundedStrong
            }
            return .boundedStrong
        case .transcodeVideo:
            return .boundedStrong
        case .merge:
            return plan.needsConversion
                ? .boundedStrong
                : .fastStructural
        case .attachArtwork:
            return plan.needsConversion
                ? .boundedStrong
                : .fastStructural
        case .remux, .extractAudio, .removeAudio, .embedSubtitles,
             .writeChapters:
            return .fastStructural
        case .burnSubtitles, .splitChapters:
            return .boundedStrong
        case let .trim(_, mode):
            return mode == .accurate
                ? .boundedStrong
                : .fastStructural
        case .removeRanges:
            return .boundedStrong
        }
    }

    private func outputPolicies(
        for operation: MediaProcessingOperation
    ) throws -> (
        video: VideoOutputPolicy,
        audio: AudioOutputPolicy
    ) {
        switch operation {
        case .transcodeVideo:
            guard let codec = plan.videoEncodingCodec else {
                throw MediaProcessorError.invalidRequest(
                    "The output plan has no video encoder request."
                )
            }
            return (
                .encode(
                    VideoEncodingSettings(
                        codec: codec,
                        bitRate: nil,
                        dimensions: plan.expectedDimensions,
                        frameRate: plan.videoEncodingFrameRate,
                        pixelFormat: codec == .hevc ? "p010le" : "nv12",
                        profile: nil,
                        level: nil,
                        acceleration: settings.preferVideoToolbox
                            ? .preferVideoToolbox
                            : .automatic
                    )
                ),
                .remove
            )
        case .transcodeAudio:
            guard let audio = plan.audioEncodingSettings else {
                throw MediaProcessorError.invalidRequest(
                    "The output plan has no audio encoder request."
                )
            }
            return (.remove, .encode(audio))
        case .removeAudio:
            return (.copy, .remove)
        case .extractAudio:
            return (.remove, .copy)
        case .merge, .remux, .attachArtwork:
            return (.copy, .copy)
        case .embedSubtitles, .burnSubtitles, .writeChapters, .trim,
             .removeRanges, .splitChapters:
            throw MediaProcessorError.invalidRequest(
                "Part 8 processing is outside the current conversion workflow."
            )
        }
    }

    private func expectations(
        for role: Role,
        requireArtwork: Bool?
    ) -> (
        videoStreams: ClosedRange<Int>,
        audioStreams: ClosedRange<Int>,
        videoCodec: MediaCodec?,
        audioCodec: MediaCodec?,
        dimensions: MediaDimensions?,
        frameRate: Double?,
        HDR: Bool?,
        sampleRate: Int?,
        channelCount: Int?,
        audioBitRate: Int64?,
        requireArtwork: Bool
    ) {
        switch role {
        case .final:
            (
                plan.expectedVideoStreams,
                plan.expectedAudioStreams,
                plan.expectedVideoCodec,
                plan.expectedAudioCodec,
                plan.expectedDimensions,
                plan.expectedFrameRate,
                plan.expectedHDR,
                plan.expectedSampleRate,
                plan.expectedChannelCount,
                plan.mode == .audioOnly
                    ? plan.expectedAudioBitRate
                    : nil,
                requireArtwork ?? plan.requireArtwork
            )
        case .videoStage:
            (
                1 ... 1,
                0 ... 0,
                plan.expectedVideoCodec,
                nil,
                plan.expectedDimensions,
                plan.expectedFrameRate,
                plan.expectedHDR,
                nil,
                nil,
                nil,
                false
            )
        case .audioStage:
            (
                0 ... 0,
                1 ... 1,
                nil,
                plan.expectedAudioCodec,
                nil,
                nil,
                nil,
                plan.expectedSampleRate,
                plan.expectedChannelCount,
                plan.expectedAudioBitRate,
                false
            )
        }
    }
}
