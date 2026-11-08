import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailService {
    private let session: URLSession
    private let fileManager: FileManager
    private let maximumBytes = 20 * 1_024 * 1_024

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
    }

    nonisolated static var supportedOutputFormats: [ThumbnailFormatChoice] {
        let encoders = Set(
            (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        )
        return ThumbnailFormatChoice.allCases.filter { choice in
            guard let type = choice.uniformType else { return true }
            return encoders.contains(type.identifier)
        }
    }

    func download(
        from thumbnails: [MediaThumbnail],
        selectedID: String?,
        to destination: URL,
        outputFormat: ThumbnailFormatChoice,
        cropSquare: Bool
    ) async throws -> URL {
        let candidates = Self.orderedCandidates(
            thumbnails,
            selectedID: selectedID
        )
        guard !candidates.isEmpty else {
            throw ThumbnailError.invalidURL
        }
        var lastError: (any Error)?
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                return try await download(
                    candidate.url,
                    to: destination,
                    outputFormat: outputFormat,
                    cropSquare: cropSquare
                )
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        throw lastError ?? ThumbnailError.downloadFailed
    }

    private func download(
        _ URL: URL,
        to destination: URL,
        outputFormat: ThumbnailFormatChoice,
        cropSquare: Bool
    ) async throws -> URL {
        guard URL.scheme == "https" else {
            throw ThumbnailError.invalidURL
        }
        var request = URLRequest(url: URL)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard
            let HTTP = response as? HTTPURLResponse,
            HTTP.statusCode == 200,
            data.count > 0,
            data.count <= maximumBytes
        else {
            throw ThumbnailError.downloadFailed
        }
        return try write(
            data,
            to: destination,
            outputFormat: outputFormat,
            cropSquare: cropSquare
        )
    }

    func write(
        _ data: Data,
        to destination: URL,
        outputFormat: ThumbnailFormatChoice,
        cropSquare: Bool
    ) throws -> URL {
        guard data.count > 0, data.count <= maximumBytes else {
            throw ThumbnailError.downloadFailed
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let sourceIdentifier = CGImageSourceGetType(source) as String?,
            let sourceType = UTType(sourceIdentifier),
            sourceType.conforms(to: .image),
            CGImageSourceGetCount(source) > 0,
            let decodedImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                nil
            )
        else {
            throw ThumbnailError.decodeFailed
        }

        let outputType: UTType
        if let requested = outputFormat.uniformType {
            outputType = requested
        } else if cropSquare {
            outputType = Self.canEncode(sourceType) ? sourceType : .jpeg
        } else {
            outputType = sourceType
        }
        let fileExtension = outputType.preferredFilenameExtension
            ?? outputFormat.fallbackFileExtension
        let target = destination
            .deletingPathExtension()
            .appendingPathExtension(fileExtension)

        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if outputFormat == .original, !cropSquare {
            try data.write(
                to: target,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            return target
        }

        let mutable = NSMutableData()
        guard
            Self.canEncode(outputType),
            let encoder = CGImageDestinationCreateWithData(
                mutable,
                outputType.identifier as CFString,
                1,
                nil
            )
        else {
            throw ThumbnailError.encoderUnavailable
        }
        let options: CFDictionary? = if outputType.conforms(to: .jpeg)
            || outputType.conforms(to: .webP) {
            [
                kCGImageDestinationLossyCompressionQuality: 0.92,
            ] as CFDictionary
        } else {
            nil
        }
        if cropSquare {
            CGImageDestinationAddImage(
                encoder,
                Self.squareCrop(decodedImage),
                options
            )
        } else {
            CGImageDestinationAddImageFromSource(
                encoder,
                source,
                0,
                options
            )
        }
        guard CGImageDestinationFinalize(encoder) else {
            throw ThumbnailError.encoderUnavailable
        }
        try (mutable as Data).write(
            to: target,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        return target
    }

    private nonisolated static func orderedCandidates(
        _ thumbnails: [MediaThumbnail],
        selectedID: String?
    ) -> [MediaThumbnail] {
        let eligible = if let selectedID {
            thumbnails.filter { $0.id == selectedID }
        } else {
            thumbnails
        }
        let ordered = eligible.sorted { left, right in
            let leftArea = thumbnailArea(left)
            let rightArea = thumbnailArea(right)
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            let leftWidth = max(left.width ?? 0, 0)
            let rightWidth = max(right.width ?? 0, 0)
            if leftWidth != rightWidth {
                return leftWidth > rightWidth
            }
            let leftHeight = max(left.height ?? 0, 0)
            let rightHeight = max(right.height ?? 0, 0)
            if leftHeight != rightHeight {
                return leftHeight > rightHeight
            }
            let leftID = left.id ?? ""
            let rightID = right.id ?? ""
            if leftID != rightID {
                return leftID < rightID
            }
            return left.url.absoluteString < right.url.absoluteString
        }
        var seenURLs: Set<URL> = []
        return ordered.filter { seenURLs.insert($0.url).inserted }
    }

    private nonisolated static func thumbnailArea(
        _ thumbnail: MediaThumbnail
    ) -> UInt64 {
        let width = UInt64(max(thumbnail.width ?? 0, 0))
        let height = UInt64(max(thumbnail.height ?? 0, 0))
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? .max : area
    }

    private nonisolated static func canEncode(_ type: UTType) -> Bool {
        let encoders = Set(
            (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        )
        return encoders.contains(type.identifier)
    }

    private nonisolated static func squareCrop(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let rectangle = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        return image.cropping(to: rectangle) ?? image
    }
}

private extension ThumbnailFormatChoice {
    var uniformType: UTType? {
        switch self {
        case .original: nil
        case .jpeg: .jpeg
        case .png: .png
        case .webp: .webP
        }
    }

    var fallbackFileExtension: String {
        switch self {
        case .original, .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        }
    }
}

enum ThumbnailError: LocalizedError, Sendable {
    case invalidURL
    case downloadFailed
    case decodeFailed
    case encoderUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The thumbnail URL is invalid."
        case .downloadFailed: "The thumbnail could not be downloaded."
        case .decodeFailed: "The thumbnail image could not be decoded."
        case .encoderUnavailable: "The requested thumbnail format is unavailable."
        }
    }
}
