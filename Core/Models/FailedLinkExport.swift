import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FailedLinkExport: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(jobs: [DownloadJob], batches: [DownloadBatch] = []) {
        self.init(urls: jobs.filter { [.failed, .needsAttention].contains($0.state) }.map(\.sourceURL)
            + batches.flatMap(\.items).filter { [.failed, .needsAttention].contains($0.state) }.compactMap(\.sourceURL))
    }
    init(urls: [URL]) {
        var seen: Set<String> = []
        text = urls.compactMap {
            SharedLinkParser.canonicalURL($0)?.absoluteString
        }.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data((text + "\n").utf8)) }
}
