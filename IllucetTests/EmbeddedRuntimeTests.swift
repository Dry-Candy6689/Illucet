import Foundation
import Testing
@testable import Illucet

@Suite(.serialized)
struct EmbeddedRuntimeTests {
    @Test
    func embeddedPythonReinitializesAfterPriorEngineShutdown() async throws {
        let resources = try #require(Bundle.main.resourceURL)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-PythonLifecycle-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let writable = root.appending(
            path: "PythonPackages",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: writable,
            withIntermediateDirectories: true
        )
        try Data("ORIGIN = \"writable-version-1\"\n".utf8).write(
            to: writable.appending(path: "writable_probe.py"),
            options: .atomic
        )

        for cycle in 1 ... 2 {
            let engine = try PythonEngine(
                pythonHome: resources.appending(path: "python"),
                bundledApp: resources.appending(path: "PythonApp"),
                bundledPackages: resources.appending(path: "PythonPackages"),
                writablePackages: writable,
                recorder: PythonEventRecorder()
            )
            try await engine.start()
            let response = try await engine.execute(
                requestID: UInt64(1_000 + cycle),
                requestJSON: #"{"action":"basic"}"#
            )
            #expect(response.contains("bundled-read-only-package"))
            if cycle == 1 {
                let request = "{\"action\":\"runtime_versions\",\"padding\":\""
                    + String(repeating: "x", count: 300_000) + "\"}"
                let bounded = try await engine.execute(requestID: 2_000, requestJSON: request)
                #expect(bounded.contains("yt_dlp_version"))
                await #expect(throws: PythonBridgeError.self) {
                    try await engine.execute(requestID: 2_001,
                        requestJSON: String(repeating: "x", count: 512 * 1_024 + 1))
                }
            }
            try await engine.shutdown()
        }
    }

    @Test
    func liveChallengeProofDistinguishesAbsentFromIncompleteChallenges() {
        #expect(
            LiveMetadataStage0ProofRunner.challengeProofStatus(
                providerPathIsValid: true,
                challengeRequestCount: 0
            ) == .notRun
        )
        #expect(
            LiveMetadataStage0ProofRunner.challengeProofStatus(
                providerPathIsValid: true,
                challengeRequestCount: 2
            ) == .pass
        )
        #expect(
            LiveMetadataStage0ProofRunner.challengeProofStatus(
                providerPathIsValid: true,
                challengeRequestCount: 1
            ) == .pass
        )
        #expect(
            LiveMetadataStage0ProofRunner.challengeProofStatus(
                providerPathIsValid: false,
                challengeRequestCount: 1
            ) == .fail
        )
    }

    @Test(
        "Explicit embedded Runtime Proof",
        .enabled(if: RuntimeProofTestGate.isEnabled)
    )
    func explicitEmbeddedRuntimeProofReclassifiesKnownFailures() async {
        let report = await Stage0ProofRunner.run()
        let nonPassing = report.checks.filter { $0.status != .pass }
        print(
            "runtime_proof_measurement target=\(report.target) "
                + "pass=\(report.passedCount) fail=\(report.failedCount) "
                + "blocked=\(report.blockedCount) "
                + "notRun=\(report.notRunCount) total=\(report.checks.count)"
        )
        for check in nonPassing {
            print(
                "runtime_proof_nonpass id=\(check.id) "
                    + "status=\(check.status.rawValue) "
                    + "evidence=\(check.evidence)"
            )
        }

        #expect(report.checks.count == 44)
        #expect(report.passedCount == 41)
        #expect(report.failedCount == 0)
        #expect(report.blockedCount == 0)
        #expect(report.notRunCount == 3)
        #expect(
            report.checks.first { $0.id == "ffmpeg-artwork-embedding" }?
                .status == .pass
        )
        #expect(
            report.checks.first { $0.id == "ffmpeg-native-progress" }?
                .status == .pass
        )
    }

    @Test
    func typedPythonEventDecodes() throws {
        let data = Data(
            #"{"kind":"progress","payload":{"completed":1,"total":2}}"#.utf8
        )
        let recorder = PythonEventRecorder()
        recorder.record(requestID: 42, data: data)

        let event = try #require(recorder.events(for: 42).first)
        #expect(event.kind == "progress")
        #expect(event.payload["completed"] == .number(1))
        #expect(event.payload["total"] == .number(2))
    }

    @Test
    func reportCountsOnlyExplicitPassAndFail() {
        let report = Stage0ProofReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            target: "fixture",
            checks: [
                Stage0Check(
                    id: "pass",
                    name: "Pass",
                    status: .pass,
                    evidence: "fixture"
                ),
                Stage0Check(
                    id: "fail",
                    name: "Fail",
                    status: .fail,
                    evidence: "fixture"
                ),
                Stage0Check(
                    id: "blocked",
                    name: "Blocked",
                    status: .blocked,
                    evidence: "fixture"
                )
            ],
            events: []
        )

        #expect(report.passedCount == 1)
        #expect(report.failedCount == 1)
    }

    @Test
    func reportInspectionKeepsEveryCheckFailureFirstAndStable() throws {
        let passingChecks = (1 ... 13).map { index in
            Stage0Check(
                id: "pass-\(index)",
                name: "Pass \(index)",
                status: .pass,
                evidence: "Passing evidence \(index)"
            )
        }
        let lateFailure = Stage0Check(
            id: "late-failure",
            name: "Late failure",
            status: .fail,
            evidence: "Failure after the former 12-row boundary"
        )
        let lateBlocked = Stage0Check(
            id: "late-blocked",
            name: "Late blocked",
            status: .blocked,
            evidence: "Blocked evidence"
        )
        let lateNotRun = Stage0Check(
            id: "late-not-run",
            name: "Late not run",
            status: .notRun,
            evidence: "Not-run evidence"
        )
        let report = Stage0ProofReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            target: "fixture",
            checks: passingChecks + [
                lateFailure,
                lateBlocked,
                lateNotRun,
            ],
            events: []
        )

        let inspected = report.checksForInspection
        #expect(inspected.count == 16)
        #expect(
            inspected.map(\.id) == [
                "late-failure",
                "late-blocked",
                "late-not-run",
            ] + passingChecks.map(\.id)
        )
        #expect(try #require(inspected.first).evidence == lateFailure.evidence)
        #expect(report.passedCount == 13)
        #expect(report.failedCount == 1)
        #expect(report.blockedCount == 1)
        #expect(report.notRunCount == 1)
    }

    @Test
    func quickJSProofDecodesStableProviderContract() throws {
        let data = Data(
            """
            {
              "ok": true,
              "action": "quickjs",
              "data": {
                "answer": 42,
                "core_sha256": "core",
                "ejs_version": "0.8.0",
                "elapsed": 0.01,
                "empty_response_count": 0,
                "empty_result_type": "result",
                "fail_closed_cases": {
                  "malformed_response": true,
                  "missing_response": true,
                  "response_error": true,
                  "runtime_failure": true,
                  "semantic_validation_exception": true,
                  "semantic_signature_validation_exception": true,
                  "valid": true,
                  "version_mismatch": true
                },
                "fail_closed_director": true,
                "lib_sha256": "lib",
                "provider_available": true,
                "provider_key": "IllucetQuickJS",
                "provider_registered": true,
              "quickjs_version": "0.15.0",
              "sensitive_director_log_found": false,
              "thrown_text_redacted": true,
              "unicode": "Illucet 🔐",
                "ytdlp_version": "2026.09.27.232945"
              }
            }
            """.utf8
        )

        let envelope = try JSONDecoder().decode(
            BridgeEnvelope<QuickJSProof>.self,
            from: data
        )

        #expect(envelope.data.providerRegistered)
        #expect(envelope.data.providerAvailable)
        #expect(envelope.data.providerKey == "IllucetQuickJS")
        #expect(envelope.data.emptyResultType == "result")
        #expect(envelope.data.quickjsVersion == "0.15.0")
        #expect(envelope.data.thrownTextRedacted)
        #expect(envelope.data.failClosedDirector)
        #expect(!envelope.data.sensitiveDirectorLogFound)
    }

    @Test
    func ffmpegProofDecodesFrozenNativeContract() throws {
        let data = Data(
            """
            {
              "ffmpegVersion": "8.1.2",
              "configuration": "--disable-programs --disable-network",
              "outputDirectory": "/tmp/proof",
              "operations": [
                {
                  "id": "merge",
                  "status": "PASS",
                  "progressStage": "merge"
                }
              ],
              "outputs": [
                {
                  "id": "merge",
                  "path": "/tmp/proof/merged.mp4",
                  "probe": {
                    "format": "mov,mp4,m4a,3gp,3g2,mj2",
                    "formatLongName": "QuickTime / MOV",
                    "duration": 2.0,
                    "bitRate": 200000,
                    "size": 50000,
                    "streamCount": 2,
                    "videoStreamCount": 1,
                    "audioStreamCount": 1,
                    "subtitleStreamCount": 0,
                    "artworkCount": 0,
                    "metadata": {"title": "fixture"},
                    "streams": [
                      {
                        "index": 0,
                        "type": "video",
                        "codec": "mpeg4",
                        "codecLongName": "MPEG-4 part 2",
                        "duration": 2.0,
                        "bitRate": 100000,
                        "attachedPicture": false,
                        "decodedFrames": 48,
                        "width": 320,
                        "height": 180,
                        "frameRate": 24.0,
                        "sampleRate": 0,
                        "channels": 0,
                        "channelLayout": "",
                        "packetSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "metadata": {}
                      },
                      {
                        "index": 1,
                        "type": "audio",
                        "codec": "aac",
                        "codecLongName": "AAC",
                        "duration": 2.0,
                        "bitRate": 96000,
                        "attachedPicture": false,
                        "decodedFrames": 95,
                        "width": 0,
                        "height": 0,
                        "frameRate": 0,
                        "sampleRate": 48000,
                        "channels": 2,
                        "channelLayout": "stereo",
                        "packetSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "metadata": {}
                      }
                    ]
                  }
                }
              ]
            }
            """.utf8
        )

        let proof = try JSONDecoder().decode(
            FFmpegStage0Proof.self,
            from: data
        )

        #expect(proof.ffmpegVersion == "8.1.2")
        #expect(proof.operations.first?.status == "PASS")
        #expect(proof.outputs.first?.probe.videoStreamCount == 1)
        #expect(proof.outputs.first?.probe.audioStreamCount == 1)
        #expect(proof.outputs.first?.probe.streams.last?.sampleRate == 48_000)
    }

    @Test
    func ffmpegProofContractRejectsDuplicateRecords() {
        let ids = ffmpegOperationIDs
        let proof = FFmpegStage0Proof(
            ffmpegVersion: "8.1.2",
            configuration: "",
            outputDirectory: "/tmp/proof",
            operations: ids.map {
                FFmpegStage0Operation(
                    id: $0,
                    status: "PASS",
                    progressStage: ffmpegProgressStage(for: $0)
                )
            },
            outputs: ids.map {
                makeFFmpegOutput(id: $0, path: "/tmp/proof/\($0)")
            }
        )
        #expect(FFmpegStage0ProofRunner.hasExactProofContract(proof))

        let duplicated = FFmpegStage0Proof(
            ffmpegVersion: proof.ffmpegVersion,
            configuration: proof.configuration,
            outputDirectory: proof.outputDirectory,
            operations: proof.operations + [proof.operations[0]],
            outputs: proof.outputs + [proof.outputs[0]]
        )
        #expect(!FFmpegStage0ProofRunner.hasExactProofContract(duplicated))
    }

    @Test
    func ffmpegProgressRejectsMissingAndNonMonotonicStages() {
        let valid = ffmpegOperationIDs.flatMap { id in
            let stage = ffmpegProgressStage(for: id)
            return [
                FFmpegStage0ProgressEvent(stage: stage, progress: 0),
                FFmpegStage0ProgressEvent(stage: stage, progress: -1),
                FFmpegStage0ProgressEvent(stage: stage, progress: 0.5),
                FFmpegStage0ProgressEvent(stage: stage, progress: 1),
            ]
        }
        let operations = ffmpegOperationIDs.map {
            FFmpegStage0Operation(
                id: $0,
                status: "PASS",
                progressStage: ffmpegProgressStage(for: $0)
            )
        }
        #expect(
            FFmpegStage0ProofRunner.validatesProgress(
                valid,
                operations: operations
            )
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesProgress(
                Array(valid.dropLast(4)),
                operations: operations
            )
        )

        var nonMonotonic = valid
        nonMonotonic[2] = FFmpegStage0ProgressEvent(
            stage: ffmpegProgressStage(for: ffmpegOperationIDs[0]),
            progress: 0.8
        )
        nonMonotonic.insert(
            FFmpegStage0ProgressEvent(
                stage: ffmpegProgressStage(for: ffmpegOperationIDs[0]),
                progress: 0.4
            ),
            at: 3
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesProgress(
                nonMonotonic,
                operations: operations
            )
        )

        var outOfRange = valid
        outOfRange[1] = FFmpegStage0ProgressEvent(
            stage: ffmpegProgressStage(for: ffmpegOperationIDs[0]),
            progress: -2
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesProgress(
                outOfRange,
                operations: operations
            )
        )

        let flooded = ffmpegOperationIDs.flatMap { id in
            (0 ... 64).map { index in
                FFmpegStage0ProgressEvent(
                    stage: ffmpegProgressStage(for: id),
                    progress: Double(index) / 64
                )
            }
        }
        #expect(
            !FFmpegStage0ProofRunner.validatesProgress(
                flooded,
                operations: operations
            )
        )

        var mismatched = operations
        mismatched[7] = FFmpegStage0Operation(
            id: "mp3-128k",
            status: "PASS",
            progressStage: "mp3-128k"
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesProgress(
                valid,
                operations: mismatched
            )
        )
    }

    @Test
    func ffmpegOutputEvidenceFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let media = root.appending(path: "media.mp4")
        try Data(repeating: 0x5A, count: 32).write(to: media)
        let escaped = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4"
        )
        try Data(repeating: 0x5A, count: 32).write(to: escaped)
        defer {
            try? FileManager.default.removeItem(at: escaped)
        }

        let valid = makeFFmpegOutput(
            id: "merge",
            path: media.path,
            size: 32
        )
        #expect(
            FFmpegStage0ProofRunner.validatesOutputEvidence(
                valid,
                allowedRoot: root
            )
        )

        let wrongSize = makeFFmpegOutput(
            id: "merge",
            path: media.path,
            size: 31
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesOutputEvidence(
                wrongSize,
                allowedRoot: root
            )
        )
        let badHash = makeFFmpegOutput(
            id: "merge",
            path: media.path,
            size: 32,
            packetSHA256: String(repeating: "G", count: 64)
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesOutputEvidence(
                badHash,
                allowedRoot: root
            )
        )
        let noDecode = makeFFmpegOutput(
            id: "merge",
            path: media.path,
            size: 32,
            decodedFrames: 0
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesOutputEvidence(
                noDecode,
                allowedRoot: root
            )
        )
        let wrongDuration = makeFFmpegOutput(
            id: "merge",
            path: media.path,
            size: 32,
            duration: 1
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesOutputEvidence(
                wrongDuration,
                allowedRoot: root
            )
        )
        let escapedPath = makeFFmpegOutput(
            id: "merge",
            path: escaped.path,
            size: 32
        )
        #expect(
            !FFmpegStage0ProofRunner.validatesOutputEvidence(
                escapedPath,
                allowedRoot: root
            )
        )
    }

    @Test
    func ffmpegStreamCopyRequiresIdenticalPacketPayload() {
        let source = makeFFmpegStream(
            packetSHA256: String(repeating: "a", count: 64)
        )
        let same = makeFFmpegStream(
            packetSHA256: String(repeating: "a", count: 64)
        )
        let changed = makeFFmpegStream(
            packetSHA256: String(repeating: "b", count: 64)
        )

        #expect(FFmpegStage0ProofRunner.sameCopiedVideo(source, same))
        #expect(!FFmpegStage0ProofRunner.sameCopiedVideo(source, changed))
    }

    private var ffmpegOperationIDs: [String] {
        [
            "fixture-video",
            "fixture-audio",
            "fixture-incompatible",
            "fixture-artwork",
            "merge",
            "audio-copy",
            "video-only",
            "mp3-128k",
            "compatible-mp4",
            "mp3-artwork",
        ]
    }

    private func ffmpegProgressStage(for operationID: String) -> String {
        [
            "mp3-128k": "audio-mp3",
            "compatible-mp4": "video-transcode",
            "mp3-artwork": "artwork",
        ][operationID] ?? operationID
    }

    private func makeFFmpegOutput(
        id: String,
        path: String,
        size: Int64 = 32,
        packetSHA256: String = String(repeating: "a", count: 64),
        decodedFrames: Int = 60,
        duration: Double = 2
    ) -> FFmpegStage0Output {
        let stream = makeFFmpegStream(
            packetSHA256: packetSHA256,
            decodedFrames: decodedFrames,
            duration: duration
        )
        return FFmpegStage0Output(
            id: id,
            path: path,
            probe: FFmpegStage0Probe(
                format: "mov,mp4",
                formatLongName: "QuickTime / MOV",
                duration: duration,
                bitRate: 128_000,
                size: size,
                streamCount: 1,
                videoStreamCount: 1,
                audioStreamCount: 0,
                subtitleStreamCount: 0,
                artworkCount: 0,
                metadata: [:],
                streams: [stream]
            )
        )
    }

    private func makeFFmpegStream(
        packetSHA256: String,
        decodedFrames: Int = 60,
        duration: Double = 2
    ) -> FFmpegStage0Stream {
        FFmpegStage0Stream(
            index: 0,
            type: "video",
            codec: "mpeg4",
            codecLongName: "MPEG-4 part 2",
            duration: duration,
            bitRate: 128_000,
            attachedPicture: false,
            decodedFrames: decodedFrames,
            width: 320,
            height: 180,
            frameRate: 30,
            sampleRate: 0,
            channels: 0,
            channelLayout: "",
            packetSHA256: packetSHA256,
            metadata: [:]
        )
    }
}

private enum RuntimeProofTestGate {
    static let isEnabled = ProcessInfo.processInfo.environment[
        "ILLUCET_RUN_RUNTIME_PROOF"
    ] == "1"
}
