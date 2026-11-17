import Foundation

extension DeveloperFixtures {
    static var externalAssets: [MediaMetadata] {
        let records: [(MediaSite, String, String, String, SourceMediaKind)] = [(.tiktok, "https://www.tiktok.com/@sample/video/123456", "123456", "A little adventure", .video),
         (.instagram, "https://www.instagram.com/p/SamplePost/", "SamplePost", "Sunset by the coast", .image),
         (.x, "https://x.com/sample/status/123456", "123456", "A moment worth keeping", .video),
         (.reddit, "https://www.reddit.com/r/sample/comments/abc123/example/", "abc123", "The view from the trail", .image)]
        return records.map { site, url, id, title, kind in
                MediaMetadata(sourceIdentity: .init(site: site, postID: id, assetID: id, kind: kind),
                    assetFingerprint: kind == .image ? String(repeating: "a", count: 64) : nil,
                    canonicalURL: URL(string: url)!, videoID: id, title: title, channel: nil,
                    uploader: "Sample creator", durationSeconds: kind == .image ? nil : 32,
                    uploadDate: nil, description: nil, isLive: false, liveStatus: nil,
                    thumbnails: [], chapters: [], subtitles: [], formats: kind == .image ? [] : media.formats)
            }
    }
}
