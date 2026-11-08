import Foundation
import ImageIO
import Testing
@testable import Illucet

@Suite("Part 3 coordinator integration", .serialized)
struct DownloadCoordinatorTests {
    @Test(
        "PD-R1 authorized live downloader smoke",
        .enabled(if: PDR1LiveTestGate.isEnabled),
        arguments: PDR1LiveSmokeMode.allCases
    )
    func authorizedLiveDownloaderSmoke(
        _ mode: PDR1LiveSmokeMode
    ) async throws {
        let authorization = try AuthorizedLiveTestConfigurationLoader.load()
        let checksRecovery = mode == .videoAndAudio
            && ProcessInfo.processInfo.environment["ILLUCET_LIVE_BACKGROUND_RECOVERY"] == "1"
        let continuation = checksRecovery
            ? CoordinatorLiveContinuation(base: await ContinuedProcessingController()) : nil
        let harness = try PDR1LiveCoordinatorHarness(processingContinuation: continuation)
        defer { harness.finish() }

        do {
            let metadata = try await harness.analyze(
                authorization.standardVideoURL
            )
            var configuration = mode.configuration
            let checksThumbnail = mode == .videoAndAudio && ProcessInfo.processInfo.environment["ILLUCET_LIVE_INCLUDE_THUMBNAIL"] == "1"
            if checksThumbnail {
                configuration.preset = .compatible
                configuration.videoCodec = .h264
                configuration.audioCodec = .aac
                configuration.container = .mp4
                configuration.thumbnailBehavior = .includeVideoThumbnail
                configuration = OutputCapabilityMatrix.normalized(configuration)
            }
            if checksRecovery {
                configuration.maximumResolution = 360
                configuration.videoCodec = .h264
                configuration.audioCodec = .aac
                configuration.container = .mp4
                configuration = OutputCapabilityMatrix.normalized(configuration)
                FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
                var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
                policy.setAction(.remove, for: .sponsor)
                policy.removalMode = .fastKeyframe
                policy.replaceSelection(videoID: metadata.videoID,
                    queriedCategories: policy.requestedDiscoveryCategories,
                    segments: [.init(segmentID: "authorized-recovery-fixture", category: .sponsor,
                        startSeconds: 1, endSeconds: 2, description: nil,
                        submittedVideoDuration: try #require(metadata.durationSeconds),
                        serverAction: .skip, votes: 1, isLocked: false)])
                configuration.sponsorBlock = policy
            }
            let checksChapters = mode == .videoAndAudio
                && ProcessInfo.processInfo.environment["ILLUCET_LIVE_CHAPTERS"] == "1"
            if checksChapters {
                print("Live chapter check: metadata duration=\(metadata.durationSeconds ?? 0), chapters=\(metadata.chapters)")
                let categories = SponsorBlockPolicy.discoveryCategories
                let segments = try await SponsorBlockService.live().segments(
                    videoID: metadata.videoID, categories: categories
                )
                #expect(!segments.isEmpty, "Chapter check requires real SponsorBlock segments")
                var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: categories)
                for category in categories { policy.setAction(.markAsChapter, for: category) }
                policy.replaceSelection(videoID: metadata.videoID, queriedCategories: categories, segments: segments)
                configuration.sponsorBlock = policy
                configuration.writeChapters = true
                configuration.preserveChapters = true
                print("Live chapter check: marking \(segments.count) SponsorBlock segments")
            }
            let job = try await harness.enqueue(
                metadata: metadata,
                configuration: configuration
            )
            let retainedBase: URL?
            if let continuation {
                retainedBase = try await harness.interruptSponsorBlockForProof(job.id, continuation: continuation)
            } else { retainedBase = nil }
            let terminal = try await harness.waitForTerminalJob(job.id)
            if checksThumbnail {
                #expect(terminal.outputProbe?.streams.contains { $0.disposition.attachedPicture } == true)
            }
            if let retainedBase {
                let reused = harness.verifiedAssemblies(job.id) == Set([retainedBase])
                #expect(reused)
                #expect(terminal.sponsorBlockApplication?.status == .applied)
                print("ILLUCET_LIVE_RECOVERY resumed_same_verified_assembly=\(reused)")
            }

            if terminal.state != .completed {
                let detail = terminal.errorMessage
                    ?? terminal.errorCode
                    ?? "unknown"
                throw LiveDownloadFailure(message: "\(mode.rawValue) failed: \(detail)")
            }
            let outputURL = try #require(terminal.outputURL)
            let values = try outputURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            #expect(values.isRegularFile == true)
            #expect((values.fileSize ?? 0) > 0)

            switch mode {
            case .thumbnailOnly:
                let source = try #require(
                    CGImageSourceCreateWithURL(outputURL as CFURL, nil)
                )
                #expect(CGImageSourceGetCount(source) > 0)
                #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
            case .videoAndAudio:
                let probe = try #require(terminal.outputProbe)
                #expect(probe.videoStreamCount > 0)
                #expect(probe.audioStreamCount > 0)
                if checksChapters {
                    #expect(!probe.chapters.isEmpty)
                    #expect(probe.chapters.contains { $0.title.hasPrefix("SponsorBlock:") })
                    print("Live chapter check: verified duration=\(probe.durationSeconds ?? 0), chapters=\(probe.chapters)")
                }
            case .audioOnly:
                let probe = try #require(terminal.outputProbe)
                #expect(probe.videoStreamCount == 0)
                #expect(probe.audioStreamCount > 0)
            case .videoOnly:
                let probe = try #require(terminal.outputProbe)
                #expect(probe.videoStreamCount > 0)
                #expect(probe.audioStreamCount == 0)
            }

        } catch {
            await harness.shutdown()
            throw error
        }

        await harness.shutdown()
    }

    @Test("Authorized single video download", .enabled(if: PDR1LiveTestGate.isEnabled))
    func authorizedLiveVideoDownloadSmoke() async throws {
        try await authorizedLiveDownloaderSmoke(.videoAndAudio)
    }

    @Test("Authorized timed download", .enabled(if: PDR1LiveTestGate.isEnabled
        && ProcessInfo.processInfo.environment["ILLUCET_DOWNLOAD_BENCHMARK"] == "1"))
    func authorizedDownloadBenchmark() async throws {
        let authorization = try AuthorizedLiveTestConfigurationLoader.load()
        let height = try #require(Int(ProcessInfo.processInfo.environment["ILLUCET_BENCHMARK_HEIGHT"] ?? ""))
        let harness = try PDR1LiveCoordinatorHarness()
        defer { harness.finish() }
        let started = ContinuousClock.now
        do {
            let metadata = try await harness.analyze(authorization.standardVideoURL)
            let analyzed = ContinuousClock.now
            let versions = try await harness.versions()
            var configuration = PDR1LiveSmokeMode.videoAndAudio.configuration
            configuration.maximumResolution = height
            FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
            let facts = try FormatSelection.selectedSourceFacts(configuration: configuration, metadata: metadata)
            let selected = metadata.formats.filter { configuration.selectedFormatIDs.contains($0.formatID) }
            let job = try await harness.enqueue(metadata: metadata, configuration: configuration)
            let terminal = try await harness.waitForTerminalJob(job.id)
            guard terminal.state == .completed else {
                throw LiveDownloadFailure(message: terminal.errorMessage ?? terminal.errorCode ?? "benchmark failed")
            }
            let output = try #require(terminal.outputURL)
            let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            #expect(values.isRegularFile == true && values.isSymbolicLink != true)
            #expect((values.fileSize ?? 0) > 0)
            #expect((terminal.outputProbe?.videoStreamCount ?? 0) > 0)
            #expect((terminal.outputProbe?.audioStreamCount ?? 0) > 0)
            let observations = harness.observations(job.id)
            let finished = try #require(observations.last(where: { $0.job.state == .completed }))
            var stages: [String: Double] = [:]
            for (first, next) in zip(observations, observations.dropFirst()) {
                stages[first.job.stage.rawValue, default: 0] += Self.benchmarkSeconds(first.observedAt.duration(to: next.observedAt))
            }
            let report: [String: Any] = [
                "videoID": metadata.videoID, "heightLimit": height,
                "formats": facts.map { ["id": $0.formatID, "protocol": $0.protocolName, "transport": $0.transport.rawValue] },
                "actualHeight": selected.compactMap(\.height).max() ?? 0,
                "sessionMode": "production background",
                "extractionSeconds": Self.benchmarkSeconds(started.duration(to: analyzed)),
                "pipelineSeconds": Self.benchmarkSeconds(analyzed.duration(to: finished.observedAt)),
                "totalSeconds": Self.benchmarkSeconds(started.duration(to: finished.observedAt)),
                "stages": stages, "downloadedBytes": terminal.progress.bytesDownloaded,
                "outputBytes": values.fileSize ?? 0, "ytDLPVersion": versions.ytDLP
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("ILLUCET_BENCHMARK " + String(decoding: data, as: UTF8.self))
        } catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }

    private static func benchmarkSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test("Part 13 authorized creator inventories and sidecar download",
          .enabled(if: ProcessInfo.processInfo.environment["ILLUCET_PART13_LIVE"] == "1"))
    func authorizedPart13CreatorAndSidecarSmoke() async throws {
        let harness = try PDR1LiveCoordinatorHarness()
        defer { harness.finish() }
        do {
        let analyzer = try await harness.playlistAnalyzer()
        var publicShortURLs: [URL] = []
        for (path, kind) in [("@NASA/videos", PlaylistKind.creatorUploads), ("@NASA/shorts", .creatorShorts), ("@SpaceX/streams", .creatorReplays)] {
            print("Part 13 live: analyzing \(kind.rawValue)")
            let result = try await analyzer.analyze(url: URL(string: "https://www.youtube.com/" + path)!, maximumEntries: 3, detailed: kind == .creatorReplays)
            print("Part 13 live: \(kind.rawValue) returned \(result.entries.count) entries")
            if kind == .creatorShorts { publicShortURLs = result.entries.filter { $0.availability == .available }.compactMap(\.canonicalURL) }
            #expect(result.entries.count <= 3)
            #expect(!result.entries.isEmpty)
            #expect(result.entries.contains { $0.availability == .available })
            if kind == .creatorShorts { #expect(result.entries.allSatisfy { $0.isShort == true }) }
            if kind == .creatorReplays { #expect(result.entries.filter { $0.availability == .available }.allSatisfy { $0.isLive == false }) }
        }
            print("Part 13 live: analyzing the public creator Short")
            var selectedMetadata: MediaMetadata?
            for url in publicShortURLs {
                do {
                    selectedMetadata = try await harness.analyze(url)
                    break
                } catch ExtractionError.extractorFailure(let code, _, _) where code == "metadata_too_large" {
                    print("Part 13 live: candidate exceeded the existing metadata bound; checking next loaded Short")
                }
            }
            let metadata = try #require(selectedMetadata)
            print("Part 13 live: downloading verified video and audio with sidecars")
            var configuration = PDR1LiveSmokeMode.videoAndAudio.configuration
            configuration.metadataSidecars = Set(MetadataSidecarKind.allCases)
            let job = try await harness.enqueue(metadata: metadata, configuration: configuration)
            let terminal = try await harness.waitForTerminalJob(job.id)
            #expect(terminal.state == .completed)
            let output = try #require(terminal.outputURL)
            #expect(terminal.outputProbe?.videoStreamCount == 1)
            #expect((terminal.outputProbe?.audioStreamCount ?? 0) > 0)
            let extras = try #require(terminal.metadataSidecars)
            #expect(extras.count == 5)
            let sha = try #require(extras.first { $0.kind == .sha256 })
            #expect(try String(contentsOf: sha.localURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == MetadataSidecarWriter.digest(output))
        } catch {
            await harness.shutdown()
            throw error
        }
        await harness.shutdown()
    }

    @Test(
        "Source filenames preserve safe IDs and reject cross-job traversal before transfer",
        arguments: [false, true]
    )
    func sourceFilenameCannotEscapeItsJob(traversal: Bool) async throws {
        let otherJobID = UUID()
        let otherRoot = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-\(otherJobID.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: otherRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let sentinel = otherRoot.appending(path: "18.mp4")
        let sentinelBytes = Data("another job's completed source".utf8)
        try sentinelBytes.write(to: sentinel)

        let formatID = traversal
            ? "../Illucet-\(otherJobID.uuidString)/18"
            : "18"
        let original = try #require(
            DeveloperFixtures.media.formats.first { $0.formatID == "18" }
        )
        var formatJSON = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(original)
            ) as? [String: Any]
        )
        formatJSON["format_id"] = formatID
        let format = try JSONDecoder().decode(
            MediaFormat.self,
            from: JSONSerialization.data(withJSONObject: formatJSON)
        )
        let metadata = DeveloperFixtures.metadata(formats: [format])
        let downloader = CoordinatorScriptedDownloader(failures: [])
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            downloader: downloader
        )
        defer { harness.finish() }
        await harness.configure()
        var configuration = Self.configuration
        configuration.formatSelectionProvenance = .manual
        configuration.selectedVideoFormatID = formatID
        let job = try await harness.enqueue(
            metadata: metadata,
            configuration: configuration
        )
        let jobRoot = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-\(job.id.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: jobRoot) }
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let terminal = try #require(
            harness.recorder.jobs(job.id).last(where: {
                $0.state == .completed || $0.state == .failed
            })
        )
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        if traversal {
            #expect(terminal.state == .failed)
            #expect(
                terminal.errorMessage
                    == StreamTransferDescriptorError.invalidStreamID
                        .localizedDescription
            )
            #expect(await downloader.callCount == 0)
            #expect(await downloader.destinationURLs.isEmpty)
        } else {
            #expect(terminal.state == .completed)
            #expect(await downloader.callCount == 1)
            #expect(
                await downloader.destinationURLs
                    == [jobRoot.appending(path: "18.mp4")]
            )
        }
    }

    @Test
    func ordinaryRemuxUsesOnlyStructuralVerificationAndReusesOutputProbe()
        async throws
    {
        let processor = CoordinatorMediaProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            resolver: CoordinatorRoleAwareResolver(
                exposesExactBytes: false
            ),
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.selectedVideoFormatID = "137"
        configuration.selectedAudioFormatID = "140"
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let terminal = try #require(
            harness.recorder.jobs(job.id).last(where: {
                $0.state == .completed || $0.state == .failed
            })
        )
        #expect(
            terminal.state == .completed,
            Comment(
                rawValue:
                    "Pipeline ended with "
                    + "\(terminal.errorCode ?? "no code"): "
                    + (terminal.errorMessage ?? "no message")
            )
        )

        let verification = await processor.verificationSnapshot()
        #expect(verification.probes.count == 2)
        #expect(
            verification.probes.allSatisfy {
                $0.verificationClass == .fastStructural
            }
        )
        #expect(verification.processes.count == 1)
        #expect(
            verification.processes.map(\.verificationClass)
                == [.fastStructural]
        )
        #expect(
            verification.processes.first.map { process in
                !verification.probes.contains {
                    $0.fileURL == process.destinationURL
                }
            } == true
        )
        #expect(
            verification.fullDecodeVerificationCount == 0
        )
        let transportEntries = await harness.diagnostics.allEntries().filter {
            $0.subsystem == "transport"
        }
        #expect(
            transportEntries.count {
                $0.event == "stream_resolved"
            } == 2
        )
        #expect(
            transportEntries.count {
                $0.event == "stream_transfer_completed"
            } == 2
        )
        #expect(
            transportEntries
                .filter { $0.event == "stream_resolved" }
                .allSatisfy {
                    $0.detail?.contains("http_chunk_size=10485760") == true
                        && $0.detail?.contains("challenge_resolved=true")
                            == true
                        && !$0.detail!.contains("https://")
                        && !$0.detail!.contains("/")
                }
        )
    }

    @Test
    func fragmentPauseBetweenTasksAcknowledgesCancellationAndResumeRestarts() async throws {
        let scenario = CoordinatorDASHScenario.videoOnly
        let resolver = CoordinatorDASHResolver(metadata: scenario.metadata)
        let downloader = CoordinatorPauseGapDASHDownloader()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(scenario.metadata), .success(scenario.metadata)]),
            DASHResolver: resolver, DASHDownloader: downloader, DASHAssembler: CoordinatorDASHAssembler())
        defer { harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue(metadata: scenario.metadata, configuration: scenario.configuration)
        try await waitUntil { await downloader.waitingBetweenResources }
        await harness.coordinator.pause(job.id)
        let paused = try #require(await harness.coordinator.currentJobs().first { $0.id == job.id })
        #expect(paused.state == .paused)
        #expect(paused.resumableTransferStage == nil)
        #expect(paused.pipelineCheckpoint != nil)
        #expect(!FragmentSourceLeases.shared.hasActiveSource(jobID: job.id))
        #expect(await downloader.attempts == 1)
        #expect(await downloader.passedFirstWait == false)
        #expect(!harness.recorder.jobs(job.id).contains { $0.state == .cancelled || $0.state == .failed })
        await harness.coordinator.resume(job.id)
        try await waitUntil { harness.recorder.jobs(job.id).contains { $0.state.isTerminal } }
        let terminal = try #require(harness.recorder.jobs(job.id).last { $0.state.isTerminal })
        #expect(terminal.state == .completed)
        #expect(await downloader.attempts == 2)
        #expect(await downloader.passedFirstWait == false)
        #expect(await resolver.resolvedFormatIDs == ["137", "137"])
    }

    @Test(arguments: [false, true])
    func fragmentPauseWaitsForTransportCancellationBeforeResumeOrCleanup(cancelInstead: Bool) async throws {
        let scenario = CoordinatorDASHScenario.videoOnly
        let fragments = CoordinatorPauseGapDASHDownloader()
        let controls = CoordinatorDelayedPauseControls()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(scenario.metadata), .success(scenario.metadata)]),
            downloader: controls, DASHResolver: CoordinatorDASHResolver(metadata: scenario.metadata),
            DASHDownloader: fragments, DASHAssembler: CoordinatorDASHAssembler())
        defer { controls.releaseAll(); harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue(metadata: scenario.metadata, configuration: scenario.configuration)
        try await waitUntil { await fragments.waitingBetweenResources }
        let pause = Task { await harness.coordinator.pause(job.id) }
        try await waitUntil { controls.cancelCount == 1 && !FragmentSourceLeases.shared.hasActiveSource(jobID: job.id) }
        if cancelInstead {
            let cancel = Task { await harness.coordinator.cancel(job.id) }
            try await waitUntil { controls.cancelCount == 2 }
            controls.release(2)
            await cancel.value
            #expect(controls.discardCount == 0)
            controls.release(1)
            await pause.value
            #expect(controls.discardCount > 0)
            #expect(await harness.coordinator.currentJobs().first { $0.id == job.id }?.state == .cancelled)
            #expect(await fragments.attempts == 1)
        } else {
            await harness.coordinator.resume(job.id, transferLimitOverride: true)
            #expect(await harness.coordinator.currentJob(job.id)?.transferLimitOverride == true)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await fragments.attempts == 1)
            controls.release(1)
            await pause.value
            try await waitUntil { harness.recorder.jobs(job.id).contains { $0.state.isTerminal } }
            #expect(harness.recorder.jobs(job.id).last?.state == .completed)
            #expect(harness.recorder.jobs(job.id).last?.transferLimitOverride == true)
            #expect(await fragments.attempts == 2)
        }
    }

    @Test(arguments: [1, 3])
    func DASHExpiredFragmentProductionRefreshIsExactAndBounded(failures: Int) async throws {
        let accountID = UUID()
        let scenario = CoordinatorDASHScenario.videoOnly
        let resolver = CoordinatorDASHResolver(metadata: scenario.metadata)
        let downloader = CoordinatorDASHDownloader(expiryFailures: failures)
        let assembler = CoordinatorDASHAssembler()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(scenario.metadata)]),
            DASHResolver: resolver, DASHDownloader: downloader, DASHAssembler: assembler, expectedAccountID: accountID)
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.automaticRetryCount = 3
        settings.keepTemporaryFilesAfterFailure = true
        await harness.configure(settings)
        var configuration = scenario.configuration
        configuration.accountID = accountID
        let job = try await harness.enqueue(metadata: scenario.metadata, configuration: configuration)
        try await waitUntil { harness.recorder.jobs(job.id).contains { $0.state.isTerminal } }
        let terminal = try #require(harness.recorder.jobs(job.id).last { $0.state.isTerminal })
        let expectedAttempts = min(failures + 1, 3)
        let exactID = try #require(scenario.DASHFormatIDs.first)
        #expect(await resolver.resolvedFormatIDs == Array(repeating: exactID, count: expectedAttempts))
        #expect(await downloader.downloadedFormatIDs == Array(repeating: exactID, count: expectedAttempts))
        #expect(terminal.retryCount == 0)
        #expect(terminal.state == (failures == 1 ? .completed : .failed))
        #expect(harness.recorder.jobs(job.id).contains {
            $0.pipelineCheckpoint?.fragmentURLRefreshCounts?[exactID] == min(failures, 2)
        })
        if failures == 3 {
            #expect(await assembler.assembledFormatIDs.isEmpty)
        }
    }

    @Test
    func HLSExpiredFragmentRefreshRejectsChangedSelectionBeforeSecondDownload() async throws {
        let accountID = UUID()
        let calls = CoordinatorHLSCallRecorder()
        let initial = try CoordinatorHLSScenario.selection()
        let changed = try CoordinatorHLSScenario.selection(formatID: "different-quality")
        let resolver = CoordinatorHLSResolver(selection: initial, calls: calls, refreshSelection: changed)
        let downloader = CoordinatorHLSDownloader(calls: calls, expiryFailures: 1)
        let assembler = CoordinatorHLSAssembler(calls: calls, mediaProcessor: CoordinatorMediaProcessor())
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(CoordinatorHLSScenario.metadata)]),
            HLSResolver: resolver, HLSDownloader: downloader, HLSAssembler: assembler, expectedAccountID: accountID)
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.automaticRetryCount = 3
        settings.keepTemporaryFilesAfterFailure = true
        await harness.configure(settings)
        var configuration = CoordinatorHLSScenario.configuration
        configuration.accountID = accountID
        let job = try await harness.enqueue(metadata: CoordinatorHLSScenario.metadata,
                                            configuration: configuration)
        try await waitUntil { harness.recorder.jobs(job.id).contains { $0.state.isTerminal } }
        let terminal = try #require(harness.recorder.jobs(job.id).last { $0.state.isTerminal })
        #expect(terminal.state == .failed)
        #expect(terminal.retryCount == 0)
        #expect(await resolver.resolvedFormatIDs == [initial.formatID, initial.formatID])
        #expect(await downloader.downloadedFormatIDs == [initial.formatID])
        #expect(await assembler.assembledFormatIDs.isEmpty)
        #expect(terminal.pipelineCheckpoint?.fragmentURLRefreshCounts?[initial.formatID] == 1)
    }

    @Test(
        "P10.3B production handoff covers exact DASH roles and mixed transport",
        arguments: CoordinatorDASHScenario.allCases
    )
    func DASHProductionHandoff(
        _ scenario: CoordinatorDASHScenario
    ) async throws {
        let metadata = scenario.metadata
        let resolver = CoordinatorDASHResolver(metadata: metadata)
        let DASHDownloader = CoordinatorDASHDownloader()
        let DASHAssembler = CoordinatorDASHAssembler()
        let processor = CoordinatorMediaProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            resolver: CoordinatorRoleAwareResolver(
                exposesExactBytes: false
            ),
            DASHResolver: resolver,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler,
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        let configuration = scenario.configuration
        let job = try await harness.enqueue(
            metadata: metadata,
            configuration: configuration
        )
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let terminal = try #require(
            harness.recorder.jobs(job.id).last {
                $0.state == .completed || $0.state == .failed
            }
        )
        #expect(
            terminal.state == .completed,
            Comment(
                rawValue: terminal.errorMessage
                    ?? terminal.errorCode
                    ?? "DASH pipeline did not complete"
            )
        )
        #expect(await resolver.resolvedFormatIDs == scenario.DASHFormatIDs)
        #expect(await DASHDownloader.downloadedFormatIDs == scenario.DASHFormatIDs)
        #expect(await DASHAssembler.assembledFormatIDs == scenario.DASHFormatIDs)
        #expect(
            await DASHAssembler.verificationClasses
                == Array(
                    repeating: .fastStructural,
                    count: scenario.DASHFormatIDs.count
                )
        )
        let stagingDirectories = await DASHDownloader.stagingDirectories
        #expect(stagingDirectories.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let transferProgress = harness.recorder.jobs(job.id).filter {
            $0.progress.bytesDownloaded > 0
        }
        #expect(!transferProgress.isEmpty)
        #expect(transferProgress.allSatisfy {
            $0.progress.totalBytes == nil
        })

        let checkpointJSON = String(
            decoding: try JSONEncoder().encode(terminal),
            as: UTF8.self
        )
        #expect(!checkpointJSON.contains("fragment-secret"))
        #expect(!checkpointJSON.contains("googlevideo"))
        #expect(!checkpointJSON.contains(".dash-fragments-"))
        let diagnosticText = await harness.diagnostics.allEntries()
            .compactMap(\.detail)
            .joined(separator: "\n")
        #expect(!diagnosticText.contains("fragment-secret"))
        #expect(!diagnosticText.contains("googlevideo"))
        #expect(!diagnosticText.contains("User-Agent"))
        #expect(
            diagnosticText.contains("strategy=dash_fragments")
        )
        if scenario == .mixed {
            #expect(diagnosticText.contains("strategy=one_get"))
        }
    }

    @Test
    func DASHProductionHandoffReusesAcceptedAppControlledSource()
        async throws
    {
        let scenario = CoordinatorDASHScenario.videoOnly
        let resolver = CoordinatorDASHResolver(metadata: scenario.metadata)
        let DASHDownloader = CoordinatorDASHDownloader()
        let DASHAssembler = CoordinatorDASHAssembler()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(scenario.metadata)]
            ),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false),
            DASHResolver: resolver,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler
        )
        defer { harness.finish() }

        await harness.configure()
        var restored = Self.restoredJob(state: .running, title: "DASH reuse")
        restored.configuration = scenario.configuration
        restored.selectedFormatIDs = scenario.configuration.selectedFormatIDs
        let sourceURL = try harness.writeTemporarySource(
            jobID: restored.id,
            filename: "137.mp4",
            data: Data("initmedia".utf8)
        )
        restored.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .transferring,
            sourceFiles: ["137": sourceURL]
        )
        let restoredID = restored.id

        await harness.coordinator.restore([restored])
        try await waitUntil {
            harness.recorder.jobs(restoredID).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let terminal = try #require(
            harness.recorder.jobs(restoredID).last {
                $0.state == .completed || $0.state == .failed
            }
        )
        #expect(terminal.state == .completed)
        #expect(await resolver.resolvedFormatIDs == ["137"])
        #expect(await DASHDownloader.downloadedFormatIDs.isEmpty)
        #expect(await DASHAssembler.assembledFormatIDs.isEmpty)
        let diagnosticText = await harness.diagnostics.allEntries()
            .compactMap(\.detail)
            .joined(separator: "\n")
        #expect(diagnosticText.contains("source_reused=true"))
        #expect(diagnosticText.contains("strategy=source_reuse"))
    }

    @Test
    func DASHProductionHandoffCancellationCleansTransientFragments()
        async throws
    {
        let scenario = CoordinatorDASHScenario.videoOnly
        let resolver = CoordinatorDASHResolver(metadata: scenario.metadata)
        let DASHDownloader = CoordinatorBlockingDASHDownloader()
        let DASHAssembler = CoordinatorDASHAssembler()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(scenario.metadata)]
            ),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false),
            DASHResolver: resolver,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler
        )
        defer { harness.finish() }

        await harness.configure()
        let job = try await harness.enqueue(
            metadata: scenario.metadata,
            configuration: scenario.configuration
        )
        try await waitUntil { await DASHDownloader.hasStarted }
        await harness.coordinator.cancel(job.id)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .cancelled }
        }
        try await waitUntil {
            await DASHDownloader.stagingDirectories.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            }
        }

        #expect(await DASHAssembler.assembledFormatIDs.isEmpty)
        #expect(
            !harness.recorder.jobs(job.id).contains {
                $0.state == .completed
                    || $0.pipelineCheckpoint?.phase == .sourcesReady
            }
        )
    }

    @Test
    func HLSProductionHandoffStagesAssemblesCheckpointsAndCleans()
        async throws
    {
        let metadata = CoordinatorHLSScenario.metadata
        let calls = CoordinatorHLSCallRecorder()
        let selection = try CoordinatorHLSScenario.selection()
        let selectedResources = selection.resourcePlan.events
            .compactMap(\.resource)
        #expect(selectedResources.count == 3)
        #expect(selectedResources.allSatisfy { $0.encryption != nil })
        #expect(selectedResources.map(\.mediaSequence) == [nil, 0, 1])
        let resolver = CoordinatorHLSResolver(
            selection: selection,
            calls: calls
        )
        let HLSDownloader = CoordinatorHLSDownloader(calls: calls)
        let processor = CoordinatorMediaProcessor()
        let HLSAssembler = CoordinatorHLSAssembler(
            calls: calls,
            mediaProcessor: processor
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            HLSResolver: resolver,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler,
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        let job = try await harness.enqueue(
            metadata: metadata,
            configuration: CoordinatorHLSScenario.configuration
        )
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let snapshots = harness.recorder.jobs(job.id)
        let terminal = try #require(snapshots.last {
            $0.state == .completed || $0.state == .failed
        })
        #expect(
            terminal.state == .completed,
            Comment(rawValue: terminal.errorMessage
                ?? terminal.errorCode
                ?? "HLS pipeline did not complete")
        )
        #expect(await calls.events == ["resolve", "stage", "assemble"])
        #expect(
            await resolver.resolvedFormatIDs
                == [CoordinatorHLSScenario.formatID]
        )
        #expect(
            await HLSDownloader.downloadedFormatIDs
                == [CoordinatorHLSScenario.formatID]
        )
        #expect(
            await HLSAssembler.assembledFormatIDs
                == [CoordinatorHLSScenario.formatID]
        )
        #expect(await HLSAssembler.verificationClasses == [.fastStructural])

        let stagingDirectories = await HLSDownloader.stagingDirectories
        #expect(stagingDirectories.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let assemblyDirectories = await HLSAssembler.assemblyDirectories
        #expect(assemblyDirectories.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let destination = try #require(
            await HLSAssembler.destinationURLs.first
        )
        #expect(
            destination.deletingLastPathComponent().lastPathComponent
                == "Illucet-\(job.id.uuidString)"
        )
        #expect(
            destination.lastPathComponent
                == "\(CoordinatorHLSScenario.formatID).mp4"
        )
        let sourcesReady = try #require(snapshots.first {
            $0.pipelineCheckpoint?.phase == .sourcesReady
        })
        #expect(
            sourcesReady.pipelineCheckpoint?.sourceFiles[
                CoordinatorHLSScenario.formatID
            ] == destination
        )

        let transferBytes = snapshots.map(\.progress.bytesDownloaded).filter {
            $0 > 0 && $0 <= 9
        }
        #expect(transferBytes.contains(4))
        #expect(transferBytes.contains(9))
        #expect(
            zip(transferBytes, transferBytes.dropFirst()).allSatisfy {
                $0.0 <= $0.1
            }
        )
        #expect(snapshots.filter {
            $0.progress.bytesDownloaded > 0
        }.allSatisfy {
            $0.progress.totalBytes == nil
        })
        #expect(terminal.outputProbe?.videoStreamCount == 1)
        #expect(terminal.outputProbe?.audioStreamCount == 1)

        let checkpointJSON = String(
            decoding: try JSONEncoder().encode(sourcesReady),
            as: UTF8.self
        )
        let diagnosticText = await harness.diagnostics.allEntries()
            .compactMap(\.detail)
            .joined(separator: "\n")
        for forbidden in CoordinatorEncryptedHLSFixture.secretMarkers {
            #expect(!checkpointJSON.contains(forbidden))
            #expect(!diagnosticText.contains(forbidden))
        }
        #expect(diagnosticText.contains("strategy=hls_resources"))
        #expect(diagnosticText.contains("source_type=hls"))
        #expect(diagnosticText.contains("resource_count=3"))
    }

    @Test
    func HLSAES128RealPipelineDecryptsStagesAssemblesAndPublishes()
        async throws
    {
        let metadata = CoordinatorHLSScenario.metadata
        let selection = try CoordinatorHLSScenario.selection()
        let resources = selection.resourcePlan.events.compactMap(\.resource)
        #expect(resources.count == 3)
        let keyAURL = try #require(resources[0].encryption?.keyURL)
        let keyBURL = try #require(resources[2].encryption?.keyURL)
        #expect(
            resources.compactMap { $0.encryption?.keyURL }
                == [keyAURL, keyAURL, keyBURL]
        )

        CoordinatorEncryptedHLSResourceURLProtocol.reset(
            responses: CoordinatorEncryptedHLSFixture.ciphertextByPath
        )
        defer { CoordinatorEncryptedHLSResourceURLProtocol.reset() }
        let keyLoader = CoordinatorEncryptedHLSKeyLoader(keys: [
            keyAURL.absoluteString: CoordinatorEncryptedHLSFixture.keyA,
            keyBURL.absoluteString: CoordinatorEncryptedHLSFixture.keyB,
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [
            CoordinatorEncryptedHLSResourceURLProtocol.self,
        ]
        let service = StreamDownloadService(
            fileManager: .default,
            sessionIdentifier:
                "tests.illucet.p10c6.e2e.\(UUID().uuidString)",
            configuration: sessionConfiguration,
            hlsAES128KeyLoader: keyLoader
        )
        let calls = CoordinatorHLSCallRecorder()
        let resolver = CoordinatorHLSResolver(
            selection: selection,
            calls: calls
        )
        let HLSDownloader = CoordinatorRecordingRealHLSDownloader(
            delegate: service,
            calls: calls
        )
        let processor = CoordinatorMediaProcessor()
        let HLSAssembler = CoordinatorHLSAssembler(
            calls: calls,
            mediaProcessor: processor
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            HLSResolver: resolver,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler,
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        let job = try await harness.enqueue(
            metadata: metadata,
            configuration: CoordinatorHLSScenario.configuration
        )
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }

        let snapshots = harness.recorder.jobs(job.id)
        let terminal = try #require(snapshots.last {
            $0.state == .completed || $0.state == .failed
        })
        #expect(
            terminal.state == .completed,
            Comment(rawValue: terminal.errorMessage
                ?? terminal.errorCode
                ?? "Real encrypted HLS pipeline did not complete")
        )
        #expect(await calls.events == ["resolve", "stage", "assemble"])
        #expect(
            await keyLoader.requestedURLs() == [keyAURL, keyBURL]
        )
        #expect(
            CoordinatorEncryptedHLSResourceURLProtocol.requestedPaths == [
                "/hls/init.mp4", "/hls/one.m4s", "/hls/two.m4s",
            ]
        )
        #expect(
            CoordinatorEncryptedHLSResourceURLProtocol
                .taskDescriptions.allSatisfy { $0 != nil }
        )
        #expect(
            CoordinatorEncryptedHLSResourceURLProtocol
                .taskDescriptions.count == 3
        )

        let staging = try #require(await HLSDownloader.snapshot)
        #expect(
            staging.plaintextResources
                == CoordinatorEncryptedHLSFixture.plaintextResources
        )
        #expect(staging.byteCounts == [4, 2, 3])
        #expect(
            staging.plaintextResources.allSatisfy {
                !CoordinatorEncryptedHLSFixture.ciphertexts.contains($0)
            }
        )
        #expect(
            staging.resourceURLs.map(\.lastPathComponent) == [
                "resource-000000-init.part",
                "resource-000001-media.part",
                "resource-000002-media.part",
            ]
        )

        let sourcesReady = try #require(snapshots.first {
            $0.pipelineCheckpoint?.phase == .sourcesReady
        })
        let destination = try #require(
            sourcesReady.pipelineCheckpoint?.sourceFiles[
                CoordinatorHLSScenario.formatID
            ]
        )
        let expectedRoot = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-\(job.id.uuidString)",
            directoryHint: .isDirectory
        )
        #expect(
            destination.deletingLastPathComponent().standardizedFileURL
                == expectedRoot.standardizedFileURL
        )
        #expect(
            destination.lastPathComponent
                == "\(CoordinatorHLSScenario.formatID).mp4"
        )
        let publishedSource = try #require(
            await processor.probeFileObservation(for: destination)
        )
        #expect(
            publishedSource.bytes
                == CoordinatorEncryptedHLSFixture.assembledPlaintext
        )
        #expect(publishedSource.isRegularFile == true)
        #expect(publishedSource.isSymbolicLink != true)
        #expect(publishedSource.fileSize == 9)
        #expect(terminal.outputProbe?.videoStreamCount == 1)
        #expect(terminal.outputProbe?.audioStreamCount == 1)

        #expect(
            !FileManager.default.fileExists(
                atPath: staging.directoryURL.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let assemblyDirectories = await HLSAssembler.assemblyDirectories
        #expect(assemblyDirectories.count == 1)
        #expect(assemblyDirectories.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let verification = await processor.verificationSnapshot()
        #expect(verification.probes.contains {
            $0.fileURL.lastPathComponent == ".assembled.partial"
                && $0.verificationClass == .fastStructural
        })

        let checkpointText = String(
            decoding: try JSONEncoder().encode(sourcesReady),
            as: UTF8.self
        )
        let diagnosticText = await harness.diagnostics.allEntries()
            .compactMap(\.detail)
            .joined(separator: "\n")
        let descriptorText = CoordinatorEncryptedHLSResourceURLProtocol
            .taskDescriptions.compactMap { $0 }.joined(separator: "\n")
        let filenameText = (
            staging.resourceURLs
                + assemblyDirectories
                + [destination]
        ).map(\.lastPathComponent).joined(separator: "\n")
        for forbidden in CoordinatorEncryptedHLSFixture.secretMarkers {
            #expect(!checkpointText.contains(forbidden))
            #expect(!diagnosticText.contains(forbidden))
            #expect(!descriptorText.contains(forbidden))
            #expect(!filenameText.contains(forbidden))
        }
        #expect(diagnosticText.contains("strategy=hls_resources"))
        #expect(diagnosticText.contains("source_type=hls"))
        #expect(diagnosticText.contains("resource_count=3"))
    }

    @Test
    func HLSProductionHandoffRejectsResolvedIdentityBeforeStaging()
        async throws
    {
        let metadata = CoordinatorHLSScenario.metadata
        let mismatches = try [
            CoordinatorHLSScenario.selection(videoID: "AbCdEf123_-"),
            CoordinatorHLSScenario.selection(formatID: "hls-other"),
            CoordinatorHLSScenario.selection(protocolName: "m3u8"),
            CoordinatorHLSScenario.selection(sourceType: "dash"),
            CoordinatorHLSScenario.selection(fileExtension: "webm"),
            CoordinatorHLSScenario.selection(hasAudio: false),
        ]
        for mismatch in mismatches {
            let calls = CoordinatorHLSCallRecorder()
            let resolver = CoordinatorHLSResolver(
                selection: mismatch,
                calls: calls
            )
            let HLSDownloader = CoordinatorHLSDownloader(calls: calls)
            let HLSAssembler = CoordinatorHLSAssembler(
                calls: calls,
                mediaProcessor: CoordinatorMediaProcessor()
            )
            let harness = try CoordinatorHarness(
                network: .fixtureWiFi,
                extractor: CoordinatorScriptedExtractor(
                    results: [.success(metadata)]
                ),
                HLSResolver: resolver,
                HLSDownloader: HLSDownloader,
                HLSAssembler: HLSAssembler
            )
            defer { harness.finish() }

            var settings = AppSettings.defaults
            settings.automaticRetryCount = 0
            await harness.configure(settings)
            let job = try await harness.enqueue(
                metadata: metadata,
                configuration: CoordinatorHLSScenario.configuration
            )
            try await waitUntil {
                harness.recorder.jobs(job.id).contains {
                    $0.state == .failed
                }
            }

            #expect(await calls.events == ["resolve"])
            #expect(await HLSDownloader.downloadedFormatIDs.isEmpty)
            #expect(await HLSAssembler.assembledFormatIDs.isEmpty)
            #expect(!harness.recorder.jobs(job.id).contains {
                $0.pipelineCheckpoint?.phase == .sourcesReady
            })
        }
    }

    @Test
    func HLSProductionHandoffReusesOnlyAcceptedJobLocalSource()
        async throws
    {
        let metadata = CoordinatorHLSScenario.metadata
        let calls = CoordinatorHLSCallRecorder()
        let resolver = CoordinatorHLSResolver(
            selection: try CoordinatorHLSScenario.selection(),
            calls: calls
        )
        let HLSDownloader = CoordinatorHLSDownloader(calls: calls)
        let HLSAssembler = CoordinatorHLSAssembler(
            calls: calls,
            mediaProcessor: CoordinatorMediaProcessor()
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            HLSResolver: resolver,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler
        )
        defer { harness.finish() }

        await harness.configure()
        var restored = Self.restoredJob(state: .running, title: "HLS reuse")
        restored.configuration = CoordinatorHLSScenario.configuration
        restored.selectedFormatIDs =
            CoordinatorHLSScenario.configuration.selectedFormatIDs
        let sourceURL = try harness.writeTemporarySource(
            jobID: restored.id,
            filename: "\(CoordinatorHLSScenario.formatID).mp4",
            data: Data("initmedia".utf8)
        )
        restored.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .transferring,
            sourceFiles: [CoordinatorHLSScenario.formatID: sourceURL]
        )
        let restoredID = restored.id

        await harness.coordinator.restore([restored])
        try await waitUntil {
            harness.recorder.jobs(restoredID).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let terminal = try #require(
            harness.recorder.jobs(restoredID).last {
                $0.state == .completed || $0.state == .failed
            }
        )
        #expect(terminal.state == .completed)
        #expect(await calls.events == ["resolve"])
        #expect(await HLSDownloader.downloadedFormatIDs.isEmpty)
        #expect(await HLSAssembler.assembledFormatIDs.isEmpty)
        let diagnosticText = await harness.diagnostics.allEntries()
            .compactMap(\.detail)
            .joined(separator: "\n")
        #expect(diagnosticText.contains("source_reused=true"))
        #expect(diagnosticText.contains("strategy=source_reuse"))
    }

    @Test
    func nativeProcessingCancellationStaysCancelledWithoutFailureHistory() async throws {
        let processor = CoordinatorTypedCancellationProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            processor: processor
        )
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.keepTemporaryFilesAfterFailure = false
        await harness.configure(settings)
        let job = try await harness.enqueue()
        try await waitUntil { await processor.hasStarted }
        await harness.coordinator.cancel(job.id)
        try await waitUntil {
            await harness.coordinator.currentJobs().first { $0.id == job.id }?.state == .cancelled
                && !harness.temporaryRootExists(jobID: job.id)
        }
        #expect(!harness.recorder.jobs(job.id).contains { $0.state == .failed })
        #expect(harness.recorder.history(job.id).isEmpty)
        #expect(await processor.hasFinished)
    }

    @Test
    func HLSProductionHandoffCancellationCleansTransientResources()
        async throws
    {
        let metadata = CoordinatorHLSScenario.metadata
        let calls = CoordinatorHLSCallRecorder()
        let resolver = CoordinatorHLSResolver(
            selection: try CoordinatorHLSScenario.selection(),
            calls: calls
        )
        let HLSDownloader = CoordinatorHLSDownloader(calls: calls)
        let HLSAssembler = CoordinatorBlockingHLSAssembler(calls: calls)
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(metadata)]
            ),
            HLSResolver: resolver,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.keepTemporaryFilesAfterFailure = false
        await harness.configure(settings)
        let job = try await harness.enqueue(
            metadata: metadata,
            configuration: CoordinatorHLSScenario.configuration
        )
        try await waitUntil { await HLSAssembler.hasStarted }
        await harness.coordinator.cancel(job.id)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .cancelled }
        }
        try await waitUntil {
            await HLSDownloader.stagingDirectories.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            }
        }
        try await waitUntil {
            !harness.temporaryRootExists(jobID: job.id)
        }

        #expect(await calls.events == ["resolve", "stage", "assemble"])
        #expect(!harness.recorder.jobs(job.id).contains {
            $0.state == .completed
                || $0.pipelineCheckpoint?.phase == .sourcesReady
        })
        #expect(!harness.temporaryRootExists(jobID: job.id))
    }

    @Test
    func sponsorBlockExecutionDiagnosticsAreOptInAndObservational()
        async throws
    {
        let scenario = CoordinatorDASHScenario.combined
        let submittedVideoDuration = try #require(
            scenario.metadata.durationSeconds
        )
        let resolver = CoordinatorDASHResolver(metadata: scenario.metadata)
        let DASHDownloader = CoordinatorDASHDownloader()
        let DASHAssembler = CoordinatorDASHAssembler()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [
                    .success(scenario.metadata),
                    .success(scenario.metadata),
                ]
            ),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false),
            DASHResolver: resolver,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler
        )
        defer { harness.finish() }

        var configuration = scenario.configuration
        var policy = SponsorBlockPolicy(
            isEnabled: true,
            selectedCategories: [.sponsor]
        )
        policy.setAction(.markAsChapter, for: .sponsor)
        policy.replaceSelection(
            videoID: scenario.metadata.videoID,
            queriedCategories: policy.requestedDiscoveryCategories,
            segments: [
                SponsorBlockSegment(
                    segmentID: "diagnostic-chapter",
                    category: .sponsor,
                    startSeconds: 1,
                    endSeconds: 2,
                    description: nil,
                    submittedVideoDuration: submittedVideoDuration,
                    serverAction: .skip,
                    votes: 1,
                    isLocked: false
                ),
            ]
        )
        configuration.sponsorBlock = policy

        var settings = AppSettings.defaults
        settings.sponsorBlockDiagnosticLoggingEnabled = true
        await harness.configure(settings)
        let enabledJob = try await harness.enqueue(
            metadata: scenario.metadata,
            configuration: configuration
        )
        try await waitUntil {
            harness.recorder.jobs(enabledJob.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let enabledTerminal = try #require(
            harness.recorder.jobs(enabledJob.id).last {
                $0.state == .completed || $0.state == .failed
            }
        )
        #expect(
            enabledTerminal.state == .completed,
            Comment(
                rawValue: enabledTerminal.errorMessage
                    ?? enabledTerminal.errorCode
                    ?? "SponsorBlock diagnostic fixture did not complete"
            )
        )
        let enabledEntries = await harness.diagnostics.allEntries().filter {
            $0.subsystem == "sponsorblock"
        }
        #expect(Set(enabledEntries.map(\.event)) == [
            "execution_started", "execution_completed",
        ])
        let enabledText = enabledEntries.compactMap(\.detail)
            .joined(separator: "\n")
        #expect(enabledText.contains("selected_entry_count=1"))
        #expect(enabledText.contains("chapter_count=1"))
        #expect(!enabledText.contains("diagnostic-chapter"))
        #expect(!enabledText.contains(scenario.metadata.videoID))

        settings.sponsorBlockDiagnosticLoggingEnabled = false
        await harness.configure(settings)
        let disabledJob = try await harness.enqueue(
            metadata: scenario.metadata,
            configuration: configuration
        )
        try await waitUntil {
            harness.recorder.jobs(disabledJob.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }
        let disabledTerminal = try #require(
            harness.recorder.jobs(disabledJob.id).last {
                $0.state == .completed || $0.state == .failed
            }
        )
        #expect(
            disabledTerminal.state == .completed,
            Comment(
                rawValue: disabledTerminal.errorMessage
                    ?? disabledTerminal.errorCode
                    ?? "SponsorBlock diagnostic fixture did not complete"
            )
        )
        #expect(
            disabledTerminal.outputProbe?.streams
                == enabledTerminal.outputProbe?.streams
        )
        #expect(
            await harness.diagnostics.allEntries().count {
                $0.subsystem == "sponsorblock"
            } == enabledEntries.count
        )
    }

    @Test
    func exactTransferredByteMismatchIsDeletedBeforeMediaProcessing()
        async throws
    {
        let processor = CoordinatorMediaProcessor()
        let downloader = CoordinatorScriptedDownloader(failures: [])
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            resolver: CoordinatorRoleAwareResolver(
                exposesExactBytes: true
            ),
            downloader: downloader,
            processor: processor
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 0
        settings.keepTemporaryFilesAfterFailure = true
        await harness.configure(settings)
        let job = try await harness.enqueue()
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .failed
            }
        }

        #expect(await downloader.callCount == 1)
        #expect(
            await downloader.verifiedExpectedByteCounts == [16_000_000]
        )
        let destinations = await downloader.destinationURLs
        #expect(destinations.count == 1)
        #expect(destinations.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        let verification = await processor.verificationSnapshot()
        #expect(verification.probes.isEmpty)
        #expect(verification.processes.isEmpty)
    }

    @Test
    func terminalAudioTranscodePerformsOneBoundedFinalVerification()
        async throws
    {
        let processor = CoordinatorMediaProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.mode = .audioOnly
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = "18"
        configuration.audioCodec = .aac
        configuration.container = .m4a
        configuration.audioRateControl = .quality
        configuration.audioQuality = .high
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed
            }
        }

        let verification = await processor.verificationSnapshot()
        #expect(verification.probes.count == 1)
        #expect(
            verification.probes.map(\.verificationClass)
                == [.fastStructural]
        )
        #expect(verification.processes.count == 1)
        #expect(
            verification.processes.map(\.verificationClass)
                == [.boundedStrong]
        )
        #expect(verification.boundedVerificationCount == 1)
        #expect(verification.fullDecodeVerificationCount == 0)
        #expect(
            verification.processes.first.map { process in
                !verification.probes.contains {
                    $0.fileURL == process.destinationURL
                }
            } == true
        )
    }

    @Test
    func automaticSelectionRecoversAcrossExecutionReanalysis() async throws {
        let changedInventory = DeveloperFixtures.metadata(
            formats: DeveloperFixtures.media.formats.filter {
                ["401", "18", "251"].contains($0.formatID)
            }
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(changedInventory)]
            )
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.preset = .compatible
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = nil
        configuration.formatSelectionProvenance = nil
        FormatSelection.applyAutomaticSelection(
            to: &configuration,
            metadata: DeveloperFixtures.media
        )
        #expect(configuration.selectedFormatIDs == ["137", "140"])
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.configuration.selectedFormatIDs == ["18"]
                    && $0.selectedFormatIDs == ["18"]
            }
        }
        let refreshed = try #require(
            harness.recorder.jobs(job.id).last {
                $0.configuration.selectedFormatIDs == ["18"]
            }
        )
        #expect(refreshed.configuration.formatSelectionProvenance == .automatic)
        await harness.coordinator.cancelAll()
    }

    @Test
    func manualExactSelectionIsNotSubstitutedDuringReanalysis() async throws {
        let changedInventory = DeveloperFixtures.metadata(
            formats: DeveloperFixtures.media.formats.filter {
                ["401", "18", "251"].contains($0.formatID)
            }
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(changedInventory)]
            )
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 0
        await harness.configure(settings)
        var configuration = Self.configuration
        configuration.selectedVideoFormatID = "137"
        configuration.selectedAudioFormatID = "140"
        configuration.formatSelectionProvenance = .manual
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .failed }
        }
        let failed = try #require(
            harness.recorder.jobs(job.id).last { $0.state == .failed }
        )
        #expect(failed.selectedFormatIDs == ["137", "140"])
        #expect(failed.configuration.selectedFormatIDs == ["137", "140"])
        #expect(failed.configuration.formatSelectionProvenance == .manual)
        #expect(
            failed.errorMessage
                == OutputCompatibilityError.invalidFormatSelection
                    .localizedDescription
        )
    }

    @Test
    func noisyProcessingProgressStaysBoundedThroughCoordinatorAndTerminalWins()
        async throws
    {
        let processor = CoordinatorNoisyMediaProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            resolver: CoordinatorRoleAwareResolver(
                exposesExactBytes: false
            ),
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.selectedVideoFormatID = "137"
        configuration.selectedAudioFormatID = "140"
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed || $0.state == .failed
            }
        }

        let measurement = try #require(
            await processor.measurements.first
        )
        let observations = harness.recorder.jobObservations(job.id)
        let processingObservations = observations.filter {
            $0.observedAt >= measurement.operationStartedAt
                && ($0.job.stage == .merging
                    || $0.job.stage == .verifyingOutput)
                && $0.job.progress.processingFraction != nil
        }
        let deliveredProcessingUpdates =
            processingObservations.reduce(
                into: [CoordinatorJobObservation]()
            ) { delivered, observation in
                guard
                    delivered.last?.job.stage != observation.job.stage
                        || delivered.last?.job.progress.processingFraction
                            != observation.job.progress.processingFraction
                else { return }
                delivered.append(observation)
            }
        let newestSteadyFraction = Double(10_000) / Double(10_001)
        let nextStage = try #require(
            observations.first {
                $0.observedAt >= measurement.operationFinishedAt
                    && $0.job.stage == .verifyingOutput
            }
        )
        #expect(nextStage.job.progress.processingFraction == nil)
        #expect(nextStage.job.progress.processingETASeconds == nil)
        let finalProgress = try #require(
            observations.first {
                $0.observedAt <= nextStage.observedAt
                    && $0.job.stage == .merging
                    && $0.job.progress.processingFraction == 1
            }
        )
        let terminal = try #require(
            observations.first {
                $0.observedAt >= measurement.operationFinishedAt
                    && $0.job.state.isTerminal
            }
        )
        let operationElapsed = measurement.operationStartedAt.duration(
            to: measurement.operationFinishedAt
        )
        let finishToNextStage = measurement.operationFinishedAt.duration(
            to: nextStage.observedAt
        )
        let finalProgressToFinish = finalProgress.observedAt.duration(
            to: measurement.operationFinishedAt
        )
        let finishToTerminal = measurement.operationFinishedAt.duration(
            to: terminal.observedAt
        )

        #expect(measurement.progressOpportunities == 10_002)
        #expect(deliveredProcessingUpdates.count >= 2)
        // The coordinator also publishes a bounded number of durable
        // checkpoint/stage snapshots carrying the newest processing value.
        #expect(deliveredProcessingUpdates.count <= 8)
        #expect(
            deliveredProcessingUpdates.contains {
                $0.job.stage == .merging
                    && $0.job.progress.processingFraction == 0
            }
        )
        #expect(
            deliveredProcessingUpdates.contains {
                guard $0.job.stage == .merging,
                      let fraction = $0.job.progress.processingFraction
                else { return false }
                return abs(fraction - newestSteadyFraction) < 0.000_001
            }
        )
        #expect(finalProgress.job.progress.processingFraction == 1)
        #expect(nextStage.job.progress.overallFraction == 0.96)
        #expect(
            observations.allSatisfy {
                $0.observedAt < nextStage.observedAt
                    || $0.job.stage != .merging
            }
        )
        #expect(terminal.job.state == .completed)
        #expect(terminal.job.stage == .complete)
        #expect(operationElapsed < .seconds(1))
        #expect(finishToNextStage < .milliseconds(500))
        #expect(finalProgressToFinish < .milliseconds(500))
        #expect(finishToTerminal < .seconds(1))
        print(
            "coordinator_progress_measurement "
                + "opportunities=\(measurement.progressOpportunities) "
                + "delivered=\(deliveredProcessingUpdates.count) "
                + "operation_elapsed=\(operationElapsed) "
                + "finish_to_next_stage=\(finishToNextStage) "
                + "final_progress_to_finish=\(finalProgressToFinish) "
                + "finish_to_terminal=\(finishToTerminal)"
        )
    }

    @Test
    func thumbnailOnlyPipelineSkipsMediaResolutionAndProcessing()
        async throws
    {
        let resolver = CoordinatorCountingResolver()
        let processor = CoordinatorMediaProcessor()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            resolver: resolver,
            processor: processor
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.thumbnailBehavior = .thumbnailOnly
        configuration.thumbnailFormat = .original
        configuration.selectedVideoFormatID = nil
        configuration.selectedAudioFormatID = nil
        configuration.sponsorBlock = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
        configuration.sponsorBlock.setAction(.remove, for: .sponsor)
        configuration.sponsorBlock.removalMode = .fastKeyframe
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed
            }
        }
        let completed = try #require(
            harness.recorder.jobs(job.id).last { $0.state == .completed }
        )
        let outputURL = try #require(completed.outputURL)
        let verification = await processor.verificationSnapshot()
        let stages = harness.recorder.jobs(job.id).map(\.stage)

        #expect(completed.configuration.sponsorBlock == .disabled)
        #expect(completed.effectiveOutputIdentity == .thumbnailOnly)
        #expect(completed.selectedFormatIDs.isEmpty)
        #expect(completed.outputProbe == nil)
        #expect(outputURL.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(resolver.callCount == 0)
        #expect(verification.processes.isEmpty)
        #expect(verification.probes.isEmpty)
        #expect(stages.contains(.downloadingThumbnail))
        #expect(stages.contains(.savingFiles))
        #expect(!stages.contains(.downloadingVideo))
        #expect(!stages.contains(.downloadingAudio))
        #expect(!stages.contains(.verifyingSources))
        #expect(!harness.temporaryRootExists(jobID: job.id))
        #expect(harness.recorder.history(job.id).count == 1)
        #expect(
            harness.recorder.history(job.id).first?.effectiveOutputIdentity
                == .thumbnailOnly
        )
    }

    @Test(arguments: [BundleStyle.packageFolder, .zip])
    func packageFinalizationCompletesExportCleanupAndHistory(
        bundleStyle: BundleStyle
    ) async throws {
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            )
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.bundleStyle = bundleStyle
        configuration.filenameTemplate = "Package Fixture"
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed
            }
        }
        let completed = try #require(
            harness.recorder.jobs(job.id).last { $0.state == .completed }
        )
        let packageURL = try #require(completed.packageURL)
        let values = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        )
        let stages = harness.recorder.jobs(job.id).map(\.stage)
        let history = try #require(harness.recorder.history(job.id).first)

        #expect(completed.outputURL == packageURL)
        #expect(completed.pipelineCheckpoint?.phase == .complete)
        #expect(stages.contains(.packaging))
        #expect(stages.contains(.savingFiles))
        #expect(stages.contains(.cleaningUp))
        #expect(stages.contains(.zipping) == (bundleStyle == .zip))
        #expect(!harness.temporaryRootExists(jobID: job.id))
        #expect(harness.recorder.history(job.id).count == 1)
        #expect(history.packageURL == packageURL)
        if bundleStyle == .zip {
            #expect(values.isRegularFile == true)
            #expect(packageURL.pathExtension == "zip")
        } else {
            #expect(values.isDirectory == true)
            #expect(packageURL.pathExtension.isEmpty)
        }
    }

    @Test
    func selectedSubtitleRunsThroughPipelineAndPublishesSidecar()
        async throws
    {
        let transport = CoordinatorSubtitleTransport()
        let extractor = CoordinatorScriptedExtractor(
            results: [.success(DeveloperFixtures.media)]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: extractor,
            subtitleTransport: transport
        )
        defer { harness.finish() }

        await harness.configure()
        var configuration = Self.configuration
        configuration.subtitleDelivery = .sidecarSRT
        configuration.subtitleSelections = [
            SubtitleTrackSelection(
                trackID: "subtitle-111111111111111111111111",
                formatID: "subtitle-format-111111111111111111111111",
                language: "en",
                automatic: false
            ),
        ]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed && $0.subtitleSidecars?.count == 1
            }
        }
        let completed = try #require(
            harness.recorder.jobs(job.id).last {
                $0.state == .completed
            }
        )
        let mediaURL = try #require(completed.outputURL)
        let sidecar = try #require(completed.subtitleSidecars?.first)
        let sidecarURL = try #require(sidecar.localURL)
        #expect(await transport.callCount == 1)
        #expect(sidecar.kind == .subRip)
        #expect(sidecar.selection.automatic == false)
        #expect(sidecarURL.deletingLastPathComponent()
            == mediaURL.deletingLastPathComponent())
        #expect(sidecarURL.deletingPathExtension().lastPathComponent
            .hasPrefix(mediaURL.deletingPathExtension().lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(harness.preparedSubtitleFiles(jobID: job.id).isEmpty)
    }

    @Test
    func filesAndPhotosFailureRetainsRequiredSidecarWithFilesCopy()
        async throws
    {
        let transport = CoordinatorSubtitleTransport()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            photoLibrary: CoordinatorFailingPhotoLibrary(),
            subtitleTransport: transport
        )
        defer { harness.finish() }

        let bookmark = try await harness.filesBookmark()
        await harness.configure(folderBookmark: bookmark)
        var configuration = Self.configuration
        configuration.destination = .filesAndPhotos
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
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .failed
                    && $0.outputURL != nil
                    && $0.subtitleSidecars?.count == 1
            }
        }
        let failed = try #require(
            harness.recorder.jobs(job.id).last { $0.state == .failed }
        )
        let mediaURL = try #require(failed.outputURL)
        let sidecarURL = try #require(
            failed.subtitleSidecars?.first?.localURL
        )
        #expect(failed.errorCode == "files_saved_photos_failed")
        #expect(sidecarURL.deletingLastPathComponent()
            == mediaURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: mediaURL.path))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(harness.preparedSubtitleFiles(jobID: job.id).isEmpty)
    }

    @Test
    func thrownThumbnailDuplicatePreflightCleansOnlyPreparedSidecars()
        async throws
    {
        let transport = CoordinatorSubtitleTransport()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            subtitleTransport: transport
        )
        defer { harness.finish() }
        await transport.setMutation {
            try harness.replaceDocumentsRootWithFile()
        }

        var settings = AppSettings.defaults
        settings.keepTemporaryFilesAfterFailure = true
        await harness.configure(settings)
        let configuration = Self.sidecarAndThumbnailConfiguration
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .failed }
        }
        #expect(harness.temporaryRootExists(jobID: job.id))
        #expect(harness.preparedSubtitleFiles(jobID: job.id).isEmpty)
        #expect(!harness.unrelatedTemporaryFiles(jobID: job.id).isEmpty)
    }

    @Test
    func cancelledThumbnailDuplicateDecisionCleansOnlyPreparedSidecars()
        async throws
    {
        let transport = CoordinatorSubtitleTransport()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [.success(DeveloperFixtures.media)]
            ),
            subtitleTransport: transport
        )
        defer { harness.finish() }
        try harness.writeDocumentFixture(
            filename: "Fixture-thumbnail.png"
        )

        var settings = AppSettings.defaults
        settings.duplicateHandling = .ask
        settings.keepTemporaryFilesAfterFailure = true
        await harness.configure(settings)
        let configuration = Self.sidecarAndThumbnailConfiguration
        let job = try await harness.enqueue(configuration: configuration)

        try await waitUntil {
            harness.recorder.duplicateRequest(jobID: job.id) != nil
        }
        let request = try #require(
            harness.recorder.duplicateRequest(jobID: job.id)
        )
        #expect(request.desiredURL.lastPathComponent == "Fixture-thumbnail.png")
        await harness.coordinator.resolveDuplicate(
            requestID: request.id,
            handling: nil
        )

        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .cancelled }
        }
        #expect(harness.temporaryRootExists(jobID: job.id))
        #expect(harness.preparedSubtitleFiles(jobID: job.id).isEmpty)
        #expect(!harness.unrelatedTemporaryFiles(jobID: job.id).isEmpty)
    }

    @Test
    func unavailableNetworkHoldsWithoutExtractionThenWiFiStarts() async throws {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .unavailable,
            extractor: extractor
        )
        defer { harness.finish() }

        await harness.configure()
        let job = try await harness.enqueue()

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForNetwork
            }
        }
        #expect(extractor.callCount == 0)

        harness.network.send(.fixtureWiFi)

        try await waitUntil {
            extractor.callCount == 1
        }
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .failed
            }
        }
    }

    @Test
    func queuedNetworkWaitCanBePausedAndResumedWithoutStartingWork()
        async throws {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .unavailable,
            extractor: extractor
        )
        defer { harness.finish() }

        await harness.configure()
        let job = try await harness.enqueue()
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForNetwork
            }
        }

        await harness.coordinator.pause(job.id)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .paused
            }
        }
        #expect(extractor.callCount == 0)

        await harness.coordinator.resume(job.id)
        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForNetwork
            }
        }
        #expect(extractor.callCount == 0)
    }

    @Test
    func cellularContinueOnceStartsOnlyTheRequestedJob() async throws {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureCellular,
            extractor: extractor
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.askBeforeCellular = true
        await harness.configure(settings)
        let job = try await harness.enqueue()

        let request = try await waitForNetworkRequest(
            jobID: job.id,
            recorder: harness.recorder
        )
        #expect(extractor.callCount == 0)
        #expect(
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForCellularApproval
            }
        )

        await harness.coordinator.resolveNetworkAccess(
            requestID: request.id,
            choice: .continueOnce
        )

        try await waitUntil {
            extractor.callCount == 1
        }
        #expect(
            !harness.recorder.hasCellularPreferenceChange(false)
        )
    }

    @Test
    func cellularAlwaysAllowStartsAndPublishesGlobalPreference()
        async throws
    {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureCellular,
            extractor: extractor
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.askBeforeCellular = true
        await harness.configure(settings)
        let job = try await harness.enqueue()
        let request = try await waitForNetworkRequest(
            jobID: job.id,
            recorder: harness.recorder
        )

        await harness.coordinator.resolveNetworkAccess(
            requestID: request.id,
            choice: .alwaysAllow
        )

        try await waitUntil {
            extractor.callCount == 1
                && harness.recorder.hasCellularPreferenceChange(false)
        }
    }

    @Test func chargingRequirementWaitsThenAdmitsWithoutRestartingActiveWork() async throws {
        let extractor = CoordinatorScriptedExtractor(results: [.failure(Self.permanentExtractionFailure)])
        let harness = try CoordinatorHarness(network: .fixtureWiFi, extractor: extractor)
        defer { harness.finish() }
        await harness.configure()
        var configuration = Self.configuration
        configuration.waitForCharging = true
        let job = try await harness.enqueue(configuration: configuration)
        try await waitUntil { harness.recorder.jobs(job.id).contains { $0.state == .waitingForPower } }
        #expect(extractor.callCount == 0)
        await harness.coordinator.updatePowerState(connected: true)
        try await waitUntil { extractor.callCount == 1 }
        await harness.coordinator.updatePowerState(connected: false)
        #expect(extractor.callCount == 1)
    }

    @Test
    func cellularWaitForWiFiAutomaticallyStartsOnWiFi() async throws {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureCellular,
            extractor: extractor
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.askBeforeCellular = true
        await harness.configure(settings)
        let job = try await harness.enqueue()
        let request = try await waitForNetworkRequest(
            jobID: job.id,
            recorder: harness.recorder
        )

        await harness.coordinator.resolveNetworkAccess(
            requestID: request.id,
            choice: .waitForWiFi
        )

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForWiFi
                    && $0.networkAuthorization == .waitForWiFi
            }
        }
        #expect(extractor.callCount == 0)

        harness.network.send(.fixtureWiFi)
        try await waitUntil {
            extractor.callCount == 1
        }
    }

    @Test
    func cellularCancelTerminatesWithoutStartingExtraction()
        async throws
    {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureCellular,
            extractor: extractor
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.askBeforeCellular = true
        await harness.configure(settings)
        let job = try await harness.enqueue()
        let request = try await waitForNetworkRequest(
            jobID: job.id,
            recorder: harness.recorder
        )

        await harness.coordinator.resolveNetworkAccess(
            requestID: request.id,
            choice: .cancel
        )

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .cancelled
            }
        }
        #expect(extractor.callCount == 0)
    }

    @Test
    func retryableExtractorStopsAtConfiguredRetryCap() async throws {
        let retryable = ExtractionError.extractorFailure(
            code: "temporary",
            message: "Try again.",
            retryable: true
        )
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(retryable),
                .failure(retryable),
                .failure(retryable),
                .failure(retryable),
            ]
        )
        let sleeper = CoordinatorSleeperRecorder()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: extractor,
            retrySleeper: { delay in
                await sleeper.record(delay)
            }
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 2
        await harness.configure(settings)
        let job = try await harness.enqueue()

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .failed && $0.retryCount == 2
            }
        }

        #expect(extractor.callCount == 3)
        #expect(extractor.allowsRecentAnalysis == [true, false, false])
        #expect(await sleeper.delays == [1, 2])
        #expect(
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForRetry
                    && $0.stage == .waitingToRetry
            }
        )
    }

    @Test
    func permanentExtractorFailureIsNeverRetried() async throws {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .failure(Self.permanentExtractionFailure),
                .success(DeveloperFixtures.media),
            ]
        )
        let sleeper = CoordinatorSleeperRecorder()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: extractor,
            retrySleeper: { delay in
                await sleeper.record(delay)
            }
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 4
        await harness.configure(settings)
        let job = try await harness.enqueue()

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .failed
            }
        }

        #expect(extractor.callCount == 1)
        #expect(await sleeper.delays.isEmpty)
        #expect(
            harness.recorder.jobs(job.id)
                .last(where: { $0.state == .failed })?
                .retryCount == 0
        )
    }

    @Test
    func restorationRecoversCheckpointButFlagsLegacyRunningJob()
        async throws
    {
        let harness = try CoordinatorHarness(
            network: .unavailable,
            extractor: CoordinatorScriptedExtractor(
                results: [
                    .failure(Self.permanentExtractionFailure),
                ]
            )
        )
        defer { harness.finish() }

        await harness.configure()
        var checkpointed = Self.restoredJob(
            state: .running,
            title: "Checkpointed"
        )
        checkpointed.pipelineCheckpoint = DownloadPipelineCheckpoint(
            phase: .sourcesReady
        )
        let legacy = Self.restoredJob(
            state: .running,
            title: "Legacy"
        )
        let checkpointedID = checkpointed.id
        let legacyID = legacy.id

        await harness.coordinator.restore([checkpointed, legacy])

        try await waitUntil {
            harness.recorder.jobs(checkpointedID).contains {
                $0.state == .queued && $0.stage == .restoring
            }
                && harness.recorder.jobs(legacyID).contains {
                    $0.state == .needsAttention
                        && $0.errorCode == "app_was_terminated"
                }
        }
        #expect(
            !harness.recorder.jobs(checkpointedID).contains {
                $0.state == .needsAttention
            }
        )
    }

    @Test
    func restorationReconstructsProgressFromBackgroundTaskCounters()
        async throws
    {
        var restored = Self.restoredJob(
            state: .running,
            title: "Background transfer"
        )
        restored.progress.instantaneousBytesPerSecond = 9_999
        restored.progress.smoothedBytesPerSecond = 8_888
        restored.progress.downloadETASeconds = 42
        restored.progress.sampleCount = 8
        let descriptor = try StreamTransferDescriptor(
            sessionIdentifier: "tests.illucet.background",
            taskIdentifier: 17,
            jobID: restored.id,
            streamID: "18",
            destination: StreamTransferDestinationIdentity(
                root: .temporary,
                relativePath: "Illucet-\(restored.id.uuidString)/18.mp4"
            )
        )
        let downloader = CoordinatorRestorationDownloader(
            registrations: [
                StreamTransferRegistration(
                    descriptor: descriptor,
                    state: .suspended,
                    bytesReceived: 40,
                    totalBytesExpected: 100,
                    verifiedReusableBytes: 32,
                    networkBytesReceived: 8
                ),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .unavailable,
            extractor: CoordinatorScriptedExtractor(
                results: [
                    .failure(Self.permanentExtractionFailure),
                ]
            ),
            downloader: downloader
        )
        defer { harness.finish() }

        await harness.configure()
        let jobID = restored.id
        await harness.coordinator.restore([restored])

        try await waitUntil {
            harness.recorder.jobs(jobID).contains {
                $0.progress.bytesDownloaded == 40
                    && $0.progress.totalBytes == 100
                    && $0.progress.currentStream == "18"
            }
        }
        let reconstructed = try #require(
            harness.recorder.jobs(jobID).last {
                $0.progress.bytesDownloaded == 40
            }
        )
        #expect(
            abs(
                (reconstructed.progress.overallFraction ?? 0) - 0.312
            ) < 0.000_001
        )
        #expect(reconstructed.progress.instantaneousBytesPerSecond == nil)
        #expect(reconstructed.progress.smoothedBytesPerSecond == nil)
        #expect(reconstructed.progress.downloadETASeconds == nil)
        #expect(reconstructed.progress.sampleCount == 0)
        #expect(reconstructed.progress.verifiedReusableBytes == 32)
    }

    @Test(arguments: [false, true])
    func restorationKeepsAdmittedNativeTransfersRunningAndPreservesUserPause(paused: Bool) async throws {
        var job = Self.restoredJob(state: paused ? .paused : .running, title: "Native restoration")
        job.selectedFormatIDs = ["18"]
        let descriptor = try StreamTransferDescriptor(sessionIdentifier: "tests.restore", taskIdentifier: 1,
            jobID: job.id, streamID: "18", destination: .init(root: .temporary,
                relativePath: "Illucet-\(job.id)/18.mp4"))
        let downloader = CoordinatorRestorationDownloader(registrations: [StreamTransferRegistration(
            descriptor: descriptor, state: .running, bytesReceived: 10, totalBytesExpected: 100)])
        let controller = DownloadRestorationController(downloader: downloader)
        _ = await controller.restore([job], continuingJobIDs: [job.id])
        #expect(await downloader.pausedJobIDs == (paused ? [job.id] : []))
        if !paused {
            _ = await controller.restore([job], continuingJobIDs: [])
            #expect(await downloader.pausedJobIDs == [job.id])
        }
    }

    @Test
    func restoringBatchedRangesCountsTheSharedBaselineAndTotalOnce() async throws {
        var job = Self.restoredJob(state: .paused, title: "Batched range restoration")
        job.selectedFormatIDs = ["137"]
        job.progress = .zero
        let roots = StreamTransferDestinationRoots.live(fileManager: .default)
        let destination = roots.temporaryDirectory.appending(path: "Illucet-\(job.id)/137.mp4")
        let chunk = StreamRangePlan.minimumChunkBytes
        let total = chunk * 3
        let staging = StreamRangeStaging.directory(for: destination, role: .video, totalBytes: total)
        var registrations: [StreamTransferRegistration] = []
        for index in 1...2 {
            let range = StreamByteRange(start: Int64(index) * chunk, end: Int64(index + 1) * chunk - 1)
            let descriptor = try StreamTransferDescriptor(sessionIdentifier: "tests.restore.batch", taskIdentifier: index,
                jobID: job.id, streamID: "137", destination: roots.identity(for: destination), mediaRole: .video,
                expectedTotalBytes: total, byteRange: range, rangeChunkBytes: chunk,
                stagingDestination: roots.identity(for: StreamRangeStaging.chunkURL(in: staging, range: range)))
            let network = Int64(index * 10)
            registrations.append(StreamTransferRegistration(descriptor: descriptor, state: .running,
                bytesReceived: chunk + network, totalBytesExpected: total,
                verifiedReusableBytes: chunk, networkBytesReceived: network))
        }
        let downloader = CoordinatorRestorationDownloader(registrations: registrations)
        let result = try #require(await DownloadRestorationController(downloader: downloader).restore([job]).first)
        #expect(result.progress.bytesDownloaded == chunk + 30)
        #expect(result.progress.verifiedReusableBytes == chunk)
        #expect(result.progress.totalBytes == total)
    }

    @Test
    func forbiddenTransferReanalyzesAndReresolvesBeforeRetry()
        async throws
    {
        let extractor = CoordinatorScriptedExtractor(
            results: [
                .success(DeveloperFixtures.media),
                .success(DeveloperFixtures.media),
            ]
        )
        let resolver = CoordinatorCountingResolver()
        let downloader = CoordinatorScriptedDownloader(
            failures: [
                .forbiddenHTTPFailure(statusCode: 403),
            ]
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: extractor,
            resolver: resolver,
            downloader: downloader
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 2
        await harness.configure(settings)
        let job = try await harness.enqueue()

        try await waitUntil {
            harness.recorder.jobs(job.id).contains {
                $0.state == .completed
            }
        }

        #expect(extractor.callCount == 2)
        #expect(resolver.callCount == 2)
        #expect(await downloader.callCount == 2)
        #expect(
            harness.recorder.jobs(job.id).contains {
                $0.state == .waitingForRetry
                    && $0.lastRetryReason == .mediaAccessForbidden
            }
        )
    }

    @Test
    func exhaustedForbiddenTransferKeepsSafeTerminalIdentity()
        async throws
    {
        let extractor = CoordinatorScriptedExtractor(
            results: Array(
                repeating: .success(DeveloperFixtures.media),
                count: 3
            )
        )
        let resolver = CoordinatorCountingResolver()
        let downloader = CoordinatorScriptedDownloader(
            failures: Array(
                repeating: .forbiddenHTTPFailure(statusCode: 403),
                count: 3
            )
        )
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: extractor,
            resolver: resolver,
            downloader: downloader
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.automaticRetryCount = 2
        await harness.configure(settings)
        let job = try await harness.enqueue()

        try await waitUntil {
            harness.recorder.jobs(job.id).contains { $0.state == .failed }
        }
        let terminal = try #require(
            harness.recorder.jobs(job.id).last { $0.state == .failed }
        )
        #expect(terminal.errorCode == "http_403_forbidden")
        #expect(
            terminal.errorMessage
                == "The media server denied access to the selected stream (HTTP 403)."
        )
        #expect(terminal.errorCode != "unknown_internal_error")
        #expect(extractor.callCount == 3)
        #expect(resolver.callCount == 3)
        #expect(await downloader.callCount == 3)

        let entries = await harness.diagnostics.allEntries()
        let retryEntries = entries.filter {
            $0.event == "automatic_retry_scheduled"
        }
        #expect(retryEntries.count == 2)
        #expect(
            retryEntries.allSatisfy {
                $0.detail?.contains("reason=mediaAccessForbidden") == true
            }
        )
        let terminalEntry = try #require(
            entries.first { $0.event == "job_failed" }
        )
        #expect(
            terminalEntry.detail?.contains("code=http_403_forbidden") == true
        )
        #expect(terminalEntry.detail?.contains("http://") == false)
        #expect(terminalEntry.detail?.contains("https://") == false)
        #expect(
            terminalEntry.detail?
                .localizedCaseInsensitiveContains("token") == false
        )
    }

    @Test
    func publicationWriteFailurePreventsTheExternalSave() async throws {
        let journal = CoordinatorPublicationJournal(failure: .beforeEffect)
        defer { journal.removeFiles() }
        let photos = CoordinatorPublicationPhotos()
        let background = CoordinatorBackgroundContinuation()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: photos, processingContinuation: background,
            publicationWriter: { try await journal.save($0) })
        defer { harness.finish() }
        await harness.configure()
        var config = Self.configuration; config.destination = .photos
        let queued = try await harness.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        #expect(await photos.calls == 0)
        #expect(await harness.coordinator.currentJob(queued.id)?.state == .failed)
        #expect(harness.temporaryRootExists(jobID: queued.id))
        let saved = try await journal.loadJob()
        #expect(saved.pipelineCheckpoint?.publicationPlan != nil)
        #expect(saved.pipelineCheckpoint?.publicationReceipts?.allSatisfy { $0.state == .notStarted } == true)
    }

    @Test
    func retryPhotosAfterRelaunchKeepsTheCommittedFilesCopy() async throws {
        let journal = CoordinatorPublicationJournal()
        defer { journal.removeFiles() }
        let photos = CoordinatorPublicationPhotos(denyFirst: true)
        let background = CoordinatorBackgroundContinuation()
        let first = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: photos, processingContinuation: background,
            publicationWriter: { try await journal.save($0) })
        defer { first.finish() }
        await first.configure(folderBookmark: try await first.filesBookmark())
        var config = Self.configuration; config.destination = .filesAndPhotos
        config.filenameTemplate = "Named export"
        let queued = try await first.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        let failed = try await journal.loadJob()
        #expect(failed.state == .failed)
        let originalURL = try #require(failed.outputURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let record = try #require(first.recorder.history(queued.id).last)
        #expect(record.publicationReceipts?.first { $0.destination == .files }?.state == .committed)
        #expect(record.publicationReceipts?.first { $0.destination == .photos }?.failureCode == "photos_permission_denied")
        let extractor = CoordinatorScriptedExtractor(results: [])
        let second = try CoordinatorHarness(network: .unavailable, extractor: extractor,
            photoLibrary: photos, publicationWriter: { try await journal.save($0) })
        defer { second.finish() }
        await second.configure()
        await second.coordinator.restore([failed])
        await second.coordinator.retry(queued.id)
        try await waitUntil { await second.coordinator.currentJob(queued.id)?.state == .completed }
        #expect(await second.coordinator.currentJob(queued.id)?.outputURL == originalURL)
        #expect(try Data(contentsOf: originalURL) == originalBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: originalURL.deletingLastPathComponent().path).count == 1)
        #expect(await photos.calls == 2)
        #expect(await photos.names == ["Named export.mp4", "Named export.mp4"])
        #expect(extractor.callCount == 0)
    }

    @Test
    func lostPhotosAcknowledgementRestoresAsUnknownAndCannotReplay() async throws {
        let journal = CoordinatorPublicationJournal(failure: .afterPhotos)
        defer { journal.removeFiles() }
        let photos = CoordinatorPublicationPhotos()
        let background = CoordinatorBackgroundContinuation()
        let first = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: photos, processingContinuation: background,
            publicationWriter: { try await journal.save($0) })
        defer { first.finish() }
        await first.configure()
        var config = Self.configuration; config.destination = .photos
        let queued = try await first.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        let saved = try await journal.loadJob()
        #expect(saved.pipelineCheckpoint?.publicationReceipts?.first?.state == .committing)
        #expect(await photos.calls == 1)
        let second = try CoordinatorHarness(network: .unavailable,
            extractor: CoordinatorScriptedExtractor(results: []), photoLibrary: photos)
        defer { second.finish() }
        await second.configure()
        await second.coordinator.restore([saved])
        await second.coordinator.retry(queued.id)
        let restored = await second.coordinator.currentJob(queued.id)
        #expect(restored?.state == .needsAttention)
        #expect(restored?.errorCode == "export_outcome_unknown")
        #expect(restored?.hasUnknownPublication == true)
        #expect(await photos.calls == 1)
    }

    @Test
    func finalSnapshotFailureRetriesCompletionWithoutSavingPhotosAgain() async throws {
        let journal = CoordinatorPublicationJournal(failure: .completion)
        defer { journal.removeFiles() }
        let photos = CoordinatorPublicationPhotos()
        let background = CoordinatorBackgroundContinuation()
        let first = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: photos, processingContinuation: background,
            publicationWriter: { try await journal.save($0) })
        defer { first.finish() }
        await first.configure()
        var config = Self.configuration; config.destination = .photos
        let queued = try await first.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        let saved = try await journal.loadJob()
        #expect(saved.pipelineCheckpoint?.publicationReceipts?.first?.state == .committed)
        #expect(first.temporaryRootExists(jobID: queued.id))
        await journal.unblock()
        let extractor = CoordinatorScriptedExtractor(results: [])
        let second = try CoordinatorHarness(network: .unavailable, extractor: extractor,
            photoLibrary: photos, publicationWriter: { try await journal.save($0) })
        defer { second.finish() }
        await second.configure()
        await second.coordinator.restore([saved])
        try await waitUntil { await second.coordinator.currentJob(queued.id)?.state == .completed }
        #expect(await photos.calls == 1)
        #expect(extractor.callCount == 0)
        #expect(try await journal.loadJob().state == .completed)
    }

    @Test
    func shareCleanupWaitsForTheOutcomePersistenceAcknowledgement() async throws {
        let background = CoordinatorBackgroundContinuation()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        var config = Self.configuration; config.destination = .share
        let queued = try await harness.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        let staged = try #require(await harness.coordinator.currentJob(queued.id)?.outputURL)
        await harness.coordinator.shareDidFinish(jobID: queued.id, state: .completed)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(await harness.coordinator.currentJob(queued.id)?.shareCompletionState == .completed)
        await harness.coordinator.shareDidFinish(jobID: queued.id, state: .cancelled)
        #expect(await harness.coordinator.currentJob(queued.id)?.shareCompletionState == .completed)
        await harness.coordinator.acknowledgeSharePersistence(jobID: queued.id, state: .completed)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test
    func photoImportWithUncertainResultCannotBeRepeated() async throws {
        let photos = CoordinatorUncertainPhotoLibrary()
        let background = CoordinatorBackgroundContinuation()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: photos, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        var config = Self.configuration; config.destination = .photos
        let queued = try await harness.enqueue(configuration: config)
        try await waitUntil { await background.success != nil }
        #expect(await harness.coordinator.currentJob(queued.id)?.hasUnknownPublication == true)
        #expect(await harness.coordinator.currentJob(queued.id)?.errorCode == "export_outcome_unknown")
        #expect(await harness.coordinator.currentJob(queued.id)?.errorMessage == ExportPublicationError.outcomeUnknown.localizedDescription)
        await harness.coordinator.retry(queued.id)
        #expect(await photos.calls == 1)
        #expect(await harness.coordinator.currentJob(queued.id)?.state == .failed)
    }

    @Test
    func restoredExportEvidenceDoesNotReplayCompletedPublication() async throws {
        let harness = try CoordinatorHarness(network: .unavailable,
            extractor: CoordinatorScriptedExtractor(results: []))
        defer { harness.finish() }
        await harness.configure()
        var restored = DeveloperFixtures.sponsorBlockAppliedJob
        restored.state = .running
        restored.stage = .savingPhotos
        restored.exportOutcome = .photos
        restored.photosAssetLocalIdentifiers = ["existing-asset"]
        restored.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .complete)
        await harness.coordinator.restore([restored])
        let current = await harness.coordinator.currentJob(restored.id)
        #expect(current?.state == .completed)
        #expect(current?.stage == .complete)
        #expect(current?.photosAssetLocalIdentifiers == ["existing-asset"])
    }

    @Test
    func pauseAllHoldsPowerAndNetworkWaitersUntilExplicitResume() async throws {
        let harness = try CoordinatorHarness(network: .unavailable,
            extractor: CoordinatorScriptedExtractor(results: []))
        defer { harness.finish() }
        await harness.configure()
        let first = try await harness.enqueue()
        var power = Self.configuration; power.waitForCharging = true
        let second = try await harness.enqueue(configuration: power)
        await harness.coordinator.pauseAll()
        #expect(await harness.coordinator.currentJob(first.id)?.state == .paused)
        #expect(await harness.coordinator.currentJob(second.id)?.state == .paused)
        await harness.coordinator.updatePowerState(connected: true)
        #expect(await harness.coordinator.currentJob(second.id)?.state == .paused)
        await harness.coordinator.resumeAll()
        try await waitUntil { await harness.coordinator.currentJob(first.id)?.state == .waitingForNetwork }
        #expect(await harness.coordinator.currentJob(second.id)?.state != .running)
    }

    @Test
    func pauseAtVideoCompletionBlocksAudioUntilExplicitResume() async throws {
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 0)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false), downloader: downloader)
        defer { harness.finish() }
        await harness.configure()
        var config = Self.configuration
        config.selectedVideoFormatID = "137"
        config.selectedAudioFormatID = "140"
        let job = try await harness.enqueue(configuration: config)
        try await waitUntil { await downloader.callCount == 1 }
        await harness.coordinator.pause(job.id)
        await downloader.releaseAll()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await harness.coordinator.currentJob(job.id)?.state == .paused)
        #expect(await downloader.callCount == 1)
        await harness.coordinator.resume(job.id)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state.isTerminal == true }
        #expect(await downloader.callCount == 2)
        #expect(await harness.coordinator.currentJob(job.id)?.state == .completed)
    }

    @Test
    func nativeResumeWaitingForSlotRetainsBytesAndCanBePausedAgain() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media), .success(DeveloperFixtures.media)]),
            downloader: downloader, transferPermits: pool)
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.maximumSimultaneousDownloads = 1
        await harness.configure(settings)
        let first = try await harness.enqueue()
        try await waitUntil { await downloader.callCount == 1 }
        try await waitUntil { await harness.coordinator.currentJob(first.id)?.progress.bytesDownloaded == 4 }
        await harness.coordinator.pause(first.id)
        let second = try await harness.enqueue()
        try await waitUntil { await downloader.callCount == 2 }
        let resuming = Task { await harness.coordinator.resume(first.id) }
        try await waitUntil { await pool.snapshot().waitingCount == 1 }
        let waiting = try #require(await harness.coordinator.currentJob(first.id))
        #expect(waiting.isWaitingForTransferSlot)
        #expect(waiting.progress.bytesDownloaded == 4)
        await harness.coordinator.prioritize(first.id)
        await harness.coordinator.pause(first.id)
        await resuming.value
        #expect(await harness.coordinator.currentJob(first.id)?.state == .paused)
        #expect(await pool.snapshot().waitingCount == 0)
        #expect(await pool.snapshot().activeCount == 1)
        await harness.coordinator.cancel(first.id)
        await harness.coordinator.cancel(second.id)
        try await waitUntil { await pool.snapshot().activeCount == 0 }
        #expect(await downloader.callCount == 2)
    }

    @Test
    func resumeAllQueuesEveryPausedNativeTransferBeforeAnySlotIsAvailable() async throws {
        let pool = AsyncPermitPool(limit: 3)
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            downloader: downloader, transferPermits: pool)
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.maximumSimultaneousDownloads = 3
        await harness.configure(settings)
        for _ in 0..<3 { _ = try await harness.enqueue() }
        try await waitUntil { await downloader.callCount == 3 }
        await harness.coordinator.pauseAll()
        settings.maximumSimultaneousDownloads = 1
        await harness.configure(settings)
        let holder = try await pool.acquire()
        let resuming = Task { await harness.coordinator.resumeAll() }
        try await waitUntil { await pool.snapshot().waitingCount == 3 }
        #expect(await harness.coordinator.currentJobs().allSatisfy(\.isWaitingForTransferSlot))
        await harness.coordinator.cancelAll()
        await pool.release(holder)
        await resuming.value
        #expect(await pool.snapshot().activeCount == 0)
        #expect(await pool.snapshot().waitingCount == 0)
    }

    @Test(arguments: [false, true])
    func restorationSeparatesUserPauseFromNativeReconciliationPause(manuallyPaused: Bool) async throws {
        let pool = AsyncPermitPool(limit: 1)
        let holder = try await pool.acquire()
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 1, admissionPaused: true)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            downloader: downloader, transferPermits: pool)
        defer { harness.finish() }
        var settings = AppSettings.defaults
        settings.maximumSimultaneousDownloads = 1
        await harness.configure(settings)
        var job = Self.restoredJob(state: manuallyPaused ? .paused : .running, title: "Restored pause")
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .transferring)
        let jobID = job.id
        await harness.coordinator.restore([job])
        if manuallyPaused {
            #expect(await harness.coordinator.currentJob(job.id)?.state == .paused)
            await harness.coordinator.resumeForegroundJobs()
            #expect(await harness.coordinator.currentJob(job.id)?.state == .paused)
            await harness.coordinator.resume(job.id)
        }
        try await waitUntil { await pool.snapshot().waitingCount == 1 }
        #expect(await downloader.callCount == 0)
        await pool.release(holder)
        await downloader.releaseAll()
        try await waitUntil { await harness.coordinator.currentJob(jobID)?.state.isTerminal == true }
        #expect(await harness.coordinator.currentJob(jobID)?.state == .completed)
        #expect(await downloader.callCount == 1)
    }

    @Test
    func completionIsCommittedBeforeNotificationDeliveryFinishes() async throws {
        let delivery = CoordinatorCompletionDeliveryGate()
        let background = CoordinatorBackgroundContinuation()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            processingContinuation: background,
            notifications: UserNotificationService(deliver: { message in
                if message.title == "Download complete" { await delivery.wait() }
            })
        )
        defer { harness.finish() }
        await harness.configure(notifyDownloadComplete: true)
        let queued = try await harness.enqueue()
        do {
            try await waitUntil { await delivery.isWaiting }
            try await waitUntil { harness.recorder.history(queued.id).count == 1 }
            let current = await harness.coordinator.currentJob(queued.id)
            #expect(current?.state == .completed)
            #expect(current?.stage == .complete)
            #expect(current?.pipelineCheckpoint?.phase == .complete)
            #expect(current?.outputURL != nil)
            #expect(harness.recorder.jobs(queued.id).last?.state == .completed)
            #expect(harness.recorder.history(queued.id).first?.status == .completed)
            // A slow notification must not leave a cancellable/running job behind.
            await harness.coordinator.cancel(queued.id)
            #expect(await harness.coordinator.currentJob(queued.id)?.state == .completed)
            await harness.coordinator.removeTerminalJobs([queued.id])
        } catch {
            await delivery.release()
            throw error
        }
        await delivery.release()
        try await waitUntil { await background.success != nil }
        #expect(await harness.coordinator.currentJob(queued.id) == nil)
        #expect(harness.recorder.history(queued.id).count == 1)
    }

    @Test
    func cancelledExportIgnoresLatePhotoCompletion() async throws {
        let delivery = CoordinatorCompletionDeliveryGate()
        let background = CoordinatorBackgroundContinuation()
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            photoLibrary: CoordinatorDelayedPhotoLibrary(delivery: delivery),
            processingContinuation: background
        )
        defer { harness.finish() }
        await harness.configure()
        var configuration = Self.configuration
        configuration.destination = .photos
        let queued = try await harness.enqueue(configuration: configuration)
        do {
            try await waitUntil { await delivery.isWaiting }
            await harness.coordinator.cancel(queued.id)
            #expect(await harness.coordinator.currentJob(queued.id)?.state == .cancelled)
        } catch {
            await delivery.release()
            throw error
        }
        await delivery.release()
        try await waitUntil { await background.success != nil }
        #expect(await harness.coordinator.currentJob(queued.id)?.state == .cancelled)
        #expect(harness.recorder.history(queued.id).isEmpty)
        #expect(!harness.recorder.jobs(queued.id).contains { $0.state == .completed })
    }

    @Test
    func backgroundPlaybackDefersWithoutFailureAndRetryReusesProcessedFile() async throws {
        let processor = CoordinatorMediaProcessor()
        let playback = CoordinatorForegroundPlaybackVerifier()
        let permits = AsyncPermitPool(limit: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media), .success(DeveloperFixtures.media)]),
            processor: processor, playbackVerifier: playback, processingPermits: permits)
        defer { harness.finish() }
        await harness.configure()
        let queued = try await harness.enqueue()
        try await waitUntil { harness.recorder.jobs(queued.id).contains { $0.state == .needsAttention } }
        let deferred = try #require(await harness.coordinator.currentJob(queued.id))
        #expect(deferred.errorCode == "playback_requires_foreground")
        #expect(deferred.pipelineCheckpoint?.phase == .awaitingPlaybackVerification)
        let retained = try #require(deferred.pipelineCheckpoint?.processedFileURL)
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(deferred.outputURL == nil)
        #expect(harness.recorder.history(queued.id).isEmpty)
        #expect(!harness.recorder.jobs(queued.id).contains { $0.state == .failed })
        try await waitUntil { await permits.snapshot().activeCount == 0 }
        let processingCount = await processor.verificationSnapshot().processes.count
        await playback.allowPlayback()
        await harness.coordinator.resumeForegroundJobs()
        await harness.coordinator.resumeForegroundJobs()
        try await waitUntil { harness.recorder.jobs(queued.id).contains { $0.state.isTerminal } }
        let completed = try #require(await harness.coordinator.currentJob(queued.id))
        #expect(completed.state == .completed, "\(completed.errorMessage ?? "")")
        #expect(await processor.verificationSnapshot().processes.count == processingCount)
        #expect(await playback.calls == 2)
    }

    @Test
    func deniedBackgroundGrantWaitsWithoutProcessingAndResumesOnce() async throws {
        let background = CoordinatorBackgroundContinuation()
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 0)
        let processor = CoordinatorMediaProcessor()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media), .success(DeveloperFixtures.media)]),
            downloader: downloader, processor: processor, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        let queued = try await harness.enqueue()
        try await waitUntil { await downloader.callCount == 1 }
        await background.setAllowed(false)
        await downloader.releaseAll()
        try await waitUntil { await harness.coordinator.currentJob(queued.id)?.resumesOnForeground == true }
        let stopped = try #require(await harness.coordinator.currentJob(queued.id))
        #expect(stopped.foregroundResumeReason == .processingTime)
        #expect(stopped.pipelineCheckpoint?.sourceFiles.isEmpty == false)
        #expect(await processor.verificationSnapshot().processes.isEmpty)
        await background.setAllowed(true)
        await harness.coordinator.resumeForegroundJobs()
        await harness.coordinator.resumeForegroundJobs()
        try await waitUntil { await harness.coordinator.currentJob(queued.id)?.state == .completed }
        #expect(await harness.coordinator.currentJob(queued.id)?.foregroundResumeReason == nil)
        try await waitUntil { harness.recorder.history(queued.id).count == 1 }
        #expect(harness.recorder.history(queued.id).count == 1)
    }

    @Test
    func foregroundDuringOldAttemptFinishWaitsForTeardownThenResumesOnce() async throws {
        let background = CoordinatorBackgroundContinuation()
        await background.setAllowed(false)
        await background.holdNextFinish()
        let downloader = CoordinatorScriptedDownloader(failures: [])
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            downloader: downloader, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue()
        try await waitUntil { await background.finishIsWaiting }
        await background.setAllowed(true)
        await harness.coordinator.resumeForegroundJobs()
        await harness.coordinator.resumeForegroundJobs()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await background.beginCount == 1)
        await background.releaseFinish()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        try await waitUntil { !harness.recorder.history(job.id).isEmpty }
        #expect(await downloader.callCount == 1)
        #expect(harness.recorder.history(job.id).count == 1)
    }

    @Test
    func pendingBackgroundGrantWaitsWithoutHoldingProcessingPermit() async throws {
        let background = CoordinatorPendingContinuation()
        let downloader = CoordinatorPauseBoundaryDownloader(nativeTaskCount: 0)
        let processing = AsyncPermitPool(limit: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            downloader: downloader, processingPermits: processing, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue()
        try await waitUntil { await downloader.callCount == 1 }
        await background.setAllowed(false)
        await downloader.releaseAll()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.stage.rawValue == "Waiting for background time" }
        #expect(await harness.coordinator.currentJob(job.id)?.state == .running)
        #expect(await processing.snapshot().activeCount == 0)
        await background.setAllowed(true)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        #expect(await downloader.callCount == 1)
        #expect(await background.attempts.count == 1)
    }

    @Test
    func interruptedSponsorBlockResumesFromVerifiedAssembly() async throws {
        var newerFields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(DeveloperFixtures.media)) as? [String: Any])
        var newerFormats = try #require(newerFields["formats"] as? [[String: Any]])
        for index in newerFormats.indices where newerFormats[index]["format_id"] as? String == "137" {
            newerFormats[index]["width"] = 640
            newerFormats[index]["height"] = 360
            newerFormats[index]["frames_per_second"] = 60
        }
        newerFields["formats"] = newerFormats
        let newerMetadata = try JSONDecoder().decode(MediaMetadata.self,
            from: JSONSerialization.data(withJSONObject: newerFields))
        for scenario in ["queued", "expired", "missing-base"] {
            let queuedGrant = scenario != "expired"
            let pending = CoordinatorPendingContinuation()
            let expiring = CoordinatorBackgroundContinuation()
            let controller: any ContinuedProcessingControlling = queuedGrant ? pending : expiring
            let processor = CoordinatorInterruptedEditProcessor()
            let downloader = CoordinatorScriptedDownloader(failures: [])
            let harness = try CoordinatorHarness(network: .fixtureWiFi,
                extractor: CoordinatorScriptedExtractor(results: [
                    .success(DeveloperFixtures.media), .success(newerMetadata)
                ]), downloader: downloader, processor: processor, processingContinuation: controller)
            defer { harness.finish() }
            await harness.configure()
            var config = Self.configuration
            config.maximumResolution = 360
            config.preserveSourceResolution = false
            config.formatSelectionProvenance = .automatic
            var policy = SponsorBlockPolicy(isEnabled: true, selectedCategories: [.sponsor])
            let duration = try #require(DeveloperFixtures.media.durationSeconds)
            policy.setAction(.remove, for: .sponsor)
            policy.removalMode = .fastKeyframe
            policy.replaceSelection(videoID: DeveloperFixtures.media.videoID,
                queriedCategories: policy.requestedDiscoveryCategories,
                segments: [.init(segmentID: "interrupted-edit", category: .sponsor,
                    startSeconds: 1, endSeconds: 2, description: nil,
                    submittedVideoDuration: duration,
                    serverAction: .skip, votes: 1, isLocked: false)])
            config.sponsorBlock = policy
            let job = try await harness.enqueue(configuration: config)
            try await waitUntil { await processor.editStarts == 1 }
            let checkpoint = try #require(await harness.coordinator.currentJob(job.id)?.pipelineCheckpoint)
            let base = try #require(checkpoint.baseProcessedFileURL)
            #expect(FileManager.default.fileExists(atPath: base.path))
            if queuedGrant {
                await pending.setAllowed(false)
                await harness.coordinator.applicationDidEnterBackground()
                try await waitUntil { await harness.coordinator.currentJob(job.id)?.stage == .waitingForBackgroundTime }
            } else {
                await expiring.expire()
                try await waitUntil { await harness.coordinator.currentJob(job.id)?.resumesOnForeground == true }
            }
            #expect(FileManager.default.fileExists(atPath: base.path))
            #expect(harness.recorder.history(job.id).isEmpty)
            if scenario == "missing-base" { try FileManager.default.removeItem(at: base) }
            await processor.allowEdits()
            if queuedGrant { await pending.setAllowed(true) }
            else { await expiring.setAllowed(true); await harness.coordinator.resumeForegroundJobs() }
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state.isTerminal == true }
            let completed = try #require(await harness.coordinator.currentJob(job.id))
            #expect(completed.state == .completed, "\(completed.errorCode ?? "none"): \(completed.errorMessage ?? "none")")
            #expect(completed.sponsorBlockApplication?.status == .applied)
            #expect(completed.selectedFormatIDs == ["18"])
            #expect(await processor.assemblyCount == (scenario == "missing-base" ? 2 : 1))
            #expect(await processor.editStarts == 2)
            #expect(await downloader.callCount == 1)
            // Authoritative state can finish before this AsyncStream observer
            // consumes addHistory. Await delivery, then retain the exact-once check.
            try await waitUntil { !harness.recorder.history(job.id).isEmpty }
            #expect(harness.recorder.history(job.id).count == 1)
        }
    }

    @Test
    func losingForegroundDuringCPUWorkWaitsForQueuedGrantInSameAttempt() async throws {
        let background = CoordinatorPendingContinuation()
        let processor = CoordinatorBlockingMediaProcessor()
        let downloader = CoordinatorScriptedDownloader(failures: [])
        let processing = AsyncPermitPool(limit: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            downloader: downloader, processor: processor, processingPermits: processing, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue()
        try await waitUntil { await processor.maximumConcurrentProbes == 1 }
        await background.setAllowed(false)
        await harness.coordinator.applicationDidEnterBackground()
        do {
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.stage == .waitingForBackgroundTime }
        } catch {
            let current = await harness.coordinator.currentJob(job.id)
            Issue.record("Grant wait missing: \(String(describing: current?.state)) / \(String(describing: current?.stage)) / \(current?.errorCode ?? "none")")
            throw error
        }
        #expect(await processing.snapshot().activeCount == 0)
        // Interrupt source verification again after it reuses the checkpoint.
        await background.setAllowed(true)
        try await waitUntil { await processor.probeCount == 2 }
        await background.setAllowed(false)
        await harness.coordinator.applicationDidEnterBackground()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.stage == .waitingForBackgroundTime }
        let sources = try #require(await harness.coordinator.currentJob(job.id)?.pipelineCheckpoint?.sourceFiles)
        #expect(!sources.isEmpty)
        #expect(sources.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await processor.allowProbes()
        await background.setAllowed(true)
        do {
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        } catch {
            let current = await harness.coordinator.currentJob(job.id)
            Issue.record("Grant recovery incomplete: \(String(describing: current?.state)) / \(String(describing: current?.stage)) / \(current?.errorCode ?? "none")")
            throw error
        }
        #expect(await background.attempts.count == 1)
        #expect(await downloader.callCount == 1)
    }

    @Test
    func foregroundRecoveryIsBoundedToOneRetryPerActivation() async throws {
        let playback = CoordinatorForegroundPlaybackVerifier()
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]), playbackVerifier: playback)
        defer { harness.finish() }
        await harness.configure()
        let job = try await harness.enqueue()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.resumesOnForeground == true }
        await harness.coordinator.resumeForegroundJobs()
        try await waitUntil { await playback.calls == 2 }
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.resumesOnForeground == true }
        await harness.coordinator.resumeForegroundJobs()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await playback.calls == 2)
        await playback.allowPlayback()
        await harness.coordinator.setForegroundEligibility(false, revision: 1)
        await harness.coordinator.setForegroundEligibility(true, revision: 2)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        #expect(await playback.calls == 3)
    }

    @Test(arguments: ["acknowledged", "timeout", "cancelled"])
    func stalledTransferWaitsForAcknowledgementAndPreservesCompletedVideo(scenario: String) async throws {
        let clock = CoordinatorTransferClock()
        let downloader = CoordinatorRecoveryDownloader(holdCancellation: true)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false), downloader: downloader,
            transferClock: { clock.now })
        defer { harness.finish() }
        await harness.configure()
        await harness.coordinator.setForegroundEligibility(true, revision: 1)
        var config = Self.configuration
        config.selectedVideoFormatID = "137"; config.selectedAudioFormatID = "140"
        let job = try await harness.enqueue(configuration: config)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.progress.instantaneousBytesPerSecond == 2 }
        clock.advance(91)
        await harness.coordinator.checkTransferLiveness()
        try await waitUntil { await downloader.cancellationWaiting }
        #expect(await harness.coordinator.currentJob(job.id)?.isAwaitingTransferCleanup == true)
        await harness.coordinator.retry(job.id)
        #expect(await downloader.audioCalls == 1)
        if scenario == "timeout" {
            clock.advance(16)
            await harness.coordinator.checkTransferLiveness()
        }
        let cancellation: Task<Void, Never>? = scenario == "cancelled" ? Task { await harness.coordinator.cancel(job.id) } : nil
        if cancellation != nil {
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .cancelled }
            await harness.coordinator.clearCompleted()
            #expect(await harness.coordinator.currentJob(job.id) != nil)
        }
        await downloader.releaseCancellation()
        if let cancellation {
            await cancellation.value
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.isAwaitingTransferCleanup == false }
            #expect(await harness.coordinator.currentJob(job.id)?.state == .cancelled)
            #expect(await downloader.audioCalls == 1)
        } else {
            if scenario == "timeout" {
                try await waitUntil { await harness.coordinator.currentJob(job.id)?.errorCode == "transfer_stalled" }
                #expect(await downloader.audioCalls == 1)
                await harness.coordinator.retry(job.id)
            }
            try await waitUntil { await downloader.audioCalls == 2 }
            await downloader.finishAudio()
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
            #expect(await downloader.videoCalls == 1)
        }
    }

    @Test
    func stalledTransferStopsAfterTwoRecoveriesAndManualRetryStartsNewBudget() async throws {
        let clock = CoordinatorTransferClock()
        let downloader = CoordinatorRecoveryDownloader(holdCancellation: false)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false), downloader: downloader,
            transferClock: { clock.now })
        defer { harness.finish() }
        await harness.configure()
        await harness.coordinator.setForegroundEligibility(true, revision: 1)
        var config = Self.configuration
        config.selectedVideoFormatID = "137"; config.selectedAudioFormatID = "140"
        let job = try await harness.enqueue(configuration: config)
        for attempt in 1...3 {
            try await waitUntil { await downloader.audioCalls == attempt }
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.progress.instantaneousBytesPerSecond == Double(attempt + 1) }
            clock.advance(91)
            await harness.coordinator.checkTransferLiveness()
        }
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.errorCode == "transfer_stalled" }
        #expect(await harness.coordinator.currentJob(job.id)?.transferRecoveryCount == 2)
        #expect(await downloader.audioCalls == 3)
        await downloader.finishAudio()
        await harness.coordinator.retry(job.id)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        #expect(await harness.coordinator.currentJob(job.id)?.transferRecoveryCount == nil)
        #expect(await downloader.videoCalls == 1)
    }

    @Test
    func olderSceneHandoffCannotRestoreBackgroundPacingAfterActivation() async throws {
        let downloader = CoordinatorRecoveryDownloader(holdCancellation: false)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: []), downloader: downloader)
        defer { harness.finish() }
        await harness.configure()
        await downloader.holdNextForegroundChange(false)
        let oldCallback = Task { await harness.coordinator.setForegroundEligibility(false, revision: 1) }
        try await waitUntil { await downloader.foregroundChangeWaiting }
        await harness.coordinator.setForegroundEligibility(true, revision: 2)
        await downloader.releaseForegroundChange()
        await oldCallback.value
        #expect(await downloader.foregroundActive)
        await harness.coordinator.setForegroundEligibility(false, revision: 1)
        #expect(await downloader.foregroundActive)
    }

    @Test(arguments: ["background", "pause", "offline"])
    func livenessDoesNotChargeIneligibleTime(reason: String) async throws {
        let clock = CoordinatorTransferClock()
        let downloader = CoordinatorRecoveryDownloader(holdCancellation: false)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            resolver: CoordinatorRoleAwareResolver(exposesExactBytes: false), downloader: downloader,
            transferClock: { clock.now })
        defer { harness.finish() }
        await harness.configure()
        await harness.coordinator.setForegroundEligibility(true, revision: 1)
        var config = Self.configuration
        config.selectedVideoFormatID = "137"; config.selectedAudioFormatID = "140"
        let job = try await harness.enqueue(configuration: config)
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.progress.instantaneousBytesPerSecond == 2 }
        switch reason {
        case "background": await harness.coordinator.setForegroundEligibility(false, revision: 2)
        case "pause": await harness.coordinator.pause(job.id)
        default:
            harness.network.send(.unavailable)
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .waitingForNetwork }
        }
        clock.advance(600)
        await harness.coordinator.checkTransferLiveness()
        #expect(await harness.coordinator.currentJob(job.id)?.transferRecoveryCount == nil)
        switch reason {
        case "background": await harness.coordinator.setForegroundEligibility(true, revision: 3)
        case "pause": await harness.coordinator.resume(job.id)
        default:
            harness.network.send(.fixtureWiFi)
            try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .running }
        }
        clock.advance(89)
        await harness.coordinator.checkTransferLiveness()
        #expect(await harness.coordinator.currentJob(job.id)?.transferRecoveryCount == nil)
        await downloader.finishAudio()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.state == .completed }
        #expect(await downloader.audioCalls == 1)
    }

    @Test
    func admissionSnapshotFailureDoesNotStartExtractionOrTransfer() async throws {
        let extractor = CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)])
        let downloader = CoordinatorScriptedDownloader(failures: [])
        let harness = try CoordinatorHarness(network: .fixtureWiFi, extractor: extractor, downloader: downloader)
        defer { harness.finish() }
        await harness.configure()
        await harness.coordinator.setPublicationWriter { _ in throw NativeTransferCheckpointError.persistenceUnavailable }
        let job = try await harness.enqueue()
        try await waitUntil { await harness.coordinator.currentJob(job.id)?.errorCode == "state_save_failed" }
        #expect(extractor.callCount == 0)
        #expect(await downloader.callCount == 0)
        #expect(await harness.coordinator.currentJob(job.id)?.state == .needsAttention)
    }

    @Test
    func backgroundExpirationPreservesSourcesAndRequiresExplicitRetry() async throws {
        let background = CoordinatorBackgroundContinuation()
        let processor = CoordinatorBlockingMediaProcessor()
        let permits = AsyncPermitPool(limit: 1)
        let harness = try CoordinatorHarness(network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(results: [.success(DeveloperFixtures.media)]),
            processor: processor, processingPermits: permits, processingContinuation: background)
        defer { harness.finish() }
        await harness.configure()
        let queued = try await harness.enqueue()
        try await waitUntil { await processor.maximumConcurrentProbes == 1 }
        await background.expire()
        let jobs = await harness.coordinator.currentJobs()
        let stopped = try #require(jobs.first { $0.id == queued.id })
        #expect(stopped.state == .needsAttention)
        #expect(stopped.errorCode == "background_processing_expired")
        #expect(stopped.outputURL == nil)
        #expect(stopped.pipelineCheckpoint?.sourceFiles.isEmpty == false)
        for file in stopped.pipelineCheckpoint?.sourceFiles.values ?? [:].values {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(await permits.snapshot().activeCount == 0)
        #expect(await background.success == false)
    }

    @Test
    func processingUsesItsOwnPermitAndCannotBeMarkedPaused()
        async throws
    {
        let processor = CoordinatorBlockingMediaProcessor()
        let transferPermits = AsyncPermitPool(limit: 1)
        let processingPermits = AsyncPermitPool(limit: 1)
        let harness = try CoordinatorHarness(
            network: .fixtureWiFi,
            extractor: CoordinatorScriptedExtractor(
                results: [
                    .success(DeveloperFixtures.media),
                    .success(DeveloperFixtures.media),
                ]
            ),
            processor: processor,
            transferPermits: transferPermits,
            processingPermits: processingPermits
        )
        defer { harness.finish() }

        var settings = AppSettings.defaults
        settings.maximumSimultaneousDownloads = 1
        settings.maximumSimultaneousProcessingJobs = 1
        await harness.configure(settings)
        let first = try await harness.enqueue()
        let second = try await harness.enqueue()

        try await waitUntil {
            let snapshot = await processingPermits.snapshot()
            return snapshot.activeCount == 1
                && snapshot.waitingCount == 1
        }
        let transferSnapshot = await transferPermits.snapshot()
        #expect(transferSnapshot.activeCount == 0)
        #expect(transferSnapshot.waitingCount == 0)
        #expect(await processor.maximumConcurrentProbes == 1)

        let processingJobID = try #require(
            [first.id, second.id].first {
                harness.recorder.jobs($0).contains {
                    $0.stage == .verifyingSources
                }
            }
        )
        await harness.coordinator.pause(processingJobID)
        await Task.yield()

        #expect(
            !harness.recorder.jobs(processingJobID).contains {
                $0.state == .paused
            }
        )
        #expect(
            harness.recorder.jobs(processingJobID).contains {
                $0.state == .running
                    && $0.stage == .verifyingSources
            }
        )

        await harness.coordinator.cancelAll()
        try await waitUntil {
            let snapshot = await processingPermits.snapshot()
            return snapshot.activeCount == 0
                && snapshot.waitingCount == 0
        }
    }

    private static let permanentExtractionFailure =
        ExtractionError.extractorFailure(
            code: "private_video",
            message: "Unavailable.",
            retryable: false
        )

    private static func restoredJob(
        state: DownloadJobState,
        title: String
    ) -> DownloadJob {
        var configuration = Self.configuration
        configuration.filenameTemplate = title
        return DownloadJob(
            id: UUID(),
            sourceURL: DeveloperFixtures.media.canonicalURL,
            videoID: DeveloperFixtures.media.videoID,
            title: title,
            channel: DeveloperFixtures.media.channel,
            thumbnailURL: nil,
            createdAt: .now,
            updatedAt: .now,
            configuration: configuration,
            state: state,
            stage: .downloadingVideo,
            progress: .zero,
            priority: 0,
            retryCount: 0,
            maximumRetries: 2,
            errorCode: nil,
            errorMessage: nil,
            outputURL: nil,
            outputProbe: nil,
            selectedFormatIDs: configuration.selectedFormatIDs,
            extractorVersion: "fixture"
        )
    }

    fileprivate static var configuration: DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.mode = .videoAndAudio
        value.preset = .custom
        value.selectedVideoFormatID = "18"
        value.selectedAudioFormatID = nil
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.preserveChapters = false
        value.writeChapters = false
        value.bundleStyle = .mediaOnly
        value.destination = .appDocuments
        return OutputCapabilityMatrix.normalized(value)
    }

    private static var sidecarAndThumbnailConfiguration:
        DownloadConfiguration
    {
        var value = configuration
        value.filenameTemplate = "Fixture"
        value.thumbnailBehavior = .separate
        value.thumbnailFormat = .original
        value.subtitleDelivery = .sidecarVTT
        value.subtitleSelections = [
            SubtitleTrackSelection(
                trackID: "subtitle-111111111111111111111111",
                formatID: "subtitle-format-111111111111111111111111",
                language: "en",
                automatic: false
            ),
        ]
        return OutputCapabilityMatrix.normalized(value)
    }

    private func waitForNetworkRequest(
        jobID: UUID,
        recorder: CoordinatorEventRecorder
    ) async throws -> NetworkAccessRequest {
        try await waitUntil {
            recorder.networkRequest(jobID: jobID) != nil
        }
        return try #require(recorder.networkRequest(jobID: jobID))
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 2_000 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CoordinatorTestFailure.timeout
    }
}

private struct LiveDownloadFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private enum PDR1LiveTestGate {
    static var isEnabled: Bool {
        AuthorizedLiveTestConfigurationLoader.executionWasRequested()
            && (try? AuthorizedLiveTestConfigurationLoader.load()) != nil
    }
}

enum PDR1LiveSmokeMode: String, CaseIterable, Sendable {
    case videoAndAudio = "Video + Audio"
    case audioOnly = "Audio Only"
    case videoOnly = "Video Only"
    case thumbnailOnly = "Thumbnail Only"

    var configuration: DownloadConfiguration {
        var value = DownloadConfiguration.standard
        value.preset = .custom
        value.selectedVideoFormatID = nil
        value.selectedAudioFormatID = nil
        value.maximumResolution = 360
        value.preserveSourceResolution = false
        value.videoCodec = .automatic
        value.audioCodec = .automatic
        value.container = .automatic
        value.thumbnailBehavior = .none
        value.subtitleDelivery = .none
        value.preserveChapters = false
        value.writeChapters = false
        value.bundleStyle = .mediaOnly
        value.destination = .appDocuments
        value.filenameTemplate = switch self {
        case .videoAndAudio: "PD-R1-video-audio"
        case .audioOnly: "PD-R1-audio-only"
        case .videoOnly: "PD-R1-video-only"
        case .thumbnailOnly: "PD-R1-thumbnail-only"
        }

        switch self {
        case .videoAndAudio:
            value.mode = .videoAndAudio
        case .audioOnly:
            value.mode = .audioOnly
        case .videoOnly:
            value.mode = .videoOnly
        case .thumbnailOnly:
            value.thumbnailBehavior = .thumbnailOnly
            value.thumbnailFormat = .original
            value.cropArtworkSquare = false
        }
        return OutputCapabilityMatrix.normalized(value)
    }
}

private final class PDR1LiveCoordinatorHarness: @unchecked Sendable {
    private let rootURL: URL
    private let runtime = RuntimeEnvironment()
    private let coordinator: DownloadCoordinator
    private let recorder: CoordinatorEventRecorder
    private let startupTask: Task<Void, Never>

    init(processingContinuation: (any ContinuedProcessingControlling)? = nil) throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-PDR1Live-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let exporter = ExportManager(
            documentsRootURL: rootURL.appending(
                path: "Documents",
                directoryHint: .isDirectory
            ),
            shareRootURL: rootURL.appending(
                path: "Share",
                directoryHint: .isDirectory
            )
        )
        let benchmark = ProcessInfo.processInfo.environment["ILLUCET_DOWNLOAD_BENCHMARK"] == "1"
        let downloader = StreamDownloadService(
            sessionIdentifier: "com.local.illucet.pd-r1.\(UUID().uuidString)",
            hooks: benchmark ? StreamDownloadServiceHooks(beforeWaiterRegistration: nil, didFinishCollecting: { metrics in
                let safe: [String: Any] = [
                    "taskSeconds": metrics.taskInterval.duration,
                    "transactions": metrics.transactionMetrics.map { item -> [String: Any] in
                        func interval(_ start: Date?, _ end: Date?) -> Double {
                            guard let start, let end else { return 0 }
                            return end.timeIntervalSince(start)
                        }
                        return ["protocol": item.networkProtocolName ?? "unknown",
                            "connectionReused": item.isReusedConnection,
                            "beforeFetchSeconds": interval(metrics.taskInterval.start, item.fetchStartDate),
                            "connectSeconds": interval(item.connectStartDate, item.connectEndDate),
                            "responseWaitSeconds": interval(item.requestEndDate, item.responseStartDate),
                            "receiveSeconds": interval(item.responseStartDate, item.responseEndDate),
                            "responseBytes": item.countOfResponseBodyBytesReceived]
                    }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) {
                    print("ILLUCET_TRANSFER_TIMING " + String(decoding: data, as: UTF8.self))
                }
            }) : .none
        )
        let processor = NativeFFmpegMediaProcessor()
        let publicationWriter: @Sendable (DownloadJob) async throws -> Void = { [rootURL] job in
            let writer = IllucetPersistence(rootURL: rootURL.appending(path: "PublicationState"))
            var state = try await writer.load()
            state.jobs.removeAll { $0.id == job.id }
            state.jobs.append(job)
            try await writer.save(state)
        }
        let coordinator = DownloadCoordinator(
            runtime: runtime,
            downloader: downloader,
            DASHDownloader: downloader,
            DASHAssembler: DASHLocalStreamAssembler(mediaProcessor: processor),
            HLSDownloader: downloader,
            HLSAssembler: HLSLocalStreamAssembler(mediaProcessor: processor),
            mediaProcessor: processor,
            storage: StorageManager(),
            exporter: exporter,
            thumbnails: ThumbnailService(),
            diagnostics: DiagnosticStore(
                rootURL: rootURL.appending(
                    path: "Diagnostics",
                    directoryHint: .isDirectory
                )
            ),
            notifications: UserNotificationService(),
            networkMonitor: CoordinatorNetworkMonitor(.fixtureWiFi),
            processingContinuation: processingContinuation,
            publicationWriter: publicationWriter
        )
        self.coordinator = coordinator
        recorder = CoordinatorEventRecorder(coordinator.updates)
        startupTask = Task {
            // Match app startup: native task plans and receipts require a real
            // durable writer before restoration/transfer admission. This is a
            // foreground smoke test; OS background admission is separate proof.
            await coordinator.setPublicationWriter(publicationWriter)
            await coordinator.restore([])
            await coordinator.resumeForegroundJobs()
        }
    }

    func observations(_ jobID: UUID) -> [CoordinatorJobObservation] { recorder.jobObservations(jobID) }
    func verifiedAssemblies(_ jobID: UUID) -> Set<URL> {
        Set(recorder.jobs(jobID).compactMap { $0.pipelineCheckpoint?.baseProcessedFileURL })
    }

    func versions() async throws -> ExtractorVersions {
        let extractor = try await runtime.extractor()
        return try await extractor.versions()
    }

    func playlistAnalyzer() async throws -> YTDLPPlaylistAnalyzer { try await runtime.playlistAnalyzer() }

    func analyze(_ URL: URL) async throws -> MediaMetadata {
        await startupTask.value
        var settings = AppSettings.defaults
        settings.minimumFreeSpaceReserveBytes = 0
        settings.notifyDownloadComplete = false
        settings.notifyProcessingComplete = false
        settings.notifyFailure = false
        settings.notifyNeedsAttention = false
        settings.notifyLowStorage = false
        settings.liveActivities = false
        settings.automaticRetryCount = 0
        await coordinator.configure(settings: settings, folderBookmark: nil)

        let extractor = try await runtime.extractor()
        return try await extractor.analyze(url: URL)
    }

    func enqueue(
        metadata: MediaMetadata,
        configuration: DownloadConfiguration
    ) async throws -> DownloadJob {
        await startupTask.value
        return try await coordinator.enqueue(
            metadata: metadata,
            configuration: configuration,
            extractorVersion: "authorized-live"
        )
    }

    func waitForTerminalJob(_ jobID: UUID) async throws -> DownloadJob {
        for _ in 0 ..< 1_200 {
            if let terminal = recorder.jobs(jobID).last(where: {
                $0.state.isTerminal
            }) {
                return terminal
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CoordinatorTestFailure.timeout
    }

    /// Real public transfer/native editing; only OS grant timing is injected.
    func interruptSponsorBlockForProof(_ jobID: UUID,
        continuation: CoordinatorLiveContinuation) async throws -> URL {
        var reachedEdit = false
        for _ in 0..<120_000 {
            let current = await coordinator.currentJob(jobID)
            if current?.stage == .removingSponsorSegments, current?.state == .running {
                reachedEdit = true
                break
            }
            if current?.state.isTerminal == true {
                throw LiveDownloadFailure(message: current?.errorMessage ?? "The edit stage completed before interruption.")
            }
            if current?.state == .needsAttention {
                let status = await continuation.nativeStatus(jobID: jobID)
                throw LiveDownloadFailure(message: "Native recovery requires attention (\(status.state.rawValue), \(status.reason?.rawValue ?? "none")).")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reachedEdit else { throw CoordinatorTestFailure.timeout }
        let nativeStatus = await continuation.nativeStatus(jobID: jobID)
        #expect(nativeStatus.reason != .registrationRejected)
        print("ILLUCET_LIVE_RECOVERY native_scheduler_state=\(nativeStatus.state.rawValue) reason=\(nativeStatus.reason?.rawValue ?? "none")")
        await continuation.setAllowed(false)
        await coordinator.applicationDidEnterBackground()
        for _ in 0..<3_000 {
            let current = await coordinator.currentJob(jobID)
            if current?.stage == .waitingForBackgroundTime {
                let base = try #require(current?.pipelineCheckpoint?.baseProcessedFileURL)
                let values = try base.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                #expect(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0)
                print("ILLUCET_LIVE_RECOVERY interrupted_edit_checkpoint_retained=true")
                await continuation.setAllowed(true)
                return base
            }
            if current?.state.isTerminal == true {
                throw LiveDownloadFailure(message: current?.errorMessage ?? "The edit did not wait for its execution grant.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CoordinatorTestFailure.timeout
    }

    func shutdown() async {
        for job in await coordinator.currentJobs() where !job.state.isTerminal {
            await coordinator.cancel(job.id)
        }
        await runtime.shutdown()
    }

    func finish() {
        recorder.finish()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class CoordinatorHarness: @unchecked Sendable {
    let coordinator: DownloadCoordinator
    let network: CoordinatorNetworkMonitor
    let recorder: CoordinatorEventRecorder
    let exporter: ExportManager
    let diagnostics: DiagnosticStore
    let sponsorBlockDiagnostics: SponsorBlockDiagnosticLogger

    private let rootURL: URL

    init(
        network snapshot: NetworkPathSnapshot,
        extractor: CoordinatorScriptedExtractor,
        resolver: any StreamResolver = CoordinatorResolver(),
        downloader: any StreamDownloading = CoordinatorDownloader(),
        DASHResolver: (any DASHFragmentResolving)? = nil,
        DASHDownloader: (any DASHFragmentDownloading)? = nil,
        DASHAssembler: (any DASHLocalStreamAssembling)? = nil,
        HLSResolver: (any HLSPlaylistResolving)? = nil,
        HLSDownloader: (any HLSResourceDownloading)? = nil,
        HLSAssembler: (any HLSLocalStreamAssembling)? = nil,
        processor: any MediaProcessor = CoordinatorMediaProcessor(),
        playbackVerifier: any ApplePlaybackVerifying = CoordinatorPlaybackVerifier(),
        retrySleeper: @escaping DownloadRetrySleeper = { _ in },
        transferPermits: AsyncPermitPool? = nil,
        processingPermits: AsyncPermitPool? = nil,
        photoLibrary: any PhotoLibraryExporting = SystemPhotoLibraryExporter(),
        subtitleTransport: (any SubtitleTransporting)? = nil,
        expectedAccountID: UUID? = nil,
        processingContinuation: (any ContinuedProcessingControlling)? = nil,
        notifications: UserNotificationService = UserNotificationService(),
        publicationWriter: @escaping @Sendable (DownloadJob) async throws -> Void = { _ in },
        transferClock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "Illucet-DownloadCoordinatorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        network = CoordinatorNetworkMonitor(snapshot)
        let runtime = CoordinatorRuntime(
            extractor: extractor,
            resolver: resolver,
            DASHResolver: DASHResolver,
            HLSResolver: HLSResolver, expectedAccountID: expectedAccountID
        )
        let activeExporter = ExportManager(
            photoLibrary: photoLibrary,
            documentsRootURL: rootURL.appending(
                path: "Documents",
                directoryHint: .isDirectory
            ),
            shareRootURL: rootURL.appending(
                path: "Share",
                directoryHint: .isDirectory
            )
        )
        exporter = activeExporter
        let activeDiagnostics = DiagnosticStore(
            rootURL: rootURL.appending(
                path: "Diagnostics",
                directoryHint: .isDirectory
            )
        )
        diagnostics = activeDiagnostics
        let activeSponsorBlockDiagnostics = SponsorBlockDiagnosticLogger(
            store: activeDiagnostics
        )
        sponsorBlockDiagnostics = activeSponsorBlockDiagnostics
        let subtitleWorkflow = subtitleTransport.map {
            SubtitleSidecarWorkflow(
                transport: $0,
                exporter: activeExporter
            )
        }
        coordinator = DownloadCoordinator(
            runtime: runtime,
            downloader: downloader,
            DASHDownloader: DASHDownloader,
            DASHAssembler: DASHAssembler,
            HLSDownloader: HLSDownloader,
            HLSAssembler: HLSAssembler,
            mediaProcessor: processor,
            playbackVerifier: playbackVerifier,
            storage: StorageManager(),
            exporter: activeExporter,
            thumbnails: CoordinatorThumbnailURLProtocol.thumbnailService(),
            diagnostics: activeDiagnostics,
            sponsorBlockDiagnostics: activeSponsorBlockDiagnostics,
            notifications: notifications,
            networkMonitor: network,
            retrySleeper: retrySleeper,
            transferPermits: transferPermits,
            processingPermits: processingPermits,
            subtitleWorkflow: subtitleWorkflow,
            processingContinuation: processingContinuation,
            publicationWriter: publicationWriter,
            transferClock: transferClock,
            automaticallyMonitorTransfers: false
        )
        recorder = CoordinatorEventRecorder(coordinator.updates)
    }

    func configure(
        _ requested: AppSettings = .defaults,
        folderBookmark: Data? = nil,
        notifyDownloadComplete: Bool = false
    ) async {
        var settings = requested
        settings.minimumFreeSpaceReserveBytes = 0
        settings.notifyDownloadComplete = notifyDownloadComplete
        settings.notifyProcessingComplete = false
        settings.notifyFailure = false
        settings.notifyNeedsAttention = false
        settings.notifyLowStorage = false
        settings.liveActivities = false
        await sponsorBlockDiagnostics.setEnabled(
            settings.sponsorBlockDiagnosticLoggingEnabled
        )
        await coordinator.configure(
            settings: settings,
            folderBookmark: folderBookmark
        )
    }

    func filesBookmark() async throws -> Data {
        let folder = rootURL.appending(
            path: "Files",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return try await exporter.bookmark(for: folder)
    }

    func enqueue(
        metadata: MediaMetadata = DeveloperFixtures.media,
        configuration: DownloadConfiguration = DownloadCoordinatorTests.configuration
    ) async throws -> DownloadJob {
        try await coordinator.enqueue(
            metadata: metadata,
            configuration: configuration,
            extractorVersion: "fixture"
        )
    }

    func writeTemporarySource(
        jobID: UUID,
        filename: String,
        data: Data
    ) throws -> URL {
        let root = temporaryRoot(jobID: jobID)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let URL = root.appending(path: filename)
        try data.write(to: URL)
        return URL
    }

    func writeDocumentFixture(filename: String) throws {
        let documents = documentsRootURL
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(
            to: documents.appending(path: filename)
        )
    }

    func replaceDocumentsRootWithFile() throws {
        let documents = documentsRootURL
        try FileManager.default.removeItem(at: documents)
        try Data("not a directory".utf8).write(to: documents)
    }

    func temporaryRootExists(jobID: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: temporaryRoot(jobID: jobID).path
        )
    }

    func preparedSubtitleFiles(jobID: UUID) -> [URL] {
        temporaryFiles(jobID: jobID).filter {
            $0.pathComponents.contains("Subtitles")
        }
    }

    func unrelatedTemporaryFiles(jobID: UUID) -> [URL] {
        temporaryFiles(jobID: jobID).filter {
            !$0.pathComponents.contains("Subtitles")
        }
    }

    func finish() {
        recorder.finish()
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var documentsRootURL: URL {
        rootURL.appending(
            path: "Documents",
            directoryHint: .isDirectory
        )
    }

    private func temporaryRoot(jobID: UUID) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func temporaryFiles(jobID: UUID) -> [URL] {
        let root = temporaryRoot(jobID: jobID)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { element in
            guard let URL = element as? URL,
                  (try? URL.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true
            else {
                return nil
            }
            return URL
        }
    }
}

private actor CoordinatorSubtitleTransport: SubtitleTransporting {
    private(set) var callCount = 0
    private var mutation: (@Sendable () throws -> Void)?

    func setMutation(_ mutation: @escaping @Sendable () throws -> Void) {
        self.mutation = mutation
    }

    func download(from URL: URL) async throws -> Data {
        callCount += 1
        try mutation?()
        return Data(
            "WEBVTT\n\n00:00.000 --> 00:01.000\nFixture\n".utf8
        )
    }
}

private final class CoordinatorThumbnailURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let data = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(data.count)",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func thumbnailService() -> ThumbnailService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoordinatorThumbnailURLProtocol.self]
        return ThumbnailService(
            session: URLSession(configuration: configuration)
        )
    }
}

private struct CoordinatorFailingPhotoLibrary: PhotoLibraryExporting {
    func saveAsset(
        at fileURL: URL,
        kind: ExportAssetKind
    ) async throws -> String {
        throw CoordinatorTestFailure.photoFailure
    }
}

private final class CoordinatorNetworkMonitor:
    NetworkPathMonitoring,
    @unchecked Sendable
{
    let updates: AsyncStream<NetworkPathSnapshot>

    private let lock = NSLock()
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation
    private var snapshot: NetworkPathSnapshot

    init(_ snapshot: NetworkPathSnapshot) {
        self.snapshot = snapshot
        var captured: AsyncStream<NetworkPathSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuation = captured
    }

    func currentSnapshot() async -> NetworkPathSnapshot {
        lock.withLock { snapshot }
    }

    func send(_ value: NetworkPathSnapshot) {
        lock.withLock {
            snapshot = value
        }
        continuation.yield(value)
    }

    deinit {
        continuation.finish()
    }
}

private final class CoordinatorScriptedExtractor:
    ExtractorEngine,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Result<MediaMetadata, ExtractionError>]
    private var calls = 0
    private var recentReuseRequests: [Bool] = []

    init(results: [Result<MediaMetadata, ExtractionError>]) {
        self.results = results
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var allowsRecentAnalysis: [Bool] {
        lock.withLock { recentReuseRequests }
    }

    func analyzeForDownload(url: URL, allowRecent: Bool) async throws -> DownloadAnalysis {
        lock.withLock { recentReuseRequests.append(allowRecent) }
        return DownloadAnalysis(metadata: try await analyze(url: url), reuseToken: nil)
    }

    func versions() async throws -> ExtractorVersions {
        ExtractorVersions(python: "fixture", ytDLP: "fixture", ejs: "fixture")
    }

    func analyze(url: URL) async throws -> MediaMetadata {
        let result: Result<MediaMetadata, ExtractionError> = lock.withLock {
            calls += 1
            if results.count > 1 {
                return results.removeFirst()
            }
            return results.first ?? .success(DeveloperFixtures.media)
        }
        return try result.get()
    }

    func cancel(requestID: UInt64) {}
}

private actor CoordinatorRuntime: RuntimeProviding {
    let expectedAccountID: UUID?
    let extractor: any ExtractorEngine
    let resolver: any StreamResolver
    let DASHResolver: (any DASHFragmentResolving)?
    let HLSResolver: (any HLSPlaylistResolving)?

    init(
        extractor: any ExtractorEngine,
        resolver: any StreamResolver,
        DASHResolver: (any DASHFragmentResolving)? = nil,
        HLSResolver: (any HLSPlaylistResolving)? = nil,
        expectedAccountID: UUID? = nil
    ) {
        self.expectedAccountID = expectedAccountID
        self.extractor = extractor
        self.resolver = resolver
        self.DASHResolver = DASHResolver
        self.HLSResolver = HLSResolver
    }

    func makeExtractor(accountID: UUID?) async throws -> any ExtractorEngine {
        #expect(accountID == expectedAccountID)
        return try await makeExtractor()
    }

    func makeResolver(accountID: UUID?) async throws -> any StreamResolver {
        #expect(accountID == expectedAccountID)
        return try await makeResolver()
    }

    func makeDASHFragmentResolver(accountID: UUID?) async throws -> any DASHFragmentResolving {
        #expect(accountID == expectedAccountID)
        return try await makeDASHFragmentResolver()
    }

    func makeHLSPlaylistResolver(accountID: UUID?) async throws -> any HLSPlaylistResolving {
        #expect(accountID == expectedAccountID)
        return try await makeHLSPlaylistResolver()
    }

    func makeExtractor() async throws -> any ExtractorEngine {
        extractor
    }

    func makeResolver() async throws -> any StreamResolver {
        resolver
    }

    func makeDASHFragmentResolver() async throws
        -> any DASHFragmentResolving
    {
        guard let DASHResolver else {
            throw DASHFragmentResolutionError.bridgeUnavailable
        }
        return DASHResolver
    }

    func makeHLSPlaylistResolver() async throws
        -> any HLSPlaylistResolving
    {
        guard let HLSResolver else {
            throw HLSPlaylistResolutionError.bridgeUnavailable
        }
        return HLSResolver
    }
}

private struct CoordinatorResolver: StreamResolver {
    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet {
        ResolvedStreamSet(
            videoID: DeveloperFixtures.media.videoID,
            streams: formatIDs.map {
                ResolvedStream(
                    formatID: $0,
                    URL: URL(string: "https://fixture.invalid/\($0)")!,
                    HTTPHeaders: [:],
                    fileExtension: "mp4",
                    protocolName: "https",
                    sourceType: "direct_http",
                    hasVideo: true,
                    hasAudio: true,
                    expectedBytes: nil
                )
            },
            resolvedAt: .now
        )
    }
}

private struct CoordinatorRoleAwareResolver: StreamResolver {
    let exposesExactBytes: Bool

    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet {
        let streams = try formatIDs.map { formatID in
            guard let format = DeveloperFixtures.media.formats.first(
                where: { $0.formatID == formatID }
            ) else {
                throw CoordinatorTestFailure.unexpectedProcessing
            }
            return ResolvedStream(
                formatID: formatID,
                URL: URL(
                    string: "https://fixture.invalid/\(formatID)"
                )!,
                HTTPHeaders: [:],
                fileExtension: format.extension,
                protocolName: format.protocolName ?? "https",
                sourceType: format.sourceType,
                hasVideo: format.hasVideo,
                hasAudio: format.hasAudio,
                expectedBytes: exposesExactBytes
                    ? format.exactFileSizeBytes
                    : nil,
                httpChunkSize: 10 * 1_024 * 1_024
            )
        }
        return ResolvedStreamSet(
            videoID: DeveloperFixtures.media.videoID,
            streams: streams,
            resolvedAt: .now
        )
    }
}

enum CoordinatorDASHScenario: CaseIterable, Sendable {
    case combined
    case videoOnly
    case audioOnly
    case mixed

    var DASHFormatIDs: [String] {
        switch self {
        case .combined: ["18"]
        case .videoOnly, .mixed: ["137"]
        case .audioOnly: ["140"]
        }
    }

    var metadata: MediaMetadata {
        let formatsByID = Dictionary(
            uniqueKeysWithValues: DeveloperFixtures.media.formats.map {
                ($0.formatID, $0)
            }
        )
        let selectedIDs: [String] = switch self {
        case .combined: ["18"]
        case .videoOnly: ["137"]
        case .audioOnly: ["140"]
        case .mixed: ["137", "140"]
        }
        return DeveloperFixtures.metadata(
            formats: selectedIDs.compactMap { formatID in
                guard let format = formatsByID[formatID] else { return nil }
                return DASHFormatIDs.contains(formatID)
                    ? Self.DASHFormat(format)
                    : format
            }
        )
    }

    var configuration: DownloadConfiguration {
        var value = DownloadCoordinatorTests.configuration
        value.preset = .custom
        value.formatSelectionProvenance = .manual
        switch self {
        case .combined:
            value.mode = .videoAndAudio
            value.selectedVideoFormatID = "18"
            value.selectedAudioFormatID = nil
        case .videoOnly:
            value.mode = .videoOnly
            value.selectedVideoFormatID = "137"
            value.selectedAudioFormatID = nil
        case .audioOnly:
            value.mode = .audioOnly
            value.selectedVideoFormatID = nil
            value.selectedAudioFormatID = "140"
        case .mixed:
            value.mode = .videoAndAudio
            value.selectedVideoFormatID = "137"
            value.selectedAudioFormatID = "140"
        }
        return OutputCapabilityMatrix.normalized(value)
    }

    private static func DASHFormat(_ format: MediaFormat) -> MediaFormat {
        MediaFormat(
            formatID: format.formatID,
            formatNote: format.formatNote,
            extension: format.extension,
            container: format.container,
            videoCodec: format.videoCodec,
            audioCodec: format.audioCodec,
            width: format.width,
            height: format.height,
            resolution: format.resolution,
            framesPerSecond: format.framesPerSecond,
            dynamicRange: format.dynamicRange,
            isHDR: format.isHDR,
            audioBitrateKbps: format.audioBitrateKbps,
            videoBitrateKbps: format.videoBitrateKbps,
            totalBitrateKbps: format.totalBitrateKbps,
            exactFileSizeBytes: format.exactFileSizeBytes,
            approximateFileSizeBytes: format.approximateFileSizeBytes,
            hasVideo: format.hasVideo,
            hasAudio: format.hasAudio,
            protocolName: "http_dash_segments",
            sourceType: "dash",
            language: format.language
        )
    }
}

private actor CoordinatorDASHResolver: DASHFragmentResolving {
    let metadata: MediaMetadata
    private(set) var resolvedFormatIDs: [String] = []

    init(metadata: MediaMetadata) {
        self.metadata = metadata
    }

    func resolveDASHFragments(
        url: URL,
        formatID: String
    ) async throws -> ResolvedDASHFragmentPlan {
        guard let format = metadata.formats.first(where: {
            $0.formatID == formatID
        }) else {
            throw DASHFragmentResolutionError.invalidSelection
        }
        resolvedFormatIDs.append(formatID)
        return ResolvedDASHFragmentPlan(
            videoID: metadata.videoID,
            formatID: formatID,
            protocolName: "http_dash_segments",
            sourceType: "dash",
            fileExtension: format.extension ?? "mp4",
            hasVideo: format.hasVideo,
            hasAudio: format.hasAudio,
            HTTPHeaders: ["User-Agent": "fragment-secret-agent"],
            expectedBytes: nil,
            fragments: [
                ResolvedDASHFragment(
                    position: 0,
                    URL: URL(
                        string: "https://rr1.googlevideo.com/videoplayback?sig=fragment-secret-0"
                    )!,
                    expectedBytes: 4
                ),
                ResolvedDASHFragment(
                    position: 1,
                    URL: URL(
                        string: "https://rr1.googlevideo.com/videoplayback?sig=fragment-secret-1"
                    )!,
                    expectedBytes: 5
                ),
            ],
            resolvedAt: .now
        )
    }
}

private actor CoordinatorDASHDownloader: DASHFragmentDownloading {
    private(set) var downloadedFormatIDs: [String] = []
    private(set) var stagingDirectories: [URL] = []
    private var expiryFailures: Int

    init(expiryFailures: Int = 0) { self.expiryFailures = expiryFailures }

    func downloadDASHFragments(
        _ plan: ResolvedDASHFragmentPlan,
        jobID: UUID,
        stagingDirectoryURL: URL,
        progress: @escaping DASHFragmentTransferProgressHandler
    ) async throws -> DASHFragmentStagingResult {
        downloadedFormatIDs.append(plan.formatID)
        if expiryFailures > 0 {
            expiryFailures -= 1
            throw StreamDownloadError.HTTPFailure(statusCode: 403)
        }
        stagingDirectories.append(stagingDirectoryURL)
        try FileManager.default.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        let payloads = [Data("init".utf8), Data("media".utf8)]
        var staged: [StagedDASHFragment] = []
        var completedBytes: Int64 = 0
        for (position, payload) in payloads.enumerated() {
            try Task.checkCancellation()
            let fileURL = stagingDirectoryURL.appending(
                path: String(format: "fragment-%06d.part", position)
            )
            try payload.write(to: fileURL)
            let byteCount = Int64(payload.count)
            progress(
                DASHFragmentTransferProgress(
                    jobID: jobID,
                    formatID: plan.formatID,
                    fragmentPosition: position,
                    completedFragmentCount: position,
                    completedBytesBeforeFragment: completedBytes,
                    fragmentCount: payloads.count,
                    fragmentProgress: StreamTransferProgress(
                        jobID: jobID,
                        streamID: plan.formatID,
                        bytesWritten: byteCount,
                        totalBytesWritten: byteCount,
                        totalBytesExpected: byteCount,
                        instantaneousBytesPerSecond: Double(byteCount),
                        verifiedReusableBytes: byteCount,
                        networkBytesReceived: byteCount
                    )
                )
            )
            staged.append(
                StagedDASHFragment(
                    position: position,
                    fileURL: fileURL,
                    byteCount: byteCount
                )
            )
            completedBytes += byteCount
        }
        return DASHFragmentStagingResult(
            videoID: plan.videoID,
            formatID: plan.formatID,
            fragments: staged
        )
    }
}

private actor CoordinatorBlockingDASHDownloader: DASHFragmentDownloading {
    private(set) var hasStarted = false
    private(set) var stagingDirectories: [URL] = []

    func downloadDASHFragments(
        _ plan: ResolvedDASHFragmentPlan,
        jobID: UUID,
        stagingDirectoryURL: URL,
        progress: @escaping DASHFragmentTransferProgressHandler
    ) async throws -> DASHFragmentStagingResult {
        hasStarted = true
        stagingDirectories.append(stagingDirectoryURL)
        try FileManager.default.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        let partialURL = stagingDirectoryURL.appending(
            path: "fragment-000000.part"
        )
        try Data("partial".utf8).write(to: partialURL)
        try await Task.sleep(for: .seconds(3_600))
        throw CoordinatorTestFailure.unexpectedProcessing
    }
}

private actor CoordinatorPauseGapDASHDownloader: DASHFragmentDownloading {
    private(set) var attempts = 0
    private(set) var waitingBetweenResources = false
    private(set) var passedFirstWait = false
    private let delegate = CoordinatorDASHDownloader()

    func downloadDASHFragments(_ plan: ResolvedDASHFragmentPlan, jobID: UUID,
        stagingDirectoryURL: URL, progress: @escaping DASHFragmentTransferProgressHandler
    ) async throws -> DASHFragmentStagingResult {
        let lease = try FragmentSourceLeases.shared.acquire(jobID: jobID, formatID: plan.formatID)
        defer { FragmentSourceLeases.shared.release(lease) }
        attempts += 1
        if attempts == 1 {
            waitingBetweenResources = true
            try await Task.sleep(for: .seconds(3600))
            passedFirstWait = true
        }
        return try await delegate.downloadDASHFragments(plan, jobID: jobID,
            stagingDirectoryURL: stagingDirectoryURL, progress: progress)
    }
}

private actor CoordinatorDASHAssembler: DASHLocalStreamAssembling {
    private(set) var assembledFormatIDs: [String] = []
    private(set) var verificationClasses: [MediaVerificationClass] = []

    func assemble(
        _ input: DASHLocalStreamAssemblyInput
    ) async throws -> DASHLocalStreamAssemblyResult {
        assembledFormatIDs.append(input.plan.formatID)
        verificationClasses.append(input.verificationClass)
        guard input.stagingResult.fragments.map(\.position) == [0, 1]
        else {
            throw DASHLocalStreamAssemblyError.invalidInput
        }
        let bytes = try input.stagingResult.fragments.reduce(into: Data()) {
            result, fragment in
            result.append(try Data(contentsOf: fragment.fileURL))
        }
        guard bytes == Data("initmedia".utf8) else {
            throw DASHLocalStreamAssemblyError.aggregateByteCountMismatch
        }
        let fileURL = input.destinationDirectoryURL.appending(
            path: "\(input.plan.formatID).\(input.plan.fileExtension)"
        )
        try bytes.write(to: fileURL)
        let base = CoordinatorMediaProcessor.probe(
            fileURL,
            verificationClass: input.verificationClass
        )
        let streams = base.streams.filter { stream in
            (stream.kind == .video && input.plan.hasVideo)
                || (stream.kind == .audio && input.plan.hasAudio)
        }
        let probe = MediaProbeResult(
            fileURL: fileURL,
            formatNames: base.formatNames,
            formatLongName: base.formatLongName,
            durationSeconds: base.durationSeconds,
            startTimeSeconds: base.startTimeSeconds,
            bitRate: base.bitRate,
            fileSize: Int64(bytes.count),
            metadata: base.metadata,
            streams: streams,
            chapters: base.chapters,
            verificationEvidence: base.verificationEvidence
        )
        return DASHLocalStreamAssemblyResult(
            videoID: input.plan.videoID,
            formatID: input.plan.formatID,
            fileExtension: input.plan.fileExtension,
            fileURL: fileURL,
            byteCount: Int64(bytes.count),
            probe: probe
        )
    }
}

private enum CoordinatorHLSScenario {
    static let formatID = "hls-combined"
    static let mediaURL = URL(
        string:
            "https://rr1---sn.example.googlevideo.com/hls/media.m3u8?sig=hls-playlist-secret"
    )!
    static let playlist = """
    #EXTM3U
    #EXT-X-VERSION:2
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=AES-128,URI="key-a.bin?sig=hls-key-a-secret",IV=0x202122232425262728292A2B2C2D2E2F
    #EXT-X-MAP:URI="init.mp4?sig=hls-resource-secret"
    #EXTINF:6,
    one.m4s?sig=hls-resource-secret
    #EXT-X-KEY:METHOD=AES-128,URI="key-b.bin?sig=hls-key-b-secret",IV=0X303132333435363738393A3B3C3D3E3F
    #EXT-X-DISCONTINUITY
    #EXTINF:6,
    two.m4s?sig=hls-resource-secret
    #EXT-X-ENDLIST
    """

    static var metadata: MediaMetadata {
        let base = DeveloperFixtures.media.formats.first {
            $0.formatID == "18"
        }!
        return DeveloperFixtures.metadata(
            formats: [
                MediaFormat(
                    formatID: formatID,
                    formatNote: base.formatNote,
                    extension: "mp4",
                    container: base.container,
                    videoCodec: base.videoCodec,
                    audioCodec: base.audioCodec,
                    width: base.width,
                    height: base.height,
                    resolution: base.resolution,
                    framesPerSecond: base.framesPerSecond,
                    dynamicRange: base.dynamicRange,
                    isHDR: base.isHDR,
                    audioBitrateKbps: base.audioBitrateKbps,
                    videoBitrateKbps: base.videoBitrateKbps,
                    totalBitrateKbps: base.totalBitrateKbps,
                    exactFileSizeBytes: nil,
                    approximateFileSizeBytes: nil,
                    hasVideo: true,
                    hasAudio: true,
                    protocolName: "m3u8_native",
                    sourceType: "hls",
                    language: base.language
                ),
            ]
        )
    }

    static var configuration: DownloadConfiguration {
        var value = DownloadCoordinatorTests.configuration
        value.selectedVideoFormatID = formatID
        value.selectedAudioFormatID = nil
        value.formatSelectionProvenance = .manual
        return OutputCapabilityMatrix.normalized(value)
    }

    static func selection(
        videoID: String = DeveloperFixtures.media.videoID,
        formatID: String = CoordinatorHLSScenario.formatID,
        protocolName: String = "m3u8_native",
        sourceType: String = "hls",
        fileExtension: String = "mp4",
        hasVideo: Bool = true,
        hasAudio: Bool = true
    ) throws -> ResolvedHLSPlaylistSelection {
        let document = try HLSPlaylistParser.parse(
            Data(playlist.utf8),
            finalPlaylistURL: mediaURL
        )
        guard case let .media(plan) = document else {
            throw CoordinatorTestFailure.unexpectedProcessing
        }
        return ResolvedHLSPlaylistSelection(
            videoID: videoID,
            formatID: formatID,
            protocolName: protocolName,
            sourceType: sourceType,
            fileExtension: fileExtension,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            HTTPHeaders: [
                "User-Agent": "hls-resource-secret-agent",
            ],
            mediaPlaylistURL: mediaURL,
            route: .directMedia,
            playlistRequestCount: 1,
            redirectCount: 0,
            masterVariantCount: 0,
            mediaSegmentCount: plan.mediaSegmentCount,
            resourcePlan: plan,
            resolvedAt: .now
        )
    }
}

private enum CoordinatorEncryptedHLSFixture {
    static let keyA = data(
        hex: "000102030405060708090a0b0c0d0e0f"
    )
    static let keyB = data(
        hex: "101112131415161718191a1b1c1d1e1f"
    )
    static let plaintextResources = [
        Data("init".utf8),
        Data("me".utf8),
        Data("dia".utf8),
    ]
    static let assembledPlaintext = Data("initmedia".utf8)
    static let ciphertextByPath: [String: Data] = [
        "/hls/init.mp4": data(
            hex: "78aefe1fd7fc679e82ccc2faf45e50c0"
        ),
        "/hls/one.m4s": data(
            hex: "9e06e081c4e0dda063406cf3263be250"
        ),
        "/hls/two.m4s": data(
            hex: "ce867de9afe5fe4339e15b6dd114296c"
        ),
    ]
    static let ciphertexts = [
        ciphertextByPath["/hls/init.mp4"]!,
        ciphertextByPath["/hls/one.m4s"]!,
        ciphertextByPath["/hls/two.m4s"]!,
    ]
    static let secretMarkers = [
        "#EXTM3U",
        "googlevideo",
        "sig=",
        "hls-playlist-secret",
        "hls-key-a-secret",
        "hls-key-b-secret",
        "hls-resource-secret",
        "hls-resource-secret-agent",
        "000102030405060708090a0b0c0d0e0f",
        "101112131415161718191a1b1c1d1e1f",
        "202122232425262728292A2B2C2D2E2F",
        "303132333435363738393A3B3C3D3E3F",
        "Authorization",
        "Cookie",
        "token",
    ]

    private static func data(hex: String) -> Data {
        precondition(hex.utf8.count.isMultiple(of: 2))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}

private actor CoordinatorEncryptedHLSKeyLoader: HLSAES128KeyLoading {
    private let keys: [String: Data]
    private var requestedURLStorage: [URL] = []

    init(keys: [String: Data]) {
        self.keys = keys
    }

    func loadKey(
        from initialURL: URL,
        HTTPHeaders: [String: String],
        networkPolicy: StreamTransferNetworkPolicy,
        maximumRedirects: Int
    ) async throws -> HLSAES128KeyLoadResult {
        try Task.checkCancellation()
        guard
            HLSPlaylistSecurity.isAllowedPlaylistURL(initialURL),
            HLSPlaylistSecurity.areAllowedHeaders(HTTPHeaders),
            maximumRedirects >= 0,
            let key = keys[initialURL.absoluteString],
            key.count == URLSessionHLSAES128KeyLoader.keyByteCount
        else {
            throw HLSAES128KeyLoadingError.invalidResponse
        }
        _ = networkPolicy
        requestedURLStorage.append(initialURL)
        return HLSAES128KeyLoadResult(key: key, redirectCount: 0)
    }

    func requestedURLs() -> [URL] {
        requestedURLStorage
    }
}

private struct CoordinatorEncryptedHLSStagingSnapshot: Equatable, Sendable {
    let directoryURL: URL
    let resourceURLs: [URL]
    let plaintextResources: [Data]
    let byteCounts: [Int64]
}

private actor CoordinatorRecordingRealHLSDownloader:
    HLSResourceDownloading
{
    private let delegate: any HLSResourceDownloading
    private let calls: CoordinatorHLSCallRecorder
    private(set) var snapshot: CoordinatorEncryptedHLSStagingSnapshot?

    init(
        delegate: any HLSResourceDownloading,
        calls: CoordinatorHLSCallRecorder
    ) {
        self.delegate = delegate
        self.calls = calls
    }

    func downloadHLSResources(
        _ selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        progress: @escaping HLSResourceTransferProgressHandler
    ) async throws -> HLSResourceStagingResult {
        await calls.record("stage")
        let result = try await delegate.downloadHLSResources(
            selection,
            jobID: jobID,
            progress: progress
        )
        let resources = result.events.compactMap(\.resource)
        snapshot = try CoordinatorEncryptedHLSStagingSnapshot(
            directoryURL: result.stagingDirectoryURL,
            resourceURLs: resources.map(\.fileURL),
            plaintextResources: resources.map {
                try Data(contentsOf: $0.fileURL)
            },
            byteCounts: resources.map(\.byteCount)
        )
        return result
    }
}

private final class CoordinatorEncryptedHLSResourceURLProtocol:
    URLProtocol
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var requestedPathStorage: [String] = []
    nonisolated(unsafe) private static var taskDescriptionStorage: [String?] = []

    private let stateLock = NSLock()
    private var stopped = false

    static var requestedPaths: [String] {
        lock.withLock { requestedPathStorage }
    }

    static var taskDescriptions: [String?] {
        lock.withLock { taskDescriptionStorage }
    }

    static func reset(responses: [String: Data] = [:]) {
        lock.withLock {
            Self.responses = responses
            requestedPathStorage = []
            taskDescriptionStorage = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".googlevideo.com") == true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let URL = request.url else { return }
        let body = Self.lock.withLock { () -> Data? in
            Self.requestedPathStorage.append(URL.path)
            Self.taskDescriptionStorage.append(task?.taskDescription)
            return Self.responses[URL.path]
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.respond(to: URL, body: body)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private func respond(to URL: URL, body: Data?) {
        guard !stateLock.withLock({ stopped }) else { return }
        guard let body else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        guard let response = HTTPURLResponse(
            url: URL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(body.count),
                "Content-Encoding": "identity",
            ]
        ) else {
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor CoordinatorHLSCallRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor CoordinatorHLSResolver: HLSPlaylistResolving {
    let selection: ResolvedHLSPlaylistSelection
    let calls: CoordinatorHLSCallRecorder
    let refreshSelection: ResolvedHLSPlaylistSelection?
    private(set) var resolvedFormatIDs: [String] = []

    init(
        selection: ResolvedHLSPlaylistSelection,
        calls: CoordinatorHLSCallRecorder,
        refreshSelection: ResolvedHLSPlaylistSelection? = nil
    ) {
        self.selection = selection
        self.calls = calls
        self.refreshSelection = refreshSelection
    }

    func resolveHLSPlaylist(
        _ request: ExactHLSPlaylistRequest
    ) async throws -> ResolvedHLSPlaylistSelection {
        await calls.record("resolve")
        resolvedFormatIDs.append(request.formatID)
        return resolvedFormatIDs.count > 1 ? (refreshSelection ?? selection) : selection
    }
}

private actor CoordinatorHLSDownloader: HLSResourceDownloading {
    let calls: CoordinatorHLSCallRecorder
    private(set) var downloadedFormatIDs: [String] = []
    private(set) var stagingDirectories: [URL] = []

    private var expiryFailures: Int

    init(calls: CoordinatorHLSCallRecorder, expiryFailures: Int = 0) {
        self.calls = calls
        self.expiryFailures = expiryFailures
    }

    func downloadHLSResources(
        _ selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        progress: @escaping HLSResourceTransferProgressHandler
    ) async throws -> HLSResourceStagingResult {
        await calls.record("stage")
        downloadedFormatIDs.append(selection.formatID)
        if expiryFailures > 0 {
            expiryFailures -= 1
            throw StreamDownloadError.HTTPFailure(statusCode: 410)
        }
        let roots = StreamTransferDestinationRoots.live()
        let stagingDirectory = roots.applicationSupportDirectory
            .appending(path: "HLS-Staging", directoryHint: .isDirectory)
            .appending(
                path:
                    "task-\(jobID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        stagingDirectories.append(stagingDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let payloads = [
            Data("init".utf8),
            Data("me".utf8),
            Data("dia".utf8),
        ]
        let resources = selection.resourcePlan.events.compactMap(\.resource)
        guard resources.count == payloads.count else {
            throw HLSResourceStagingError.invalidPlan
        }
        var completedBytes: Int64 = 0
        var stagedByPosition: [Int: StagedHLSResource] = [:]
        for (offset, pair) in zip(resources, payloads).enumerated() {
            try Task.checkCancellation()
            let resource = pair.0
            let payload = pair.1
            let role = resource.kind == .initialization ? "init" : "media"
            let fileURL = stagingDirectory.appending(
                path: String(
                    format: "resource-%06d-%@.part",
                    resource.position,
                    role
                )
            )
            try payload.write(to: fileURL)
            let staged = StagedHLSResource(
                position: resource.position,
                kind: resource.kind,
                fileURL: fileURL,
                byteCount: Int64(payload.count),
                byteRange: resource.byteRange
            )
            stagedByPosition[resource.position] = staged
            completedBytes += staged.byteCount
            progress(
                HLSResourceTransferProgress(
                    jobID: jobID,
                    formatID: selection.formatID,
                    resourcePosition: resource.position,
                    completedResourceCount: offset + 1,
                    resourceCount: resources.count,
                    completedBytes: completedBytes
                )
            )
        }
        let events: [StagedHLSPlaylistEvent] = try selection.resourcePlan.events
            .map { event in
                switch event {
                case let .initialization(eventPosition, resource):
                    guard let staged = stagedByPosition[resource.position]
                    else {
                        throw HLSResourceStagingError.invalidPlan
                    }
                    return .initialization(
                        eventPosition: eventPosition,
                        resource: staged
                    )
                case let .media(
                    eventPosition,
                    resource,
                    initializationEventPosition
                ):
                    guard let staged = stagedByPosition[resource.position]
                    else {
                        throw HLSResourceStagingError.invalidPlan
                    }
                    return .media(
                        eventPosition: eventPosition,
                        resource: staged,
                        initializationEventPosition:
                            initializationEventPosition
                    )
                case let .discontinuity(eventPosition):
                    return .discontinuity(eventPosition: eventPosition)
                }
            }
        return HLSResourceStagingResult(
            videoID: selection.videoID,
            formatID: selection.formatID,
            stagingDirectoryURL: stagingDirectory,
            events: events
        )
    }
}

private actor CoordinatorHLSAssembler: HLSLocalStreamAssembling {
    let calls: CoordinatorHLSCallRecorder
    let delegate: HLSLocalStreamAssembler
    private(set) var assembledFormatIDs: [String] = []
    private(set) var verificationClasses: [MediaVerificationClass] = []
    private(set) var destinationURLs: [URL] = []
    private(set) var assemblyDirectories: [URL] = []

    init(
        calls: CoordinatorHLSCallRecorder,
        mediaProcessor: any MediaProcessor
    ) {
        self.calls = calls
        delegate = HLSLocalStreamAssembler(mediaProcessor: mediaProcessor)
    }

    func assemble(
        _ input: HLSLocalStreamAssemblyInput
    ) async throws -> HLSLocalStreamAssemblyResult {
        await calls.record("assemble")
        assembledFormatIDs.append(input.selection.formatID)
        verificationClasses.append(input.verificationClass)
        if let destination = input.jobLocalDestinationURL {
            destinationURLs.append(destination)
        }
        let result = try await delegate.assemble(input)
        assemblyDirectories.append(result.assemblyDirectoryURL)
        return result
    }
}

private actor CoordinatorBlockingHLSAssembler: HLSLocalStreamAssembling {
    let calls: CoordinatorHLSCallRecorder
    private(set) var hasStarted = false

    init(calls: CoordinatorHLSCallRecorder) {
        self.calls = calls
    }

    func assemble(
        _ input: HLSLocalStreamAssemblyInput
    ) async throws -> HLSLocalStreamAssemblyResult {
        await calls.record("assemble")
        hasStarted = true
        try await Task.sleep(for: .seconds(3_600))
        throw CoordinatorTestFailure.unexpectedProcessing
    }
}

private final class CoordinatorCountingResolver:
    StreamResolver,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet {
        lock.withLock {
            calls += 1
        }
        return ResolvedStreamSet(
            videoID: DeveloperFixtures.media.videoID,
            streams: formatIDs.map {
                ResolvedStream(
                    formatID: $0,
                    URL: URL(
                        string: "https://fixture.invalid/\($0)"
                    )!,
                    HTTPHeaders: [:],
                    fileExtension: "mp4",
                    protocolName: "https",
                    sourceType: "direct_http",
                    hasVideo: true,
                    hasAudio: true,
                    expectedBytes: nil
                )
            },
            resolvedAt: .now
        )
    }
}

private actor CoordinatorDownloader: StreamDownloading {
    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: destinationURL)
        progress(
            StreamTransferProgress(
                jobID: jobID,
                streamID: stream.formatID,
                bytesWritten: 7,
                totalBytesWritten: 7,
                totalBytesExpected: 7,
                instantaneousBytesPerSecond: 7
            )
        )
        return destinationURL
    }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        control(.cancel)
    }

    func pause(jobID: UUID) async -> StreamTaskControlResult {
        control(.pause)
    }

    func resume(jobID: UUID) async -> StreamTaskControlResult {
        control(.resume)
    }

    func reconcileBackgroundTasks() async -> [StreamTransferRegistration] {
        []
    }

    private func control(
        _ action: StreamTaskControlAction
    ) -> StreamTaskControlResult {
        StreamTaskControlResult(
            action: action,
            matchedTaskCount: 0,
            affectedTaskCount: 0,
            acknowledgedTaskCount: 0
        )
    }
}

private actor CoordinatorScriptedDownloader: StreamDownloading {
    private var failures: [StreamDownloadError]
    private(set) var callCount = 0
    private(set) var destinationURLs: [URL] = []
    private(set) var verifiedExpectedByteCounts: [Int64?] = []

    init(failures: [StreamDownloadError]) {
        self.failures = failures
    }

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        try performDownload(
            stream,
            jobID: jobID,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        verifiedExpectedBytes: Int64?,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> StreamDownloadResult {
        verifiedExpectedByteCounts.append(verifiedExpectedBytes)
        let URL = try performDownload(
            stream,
            jobID: jobID,
            destinationURL: destinationURL,
            progress: progress
        )
        return StreamDownloadResult(
            fileURL: URL,
            strategy: .oneGET,
            plannedRangeCount: 0,
            requestedRangeCount: 0,
            verifiedReusableBytes: 0,
            networkBytesReceived: 7
        )
    }

    private func performDownload(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) throws -> URL {
        callCount += 1
        destinationURLs.append(destinationURL)
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: destinationURL)
        progress(
            StreamTransferProgress(
                jobID: jobID,
                streamID: stream.formatID,
                bytesWritten: 7,
                totalBytesWritten: 7,
                totalBytesExpected: 7,
                instantaneousBytesPerSecond: 7
            )
        )
        return destinationURL
    }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        control(.cancel)
    }

    func pause(jobID: UUID) async -> StreamTaskControlResult {
        control(.pause)
    }

    func resume(jobID: UUID) async -> StreamTaskControlResult {
        control(.resume)
    }

    private func control(
        _ action: StreamTaskControlAction
    ) -> StreamTaskControlResult {
        StreamTaskControlResult(
            action: action,
            matchedTaskCount: 0,
            affectedTaskCount: 0,
            acknowledgedTaskCount: 0
        )
    }
}

/// Finishes the native request before delivering its result in the boundary
/// case; the pipeline must respect pause even when no native task remains.
private actor CoordinatorPauseBoundaryDownloader: StreamDownloading {
    let nativeTaskCount: Int
    private var released = false
    private var paused: Set<UUID> = []
    private let initialAdmissionPaused: Bool
    private var admissionPauses: [UUID: Bool] = [:]
    private(set) var callCount = 0

    init(nativeTaskCount: Int, admissionPaused: Bool = false) {
        self.nativeTaskCount = nativeTaskCount
        self.initialAdmissionPaused = admissionPaused
    }
    func setAdmissionPaused(_ paused: Bool, jobID: UUID) async { admissionPauses[jobID] = paused }
    func releaseAll() { released = true }

    func download(_ stream: ResolvedStream, jobID: UUID, destinationURL: URL,
                  progress: @escaping StreamTransferProgressHandler) async throws -> URL {
        while admissionPauses[jobID] ?? initialAdmissionPaused {
            try await Task.sleep(for: .milliseconds(10))
        }
        callCount += 1
        progress(StreamTransferProgress(jobID: jobID, streamID: stream.formatID,
            bytesWritten: 4, totalBytesWritten: 4, totalBytesExpected: 7,
            instantaneousBytesPerSecond: 4))
        while !released || paused.contains(jobID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: destinationURL)
        return destinationURL
    }
    func pause(jobID: UUID) async -> StreamTaskControlResult {
        if nativeTaskCount > 0 { paused.insert(jobID) }
        return control(.pause)
    }
    func resume(jobID: UUID) async -> StreamTaskControlResult {
        paused.remove(jobID)
        admissionPauses[jobID] = false
        return control(.resume)
    }
    func cancel(jobID: UUID) async -> StreamTaskControlResult { control(.cancel) }
    private func control(_ action: StreamTaskControlAction) -> StreamTaskControlResult {
        StreamTaskControlResult(action: action, matchedTaskCount: nativeTaskCount,
            affectedTaskCount: nativeTaskCount, acknowledgedTaskCount: nativeTaskCount)
    }
}

private actor CoordinatorRestorationDownloader: StreamDownloading {
    private(set) var pausedJobIDs: [UUID] = []
    let registrations: [StreamTransferRegistration]

    init(registrations: [StreamTransferRegistration]) {
        self.registrations = registrations
    }

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        throw CoordinatorTestFailure.unexpectedDownload
    }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        control(.cancel)
    }

    func pause(jobID: UUID) async -> StreamTaskControlResult {
        pausedJobIDs.append(jobID)
        let matched = registrations.count {
            $0.descriptor.jobID == jobID
        }
        return StreamTaskControlResult(
            action: .pause,
            matchedTaskCount: matched,
            affectedTaskCount: matched,
            acknowledgedTaskCount: matched
        )
    }

    func resume(jobID: UUID) async -> StreamTaskControlResult {
        control(.resume)
    }

    func reconcileBackgroundTasks() async -> [
        StreamTransferRegistration
    ] {
        registrations
    }

    private func control(
        _ action: StreamTaskControlAction
    ) -> StreamTaskControlResult {
        StreamTaskControlResult(
            action: action,
            matchedTaskCount: 0,
            affectedTaskCount: 0,
            acknowledgedTaskCount: 0
        )
    }
}

private struct CoordinatorProbeVerificationCall: Equatable, Sendable {
    let fileURL: URL
    let verificationClass: MediaVerificationClass
}

private struct CoordinatorProcessVerificationCall: Equatable, Sendable {
    let destinationURL: URL
    let verificationClass: MediaVerificationClass
}

private struct CoordinatorVerificationSnapshot: Equatable, Sendable {
    let probes: [CoordinatorProbeVerificationCall]
    let processes: [CoordinatorProcessVerificationCall]

    var fullDecodeVerificationCount: Int {
        probes.count {
            $0.verificationClass == .strongFullDecode
        } + processes.count {
            $0.verificationClass == .strongFullDecode
        }
    }

    var boundedVerificationCount: Int {
        probes.count {
            $0.verificationClass == .boundedStrong
        } + processes.count {
            $0.verificationClass == .boundedStrong
        }
    }
}

private struct CoordinatorProbeFileObservation: Equatable, Sendable {
    let fileURL: URL
    let bytes: Data
    let isRegularFile: Bool?
    let isSymbolicLink: Bool?
    let fileSize: Int?
}

private actor CoordinatorMediaProcessor: MediaProcessor {
    private var metadataByPath: [String: [String: String]] = [:]
    private var probeCalls: [CoordinatorProbeVerificationCall] = []
    private var processCalls: [CoordinatorProcessVerificationCall] = []
    private var probeFileObservations: [CoordinatorProbeFileObservation] = []

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        try Data("processed".utf8).write(to: request.destinationURL)
        let metadata = Self.metadata(request.metadata)
        metadataByPath[request.destinationURL.path] = metadata
        processCalls.append(
            CoordinatorProcessVerificationCall(
                destinationURL: request.destinationURL,
                verificationClass: request.verification
                    .requiredVerificationClass
            )
        )
        let probe = Self.processedProbe(
            request,
            metadata: metadata
        )
        return MediaProcessingResult(
            operationID: request.operationID,
            outputURLs: [request.destinationURL],
            probes: [probe],
            usedStreamCopy: true,
            usedHardwareAcceleration: false,
            usedSoftwareFallback: false,
            videoEncoderName: nil,
            appliedLoudnessNormalization: false,
            elapsedSeconds: 0
        )
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        if let bytes = try? Data(contentsOf: fileURL),
           let values = try? fileURL.resourceValues(
               forKeys: [
                   .isRegularFileKey,
                   .isSymbolicLinkKey,
                   .fileSizeKey,
               ]
           ) {
            probeFileObservations.append(
                CoordinatorProbeFileObservation(
                    fileURL: fileURL,
                    bytes: bytes,
                    isRegularFile: values.isRegularFile,
                    isSymbolicLink: values.isSymbolicLink,
                    fileSize: values.fileSize
                )
            )
        }
        probeCalls.append(
            CoordinatorProbeVerificationCall(
                fileURL: fileURL,
                verificationClass: verificationClass
            )
        )
        return Self.sourceProbe(
            fileURL,
            metadata: metadataByPath[fileURL.path] ?? [:],
            verificationClass: verificationClass
        )
    }

    func cancel(operationID: UUID) async {}

    func verificationSnapshot() -> CoordinatorVerificationSnapshot {
        CoordinatorVerificationSnapshot(
            probes: probeCalls,
            processes: processCalls
        )
    }

    func probeFileObservation(
        for fileURL: URL
    ) -> CoordinatorProbeFileObservation? {
        probeFileObservations.last {
            $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL
        }
    }

    fileprivate static func probe(
        _ fileURL: URL,
        metadata: [String: String] = [:],
        verificationClass: MediaVerificationClass = .strongFullDecode
    ) -> MediaProbeResult {
        MediaProbeResult(
            fileURL: fileURL,
            formatNames: ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"],
            formatLongName: "Fixture MP4",
            durationSeconds: DeveloperFixtures.media.durationSeconds,
            startTimeSeconds: 0,
            bitRate: 628_000,
            fileSize: 9,
            metadata: metadata,
            streams: [
                MediaStreamProbe(
                    index: 0,
                    kind: .video,
                    codecName: "h264",
                    codecLongName: "H.264",
                    codecProfile: nil,
                    codecTag: nil,
                    durationSeconds: DeveloperFixtures.media.durationSeconds,
                    bitRate: 500_000,
                    timeBase: nil,
                    disposition: MediaStreamDisposition(
                        isDefault: true,
                        forced: false,
                        attachedPicture: false
                    ),
                    metadata: [:],
                    video: VideoStreamProbe(
                        width: 640,
                        height: 360,
                        pixelFormat: "yuv420p",
                        averageFrameRate: MediaRational(
                            numerator: 30,
                            denominator: 1
                        ),
                        realFrameRate: nil,
                        colorSpace: nil,
                        colorTransfer: nil,
                        colorPrimaries: nil,
                        colorRange: nil,
                        fieldOrder: nil,
                        isHDR: false
                    ),
                    audio: nil,
                    subtitle: nil,
                    decodedFrames: verificationClass == .fastStructural
                        ? 0
                        : 3,
                    decodedSampleWindows:
                        verificationClass == .boundedStrong ? 3 : 0
                ),
                MediaStreamProbe(
                    index: 1,
                    kind: .audio,
                    codecName: "aac",
                    codecLongName: "AAC",
                    codecProfile: nil,
                    codecTag: nil,
                    durationSeconds: DeveloperFixtures.media.durationSeconds,
                    bitRate: 96_000,
                    timeBase: nil,
                    disposition: MediaStreamDisposition(
                        isDefault: true,
                        forced: false,
                        attachedPicture: false
                    ),
                    metadata: [:],
                    video: nil,
                    audio: AudioStreamProbe(
                        sampleFormat: "fltp",
                        sampleRate: 44_100,
                        channelCount: 2,
                        channelLayout: "stereo",
                        bitsPerSample: nil
                    ),
                    subtitle: nil,
                    decodedFrames: verificationClass == .fastStructural
                        ? 0
                        : 3,
                    decodedSampleWindows:
                        verificationClass == .boundedStrong ? 3 : 0
                ),
            ],
            chapters: [],
            verificationEvidence: verificationEvidence(
                verificationClass
            )
        )
    }

    private static func sourceProbe(
        _ fileURL: URL,
        metadata: [String: String],
        verificationClass: MediaVerificationClass
    ) -> MediaProbeResult {
        let source = probe(
            fileURL,
            metadata: metadata,
            verificationClass: verificationClass
        )
        let formatID = fileURL.deletingPathExtension()
            .lastPathComponent
        let streams: [MediaStreamProbe]
        switch formatID {
        case "137", "401":
            streams = source.streams.filter { $0.kind == .video }
        case "140", "251":
            streams = source.streams.filter { $0.kind == .audio }
        default:
            streams = source.streams
        }
        return MediaProbeResult(
            fileURL: source.fileURL,
            formatNames: source.formatNames,
            formatLongName: source.formatLongName,
            durationSeconds: source.durationSeconds,
            startTimeSeconds: source.startTimeSeconds,
            bitRate: source.bitRate,
            fileSize: source.fileSize,
            metadata: source.metadata,
            streams: streams,
            chapters: source.chapters,
            verificationEvidence: source.verificationEvidence
        )
    }

    private static func processedProbe(
        _ request: MediaProcessingRequest,
        metadata: [String: String]
    ) -> MediaProbeResult {
        let verificationClass = request.verification
            .requiredVerificationClass
        let source = probe(
            request.destinationURL,
            metadata: metadata,
            verificationClass: verificationClass
        )
        let includesVideo = request.verification.expectedVideoStreams?
            .contains(1) ?? true
        let includesAudio = request.verification.expectedAudioStreams?
            .contains(1) ?? true
        let streams = source.streams.filter {
            ($0.kind != .video || includesVideo)
                && ($0.kind != .audio || includesAudio)
        }.map { stream in
            guard
                stream.kind == .video,
                let video = stream.video,
                let dimensions = request.verification.expectedDimensions
            else {
                return stream
            }
            return MediaStreamProbe(
                index: stream.index,
                kind: stream.kind,
                codecName: stream.codecName,
                codecLongName: stream.codecLongName,
                codecProfile: stream.codecProfile,
                codecTag: stream.codecTag,
                durationSeconds: stream.durationSeconds,
                bitRate: stream.bitRate,
                timeBase: stream.timeBase,
                disposition: stream.disposition,
                metadata: stream.metadata,
                video: VideoStreamProbe(
                    width: dimensions.width,
                    height: dimensions.height,
                    pixelFormat: video.pixelFormat,
                    averageFrameRate: video.averageFrameRate,
                    realFrameRate: video.realFrameRate,
                    colorSpace: video.colorSpace,
                    colorTransfer: video.colorTransfer,
                    colorPrimaries: video.colorPrimaries,
                    colorRange: video.colorRange,
                    fieldOrder: video.fieldOrder,
                    isHDR: video.isHDR
                ),
                audio: stream.audio,
                subtitle: stream.subtitle,
                decodedFrames: stream.decodedFrames,
                decodedSampleWindows: stream.decodedSampleWindows
            )
        }
        return MediaProbeResult(
            fileURL: source.fileURL,
            formatNames: source.formatNames,
            formatLongName: source.formatLongName,
            durationSeconds: source.durationSeconds,
            startTimeSeconds: source.startTimeSeconds,
            bitRate: source.bitRate,
            fileSize: source.fileSize,
            metadata: source.metadata,
            streams: streams,
            chapters: request.chapters,
            verificationEvidence: source.verificationEvidence
        )
    }

    private static func verificationEvidence(
        _ verificationClass: MediaVerificationClass
    ) -> MediaProbeEvidence {
        MediaProbeEvidence(
            verificationClass: verificationClass,
            fullDecodePerformed:
                verificationClass == .strongFullDecode,
            packetsInspected: 16,
            inspectedPacketBytes: 4_096,
            tailInspectionAttempted:
                verificationClass != .strongFullDecode,
            tailInspectionSucceeded:
                verificationClass != .strongFullDecode,
            tailInspectionReachedEOF:
                verificationClass != .strongFullDecode
        )
    }

    private static func metadata(
        _ tags: MediaTagSet
    ) -> [String: String] {
        var values = tags.additional
        let standard: [String: String?] = [
            "title": tags.title,
            "artist": tags.artist,
            "album": tags.album,
            "album_artist": tags.albumArtist,
            "comment": tags.comment,
            "date": tags.date,
            "genre": tags.genre,
            "language": tags.language,
            "description": tags.description,
        ]
        for (key, value) in standard {
            if let value, !value.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

private struct CoordinatorNoisyProgressMeasurement: Sendable {
    let progressOpportunities: Int
    let operationStartedAt: ContinuousClock.Instant
    let operationFinishedAt: ContinuousClock.Instant
}

private actor CoordinatorNoisyMediaProcessor: MediaProcessor {
    private let base = CoordinatorMediaProcessor()
    private(set) var measurements: [CoordinatorNoisyProgressMeasurement] = []

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        let startedAt = ContinuousClock.now
        let result = try await base.process(request, progress: { _ in })

        for index in 0 ... 10_000 {
            progress(
                Self.progress(
                    operationID: request.operationID,
                    stage: .muxing,
                    fraction: Double(index) / Double(10_001)
                )
            )
        }
        progress(
            Self.progress(
                operationID: request.operationID,
                stage: .muxing,
                fraction: 1
            )
        )
        let finishedAt = ContinuousClock.now
        measurements.append(
            CoordinatorNoisyProgressMeasurement(
                progressOpportunities: 10_002,
                operationStartedAt: startedAt,
                operationFinishedAt: finishedAt
            )
        )
        return result
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        try await base.probe(
            fileURL,
            verificationClass: verificationClass
        )
    }

    func cancel(operationID: UUID) async {
        await base.cancel(operationID: operationID)
    }

    private static func progress(
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

private actor CoordinatorTypedCancellationProcessor: MediaProcessor {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private(set) var hasFinished = false

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        throw CoordinatorTestFailure.unexpectedProcessing
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        hasStarted = true
        await withCheckedContinuation { waiter = $0 }
        hasFinished = true
        // The native processor uses this typed error, rather than CancellationError.
        throw MediaProcessorError.cancelled
    }

    func cancel(operationID: UUID) async {
        waiter?.resume()
        waiter = nil
    }
}

/// Uses the production scheduler while injecting only the interruption/grant timing.
private actor CoordinatorLiveContinuation: ContinuedProcessingControlling {
    private let base: ContinuedProcessingController
    private var allowed = true
    private var attempts: [UUID: UUID] = [:]
    init(base: ContinuedProcessingController) { self.base = base }
    func setAllowed(_ value: Bool) { allowed = value }
    func begin(job: DownloadJob, attempt: UUID, expiration: @escaping @Sendable () async -> Void) async {
        attempts[job.id] = attempt
        await base.begin(job: job, attempt: attempt, expiration: expiration)
    }
    func canProcess(jobID: UUID, attempt: UUID) async -> Bool {
        guard allowed else { return false }
        return await base.canProcess(jobID: jobID, attempt: attempt)
    }
    func status(jobID: UUID, attempt: UUID) async -> ContinuedProcessingStatus {
        if !allowed { return .init(state: .queued) }
        return await base.status(jobID: jobID, attempt: attempt)
    }
    func nativeStatus(jobID: UUID) async -> ContinuedProcessingStatus {
        guard let attempt = attempts[jobID] else { return .init(state: .notRequested) }
        return await base.status(jobID: jobID, attempt: attempt)
    }
    func waitForExecution(jobID: UUID, attempt: UUID) async throws {
        while !allowed { try await Task.sleep(for: .milliseconds(10)) }
        try await base.waitForExecution(jobID: jobID, attempt: attempt)
    }
    func finish(jobID: UUID, attempt: UUID, success: Bool) async {
        await base.finish(jobID: jobID, attempt: attempt, success: success)
    }
}

private actor CoordinatorPendingContinuation: ContinuedProcessingControlling {
    private var allowed = true
    private(set) var attempts: Set<UUID> = []
    func setAllowed(_ value: Bool) { allowed = value }
    func begin(job: DownloadJob, attempt: UUID, expiration: @escaping @Sendable () async -> Void) { attempts.insert(attempt) }
    func canProcess(jobID: UUID, attempt: UUID) -> Bool { allowed }
    func status(jobID: UUID, attempt: UUID) -> ContinuedProcessingStatus { .init(state: allowed ? .granted : .queued) }
    func waitForExecution(jobID: UUID, attempt: UUID) async throws {
        while !allowed { try await Task.sleep(for: .milliseconds(10)) }
    }
    func finish(jobID: UUID, attempt: UUID, success: Bool) {}
}

private actor CoordinatorBackgroundContinuation: ContinuedProcessingControlling {
    var expiration: (@Sendable () async -> Void)?
    var success: Bool?
    private var allowed = true
    private var holdFinish = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private(set) var finishIsWaiting = false
    private(set) var beginCount = 0
    private var begunAttempts: Set<UUID> = []
    func holdNextFinish() { holdFinish = true }
    func releaseFinish() { finishWaiter?.resume(); finishWaiter = nil }
    func setAllowed(_ value: Bool) { allowed = value }
    func canProcess(jobID: UUID, attempt: UUID) -> Bool { allowed }
    func begin(job: DownloadJob, attempt: UUID, expiration: @escaping @Sendable () async -> Void) {
        if begunAttempts.insert(attempt).inserted { beginCount += 1 }
        self.expiration = expiration
    }
    func finish(jobID: UUID, attempt: UUID, success: Bool) async {
        if holdFinish {
            holdFinish = false
            finishIsWaiting = true
            await withCheckedContinuation { finishWaiter = $0 }
            finishIsWaiting = false
        }
        self.success = success
    }
    func expire() async { await expiration?() }
}

private actor CoordinatorInterruptedEditProcessor: MediaProcessor {
    private let base = CoordinatorMediaProcessor()
    private var blocked = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var editStarts = 0
    private(set) var assemblyCount = 0

    func process(_ request: MediaProcessingRequest,
                 progress: @escaping MediaProcessingProgressHandler) async throws -> MediaProcessingResult {
        if case .removeRanges = request.operation {
            editStarts += 1
            if blocked { await withCheckedContinuation { waiters.append($0) } }
            try Task.checkCancellation()
        } else { assemblyCount += 1 }
        guard !FileManager.default.fileExists(atPath: request.destinationURL.path) else {
            throw MediaProcessorError.outputAlreadyExists(request.destinationURL)
        }
        return try await base.process(request, progress: progress)
    }

    func probe(_ fileURL: URL, verificationClass: MediaVerificationClass) async throws -> MediaProbeResult {
        try await base.probe(fileURL, verificationClass: verificationClass)
    }

    func allowEdits() { blocked = false; releaseWaiters() }
    func cancel(operationID: UUID) { releaseWaiters() }
    private func releaseWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CoordinatorBlockingMediaProcessor: MediaProcessor {
    private let completedProcessor = CoordinatorMediaProcessor()
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeProbes = 0
    private var peakProbes = 0
    private var probesAllowed = false
    private(set) var probeCount = 0
    func allowProbes() async { probesAllowed = true; await cancel(operationID: UUID()) }

    var maximumConcurrentProbes: Int {
        peakProbes
    }

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        try await completedProcessor.process(request, progress: progress)
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        probeCount += 1
        activeProbes += 1
        peakProbes = max(peakProbes, activeProbes)
        if !probesAllowed {
            await withCheckedContinuation { continuation in probeWaiters.append(continuation) }
        }
        activeProbes -= 1
        try Task.checkCancellation()
        return try await completedProcessor.probe(
            fileURL,
            verificationClass: verificationClass
        )
    }

    func cancel(operationID: UUID) async {
        let waiters = probeWaiters
        probeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct CoordinatorPlaybackVerifier: ApplePlaybackVerifying {
    func verify(fileURL: URL) async throws -> ApplePlaybackVerification {
        ApplePlaybackVerification(
            fileURL: fileURL,
            fileSize: 9,
            assetDurationSeconds: DeveloperFixtures.media.durationSeconds,
            videoTrackCount: 1,
            audioTrackCount: 1,
            decodedSamples: [],
            playerItemBecameReady: true,
            playbackAdvanceSeconds: 1,
            verificationElapsedSeconds: 0
        )
    }
}

private actor CoordinatorSleeperRecorder {
    private(set) var delays: [Double] = []

    func record(_ delay: Double) {
        delays.append(delay)
    }
}

private final class CoordinatorEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadCoordinatorEvent] = []
    private var observedJobs: [CoordinatorJobObservation] = []
    private var observationTask: Task<Void, Never>?

    init(_ stream: AsyncStream<DownloadCoordinatorEvent>) {
        observationTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                lock.withLock {
                    events.append(event)
                    if case let .upsertJob(job) = event {
                        observedJobs.append(
                            CoordinatorJobObservation(
                                job: job,
                                observedAt: .now
                            )
                        )
                    }
                }
            }
        }
    }

    func jobs(_ jobID: UUID) -> [DownloadJob] {
        lock.withLock {
            events.compactMap { event in
                guard case let .upsertJob(job) = event,
                      job.id == jobID
                else {
                    return nil
                }
                return job
            }
        }
    }

    func history(_ jobID: UUID) -> [HistoryRecord] {
        lock.withLock {
            events.compactMap { event in
                guard case let .addHistory(record) = event,
                      record.jobID == jobID
                else {
                    return nil
                }
                return record
            }
        }
    }

    func jobObservations(_ jobID: UUID) -> [CoordinatorJobObservation] {
        lock.withLock {
            observedJobs.filter { $0.job.id == jobID }
        }
    }

    func networkRequest(jobID: UUID) -> NetworkAccessRequest? {
        lock.withLock {
            events.compactMap { event in
                guard case let .requestNetworkAccess(request) = event,
                      request.jobID == jobID
                else {
                    return nil
                }
                return request
            }.first
        }
    }

    func duplicateRequest(jobID: UUID) -> DuplicateConflict? {
        lock.withLock {
            events.compactMap { event in
                guard case let .requestDuplicate(request) = event,
                      request.jobID == jobID
                else {
                    return nil
                }
                return request
            }.first
        }
    }

    func hasCellularPreferenceChange(_ value: Bool) -> Bool {
        lock.withLock {
            events.contains { event in
                guard case let .cellularPromptPreferenceChanged(changed) =
                    event
                else {
                    return false
                }
                return changed == value
            }
        }
    }

    func finish() {
        observationTask?.cancel()
        observationTask = nil
    }
}

private struct CoordinatorJobObservation: Sendable {
    let job: DownloadJob
    let observedAt: ContinuousClock.Instant
}

private extension NetworkPathSnapshot {
    static let fixtureWiFi = Self(
        isSatisfied: true,
        interface: .wifi,
        isExpensive: false,
        isConstrained: false
    )

    static let fixtureCellular = Self(
        isSatisfied: true,
        interface: .cellular,
        isExpensive: true,
        isConstrained: false
    )
}

private enum CoordinatorTestFailure: Error {
    case timeout
    case unexpectedDownload
    case unexpectedProcessing
    case photoFailure
}

private final class CoordinatorDelayedPauseControls: StreamDownloading, FragmentCheckpointManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let delegate = CoordinatorDownloader()
    private var calls = 0
    private var discards = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    var cancelCount: Int { lock.withLock { calls } }
    var discardCount: Int { lock.withLock { discards } }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        await withCheckedContinuation { continuation in
            lock.withLock { calls += 1; waiters[calls] = continuation }
        }
        return await delegate.cancel(jobID: jobID)
    }
    func release(_ call: Int) { lock.withLock { waiters.removeValue(forKey: call) }?.resume() }
    func releaseAll() {
        let pending = lock.withLock { let values = Array(waiters.values); waiters.removeAll(); return values }
        pending.forEach { $0.resume() }
    }
    func discardFragmentCheckpoints(jobID: UUID, formatID: String?) throws {
        lock.withLock { discards += 1 }
    }
    func pause(jobID: UUID) async -> StreamTaskControlResult { await delegate.pause(jobID: jobID) }
    func resume(jobID: UUID) async -> StreamTaskControlResult { await delegate.resume(jobID: jobID) }
    func reconcileBackgroundTasks() async -> [StreamTransferRegistration] { [] }
    func download(_ stream: ResolvedStream, jobID: UUID, destinationURL: URL,
                  progress: @escaping StreamTransferProgressHandler) async throws -> URL {
        try await delegate.download(stream, jobID: jobID, destinationURL: destinationURL, progress: progress)
    }
}

private actor CoordinatorForegroundPlaybackVerifier: ApplePlaybackVerifying {
    private var allowed = false
    private(set) var calls = 0
    func allowPlayback() { allowed = true }
    func verify(fileURL: URL) async throws -> ApplePlaybackVerification {
        calls += 1
        guard allowed else { throw ApplePlaybackVerifierError.requiresForeground }
        return try await CoordinatorPlaybackVerifier().verify(fileURL: fileURL)
    }
}

private actor CoordinatorCompletionDeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            isWaiting = true
        }
    }

    func release() {
        released = true
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

private struct CoordinatorDelayedPhotoLibrary: PhotoLibraryExporting {
    let delivery: CoordinatorCompletionDeliveryGate

    func saveAsset(at fileURL: URL, kind: ExportAssetKind) async throws -> String {
        // Model an OS save callback that arrives after cancellation.
        await delivery.wait()
        return "synthetic-asset"
    }
}

private actor CoordinatorPublicationPhotos: PhotoLibraryExporting {
    private(set) var calls = 0
    private(set) var names: [String] = []
    let denyFirst: Bool
    init(denyFirst: Bool = false) { self.denyFirst = denyFirst }
    func saveAsset(at fileURL: URL, kind: ExportAssetKind) async throws -> String {
        try await saveAsset(at: fileURL, kind: kind, originalFilename: fileURL.lastPathComponent)
    }
    func saveAsset(at fileURL: URL, kind: ExportAssetKind, originalFilename: String) async throws -> String {
        calls += 1; names.append(originalFilename)
        if denyFirst && calls == 1 { throw IllucetError.photosPermissionDenied }
        return "synthetic-asset-\(calls)"
    }
}

private actor CoordinatorPublicationJournal {
    enum Failure { case beforeEffect, afterPhotos, completion }
    nonisolated let root = FileManager.default.temporaryDirectory.appending(path: "D2-Journal-\(UUID())")
    private var failure: Failure?
    private var blocked = false
    init(failure: Failure? = nil) { self.failure = failure }
    func save(_ job: DownloadJob) async throws {
        let receipts = job.pipelineCheckpoint?.publicationReceipts ?? []
        if (failure == .beforeEffect && receipts.contains { $0.state == .committing })
            || (failure == .afterPhotos && receipts.contains { $0.destination == .photos && $0.state == .committed })
            || (failure == .completion && job.state == .completed) { blocked = true }
        if blocked { throw ExportPublicationError.persistenceUnavailable }
        let writer = IllucetPersistence(rootURL: root)
        var snapshot = try await writer.load()
        snapshot.schemaVersion = IllucetSnapshot.currentSchemaVersion
        snapshot.jobs = [job]
        try await writer.save(snapshot)
    }
    func loadJob() async throws -> DownloadJob {
        let snapshot = try await IllucetPersistence(rootURL: root).load()
        return try #require(snapshot.jobs.first)
    }
    func unblock() { blocked = false; failure = nil }
    nonisolated func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private actor CoordinatorUncertainPhotoLibrary: PhotoLibraryExporting {
    private(set) var calls = 0
    func saveAsset(at fileURL: URL, kind: ExportAssetKind) async throws -> String {
        calls += 1
        throw ExportPublicationError.outcomeUnknown
    }
}

private final class CoordinatorTransferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    var now: Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

private actor CoordinatorRecoveryDownloader: StreamDownloading {
    private var heldForegroundChange: Bool?
    private var foregroundWaiter: CheckedContinuation<Void, Never>?
    private(set) var foregroundActive = false
    var foregroundChangeWaiting: Bool { foregroundWaiter != nil }
    func holdNextForegroundChange(_ active: Bool) { heldForegroundChange = active }
    func releaseForegroundChange() { foregroundWaiter?.resume(); foregroundWaiter = nil }
    func setForegroundActive(_ active: Bool) async {
        if heldForegroundChange == active {
            heldForegroundChange = nil
            await withCheckedContinuation { foregroundWaiter = $0 }
        }
        foregroundActive = active
    }
    private var streams: [String] = []
    private var finishesAudio = false
    private var holdsCancellation: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var audioCalls: Int { streams.count { $0 == "140" } }
    var videoCalls: Int { streams.count { $0 == "137" } }
    var cancellationWaiting: Bool { !waiters.isEmpty }
    init(holdCancellation: Bool) { holdsCancellation = holdCancellation }
    func finishAudio() { finishesAudio = true }
    func releaseCancellation() {
        holdsCancellation = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func download(_ stream: ResolvedStream, jobID: UUID, destinationURL: URL,
                  progress: @escaping StreamTransferProgressHandler) async throws -> URL {
        streams.append(stream.formatID)
        progress(StreamTransferProgress(jobID: jobID, streamID: stream.formatID,
            bytesWritten: 4, totalBytesWritten: 4, totalBytesExpected: 7,
            instantaneousBytesPerSecond: Double(streams.count)))
        while stream.formatID == "140" && !finishesAudio { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: destinationURL)
        return destinationURL
    }
    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        if holdsCancellation { await withCheckedContinuation { waiters.append($0) } }
        return control(.cancel)
    }
    func pause(jobID: UUID) async -> StreamTaskControlResult { control(.pause) }
    func resume(jobID: UUID) async -> StreamTaskControlResult { control(.resume) }
    private func control(_ action: StreamTaskControlAction) -> StreamTaskControlResult {
        StreamTaskControlResult(action: action, matchedTaskCount: 1, affectedTaskCount: 1, acknowledgedTaskCount: 1)
    }
}
