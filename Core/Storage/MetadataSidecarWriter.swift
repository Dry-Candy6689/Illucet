import CryptoKit
import Foundation

enum MetadataSidecarKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case info = "Metadata JSON", description = "Description text", source = "Source URL", nfo = "NFO", sha256 = "SHA-256 checksum"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .info: "info.json"
        case .description: "description.txt"
        case .source: "url"
        case .nfo: "nfo"
        case .sha256: "sha256"
        }
    }
}

struct MetadataSidecarRecord: Codable, Equatable, Sendable {
    let kind: MetadataSidecarKind?
    let localURL: URL
}

enum MetadataSidecarWriter {
    private struct Info: Encodable {
        let videoID: String
        let title: String
        let channel: String?
        let durationSeconds: Double?
        let uploadDate: String?
        let source: String
    }
    static func prepare(kinds: Set<MetadataSidecarKind>, metadata: MediaMetadata,
                        mediaURL: URL, root: URL) throws -> [(kind: MetadataSidecarKind, url: URL)] {
        let source = "https://www.youtube.com/watch?v=\(metadata.videoID)"
        return try MetadataSidecarKind.allCases.filter(kinds.contains).map { kind in
            try Task.checkCancellation()
            let data: Data
            switch kind {
            case .info:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(Info(videoID: metadata.videoID, title: metadata.title,
                    channel: metadata.channel, durationSeconds: metadata.durationSeconds,
                    uploadDate: metadata.uploadDate, source: source))
            case .description:
                data = Data(String((metadata.description ?? "").prefix(1_048_576)).utf8)
            case .source:
                data = Data(("[InternetShortcut]\nURL=" + source + "\n").utf8)
            case .nfo:
                data = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<movie><title>" + xml(metadata.title)
                    + "</title><plot>" + xml(String((metadata.description ?? "").prefix(1_048_576)))
                    + "</plot><uniqueid type=\"youtube\">" + xml(metadata.videoID) + "</uniqueid></movie>\n").utf8)
            case .sha256:
                data = Data((try digest(mediaURL) + "\n").utf8)
            }
            let url = root.appendingPathComponent("metadata." + kind.fileExtension)
            try data.write(to: url, options: .atomic)
            return (kind, url)
        }
    }
    static func digest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 262_144), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func xml(_ value: String) -> String {
        let clean = String(value.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v == 9 || v == 10 || v == 13 || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
        })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
