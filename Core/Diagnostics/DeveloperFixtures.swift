import Foundation

enum DeveloperFixtures {
    static var largeSubtitleMedia: MediaMetadata {
        let source = media
        let subtitles = (0..<1000).map { index in
            let identity = String(format: "%024x", index)
            return MediaSubtitleTrack(trackID: "subtitle-" + identity, language: index == 0 ? "en" : "x-\(index)",
                name: index == 0 ? "English" : "Language \(index)", automatic: index % 2 == 0,
                formats: (0..<5).map { format in MediaSubtitleFormat(
                    formatID: "subtitle-format-" + String(format: "%024x", index * 5 + format),
                    url: URL(string: "https://example.invalid/subtitles")!, extension: "vtt", name: "Track \(format)") })
        }
        return MediaMetadata(canonicalURL: source.canonicalURL, videoID: source.videoID,
            title: source.title, channel: source.channel, uploader: source.uploader,
            durationSeconds: source.durationSeconds, uploadDate: source.uploadDate,
            description: source.description, isLive: source.isLive, liveStatus: source.liveStatus,
            thumbnails: source.thumbnails, chapters: source.chapters, subtitles: subtitles, formats: source.formats)
    }

    static var runtimeProofInspectionReport: Stage0ProofReport {
        let passingChecks = (1 ... 14).map { index in
            Stage0Check(
                id: "fixture-pass-\(index)",
                name: "Runtime fixture pass \(index)",
                status: .pass,
                evidence: "Deterministic passing evidence \(index)."
            )
        }
        return Stage0ProofReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: "UI fixture",
            checks: passingChecks + [
                Stage0Check(
                    id: "fixture-late-failure",
                    name: "Late runtime fixture failure",
                    status: .fail,
                    evidence: "This failure began after the old 12-row cutoff."
                ),
                Stage0Check(
                    id: "fixture-late-blocked",
                    name: "Late runtime fixture blocked",
                    status: .blocked,
                    evidence: "A blocked result remains inspectable."
                ),
            ],
            events: []
        )
    }

    static let sponsorBlockSegments = [
        SponsorBlockSegment(
            segmentID: "fixture-sponsor-001",
            category: .sponsor,
            startSeconds: 18,
            endSeconds: 31.5,
            description: "Paid promotion",
            submittedVideoDuration: 213,
            serverAction: .skip,
            votes: 14,
            isLocked: true
        ),
        SponsorBlockSegment(
            segmentID: "fixture-intro-001",
            category: .intro,
            startSeconds: 0,
            endSeconds: 7.25,
            description: "Channel intro",
            submittedVideoDuration: 213,
            serverAction: .skip,
            votes: 8,
            isLocked: false
        ),
        SponsorBlockSegment(
            segmentID: "fixture-filler-001",
            category: .filler,
            startSeconds: 96,
            endSeconds: 101.5,
            description: "Possible filler",
            submittedVideoDuration: 213,
            serverAction: .skip,
            votes: 3,
            isLocked: false
        ),
    ]

    static let RickURL = URL(
        string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )!

    static let playlistURL = URL(
        string:
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLVLT000000000001"
    )!

    static let media = MediaMetadata(
        canonicalURL: RickURL,
        videoID: "dQw4w9WgXcQ",
        title: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)",
        channel: "Rick Astley",
        uploader: "Rick Astley",
        durationSeconds: 213,
        uploadDate: "2009-10-25",
        description:
            "Deterministic developer fixture used only for previews and UI tests.",
        isLive: false,
        liveStatus: "not_live",
        thumbnails: [
            MediaThumbnail(
                url: URL(
                    string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"
                )!,
                width: 1_280,
                height: 720,
                id: "maxres"
            ),
        ],
        chapters: [
            ExtractedChapter(
                title: "Intro",
                startTimeSeconds: 0,
                endTimeSeconds: 18
            ),
            ExtractedChapter(
                title: "Verse",
                startTimeSeconds: 18,
                endTimeSeconds: 58
            ),
        ],
        subtitles: [
            MediaSubtitleTrack(
                trackID: "subtitle-111111111111111111111111",
                language: "en",
                name: "English",
                automatic: false,
                formats: [
                    MediaSubtitleFormat(
                        formatID:
                            "subtitle-format-111111111111111111111111",
                        url: URL(
                            string:
                                "https://captions.example.invalid/manual/en.vtt"
                        )!,
                        extension: "vtt",
                        name: "English"
                    ),
                ]
            ),
            MediaSubtitleTrack(
                trackID: "subtitle-222222222222222222222222",
                language: "en-auto",
                name: "English (automatic)",
                automatic: true,
                formats: [
                    MediaSubtitleFormat(
                        formatID:
                            "subtitle-format-222222222222222222222222",
                        url: URL(
                            string:
                                "https://captions.example.invalid/automatic/en.vtt"
                        )!,
                        extension: "vtt",
                        name: "English (automatic)"
                    ),
                ]
            ),
        ],
        formats: [
            MediaFormat(
                formatID: "401",
                formatNote: "2160p",
                extension: "mp4",
                container: "mp4_dash",
                videoCodec: "av01.0.12M.08",
                audioCodec: nil,
                width: 3_840,
                height: 2_160,
                resolution: "3840x2160",
                framesPerSecond: 30,
                dynamicRange: "SDR",
                isHDR: false,
                audioBitrateKbps: nil,
                videoBitrateKbps: 11_500,
                totalBitrateKbps: 11_500,
                exactFileSizeBytes: 308_000_000,
                approximateFileSizeBytes: nil,
                hasVideo: true,
                hasAudio: false,
                protocolName: "https",
                sourceType: "direct_http",
                language: nil
            ),
            MediaFormat(
                formatID: "137",
                formatNote: "1080p",
                extension: "mp4",
                container: "mp4_dash",
                videoCodec: "avc1.640028",
                audioCodec: nil,
                width: 1_920,
                height: 1_080,
                resolution: "1920x1080",
                framesPerSecond: 30,
                dynamicRange: "SDR",
                isHDR: false,
                audioBitrateKbps: nil,
                videoBitrateKbps: 4_500,
                totalBitrateKbps: 4_500,
                exactFileSizeBytes: 121_000_000,
                approximateFileSizeBytes: nil,
                hasVideo: true,
                hasAudio: false,
                protocolName: "https",
                sourceType: "direct_http",
                language: nil
            ),
            MediaFormat(
                formatID: "18",
                formatNote: "360p",
                extension: "mp4",
                container: "mp4",
                videoCodec: "avc1.42001E",
                audioCodec: "mp4a.40.2",
                width: 640,
                height: 360,
                resolution: "640x360",
                framesPerSecond: 30,
                dynamicRange: "SDR",
                isHDR: false,
                audioBitrateKbps: 96,
                videoBitrateKbps: 500,
                totalBitrateKbps: 596,
                exactFileSizeBytes: 16_000_000,
                approximateFileSizeBytes: nil,
                hasVideo: true,
                hasAudio: true,
                protocolName: "https",
                sourceType: "direct_http",
                language: "en"
            ),
            MediaFormat(
                formatID: "140",
                formatNote: "medium",
                extension: "m4a",
                container: "m4a_dash",
                videoCodec: nil,
                audioCodec: "mp4a.40.2",
                width: nil,
                height: nil,
                resolution: "audio only",
                framesPerSecond: nil,
                dynamicRange: nil,
                isHDR: false,
                audioBitrateKbps: 129,
                videoBitrateKbps: nil,
                totalBitrateKbps: 129,
                exactFileSizeBytes: 3_500_000,
                approximateFileSizeBytes: nil,
                hasVideo: false,
                hasAudio: true,
                protocolName: "https",
                sourceType: "direct_http",
                language: "en"
            ),
            MediaFormat(
                formatID: "251",
                formatNote: "medium",
                extension: "webm",
                container: "webm_dash",
                videoCodec: nil,
                audioCodec: "opus",
                width: nil,
                height: nil,
                resolution: "audio only",
                framesPerSecond: nil,
                dynamicRange: nil,
                isHDR: false,
                audioBitrateKbps: 133,
                videoBitrateKbps: nil,
                totalBitrateKbps: 133,
                exactFileSizeBytes: 3_600_000,
                approximateFileSizeBytes: nil,
                hasVideo: false,
                hasAudio: true,
                protocolName: "https",
                sourceType: "direct_http",
                language: "en"
            ),
        ]
    )

    static var videoOnlyMedia: MediaMetadata {
        metadata(
            formats: media.formats.filter { $0.hasVideo && !$0.hasAudio }
        )
    }

    static var audioOnlyMedia: MediaMetadata {
        metadata(
            formats: media.formats.filter { $0.hasAudio && !$0.hasVideo }
        )
    }

    static func metadata(formats: [MediaFormat]) -> MediaMetadata {
        MediaMetadata(
            canonicalURL: media.canonicalURL,
            videoID: media.videoID,
            title: media.title,
            channel: media.channel,
            uploader: media.uploader,
            durationSeconds: media.durationSeconds,
            uploadDate: media.uploadDate,
            description: media.description,
            isLive: media.isLive,
            liveStatus: media.liveStatus,
            thumbnails: media.thumbnails,
            chapters: media.chapters,
            subtitles: media.subtitles,
            formats: formats
        )
    }

    static let playlist = PlaylistAnalysis(
        canonicalURL: URL(
            string:
                "https://www.youtube.com/playlist?list=PLVLT000000000001"
        )!,
        playlistID: "PLVLT000000000001",
        kind: .playlist,
        referencedVideoID: "dQw4w9WgXcQ",
        title: "Illucet Road Trip Mix",
        creator: "Fixture Channel",
        thumbnailURL: URL(
            string:
                "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"
        ),
        reportedItemCount: 5,
        estimatedTotalBytes: 124_000_000,
        entries: [
            PlaylistEntry(
                index: 1,
                videoID: "dQw4w9WgXcQ",
                canonicalURL: RickURL,
                title: "Never Gonna Give You Up",
                creator: "Rick Astley",
                durationSeconds: 213,
                thumbnailURL: URL(
                    string:
                        "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"
                ),
                estimatedBytes: 36_000_000,
                availability: .available
            ),
            PlaylistEntry(
                index: 2,
                videoID: "VLT00000001",
                canonicalURL: URL(
                    string:
                        "https://www.youtube.com/watch?v=VLT00000001"
                ),
                title: "Night Drive",
                creator: "Fixture Channel",
                durationSeconds: 188,
                thumbnailURL: URL(
                    string:
                        "https://i.ytimg.com/vi/VLT00000001/maxresdefault.jpg"
                ),
                estimatedBytes: 42_000_000,
                availability: .available
            ),
            PlaylistEntry(
                index: 3,
                videoID: "VLT00000002",
                canonicalURL: URL(
                    string:
                        "https://www.youtube.com/watch?v=VLT00000002"
                ),
                title: "Morning Light",
                creator: "Fixture Channel",
                durationSeconds: 241,
                thumbnailURL: URL(
                    string:
                        "https://i.ytimg.com/vi/VLT00000002/maxresdefault.jpg"
                ),
                estimatedBytes: 46_000_000,
                availability: .available
            ),
            PlaylistEntry(
                index: 4,
                videoID: nil,
                canonicalURL: nil,
                title: "Deleted video",
                creator: nil,
                durationSeconds: nil,
                thumbnailURL: nil,
                estimatedBytes: nil,
                availability: .deleted
            ),
            PlaylistEntry(
                index: 5,
                videoID: nil,
                canonicalURL: nil,
                title: "Private video",
                creator: nil,
                durationSeconds: nil,
                thumbnailURL: nil,
                estimatedBytes: nil,
                availability: .privateVideo
            ),
        ],
        isTruncated: false
    )

    static func media(for entry: PlaylistEntry) -> MediaMetadata {
        guard let videoID = entry.videoID,
              let canonicalURL = entry.canonicalURL
        else {
            return media
        }
        return MediaMetadata(
            canonicalURL: canonicalURL,
            videoID: videoID,
            title: entry.title,
            channel: entry.creator,
            uploader: entry.creator,
            durationSeconds: entry.durationSeconds,
            uploadDate: media.uploadDate,
            description: media.description,
            isLive: false,
            liveStatus: "not_live",
            thumbnails: entry.thumbnailURL.map {
                [
                    MediaThumbnail(
                        url: $0,
                        width: 1_280,
                        height: 720,
                        id: "maxres"
                    ),
                ]
            } ?? [],
            chapters: media.chapters,
            subtitles: media.subtitles,
            formats: media.formats
        )
    }

    static var completedBatch: DownloadBatch {
        var configuration = DownloadConfiguration.standard
        configuration.maximumPlaylistItems = 25
        configuration.numberPlaylistFilenames = true
        var batch = DownloadBatch(
            id: UUID(
                uuidString: "B6000000-0000-0000-0000-000000000001"
            )!,
            analysis: playlist,
            selection: .entirePlaylist,
            configuration: configuration,
            destinationStructure: .playlistSubfolder,
            continueOnError: true,
            skipArchivedItems: true,
            numberFilenames: true,
            filenameIndexWidth: 2,
            entries: Array(playlist.entries.prefix(3)),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        batch.items[0].state = .completed
        batch.items[1].state = .failed
        batch.items[1].errorCode = "fixture_failure"
        batch.items[1].errorMessage = "Connection interrupted."
        batch.items[2].state = .skipped
        batch.state = .completedWithFailures
        batch.progress = BatchProgressAggregator.progress(
            items: batch.items,
            jobsByID: [:]
        )
        return batch
    }

    static var failedThumbnailOnlyJob: DownloadJob {
        var configuration = DownloadConfiguration.standard
        configuration.thumbnailBehavior = .thumbnailOnly
        return DownloadJob(
            id: UUID(
                uuidString: "81314000-0000-0000-0000-000000000001"
            )!,
            sourceURL: RickURL,
            videoID: media.videoID,
            title: "Failed Thumbnail Fixture",
            channel: media.channel,
            thumbnailURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            configuration: configuration,
            state: .failed,
            stage: .downloadingThumbnail,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: "fixture_thumbnail_failure",
            errorMessage: "Fixture thumbnail transfer failed.",
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
    }

    static var failedSubtitlesOnlyJob: DownloadJob {
        var configuration = DownloadConfiguration.standard
        configuration.requestKind = .subtitlesOnly
        configuration.subtitleDelivery = .sidecarVTT
        configuration.subtitleSelections = [
            SubtitleTrackSelection(
                trackID: "subtitle-111111111111111111111111",
                formatID: "subtitle-format-111111111111111111111111",
                language: "en",
                automatic: false
            ),
        ]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        return DownloadJob(
            id: UUID(
                uuidString: "81500000-0000-0000-0000-000000000001"
            )!,
            sourceURL: RickURL,
            videoID: media.videoID,
            title: "Failed Subtitles Fixture",
            channel: media.channel,
            thumbnailURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            configuration: configuration,
            state: .failed,
            stage: .downloadingSubtitles,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: "fixture_subtitle_failure",
            errorMessage: "Fixture subtitle transfer failed.",
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
    }

    static var completedSubtitlesOnlyJob: DownloadJob {
        var job = failedSubtitlesOnlyJob
        job = DownloadJob(
            id: UUID(
                uuidString: "81500000-0000-0000-0000-000000000002"
            )!,
            sourceURL: job.sourceURL,
            videoID: job.videoID,
            title: "Completed Subtitles Fixture",
            channel: job.channel,
            thumbnailURL: nil,
            createdAt: job.createdAt.addingTimeInterval(1),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            configuration: job.configuration,
            state: .completed,
            stage: .complete,
            progress: JobProgress(
                bytesDownloaded: 0,
                totalBytes: nil,
                instantaneousBytesPerSecond: nil,
                smoothedBytesPerSecond: nil,
                downloadETASeconds: nil,
                processingFraction: nil,
                processingETASeconds: nil,
                overallFraction: 1,
                overallETASeconds: nil,
                currentStream: nil,
                sampleCount: 0
            ),
            priority: 1,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: [],
            extractorVersion: "fixture"
        )
        job.subtitleSidecars = [
            SubtitleSidecarRecord(
                selection: job.configuration.subtitleSelections![0],
                kind: .webVTT,
                filename:
                    "Completed Subtitles Fixture.en.manual.11111111-11111111.vtt",
                localURL: nil
            ),
        ]
        job.exportOutcome = .shared
        job.shareCompletionState = .completed
        return job
    }

    static let archive: [DownloadArchiveEntry] = [
        .youtube(
            videoID: "dQw4w9WgXcQ",
            completedAt: Date(timeIntervalSince1970: 1_700_000_100),
            batchID: UUID(
                uuidString: "B6000000-0000-0000-0000-000000000001"
            )
        ),
        .youtube(
            videoID: "VLT00000009",
            completedAt: Date(timeIntervalSince1970: 1_699_000_000)
        ),
    ]

    static var sponsorBlockAppliedJob: DownloadJob {
        var job = failedThumbnailOnlyJob
        job.title = "SponsorBlock Applied Fixture"
        job.state = .completed
        job.stage = .complete
        job.progress.overallFraction = 1
        job.errorCode = nil
        job.errorMessage = nil
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor],
            removalMode: .fastKeyframe
        )
        policy.setAction(.remove, for: .sponsor)
        job.configuration.thumbnailBehavior = .none
        job.configuration.sponsorBlock = policy
        let requestedRange = MediaTimeRange(
            startSeconds: 18,
            endSeconds: 31.5
        )
        var application = SponsorBlockApplicationRecord.requested(
            plan: SponsorBlockPlan(
                videoID: media.videoID,
                entries: [
                    SponsorBlockPlanEntry(
                        sourceSegmentIDs: ["fixture-sponsor-001"],
                        categories: [.sponsor],
                        startSeconds: requestedRange.startSeconds,
                        endSeconds: requestedRange.endSeconds,
                        action: .remove
                    ),
                ]
            ),
            mode: .fastKeyframe
        )
        application.status = .applied
        application.actualRemovalMode = .fastKeyframe
        application.actualRemovalRanges = [
            MediaTimeRange(startSeconds: 17.75, endSeconds: 31.75),
        ]
        application.removedSegmentCount = 1
        application.removedDurationSeconds = 14
        application.sponsorBlockChapterCount = 2
        job.sponsorBlockApplication = application
        return job
    }
}

struct SponsorBlockUnavailableFixtureService: SponsorBlockServing {
    func segments(
        videoID: String,
        categories: Set<SponsorBlockCategory>
    ) async throws -> [SponsorBlockSegment] {
        throw SponsorBlockServiceError.transportFailure
    }
}
