import Foundation

enum SponsorBlockExecutionError: LocalizedError, Equatable, Sendable {
    case invalidTimeline
    case removesAllContent
    case unsupportedOutput
    case missingProbe
    case invalidAppliedRanges
    case chapterLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidTimeline:
            "The SponsorBlock timeline is invalid."
        case .removesAllContent:
            "The selected SponsorBlock ranges would remove all content."
        case .unsupportedOutput:
            "SponsorBlock removal is unavailable for this output configuration."
        case .missingProbe:
            "The SponsorBlock edit produced no verified media probe."
        case .invalidAppliedRanges:
            "The media editor returned invalid applied SponsorBlock ranges."
        case .chapterLimitExceeded:
            "The transformed SponsorBlock chapter list is too large."
        }
    }
}

struct SponsorBlockTimeline: Equatable, Sendable {
    static let boundaryTolerance = 0.000_5

    let sourceDurationSeconds: Double
    let sourceWindow: MediaTimeRange
    let keptSourceRanges: [MediaTimeRange]

    var finalDurationSeconds: Double {
        keptSourceRanges.reduce(0) { $0 + $1.durationSeconds }
    }

    var removedSourceRanges: [MediaTimeRange] {
        Self.complement(of: keptSourceRanges, inside: sourceWindow)
    }

    static func compose(
        sourceDurationSeconds: Double,
        manualTrim: MediaTrimRange?,
        requestedRemovals: [MediaTimeRange]
    ) throws -> Self {
        guard sourceDurationSeconds.isFinite,
              sourceDurationSeconds > 0
        else {
            throw SponsorBlockExecutionError.invalidTimeline
        }
        let start = manualTrim?.startSeconds ?? 0
        let end = min(
            manualTrim?.endSeconds ?? sourceDurationSeconds,
            sourceDurationSeconds
        )
        guard start.isFinite, end.isFinite,
              start >= 0, end > start,
              end <= sourceDurationSeconds + boundaryTolerance
        else {
            throw SponsorBlockExecutionError.invalidTimeline
        }
        let window = MediaTimeRange(startSeconds: start, endSeconds: end)
        let removals = try normalized(
            requestedRemovals.compactMap { range in
                let lower = max(range.startSeconds, window.startSeconds)
                let upper = min(range.endSeconds, window.endSeconds)
                guard upper - lower > boundaryTolerance else { return nil }
                return MediaTimeRange(
                    startSeconds: lower,
                    endSeconds: upper
                )
            },
            inside: window
        )
        let kept = complement(of: removals, inside: window)
        guard !kept.isEmpty,
              kept.reduce(0, { $0 + $1.durationSeconds })
                > boundaryTolerance
        else {
            throw SponsorBlockExecutionError.removesAllContent
        }
        return Self(
            sourceDurationSeconds: sourceDurationSeconds,
            sourceWindow: window,
            keptSourceRanges: kept
        )
    }

    static func fromAppliedKeptRanges(
        sourceDurationSeconds: Double,
        sourceWindow: MediaTimeRange,
        keptRanges: [MediaTimeRange]
    ) throws -> Self {
        let normalizedRanges = try normalized(
            keptRanges,
            inside: sourceWindow
        )
        guard !normalizedRanges.isEmpty,
              normalizedRanges.reduce(0, { $0 + $1.durationSeconds })
                > boundaryTolerance
        else {
            throw SponsorBlockExecutionError.invalidAppliedRanges
        }
        return Self(
            sourceDurationSeconds: sourceDurationSeconds,
            sourceWindow: sourceWindow,
            keptSourceRanges: normalizedRanges
        )
    }

    func finalTime(forSourceTime sourceTime: Double) -> Double? {
        guard sourceTime.isFinite else { return nil }
        var elapsed = 0.0
        for range in keptSourceRanges {
            if sourceTime >= range.startSeconds - Self.boundaryTolerance,
               sourceTime <= range.endSeconds + Self.boundaryTolerance {
                return elapsed + min(
                    max(sourceTime - range.startSeconds, 0),
                    range.durationSeconds
                )
            }
            elapsed += range.durationSeconds
        }
        return nil
    }

    func transformed(_ sourceRange: MediaTimeRange) -> MediaTimeRange? {
        guard sourceRange.startSeconds.isFinite,
              sourceRange.endSeconds.isFinite,
              sourceRange.endSeconds > sourceRange.startSeconds
        else {
            return nil
        }
        var elapsed = 0.0
        var first: Double?
        var last: Double?
        for kept in keptSourceRanges {
            let lower = max(sourceRange.startSeconds, kept.startSeconds)
            let upper = min(sourceRange.endSeconds, kept.endSeconds)
            if upper - lower > Self.boundaryTolerance {
                first = first ?? elapsed + lower - kept.startSeconds
                last = elapsed + upper - kept.startSeconds
            }
            elapsed += kept.durationSeconds
        }
        guard let first, let last,
              last - first > Self.boundaryTolerance
        else {
            return nil
        }
        return MediaTimeRange(startSeconds: first, endSeconds: last)
    }

    private static func normalized(
        _ ranges: [MediaTimeRange],
        inside window: MediaTimeRange
    ) throws -> [MediaTimeRange] {
        let sorted = try ranges.map { range -> MediaTimeRange in
            guard range.startSeconds.isFinite,
                  range.endSeconds.isFinite,
                  range.startSeconds >= window.startSeconds
                    - boundaryTolerance,
                  range.endSeconds <= window.endSeconds
                    + boundaryTolerance,
                  range.endSeconds - range.startSeconds
                    > boundaryTolerance
            else {
                throw SponsorBlockExecutionError.invalidTimeline
            }
            return MediaTimeRange(
                startSeconds: max(range.startSeconds, window.startSeconds),
                endSeconds: min(range.endSeconds, window.endSeconds)
            )
        }.sorted {
            if $0.startSeconds != $1.startSeconds {
                return $0.startSeconds < $1.startSeconds
            }
            return $0.endSeconds < $1.endSeconds
        }
        var result: [MediaTimeRange] = []
        for range in sorted {
            guard let previous = result.last,
                  range.startSeconds <= previous.endSeconds
                    + boundaryTolerance
            else {
                result.append(range)
                continue
            }
            result[result.count - 1] = MediaTimeRange(
                startSeconds: previous.startSeconds,
                endSeconds: max(previous.endSeconds, range.endSeconds)
            )
        }
        return result
    }

    private static func complement(
        of ranges: [MediaTimeRange],
        inside window: MediaTimeRange
    ) -> [MediaTimeRange] {
        var cursor = window.startSeconds
        var result: [MediaTimeRange] = []
        for range in ranges {
            if range.startSeconds - cursor > boundaryTolerance {
                result.append(
                    MediaTimeRange(
                        startSeconds: cursor,
                        endSeconds: range.startSeconds
                    )
                )
            }
            cursor = max(cursor, range.endSeconds)
        }
        if window.endSeconds - cursor > boundaryTolerance {
            result.append(
                MediaTimeRange(
                    startSeconds: cursor,
                    endSeconds: window.endSeconds
                )
            )
        }
        return result
    }
}

struct SponsorBlockChapterMergeResult: Equatable, Sendable {
    let chapters: [MediaChapter]
    let sponsorBlockChapterCount: Int
}

enum SponsorBlockChapterMerger {
    private enum Kind: Int, Sendable {
        case highlight = 3
        case creator = 0
        case sponsorBlock = 1
        case content = 2
    }

    private struct Candidate: Sendable {
        let key: String
        let title: String
        let range: MediaTimeRange
        let kind: Kind
        let stableIndex: Int
    }

    static func merge(
        creatorChapters: [ExtractedChapter],
        includeCreatorChapters: Bool,
        creatorDurationSeconds: Double? = nil,
        plan: SponsorBlockPlan,
        timeline: SponsorBlockTimeline
    ) throws -> SponsorBlockChapterMergeResult {
        var candidates: [Candidate] = []
        if includeCreatorChapters {
            let normalized = try ChapterWorkflow.normalized(
                creatorChapters,
                // Extractor chapter bounds belong to the metadata timeline.
                // The measured media duration may be slightly shorter. Validate
                // first, then intersect with the actual kept media ranges below.
                durationSeconds: creatorDurationSeconds ?? timeline.sourceDurationSeconds
            )
            for (index, chapter) in normalized.enumerated() {
                guard let range = timeline.transformed(
                    MediaTimeRange(
                        startSeconds: chapter.startSeconds,
                        endSeconds: chapter.endSeconds
                    )
                ) else {
                    continue
                }
                candidates.append(
                    Candidate(
                        key: "creator-\(index)",
                        title: chapter.title,
                        range: range,
                        kind: .creator,
                        stableIndex: index
                    )
                )
            }
        }

        for (index, entry) in plan.entries.enumerated()
        where entry.action == .markAsChapter {
            if entry.categories == [.highlight] {
                // A point is a chapter boundary, never a removable interval.
                guard timeline.keptSourceRanges.contains(where: { entry.startSeconds >= $0.startSeconds && entry.startSeconds < $0.endSeconds }),
                      let point = timeline.finalTime(forSourceTime: entry.startSeconds),
                      point < timeline.finalDurationSeconds - SponsorBlockTimeline.boundaryTolerance else { continue }
                let nextBoundary = candidates.flatMap { [$0.range.startSeconds, $0.range.endSeconds] }
                    .filter { $0 > point + SponsorBlockTimeline.boundaryTolerance }.min() ?? timeline.finalDurationSeconds
                let existing = candidates.filter { point >= $0.range.startSeconds && point < $0.range.endSeconds }
                    .sorted(by: candidateOrder).first
                let title = existing.map { $0.title + " · Highlight" } ?? "Highlight"
                candidates.append(Candidate(key: "highlight-\(entry.sourceSegmentIDs.joined(separator: ","))",
                    title: title, range: .init(startSeconds: point, endSeconds: nextBoundary),
                    kind: .highlight, stableIndex: index))
                continue
            }
            guard let range = timeline.transformed(
                MediaTimeRange(
                    startSeconds: entry.startSeconds,
                    endSeconds: entry.endSeconds
                )
            ) else {
                continue
            }
            let categoryTitle = entry.categories.map(\.title)
                .joined(separator: " + ")
            candidates.append(
                Candidate(
                    key: "sponsor-\(entry.sourceSegmentIDs.joined(separator: ","))",
                    title: "SponsorBlock: \(categoryTitle)",
                    range: range,
                    kind: .sponsorBlock,
                    stableIndex: index
                )
            )
        }

        guard !candidates.isEmpty else {
            return SponsorBlockChapterMergeResult(
                chapters: [],
                sponsorBlockChapterCount: 0
            )
        }

        var boundaries = [0.0, timeline.finalDurationSeconds]
        boundaries.append(contentsOf: candidates.flatMap {
            [$0.range.startSeconds, $0.range.endSeconds]
        })
        boundaries.sort()
        var unique: [Double] = []
        for boundary in boundaries {
            if let last = unique.last,
               abs(last - boundary) <= SponsorBlockTimeline.boundaryTolerance {
                continue
            }
            unique.append(boundary)
        }
        guard unique.count - 1 <= ChapterWorkflow.maximumChapterCount else {
            throw SponsorBlockExecutionError.chapterLimitExceeded
        }

        var intervals: [(candidate: Candidate, range: MediaTimeRange)] = []
        for index in 0 ..< max(0, unique.count - 1) {
            let start = unique[index]
            let end = unique[index + 1]
            guard end - start > SponsorBlockTimeline.boundaryTolerance else {
                continue
            }
            let midpoint = start + (end - start) / 2
            let active = candidates.filter {
                midpoint >= $0.range.startSeconds
                    && midpoint < $0.range.endSeconds
            }.sorted(by: candidateOrder)
            let selected = active.first ?? Candidate(
                key: "content",
                title: "Content",
                range: MediaTimeRange(
                    startSeconds: 0,
                    endSeconds: timeline.finalDurationSeconds
                ),
                kind: .content,
                stableIndex: .max
            )
            let range = MediaTimeRange(
                startSeconds: start,
                endSeconds: end
            )
            if let last = intervals.last,
               last.candidate.key == selected.key {
                intervals[intervals.count - 1].range = MediaTimeRange(
                    startSeconds: last.range.startSeconds,
                    endSeconds: end
                )
            } else {
                intervals.append((selected, range))
            }
        }

        var usedTitles: [String: Int] = [:]
        let chapters = intervals.enumerated().map { index, interval in
            let base = boundedTitle(interval.candidate.title, index: index)
            let count = (usedTitles[base] ?? 0) + 1
            usedTitles[base] = count
            let title = count == 1 ? base : "\(base) (\(count))"
            return MediaChapter(
                title: String(title.prefix(256)),
                startSeconds: interval.range.startSeconds,
                endSeconds: interval.range.endSeconds
            )
        }
        let sponsorBlockChapterCount = intervals.reduce(into: 0) {
            count, interval in
            if interval.candidate.kind == .sponsorBlock || interval.candidate.kind == .highlight {
                count += 1
            }
        }
        return SponsorBlockChapterMergeResult(
            chapters: chapters,
            sponsorBlockChapterCount: sponsorBlockChapterCount
        )
    }

    private static func candidateOrder(
        _ lhs: Candidate,
        _ rhs: Candidate
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue > rhs.kind.rawValue }
        if lhs.range.startSeconds != rhs.range.startSeconds {
            return lhs.range.startSeconds > rhs.range.startSeconds
        }
        if lhs.stableIndex != rhs.stableIndex {
            return lhs.stableIndex < rhs.stableIndex
        }
        return lhs.key < rhs.key
    }

    private static func boundedTitle(_ value: String, index: Int) -> String {
        let filtered = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let bounded = String(
            filtered.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(220)
        )
        return bounded.isEmpty ? "Chapter \(index + 1)" : bounded
    }
}

enum SponsorBlockExecutionSupport {
    static func validate(
        plan sponsorPlan: SponsorBlockPlan,
        policy: SponsorBlockPolicy,
        configuration: DownloadConfiguration,
        outputPlan: OutputPlan
    ) throws {
        guard sponsorPlan.entries.contains(where: { $0.action == .remove })
        else {
            return
        }
        guard configuration.subtitleDelivery == .none,
              !outputPlan.requireArtwork
        else {
            throw SponsorBlockPlanningError.unsupportedExecutionPath
        }
        let hasVideo = outputPlan.expectedVideoStreams.contains(1)
        let hasAudio = outputPlan.expectedAudioStreams.contains(1)
        let audioSupported = !hasAudio || outputPlan.expectedAudioCodec == .aac
        switch policy.removalMode {
        case .accurate:
            if hasVideo {
                guard [.mp4, .mov].contains(outputPlan.container),
                      [.h264, .hevc].contains(outputPlan.expectedVideoCodec),
                      audioSupported,
                      configuration.resolvedTrimMode == .accurate
                else {
                    throw SponsorBlockPlanningError.unsupportedExecutionPath
                }
            } else {
                guard hasAudio,
                      outputPlan.container == .m4a,
                      outputPlan.expectedAudioCodec == .aac,
                      configuration.trimStartSeconds == nil,
                      configuration.trimEndSeconds == nil
                else {
                    throw SponsorBlockPlanningError.unsupportedExecutionPath
                }
            }
        case .fastKeyframe:
            guard hasVideo,
                  [.mp4, .mov].contains(outputPlan.container),
                  [.h264, .hevc].contains(outputPlan.expectedVideoCodec),
                  audioSupported,
                  configuration.trimStartSeconds == nil,
                  configuration.trimEndSeconds == nil
            else {
                throw SponsorBlockPlanningError.unsupportedExecutionPath
            }
        }
    }

    static func fastModeAvailable(
        configuration: DownloadConfiguration,
        metadata: MediaMetadata?
    ) -> Bool {
        guard let metadata,
              configuration.trimStartSeconds == nil,
              configuration.trimEndSeconds == nil,
              configuration.subtitleDelivery == .none,
              let outputPlan = try? OutputCapabilityMatrix.makePlan(
                  configuration: configuration,
                  metadata: metadata
              )
        else {
            return false
        }
        return outputPlan.expectedVideoStreams.contains(1)
            && [.mp4, .mov].contains(outputPlan.container)
            && [.h264, .hevc].contains(outputPlan.expectedVideoCodec)
            && (!outputPlan.expectedAudioStreams.contains(1)
                || outputPlan.expectedAudioCodec == .aac)
            && !outputPlan.requireArtwork
    }
}

struct SponsorBlockExecutionResult: Equatable, Sendable {
    let fileURL: URL
    let probe: MediaProbeResult
    let timeline: SponsorBlockTimeline
    let requestedRemovalRanges: [MediaTimeRange]
    let actualRemovalRanges: [MediaTimeRange]
    let actualMode: SponsorBlockRemovalMode?
    let chapters: [MediaChapter]
    let sponsorBlockChapterCount: Int
}

enum SponsorBlockCheckpointPlanner {
    static func usesTimeline(
        plan: SponsorBlockPlan,
        application: SponsorBlockApplicationRecord?
    ) -> Bool {
        plan.hasOutputMutation
            && (application?.status == .requested
                || application?.status == .applied)
    }

    static func shouldExecute(
        plan: SponsorBlockPlan,
        application: SponsorBlockApplicationRecord?,
        checkpoint: DownloadPipelineCheckpoint?
    ) -> Bool {
        plan.hasOutputMutation
            && application?.status == .requested
            && checkpoint?.sponsorBlockEditVerified != true
    }
}

final class SponsorBlockExecutionWorkflow: @unchecked Sendable {
    static let audioVideoSyncToleranceSeconds = 0.08

    private let mediaProcessor: any MediaProcessor

    init(mediaProcessor: any MediaProcessor) {
        self.mediaProcessor = mediaProcessor
    }

    func execute(
        mediaURL: URL,
        inputProbe: MediaProbeResult,
        sponsorPlan: SponsorBlockPlan,
        policy: SponsorBlockPolicy,
        configuration: DownloadConfiguration,
        outputPlan: OutputPlan,
        metadata: MediaMetadata,
        settings: AppSettings,
        destinationURL: URL,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> SponsorBlockExecutionResult {
        try SponsorBlockExecutionSupport.validate(
            plan: sponsorPlan,
            policy: policy,
            configuration: configuration,
            outputPlan: outputPlan
        )
        let sourceDuration = inputProbe.durationSeconds
            ?? metadata.durationSeconds
        guard let sourceDuration else {
            throw SponsorBlockExecutionError.invalidTimeline
        }
        let requestedRemovals = Self.requestedRemovalRanges(
            sponsorPlan: sponsorPlan,
            sourceDurationSeconds: sourceDuration
        )
        let manualTrim: MediaTrimRange? =
            configuration.trimStartSeconds != nil
                || configuration.trimEndSeconds != nil
            ? MediaTrimRange(
                startSeconds: configuration.trimStartSeconds ?? 0,
                endSeconds: configuration.trimEndSeconds
            )
            : nil
        let requestedTimeline = try SponsorBlockTimeline.compose(
            sourceDurationSeconds: sourceDuration,
            manualTrim: manualTrim,
            requestedRemovals: requestedRemovals
        )
        let needsMediaEdit = !requestedRemovals.isEmpty || manualTrim != nil
        let actualTimeline: SponsorBlockTimeline
        let editedURL: URL
        let editedProbe: MediaProbeResult
        let actualMode: SponsorBlockRemovalMode?

        if needsMediaEdit {
            let editMode: SponsorBlockRemovalMode = requestedRemovals.isEmpty
                ? configuration.resolvedTrimMode.sponsorBlockMode
                : policy.removalMode
            let request = try makeRequest(
                mediaURL: mediaURL,
                destinationURL: destinationURL,
                keptRanges: requestedTimeline.keptSourceRanges,
                mode: editMode,
                plan: outputPlan,
                inputProbe: inputProbe,
                metadata: metadata,
                settings: settings,
                expectedDuration: requestedTimeline.finalDurationSeconds,
                operationID: operationID
            )
            let result = try await mediaProcessor.process(
                request,
                progress: progress
            )
            guard let probe = result.probes.first else {
                throw SponsorBlockExecutionError.missingProbe
            }
            let appliedRanges = result.appliedTimeRanges
                ?? requestedTimeline.keptSourceRanges
            let appliedWindow: MediaTimeRange
            if requestedRemovals.isEmpty,
               editMode == .fastKeyframe,
               let first = appliedRanges.first,
               let last = appliedRanges.last {
                appliedWindow = MediaTimeRange(
                    startSeconds: first.startSeconds,
                    endSeconds: last.endSeconds
                )
            } else {
                appliedWindow = requestedTimeline.sourceWindow
            }
            actualTimeline = try SponsorBlockTimeline.fromAppliedKeptRanges(
                sourceDurationSeconds: sourceDuration,
                sourceWindow: appliedWindow,
                keptRanges: appliedRanges
            )
            guard let duration = probe.durationSeconds,
                  abs(duration - actualTimeline.finalDurationSeconds)
                    <= (editMode == .accurate ? 0.08 : 1.0)
            else {
                throw MediaProcessorError.verificationMismatch(
                    "The SponsorBlock output duration does not match the applied timeline."
                )
            }
            try probe.verifyAudioVideoSync(
                toleranceSeconds: Self.audioVideoSyncToleranceSeconds
            )
            editedURL = destinationURL
            editedProbe = probe
            actualMode = requestedRemovals.isEmpty ? nil : editMode
        } else {
            actualTimeline = requestedTimeline
            editedURL = mediaURL
            editedProbe = inputProbe
            actualMode = nil
        }

        let merged = try SponsorBlockChapterMerger.merge(
            creatorChapters: metadata.chapters,
            includeCreatorChapters: configuration.preserveChapters
                || configuration.writeChapters
                || configuration.splitChapters,
            creatorDurationSeconds: metadata.durationSeconds,
            plan: sponsorPlan,
            timeline: actualTimeline
        )
        return SponsorBlockExecutionResult(
            fileURL: editedURL,
            probe: editedProbe,
            timeline: actualTimeline,
            requestedRemovalRanges: requestedTimeline.removedSourceRanges,
            actualRemovalRanges: actualTimeline.removedSourceRanges,
            actualMode: actualMode,
            chapters: merged.chapters,
            sponsorBlockChapterCount: merged.sponsorBlockChapterCount
        )
    }

    static func requestedRemovalRanges(
        sponsorPlan: SponsorBlockPlan,
        sourceDurationSeconds: Double
    ) -> [MediaTimeRange] {
        sponsorPlan.entries.compactMap { entry in
            guard entry.action == .remove else { return nil }
            // Launch planning clamps service timing to the analyzed duration.
            // Reconcile that same bounded end boundary with the verified local
            // duration so a harmless probe delta cannot create a false tail.
            let trailingGap = sourceDurationSeconds - entry.endSeconds
            let reconciledEnd = trailingGap >= 0
                && trailingGap
                    <= SponsorBlockTiming.maximumEndBoundaryDifferenceSeconds
                ? sourceDurationSeconds
                : entry.endSeconds
            return MediaTimeRange(
                startSeconds: entry.startSeconds,
                endSeconds: reconciledEnd
            )
        }
    }

    private struct AccurateAACAudioFacts {
        let encodingSettings: AudioEncodingSettings
        let sampleRate: Int
        let channelCount: Int
    }

    private func accurateAACAudioFacts(
        plan: OutputPlan,
        inputProbe: MediaProbeResult
    ) throws -> AccurateAACAudioFacts {
        let audioStreams = inputProbe.streams.filter { $0.kind == .audio }
        guard plan.expectedAudioCodec == .aac,
              audioStreams.count == 1,
              let audioStream = audioStreams.first,
              MediaCodec.aac.matches(probeCodec: audioStream.codecName),
              let sampleRate = audioStream.audio?.sampleRate,
              sampleRate > 0,
              let channelCount = audioStream.audio?.channelCount,
              channelCount > 0,
              plan.audioEncodingSettings?.codec == nil
                || plan.audioEncodingSettings?.codec == .aac
        else {
            throw MediaProcessorError.invalidRequest(
                "Accurate video removal requires known AAC audio facts."
            )
        }
        let sourceBitRate = audioStream.bitRate.flatMap {
            $0 > 0 ? $0 : nil
        }
        return AccurateAACAudioFacts(
            encodingSettings: AudioEncodingSettings(
                codec: .aac,
                bitRate: sourceBitRate,
                quality: plan.audioEncodingSettings?.quality,
                sampleRate: sampleRate,
                channelLayout: plan.audioEncodingSettings?.channelLayout
                    ?? .preserve,
                loudnessNormalization: plan.audioEncodingSettings?
                    .loudnessNormalization
            ),
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    private func makeRequest(
        mediaURL: URL,
        destinationURL: URL,
        keptRanges: [MediaTimeRange],
        mode: SponsorBlockRemovalMode,
        plan: OutputPlan,
        inputProbe: MediaProbeResult,
        metadata: MediaMetadata,
        settings: AppSettings,
        expectedDuration: Double,
        operationID: UUID
    ) throws -> MediaProcessingRequest {
        let hasVideo = plan.expectedVideoStreams.contains(1)
        let hasAudio = plan.expectedAudioStreams.contains(1)
        let videoPolicy: VideoOutputPolicy
        if hasVideo, mode == .accurate,
           let codec = plan.expectedVideoCodec {
            videoPolicy = .encode(
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
        } else {
            videoPolicy = hasVideo ? .copy : .remove
        }
        let accurateAACAudioFacts = hasAudio && mode == .accurate
            ? try accurateAACAudioFacts(plan: plan, inputProbe: inputProbe)
            : nil
        let audioPolicy: AudioOutputPolicy
        if let accurateAACAudioFacts {
            audioPolicy = .encode(accurateAACAudioFacts.encodingSettings)
        } else {
            audioPolicy = hasAudio ? .copy : .remove
        }
        let metadataPolicy = ConversionMetadataPolicy(
            metadata: metadata,
            preserve: settings.preserveMetadata,
            container: plan.container
        )
        return MediaProcessingRequest(
            operationID: operationID,
            operation: .removeRanges(
                mediaURL: mediaURL,
                mode: mode,
                keptRanges: keptRanges
            ),
            destinationURL: destinationURL,
            output: MediaOutputSpecification(
                container: plan.container,
                video: videoPolicy,
                audio: audioPolicy,
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
                expectedVideoStreams: plan.expectedVideoStreams,
                expectedAudioStreams: plan.expectedAudioStreams,
                expectedSubtitleStreams: 0 ... 0,
                expectedVideoCodec: plan.expectedVideoCodec,
                expectedAudioCodec: plan.expectedAudioCodec,
                expectedDimensions: plan.expectedDimensions,
                expectedFrameRate: plan.expectedFrameRate,
                frameRateTolerance: 0.12,
                expectedHDR: plan.expectedHDR,
                expectedAudioSampleRate: accurateAACAudioFacts?.sampleRate
                    ?? plan.expectedSampleRate,
                expectedAudioChannelCount: accurateAACAudioFacts?.channelCount
                    ?? plan.expectedChannelCount,
                expectedDurationSeconds: expectedDuration,
                durationToleranceSeconds: mode == .accurate ? 0.08 : 1.0,
                expectedAudioBitRate: nil,
                audioBitRateToleranceFraction:
                    ConversionCapabilityMatrix.bitRateToleranceFraction(
                        for: plan.expectedAudioCodec
                    ),
                expectedChapterCount: 0 ... 0,
                requireArtwork: false,
                requireMetadataKeys: metadataPolicy.requiredKeys,
                expectedMetadataValues: metadataPolicy.expectedValues,
                forbiddenMetadataKeys: metadataPolicy.forbiddenKeys,
                requiredVerificationClass: mode == .accurate
                    ? .boundedStrong
                    : .fastStructural
            )
        )
    }
}

private extension MediaTrimMode {
    var sponsorBlockMode: SponsorBlockRemovalMode {
        switch self {
        case .accurate: .accurate
        case .fastKeyframe: .fastKeyframe
        }
    }
}
