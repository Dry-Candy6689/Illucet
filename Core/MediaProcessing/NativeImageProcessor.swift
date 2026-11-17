import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum NativeImageProcessor {
    // Some services expose only an album position. Probe those images in native
    // code and keep only their content digest, never a signed source URL.
    static func contentFingerprint(_ address: String, maximumBytes: Int) async throws -> (digest: String, bytes: Int) {
        guard maximumBytes > 0, let url = URL(string: address), ImageFingerprintRedirects.accepts(url) else {
            throw StreamResolutionError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ImageFingerprintRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= maximumBytes else { throw StreamResolutionError.invalidResponse }
        var digest = SHA256(), chunk = Data(), count = 0
        for try await byte in stream {
            count += 1
            guard count <= maximumBytes else { throw StreamResolutionError.invalidResponse }
            chunk.append(byte)
            if chunk.count == 65_536 {
                try Task.checkCancellation()
                digest.update(data: chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        guard count > 0 else { throw StreamResolutionError.invalidResponse }
        digest.update(data: chunk)
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    static func verifyContent(_ file: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256 else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, (1...8 * 1024 * 1024).contains(count) else {
            throw StreamResolutionError.invalidResponse
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else {
            throw MediaProcessorError.verificationMismatch("The downloaded photo changed. Review this post again.")
        }
    }

    static func verify(_ file: URL) throws -> CGImageSource {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, (1...200_000_000).contains(bytes),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              (1...500).contains(CGImageSourceGetCount(source)) else { throw MediaProcessorError.verificationMismatch("The downloaded image is invalid.") }
        var pixels: Int64 = 0
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...32_768).contains(width), (1...32_768).contains(height) else {
                throw MediaProcessorError.verificationMismatch("The image dimensions are invalid.")
            }
            pixels += Int64(width) * Int64(height)
            guard pixels <= 150_000_000,
                  CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw MediaProcessorError.verificationMismatch("The image could not be decoded within the safety limit.")
            }
        }
        return source
    }

    static func prepare(_ original: URL, removeMetadata: Bool, directory: URL) throws -> URL {
        let source = try verify(original)
        guard let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else { throw MediaProcessorError.verificationMismatch("This image format cannot remove metadata.") }
        if !removeMetadata {
            if UTType(filenameExtension: original.pathExtension)?.identifier == type as String { return original }
            let named = directory.appending(path: "original-image.\(ext)")
            try FileManager.default.copyItem(at: original, to: named)
            _ = try verify(named)
            return named
        }
        let frames = CGImageSourceGetCount(source)
        guard frames == 1 || type as String == UTType.gif.identifier else {
            throw MediaProcessorError.verificationMismatch("This animation can only be saved as an original. Turn off image metadata removal and try again.")
        }
        let destination = directory.appending(path: "private-image.\(ext)")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, type, frames, nil) else {
            throw MediaProcessorError.verificationMismatch("Metadata removal is unavailable for this image format. Save the original or choose another format.")
        }
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loop = gif[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:loop]] as CFDictionary)
        }
        for index in 0..<frames {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw MediaProcessorError.verificationMismatch("The image could not be decoded.") }
            let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var safe: [CFString: Any] = [:]
            if let orientation = originalProperties[kCGImagePropertyOrientation] { safe[kCGImagePropertyOrientation] = orientation }
            if let gif = originalProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                safe[kCGImagePropertyGIFDictionary] = gif.filter { [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime].contains($0.key) }
            }
            CGImageDestinationAddImage(writer, image, safe as CFDictionary)
        }
        guard CGImageDestinationFinalize(writer) else { throw MediaProcessorError.verificationMismatch("The private image copy could not be saved.") }
        let output = try verify(destination)
        guard CGImageSourceGetCount(output) == CGImageSourceGetCount(source) else { throw MediaProcessorError.verificationMismatch("Image animation was not preserved.") }
        return destination
    }
}

private final class ImageFingerprintRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static func accepts(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "byteoversea.com", "ibytedtos.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.accepts) == true ? request : nil)
    }
}
