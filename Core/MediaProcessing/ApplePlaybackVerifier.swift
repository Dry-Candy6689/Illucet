import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit

protocol ApplePlaybackVerifying: Sendable {
    func verify(fileURL: URL) async throws -> ApplePlaybackVerification
}

/// Verifies more than file existence or container readability.
///
/// A successful result means AVFoundation reported the local asset playable,
/// AVAssetReader produced decoded output for every present audio/video media
/// type. Developer verification additionally requires AVPlayer advancement;
/// production downloads pass requiresPlayerPlayback: false to avoid background playback.
struct ApplePlaybackVerifier: ApplePlaybackVerifying, Sendable {
    struct Configuration: Equatable, Sendable {
        let assetInspectionTimeoutSeconds: Double
        let sampleDecodeTimeoutSeconds: Double
        let playerReadyTimeoutSeconds: Double
        let playbackAdvanceTimeoutSeconds: Double
        let pollingIntervalSeconds: Double

        init(
            assetInspectionTimeoutSeconds: Double = 10,
            sampleDecodeTimeoutSeconds: Double = 10,
            playerReadyTimeoutSeconds: Double = 10,
            playbackAdvanceTimeoutSeconds: Double = 10,
            pollingIntervalSeconds: Double = 0.05
        ) {
            self.assetInspectionTimeoutSeconds =
                assetInspectionTimeoutSeconds
            self.sampleDecodeTimeoutSeconds = sampleDecodeTimeoutSeconds
            self.playerReadyTimeoutSeconds = playerReadyTimeoutSeconds
            self.playbackAdvanceTimeoutSeconds =
                playbackAdvanceTimeoutSeconds
            self.pollingIntervalSeconds = pollingIntervalSeconds
        }
    }

    private static let requiredPlaybackAdvanceSeconds = 0.2

    let requiresPlayerPlayback: Bool
    private let configuration: Configuration

    init(configuration: Configuration = .init(), requiresPlayerPlayback: Bool = true) {
        self.requiresPlayerPlayback = requiresPlayerPlayback
        self.configuration = configuration
    }

    func verify(fileURL: URL) async throws -> ApplePlaybackVerification {
        try Self.validate(configuration)
        try Task.checkCancellation()

        guard fileURL.isFileURL else {
            throw ApplePlaybackVerifierError.nonFileURL
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw ApplePlaybackVerifierError.fileUnavailable(fileURL)
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ApplePlaybackVerifierError.fileUnreadable(fileURL)
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw ApplePlaybackVerifierError.emptyFile
        }

        let startedAt = ContinuousClock.now
        let inspection: AssetInspection
        do {
            inspection = try await Self.runBoundedDetached(
                stage: .assetInspection,
                timeoutSeconds:
                    configuration.assetInspectionTimeoutSeconds
            ) {
                let asset = AVURLAsset(url: fileURL)
                let isPlayable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                let duration = try await asset.load(.duration)
                try Task.checkCancellation()
                let videoTracks = try await asset.loadTracks(
                    withMediaType: .video
                )
                try Task.checkCancellation()
                let audioTracks = try await asset.loadTracks(
                    withMediaType: .audio
                )
                try Task.checkCancellation()
                return AssetInspection(
                    isPlayable: isPlayable,
                    durationSeconds: Self.finiteSeconds(duration),
                    videoTrackCount: videoTracks.count,
                    audioTrackCount: audioTracks.count
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ApplePlaybackVerifierError {
            throw error
        } catch {
            throw ApplePlaybackVerifierError.assetInspectionFailed(
                error.localizedDescription
            )
        }

        guard inspection.isPlayable else {
            throw ApplePlaybackVerifierError.assetNotPlayable
        }
        guard
            inspection.videoTrackCount > 0
                || inspection.audioTrackCount > 0
        else {
            throw ApplePlaybackVerifierError.noAudioOrVideoTracks
        }

        var decodedSamples: [AppleDecodedSampleEvidence] = []
        if inspection.videoTrackCount > 0 {
            decodedSamples.append(
                try await Self.decodeFirstSample(
                    fileURL: fileURL,
                    kind: .video,
                    timeoutSeconds:
                        configuration.sampleDecodeTimeoutSeconds
                )
            )
        }
        if inspection.audioTrackCount > 0 {
            decodedSamples.append(
                try await Self.decodeFirstSample(
                    fileURL: fileURL,
                    kind: .audio,
                    timeoutSeconds:
                        configuration.sampleDecodeTimeoutSeconds
                )
            )
        }

        try Task.checkCancellation()
        let advance: Double
        if requiresPlayerPlayback {
            advance = try await Self.verifyPlayerPlayback(fileURL: fileURL, configuration: configuration).advanceSeconds
        } else {
            // Downloads validate actual decoded samples without trying to play
            // video in a background app. Runtime Proof still exercises AVPlayer.
            advance = 0
        }
        try Task.checkCancellation()
        let elapsed = Self.seconds(
            from: startedAt.duration(to: ContinuousClock.now)
        )

        return ApplePlaybackVerification(
            fileURL: fileURL,
            fileSize: fileSize,
            assetDurationSeconds: inspection.durationSeconds,
            videoTrackCount: inspection.videoTrackCount,
            audioTrackCount: inspection.audioTrackCount,
            decodedSamples: decodedSamples,
            playerItemBecameReady: requiresPlayerPlayback,
            playbackAdvanceSeconds: advance,
            verificationElapsedSeconds: elapsed
        )
    }

    private static func validate(_ configuration: Configuration) throws {
        let timeoutValues = [
            configuration.assetInspectionTimeoutSeconds,
            configuration.sampleDecodeTimeoutSeconds,
            configuration.playerReadyTimeoutSeconds,
            configuration.playbackAdvanceTimeoutSeconds,
        ]
        guard timeoutValues.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ApplePlaybackVerifierError.invalidConfiguration(
                "All timeout values must be finite and greater than zero."
            )
        }
        guard
            configuration.pollingIntervalSeconds.isFinite,
            configuration.pollingIntervalSeconds >= 0.01,
            configuration.pollingIntervalSeconds <= 1
        else {
            throw ApplePlaybackVerifierError.invalidConfiguration(
                "The polling interval must be between 0.01 and 1 second."
            )
        }
    }

    private static func runBoundedDetached<Value: Sendable>(
        stage: ApplePlaybackVerificationStage,
        timeoutSeconds: Double,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let cancellation = BoundedTaskCancellationState()
        let work = Task.detached(priority: .utility) {
            do {
                let value = try await operation()
                guard cancellation.markCompleted() else {
                    throw terminalCancellationError(
                        cancellation,
                        stage: stage,
                        timeoutSeconds: timeoutSeconds
                    )
                }
                return value
            } catch {
                if cancellation.markCompleted() {
                    throw error
                }
                throw terminalCancellationError(
                    cancellation,
                    stage: stage,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }

        return try await awaitSoftDeadline(
            work: work,
            stage: stage,
            timeoutSeconds: timeoutSeconds,
            cancellation: cancellation
        )
    }

    private static func decodeFirstSample(
        fileURL: URL,
        kind: AppleDecodedMediaKind,
        timeoutSeconds: Double
    ) async throws -> AppleDecodedSampleEvidence {
        let readerCancellation = BoundedTaskCancellationState()
        let work = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()

                let asset = AVURLAsset(url: fileURL)
                let tracks = try await asset.loadTracks(
                    withMediaType: kind.avMediaType
                )
                guard let track = tracks.first else {
                    throw ApplePlaybackVerifierError.trackDisappeared(kind)
                }
                try Task.checkCancellation()

                let reader: AVAssetReader
                do {
                    reader = try AVAssetReader(asset: asset)
                } catch {
                    throw ApplePlaybackVerifierError.readerCreationFailed(
                        kind: kind,
                        reason: error.localizedDescription
                    )
                }
                defer {
                    // AVAssetReader explicitly forbids calling
                    // cancelReading concurrently with copyNextSampleBuffer.
                    // Both calls therefore remain on this worker.
                    if reader.status == .reading {
                        reader.cancelReading()
                    }
                }

                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: kind.outputSettings
                )
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    throw ApplePlaybackVerifierError.readerOutputRejected(kind)
                }
                reader.add(output)

                try Task.checkCancellation()
                guard reader.startReading() else {
                    throw ApplePlaybackVerifierError.readerStartFailed(
                        kind: kind,
                        reason: reader.error?.localizedDescription
                            ?? "No AVAssetReader error was provided."
                    )
                }

                guard let sample = output.copyNextSampleBuffer() else {
                    if readerCancellation.reason == .timeout {
                        throw ApplePlaybackVerifierError.timedOut(
                            stage: kind.verificationStage,
                            seconds: timeoutSeconds
                        )
                    }
                    if
                        readerCancellation.reason == .task
                            || Task.isCancelled
                    {
                        throw CancellationError()
                    }
                    throw ApplePlaybackVerifierError.noDecodedSample(
                        kind: kind,
                        reason: reader.error?.localizedDescription
                            ?? "The reader returned no sample."
                    )
                }
                if readerCancellation.reason == .timeout {
                    throw ApplePlaybackVerifierError.timedOut(
                        stage: kind.verificationStage,
                        seconds: timeoutSeconds
                    )
                }
                try Task.checkCancellation()

                guard
                    CMSampleBufferIsValid(sample),
                    CMSampleBufferDataIsReady(sample)
                else {
                    throw ApplePlaybackVerifierError.invalidDecodedSample(kind)
                }

                let dimensions: MediaDimensions?
                let audioSampleCount: Int?
                switch kind {
                case .video:
                    guard
                        let pixelBuffer =
                            CMSampleBufferGetImageBuffer(sample),
                        CVPixelBufferGetWidth(pixelBuffer) > 0,
                        CVPixelBufferGetHeight(pixelBuffer) > 0
                    else {
                        throw ApplePlaybackVerifierError
                            .missingDecodedPixelBuffer
                    }
                    dimensions = MediaDimensions(
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer)
                    )
                    audioSampleCount = nil

                case .audio:
                    guard
                        let description =
                            CMSampleBufferGetFormatDescription(sample),
                        let audioDescription =
                            CMAudioFormatDescriptionGetStreamBasicDescription(
                                description
                            ),
                        audioDescription.pointee.mFormatID
                            == kAudioFormatLinearPCM,
                        CMSampleBufferGetNumSamples(sample) > 0
                    else {
                        throw ApplePlaybackVerifierError
                            .missingLinearPCMAudio
                    }
                    dimensions = nil
                    audioSampleCount = CMSampleBufferGetNumSamples(sample)
                }

                let evidence = AppleDecodedSampleEvidence(
                    kind: kind,
                    presentationTimeSeconds: Self.finiteSeconds(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    ),
                    videoDimensions: dimensions,
                    audioSampleCount: audioSampleCount
                )
                guard readerCancellation.markCompleted() else {
                    throw terminalCancellationError(
                        readerCancellation,
                        stage: kind.verificationStage,
                        timeoutSeconds: timeoutSeconds
                    )
                }
                return evidence
            } catch {
                if readerCancellation.markCompleted() {
                    throw error
                }
                throw terminalCancellationError(
                    readerCancellation,
                    stage: kind.verificationStage,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }

        return try await awaitSoftDeadline(
            work: work,
            stage: kind.verificationStage,
            timeoutSeconds: timeoutSeconds,
            cancellation: readerCancellation
        )
    }

    /// Requests cooperative cancellation at the deadline, then awaits the
    /// owning worker so no AVFoundation object outlives the operation. A
    /// synchronous framework call already in progress cannot be forcibly
    /// interrupted, so this is intentionally a soft deadline.
    private static func awaitSoftDeadline<Value: Sendable>(
        work: Task<Value, any Error>,
        stage: ApplePlaybackVerificationStage,
        timeoutSeconds: Double,
        cancellation: BoundedTaskCancellationState
    ) async throws -> Value {
        let deadlineTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            if cancellation.cancel(reason: .timeout) {
                work.cancel()
            }
        }
        defer {
            deadlineTask.cancel()
        }
        return try await withTaskCancellationHandler {
            do {
                return try await work.value
            } catch is CancellationError {
                if cancellation.reason == .timeout {
                    throw ApplePlaybackVerifierError.timedOut(
                        stage: stage,
                        seconds: timeoutSeconds
                    )
                }
                throw CancellationError()
            }
        } onCancel: {
            if cancellation.cancel(reason: .task) {
                work.cancel()
            }
        }
    }

    private static func terminalCancellationError(
        _ cancellation: BoundedTaskCancellationState,
        stage: ApplePlaybackVerificationStage,
        timeoutSeconds: Double
    ) -> any Error {
        if cancellation.reason == .timeout {
            return ApplePlaybackVerifierError.timedOut(
                stage: stage,
                seconds: timeoutSeconds
            )
        }
        return CancellationError()
    }

    /// Actual playback requires a foreground app; a background restriction is not
    /// evidence that a structurally verified media file is broken.
    @MainActor
    static func requireForeground(_ state: UIApplication.State, interrupted: Bool = false) throws {
        guard state == .active, !interrupted else {
            throw ApplePlaybackVerifierError.requiresForeground
        }
    }

    @MainActor
    private static func verifyPlayerPlayback(
        fileURL: URL,
        configuration: Configuration
    ) async throws -> PlayerPlaybackEvidence {
        try Task.checkCancellation()

        let interruption = PlaybackForegroundInterruption()
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
        ) { _ in interruption.mark() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try requireForeground(UIApplication.shared.applicationState, interrupted: interruption.occurred)
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let readyDeadline = ContinuousClock.now.advanced(
            by: .seconds(configuration.playerReadyTimeoutSeconds)
        )
        while true {
            try Task.checkCancellation()
            try requireForeground(UIApplication.shared.applicationState, interrupted: interruption.occurred)
            if let error = item.error {
                throw ApplePlaybackVerifierError.playerItemFailed(
                    error.localizedDescription
                )
            }
            if let error = player.error {
                throw ApplePlaybackVerifierError.playerFailed(
                    error.localizedDescription
                )
            }
            if item.status == .failed {
                throw ApplePlaybackVerifierError.playerItemFailed(
                    item.error?.localizedDescription
                        ?? "AVPlayerItem entered the failed state."
                )
            }
            if player.status == .failed {
                throw ApplePlaybackVerifierError.playerFailed(
                    player.error?.localizedDescription
                        ?? "AVPlayer entered the failed state."
                )
            }
            if
                item.status == .readyToPlay,
                player.status == .readyToPlay
            {
                break
            }
            guard ContinuousClock.now < readyDeadline else {
                throw ApplePlaybackVerifierError.timedOut(
                    stage: .playerReadiness,
                    seconds: configuration.playerReadyTimeoutSeconds
                )
            }
            try await Task.sleep(
                for: .seconds(configuration.pollingIntervalSeconds)
            )
        }

        let baselineSeconds = finiteSeconds(player.currentTime()) ?? 0
        player.playImmediately(atRate: 1)

        let advanceDeadline = ContinuousClock.now.advanced(
            by: .seconds(configuration.playbackAdvanceTimeoutSeconds)
        )
        while true {
            try Task.checkCancellation()
            try requireForeground(UIApplication.shared.applicationState, interrupted: interruption.occurred)
            if let error = item.error {
                throw ApplePlaybackVerifierError.playerItemFailed(
                    error.localizedDescription
                )
            }
            if let error = player.error {
                throw ApplePlaybackVerifierError.playerFailed(
                    error.localizedDescription
                )
            }
            if item.status == .failed {
                throw ApplePlaybackVerifierError.playerItemFailed(
                    item.error?.localizedDescription
                        ?? "AVPlayerItem entered the failed state."
                )
            }

            let currentSeconds =
                finiteSeconds(player.currentTime()) ?? baselineSeconds
            let advanceSeconds = max(
                0,
                currentSeconds - baselineSeconds
            )
            if advanceSeconds > requiredPlaybackAdvanceSeconds {
                return PlayerPlaybackEvidence(
                    advanceSeconds: advanceSeconds
                )
            }

            guard ContinuousClock.now < advanceDeadline else {
                let waitingReason =
                    player.reasonForWaitingToPlay?.rawValue
                    ?? "none"
                throw ApplePlaybackVerifierError.playbackDidNotAdvance(
                    observedSeconds: advanceSeconds,
                    waitingReason: waitingReason
                )
            }
            try await Task.sleep(
                for: .seconds(configuration.pollingIntervalSeconds)
            )
        }
    }

    private static func finiteSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, !time.isIndefinite else {
            return nil
        }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : nil
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

struct ApplePlaybackVerification: Codable, Equatable, Sendable {
    let fileURL: URL
    let fileSize: Int64
    let assetDurationSeconds: Double?
    let videoTrackCount: Int
    let audioTrackCount: Int
    let decodedSamples: [AppleDecodedSampleEvidence]
    let playerItemBecameReady: Bool
    let playbackAdvanceSeconds: Double
    let verificationElapsedSeconds: Double
}

struct AppleDecodedSampleEvidence: Codable, Equatable, Sendable {
    let kind: AppleDecodedMediaKind
    let presentationTimeSeconds: Double?
    let videoDimensions: MediaDimensions?
    let audioSampleCount: Int?
}

enum AppleDecodedMediaKind: String, Codable, Equatable, Sendable {
    case video
    case audio

    fileprivate var avMediaType: AVMediaType {
        switch self {
        case .video:
            .video
        case .audio:
            .audio
        }
    }

    fileprivate var verificationStage: ApplePlaybackVerificationStage {
        switch self {
        case .video:
            .videoDecoding
        case .audio:
            .audioDecoding
        }
    }

    fileprivate var outputSettings: [String: Any] {
        switch self {
        case .video:
            [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ]
        case .audio:
            [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}

enum ApplePlaybackVerificationStage: String, Codable, Equatable, Sendable {
    case assetInspection
    case videoDecoding
    case audioDecoding
    case playerReadiness
    case playbackAdvance
}

enum ApplePlaybackVerifierError: LocalizedError, Equatable, Sendable {
    case requiresForeground
    case invalidConfiguration(String)
    case nonFileURL
    case fileUnavailable(URL)
    case fileUnreadable(URL)
    case emptyFile
    case assetInspectionFailed(String)
    case assetNotPlayable
    case noAudioOrVideoTracks
    case trackDisappeared(AppleDecodedMediaKind)
    case readerCreationFailed(
        kind: AppleDecodedMediaKind,
        reason: String
    )
    case readerOutputRejected(AppleDecodedMediaKind)
    case readerStartFailed(
        kind: AppleDecodedMediaKind,
        reason: String
    )
    case noDecodedSample(
        kind: AppleDecodedMediaKind,
        reason: String
    )
    case invalidDecodedSample(AppleDecodedMediaKind)
    case missingDecodedPixelBuffer
    case missingLinearPCMAudio
    case playerItemFailed(String)
    case playerFailed(String)
    case playbackDidNotAdvance(
        observedSeconds: Double,
        waitingReason: String
    )
    case timedOut(
        stage: ApplePlaybackVerificationStage,
        seconds: Double
    )
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            "Invalid playback-verifier configuration: \(reason)"
        case .nonFileURL:
            "Apple playback verification requires a local file URL."
        case let .fileUnavailable(url):
            "The output file is unavailable: \(url.lastPathComponent)"
        case let .fileUnreadable(url):
            "The output file is not readable: \(url.lastPathComponent)"
        case .emptyFile:
            "The output file is empty."
        case let .assetInspectionFailed(reason):
            "AVFoundation could not inspect the output: \(reason)"
        case .assetNotPlayable:
            "AVFoundation reports that the output is not playable."
        case .noAudioOrVideoTracks:
            "AVFoundation found no audio or video tracks."
        case let .trackDisappeared(kind):
            "The \(kind.rawValue) track disappeared during verification."
        case let .readerCreationFailed(kind, reason):
            "Could not create the \(kind.rawValue) decoder: \(reason)"
        case let .readerOutputRejected(kind):
            "AVAssetReader rejected decoded \(kind.rawValue) output."
        case let .readerStartFailed(kind, reason):
            "The \(kind.rawValue) decoder could not start: \(reason)"
        case let .noDecodedSample(kind, reason):
            "No decoded \(kind.rawValue) sample was produced: \(reason)"
        case let .invalidDecodedSample(kind):
            "The decoded \(kind.rawValue) sample was invalid or not ready."
        case .missingDecodedPixelBuffer:
            "Video decoding did not produce a valid pixel buffer."
        case .missingLinearPCMAudio:
            "Audio decoding did not produce a linear-PCM sample."
        case let .playerItemFailed(reason):
            "AVPlayerItem failed: \(reason)"
        case let .playerFailed(reason):
            "AVPlayer failed: \(reason)"
        case .requiresForeground:
            "Open Illucet and retry to finish checking playback. Your downloaded media has been kept."
        case let .playbackDidNotAdvance(seconds, waitingReason):
            "AVPlayer advanced only \(seconds) seconds; "
                + "waiting reason: \(waitingReason)."
        case let .timedOut(stage, seconds):
            "The \(seconds)-second soft deadline was reached during "
                + "\(stage.rawValue); the active Apple framework call was "
                + "allowed to return before verification stopped."
        case let .internalFailure(reason):
            "Playback verification failed internally: \(reason)"
        }
    }
}

private struct AssetInspection: Sendable {
    let isPlayable: Bool
    let durationSeconds: Double?
    let videoTrackCount: Int
    let audioTrackCount: Int
}

private struct PlayerPlaybackEvidence: Sendable {
    let advanceSeconds: Double
}

private enum VerificationCancellationReason: Sendable {
    case task
    case timeout
}

private final class BoundedTaskCancellationState: @unchecked Sendable {
    private enum State {
        case pending
        case completed
        case cancelled(VerificationCancellationReason)
    }

    private let lock = NSLock()
    private var state = State.pending

    var reason: VerificationCancellationReason? {
        lock.withLock {
            if case let .cancelled(reason) = state {
                return reason
            }
            return nil
        }
    }

    @discardableResult
    func cancel(reason: VerificationCancellationReason) -> Bool {
        lock.withLock {
            guard case .pending = state else {
                return false
            }
            state = .cancelled(reason)
            return true
        }
    }

    func markCompleted() -> Bool {
        lock.withLock {
            guard case .pending = state else {
                return false
            }
            state = .completed
            return true
        }
    }
}

/// The player loop may be suspended until the app is active again. Remember the
/// interruption so elapsed wall time cannot turn that suspension into a bad-file error.
private final class PlaybackForegroundInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var occurred: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}
