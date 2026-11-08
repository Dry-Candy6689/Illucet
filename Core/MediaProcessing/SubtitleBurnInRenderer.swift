import AVFoundation
import CoreImage
import Foundation
import UIKit

enum SubtitleBurnInRenderer {
    static let maximumCueCount = 20_000
    static let maximumTrackCount = 4

    static func render(
        inputURL: URL,
        outputURL: URL,
        cues: [MediaRenderedSubtitleCue],
        codec: MediaCodec,
        container: MediaContainer,
        metadata: MediaTagSet,
        preserveMetadata: Bool,
        operationID: UUID,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws {
        try validate(cues: cues, codec: codec, container: container)
        let asset = AVURLAsset(url: inputURL)
        guard try await asset.loadTracks(withMediaType: .video).count == 1 else {
            throw MediaProcessorError.invalidRequest(
                "Rendered subtitles require exactly one video stream."
            )
        }
        let overlays = SubtitleOverlayRenderer()
        let composition = try await AVVideoComposition(
            applyingFiltersTo: asset
        ) { parameters in
            let time = parameters.compositionTime.seconds
            let active = cues.filter {
                time >= $0.startSeconds && time < $0.endSeconds
            }
            guard !active.isEmpty else {
                return AVCIImageFilteringResult(
                    resultImage: parameters.sourceImage
                )
            }
            let overlay = try await overlays.image(
                cues: active,
                size: parameters.renderSize
            )
            let result = overlay
                .composited(over: parameters.sourceImage)
                .cropped(to: parameters.sourceImage.extent)
            return AVCIImageFilteringResult(resultImage: result)
        }
        let preset = codec == .hevc
            ? AVAssetExportPresetHEVCHighestQuality
            : AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        let fileType: AVFileType = switch container {
        case .mp4: .mp4
        case .mov: .mov
        default:
            throw MediaProcessorError.invalidRequest(
                "Rendered subtitles support MP4 and MOV output only."
            )
        }
        guard exporter.supportedFileTypes.contains(fileType) else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        exporter.videoComposition = composition
        exporter.metadata = try await AVFoundationMetadataPublisher.items(
            sourceAsset: asset,
            tags: metadata,
            preserve: preserveMetadata
        )
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .filtering,
                completedFraction: 0,
                processedMediaSeconds: nil,
                totalMediaSeconds: nil,
                processedBytes: nil,
                estimatedRemainingSeconds: nil
            )
        )
        do {
            try await exporter.export(to: outputURL, as: fileType)
        } catch is CancellationError {
            throw MediaProcessorError.cancelled
        }
        progress(
            MediaProcessingProgress(
                operationID: operationID,
                stage: .encoding,
                completedFraction: 1,
                processedMediaSeconds: nil,
                totalMediaSeconds: nil,
                processedBytes: nil,
                estimatedRemainingSeconds: 0
            )
        )
    }

    private static func validate(
        cues: [MediaRenderedSubtitleCue],
        codec: MediaCodec,
        container: MediaContainer
    ) throws {
        guard !cues.isEmpty, cues.count <= maximumCueCount else {
            throw MediaProcessorError.invalidRequest(
                "Rendered subtitle cue count is outside the supported bound."
            )
        }
        guard [.h264, .hevc].contains(codec),
              [.mp4, .mov].contains(container)
        else {
            throw MediaProcessorError.codecUnavailable(codec)
        }
        let tracks = Set(cues.map(\.trackIndex))
        guard !tracks.isEmpty,
              tracks.count <= maximumTrackCount,
              tracks.allSatisfy({ $0 >= 0 && $0 < maximumTrackCount })
        else {
            throw MediaProcessorError.invalidRequest(
                "Rendered subtitle track count is outside the supported bound."
            )
        }
        for cue in cues {
            guard cue.startSeconds.isFinite,
                  cue.endSeconds.isFinite,
                  cue.startSeconds >= 0,
                  cue.endSeconds > cue.startSeconds,
                  !cue.text.isEmpty,
                  cue.text.utf8.count <= 16 * 1_024
            else {
                throw MediaProcessorError.invalidRequest(
                    "A rendered subtitle cue is invalid."
                )
            }
        }
    }
}

private actor SubtitleOverlayRenderer {
    private var cache: [OverlayKey: CIImage] = [:]

    func image(
        cues: [MediaRenderedSubtitleCue],
        size: CGSize
    ) throws -> CIImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let sorted = cues.sorted {
            if $0.trackIndex != $1.trackIndex {
                return $0.trackIndex < $1.trackIndex
            }
            if $0.startSeconds != $1.startSeconds {
                return $0.startSeconds < $1.startSeconds
            }
            return $0.text < $1.text
        }
        let key = OverlayKey(
            width: width,
            height: height,
            labels: sorted.map {
                "\($0.trackIndex):\($0.text)"
            }
        )
        if let cached = cache[key] { return cached }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let image = renderer.image { context in
            let textWidth = CGFloat(width) * 0.84
            let fontSize = min(
                max(CGFloat(height) * 0.045, 18),
                52
            )
            let font = UIFont.systemFont(
                ofSize: fontSize,
                weight: .semibold
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .strokeColor: UIColor.black,
                .strokeWidth: -2.0,
            ]
            let lineHeight = font.lineHeight * 2.6
            for (offset, cue) in sorted.enumerated() {
                let text = NSString(string: cue.text)
                let measured = text.boundingRect(
                    with: CGSize(
                        width: textWidth,
                        height: lineHeight
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
                let boxHeight = min(
                    max(measured.height + 20, font.lineHeight + 20),
                    lineHeight
                )
                let y = CGFloat(height) * 0.08
                    + CGFloat(offset) * (boxHeight + 8)
                let box = CGRect(
                    x: (CGFloat(width) - textWidth) / 2,
                    y: CGFloat(height) - y - boxHeight,
                    width: textWidth,
                    height: boxHeight
                )
                UIColor.black.withAlphaComponent(0.72).setFill()
                context.cgContext.addPath(
                    UIBezierPath(
                        roundedRect: box,
                        cornerRadius: 10
                    ).cgPath
                )
                context.cgContext.fillPath()
                text.draw(
                    with: box.insetBy(dx: 10, dy: 10),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
            }
        }
        guard let CGImage = image.cgImage else {
            throw MediaProcessorError.nativeFailure(
                "The subtitle renderer produced no image."
            )
        }
        let result = CIImage(cgImage: CGImage)
        if cache.count >= 512 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = result
        return result
    }
}

private struct OverlayKey: Hashable, Sendable {
    let width: Int
    let height: Int
    let labels: [String]
}
