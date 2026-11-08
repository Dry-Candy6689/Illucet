import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

enum AVFoundationMetadataPublisher {
    static func items(
        sourceAsset: AVAsset,
        tags: MediaTagSet,
        preserve: Bool
    ) async throws -> [AVMetadataItem] {
        guard preserve else { return [] }
        let replacements = replacementItems(for: tags)
        let replacedIdentifiers = replacementIdentifiers(for: tags)
        let source = try await sourceAsset.load(.metadata).filter { item in
            guard let identifier = item.identifier else { return true }
            return !replacedIdentifiers.contains(identifier)
        }
        return source + replacements
    }

    private static func replacementItems(
        for tags: MediaTagSet
    ) -> [AVMetadataItem] {
        [
            item(identifier: .iTunesMetadataSongName, value: tags.title),
            item(identifier: .iTunesMetadataArtist, value: tags.artist),
            item(identifier: .iTunesMetadataUserComment, value: tags.comment),
            item(identifier: .iTunesMetadataReleaseDate, value: tags.date),
            item(
                identifier: .iTunesMetadataDescription,
                value: tags.description
            ),
            item(identifier: .quickTimeMetadataTitle, value: tags.title),
            item(identifier: .quickTimeMetadataArtist, value: tags.artist),
            item(identifier: .quickTimeMetadataComment, value: tags.comment),
            item(
                identifier: .quickTimeMetadataCreationDate,
                value: tags.date
            ),
            item(
                identifier: .quickTimeMetadataDescription,
                value: tags.description
            ),
        ].compactMap { $0 }
    }

    private static func replacementIdentifiers(
        for tags: MediaTagSet
    ) -> Set<AVMetadataIdentifier> {
        var result = Set<AVMetadataIdentifier>()
        if tags.title?.isEmpty == false {
            result.formUnion([
                .iTunesMetadataSongName,
                .quickTimeUserDataFullName,
                .quickTimeMetadataTitle,
            ])
        }
        if tags.artist?.isEmpty == false {
            result.formUnion([
                .iTunesMetadataArtist,
                .quickTimeUserDataArtist,
                .quickTimeMetadataArtist,
            ])
        }
        if tags.comment?.isEmpty == false {
            result.formUnion([
                .iTunesMetadataUserComment,
                .quickTimeUserDataComment,
                .quickTimeMetadataComment,
            ])
        }
        if tags.date?.isEmpty == false {
            result.formUnion([
                .iTunesMetadataReleaseDate,
                .quickTimeUserDataCreationDate,
                .quickTimeMetadataCreationDate,
            ])
        }
        if tags.description?.isEmpty == false {
            result.formUnion([
                .iTunesMetadataDescription,
                .quickTimeUserDataDescription,
                .quickTimeMetadataDescription,
            ])
        }
        return result
    }

    private static func item(
        identifier: AVMetadataIdentifier,
        value: String?
    ) -> AVMetadataItem? {
        guard let value, !value.isEmpty else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

}

enum AVFoundationMediaEditor {
    private final class ExportSessionBox: @unchecked Sendable {
        private let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }

        func export(to outputURL: URL, as fileType: AVFileType) async throws {
            try await session.export(to: outputURL, as: fileType)
        }

        func cancel() {
            session.cancelExport()
        }
    }

    struct RangeEditResult: Equatable, Sendable {
        let appliedKeptRanges: [MediaTimeRange]
    }

    static func trim(
        inputURL: URL,
        outputURL: URL,
        range: MediaTrimRange,
        mode: MediaTrimMode,
        codec: MediaCodec,
        videoBitRate: Int64?,
        frameRate: Double?,
        isHDR: Bool?,
        audioSampleRate: Int?,
        audioChannelCount: Int?,
        audioBitRate: Int64?,
        container: MediaContainer,
        metadata: MediaTagSet,
        preserveMetadata: Bool,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws {
        guard range.startSeconds.isFinite,
              range.startSeconds >= 0,
              range.endSeconds?.isFinite != false,
              range.endSeconds.map({ $0 > range.startSeconds }) ?? true,
              [.h264, .hevc].contains(codec),
              [.mp4, .mov].contains(container)
        else {
            throw MediaProcessorError.invalidRequest(
                "The trim range or output is unsupported."
            )
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration).seconds
        let end = range.endSeconds ?? duration
        guard duration.isFinite,
              duration > 0,
              end <= duration + 0.05
        else {
            throw MediaProcessorError.invalidRequest(
                "The trim range exceeds the media duration."
            )
        }
        if mode == .accurate {
            _ = try await removeRanges(
                inputURL: inputURL,
                outputURL: outputURL,
                keptRanges: [
                    MediaTimeRange(
                        startSeconds: range.startSeconds,
                        endSeconds: end
                    ),
                ],
                mode: .accurate,
                codec: codec,
                videoBitRate: videoBitRate,
                frameRate: frameRate,
                isHDR: isHDR,
                audioSampleRate: audioSampleRate,
                audioChannelCount: audioChannelCount,
                audioBitRate: audioBitRate,
                container: container,
                metadata: metadata,
                preserveMetadata: preserveMetadata,
                operationID: operationID,
                progress: progress
            )
            return
        }
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        let fileType: AVFileType = container == .mov ? .mov : .mp4
        guard exporter.supportedFileTypes.contains(fileType) else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: range.startSeconds, preferredTimescale: 600),
            duration: CMTime(
                seconds: end - range.startSeconds,
                preferredTimescale: 600
            )
        )
        exporter.metadata = try await AVFoundationMetadataPublisher.items(
            sourceAsset: asset,
            tags: metadata,
            preserve: preserveMetadata
        )
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .muxing,
                completedFraction: 0,
                processedMediaSeconds: range.startSeconds,
                totalMediaSeconds: end - range.startSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        let exportSession = ExportSessionBox(exporter)
        do {
            try await withTaskCancellationHandler {
                try await exportSession.export(to: outputURL, as: fileType)
            } onCancel: {
                exportSession.cancel()
            }
        } catch is CancellationError {
            throw MediaProcessorError.cancelled
        }
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .muxing,
                completedFraction: 1,
                processedMediaSeconds: end - range.startSeconds,
                totalMediaSeconds: end - range.startSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: 0
            )
        )
    }

    static func removeRanges(
        inputURL: URL,
        outputURL: URL,
        keptRanges: [MediaTimeRange],
        mode: SponsorBlockRemovalMode,
        codec: MediaCodec?,
        videoBitRate: Int64?,
        frameRate: Double?,
        isHDR: Bool?,
        audioSampleRate: Int?,
        audioChannelCount: Int?,
        audioBitRate: Int64?,
        container: MediaContainer,
        metadata: MediaTagSet,
        preserveMetadata: Bool,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> RangeEditResult {
        guard !keptRanges.isEmpty,
              [.mp4, .mov, .m4a].contains(container)
        else {
            throw MediaProcessorError.invalidRequest(
                "The multi-range edit request is unsupported."
            )
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw MediaProcessorError.invalidRequest(
                "The media duration is invalid for range editing."
            )
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.count <= 1, audioTracks.count <= 1,
              !videoTracks.isEmpty || !audioTracks.isEmpty
        else {
            throw MediaProcessorError.invalidRequest(
                "Range editing supports one video and one audio stream."
            )
        }
        let requested = try validatedRanges(
            keptRanges,
            durationSeconds: duration
        )
        let applied: [MediaTimeRange]
        switch mode {
        case .accurate:
            applied = requested
        case .fastKeyframe:
            guard let videoTrack = videoTracks.first else {
                throw MediaProcessorError.invalidRequest(
                    "Fast SponsorBlock removal requires a video stream."
                )
            }
            let keyframes = try keyframeTimes(
                asset: asset,
                videoTrack: videoTrack,
                durationSeconds: duration
            )
            applied = try alignedRanges(
                requested,
                keyframes: keyframes,
                durationSeconds: duration
            )
        }

        let composition = AVMutableComposition()
        var insertedTrack = false
        var compositionVideoTrack: AVMutableCompositionTrack?
        var videoTransform = CGAffineTransform.identity
        var videoRenderSize = CGSize.zero
        for sourceTrack in videoTracks + audioTracks {
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MediaProcessorError.nativeFailure(
                    "Could not create the range-edit composition track."
                )
            }
            var cursor = CMTime.zero
            for range in applied {
                try Task.checkCancellation()
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
            if sourceTrack.mediaType == .video {
                videoTransform = try await sourceTrack.load(
                    .preferredTransform
                )
                let naturalSize = try await sourceTrack.load(.naturalSize)
                let transformed = CGRect(
                    origin: .zero,
                    size: naturalSize
                ).applying(videoTransform)
                videoTransform = videoTransform.concatenating(
                    CGAffineTransform(
                        translationX: -transformed.minX,
                        y: -transformed.minY
                    )
                )
                videoRenderSize = CGSize(
                    width: abs(transformed.width),
                    height: abs(transformed.height)
                )
                compositionVideoTrack = destinationTrack
            }
            insertedTrack = true
        }
        guard insertedTrack else {
            throw MediaProcessorError.invalidRequest(
                "The range-edit composition is empty."
            )
        }

        let total = applied.reduce(0) { $0 + $1.durationSeconds }
        let outputMetadata = try await AVFoundationMetadataPublisher.items(
            sourceAsset: asset,
            tags: metadata,
            preserve: preserveMetadata
        )
        if mode == .accurate, videoTracks.isEmpty {
            guard container == .m4a else {
                throw MediaProcessorError.invalidRequest(
                    "Accurate audio-only SponsorBlock removal supports M4A output."
                )
            }
            try await exportAudioComposition(
                composition,
                outputURL: outputURL,
                sampleRate: audioSampleRate,
                channelCount: audioChannelCount,
                bitRate: audioBitRate,
                metadata: outputMetadata,
                operationID: operationID,
                totalDurationSeconds: total,
                progress: progress
            )
            return RangeEditResult(appliedKeptRanges: applied)
        }

        let fileType: AVFileType = switch container {
        case .mov: .mov
        case .m4a: .m4a
        default: .mp4
        }
        if mode == .accurate {
            guard let codec,
                  [.h264, .hevc].contains(codec),
                  let sourceVideoTrack = videoTracks.first,
                  let compositionVideoTrack
            else {
                throw MediaProcessorError.invalidRequest(
                    "Accurate SponsorBlock video removal requires H.264 or HEVC."
                )
            }
            try await exportAccurateVideoComposition(
                composition,
                sourceVideoTrack: sourceVideoTrack,
                sourceAudioTrack: audioTracks.first,
                compositionVideoTrack: compositionVideoTrack,
                videoTransform: videoTransform,
                videoRenderSize: videoRenderSize,
                codec: codec,
                verifiedVideoBitRate: videoBitRate,
                frameRate: frameRate,
                isHDR: isHDR,
                audioSampleRate: audioSampleRate,
                audioChannelCount: audioChannelCount,
                audioBitRate: audioBitRate,
                outputURL: outputURL,
                fileType: fileType,
                metadata: outputMetadata,
                operationID: operationID,
                totalDurationSeconds: total,
                progress: progress
            )
            return RangeEditResult(appliedKeptRanges: applied)
        }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MediaProcessorError.codecUnavailable(
                codec ?? .aac
            )
        }
        guard exporter.supportedFileTypes.contains(fileType) else {
            throw MediaProcessorError.codecUnavailable(codec ?? .aac)
        }
        exporter.metadata = outputMetadata
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .muxing,
                completedFraction: 0,
                processedMediaSeconds: 0,
                totalMediaSeconds: total,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        let exportSession = ExportSessionBox(exporter)
        do {
            try await withTaskCancellationHandler {
                try await exportSession.export(to: outputURL, as: fileType)
            } onCancel: {
                exportSession.cancel()
            }
        } catch is CancellationError {
            throw MediaProcessorError.cancelled
        }
        try Task.checkCancellation()
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .muxing,
                completedFraction: 1,
                processedMediaSeconds: total,
                totalMediaSeconds: total,
                processedBytes: nil,
                estimatedRemainingSeconds: 0
            )
        )
        return RangeEditResult(appliedKeptRanges: applied)
    }

    private static func exportAccurateVideoComposition(
        _ composition: AVMutableComposition,
        sourceVideoTrack: AVAssetTrack,
        sourceAudioTrack: AVAssetTrack?,
        compositionVideoTrack: AVAssetTrack,
        videoTransform: CGAffineTransform,
        videoRenderSize: CGSize,
        codec: MediaCodec,
        verifiedVideoBitRate: Int64?,
        frameRate: Double?,
        isHDR: Bool?,
        audioSampleRate: Int?,
        audioChannelCount: Int?,
        audioBitRate: Int64?,
        outputURL: URL,
        fileType: AVFileType,
        metadata: [AVMetadataItem],
        operationID: UUID,
        totalDurationSeconds: Double,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws {
        guard let frameRate,
              frameRate.isFinite,
              frameRate > 0,
              videoRenderSize.width.isFinite,
              videoRenderSize.height.isFinite,
              videoRenderSize.width > 0,
              videoRenderSize.height > 0
        else {
            throw MediaProcessorError.invalidRequest(
                "Accurate video removal requires known geometry and frame rate."
            )
        }
        let trackBitRate = Int64(
            try await sourceVideoTrack.load(.estimatedDataRate).rounded()
        )
        let targetBitRate: Int64
        if let verifiedVideoBitRate, verifiedVideoBitRate > 0 {
            targetBitRate = verifiedVideoBitRate
        } else if trackBitRate > 0 {
            // Bounded fallback for direct callers: AVFoundation's measured
            // source-track rate remains source-relative and is still verified
            // against the same 2x post-encode ceiling below.
            targetBitRate = trackBitRate
        } else {
            throw MediaProcessorError.invalidRequest(
                "Accurate video removal requires a known source video bitrate."
            )
        }
        let (maximumBitRate, overflow) = targetBitRate.multipliedReportingOverflow(
            by: 2
        )
        guard !overflow,
              targetBitRate <= Int64(Int.max),
              maximumBitRate <= Int64(Int.max)
        else {
            throw MediaProcessorError.invalidRequest(
                "The source video bitrate is outside the supported range."
            )
        }
        let preserveHDR = isHDR == true
        if preserveHDR, codec != .hevc {
            throw MediaProcessorError.invalidRequest(
                "HDR Accurate video removal requires HEVC output."
            )
        }

        var layerConfiguration =
            AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: compositionVideoTrack
            )
        layerConfiguration.setTransform(videoTransform, at: .zero)
        let layer = AVVideoCompositionLayerInstruction(
            configuration: layerConfiguration
        )
        let instruction = AVVideoCompositionInstruction(
            configuration: .init(
                layerInstructions: [layer],
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: composition.duration
                )
            )
        )
        let videoComposition = AVVideoComposition(
            configuration: .init(
                frameDuration: CMTime(
                    seconds: 1 / frameRate,
                    preferredTimescale: 60_000
                ),
                instructions: [instruction],
                renderSize: videoRenderSize
            )
        )

        let reader = try AVAssetReader(asset: composition)
        let pixelFormat = preserveHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compositionVideoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create the Accurate video decoder."
            )
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetBitRate),
            AVVideoExpectedSourceFrameRateKey: frameRate,
        ]
        if codec == .h264 {
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [
                Int(targetBitRate / 8),
                1,
            ]
        }
        if preserveHDR {
            compression[AVVideoProfileLevelKey] =
                kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc
                ? AVVideoCodecType.hevc
                : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoRenderSize.width.rounded()),
            AVVideoHeightKey: Int(videoRenderSize.height.rounded()),
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colorProperties = try await videoColorProperties(
            sourceVideoTrack
        ) {
            videoSettings[AVVideoColorPropertiesKey] = colorProperties
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let sourceAudioTrack,
           let compositionAudioTrack = try await composition.loadTracks(
               withMediaType: .audio
           ).first {
            guard let audioSampleRate,
                  audioSampleRate > 0,
                  let audioChannelCount,
                  audioChannelCount > 0
            else {
                throw MediaProcessorError.invalidRequest(
                    "Accurate video removal requires known AAC audio facts."
                )
            }
            let readerAudio = AVAssetReaderTrackOutput(
                track: compositionAudioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            guard reader.canAdd(readerAudio) else {
                throw MediaProcessorError.nativeFailure(
                    "Could not create the Accurate audio decoder."
                )
            }
            reader.add(readerAudio)
            var audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannelCount,
            ]
            let trackAudioBitRate = Int64(
                try await sourceAudioTrack.load(.estimatedDataRate).rounded()
            )
            if let audioBitRate, audioBitRate > 0 {
                audioSettings[AVEncoderBitRateKey] = audioBitRate
            } else if trackAudioBitRate > 0 {
                audioSettings[AVEncoderBitRateKey] = trackAudioBitRate
            }
            let writerAudio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings
            )
            writerAudio.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerAudio) else {
                throw MediaProcessorError.nativeFailure(
                    "Could not create the Accurate AAC encoder."
                )
            }
            writer.add(writerAudio)
            audioOutput = readerAudio
            audioInput = writerAudio
        }

        guard writer.startWriting(), reader.startReading() else {
            throw MediaProcessorError.nativeFailure(
                writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription
                    ?? "Accurate video removal could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .encoding,
                completedFraction: 0,
                processedMediaSeconds: 0,
                totalMediaSeconds: totalDurationSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        var videoFinished = false
        var audioFinished = audioOutput == nil
        var processedSeconds = 0.0
        do {
            while !videoFinished || !audioFinished {
                try Task.checkCancellation()
                var appendedSample = false
                if !videoFinished, videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else {
                            throw MediaProcessorError.nativeFailure(
                                writer.error?.localizedDescription
                                    ?? "Accurate video encoding failed."
                            )
                        }
                        processedSeconds = max(
                            processedSeconds,
                            CMSampleBufferGetPresentationTimeStamp(sample)
                                .seconds
                        )
                        appendedSample = true
                    } else {
                        videoInput.markAsFinished()
                        videoFinished = true
                    }
                }
                if !audioFinished,
                   let audioOutput,
                   let audioInput,
                   audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else {
                            throw MediaProcessorError.nativeFailure(
                                writer.error?.localizedDescription
                                    ?? "Accurate AAC encoding failed."
                            )
                        }
                        processedSeconds = max(
                            processedSeconds,
                            CMSampleBufferGetPresentationTimeStamp(sample)
                                .seconds
                        )
                        appendedSample = true
                    } else {
                        audioInput.markAsFinished()
                        audioFinished = true
                    }
                }
                progress(
                    MediaProcessingProgress(
                        operationID: operationID,
                        stage: .encoding,
                        completedFraction: min(
                            max(processedSeconds / totalDurationSeconds, 0),
                            1
                        ),
                        processedMediaSeconds: processedSeconds,
                        totalMediaSeconds: totalDurationSeconds,
                        processedBytes: nil,
                        estimatedRemainingSeconds: nil
                    )
                )
                if !appendedSample, !videoFinished || !audioFinished {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            await writer.finishWriting()
            guard reader.status == .completed,
                  writer.status == .completed
            else {
                throw MediaProcessorError.nativeFailure(
                    writer.error?.localizedDescription
                        ?? reader.error?.localizedDescription
                        ?? "Accurate video removal did not complete."
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if Task.isCancelled || error is CancellationError {
                throw MediaProcessorError.cancelled
            }
            throw error
        }
        try await verifyAccurateVideoBitRate(
            outputURL,
            maximumBitRate: maximumBitRate
        )
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .encoding,
                completedFraction: 1,
                processedMediaSeconds: totalDurationSeconds,
                totalMediaSeconds: totalDurationSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: 0
            )
        )
    }

    private static func videoColorProperties(
        _ track: AVAssetTrack
    ) async throws -> [String: Any]? {
        guard let description = try await track.load(.formatDescriptions).first
        else {
            return nil
        }
        guard let formatExtensions = CMFormatDescriptionGetExtensions(
            description
        ) else {
            return nil
        }
        let extensions = formatExtensions as NSDictionary
        let mappings: [(CFString, String)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries,
             AVVideoColorPrimariesKey),
            (kCMFormatDescriptionExtension_TransferFunction,
             AVVideoTransferFunctionKey),
            (kCMFormatDescriptionExtension_YCbCrMatrix,
             AVVideoYCbCrMatrixKey),
        ]
        var result: [String: Any] = [:]
        for (source, destination) in mappings {
            if let value = extensions[source] {
                result[destination] = value
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func verifyAccurateVideoBitRate(
        _ outputURL: URL,
        maximumBitRate: Int64
    ) async throws {
        let outputAsset = AVURLAsset(url: outputURL)
        guard let track = try await outputAsset.loadTracks(
            withMediaType: .video
        ).first else {
            throw MediaProcessorError.verificationMismatch(
                "The Accurate video output has no video stream."
            )
        }
        let outputBitRate = Int64(
            try await track.load(.estimatedDataRate).rounded()
        )
        guard outputBitRate > 0, outputBitRate <= maximumBitRate else {
            throw MediaProcessorError.verificationMismatch(
                "The Accurate video bitrate \(outputBitRate) exceeded the "
                    + "source-relative ceiling \(maximumBitRate)."
            )
        }
    }

    private static func exportAudioComposition(
        _ composition: AVMutableComposition,
        outputURL: URL,
        sampleRate: Int?,
        channelCount: Int?,
        bitRate: Int64?,
        metadata: [AVMetadataItem],
        operationID: UUID,
        totalDurationSeconds: Double,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws {
        guard let track = try await composition.loadTracks(
            withMediaType: .audio
        ).first,
            let sampleRate,
            sampleRate > 0,
            let channelCount,
            channelCount > 0
        else {
            throw MediaProcessorError.invalidRequest(
                "Accurate audio removal requires a known sample rate and channel count."
            )
        }
        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
        )
        guard reader.canAdd(readerOutput) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create the accurate audio decoder."
            )
        }
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.metadata = metadata
        var outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        if let bitRate, bitRate > 0 {
            outputSettings[AVEncoderBitRateKey] = bitRate
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create the accurate AAC encoder."
            )
        }
        writer.add(writerInput)
        guard writer.startWriting(), reader.startReading() else {
            throw MediaProcessorError.nativeFailure(
                writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription
                    ?? "Accurate audio removal could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .encoding,
                completedFraction: 0,
                processedMediaSeconds: 0,
                totalMediaSeconds: totalDurationSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    break
                }
                guard writerInput.append(sample) else {
                    throw MediaProcessorError.nativeFailure(
                        writer.error?.localizedDescription
                            ?? "Accurate AAC encoding failed."
                    )
                }
                let processed = CMSampleBufferGetPresentationTimeStamp(
                    sample
                ).seconds
                progress(
                    MediaProcessingProgress(
                        operationID: operationID,
                        stage: .encoding,
                        completedFraction: min(
                            max(processed / totalDurationSeconds, 0),
                            1
                        ),
                        processedMediaSeconds: processed,
                        totalMediaSeconds: totalDurationSeconds,
                        processedBytes: nil,
                        estimatedRemainingSeconds: nil
                    )
                )
            }
            writerInput.markAsFinished()
            await writer.finishWriting()
            guard reader.status == .completed,
                  writer.status == .completed
            else {
                throw MediaProcessorError.nativeFailure(
                    writer.error?.localizedDescription
                        ?? reader.error?.localizedDescription
                        ?? "Accurate audio removal did not complete."
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if Task.isCancelled || error is CancellationError {
                throw MediaProcessorError.cancelled
            }
            throw error
        }
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .encoding,
                completedFraction: 1,
                processedMediaSeconds: totalDurationSeconds,
                totalMediaSeconds: totalDurationSeconds,
                processedBytes: nil,
                estimatedRemainingSeconds: 0
            )
        )
    }

    private static func validatedRanges(
        _ ranges: [MediaTimeRange],
        durationSeconds: Double
    ) throws -> [MediaTimeRange] {
        var previousEnd = -Double.infinity
        for range in ranges {
            guard range.startSeconds.isFinite,
                  range.endSeconds.isFinite,
                  range.startSeconds >= 0,
                  range.endSeconds > range.startSeconds,
                  range.endSeconds <= durationSeconds + 0.05,
                  range.startSeconds >= previousEnd
            else {
                throw MediaProcessorError.invalidRequest(
                    "The kept media ranges are invalid."
                )
            }
            previousEnd = range.endSeconds
        }
        return ranges
    }

    private static func keyframeTimes(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        durationSeconds: Double
    ) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProcessorError.invalidRequest(
                "Video keyframes could not be inspected."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaProcessorError.invalidRequest(
                "Video keyframe inspection could not start."
            )
        }
        var result = [0.0]
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw MediaProcessorError.cancelled
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync]
                as? Bool ?? false
            if !isNotSync {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                if seconds.isFinite,
                   seconds >= 0,
                   seconds <= durationSeconds + 0.05 {
                    result.append(seconds)
                }
            }
        }
        guard reader.status == .completed else {
            throw MediaProcessorError.invalidRequest(
                "Video keyframe inspection did not complete."
            )
        }
        result.append(durationSeconds)
        return Array(Set(result.map { ($0 * 1_000_000).rounded() / 1_000_000 }))
            .sorted()
    }

    private static func alignedRanges(
        _ ranges: [MediaTimeRange],
        keyframes: [Double],
        durationSeconds: Double
    ) throws -> [MediaTimeRange] {
        guard keyframes.count >= 2 else {
            throw MediaProcessorError.invalidRequest(
                "Fast SponsorBlock removal requires proven keyframes."
            )
        }
        let aligned = ranges.map { range in
            MediaTimeRange(
                startSeconds: nearestKeyframe(
                    to: range.startSeconds,
                    keyframes: keyframes
                ),
                endSeconds: nearestKeyframe(
                    to: range.endSeconds,
                    keyframes: keyframes
                )
            )
        }
        return try validatedRanges(
            aligned,
            durationSeconds: durationSeconds
        )
    }

    private static func nearestKeyframe(
        to value: Double,
        keyframes: [Double]
    ) -> Double {
        keyframes.min {
            let left = abs($0 - value)
            let right = abs($1 - value)
            if left != right { return left < right }
            return $0 < $1
        } ?? value
    }
}
