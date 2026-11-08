import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Illucet

struct NativeBridgeCharacterizationTests {
    @Test
    func publicVersionAndJobLifecycleRemainStable() throws {
        let job = try #require(illucet_ffmpeg_job_create(nil, nil))
        defer { illucet_ffmpeg_job_destroy(job) }

        #expect(!illucet_ffmpeg_job_is_cancelled(job))
        illucet_ffmpeg_job_cancel(job)
        #expect(illucet_ffmpeg_job_is_cancelled(job))

        #expect(String(cString: illucet_ffmpeg_version()) == DependencyVersions.ffmpeg)
        let configuration = String(
            cString: illucet_ffmpeg_configuration()
        )
        #expect(configuration.contains("--disable-programs"))
        #expect(configuration.contains("--disable-network"))
        #expect(configuration.contains("--enable-libmp3lame"))

        var result: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(result)
            illucet_ffmpeg_string_free(error)
        }
        let status = illucet_ffmpeg_version_json(&result, &error)
        #expect(status == ILLUCET_FFMPEG_OK)
        #expect(error == nil)

        let bytes = try #require(
            result.map { Data(String(cString: $0).utf8) }
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: bytes)
                as? [String: Any]
        )
        #expect(object["version"] as? String == DependencyVersions.ffmpeg)
        #expect((object["avcodecVersion"] as? NSNumber)?.intValue ?? 0 > 0)
        #expect((object["avformatVersion"] as? NSNumber)?.intValue ?? 0 > 0)
        #expect(object["configuration"] as? String == configuration)
    }

    @Test
    func invalidProbeKeepsStatusAndOwnedErrorContract() {
        var result: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(result)
            illucet_ffmpeg_string_free(error)
        }

        let status = illucet_ffmpeg_probe_json(
            nil,
            nil,
            &result,
            &error
        )
        #expect(status == ILLUCET_FFMPEG_INVALID_ARGUMENT)
        #expect(result == nil)
        #expect(
            error.map { String(cString: $0) }
                == "A valid input path is required"
        )
    }

    @Test
    func explicitProbeClassesReportTheirActualVerificationWork() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7A-ProbeClass-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtures = try generateFixtures(in: root)
        let fast = try probe(
            fixtures.audioVideo,
            probeClass: ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL
        )

        #expect(fast.verificationClass == "fastStructural")
        #expect(fast.fullDecodePerformed == false)
        #expect((fast.packetsInspected ?? 0) > 0)
        #expect((fast.packetsInspected ?? .max) <= 320)
        #expect((fast.inspectedPacketBytes ?? 0) > 0)
        #expect((fast.inspectedPacketBytes ?? .max) <= 67_108_864)
        #expect(fast.tailSeekAttempted == true)
        #expect(fast.tailSeekSucceeded == true)
        #expect(fast.tailSeekReachedEOF == true)
        #expect(fast.streams.allSatisfy { $0.decodedFrames == 0 })
        #expect(fast.streams.allSatisfy { $0.packetSHA256.isEmpty })

        let bounded = try probe(
            fixtures.audioVideo,
            probeClass: ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG
        )
        let boundedMediaStreams = bounded.streams.filter {
            !$0.attachedPicture && ["audio", "video"].contains($0.type)
        }

        #expect(bounded.verificationClass == "boundedStrong")
        #expect(bounded.fullDecodePerformed == false)
        #expect((bounded.packetsInspected ?? 0) > 0)
        #expect((bounded.packetsInspected ?? .max) <= 1_856)
        #expect(bounded.tailSeekAttempted == true)
        #expect(bounded.tailSeekSucceeded == true)
        #expect(boundedMediaStreams.count == 2)
        #expect(boundedMediaStreams.allSatisfy { $0.decodedFrames > 0 })
        #expect(boundedMediaStreams.allSatisfy {
            $0.decodedSampleWindows == 3
        })
        #expect(bounded.streams.allSatisfy { $0.packetSHA256.isEmpty })

        let strong = try probe(
            fixtures.audioVideo,
            probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
        )
        let strongMediaStreams = strong.streams.filter {
            !$0.attachedPicture && ["audio", "video"].contains($0.type)
        }

        #expect(strong.verificationClass == "strongFullDecode")
        #expect(strong.fullDecodePerformed == true)
        #expect(strongMediaStreams.count == 2)
        #expect(strongMediaStreams.allSatisfy { $0.decodedFrames > 0 })
        #expect(strongMediaStreams.allSatisfy {
            $0.packetSHA256.count == 64
        })

        let legacy = try legacyProbe(fixtures.audioVideo)
        let legacyMediaStreams = legacy.streams.filter {
            !$0.attachedPicture && ["audio", "video"].contains($0.type)
        }
        #expect(legacy.verificationClass == "strongFullDecode")
        #expect(legacy.fullDecodePerformed == true)
        #expect(legacyMediaStreams.allSatisfy { $0.decodedFrames > 0 })
        #expect(legacyMediaStreams.allSatisfy {
            $0.packetSHA256.count == 64
        })

        let truncated = root.appending(path: "truncated.mp4")
        try FileManager.default.copyItem(
            at: fixtures.video,
            to: truncated
        )
        let fileSize = try #require(
            try truncated.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        try #require(fileSize > 2_048)
        do {
            let handle = try FileHandle(forWritingTo: truncated)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(fileSize - 1_024))
        }
        try expectFastProbeRejected(truncated)

        let earlyAudio = root.appending(path: "early-audio.mkv")
        try generateEarlyAudioFixture(at: earlyAudio)
        try expectFastProbeRejected(earlyAudio)
    }

    @Test
    func boundedProbeReachesEachTargetAfterABackwardLongGOPSeek() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7A-LongGOP-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let video = root.appending(path: "long-gop.mp4")
        try await writeLongGOPVideo(to: video)
        let bounded = try probe(
            video,
            probeClass: ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG
        )
        let videoStream = try #require(
            bounded.streams.first {
                $0.type == "video" && !$0.attachedPicture
            }
        )

        #expect(videoStream.decodedSampleWindows == 3)
        // With one GOP spanning the six-second fixture, the middle and
        // near-tail seeks land on the initial keyframe. Reaching their actual
        // timestamps requires decoding hundreds of frames; counting only the
        // first pre-target frame would report three. Measure the decode work
        // directly, independently of the structural probe's packet seeks.
        #expect(videoStream.decodedFrames >= 250)
        #expect((bounded.packetsInspected ?? .max) <= 1_856)
    }

    @Test
    func structuralProbeReachesTailBeyondOnePacketWindowOfLongGOPVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7A-StructuralLongGOP-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "long-gop.mp4")
        try await writeLongGOPVideo(to: video, frameCount: 420)
        let result = try probe(video, probeClass: ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL)
        #expect(result.fullDecodePerformed == false)
        #expect(result.tailSeekReachedEOF == true)
        #expect((result.packetsInspected ?? .max) <= 320)
        #expect(result.streams.allSatisfy { $0.decodedFrames == 0 })
    }

    @Test
    func mp3ArtworkProofPreservesPayloadAudioAndSupportedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7A-Artwork-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "audio-video.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        try generateFixtures(
            video: video,
            audio: audio,
            incompatible: incompatible,
            artwork: artwork
        )
        let mp3 = root.appending(path: "audio.mp3")
        let embedded = root.appending(path: "audio-artwork.mp3")
        try transcodeMP3(input: audio, output: mp3)
        try attachMP3Artwork(media: mp3, artwork: artwork, output: embedded)

        let sourceAudio = try probe(
            mp3,
            probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
        )
        let sourceArtwork = try probe(
            artwork,
            probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
        )
        let output = try probe(
            embedded,
            probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
        )
        let outputAudio = try #require(
            output.streams.first { $0.type == "audio" }
        )
        let outputArtwork = try #require(
            output.streams.first { $0.attachedPicture }
        )

        #expect(output.videoStreamCount == 0)
        #expect(output.audioStreamCount == 1)
        #expect(output.artworkCount == 1)
        #expect(outputArtwork.codec == "mjpeg")
        #expect(outputArtwork.width > 0)
        #expect(outputArtwork.height > 0)
        #expect(
            outputArtwork.packetSHA256
                == sourceArtwork.streams.first?.packetSHA256
        )
        #expect(outputArtwork.metadata["title"] == "Cover")
        #expect(outputArtwork.metadata["comment"] == "Cover (front)")
        #expect(output.metadata["comment"] == "Artwork embedded by Illucet")
        #expect(
            outputAudio.packetSHA256
                == sourceAudio.streams.first?.packetSHA256
        )
        #expect(outputAudio.decodedFrames > 0)
        #expect(abs(output.duration - sourceAudio.duration) <= 0.05)
    }

    @Test
    func localProcessingStageMeasurements() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProcessingTiming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try generateFixtures(in: root)
        let video = root.appending(path: "h264.mp4")
        try await writeLongGOPVideo(to: video, frameCount: 60)
        let audio = root.appending(path: "audio.m4a")
        let processor = NativeFFmpegMediaProcessor()
        let verification = MediaVerificationRequirements(
            expectedContainer: .mp4, expectedFileExtension: "mp4", expectedVideoStreams: 1...1,
            expectedAudioStreams: 1...1, expectedSubtitleStreams: nil, expectedVideoCodec: .h264,
            expectedAudioCodec: .aac, expectedDimensions: MediaDimensions(width: 320, height: 180), expectedFrameRate: 30, frameRateTolerance: 0.05,
            expectedHDR: false, expectedAudioSampleRate: 48_000, expectedAudioChannelCount: 2,
            expectedDurationSeconds: nil, durationToleranceSeconds: 0.1, expectedAudioBitRate: nil,
            audioBitRateToleranceFraction: 0.08, expectedChapterCount: nil, requireArtwork: nil,
            requireMetadataKeys: [], expectedMetadataValues: [:], forbiddenMetadataKeys: [],
            requiredVerificationClass: .boundedStrong)
        let encode = VideoOutputPolicy.encode(VideoEncodingSettings(codec: .h264, bitRate: 400_000,
            dimensions: nil, frameRate: nil, pixelFormat: nil, profile: nil, level: nil, acceleration: .automatic))
        func run(_ operation: MediaProcessingOperation, _ name: String, encodeVideo: Bool = false,
                 chapters: [MediaChapter] = []) async throws -> URL {
            let destination = root.appending(path: name + ".mp4")
            let start = ContinuousClock.now
            let result = try await processor.process(MediaProcessingRequest(operationID: UUID(), operation: operation,
                destinationURL: destination, output: MediaOutputSpecification(container: .mp4,
                    video: encodeVideo ? encode : .copy, audio: .copy, dynamicRange: .preserve, subtitleCodec: nil,
                    fastStart: false, preserveMetadata: false, preserveChapters: true),
                metadata: .empty, chapters: chapters, trimming: nil, overwriteExisting: false,
                verification: verification)) { _ in }
            let duration = start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            print("ILLUCET_PROCESSING_TIMING \(name) seconds=\(seconds)")
            #expect(result.probes.first?.videoStreamCount == 1)
            #expect(result.probes.first?.audioStreamCount == 1)
            return destination
        }
        let source = try await run(.merge(videoURL: video, audioURL: audio), "setup")
        for iteration in 1...3 {
            _ = try await run(.merge(videoURL: video, audioURL: audio), "merge-\(iteration)")
            _ = try await run(.writeChapters(mediaURL: source), "chapters-\(iteration)", chapters: [
                MediaChapter(title: "Intro", startSeconds: 0, endSeconds: 1),
                MediaChapter(title: "Ending", startSeconds: 1, endSeconds: 2)])
            _ = try await run(.burnSubtitles(mediaURL: source, cues: [
                MediaRenderedSubtitleCue(startSeconds: 0.2, endSeconds: 1.8, text: "English caption", trackIndex: 0)
            ]), "burn-\(iteration)", encodeVideo: true)
            _ = try await run(.removeRanges(mediaURL: source, mode: .accurate, keptRanges: [
                MediaTimeRange(startSeconds: 0, endSeconds: 0.5),
                MediaTimeRange(startSeconds: 1, endSeconds: 2)
            ]), "accurate-\(iteration)", encodeVideo: true)
        }
    }

    @Test
    func mp4VideoCoverPreservesMediaChaptersSubtitlesAndPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VideoCover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try generateFixtures(in: root)
        let video = root.appending(path: "h264.mp4")
        try await writeLongGOPVideo(to: video, frameCount: 60)
        let processor = NativeFFmpegMediaProcessor()
        let artwork = root.appending(path: "artwork.jpg")
        var configuration = DownloadConfiguration.standard
        configuration.container = .mp4
        configuration.thumbnailBehavior = .includeVideoThumbnail
        configuration.bundleStyle = .mediaOnly
        configuration = OutputCapabilityMatrix.normalized(configuration)
        FormatSelection.applyAutomaticSelection(to: &configuration, metadata: DeveloperFixtures.media)
        let plan = try OutputCapabilityMatrix.makePlan(configuration: configuration, metadata: DeveloperFixtures.media)
        let workflow = DownloadConversionWorkflow(mediaProcessor: processor)
        let metadataPolicy = ConversionMetadataPolicy(metadata: DeveloperFixtures.media, preserve: true, container: .mp4)
        func prepare(_ operation: MediaProcessingOperation, name: String, chapters: [MediaChapter] = []) async throws -> URL {
            let output = root.appending(path: name + ".mp4")
            _ = try await processor.process(MediaProcessingRequest(
                operationID: UUID(), operation: operation, destinationURL: output,
                output: MediaOutputSpecification(container: .mp4, video: .copy, audio: .copy,
                    dynamicRange: .preserve, subtitleCodec: .movText, fastStart: true,
                    preserveMetadata: true, preserveChapters: true),
                metadata: metadataPolicy.tags, chapters: chapters, trimming: nil, overwriteExisting: false,
                verification: .basicPlayback
            )) { _ in }
            return output
        }
        let merged = try await prepare(.merge(videoURL: video, audioURL: root.appending(path: "audio.m4a")), name: "merged")
        let srt = root.appending(path: "captions.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nA visible caption\n".write(to: srt, atomically: true, encoding: .utf8)
        let subtitled = try await prepare(.embedSubtitles(mediaURL: merged, subtitles: [MediaSubtitleInput(
            fileURL: srt, languageCode: "eng", title: "English", isAutomatic: false, isDefault: true, isForced: false
        )]), name: "subtitled")
        let chaptered = try await prepare(.writeChapters(mediaURL: subtitled), name: "chaptered", chapters: [
            MediaChapter(title: "Intro", startSeconds: 0, endSeconds: 1),
            MediaChapter(title: "Ending", startSeconds: 1, endSeconds: 2)
        ])
        for (index, input) in [video, chaptered].enumerated() {
            let inputProbe = try await processor.probe(input, verificationClass: .fastStructural)
            let output = root.appending(path: "covered-\(index).mp4")
            let result = try await workflow.includeVideoThumbnail(mediaURL: input, inputProbe: inputProbe,
                artworkURL: artwork, destination: output, plan: plan, operationID: UUID(), fastStart: true) { _ in }
            let actual = try #require(result.probes.first)
            #expect(actual.videoStreamCount == 1)
            #expect(actual.audioStreamCount == index)
            #expect(actual.subtitleStreamCount == index)
            #expect(actual.chapters.count == index * 2)
            if index == 1 {
                for (key, value) in metadataPolicy.expectedValues { #expect(actual.metadata[key] == value) }
            }
            let before = try probe(input, probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE)
            let after = try probe(output, probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE)
            let cover = try probe(artwork, probeClass: ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE)
            #expect(after.artworkCount == 1)
            #expect(after.streams.first { $0.attachedPicture }?.packetSHA256 == cover.streams.first?.packetSHA256)
            for kind in ["video", "audio", "subtitle"] {
                #expect(after.streams.filter { $0.type == kind && !$0.attachedPicture }.map(\.packetSHA256)
                    == before.streams.filter { $0.type == kind && !$0.attachedPicture }.map(\.packetSHA256))
            }
            let asset = AVURLAsset(url: output)
            #expect(try await asset.load(.isPlayable))
            #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        }
        let failed = root.appending(path: "missing-cover.mp4")
        do {
            _ = try await workflow.includeVideoThumbnail(mediaURL: video, inputProbe: try await processor.probe(video, verificationClass: .fastStructural),
                artworkURL: root.appending(path: "missing.jpg"), destination: failed, plan: plan,
                operationID: UUID(), fastStart: true) { _ in }
            Issue.record("Missing cover must fail")
        } catch { #expect(!FileManager.default.fileExists(atPath: failed.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("partial") })
    }

    @Test
    func cancelledVideoCoverRemovesPartialOutput() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CancelledCover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try generateFixtures(in: root)
        let output = root.appending(path: "cancelled.mp4")
        let createdJob = illucet_ffmpeg_job_create({ _, fraction, _ in fraction >= 0.1 ? 1 : 0 }, nil)
        let job = try #require(createdJob)
        defer { illucet_ffmpeg_job_destroy(job) }
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = fixtures.video.path.withCString { media in
            root.appending(path: "artwork.jpg").path.withCString { artwork in
                output.path.withCString { destination in
                    illucet_ffmpeg_attach_artwork(media, artwork, destination, ILLUCET_MEDIA_CONTAINER_MP4, true, nil, job, &rawError)
                }
            }
        }
        #expect(status == ILLUCET_FFMPEG_CANCELLED)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("partial") })
    }

    @Test
    func preCancelledFixturePublishesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-Part7A-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appending(path: "cancelled-hdr.mov")
        let job = try #require(illucet_ffmpeg_job_create(nil, nil))
        defer { illucet_ffmpeg_job_destroy(job) }
        illucet_ffmpeg_job_cancel(job)

        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        let status = output.path.withCString {
            illucet_ffmpeg_generate_hdr_fixture($0, job, &error)
        }

        #expect(status == ILLUCET_FFMPEG_CANCELLED)
        #expect(error.map { String(cString: $0) } == "Cancelled")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).filter {
            $0.contains(".illucet-partial-")
        }
        #expect(leftovers.isEmpty)
    }

    private func generateFixtures(
        in root: URL
    ) throws -> (audioVideo: URL, video: URL) {
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let audioVideo = root.appending(path: "audio-video.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        try generateFixtures(
            video: video,
            audio: audio,
            incompatible: audioVideo,
            artwork: artwork
        )
        return (audioVideo, video)
    }

    private func generateFixtures(
        video: URL,
        audio: URL,
        incompatible: URL,
        artwork: URL
    ) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(
                            videoPath,
                            audioPath,
                            incompatiblePath,
                            artworkPath,
                            nil,
                            &rawError
                        )
                    }
                }
            }
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
    }

    private func transcodeMP3(input: URL, output: URL) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                illucet_ffmpeg_transcode_audio_mp3(
                    inputPath,
                    outputPath,
                    128_000,
                    nil,
                    &rawError
                )
            }
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
    }

    private func attachMP3Artwork(
        media: URL,
        artwork: URL,
        output: URL
    ) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = media.path.withCString { mediaPath in
            artwork.path.withCString { artworkPath in
                output.path.withCString { outputPath in
                    illucet_ffmpeg_attach_mp3_artwork(
                        mediaPath,
                        artworkPath,
                        outputPath,
                        nil,
                        &rawError
                    )
                }
            }
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
    }

    private func probe(
        _ fileURL: URL,
        probeClass: IllucetFFmpegProbeClass
    ) throws -> FFmpegStage0Probe {
        var rawResult: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(rawResult)
            illucet_ffmpeg_string_free(rawError)
        }
        let status = fileURL.path.withCString {
            illucet_ffmpeg_probe_json_with_class(
                $0,
                probeClass,
                nil,
                &rawResult,
                &rawError
            )
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
        let resultPointer = try #require(rawResult)
        return try JSONDecoder().decode(
            FFmpegStage0Probe.self,
            from: Data(String(cString: resultPointer).utf8)
        )
    }

    private func generateEarlyAudioFixture(at fileURL: URL) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(rawError) }
        let status = fileURL.path.withCString {
            illucet_ffmpeg_generate_early_audio_fixture(
                $0,
                nil,
                &rawError
            )
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
    }

    private func writeLongGOPVideo(to fileURL: URL, frameCount: Int = 180) async throws {
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 400_000,
                    AVVideoMaxKeyFrameIntervalKey: frameCount + 60,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey:
                        AVVideoProfileLevelH264BaselineAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaProcessorError.nativeFailure(
                "Could not create the long-GOP fixture."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not start the long-GOP fixture."
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MediaProcessorError.nativeFailure(
                "Could not allocate the long-GOP fixture."
            )
        }
        for frameIndex in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &optionalBuffer
            ) == kCVReturnSuccess,
                let buffer = optionalBuffer
            else {
                throw MediaProcessorError.nativeFailure(
                    "Could not allocate a long-GOP fixture frame."
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw MediaProcessorError.nativeFailure(
                    "Could not access a long-GOP fixture frame."
                )
            }
            memset(base, 48, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: 30
                )
            ) else {
                throw writer.error ?? MediaProcessorError.nativeFailure(
                    "Could not append a long-GOP fixture frame."
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MediaProcessorError.nativeFailure(
                "Could not finish the long-GOP fixture."
            )
        }
    }

    private func legacyProbe(
        _ fileURL: URL
    ) throws -> FFmpegStage0Probe {
        var rawResult: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(rawResult)
            illucet_ffmpeg_string_free(rawError)
        }
        let status = fileURL.path.withCString {
            illucet_ffmpeg_probe_json(
                $0,
                nil,
                &rawResult,
                &rawError
            )
        }
        try #require(status == ILLUCET_FFMPEG_OK)
        #expect(rawError == nil)
        let resultPointer = try #require(rawResult)
        return try JSONDecoder().decode(
            FFmpegStage0Probe.self,
            from: Data(String(cString: resultPointer).utf8)
        )
    }

    private func expectFastProbeRejected(_ fileURL: URL) throws {
        var rawResult: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(rawResult)
            illucet_ffmpeg_string_free(rawError)
        }
        let status = fileURL.path.withCString {
            illucet_ffmpeg_probe_json_with_class(
                $0,
                ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL,
                nil,
                &rawResult,
                &rawError
            )
        }
        #expect(status != ILLUCET_FFMPEG_OK)
        #expect(rawResult == nil)
        #expect(rawError != nil)
    }
}
