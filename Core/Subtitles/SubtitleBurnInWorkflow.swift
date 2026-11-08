import Foundation

struct SubtitleBurnInResult: Equatable, Sendable {
    let fileURL: URL
    let probe: MediaProbeResult
    let renderedCueCount: Int
}

enum SubtitleBurnDurationRoute: String, Equatable, Sendable {
    case verifiedDuration = "verified_duration"
    case verifiedDurationMissing = "verified_duration_missing"
    case verifiedDurationNonFinite = "verified_duration_nonfinite"
    case verifiedDurationNonPositive = "verified_duration_nonpositive"
    case verifiedExtractedTimelineMismatch =
        "verified_extracted_timeline_mismatch"
    case probeMediaFileMismatch = "probe_media_file_mismatch"
    case renderingCuesRejected = "rendering_cues_rejected"
}

enum SubtitleBurnDurationOutcome: String, Equatable, Sendable {
    case acceptedVerifiedEnd = "accepted_verified_end"
    case clippedToVerifiedEnd = "clipped_to_verified_end"
    case acceptedExtractedFallback = "accepted_extracted_fallback"
    case verifiedDurationNonFinite = "verified_duration_nonfinite"
    case verifiedDurationNonPositive = "verified_duration_nonpositive"
    case cueStartsAtOrAfterVerifiedEnd =
        "cue_starts_at_or_after_verified_end"
    case terminalOverrunBeyondBound = "terminal_overrun_beyond_bound"
    case extractedDurationFallbackRejection =
        "extracted_duration_fallback_rejection"
    case probeMediaFileMismatch = "probe_media_file_mismatch"
    case renderingCuesRejected = "rendering_cues_rejected"
}

struct SubtitleBurnDurationDecision: Equatable, Sendable {
    let route: SubtitleBurnDurationRoute
    let outcome: SubtitleBurnDurationOutcome
    let acceptedEndSeconds: Double?

    var isAccepted: Bool { acceptedEndSeconds != nil }
}

final class SubtitleBurnInWorkflow: @unchecked Sendable {
    static let maximumVerifiedMediaCueOverrunSeconds = 1.5
    static let maximumMediaDurationIdentityDifferenceSeconds = 0.5

    private let mediaProcessor: any MediaProcessor
    private let diagnostics: DiagnosticStore?

    init(
        mediaProcessor: any MediaProcessor,
        diagnostics: DiagnosticStore? = nil
    ) {
        self.mediaProcessor = mediaProcessor
        self.diagnostics = diagnostics
    }

    func burn(
        _ prepared: [PreparedSubtitleSidecar],
        into mediaURL: URL,
        inputProbe: MediaProbeResult,
        plan: OutputPlan,
        configuration: DownloadConfiguration,
        metadata: MediaMetadata,
        settings: AppSettings,
        temporaryRoot: URL,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> SubtitleBurnInResult {
        let probeMatchesMedia = inputProbe.fileURL.standardizedFileURL
            == mediaURL.standardizedFileURL
        guard probeMatchesMedia else {
            await recordDurationDiagnostic(
                probe: inputProbe,
                extractedDurationSeconds: metadata.durationSeconds,
                probeMatchesMedia: false,
                cueCount: nil,
                cue: nil,
                route: .probeMediaFileMismatch,
                outcome: .probeMediaFileMismatch,
                level: .error
            )
            throw SubtitlePipelineError.embeddingFailed
        }
        guard configuration.subtitleDelivery == .burnIn,
              !prepared.isEmpty,
              prepared.count <= SubtitleBurnInRenderer.maximumTrackCount,
              configuration.mode != .audioOnly,
              [.mp4, .mov].contains(plan.container),
              let codec = plan.expectedVideoCodec,
              [.h264, .hevc].contains(codec),
              plan.expectedHDR != true
        else {
            throw SubtitlePipelineError.embeddingFailed
        }

        var parsedCues: [(trackIndex: Int, cue: SubtitleRenderCue)] = []
        for (trackIndex, subtitle) in prepared.enumerated() {
            try Task.checkCancellation()
            let data = try Data(
                contentsOf: subtitle.temporaryURL,
                options: [.mappedIfSafe]
            )
            do {
                parsedCues.append(
                    contentsOf: try WebVTTProcessor.renderingCues(data).map {
                        (trackIndex, $0)
                    }
                )
            } catch {
                await recordDurationDiagnostic(
                    probe: inputProbe,
                    extractedDurationSeconds: metadata.durationSeconds,
                    probeMatchesMedia: true,
                    cueCount: nil,
                    cue: nil,
                    route: .renderingCuesRejected,
                    outcome: .renderingCuesRejected,
                    level: .error
                )
                throw error
            }
        }
        guard !parsedCues.isEmpty,
              parsedCues.count <= SubtitleBurnInRenderer.maximumCueCount
        else {
            throw SubtitlePipelineError.embeddingFailed
        }

        var cues: [MediaRenderedSubtitleCue] = []
        var terminalDecision: (
            cue: SubtitleRenderCue,
            decision: SubtitleBurnDurationDecision
        )?
        for parsed in parsedCues {
            let decision = Self.durationDecision(
                for: parsed.cue,
                verifiedMediaDurationSeconds: inputProbe.durationSeconds,
                extractedDurationSeconds: metadata.durationSeconds
            )
            guard let endSeconds = decision.acceptedEndSeconds else {
                await recordDurationDiagnostic(
                    probe: inputProbe,
                    extractedDurationSeconds: metadata.durationSeconds,
                    probeMatchesMedia: true,
                    cueCount: parsedCues.count,
                    cue: parsed.cue,
                    route: decision.route,
                    outcome: decision.outcome,
                    level: .error
                )
                throw SubtitlePipelineError.invalidWebVTT
            }
            cues.append(
                MediaRenderedSubtitleCue(
                    startSeconds: parsed.cue.startSeconds,
                    endSeconds: endSeconds,
                    text: parsed.cue.text,
                    trackIndex: parsed.trackIndex
                )
            )
            if terminalDecision.map({
                parsed.cue.endSeconds > $0.cue.endSeconds
            }) ?? true {
                terminalDecision = (parsed.cue, decision)
            }
        }
        if let terminalDecision {
            await recordDurationDiagnostic(
                probe: inputProbe,
                extractedDurationSeconds: metadata.durationSeconds,
                probeMatchesMedia: true,
                cueCount: parsedCues.count,
                cue: terminalDecision.cue,
                route: terminalDecision.decision.route,
                outcome: terminalDecision.decision.outcome,
                level: .info
            )
        }

        let destination = temporaryRoot.appending(
            path: "output-subtitle-burn.\(plan.fileExtension)"
        )
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        let request = MediaProcessingRequest(
            operationID: operationID,
            operation: .burnSubtitles(mediaURL: mediaURL, cues: cues),
            destinationURL: destination,
            output: MediaOutputSpecification(
                container: plan.container,
                video: .encode(
                    VideoEncodingSettings(
                        codec: codec,
                        bitRate: nil,
                        dimensions: plan.expectedDimensions,
                        frameRate: plan.expectedFrameRate,
                        pixelFormat: codec == .hevc ? "p010le" : "nv12",
                        profile: nil,
                        level: nil,
                        acceleration: .automatic
                    )
                ),
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
            trimming: nil,
            overwriteExisting: false,
            verification: MediaVerificationRequirements(
                expectedContainer: plan.container,
                expectedFileExtension: plan.fileExtension,
                expectedVideoStreams: 1 ... 1,
                expectedAudioStreams: plan.expectedAudioStreams,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: codec,
                expectedAudioCodec: plan.expectedAudioCodec,
                expectedDimensions: plan.expectedDimensions,
                expectedFrameRate: plan.expectedFrameRate,
                frameRateTolerance: 0.12,
                expectedHDR: false,
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
                requiredVerificationClass: .boundedStrong
            )
        )
        let result = try await mediaProcessor.process(
            request,
            progress: progress
        )
        guard let probe = result.probes.first,
              probe.videoStreamCount == 1,
              probe.subtitleStreamCount == 0
        else {
            throw SubtitlePipelineError.embeddingFailed
        }
        return SubtitleBurnInResult(
            fileURL: destination,
            probe: probe,
            renderedCueCount: cues.count
        )
    }

    static func boundedEndSeconds(
        for cue: SubtitleRenderCue,
        verifiedMediaDurationSeconds: Double?,
        extractedDurationSeconds: Double?
    ) throws -> Double {
        let decision = durationDecision(
            for: cue,
            verifiedMediaDurationSeconds: verifiedMediaDurationSeconds,
            extractedDurationSeconds: extractedDurationSeconds
        )
        guard let acceptedEndSeconds = decision.acceptedEndSeconds else {
            throw SubtitlePipelineError.invalidWebVTT
        }
        return acceptedEndSeconds
    }

    static func durationDecision(
        for cue: SubtitleRenderCue,
        verifiedMediaDurationSeconds: Double?,
        extractedDurationSeconds: Double?
    ) -> SubtitleBurnDurationDecision {
        let verifiedDurationTracksExtractedTimeline =
            extractedDurationSeconds.map {
                $0.isFinite
                    && abs((verifiedMediaDurationSeconds ?? $0) - $0)
                        <= maximumMediaDurationIdentityDifferenceSeconds
            } ?? true
        if let duration = verifiedMediaDurationSeconds,
           verifiedDurationTracksExtractedTimeline {
            guard duration.isFinite else {
                return SubtitleBurnDurationDecision(
                    route: .verifiedDurationNonFinite,
                    outcome: .verifiedDurationNonFinite,
                    acceptedEndSeconds: nil
                )
            }
            guard duration > 0 else {
                return SubtitleBurnDurationDecision(
                    route: .verifiedDurationNonPositive,
                    outcome: .verifiedDurationNonPositive,
                    acceptedEndSeconds: nil
                )
            }
            guard cue.startSeconds < duration else {
                return SubtitleBurnDurationDecision(
                    route: .verifiedDuration,
                    outcome: .cueStartsAtOrAfterVerifiedEnd,
                    acceptedEndSeconds: nil
                )
            }
            guard cue.endSeconds
                <= duration + maximumVerifiedMediaCueOverrunSeconds
            else {
                return SubtitleBurnDurationDecision(
                    route: .verifiedDuration,
                    outcome: .terminalOverrunBeyondBound,
                    acceptedEndSeconds: nil
                )
            }
            let endSeconds = min(cue.endSeconds, duration)
            return SubtitleBurnDurationDecision(
                route: .verifiedDuration,
                outcome: endSeconds < cue.endSeconds
                    ? .clippedToVerifiedEnd
                    : .acceptedVerifiedEnd,
                acceptedEndSeconds: endSeconds
            )
        }
        let route: SubtitleBurnDurationRoute
        if let verifiedMediaDurationSeconds {
            if !verifiedMediaDurationSeconds.isFinite {
                route = .verifiedDurationNonFinite
            } else if verifiedMediaDurationSeconds <= 0 {
                route = .verifiedDurationNonPositive
            } else {
                route = .verifiedExtractedTimelineMismatch
            }
        } else {
            route = .verifiedDurationMissing
        }
        guard extractedDurationSeconds.map({
            cue.endSeconds <= $0 + 0.5
        }) ?? true else {
            return SubtitleBurnDurationDecision(
                route: route,
                outcome: .extractedDurationFallbackRejection,
                acceptedEndSeconds: nil
            )
        }
        return SubtitleBurnDurationDecision(
            route: route,
            outcome: .acceptedExtractedFallback,
            acceptedEndSeconds: cue.endSeconds
        )
    }

    private func recordDurationDiagnostic(
        probe: MediaProbeResult,
        extractedDurationSeconds: Double?,
        probeMatchesMedia: Bool,
        cueCount: Int?,
        cue: SubtitleRenderCue?,
        route: SubtitleBurnDurationRoute,
        outcome: SubtitleBurnDurationOutcome,
        level: DiagnosticLogLevel
    ) async {
        let videoDuration = probe.streams.first {
            $0.kind == .video && !$0.disposition.attachedPicture
        }?.durationSeconds
        let audioDuration = probe.streams.first {
            $0.kind == .audio
        }?.durationSeconds
        let detail = [
            "probe_media_identity_equal=\(probeMatchesMedia)",
            "verified_duration=\(Self.diagnosticNumber(probe.durationSeconds))",
            "extracted_duration=\(Self.diagnosticNumber(extractedDurationSeconds))",
            "video_duration=\(Self.diagnosticNumber(videoDuration))",
            "audio_duration=\(Self.diagnosticNumber(audioDuration))",
            "cue_count=\(cueCount.map(String.init) ?? "unavailable")",
            "cue_start=\(Self.diagnosticNumber(cue?.startSeconds))",
            "cue_end=\(Self.diagnosticNumber(cue?.endSeconds))",
            "route=\(route.rawValue)",
            "outcome=\(outcome.rawValue)",
        ].joined(separator: ", ")
        await diagnostics?.record(
            level,
            subsystem: "subtitles",
            event: "subtitle_burn_duration_decision",
            detail: detail
        )
    }

    private static func diagnosticNumber(_ value: Double?) -> String {
        guard let value else { return "missing" }
        guard value.isFinite else {
            if value.isNaN { return "nonfinite_nan" }
            return value.sign == .minus
                ? "nonfinite_negative_infinity"
                : "nonfinite_positive_infinity"
        }
        return String(value)
    }
}
