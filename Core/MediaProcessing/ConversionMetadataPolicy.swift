import Foundation

/// Maps extractor identity into stable media tags and verification rules.
struct ConversionMetadataPolicy: Equatable, Sendable {
    let tags: MediaTagSet
    let requiredKeys: Set<String>
    let expectedValues: [String: String]
    let forbiddenKeys: Set<String>

    init(
        metadata: MediaMetadata,
        preserve: Bool,
        container: MediaContainer
    ) {
        let channel = metadata.channel ?? metadata.uploader
        let sourceIdentity = (
            metadata.description.map { ["Description: \($0)"] } ?? []
        ) + [
            "Source URL: \(metadata.canonicalURL.absoluteString)",
            "Video ID: \(metadata.videoID)",
        ]
        let comment = sourceIdentity.joined(separator: "\n")
        let optionalValues: [String: String?] = [
            "title": metadata.title,
            "artist": channel,
            "date": metadata.uploadDate,
            "description": metadata.description,
            "comment": comment,
        ]
        var values: [String: String] = optionalValues.compactMapValues { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if [.flac, .wav, .ogg].contains(container) {
            // These muxers retain the description in the comment fallback but
            // do not expose a separate description field when reopened.
            values["description"] = nil
        }
        if preserve {
            tags = MediaTagSet(
                title: metadata.title,
                artist: channel,
                album: nil,
                albumArtist: nil,
                comment: comment,
                date: metadata.uploadDate,
                genre: nil,
                language: nil,
                description: metadata.description,
                additional: ([
                    "source_url": metadata.canonicalURL.absoluteString,
                    "video_id": metadata.videoID,
                    "channel": channel,
                ] as [String: String?]).compactMapValues { $0 }
            )
            requiredKeys = Set(values.keys)
            expectedValues = values
            forbiddenKeys = []
        } else {
            tags = .empty
            requiredKeys = []
            expectedValues = [:]
            forbiddenKeys = [
                "title",
                "artist",
                "date",
                "description",
                "comment",
                "source_url",
                "video_id",
                "channel",
            ]
        }
    }
}
