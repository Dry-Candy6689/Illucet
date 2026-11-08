import Foundation

enum NativeFFmpegProgressMapping {
    static func stage(_ value: String?) -> MediaProcessingStage {
        guard let value else { return .preparing }
        if value.contains("probe") { return .probing }
        if value.contains("artwork") { return .attachingArtwork }
        if value.contains("subtitle-embed") { return .embeddingSubtitles }
        if value.contains("chapters") { return .writingChapters }
        if value.contains("merge")
            || value.contains("remux")
            || value == "audio-copy"
            || value == "video-only" {
            return .muxing
        }
        if value.hasPrefix("audio-")
            || value.contains("video-transcode")
            || value.contains("compatible") {
            return .encoding
        }
        return .readingInput
    }
}

private final class NativeFFmpegProgressBox: @unchecked Sendable {
    let operationID: UUID
    let handler: MediaProcessingProgressHandler

    init(
        operationID: UUID,
        handler: @escaping MediaProcessingProgressHandler
    ) {
        self.operationID = operationID
        self.handler = handler
    }

    func report(stage: String?, fraction: Double) -> Bool {
        handler(
            MediaProcessingProgress(
                operationID: operationID,
                stage: NativeFFmpegProgressMapping.stage(stage),
                completedFraction: fraction >= 0
                    ? min(max(fraction, 0), 1)
                    : nil,
                processedMediaSeconds: nil,
                totalMediaSeconds: nil,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        return false
    }

}

private func nativeFFmpegProgressCallback(
    _ stage: UnsafePointer<CChar>?,
    _ progress: Double,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 1 }
    let box = Unmanaged<NativeFFmpegProgressBox>
        .fromOpaque(context)
        .takeUnretainedValue()
    let stageText = stage.map { String(cString: $0) }
    return box.report(stage: stageText, fraction: progress) ? 1 : 0
}

private final class NativeFFmpegOperation: @unchecked Sendable {
    let job: OpaquePointer
    let box: NativeFFmpegProgressBox

    init?(
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) {
        box = NativeFFmpegProgressBox(
            operationID: operationID,
            handler: progress
        )
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let job = illucet_ffmpeg_job_create(
            nativeFFmpegProgressCallback,
            context
        ) else {
            return nil
        }
        self.job = job
    }

    deinit {
        illucet_ffmpeg_job_destroy(job)
    }

    func cancel() {
        illucet_ffmpeg_job_cancel(job)
    }
}

private struct NativeFFmpegExecutionReport: Sendable {
    var usedVideoToolbox = false
    var usedSoftwareFallback = false
    var videoEncoderName: String?
    var appliedLoudnessNormalization = false
    var appliedTimeRanges: [MediaTimeRange]?
}

actor NativeFFmpegMediaProcessor: MediaProcessor {
    private var active: [UUID: NativeFFmpegOperation] = [:]
    private var activeBurns: [
        UUID: Task<NativeFFmpegExecutionReport, any Error>
    ] = [:]
    private let fileManager = FileManager.default

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        try validate(request)
        if fileManager.fileExists(atPath: request.destinationURL.path) {
            guard request.overwriteExisting else {
                throw MediaProcessorError.outputAlreadyExists(
                    request.destinationURL
                )
            }
            try fileManager.removeItem(at: request.destinationURL)
        }
        try fileManager.createDirectory(
            at: request.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try BackgroundFileProtection.protectJobLocal(request.destinationURL.deletingLastPathComponent(), jobID: request.operationID, fileManager: fileManager)
        let stagedURL = Self.stagedURL(for: request.destinationURL)
        var cleanupURLs: [URL] = []
        let started = ContinuousClock.now
        do {
            let execution: NativeFFmpegExecutionReport
            if case let .burnSubtitles(mediaURL, cues) = request.operation {
                guard case let .encode(settings) = request.output.video else {
                    throw MediaProcessorError.invalidRequest(
                        "Rendered subtitles require an encoded video output."
                    )
                }
                // AVAssetExportSession can drop required QuickTime/iTunes tags.
                // Keep rendered pixels private; the typed native remux owns publication.
                let burnRenderURL = Self.stagedURL(
                    for: request.destinationURL
                )
                cleanupURLs.append(burnRenderURL)
                let burn = Task.detached(priority: .utility) {
                    try await SubtitleBurnInRenderer.render(
                        inputURL: mediaURL,
                        outputURL: burnRenderURL,
                        cues: cues,
                        codec: settings.codec,
                        container: request.output.container,
                        metadata: .empty,
                        preserveMetadata: false,
                        operationID: request.operationID,
                        progress: progress
                    )
                    var report = NativeFFmpegExecutionReport()
                    report.videoEncoderName = "AVAssetExportSession"
                    return report
                }
                activeBurns[request.operationID] = burn
                let burnExecution = try await withTaskCancellationHandler {
                    try await burn.value
                } onCancel: {
                    burn.cancel()
                }
                activeBurns[request.operationID] = nil
                guard let native = NativeFFmpegOperation(
                    operationID: request.operationID,
                    progress: progress
                ) else {
                    throw MediaProcessorError.nativeFailure(
                        "Could not create a native metadata publication job."
                    )
                }
                active[request.operationID] = native
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try Self.republishMetadata(
                            request,
                            inputURL: burnRenderURL,
                            destinationURL: stagedURL,
                            native: native
                        )
                    }.value
                } onCancel: {
                    native.cancel()
                }
                active[request.operationID] = nil
                try fileManager.removeItem(at: burnRenderURL)
                cleanupURLs.removeAll { $0 == burnRenderURL }
                execution = burnExecution
            } else if case let .trim(mediaURL, mode) = request.operation {
                guard let range = request.trimming,
                      let codec = request.verification.expectedVideoCodec
                else {
                    throw MediaProcessorError.invalidRequest(
                        "A trim request requires a range and video codec."
                    )
                }
                let trimEditURL = Self.stagedURL(
                    for: request.destinationURL
                )
                cleanupURLs.append(trimEditURL)
                let edit = Task.detached(priority: .utility) {
                    try await AVFoundationMediaEditor.trim(
                        inputURL: mediaURL,
                        outputURL: trimEditURL,
                        range: range,
                        mode: mode,
                        codec: codec,
                        videoBitRate: request.output.video.bitRate,
                        frameRate: request.verification.expectedFrameRate,
                        isHDR: request.verification.expectedHDR,
                        audioSampleRate: request.verification
                            .expectedAudioSampleRate,
                        audioChannelCount: request.verification
                            .expectedAudioChannelCount,
                        audioBitRate: request.output.audio.bitRate,
                        container: request.output.container,
                        metadata: .empty,
                        preserveMetadata: false,
                        operationID: request.operationID,
                        progress: progress
                    )
                    var report = NativeFFmpegExecutionReport()
                    report.videoEncoderName = mode == .accurate
                        ? "AVAssetWriter"
                        : nil
                    return report
                }
                activeBurns[request.operationID] = edit
                let editExecution = try await withTaskCancellationHandler {
                    try await edit.value
                } onCancel: {
                    edit.cancel()
                }
                activeBurns[request.operationID] = nil
                guard let native = NativeFFmpegOperation(
                    operationID: request.operationID,
                    progress: progress
                ) else {
                    throw MediaProcessorError.nativeFailure(
                        "Could not create a native metadata publication job."
                    )
                }
                active[request.operationID] = native
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try Self.republishMetadata(
                            request,
                            inputURL: trimEditURL,
                            destinationURL: stagedURL,
                            native: native
                        )
                    }.value
                } onCancel: {
                    native.cancel()
                }
                active[request.operationID] = nil
                try fileManager.removeItem(at: trimEditURL)
                cleanupURLs.removeAll { $0 == trimEditURL }
                execution = editExecution
            } else if case let .removeRanges(
                mediaURL,
                mode,
                keptRanges
            ) = request.operation {
                let rangeEditURL = Self.stagedURL(
                    for: request.destinationURL
                )
                cleanupURLs.append(rangeEditURL)
                let edit = Task.detached(priority: .utility) {
                    let result = try await AVFoundationMediaEditor
                        .removeRanges(
                            inputURL: mediaURL,
                            outputURL: rangeEditURL,
                            keptRanges: keptRanges,
                            mode: mode,
                            codec: request.verification.expectedVideoCodec,
                            videoBitRate: request.output.video.bitRate,
                            frameRate: request.verification
                                .expectedFrameRate,
                            isHDR: request.verification.expectedHDR,
                            audioSampleRate: request.verification
                                .expectedAudioSampleRate,
                            audioChannelCount: request.verification
                                .expectedAudioChannelCount,
                            audioBitRate: request.output.audio.bitRate,
                            container: request.output.container,
                            metadata: .empty,
                            preserveMetadata: false,
                            operationID: request.operationID,
                            progress: progress
                        )
                    var report = NativeFFmpegExecutionReport()
                    report.videoEncoderName = mode == .accurate
                        && request.verification.expectedVideoCodec != nil
                        ? "AVAssetWriter"
                        : nil
                    report.appliedTimeRanges = result.appliedKeptRanges
                    return report
                }
                activeBurns[request.operationID] = edit
                let editExecution = try await withTaskCancellationHandler {
                    try await edit.value
                } onCancel: {
                    edit.cancel()
                }
                activeBurns[request.operationID] = nil
                guard let native = NativeFFmpegOperation(
                    operationID: request.operationID,
                    progress: progress
                ) else {
                    throw MediaProcessorError.nativeFailure(
                        "Could not create a native metadata publication job."
                    )
                }
                active[request.operationID] = native
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try Self.republishMetadata(
                            request,
                            inputURL: rangeEditURL,
                            destinationURL: stagedURL,
                            native: native
                        )
                    }.value
                } onCancel: {
                    native.cancel()
                }
                active[request.operationID] = nil
                try fileManager.removeItem(at: rangeEditURL)
                cleanupURLs.removeAll { $0 == rangeEditURL }
                execution = editExecution
            } else {
                guard let native = NativeFFmpegOperation(
                    operationID: request.operationID,
                    progress: progress
                ) else {
                    throw MediaProcessorError.nativeFailure(
                        "Could not create a native FFmpeg job."
                    )
                }
                active[request.operationID] = native
                execution = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .utility) {
                        try Self.runNative(
                            request,
                            destinationURL: stagedURL,
                            native: native
                        )
                    }.value
                } onCancel: {
                    native.cancel()
                }
                active[request.operationID] = nil
            }
            progress(
                MediaProcessingProgress(
                    operationID: request.operationID,
                    stage: .probing,
                    completedFraction: nil,
                    processedMediaSeconds: nil,
                    totalMediaSeconds: nil,
                    processedBytes: nil,
                    estimatedRemainingSeconds: nil
                )
            )
            let stagedProbe = try await probe(
                stagedURL,
                verificationClass: request.verification
                    .requiredVerificationClass,
                operationID: request.operationID
            )
            let verification: MediaVerificationRequirements
            if let applied = execution.appliedTimeRanges {
                let duration = applied.reduce(0) {
                    $0 + $1.durationSeconds
                }
                let tolerance = request.operation.isAccurateRangeEdit
                    ? 0.08
                    : 1.0
                verification = request.verification.withExpectedDuration(
                    duration,
                    tolerance: tolerance
                )
            } else {
                verification = request.verification
            }
            progress(
                MediaProcessingProgress(
                    operationID: request.operationID,
                    stage: .verifying,
                    completedFraction: nil,
                    processedMediaSeconds: nil,
                    totalMediaSeconds: nil,
                    processedBytes: nil,
                    estimatedRemainingSeconds: nil
                )
            )
            try MediaOutputVerifier.verify(
                stagedProbe,
                requirements: verification
            )
            guard !fileManager.fileExists(
                atPath: request.destinationURL.path
            ) else {
                throw MediaProcessorError.outputAlreadyExists(
                    request.destinationURL
                )
            }
            // Both URLs are siblings, so this publishes the verified file with
            // one same-volume rename. The final name never points at an
            // unverified or partially written output.
            try fileManager.moveItem(
                at: stagedURL,
                to: request.destinationURL
            )
            try BackgroundFileProtection.protectJobLocal(request.destinationURL, jobID: request.operationID, fileManager: fileManager)
            let probe = Self.relocated(
                stagedProbe,
                to: request.destinationURL
            )
            let elapsed = started.duration(to: .now)
            var result = MediaProcessingResult(
                operationID: request.operationID,
                outputURLs: [request.destinationURL],
                probes: [probe],
                usedStreamCopy: Self.usedStreamCopy(request.operation),
                usedHardwareAcceleration: execution.usedVideoToolbox,
                usedSoftwareFallback: execution.usedSoftwareFallback,
                videoEncoderName: execution.videoEncoderName,
                appliedLoudnessNormalization:
                    execution.appliedLoudnessNormalization,
                elapsedSeconds: Self.seconds(elapsed)
            )
            result.appliedTimeRanges = execution.appliedTimeRanges
            return result
        } catch {
            active[request.operationID] = nil
            activeBurns[request.operationID] = nil
            try? fileManager.removeItem(at: stagedURL)
            for URL in cleanupURLs {
                try? fileManager.removeItem(at: URL)
            }
            if Task.isCancelled {
                throw MediaProcessorError.cancelled
            }
            throw error
        }
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        try await probe(
            fileURL,
            verificationClass: verificationClass,
            operationID: UUID()
        )
    }

    private func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass,
        operationID: UUID
    ) async throws -> MediaProbeResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw MediaProcessorError.inputUnavailable(fileURL)
        }
        guard let native = NativeFFmpegOperation(
            operationID: operationID,
            progress: { _ in }
        ) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create a native FFmpeg probe job."
            )
        }
        active[operationID] = native
        do {
            let raw = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try Self.runProbe(
                        fileURL,
                        verificationClass: verificationClass,
                        native: native
                    )
                }.value
            } onCancel: {
                native.cancel()
            }
            active[operationID] = nil
            return Self.mapProbe(raw, fileURL: fileURL)
        } catch {
            active[operationID] = nil
            if Task.isCancelled {
                throw MediaProcessorError.cancelled
            }
            throw error
        }
    }

    func cancel(operationID: UUID) {
        active[operationID]?.cancel()
        activeBurns[operationID]?.cancel()
    }

    private func validate(_ request: MediaProcessingRequest) throws {
        for input in request.operation.inputURLs {
            guard fileManager.fileExists(atPath: input.path) else {
                throw MediaProcessorError.inputUnavailable(input)
            }
        }
    }

    private static func runNative(
        _ request: MediaProcessingRequest,
        destinationURL: URL,
        native: NativeFFmpegOperation
    ) throws -> NativeFFmpegExecutionReport {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status: IllucetFFmpegStatus
        var execution = NativeFFmpegExecutionReport()
        switch request.operation {
        case let .merge(videoURL, audioURL):
            status = try streamCopy(
                request,
                mode: ILLUCET_STREAM_COPY_MERGE,
                firstURL: videoURL,
                secondURL: audioURL,
                destinationURL: destinationURL,
                native: native,
                rawError: &rawError
            )
        case let .remux(inputURL):
            status = try streamCopy(
                request,
                mode: ILLUCET_STREAM_COPY_REMUX,
                firstURL: inputURL,
                secondURL: nil,
                destinationURL: destinationURL,
                native: native,
                rawError: &rawError
            )
        case let .extractAudio(inputURL):
            status = try streamCopy(
                request,
                mode: ILLUCET_STREAM_COPY_EXTRACT_AUDIO,
                firstURL: inputURL,
                secondURL: nil,
                destinationURL: destinationURL,
                native: native,
                rawError: &rawError
            )
        case let .transcodeAudio(inputURL):
            guard
                case let .encode(settings) = request.output.audio,
                let codec = nativeAudioCodec(settings.codec),
                let container = nativeContainer(request.output.container)
            else {
                throw MediaProcessorError.codecUnavailable(
                    request.output.audio.codec ?? MediaCodec(rawValue: "unknown")
                )
            }
            status = withNativeMetadata(request) { metadata in
                var nativeRequest = IllucetAudioTranscodeRequest(
                    codec: codec,
                    container: container,
                    rate_control: nativeAudioRateControl(settings),
                    bitrate_bits_per_second: Int32(settings.bitRate ?? 0),
                    quality: Int32(settings.quality?.value ?? 0),
                    sample_rate: Int32(settings.sampleRate ?? 0),
                    channels: nativeChannelCount(settings.channelLayout),
                    normalize_loudness:
                        settings.loudnessNormalization != nil,
                    integrated_loudness_lufs:
                        settings.loudnessNormalization?
                            .integratedLoudnessLUFS ?? -16,
                    loudness_range_lu:
                        settings.loudnessNormalization?.loudnessRangeLU ?? 11,
                    true_peak_dbtp:
                        settings.loudnessNormalization?.truePeakDBTP ?? -1.5,
                    fast_start: request.output.fastStart,
                    metadata: metadata
                )
                return inputURL.path.withCString { input in
                    destinationURL.path.withCString { output in
                        illucet_ffmpeg_transcode_audio(
                            input,
                            output,
                            &nativeRequest,
                            native.job,
                            &rawError
                        )
                    }
                }
            }
            execution.appliedLoudnessNormalization =
                settings.loudnessNormalization != nil
        case let .removeAudio(inputURL):
            status = try streamCopy(
                request,
                mode: ILLUCET_STREAM_COPY_VIDEO_ONLY,
                firstURL: inputURL,
                secondURL: nil,
                destinationURL: destinationURL,
                native: native,
                rawError: &rawError
            )
        case let .transcodeVideo(inputURL):
            guard
                case let .encode(settings) = request.output.video,
                let codec = nativeVideoCodec(settings.codec),
                let container = nativeContainer(request.output.container)
            else {
                throw MediaProcessorError.codecUnavailable(
                    request.output.video.codec
                        ?? MediaCodec(rawValue: "unknown")
                )
            }
            var nativeReport = IllucetVideoTranscodeReport()
            status = withNativeMetadata(request) { metadata in
                let rate = nativeFrameRate(settings.frameRate)
                var nativeRequest = IllucetVideoTranscodeRequest(
                    codec: codec,
                    container: container,
                    bitrate_bits_per_second:
                        Int32(settings.bitRate ?? 0),
                    width: Int32(settings.dimensions?.width ?? 0),
                    height: Int32(settings.dimensions?.height ?? 0),
                    frame_rate_numerator: rate.numerator,
                    frame_rate_denominator: rate.denominator,
                    dynamic_range:
                        nativeDynamicRange(request.output.dynamicRange),
                    acceleration:
                        nativeAcceleration(settings.acceleration),
                    copy_audio: request.output.audio == .copy,
                    fast_start: request.output.fastStart,
                    metadata: metadata
                )
                return inputURL.path.withCString { input in
                    destinationURL.path.withCString { output in
                        illucet_ffmpeg_transcode_video(
                            input,
                            output,
                            &nativeRequest,
                            &nativeReport,
                            native.job,
                            &rawError
                        )
                    }
                }
            }
            execution.usedVideoToolbox =
                nativeReport.used_videotoolbox
            execution.usedSoftwareFallback =
                nativeReport.used_software_fallback
            execution.videoEncoderName = nativeEncoderName(nativeReport)
        case let .attachArtwork(mediaURL, artworkURL):
            guard let container = nativeContainer(request.output.container)
            else {
                throw MediaProcessorError.invalidRequest(
                    "The requested artwork container is unavailable."
                )
            }
            status = withNativeMetadata(request) { metadata in
                var nativeMetadata = metadata
                return mediaURL.path.withCString { media in
                    artworkURL.path.withCString { artwork in
                        destinationURL.path.withCString { output in
                            illucet_ffmpeg_attach_artwork(
                                media,
                                artwork,
                                output,
                                container,
                                request.output.fastStart,
                                &nativeMetadata,
                                native.job,
                                &rawError
                            )
                        }
                    }
                }
            }
        case let .embedSubtitles(mediaURL, subtitles):
            guard
                subtitles.count == 1,
                let subtitle = subtitles.first,
                let container = nativeContainer(request.output.container),
                let codec = request.output.subtitleCodec.flatMap(
                    nativeSubtitleCodec
                )
            else {
                throw MediaProcessorError.invalidRequest(
                    "Subtitle embedding requires one typed subtitle input and a compatible output codec."
                )
            }
            status = withNativeMetadata(request) { metadata in
                withOptionalCString(subtitle.languageCode) { language in
                    withOptionalCString(subtitle.title) { title in
                        var nativeRequest = IllucetSubtitleMuxRequest(
                            container: container,
                            codec: codec,
                            fast_start: request.output.fastStart,
                            metadata: metadata,
                            language: language,
                            title: title,
                            automatic: subtitle.isAutomatic,
                            is_default: subtitle.isDefault,
                            is_forced: subtitle.isForced
                        )
                        return mediaURL.path.withCString { media in
                            subtitle.fileURL.path.withCString { subtitlePath in
                                destinationURL.path.withCString { output in
                                    illucet_ffmpeg_embed_subtitle(
                                        media,
                                        subtitlePath,
                                        output,
                                        &nativeRequest,
                                        native.job,
                                        &rawError
                                    )
                                }
                            }
                        }
                    }
                }
            }
        case .burnSubtitles:
            throw MediaProcessorError.invalidRequest(
                "Rendered subtitles use the bounded Swift media renderer."
            )
        case let .writeChapters(mediaURL):
            guard let container = nativeContainer(request.output.container),
                  request.chapters.count <= ChapterWorkflow.maximumChapterCount
            else {
                throw MediaProcessorError.invalidRequest(
                    "The chapter request is outside the supported bound."
                )
            }
            status = withNativeMetadata(request) { metadata in
                withNativeChapters(request.chapters) { chapters in
                    var nativeRequest = IllucetChapterMuxRequest(
                        container: container,
                        fast_start: request.output.fastStart,
                        metadata: metadata,
                        chapters: chapters.baseAddress,
                        chapter_count: chapters.count,
                        preserve_source_chapters:
                            request.output.preserveChapters
                    )
                    return mediaURL.path.withCString { media in
                        destinationURL.path.withCString { output in
                            illucet_ffmpeg_write_chapters(
                                media,
                                output,
                                &nativeRequest,
                                native.job,
                                &rawError
                            )
                        }
                    }
                }
            }
        case .trim:
            throw MediaProcessorError.invalidRequest(
                "Trimming uses the bounded Swift media editor."
            )
        case .removeRanges:
            throw MediaProcessorError.invalidRequest(
                "Multi-range removal uses the bounded Swift media editor."
            )
        case .splitChapters:
            throw MediaProcessorError.invalidRequest(
                "This native bridge operation is not available in the current build."
            )
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw mapStatus(status, rawError: rawError)
        }
        return execution
    }

    private static func runProbe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass,
        native: NativeFFmpegOperation
    ) throws -> FFmpegStage0Probe {
        var rawResult: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(rawResult)
            illucet_ffmpeg_string_free(rawError)
        }
        let status = fileURL.path.withCString { path in
            illucet_ffmpeg_probe_json_with_class(
                path,
                nativeProbeClass(verificationClass),
                native.job,
                &rawResult,
                &rawError
            )
        }
        guard status == ILLUCET_FFMPEG_OK else {
            throw mapStatus(status, rawError: rawError)
        }
        guard let rawResult else {
            throw MediaProcessorError.probeFailure(
                "The native probe returned no result."
            )
        }
        do {
            let probe = try JSONDecoder().decode(
                FFmpegStage0Probe.self,
                from: Data(String(cString: rawResult).utf8)
            )
            guard
                probe.verificationClass == verificationClass.rawValue,
                probe.fullDecodePerformed
                    == (verificationClass == .strongFullDecode)
            else {
                throw MediaProcessorError.probeFailure(
                    "The native probe returned mismatched verification evidence."
                )
            }
            return probe
        } catch let error as MediaProcessorError {
            throw error
        } catch {
            throw MediaProcessorError.probeFailure(
                "The native probe result did not match its typed schema."
            )
        }
    }

    private static func mapProbe(
        _ raw: FFmpegStage0Probe,
        fileURL: URL
    ) -> MediaProbeResult {
        let streams = raw.streams.map { stream -> MediaStreamProbe in
            let kind: MediaStreamKind = switch stream.type {
            case "video": .video
            case "audio": .audio
            case "subtitle": .subtitle
            case "attachment": .attachment
            case "data": .data
            default: .unknown
            }
            let video = kind == .video
                ? VideoStreamProbe(
                    width: stream.width,
                    height: stream.height,
                    pixelFormat: stream.pixelFormat.flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    averageFrameRate: stream.frameRate > 0
                        ? MediaRational(
                            numerator: Int64(stream.frameRate * 1_000),
                            denominator: 1_000
                        )
                        : nil,
                    realFrameRate: nil,
                    colorSpace: stream.colorSpace.flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    colorTransfer: stream.colorTransfer.flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    colorPrimaries: stream.colorPrimaries.flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    colorRange: stream.colorRange.flatMap {
                        $0.isEmpty ? nil : $0
                    },
                    fieldOrder: nil,
                    isHDR: stream.isHDR ?? false
                )
                : nil
            let audio = kind == .audio
                ? AudioStreamProbe(
                    sampleFormat: nil,
                    sampleRate: stream.sampleRate > 0
                        ? stream.sampleRate
                        : nil,
                    channelCount: stream.channels > 0
                        ? stream.channels
                        : nil,
                    channelLayout: stream.channelLayout.isEmpty
                        ? nil
                        : stream.channelLayout,
                    bitsPerSample: nil
                )
                : nil
            return MediaStreamProbe(
                index: stream.index,
                kind: kind,
                codecName: stream.codec.isEmpty ? nil : stream.codec,
                codecLongName: stream.codecLongName.isEmpty
                    ? nil
                    : stream.codecLongName,
                codecProfile: nil,
                codecTag: nil,
                durationSeconds: stream.duration >= 0
                    ? stream.duration
                    : nil,
                bitRate: stream.bitRate > 0 ? stream.bitRate : nil,
                timeBase: nil,
                disposition: MediaStreamDisposition(
                    isDefault: stream.isDefault ?? false,
                    forced: stream.forced ?? false,
                    attachedPicture: stream.attachedPicture
                ),
                metadata: stream.metadata,
                video: video,
                audio: audio,
                subtitle: kind == .subtitle
                    ? SubtitleStreamProbe(
                        languageCode: stream.metadata["language"],
                        title: stream.metadata["title"]
                            ?? stream.metadata["handler_name"],
                        isAutomatic:
                            stream.metadata["illucet_automatic"] == "1"
                    )
                    : nil,
                decodedFrames: stream.decodedFrames,
                decodedSampleWindows: stream.decodedSampleWindows ?? 0
            )
        }
        return MediaProbeResult(
            fileURL: fileURL,
            formatNames: raw.format.split(separator: ",").map(String.init),
            formatLongName: raw.formatLongName.isEmpty
                ? nil
                : raw.formatLongName,
            durationSeconds: raw.duration >= 0 ? raw.duration : nil,
            startTimeSeconds: nil,
            bitRate: raw.bitRate > 0 ? raw.bitRate : nil,
            fileSize: raw.size,
            metadata: raw.metadata,
            streams: streams,
            chapters: (raw.chapters ?? []).map {
                MediaChapter(
                    title: $0.title,
                    startSeconds: $0.start,
                    endSeconds: $0.end
                )
            },
            verificationEvidence: raw.verificationClass.flatMap {
                value in
                guard
                    let verificationClass = MediaVerificationClass(
                        rawValue: value
                    ),
                    let fullDecodePerformed = raw.fullDecodePerformed
                else {
                    return nil
                }
                return MediaProbeEvidence(
                    verificationClass: verificationClass,
                    fullDecodePerformed: fullDecodePerformed,
                    packetsInspected: Int64(raw.packetsInspected ?? 0),
                    inspectedPacketBytes: raw.inspectedPacketBytes ?? 0,
                    tailInspectionAttempted:
                        raw.tailSeekAttempted ?? false,
                    tailInspectionSucceeded:
                        raw.tailSeekSucceeded ?? false,
                    tailInspectionReachedEOF:
                        raw.tailSeekReachedEOF ?? false
                )
            }
        )
    }

    private static func nativeProbeClass(
        _ verificationClass: MediaVerificationClass
    ) -> IllucetFFmpegProbeClass {
        switch verificationClass {
        case .fastStructural:
            ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL
        case .boundedStrong:
            ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG
        case .strongFullDecode:
            ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
        }
    }

    private static func streamCopy(
        _ request: MediaProcessingRequest,
        mode: IllucetStreamCopyMode,
        firstURL: URL,
        secondURL: URL?,
        destinationURL: URL,
        native: NativeFFmpegOperation,
        rawError: inout UnsafeMutablePointer<CChar>?
    ) throws -> IllucetFFmpegStatus {
        guard let container = nativeContainer(request.output.container)
        else {
            throw MediaProcessorError.invalidRequest(
                "The requested stream-copy container is unavailable."
            )
        }
        return withNativeMetadata(request) { metadata in
            var nativeRequest = IllucetStreamCopyRequest(
                mode: mode,
                container: container,
                fast_start: request.output.fastStart,
                metadata: metadata
            )
            return firstURL.path.withCString { first in
                withOptionalCString(secondURL?.path) { second in
                    destinationURL.path.withCString { output in
                        illucet_ffmpeg_stream_copy(
                            first,
                            second,
                            output,
                            &nativeRequest,
                            native.job,
                            &rawError
                        )
                    }
                }
            }
        }
    }

    private static func republishMetadata(
        _ request: MediaProcessingRequest,
        inputURL: URL,
        destinationURL: URL,
        native: NativeFFmpegOperation
    ) throws {
        let mode: IllucetStreamCopyMode = switch (
            request.output.video,
            request.output.audio
        ) {
        case (.remove, .remove):
            throw MediaProcessorError.invalidRequest(
                "A metadata publication job requires a media stream."
            )
        case (.remove, _):
            ILLUCET_STREAM_COPY_EXTRACT_AUDIO
        case (_, .remove):
            ILLUCET_STREAM_COPY_VIDEO_ONLY
        default:
            ILLUCET_STREAM_COPY_REMUX
        }
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = try streamCopy(
            request,
            mode: mode,
            firstURL: inputURL,
            secondURL: nil,
            destinationURL: destinationURL,
            native: native,
            rawError: &rawError
        )
        guard status == ILLUCET_FFMPEG_OK else {
            throw mapStatus(status, rawError: rawError)
        }
    }

    private static func nativeAudioCodec(
        _ codec: MediaCodec
    ) -> IllucetAudioCodec? {
        switch codec {
        case .aac: ILLUCET_AUDIO_CODEC_AAC
        case .mp3: ILLUCET_AUDIO_CODEC_MP3
        case .flac: ILLUCET_AUDIO_CODEC_FLAC
        case .alac: ILLUCET_AUDIO_CODEC_ALAC
        case .opus: ILLUCET_AUDIO_CODEC_OPUS
        case .vorbis: ILLUCET_AUDIO_CODEC_VORBIS
        case .pcmS16LE: ILLUCET_AUDIO_CODEC_PCM_S16LE
        default: nil
        }
    }

    private static func nativeVideoCodec(
        _ codec: MediaCodec
    ) -> IllucetVideoCodec? {
        switch codec {
        case .h264: ILLUCET_VIDEO_CODEC_H264
        case .hevc: ILLUCET_VIDEO_CODEC_HEVC
        default: nil
        }
    }

    private static func nativeSubtitleCodec(
        _ codec: MediaCodec
    ) -> IllucetSubtitleCodec? {
        switch codec {
        case .movText: ILLUCET_SUBTITLE_CODEC_MOV_TEXT
        case .subRip: ILLUCET_SUBTITLE_CODEC_SUBRIP
        case .webVTT: ILLUCET_SUBTITLE_CODEC_WEBVTT
        default: nil
        }
    }

    private static func nativeContainer(
        _ container: MediaContainer
    ) -> IllucetMediaContainer? {
        switch container {
        case .mp4: ILLUCET_MEDIA_CONTAINER_MP4
        case .mov: ILLUCET_MEDIA_CONTAINER_MOV
        case .matroska: ILLUCET_MEDIA_CONTAINER_MATROSKA
        case .webM: ILLUCET_MEDIA_CONTAINER_WEBM
        case .m4a: ILLUCET_MEDIA_CONTAINER_M4A
        case .mp3: ILLUCET_MEDIA_CONTAINER_MP3
        case .ogg: ILLUCET_MEDIA_CONTAINER_OGG
        case .flac: ILLUCET_MEDIA_CONTAINER_FLAC
        case .wav: ILLUCET_MEDIA_CONTAINER_WAV
        default: nil
        }
    }

    private static func nativeAudioRateControl(
        _ settings: AudioEncodingSettings
    ) -> IllucetAudioRateControl {
        if [.flac, .alac, .pcmS16LE].contains(settings.codec) {
            return ILLUCET_AUDIO_RATE_CONTROL_LOSSLESS
        }
        return settings.quality == nil
            ? ILLUCET_AUDIO_RATE_CONTROL_BITRATE
            : ILLUCET_AUDIO_RATE_CONTROL_QUALITY
    }

    private static func nativeChannelCount(
        _ layout: AudioChannelLayoutPolicy
    ) -> Int32 {
        switch layout {
        case .preserve: 0
        case .mono: 1
        case .stereo: 2
        }
    }

    private static func nativeFrameRate(
        _ frameRate: Double?
    ) -> (numerator: Int32, denominator: Int32) {
        guard let frameRate, frameRate > 0 else {
            return (0, 0)
        }
        return (
            Int32((frameRate * 1_000).rounded()),
            1_000
        )
    }

    private static func nativeDynamicRange(
        _ policy: DynamicRangePolicy
    ) -> IllucetDynamicRange {
        switch policy {
        case .preserve: ILLUCET_DYNAMIC_RANGE_PRESERVE
        case .convertToSDR: ILLUCET_DYNAMIC_RANGE_TO_SDR
        }
    }

    private static func nativeAcceleration(
        _ policy: HardwareAccelerationPolicy
    ) -> IllucetHardwareAcceleration {
        switch policy {
        case .automatic:
            ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC
        case .preferVideoToolbox:
            ILLUCET_HARDWARE_ACCELERATION_PREFER_VIDEOTOOLBOX
        case .softwareOnly:
            ILLUCET_HARDWARE_ACCELERATION_SOFTWARE_ONLY
        }
    }

    private static func nativeEncoderName(
        _ report: IllucetVideoTranscodeReport
    ) -> String? {
        var value = report.encoder_name
        return withUnsafeBytes(of: &value) { bytes in
            let characters = bytes.bindMemory(to: CChar.self)
            guard
                let base = characters.baseAddress,
                characters.first != 0
            else {
                return nil
            }
            return String(cString: base)
        }
    }

    private static func withNativeMetadata<Result>(
        _ request: MediaProcessingRequest,
        _ body: (IllucetMediaMetadata) -> Result
    ) -> Result {
        let tags = request.metadata
        return withOptionalCString(tags.title) { title in
            withOptionalCString(tags.artist) { artist in
                withOptionalCString(tags.date) { date in
                    withOptionalCString(tags.description) { description in
                        withOptionalCString(tags.comment) { comment in
                            withOptionalCString(
                                tags.additional["source_url"]
                            ) { sourceURL in
                                withOptionalCString(
                                    tags.additional["video_id"]
                                ) { videoID in
                                    withOptionalCString(
                                        tags.additional["channel"]
                                    ) { channel in
                                        body(
                                            IllucetMediaMetadata(
                                                preserve_source_metadata:
                                                    request.output
                                                    .preserveMetadata,
                                                title: title,
                                                artist: artist,
                                                date: date,
                                                description: description,
                                                comment: comment,
                                                source_url: sourceURL,
                                                video_id: videoID,
                                                channel: channel
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func withNativeChapters<Result>(
        _ chapters: [MediaChapter],
        _ body: (UnsafeBufferPointer<IllucetChapter>) -> Result
    ) -> Result {
        var native: [IllucetChapter] = []
        native.reserveCapacity(chapters.count)

        func append(
            _ index: Int
        ) -> Result {
            guard index < chapters.count else {
                return native.withUnsafeBufferPointer(body)
            }
            let chapter = chapters[index]
            return chapter.title.withCString { title in
                native.append(
                    IllucetChapter(
                        title: title,
                        start_seconds: chapter.startSeconds,
                        end_seconds: chapter.endSeconds
                    )
                )
                defer { native.removeLast() }
                return append(index + 1)
            }
        }

        return append(0)
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value, !value.isEmpty else {
            return body(nil)
        }
        return value.withCString(body)
    }

    private static func mapStatus(
        _ status: IllucetFFmpegStatus,
        rawError: UnsafeMutablePointer<CChar>?
    ) -> MediaProcessorError {
        let safeDetail = rawError.map {
            String(cString: $0).components(separatedBy: .newlines)[0]
        } ?? "The native operation failed."
        switch status {
        case ILLUCET_FFMPEG_CANCELLED:
            return .cancelled
        case ILLUCET_FFMPEG_INPUT_ERROR:
            return .nativeFailure("The media input could not be opened.")
        case ILLUCET_FFMPEG_OUTPUT_EXISTS:
            return .nativeFailure("The output already exists.")
        case ILLUCET_FFMPEG_CODEC_UNAVAILABLE:
            return .nativeFailure("A requested codec is unavailable.")
        case ILLUCET_FFMPEG_PROBE_ERROR:
            return .probeFailure(String(safeDetail.prefix(256)))
        default:
            return .nativeFailure(String(safeDetail.prefix(256)))
        }
    }

    private static func usedStreamCopy(
        _ operation: MediaProcessingOperation
    ) -> Bool {
        switch operation {
        case .merge, .extractAudio, .removeAudio, .remux, .writeChapters:
            true
        case let .trim(_, mode):
            mode == .fastKeyframe
        case .removeRanges:
            true
        case .transcodeAudio, .transcodeVideo, .attachArtwork,
             .embedSubtitles, .burnSubtitles, .splitChapters:
            false
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func stagedURL(for destination: URL) -> URL {
        let extensionValue = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        var name = ".\(stem).illucet-partial-\(UUID().uuidString)"
        if !extensionValue.isEmpty {
            name += ".\(extensionValue)"
        }
        return destination.deletingLastPathComponent().appending(path: name)
    }

    private static func relocated(
        _ probe: MediaProbeResult,
        to fileURL: URL
    ) -> MediaProbeResult {
        MediaProbeResult(
            fileURL: fileURL,
            formatNames: probe.formatNames,
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
    }
}

private extension MediaProcessingOperation {
    var isAccurateRangeEdit: Bool {
        guard case let .removeRanges(_, mode, _) = self else {
            return false
        }
        return mode == .accurate
    }
}

private extension AudioOutputPolicy {
    var bitRate: Int64? {
        if case let .encode(settings) = self {
            return settings.bitRate
        }
        return nil
    }

    var codec: MediaCodec? {
        if case let .encode(settings) = self {
            return settings.codec
        }
        return nil
    }
}

private extension VideoOutputPolicy {
    var bitRate: Int64? {
        if case let .encode(settings) = self {
            return settings.bitRate
        }
        return nil
    }

    var codec: MediaCodec? {
        if case let .encode(settings) = self {
            return settings.codec
        }
        return nil
    }
}
