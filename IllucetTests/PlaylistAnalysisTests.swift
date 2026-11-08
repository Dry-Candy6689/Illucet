import Foundation
import Testing
@testable import Illucet

struct PlaylistAnalysisTests {
    @Test
    func classifiesVideosAndPlaylistKindsWithoutTrackingData() throws {
        let cases: [(String, PlaylistKind, String?)] = [
            (
                "https://youtube.com/playlist?list=PLFixture_123"
                    + "&si=tracking",
                .playlist,
                nil
            ),
            (
                "https://youtube.com/watch?v=AbCdEf123_-"
                    + "&list=PLFixture_123&index=3",
                .playlist,
                "AbCdEf123_-"
            ),
            (
                "https://youtu.be/AbCdEf123_-?list=RDMMFixture",
                .mix,
                "AbCdEf123_-"
            ),
            (
                "https://youtube.com/shorts/AbCdEf123_-"
                    + "?list=PLShorts123",
                .shorts,
                "AbCdEf123_-"
            ),
            (
                "https://youtube.com/playlist?list=WL",
                .privateCollection,
                nil
            ),
        ]

        for (input, expectedKind, expectedVideoID) in cases {
            let url = try #require(URL(string: input))
            let intent = try YouTubeURLIntentClassifier
                .playlistIntent(from: url)

            #expect(intent.kind == expectedKind)
            #expect(intent.referencedVideoID == expectedVideoID)
            #expect(
                !intent.analysisURL.absoluteString.contains("tracking")
            )
            #expect(!intent.analysisURL.absoluteString.contains("index="))
            #expect(!intent.canonicalURL.absoluteString.contains("v="))
        }

        let videoURL = try #require(
            URL(string: "https://youtu.be/AbCdEf123_-?si=tracking")
        )
        guard case let .video(canonicalURL, videoID) =
            try YouTubeURLIntentClassifier.classify(videoURL)
        else {
            Issue.record("A plain video URL was classified as a playlist.")
            return
        }
        #expect(videoID == "AbCdEf123_-")
        #expect(
            canonicalURL.absoluteString
                == "https://www.youtube.com/watch?v=AbCdEf123_-"
        )
    }

    @Test
    func rejectsAmbiguousUnsupportedAndMalformedCollectionURLs() throws {
        let inputs = [
            "https://example.com/playlist?list=PLFixture_123",
            "https://youtube.com/channel/UC123?list=PLFixture_123",
            "https://youtube.com/playlist?list=%2Funsafe",
            "file:///playlist?list=PLFixture_123",
            "https://youtu.be/?list=PLFixture_123",
        ]
        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(throws: PlaylistAnalysisError.self) {
                try YouTubeURLIntentClassifier.classify(url)
            }
        }
    }

    @Test
    func typedRequestCannotEnableDownloads() throws {
        let request = PlaylistAnalysisRequest(
            url: "https://www.youtube.com/playlist?list=PLFixture_123",
            maximumEntries: 25
        )
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request)
            ) as? [String: Any]
        )

        #expect(object["action"] as? String == "extract_playlist")
        #expect(object["download"] as? Bool == false)
        #expect(object["maximum_entries"] as? Int == 25)
    }

    @Test
    func decodesAndValidatesBoundedPlaylistInventory() throws {
        let intent = try fixtureIntent
        let response = try successResponse(for: fixtureAnalysis)

        let result = try YTDLPPlaylistAnalyzer
            .decodeAndValidateResponse(
                response,
                expectedIntent: intent,
                maximumEntries: 20
            )

        #expect(result == fixtureAnalysis)
        #expect(result.availableItemCount == 2)
        #expect(result.unavailableItemCount == 1)
    }

    @Test
    func responseValidationRejectsUnsafeOrMismatchedInventory() throws {
        let unsafe = PlaylistAnalysis(
            canonicalURL: fixtureAnalysis.canonicalURL,
            playlistID: fixtureAnalysis.playlistID,
            kind: fixtureAnalysis.kind,
            referencedVideoID: fixtureAnalysis.referencedVideoID,
            title: fixtureAnalysis.title,
            creator: fixtureAnalysis.creator,
            thumbnailURL: URL(
                string: "https://example.com/private?token=secret"
            ),
            reportedItemCount: fixtureAnalysis.reportedItemCount,
            estimatedTotalBytes: fixtureAnalysis.estimatedTotalBytes,
            entries: fixtureAnalysis.entries,
            isTruncated: fixtureAnalysis.isTruncated
        )
        let oversized = try successResponse(for: fixtureAnalysis)
            + String(repeating: " ", count: 8 * 1_024 * 1_024)

        #expect(throws: PlaylistAnalysisError.self) {
            try YTDLPPlaylistAnalyzer.decodeAndValidateResponse(
                try successResponse(for: unsafe),
                expectedIntent: try fixtureIntent,
                maximumEntries: 20
            )
        }
        #expect(throws: PlaylistAnalysisError.self) {
            try YTDLPPlaylistAnalyzer.decodeAndValidateResponse(
                try successResponse(for: fixtureAnalysis),
                expectedIntent: try fixtureIntent,
                maximumEntries: 2
            )
        }
        #expect(throws: PlaylistAnalysisError.self) {
            try YTDLPPlaylistAnalyzer.decodeAndValidateResponse(
                oversized,
                expectedIntent: try fixtureIntent,
                maximumEntries: 20
            )
        }
    }

    @Test
    func childFactoryReanalyzesExactItemAndSpecializesBatchIdentity()
        async throws {
        let accountID = UUID()
        let recorder = PlaylistChildFactoryRecorder(
            metadata: fixtureMetadata(videoID: "AbCdEf123_-")
        )
        let factory = PlaylistChildJobFactory(
            loadAccountMetadata: { url, selectedAccountID in
                #expect(selectedAccountID == accountID)
                return try await recorder.load(url)
            },
            enqueue: { metadata, configuration, version, membership in
                #expect(configuration.accountID == accountID)
                return try await recorder.enqueue(
                    metadata: metadata,
                    configuration: configuration,
                    version: version,
                    membership: membership
                )
            }
        )
        var configuration = DownloadConfiguration.standard
        configuration.accountID = accountID
        configuration.selectedVideoFormatID = "stale-video"
        configuration.selectedAudioFormatID = "stale-audio"
        configuration.filenameTemplate =
            "{playlist_index} {playlist} {title}"
        let batch = DownloadBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: configuration,
            destinationStructure: .playlistSubfolder,
            continueOnError: true,
            skipArchivedItems: true,
            numberFilenames: true,
            filenameIndexWidth: 3,
            entries: fixtureAnalysis.entries.filter {
                $0.availability.isDownloadable
            }
        )

        let job = try await factory.enqueueChild(
            entry: fixtureAnalysis.entries[0],
            in: batch,
            extractorVersion: "fixture-version"
        )
        let call = try #require(await recorder.lastEnqueue)

        #expect(
            await recorder.loadedURLs
                == [fixtureAnalysis.entries[0].canonicalURL]
        )
        #expect(call.configuration.selectedFormatIDs.isEmpty)
        #expect(call.configuration.playlistBehavior == .referencedVideo)
        #expect(
            call.configuration.filenameTemplate
                == "001 Fixture Playlist {title}"
        )
        #expect(call.membership.batchID == batch.id)
        #expect(call.membership.entryID == fixtureAnalysis.entries[0].id)
        #expect(call.membership.playlistIndex == 1)
        #expect(call.membership.relativeOutputDirectory == "Fixture Playlist")
        #expect(job.batchMembership == call.membership)
        #expect(job.playlistItemID == call.membership.entryID)
    }

    @Test
    func childFactoryRejectsExtractorIdentitySubstitution() async throws {
        let recorder = PlaylistChildFactoryRecorder(
            metadata: fixtureMetadata(videoID: "ZyXwVu987_-")
        )
        let factory = PlaylistChildJobFactory(
            loadMetadata: { url in
                try await recorder.load(url)
            },
            enqueue: { metadata, configuration, version, membership in
                try await recorder.enqueue(
                    metadata: metadata,
                    configuration: configuration,
                    version: version,
                    membership: membership
                )
            }
        )
        let batch = DownloadBatch(
            analysis: fixtureAnalysis,
            selection: .entirePlaylist,
            configuration: .standard,
            destinationStructure: .selectedFolder,
            continueOnError: true,
            skipArchivedItems: false,
            numberFilenames: false,
            filenameIndexWidth: 2,
            entries: fixtureAnalysis.entries.filter {
                $0.availability.isDownloadable
            }
        )

        await #expect(throws: PlaylistChildJobFactoryError.self) {
            try await factory.enqueueChild(
                entry: fixtureAnalysis.entries[0],
                in: batch,
                extractorVersion: nil
            )
        }
        #expect(await recorder.lastEnqueue == nil)
    }

    private var fixtureIntent: PlaylistURLIntent {
        get throws {
            try YouTubeURLIntentClassifier.playlistIntent(
                from: #require(
                    URL(
                        string:
                            "https://youtube.com/watch?v=AbCdEf123_-"
                            + "&list=PLFixture_123"
                    )
                )
            )
        }
    }

    private var fixtureAnalysis: PlaylistAnalysis {
        PlaylistAnalysis(
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/playlist?list=PLFixture_123"
            )!,
            playlistID: "PLFixture_123",
            kind: .playlist,
            referencedVideoID: "AbCdEf123_-",
            title: "Fixture Playlist",
            creator: "Fixture Creator",
            thumbnailURL: URL(
                string:
                    "https://i.ytimg.com/vi/AbCdEf123_-/hqdefault.jpg"
            ),
            reportedItemCount: 3,
            estimatedTotalBytes: 4_000,
            entries: [
                fixtureEntry(index: 1, videoID: "AbCdEf123_-"),
                PlaylistEntry(
                    index: 2,
                    videoID: "Private123_",
                    canonicalURL: nil,
                    title: "Private video",
                    creator: nil,
                    durationSeconds: nil,
                    thumbnailURL: nil,
                    estimatedBytes: nil,
                    availability: .privateVideo
                ),
                fixtureEntry(index: 3, videoID: "MnOpQr456_-"),
            ],
            isTruncated: false
        )
    }

    private func fixtureEntry(
        index: Int,
        videoID: String
    ) -> PlaylistEntry {
        PlaylistEntry(
            index: index,
            videoID: videoID,
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/watch?v=\(videoID)"
            ),
            title: "Item \(index)",
            creator: "Fixture Creator",
            durationSeconds: Double(index * 10),
            thumbnailURL: URL(
                string:
                    "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
            ),
            estimatedBytes: Int64(index * 1_000),
            availability: .available
        )
    }

    private func fixtureMetadata(videoID: String) -> MediaMetadata {
        MediaMetadata(
            canonicalURL: URL(
                string:
                    "https://www.youtube.com/watch?v=\(videoID)"
            )!,
            videoID: videoID,
            title: "Analyzed \(videoID)",
            channel: "Fixture Creator",
            uploader: "Fixture Creator",
            durationSeconds: 10,
            uploadDate: "2026-07-28",
            description: nil,
            isLive: false,
            liveStatus: "not_live",
            thumbnails: [],
            chapters: [],
            subtitles: [],
            formats: []
        )
    }

    private func successResponse(
        for analysis: PlaylistAnalysis
    ) throws -> String {
        let envelope = PlaylistSuccessEnvelope(
            ok: true,
            action: "extract_playlist",
            data: analysis
        )
        return String(
            decoding: try JSONEncoder().encode(envelope),
            as: UTF8.self
        )
    }
}

private struct PlaylistSuccessEnvelope: Encodable {
    let ok: Bool
    let action: String
    let data: PlaylistAnalysis
}

private actor PlaylistChildFactoryRecorder {
    struct EnqueueCall: Equatable, Sendable {
        let configuration: DownloadConfiguration
        let version: String?
        let membership: BatchJobMembership
    }

    private let metadata: MediaMetadata
    private(set) var loadedURLs: [URL] = []
    private(set) var lastEnqueue: EnqueueCall?

    init(metadata: MediaMetadata) {
        self.metadata = metadata
    }

    func load(_ url: URL) throws -> MediaMetadata {
        loadedURLs.append(url)
        return metadata
    }

    func enqueue(
        metadata: MediaMetadata,
        configuration: DownloadConfiguration,
        version: String?,
        membership: BatchJobMembership
    ) throws -> DownloadJob {
        lastEnqueue = EnqueueCall(
            configuration: configuration,
            version: version,
            membership: membership
        )
        var job = DownloadJob(
            id: UUID(),
            sourceURL: metadata.canonicalURL,
            videoID: metadata.videoID,
            title: metadata.title,
            channel: metadata.channel,
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: .queued,
            stage: .waiting,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: version
        )
        job.batchMembership = membership
        job.playlistItemID = membership.entryID
        return job
    }
}
