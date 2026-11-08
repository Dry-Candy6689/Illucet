import Foundation

struct EmbeddedSubtitleIdentity: Equatable, Sendable {
    let selection: SubtitleTrackSelection
    let codec: MediaCodec
    let languageCode: String
    let title: String
    let isDefault: Bool
}

struct SubtitleEmbeddingResult: Equatable, Sendable {
    let fileURL: URL
    let probe: MediaProbeResult
    let identities: [EmbeddedSubtitleIdentity]
}

final class SubtitleEmbeddingWorkflow: @unchecked Sendable {
    private let mediaProcessor: any MediaProcessor

    init(mediaProcessor: any MediaProcessor) {
        self.mediaProcessor = mediaProcessor
    }

    func embed(
        _ prepared: [PreparedSubtitleSidecar],
        into mediaURL: URL,
        plan: OutputPlan,
        configuration: DownloadConfiguration,
        metadata: MediaMetadata,
        settings: AppSettings,
        temporaryRoot: URL,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> SubtitleEmbeddingResult {
        guard configuration.subtitleDelivery == .embed,
              !prepared.isEmpty,
              configuration.mode != .audioOnly,
              let subtitleCodec = Self.codec(for: plan.container)
        else {
            throw SubtitlePipelineError.embeddingFailed
        }
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        var currentURL = mediaURL
        var identities: [EmbeddedSubtitleIdentity] = []
        var finalProbe: MediaProbeResult?

        for (index, preparedSubtitle) in prepared.enumerated() {
            try Task.checkCancellation()
            let identity = Self.identity(
                preparedSubtitle.selection,
                codec: subtitleCodec,
                isDefault: index == 0
            )
            identities.append(identity)
            let destination = temporaryRoot.appending(
                path: "output-subtitle-\(index).\(plan.fileExtension)"
            )
            let request = MediaProcessingRequest(
                operationID: operationID,
                operation: .embedSubtitles(
                    mediaURL: currentURL,
                    subtitles: [
                        MediaSubtitleInput(
                            fileURL: preparedSubtitle.temporaryURL,
                            languageCode: identity.languageCode,
                            title: identity.title,
                            isAutomatic:
                                preparedSubtitle.selection.automatic,
                            isDefault: identity.isDefault,
                            isForced: false
                        ),
                    ]
                ),
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
                    subtitleCodec: subtitleCodec,
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
                    expectedFileExtension: plan.fileExtension,
                    expectedVideoStreams: plan.expectedVideoStreams,
                    expectedAudioStreams: plan.expectedAudioStreams,
                    expectedSubtitleStreams: identities.count ... identities.count,
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
                    expectedAudioBitRate: nil,
                    audioBitRateToleranceFraction: 0.08,
                    expectedChapterCount: 0 ... 0,
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
                throw SubtitlePipelineError.embeddingFailed
            }
            try Self.verify(
                probe,
                identities: identities
            )
            if currentURL != mediaURL {
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentURL = destination
            finalProbe = probe
        }
        guard let finalProbe else {
            throw SubtitlePipelineError.embeddingFailed
        }
        return SubtitleEmbeddingResult(
            fileURL: currentURL,
            probe: finalProbe,
            identities: identities
        )
    }

    static func codec(for container: MediaContainer) -> MediaCodec? {
        switch container {
        case .mp4, .mov: .movText
        case .matroska: .subRip
        case .webM: .webVTT
        default: nil
        }
    }

    static func identity(
        _ selection: SubtitleTrackSelection,
        codec: MediaCodec,
        isDefault: Bool
    ) -> EmbeddedSubtitleIdentity {
        let origin = selection.automatic ? "Automatic" : "Manual"
        let language = String(selection.language.prefix(96))
        let suffix = String(selection.trackID.suffix(8))
            + "-"
            + String(selection.formatID.suffix(8))
        return EmbeddedSubtitleIdentity(
            selection: selection,
            codec: codec,
            languageCode: containerLanguageCode(selection.language),
            title: "\(language) • \(origin) • \(suffix)",
            isDefault: isDefault
        )
    }

    static func verify(
        _ probe: MediaProbeResult,
        identities: [EmbeddedSubtitleIdentity]
    ) throws {
        let streams = probe.streams.filter { $0.kind == .subtitle }
        guard streams.count == identities.count else {
            throw SubtitlePipelineError.embeddingFailed
        }
        for (stream, identity) in zip(streams, identities) {
            guard
                identity.codec.matches(probeCodec: stream.codecName),
                stream.subtitle?.title == identity.title,
                stream.subtitle?.languageCode == identity.languageCode,
                stream.disposition.isDefault == identity.isDefault,
                !stream.disposition.forced
            else {
                throw SubtitlePipelineError.embeddingFailed
            }
        }
    }

    static func containerLanguageCode(_ source: String) -> String {
        let normalized = source.lowercased().split(
            whereSeparator: { $0 == "-" || $0 == "_" }
        ).first.map(String.init) ?? ""
        if normalized.count == 3,
           normalized.utf8.allSatisfy({ (97...122).contains($0) }) {
            return normalized
        }
        let ISO6392: [String: String] = [
            "ar": "ara", "de": "deu", "en": "eng", "es": "spa",
            "fr": "fra", "hi": "hin", "it": "ita", "ja": "jpn",
            "ko": "kor", "nl": "nld", "pl": "pol", "pt": "por",
            "ru": "rus", "sv": "swe", "tr": "tur", "uk": "ukr",
            "vi": "vie", "zh": "zho",
        ]
        return ISO6392[normalized] ?? "und"
    }
}
