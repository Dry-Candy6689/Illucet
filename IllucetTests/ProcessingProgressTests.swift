import Foundation
import Testing
@testable import Illucet

private final class NativeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [FFmpegStage0ProgressEvent] = []

    var events: [FFmpegStage0ProgressEvent] {
        lock.withLock { storedEvents }
    }

    func record(stage: String, progress: Double) {
        lock.withLock {
            storedEvents.append(
                FFmpegStage0ProgressEvent(
                    stage: stage,
                    progress: progress
                )
            )
        }
    }
}

private func boundedNativeProgressCallback(
    _ stage: UnsafePointer<CChar>?,
    _ progress: Double,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let stage, let context else { return 0 }
    let recorder = Unmanaged<NativeProgressRecorder>
        .fromOpaque(context)
        .takeUnretainedValue()
    recorder.record(stage: String(cString: stage), progress: progress)
    return 0
}

@Suite("Bounded processing progress")
struct ProcessingProgressTests {
    @Test
    func controlledNativeProofHasBoundedTruthfulCallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-NativeProgress-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = NativeProgressRecorder()
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        var result: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(result)
            illucet_ffmpeg_string_free(error)
        }
        let started = ContinuousClock.now
        let status = root.path.withCString { path in
            illucet_ffmpeg_run_stage0_proof(
                path,
                boundedNativeProgressCallback,
                context,
                &result,
                &error
            )
        }
        let elapsed = started.duration(to: .now)
        #expect(status == ILLUCET_FFMPEG_OK)
        #expect(error == nil)
        let resultPointer = try #require(result)
        let proof = try JSONDecoder().decode(
            FFmpegStage0Proof.self,
            from: Data(String(cString: resultPointer).utf8)
        )
        let events = recorder.events
        let counts = Dictionary(grouping: events, by: \.stage)
        let progressStages = Set(proof.operations.map(\.progressStage))

        #expect(Set(counts.keys) == progressStages)
        #expect(events.count <= progressStages.count * 32)
        #expect(counts.values.allSatisfy { 3 ... 32 ~= $0.count })
        #expect(
            FFmpegStage0ProofRunner.validatesProgress(
                events,
                operations: proof.operations
            )
        )
        print(
            "native_progress_measurement callbacks=\(events.count) "
                + "elapsed=\(elapsed) counts="
                + counts.map { "\($0.key)=\($0.value.count)" }
                    .sorted()
                    .joined(separator: ",")
        )
    }

    @Test
    func representativeMergeBoundsNativeCallbacksWithoutSlowingOperation()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-MergeProgress-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "incompatible.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        let merged = root.appending(path: "merged.mp4")
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        let fixtureStatus = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(
                            videoPath,
                            audioPath,
                            incompatiblePath,
                            artworkPath,
                            nil,
                            &error
                        )
                    }
                }
            }
        }
        try #require(fixtureStatus == ILLUCET_FFMPEG_OK)
        illucet_ffmpeg_string_free(error)
        error = nil

        let recorder = NativeProgressRecorder()
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        let rawJob = illucet_ffmpeg_job_create(
            boundedNativeProgressCallback,
            context
        )
        let job = try #require(rawJob)
        defer { illucet_ffmpeg_job_destroy(job) }
        let started = ContinuousClock.now
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                merged.path.withCString { outputPath in
                    illucet_ffmpeg_merge_stream_copy(
                        videoPath,
                        audioPath,
                        outputPath,
                        job,
                        &error
                    )
                }
            }
        }
        let elapsed = started.duration(to: .now)
        let events = recorder.events

        #expect(status == ILLUCET_FFMPEG_OK)
        #expect(error == nil)
        #expect(events.count >= 3)
        #expect(events.count <= 16)
        #expect(events.allSatisfy { $0.stage == "merge" })
        #expect(events.first?.progress == 0)
        #expect(events.last?.progress == 1)
        #expect(events.contains { $0.progress > 0 && $0.progress < 1 })
        #expect(elapsed < .seconds(1))
        print(
            "native_merge_measurement callbacks=\(events.count) "
                + "elapsed=\(elapsed)"
        )
    }

    @Test
    func preCancelledNativeMergeExitsPromptly() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-CancelledMerge-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "video.mp4")
        let audio = root.appending(path: "audio.m4a")
        let incompatible = root.appending(path: "incompatible.mkv")
        let artwork = root.appending(path: "artwork.jpg")
        let merged = root.appending(path: "cancelled.mp4")
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        let fixtureStatus = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(
                            videoPath,
                            audioPath,
                            incompatiblePath,
                            artworkPath,
                            nil,
                            &error
                        )
                    }
                }
            }
        }
        try #require(fixtureStatus == ILLUCET_FFMPEG_OK)
        illucet_ffmpeg_string_free(error)
        error = nil
        let job = try #require(illucet_ffmpeg_job_create(nil, nil))
        defer { illucet_ffmpeg_job_destroy(job) }
        illucet_ffmpeg_job_cancel(job)

        let started = ContinuousClock.now
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                merged.path.withCString { outputPath in
                    illucet_ffmpeg_merge_stream_copy(
                        videoPath,
                        audioPath,
                        outputPath,
                        job,
                        &error
                    )
                }
            }
        }
        let elapsed = started.duration(to: .now)
        #expect(status == ILLUCET_FFMPEG_CANCELLED)
        #expect(!FileManager.default.fileExists(atPath: merged.path))
        #expect(elapsed < .milliseconds(100))
    }

    @Test
    func nativeStageMappingPreservesOperationIdentity() {
        #expect(NativeFFmpegProgressMapping.stage("merge") == .muxing)
        #expect(NativeFFmpegProgressMapping.stage("remux") == .muxing)
        #expect(NativeFFmpegProgressMapping.stage("audio-copy") == .muxing)
        #expect(NativeFFmpegProgressMapping.stage("video-only") == .muxing)
        #expect(
            NativeFFmpegProgressMapping.stage("audio-mp3") == .encoding
        )
        #expect(
            NativeFFmpegProgressMapping.stage("video-transcode")
                == .encoding
        )
        #expect(
            NativeFFmpegProgressMapping.stage("artwork")
                == .attachingArtwork
        )
        #expect(
            NativeFFmpegProgressMapping.stage("subtitle-embed")
                == .embeddingSubtitles
        )
    }

    @Test
    func noisyProducerDeliversBoundedNewestProgressAndPromptFinalTruth()
        async
    {
        let recorder = ProcessingProgressRecorder()
        let operationID = UUID()
        let relay = ProcessingProgressRelay(
            minimumDeliveryInterval: .milliseconds(25)
        ) { progress in
            await recorder.record(progress)
        }
        let started = ContinuousClock.now

        for index in 0 ... 10_000 {
            relay.report(
                progress(
                    operationID: operationID,
                    stage: .muxing,
                    fraction: Double(index) / 10_001
                )
            )
        }
        relay.report(
            progress(
                operationID: operationID,
                stage: .muxing,
                fraction: 1
            )
        )
        await relay.finish()

        let delivered = await recorder.events
        let elapsed = started.duration(to: .now)
        #expect(delivered.count <= 4)
        #expect(delivered.first?.completedFraction == 0)
        #expect(
            delivered.dropFirst().contains {
                guard let fraction = $0.completedFraction else {
                    return false
                }
                return fraction > 0 && fraction < 1
            }
        )
        #expect(delivered.last?.completedFraction == 1)
        #expect(elapsed < .milliseconds(250))
        print(
            "swift_progress_measurement opportunities=10002 "
                + "delivered=\(delivered.count) elapsed=\(elapsed)"
        )
    }

    @Test
    func laterStageInvalidatesThousandsOfObsoletePendingValues() async {
        let recorder = ProcessingProgressRecorder(
            deliveryDelay: .milliseconds(10)
        )
        let operationID = UUID()
        let relay = ProcessingProgressRelay(
            minimumDeliveryInterval: .milliseconds(25)
        ) { progress in
            await recorder.record(progress)
        }

        for index in 0 ... 10_000 {
            relay.report(
                progress(
                    operationID: operationID,
                    stage: .encoding,
                    fraction: Double(index) / 10_001
                )
            )
        }
        let stageFinished = ContinuousClock.now
        relay.report(
            progress(
                operationID: operationID,
                stage: .probing,
                fraction: nil
            )
        )
        relay.report(
            progress(
                operationID: operationID,
                stage: .verifying,
                fraction: nil
            )
        )
        await relay.finish()

        let delivered = await recorder.events
        let latency = stageFinished.duration(to: .now)
        #expect(delivered.count <= 4)
        #expect(delivered.last?.stage == .verifying)
        #expect(latency < .milliseconds(250))
        print(
            "swift_stage_latency_measurement opportunities=10003 "
                + "delivered=\(delivered.count) latency=\(latency)"
        )
    }

    @Test
    func reportAfterWorkerBecameIdleStartsFreshDrainAndFinishReturns()
        async
    {
        let recorder = ProcessingProgressRecorder()
        let operationID = UUID()
        let relay = ProcessingProgressRelay(
            minimumDeliveryInterval: .zero
        ) { progress in
            await recorder.record(progress)
        }

        relay.report(
            progress(
                operationID: operationID,
                stage: .muxing,
                fraction: 0
            )
        )
        await relay.finish()
        relay.report(
            progress(
                operationID: operationID,
                stage: .muxing,
                fraction: 1
            )
        )
        await relay.finish()

        let delivered = await recorder.events
        #expect(delivered.map(\.completedFraction) == [0, 1])
    }

    private func progress(
        operationID: UUID,
        stage: MediaProcessingStage,
        fraction: Double?
    ) -> MediaProcessingProgress {
        MediaProcessingProgress(
            operationID: operationID,
            stage: stage,
            completedFraction: fraction,
            processedMediaSeconds: nil,
            totalMediaSeconds: nil,
            processedBytes: nil,
            estimatedRemainingSeconds: nil
        )
    }
}

private actor ProcessingProgressRecorder {
    private(set) var events: [MediaProcessingProgress] = []
    private let deliveryDelay: Duration

    init(deliveryDelay: Duration = .zero) {
        self.deliveryDelay = deliveryDelay
    }

    func record(_ progress: MediaProcessingProgress) async {
        if deliveryDelay > .zero {
            try? await Task.sleep(for: deliveryDelay)
        }
        events.append(progress)
    }
}
