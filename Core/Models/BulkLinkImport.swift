import Foundation
import UniformTypeIdentifiers
import UIKit

enum BulkImportError: LocalizedError {
    case tooLarge, tooManyLinks, unreadable, unsupportedFile
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Import up to 10 MiB of text at a time."
        case .tooManyLinks: "This import contains more than 500 links. Split it into smaller lists."
        case .unreadable: "This document could not be read as text. Try exporting it as TXT or RTF."
        case .unsupportedFile: "Choose a TXT, Markdown, CSV, HTML or RTF document."
        }
    }
}

struct ImportedLink: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let site: MediaSite?
    let duplicate: Bool
    var selected: Bool
}

enum BulkLinkImport {
    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumItems = 500
    static let fileTypes: [UTType] = [.plainText, .utf8PlainText, .commaSeparatedText, .html, .rtf, UTType(filenameExtension: "md") ?? .plainText]

    static func links(in text: String) throws -> [ImportedLink] {
        guard text.utf8.count <= maximumBytes else { throw BulkImportError.tooLarge }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var seen: Set<String> = []
        var result: [ImportedLink] = []
        for match in matches {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 4096 else { continue }
            let safe = SharedLinkParser.canonicalURL(url)
            let displayed = safe ?? url
            let key = displayed.absoluteString
            let duplicate = !seen.insert(key).inserted
            let site = safe.flatMap(MediaSite.recognize)
            result.append(.init(id: UUID(), url: displayed, site: site, duplicate: duplicate,
                                selected: site != nil && !duplicate))
            guard result.count <= maximumItems else { throw BulkImportError.tooManyLinks }
        }
        return result
    }

    static func text(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BulkImportError.unreadable }
        guard let size = values.fileSize, size <= maximumBytes else { throw BulkImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try text(from: data, fileExtension: url.pathExtension.lowercased())
    }

    static func text(from data: Data, fileExtension: String) throws -> String {
        guard data.count <= maximumBytes else { throw BulkImportError.tooLarge }
        switch fileExtension {
        case "rtf":
            let value = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            var text = value.string
            value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { link, _, _ in
                if let url = link as? URL { text += "\n" + url.absoluteString }
                else if let string = link as? String { text += "\n" + string }
            }
            return text
        case "html", "htm", "txt", "text", "md", "markdown", "csv":
            // Detect links in raw HTML too: no WebView, document scripts or resource loads.
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw BulkImportError.unreadable }
            return text.replacingOccurrences(of: "&amp;", with: "&")
        default: throw BulkImportError.unsupportedFile
        }
    }
}
