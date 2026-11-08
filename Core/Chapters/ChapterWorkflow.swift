import Foundation

enum ChapterWorkflowError: LocalizedError, Equatable {
    case invalidChapterData
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidChapterData:
            "The video’s chapter times are invalid or overlap. Turn off Keep source chapters, Add creator chapters, and Save each chapter as a file in download options, then try again."
        case .verificationFailed:
            "The saved chapters did not match the requested chapter times. The output was not exported. Review creator chapter settings and SponsorBlock Mark as Chapter actions before retrying."
        }
    }
}

struct ChapterWriteResult: Equatable, Sendable {
    let fileURL: URL
    let probe: MediaProbeResult
    let chapters: [MediaChapter]
}

final class ChapterWorkflow: @unchecked Sendable {
    static let maximumChapterCount = 512

    private let mediaProcessor: any MediaProcessor

    init(mediaProcessor: any MediaProcessor) {
        self.mediaProcessor = mediaProcessor
    }

    func write(
        metadataChapters: [ExtractedChapter],
        into mediaURL: URL,
        inputProbe: MediaProbeResult,
        plan: OutputPlan,
        configuration: DownloadConfiguration,
        metadata: MediaMetadata,
        settings: AppSettings,
        temporaryRoot: URL,
        operationID: UUID,
        resolvedChapters: [MediaChapter]? = nil,
        expectedDurationSeconds: Double? = nil,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> ChapterWriteResult {
        let outputDuration = expectedDurationSeconds
            ?? inputProbe.durationSeconds
            ?? metadata.durationSeconds
        let chapters: [MediaChapter]
        if let resolvedChapters {
            chapters = try Self.validated(
                resolvedChapters,
                durationSeconds: outputDuration
            )
        } else {
            chapters = configuration.writeChapters
                ? try Self.normalized(
                    metadataChapters,
                    durationSeconds: metadata.durationSeconds
                )
                : []
        }
        let preserveInput = configuration.preserveChapters
            && chapters.isEmpty
        guard !chapters.isEmpty
                || (preserveInput && !inputProbe.chapters.isEmpty)
        else {
            return ChapterWriteResult(
                fileURL: mediaURL,
                probe: inputProbe,
                chapters: []
            )
        }
        let expected = chapters.isEmpty ? inputProbe.chapters : chapters
        let destination = temporaryRoot.appending(
            path: "output-chapters.\(plan.fileExtension)"
        )
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        let request = MediaProcessingRequest(
            operationID: operationID,
            operation: .writeChapters(mediaURL: mediaURL),
            destinationURL: destination,
            output: MediaOutputSpecification(
                container: plan.container,
                video: plan.expectedVideoStreams.contains(1)
                    ? .copy
                    : .remove,
                audio: plan.expectedAudioStreams.contains(1)
                    ? .copy
                    : .remove,
                dynamicRange: .preserve,
                subtitleCodec: nil,
                fastStart: settings.fastStartMP4,
                preserveMetadata: settings.preserveMetadata,
                preserveChapters: preserveInput
            ),
            metadata: metadataPolicy.tags,
            chapters: chapters,
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: plan.container,
                expectedFileExtension: plan.fileExtension,
                expectedVideoStreams: plan.expectedVideoStreams,
                expectedAudioStreams: plan.expectedAudioStreams,
                expectedSubtitleStreams:
                    inputProbe.subtitleStreamCount
                    ... inputProbe.subtitleStreamCount,
                expectedVideoCodec: plan.expectedVideoCodec,
                expectedAudioCodec: plan.expectedAudioCodec,
                expectedDimensions: plan.expectedDimensions,
                expectedFrameRate: plan.expectedFrameRate,
                frameRateTolerance: 0.12,
                expectedHDR: plan.expectedHDR,
                expectedAudioSampleRate: plan.expectedSampleRate,
                expectedAudioChannelCount: plan.expectedChannelCount,
                expectedDurationSeconds: outputDuration,
                durationToleranceSeconds: 1.5,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction: 0.08,
                expectedChapterCount: expected.count ... expected.count,
                requireArtwork: plan.requireArtwork,
                requireMetadataKeys: metadataPolicy.requiredKeys,
                expectedMetadataValues: metadataPolicy.expectedValues,
                forbiddenMetadataKeys: metadataPolicy.forbiddenKeys,
                requiredVerificationClass: .fastStructural
            )
        )
        let result = try await mediaProcessor.process(
            request,
            progress: progress
        )
        guard let probe = result.probes.first else {
            throw ChapterWorkflowError.verificationFailed
        }
        try Self.verify(probe.chapters, expected: expected)
        return ChapterWriteResult(
            fileURL: destination,
            probe: probe,
            chapters: expected
        )
    }

    static func normalized(
        _ extracted: [ExtractedChapter],
        durationSeconds: Double?
    ) throws -> [MediaChapter] {
        guard !extracted.isEmpty,
              extracted.count <= maximumChapterCount
        else {
            if extracted.isEmpty { return [] }
            throw ChapterWorkflowError.invalidChapterData
        }
        var result: [MediaChapter] = []
        for index in extracted.indices {
            let source = extracted[index]
            let nextStart = extracted.indices.contains(index + 1)
                ? extracted[index + 1].startTimeSeconds
                : durationSeconds
            let end = source.endTimeSeconds ?? nextStart
            let title = Self.title(source.title, index: index)
            guard source.startTimeSeconds.isFinite,
                  let end,
                  end.isFinite,
                  source.startTimeSeconds >= 0,
                  end > source.startTimeSeconds,
                  durationSeconds.map({ end <= $0 + 0.05 }) ?? true,
                  nextStart.map({ end <= $0 + 0.05 }) ?? true,
                  result.last.map({
                      source.startTimeSeconds >= $0.startSeconds
                  }) ?? true
            else {
                throw ChapterWorkflowError.invalidChapterData
            }
            result.append(
                MediaChapter(
                    title: title,
                    startSeconds: source.startTimeSeconds,
                    endSeconds: end
                )
            )
        }
        return result
    }

    static func verify(
        _ actual: [MediaChapter],
        expected: [MediaChapter]
    ) throws {
        guard actual.count == expected.count else {
            throw ChapterWorkflowError.verificationFailed
        }
        for (actual, expected) in zip(actual, expected) {
            guard actual.title == expected.title,
                  abs(actual.startSeconds - expected.startSeconds) <= 0.002,
                  abs(actual.endSeconds - expected.endSeconds) <= 0.002
            else {
                throw ChapterWorkflowError.verificationFailed
            }
        }
    }

    static func validated(
        _ chapters: [MediaChapter],
        durationSeconds: Double?
    ) throws -> [MediaChapter] {
        guard chapters.count <= maximumChapterCount else {
            throw ChapterWorkflowError.invalidChapterData
        }
        var previousEnd = 0.0
        for chapter in chapters {
            guard !chapter.title.isEmpty,
                  chapter.title.count <= 256,
                  chapter.startSeconds.isFinite,
                  chapter.endSeconds.isFinite,
                  chapter.startSeconds >= previousEnd - 0.002,
                  chapter.endSeconds > chapter.startSeconds,
                  durationSeconds.map({
                      chapter.endSeconds <= $0 + 0.05
                  }) ?? true
            else {
                throw ChapterWorkflowError.invalidChapterData
            }
            previousEnd = chapter.endSeconds
        }
        return chapters
    }

    private static func title(_ value: String?, index: Int) -> String {
        let filtered = String((value ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let bounded = String(
            filtered.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(256)
        )
        return bounded.isEmpty ? "Chapter \(index + 1)" : bounded
    }
}
