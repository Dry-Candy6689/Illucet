import CryptoKit
import Foundation

private final class FFmpegStage0ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var storedEvents: [FFmpegStage0ProgressEvent] = []

    var events: [FFmpegStage0ProgressEvent] {
        lock.withLock { storedEvents }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
        }
    }

    func pollCancellation() -> Bool {
        lock.withLock { cancellationRequested }
    }

    func record(stage: String, progress: Double) -> Bool {
        lock.withLock {
            if storedEvents.count < 4_096 {
                storedEvents.append(
                    FFmpegStage0ProgressEvent(
                        stage: stage,
                        progress: progress
                    )
                )
            }
            return cancellationRequested
        }
    }
}

private func ffmpegStage0ProgressCallback(
    _ stage: UnsafePointer<CChar>?,
    _ progress: Double,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else {
        return 1
    }
    let recorder = Unmanaged<FFmpegStage0ProgressRecorder>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard let stage else {
        return recorder.pollCancellation() ? 1 : 0
    }
    let stageText = String(cString: stage)
    return recorder.record(stage: stageText, progress: progress) ? 1 : 0
}

private enum FFmpegStage0RunnerError: LocalizedError {
    case nativeFailure(status: String, message: String)
    case missingResult
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case let .nativeFailure(status, message):
            "Native FFmpeg proof failed with status \(status): \(message)"
        case .missingResult:
            "Native FFmpeg proof returned no result JSON."
        case .invalidUTF8:
            "Native FFmpeg proof returned invalid UTF-8."
        }
    }
}

enum FFmpegStage0ProofRunner {
    private static let requiredProgressStages: [String: String] = [
        "fixture-video": "fixture-video",
        "fixture-audio": "fixture-audio",
        "fixture-incompatible": "fixture-incompatible",
        "fixture-artwork": "fixture-artwork",
        "merge": "merge",
        "audio-copy": "audio-copy",
        "video-only": "video-only",
        "mp3-128k": "audio-mp3",
        "compatible-mp4": "video-transcode",
        "mp3-artwork": "artwork",
    ]
    private static let requiredIDs = Set(requiredProgressStages.keys)

    static func run() async -> [Stage0Check] {
        let recorder = FFmpegStage0ProgressRecorder()
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let outputRoot = documents.appending(
                path: "Stage0FFmpegOutputs",
                directoryHint: .isDirectory
            )
            let runRoot = outputRoot.appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: runRoot,
                withIntermediateDirectories: true
            )

            let json = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try runNativeProof(
                        outputRoot: runRoot,
                        recorder: recorder
                    )
                }.value
            } onCancel: {
                recorder.cancel()
            }
            let rawData = Data(json.utf8)
            try rawData.write(
                to: documents.appending(path: "Stage0FFmpegReport.json"),
                options: .atomic
            )

            let proof = try JSONDecoder().decode(
                FFmpegStage0Proof.self,
                from: rawData
            )
            try persistEvidence(
                rawData: rawData,
                proof: proof,
                progressEvents: recorder.events,
                documents: documents
            )
            return await validate(
                proof,
                allowedRoot: runRoot,
                progressEvents: recorder.events
            )
        } catch {
            return [
                failed(
                    id: "ffmpeg-stage0-proof",
                    name: "Run controlled in-process FFmpeg proof",
                    evidence: error.localizedDescription
                ),
            ]
        }
    }

    private static func runNativeProof(
        outputRoot: URL,
        recorder: FFmpegStage0ProgressRecorder
    ) throws -> String {
        var resultPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            illucet_ffmpeg_string_free(resultPointer)
            illucet_ffmpeg_string_free(errorPointer)
        }

        let context = Unmanaged.passUnretained(recorder).toOpaque()
        let status = outputRoot.path.withCString { outputPath in
            illucet_ffmpeg_run_stage0_proof(
                outputPath,
                ffmpegStage0ProgressCallback,
                context,
                &resultPointer,
                &errorPointer
            )
        }
        guard status == ILLUCET_FFMPEG_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? "No native error detail was returned."
            throw FFmpegStage0RunnerError.nativeFailure(
                status: String(describing: status),
                message: message
            )
        }
        guard let resultPointer else {
            throw FFmpegStage0RunnerError.missingResult
        }
        guard let result = String(validatingCString: resultPointer) else {
            throw FFmpegStage0RunnerError.invalidUTF8
        }
        return result
    }

    private static func persistEvidence(
        rawData: Data,
        proof: FFmpegStage0Proof,
        progressEvents: [FFmpegStage0ProgressEvent],
        documents: URL
    ) throws {
        #if targetEnvironment(simulator)
        let target = "iOS Simulator — not physical-device evidence"
        let runtimeIdentifier =
            ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? "Unknown iOS Simulator model"
        #else
        let target = "Physical iOS device"
        let runtimeIdentifier = "iPhone"
        #endif
        let digest = SHA256.hash(data: rawData).map {
            String(format: "%02x", $0)
        }.joined()
        let envelope = FFmpegStage0EvidenceEnvelope(
            generatedAt: Date(),
            validationTarget: target,
            runtimeIdentifier: runtimeIdentifier,
            operatingSystemVersion:
                ProcessInfo.processInfo.operatingSystemVersionString,
            rawReportSHA256: digest,
            proof: proof,
            progressEvents: progressEvents
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(
            to: documents.appending(path: "Stage0FFmpegEvidence.json"),
            options: .atomic
        )
    }

    private static func validate(
        _ proof: FFmpegStage0Proof,
        allowedRoot: URL,
        progressEvents: [FFmpegStage0ProgressEvent]
    ) async -> [Stage0Check] {
        var checks: [Stage0Check] = []
        let operationIDs = Set(proof.operations.map(\.id))
        let outputIDs = Set(proof.outputs.map(\.id))
        let configurationTokens = Set(
            proof.configuration.split(whereSeparator: \.isWhitespace).map(
                String.init
            )
        )
        let failedOperations = proof.operations.filter {
            $0.status != "PASS"
        }

        let configurationIsExpected =
            proof.ffmpegVersion == "8.1.2"
            && configurationTokens.contains("--disable-programs")
            && configurationTokens.contains("--disable-network")
            && configurationTokens.contains("--enable-libmp3lame")
            && !configurationTokens.contains("--enable-gpl")
            && !configurationTokens.contains("--enable-nonfree")
        checks.append(
            check(
                configurationIsExpected,
                id: "ffmpeg-runtime-configuration",
                name: "Load pinned LGPL FFmpeg runtime",
                evidence: "\(proof.ffmpegVersion); \(proof.configuration)"
            )
        )

        checks.append(
            check(
                hasExactProofContract(proof),
                id: "ffmpeg-controlled-operations",
                name: "Complete every controlled FFmpeg operation",
                evidence:
                    "operations=\(operationIDs.sorted()); "
                    + "outputs=\(outputIDs.sorted()); "
                    + "failures=\(failedOperations.map(\.id))"
            )
        )

        guard
            let fixtureVideo = proof.output("fixture-video"),
            let fixtureAudio = proof.output("fixture-audio"),
            let fixtureIncompatible = proof.output("fixture-incompatible"),
            let fixtureArtwork = proof.output("fixture-artwork"),
            let merge = proof.output("merge"),
            let audioCopy = proof.output("audio-copy"),
            let videoOnly = proof.output("video-only"),
            let mp3 = proof.output("mp3-128k"),
            let compatible = proof.output("compatible-mp4"),
            let artwork = proof.output("mp3-artwork")
        else {
            checks.append(
                failed(
                    id: "ffmpeg-required-outputs",
                    name: "Return every required processed output",
                    evidence: "Output IDs: \(outputIDs.sorted())"
                )
            )
            return checks
        }

        let fixtureVideoStream = fixtureVideo.probe.primaryVideo
        let fixtureAudioStream = fixtureAudio.probe.primaryAudio
        let incompatibleVideoStream =
            fixtureIncompatible.probe.primaryVideo
        let incompatibleAudioStream =
            fixtureIncompatible.probe.primaryAudio
        let mergeVideoStream = merge.probe.primaryVideo
        let mergeAudioStream = merge.probe.primaryAudio
        let audioCopyStream = audioCopy.probe.primaryAudio
        let videoOnlyStream = videoOnly.probe.primaryVideo
        let mp3Audio = mp3.probe.primaryAudio
        let compatibleVideoStream = compatible.probe.primaryVideo
        let compatibleAudioStream = compatible.probe.primaryAudio
        let embeddedAudioStream = artwork.probe.primaryAudio
        let embeddedArtworkStream = artwork.probe.attachedArtwork

        checks.append(
            check(
                merge.probe.videoStreamCount == 1
                    && merge.probe.audioStreamCount == 1
                    && merge.probe.hasFullyDecodedMedia
                    && sameCopiedVideo(
                        fixtureVideoStream,
                        mergeVideoStream
                    )
                    && sameCopiedAudio(
                        fixtureAudioStream,
                        mergeAudioStream
                    )
                    && approximately(
                        merge.probe.duration,
                        target: fixtureVideo.probe.duration,
                        tolerance: 0.12
                    ),
                id: "ffmpeg-stream-copy-merge",
                name: "Merge separate video and audio without transcoding",
                evidence:
                    "\(merge.probe.summary); video packet digest "
                    + "\(mergeVideoStream?.packetSHA256 ?? "missing"); "
                    + "audio packet digest "
                    + "\(mergeAudioStream?.packetSHA256 ?? "missing")"
            )
        )
        checks.append(
            check(
                audioCopy.probe.videoStreamCount == 0
                    && audioCopy.probe.audioStreamCount == 1
                    && audioCopy.probe.audioCodecs == ["aac"]
                    && audioCopy.probe.hasFullyDecodedMedia
                    && sameCopiedAudio(
                        incompatibleAudioStream,
                        audioCopyStream
                    )
                    && approximately(
                        audioCopy.probe.duration,
                        target: fixtureIncompatible.probe.duration,
                        tolerance: 0.12
                    ),
                id: "ffmpeg-audio-stream-copy",
                name: "Extract audio without transcoding",
                evidence: audioCopy.probe.summary
            )
        )
        checks.append(
            check(
                videoOnly.probe.videoStreamCount == 1
                    && videoOnly.probe.audioStreamCount == 0
                    && videoOnly.probe.hasFullyDecodedMedia
                    && sameCopiedVideo(
                        fixtureVideoStream,
                        videoOnlyStream
                    )
                    && approximately(
                        videoOnly.probe.duration,
                        target: fixtureVideo.probe.duration,
                        tolerance: 0.12
                    ),
                id: "ffmpeg-video-only",
                name: "Produce a file with no audio stream",
                evidence: videoOnly.probe.summary
            )
        )

        let mp3BitRate = mp3Audio?.bitRate ?? 0
        checks.append(
            check(
                mp3.probe.videoStreamCount == 0
                    && mp3.probe.audioStreamCount == 1
                    && mp3.probe.audioCodecs == ["mp3"]
                    && mp3.probe.hasFullyDecodedMedia
                    && mp3Audio?.packetSHA256
                        != fixtureAudioStream?.packetSHA256
                    && approximately(
                        mp3BitRate,
                        target: 128_000,
                        toleranceFraction: 0.08
                    )
                    && approximately(
                        mp3.probe.duration,
                        target: fixtureAudio.probe.duration,
                        tolerance: 0.15
                    ),
                id: "ffmpeg-mp3-conversion",
                name: "Convert audio to 128 kbps MP3",
                evidence:
                    "\(mp3.probe.summary), measured audio bitrate "
                    + "\(mp3BitRate) bps"
            )
        )

        let compatibleVideoCodecs = compatible.probe.videoCodecs
        let compatibleFormats = Set(
            compatible.probe.format.lowercased().split(separator: ",").map(
                String.init
            )
        )
        checks.append(
            check(
                compatibleFormats.contains("mp4")
                    && compatible.probe.videoStreamCount == 1
                    && compatible.probe.audioStreamCount == 1
                    && compatible.probe.audioCodecs == ["aac"]
                    && compatibleVideoCodecs.count == 1
                    && ["h264", "mpeg4"].contains(
                        compatibleVideoCodecs[0]
                    )
                    && compatibleVideoStream?.codec
                        != incompatibleVideoStream?.codec
                    && compatibleVideoStream?.packetSHA256
                        != incompatibleVideoStream?.packetSHA256
                    && sameCopiedAudio(
                        incompatibleAudioStream,
                        compatibleAudioStream
                    )
                    && compatible.probe.hasFullyDecodedMedia
                    && approximately(
                        compatible.probe.duration,
                        target: fixtureIncompatible.probe.duration,
                        tolerance: 0.12
                    ),
                id: "ffmpeg-compatible-mp4",
                name: "Convert video to an Apple-compatible MP4",
                evidence: compatible.probe.summary
            )
        )
        checks.append(
            check(
                artwork.probe.videoStreamCount == 0
                    && artwork.probe.audioStreamCount == 1
                    && artwork.probe.artworkCount == 1
                    && embeddedArtworkStream?.codec == "mjpeg"
                    && (embeddedArtworkStream?.width ?? 0) > 0
                    && (embeddedArtworkStream?.height ?? 0) > 0
                    && embeddedArtworkStream?.packetSHA256
                        == fixtureArtwork.probe.primaryVideo?.packetSHA256
                    && embeddedArtworkStream?.metadata["title"] == "Cover"
                    && embeddedArtworkStream?.metadata["comment"]
                        == "Cover (front)"
                    && artwork.probe.metadata["comment"]
                        == "Artwork embedded by Illucet"
                    && sameCopiedAudio(mp3Audio, embeddedAudioStream)
                    && artwork.probe.hasFullyDecodedMedia
                    && approximately(
                        artwork.probe.duration,
                        target: mp3.probe.duration,
                        tolerance: 0.05
                    ),
                id: "ffmpeg-artwork-embedding",
                name: "Embed JPEG cover artwork in MP3",
                evidence: artwork.probe.summary
            )
        )

        let taggedOutputs = proof.outputs.filter {
            $0.id != "fixture-artwork"
        }
        let metadataWasReadBack = taggedOutputs.allSatisfy { output in
            output.probe.metadataValue(for: "title")
                == "Illucet Stage 0 Fixture"
                && output.probe.metadataValue(for: "artist") == "Illucet"
        }
        checks.append(
            check(
                metadataWasReadBack,
                id: "ffmpeg-metadata-readback",
                name: "Write and read back controlled media metadata",
                evidence:
                    taggedOutputs.map {
                        "\($0.id): \($0.probe.metadata)"
                    }.joined(separator: " | ")
            )
        )

        let proofDirectory = URL(filePath: proof.outputDirectory)
        let uniquePaths = Set(proof.outputs.map(\.path))
        let pathBoundaryIsValid =
            isDescendant(proofDirectory, of: allowedRoot)
            && proof.outputs.allSatisfy { output in
                let fileURL = URL(filePath: output.path)
                return isDirectChild(fileURL, of: proofDirectory)
                    && isDescendant(fileURL, of: allowedRoot)
            }
            && uniquePaths.count == requiredIDs.count
        checks.append(
            check(
                pathBoundaryIsValid,
                id: "ffmpeg-output-boundary",
                name: "Keep controlled outputs inside a unique proof directory",
                evidence:
                    "allowedRoot=\(allowedRoot.path); "
                    + "reportedDirectory=\(proof.outputDirectory); "
                    + "uniquePaths=\(uniquePaths.count)"
            )
        )

        let probesAreConsistent = proof.outputs.allSatisfy {
            validatesOutputEvidence($0, allowedRoot: allowedRoot)
        }
        checks.append(
            check(
                probesAreConsistent,
                id: "ffmpeg-full-decode-probe",
                name: "Read back streams and fully decode controlled outputs",
                evidence:
                    proof.outputs
                        .map { "\($0.id): \($0.probe.summary)" }
                        .joined(separator: " | ")
            )
        )

        let progressByStage = Dictionary(
            grouping: progressEvents,
            by: \.stage
        )
        let progressIsValid = validatesProgress(
            progressEvents,
            operations: proof.operations
        )
        let progressCounts = progressByStage
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        checks.append(
            check(
                progressIsValid,
                id: "ffmpeg-native-progress",
                name: "Receive real native processing progress",
                evidence:
                    "\(progressEvents.count) events across "
                    + progressCounts
            )
        )

        let playbackVerifier = ApplePlaybackVerifier()
        for output in [merge, audioCopy, videoOnly, mp3, compatible, artwork] {
            do {
                let result = try await playbackVerifier.verify(
                    fileURL: URL(filePath: output.path)
                )
                checks.append(
                    passed(
                        id: "apple-playback-\(output.id)",
                        name: "Decode and play \(output.id) with Apple APIs",
                        evidence:
                            "decoded=\(result.decodedSamples.map(\.kind)); "
                            + "AVPlayer advanced "
                            + "\(result.playbackAdvanceSeconds)s"
                    )
                )
            } catch {
                checks.append(
                    failed(
                        id: "apple-playback-\(output.id)",
                        name: "Decode and play \(output.id) with Apple APIs",
                        evidence: error.localizedDescription
                    )
                )
            }
        }

        return checks
    }

    private static func approximately(
        _ value: Int64,
        target: Int64,
        toleranceFraction: Double
    ) -> Bool {
        let tolerance = Double(target) * toleranceFraction
        return abs(Double(value - target)) <= tolerance
    }

    private static func approximately(
        _ value: Double,
        target: Double,
        tolerance: Double
    ) -> Bool {
        value.isFinite
            && target.isFinite
            && abs(value - target) <= tolerance
    }

    static func hasExactProofContract(_ proof: FFmpegStage0Proof) -> Bool {
        let operationIDs = Set(proof.operations.map(\.id))
        let outputIDs = Set(proof.outputs.map(\.id))
        return operationIDs == requiredIDs
            && outputIDs == requiredIDs
            && proof.operations.count == requiredIDs.count
            && proof.outputs.count == requiredIDs.count
            && proof.operations.allSatisfy {
                $0.status == "PASS"
                    && requiredProgressStages[$0.id] == $0.progressStage
            }
    }

    static func validatesProgress(
        _ progressEvents: [FFmpegStage0ProgressEvent],
        operations: [FFmpegStage0Operation]
    ) -> Bool {
        guard operations.count == requiredProgressStages.count,
              Set(operations.map(\.id)) == requiredIDs,
              operations.allSatisfy({ operation in
                  requiredProgressStages[operation.id]
                      == operation.progressStage
              })
        else {
            return false
        }
        let progressByStage = Dictionary(
            grouping: progressEvents,
            by: \.stage
        )
        let progressStages = Set(operations.map(\.progressStage))
        return progressEvents.count <= progressStages.count * 64
            && Set(progressByStage.keys) == progressStages
            && progressStages.allSatisfy { stage in
                guard let events = progressByStage[stage],
                      events.count >= 3,
                      events.count <= 64
                else {
                    return false
                }
                let values = events.map(\.progress)
                let finiteAndBounded = values.allSatisfy {
                    $0.isFinite && $0 >= -1 && $0 <= 1
                }
                let knownValues = values.filter { $0 >= 0 }
                let monotonic = zip(
                    knownValues,
                    knownValues.dropFirst()
                ).allSatisfy {
                    $0 <= $1
                }
                return finiteAndBounded
                    && abs((values.first ?? -1) - 0) < 0.000_001
                    && abs((values.last ?? -1) - 1) < 0.000_001
                    && values.contains { $0 > 0 && $0 < 1 }
                    && monotonic
            }
    }

    static func validatesOutputEvidence(
        _ output: FFmpegStage0Output,
        allowedRoot: URL
    ) -> Bool {
        let durationIsPlausible =
            output.id == "fixture-artwork"
                ? output.probe.duration.isFinite
                    && output.probe.duration >= -1
                    && output.probe.primaryVideo?.codec == "mjpeg"
                    && (output.probe.primaryVideo?.width ?? 0) > 0
                    && (output.probe.primaryVideo?.height ?? 0) > 0
                    && (output.probe.primaryVideo?.decodedFrames ?? 0) > 0
                : output.probe.duration.isFinite
                    && output.probe.duration >= 1.75
                    && output.probe.duration <= 2.25
        let actualSize = fileSize(atPath: output.path)
        return output.probe.size > 0
            && actualSize == output.probe.size
            && output.probe.streamCount == output.probe.streams.count
            && output.probe.reportedCountsMatchStreams
            && output.probe.hasFullyDecodedMedia
            && output.probe.streams.allSatisfy {
                isValidSHA256($0.packetSHA256)
            }
            && durationIsPlausible
            && isDescendant(URL(filePath: output.path), of: allowedRoot)
    }

    static func sameCopiedVideo(
        _ source: FFmpegStage0Stream?,
        _ output: FFmpegStage0Stream?
    ) -> Bool {
        guard let source, let output else {
            return false
        }
        return source.codec == output.codec
            && source.width == output.width
            && source.height == output.height
            && approximately(
                source.frameRate,
                target: output.frameRate,
                tolerance: 0.001
            )
            && isValidSHA256(source.packetSHA256)
            && source.packetSHA256 == output.packetSHA256
    }

    static func sameCopiedAudio(
        _ source: FFmpegStage0Stream?,
        _ output: FFmpegStage0Stream?
    ) -> Bool {
        guard let source, let output else {
            return false
        }
        return source.codec == output.codec
            && source.sampleRate == output.sampleRate
            && source.channels == output.channels
            && isValidSHA256(source.packetSHA256)
            && source.packetSHA256 == output.packetSHA256
    }

    static func isValidSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64
            && bytes.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = canonical(root).path
        let candidatePath = canonical(candidate).path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isDirectChild(_ candidate: URL, of root: URL) -> Bool {
        canonical(candidate.deletingLastPathComponent()).path
            == canonical(root).path
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: path
            ),
            let number = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return number.int64Value
    }

    private static func check(
        _ condition: Bool,
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        condition
            ? passed(id: id, name: name, evidence: evidence)
            : failed(id: id, name: name, evidence: evidence)
    }

    private static func passed(
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        Stage0Check(
            id: id,
            name: name,
            status: .pass,
            evidence: evidence
        )
    }

    private static func failed(
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        Stage0Check(
            id: id,
            name: name,
            status: .fail,
            evidence: evidence
        )
    }
}

private extension FFmpegStage0Proof {
    func output(_ id: String) -> FFmpegStage0Output? {
        outputs.first { $0.id == id }
    }
}

private extension FFmpegStage0Probe {
    var primaryVideo: FFmpegStage0Stream? {
        streams.first { $0.type == "video" && !$0.attachedPicture }
    }

    var primaryAudio: FFmpegStage0Stream? {
        streams.first { $0.type == "audio" }
    }

    var attachedArtwork: FFmpegStage0Stream? {
        streams.first { $0.type == "video" && $0.attachedPicture }
    }

    var videoCodecs: [String] {
        streams
            .filter { $0.type == "video" && !$0.attachedPicture }
            .map(\.codec)
    }

    var audioCodecs: [String] {
        streams.filter { $0.type == "audio" }.map(\.codec)
    }

    var hasFullyDecodedMedia: Bool {
        streams
            .filter {
                ($0.type == "video" && !$0.attachedPicture)
                    || $0.type == "audio"
            }
            .allSatisfy { $0.decodedFrames > 0 }
    }

    var reportedCountsMatchStreams: Bool {
        videoStreamCount == streams.count {
            $0.type == "video" && !$0.attachedPicture
        }
            && audioStreamCount == streams.count { $0.type == "audio" }
            && subtitleStreamCount == streams.count {
                $0.type == "subtitle"
            }
            && artworkCount == streams.count { $0.attachedPicture }
    }

    func metadataValue(for key: String) -> String? {
        metadata.first {
            $0.key.localizedCaseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    var summary: String {
        "\(format), \(videoStreamCount)v/\(audioStreamCount)a/"
            + "\(subtitleStreamCount)s, artwork=\(artworkCount), "
            + "codecs=\(streams.map(\.codec)), duration=\(duration)s, "
            + "size=\(size)"
    }
}
