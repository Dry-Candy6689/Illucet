import Foundation
import Testing
@testable import Illucet

private let subtitlesOnlyManual = SubtitleTrackSelection(
    trackID: "subtitle-111111111111111111111111",
    formatID: "subtitle-format-111111111111111111111111",
    language: "en",
    automatic: false
)

private let subtitlesOnlyAutomatic = SubtitleTrackSelection(
    trackID: "subtitle-222222222222222222222222",
    formatID: "subtitle-format-222222222222222222222222",
    language: "en-auto",
    automatic: true
)

private let subtitlesOnlyVTT = Data(
    "WEBVTT\n\n00:00.000 --> 00:01.000\nCaption\n".utf8
)

@Suite("P8.15 Subtitles Only")
struct SubtitlesOnlyTests {
    @Test
    func durableRequestIsBackwardCompatibleAndTruthful() throws {
        var configuration = subtitlesOnlyConfiguration()
        configuration.selectedVideoFormatID = "18"
        configuration.selectedAudioFormatID = "140"
        configuration.thumbnailBehavior = .separateAndEmbed
        configuration.preserveChapters = true
        configuration.writeChapters = true
        configuration.bundleStyle = .zip
        configuration.trimStartSeconds = 1
        configuration = OutputCapabilityMatrix.normalized(configuration)

        #expect(configuration.effectiveOutputIdentity == .subtitlesOnly)
        #expect(configuration.selectedFormatIDs.isEmpty)
        #expect(configuration.thumbnailBehavior == .none)
        #expect(!configuration.preserveChapters)
        #expect(!configuration.writeChapters)
        #expect(configuration.bundleStyle == .mediaOnly)
        #expect(configuration.trimStartSeconds == nil)
        #expect(
            EffectiveOutputIdentity.implementedRequestCases.contains(
                .subtitlesOnly
            )
        )

        let encoded = try JSONEncoder.illucetEncoder.encode(configuration)
        let decoded = try JSONDecoder.illucetDecoder.decode(
            DownloadConfiguration.self,
            from: encoded
        )
        #expect(decoded == configuration)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "requestKind")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder.illucetDecoder.decode(
            DownloadConfiguration.self,
            from: legacyData
        )
        #expect(legacy.requestKind == nil)
        #expect(legacy.effectiveOutputIdentity == legacy.mode.effectiveOutputIdentity)
    }

    @Test
    func exactSelectionsValidateVTTAndSRTWithoutMediaFormats() throws {
        for delivery in [SubtitleDelivery.sidecarVTT, .sidecarSRT] {
            let configuration = subtitlesOnlyConfiguration(delivery: delivery)
            try OutputCapabilityMatrix.validate(
                configuration,
                metadata: DeveloperFixtures.media
            )
            let plans = try SubtitleSelectionPlanner.plans(
                configuration: configuration,
                metadata: DeveloperFixtures.media
            )
            #expect(plans.map(\.selection) == [
                subtitlesOnlyManual,
                subtitlesOnlyAutomatic,
            ])
            #expect(plans.allSatisfy {
                $0.kind == (delivery == .sidecarVTT ? .webVTT : .subRip)
            })
            #expect(configuration.selectedFormatIDs.isEmpty)
        }

        var missing = subtitlesOnlyConfiguration()
        missing.subtitleSelections = nil
        missing = OutputCapabilityMatrix.normalized(missing)
        #expect(throws: SubtitlePipelineError.missingSelection) {
            try OutputCapabilityMatrix.validate(
                missing,
                metadata: DeveloperFixtures.media
            )
        }

        for destination in [
            ExportDestination.photos,
            .filesAndPhotos,
            .askEveryTime,
        ] {
            var invalid = subtitlesOnlyConfiguration()
            invalid.destination = destination
            #expect(throws: SubtitlePipelineError.subtitlesOnlyDestination) {
                try OutputCapabilityMatrix.validate(
                    invalid,
                    metadata: DeveloperFixtures.media
                )
            }
        }
    }

    @Test
    func titleBasedFilenamesIncludeExactTrackIdentityAndStaySafe() throws {
        let prepared = preparedSubtitles(at: URL(filePath: "/tmp"))
        let names = try SubtitleFilenamePlanner.filenames(
            title: "../CON/Épisode: finale",
            sidecars: prepared
        )

        #expect(names.count == 2)
        #expect(Set(names).count == 2)
        #expect(names[0].contains("en.manual.11111111-11111111"))
        #expect(names[1].contains("en-auto.auto.22222222-22222222"))
        #expect(names[0].hasSuffix(".vtt"))
        #expect(names[1].hasSuffix(".srt"))
        #expect(names.allSatisfy {
            !$0.contains("/") && !$0.contains("\\")
                && $0.utf8.count <= SubtitleFilenamePlanner.maximumFilenameBytes
        })

        let sharedSuffix = [
            PreparedSubtitleSidecar(
                selection: SubtitleTrackSelection(
                    trackID: "track-first-aaaaaaaa",
                    formatID: "format-first-bbbbbbbb",
                    language: "en",
                    automatic: false
                ),
                kind: .webVTT,
                temporaryURL: URL(filePath: "/tmp/first.vtt")
            ),
            PreparedSubtitleSidecar(
                selection: SubtitleTrackSelection(
                    trackID: "track-second-aaaaaaaa",
                    formatID: "format-second-bbbbbbbb",
                    language: "en",
                    automatic: false
                ),
                kind: .webVTT,
                temporaryURL: URL(filePath: "/tmp/second.vtt")
            ),
        ]
        let collisionSafeNames = try SubtitleFilenamePlanner.filenames(
            title: "Same title",
            sidecars: sharedSuffix
        )
        #expect(Set(collisionSafeNames).count == 2)
        #expect(collisionSafeNames.allSatisfy {
            $0.utf8.count <= SubtitleFilenamePlanner.maximumFilenameBytes
        })
    }

    @Test
    func pipelineProducesVTTAndSRTWithZeroMediaOwnershipCalls() async throws {
        let root = try temporaryDirectory("Pipeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        let resolver = CountingSubtitlesResolver()
        let downloader = CountingSubtitlesDownloader()
        let processor = CountingSubtitlesProcessor()
        let extractor = SubtitlesExtractor(DeveloperFixtures.media)
        let runtime = SubtitlesRuntime(extractor: extractor, resolver: resolver)
        let exporter = ExportManager(documentsRootURL: documents)
        let flow = DownloadExportFlow(
            exporter: exporter,
            diagnostics: DiagnosticStore(rootURL: root.appending(path: "Diagnostics")),
            notifications: UserNotificationService(),
            eventSink: { _ in }
        )
        let transport = CountingSubtitleTransport([
            subtitlesOnlyVTT,
            subtitlesOnlyVTT,
        ])
        let workflow = SubtitleSidecarWorkflow(
            transport: transport,
            exporter: exporter
        )
        var configuration = subtitlesOnlyConfiguration(delivery: .sidecarVTT)
        configuration.subtitleSelections = [subtitlesOnlyManual]
        configuration = OutputCapabilityMatrix.normalized(configuration)
        var job = subtitlesOnlyJob(configuration: configuration)
        let box = SubtitlesJobBox(job)
        let runner = DownloadPipelineRunner(
            runtime: runtime,
            downloader: downloader,
            mediaProcessor: processor,
            playbackVerifier: SubtitlesPlaybackVerifier(),
            storage: StorageManager(),
            exportFlow: flow,
            thumbnails: ThumbnailService(),
            subtitleWorkflow: workflow
        )
        try await runner.run(
            jobID: job.id,
            context: subtitlesPipelineContext(box: box, flow: flow)
        )
        job = try #require(await box.value())
        #expect(job.state == .completed)
        #expect(job.effectiveOutputIdentity == .subtitlesOnly)
        #expect(job.outputURL == nil)
        #expect(job.outputProbe == nil)
        #expect(job.selectedFormatIDs.isEmpty)
        #expect(job.subtitleSidecars?.count == 1)
        let output = try #require(job.subtitleSidecars?.first?.localURL)
        #expect(output.pathExtension == "vtt")
        #expect(try Data(contentsOf: output) == subtitlesOnlyVTT)
        #expect(await resolver.callCount == 0)
        #expect(await downloader.downloadCount == 0)
        #expect(await downloader.networkPolicyCount == 0)
        #expect(await processor.processCount == 0)
        #expect(await processor.probeCount == 0)
        #expect(await transport.callCount == 1)

        var SRTConfiguration = subtitlesOnlyConfiguration(delivery: .sidecarSRT)
        SRTConfiguration.subtitleSelections = [subtitlesOnlyAutomatic]
        SRTConfiguration = OutputCapabilityMatrix.normalized(SRTConfiguration)
        let SRTJob = subtitlesOnlyJob(configuration: SRTConfiguration)
        let SRTBox = SubtitlesJobBox(SRTJob)
        try await runner.run(
            jobID: SRTJob.id,
            context: subtitlesPipelineContext(box: SRTBox, flow: flow)
        )
        let completedSRT = try #require(await SRTBox.value())
        let SRTURL = try #require(completedSRT.subtitleSidecars?.first?.localURL)
        #expect(SRTURL.pathExtension == "srt")
        #expect(
            String(decoding: try Data(contentsOf: SRTURL), as: UTF8.self)
                .contains("00:00:00,000 --> 00:00:01,000")
        )
        #expect(await resolver.callCount == 0)
        #expect(await downloader.downloadCount == 0)
        #expect(await processor.processCount == 0)
    }

    @Test
    func IllucetFilesAndSharePublishCompleteFileSets() async throws {
        let root = try temporaryDirectory("Destinations")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try writePreparedSubtitles(in: root)

        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let documentsExporter = ExportManager(documentsRootURL: documents)
        let documentsFlow = exportFlow(documentsExporter, root: root)
        let documentsJob = subtitlesOnlyJob(
            configuration: subtitlesOnlyConfiguration(destination: .appDocuments)
        )
        let documentsResult = try await documentsFlow.exportSubtitlesOnly(
            prepared: sources,
            filenames: standaloneNames(sources),
            duplicateHandling: .overwrite,
            job: documentsJob,
            folderBookmark: nil
        )
        #expect(documentsResult.result.fileURL == nil)
        #expect(documentsResult.records.count == 2)
        #expect(documentsResult.records.allSatisfy {
            $0.localURL.map { FileManager.default.fileExists(atPath: $0.path) }
                == true
        })

        let files = root.appending(path: "Files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let filesExporter = ExportManager(documentsRootURL: documents)
        let bookmark = try await filesExporter.bookmark(for: files)
        let filesResult = try await exportFlow(filesExporter, root: root)
            .exportSubtitlesOnly(
                prepared: sources,
                filenames: standaloneNames(sources),
                duplicateHandling: .overwrite,
                job: subtitlesOnlyJob(
                    configuration: subtitlesOnlyConfiguration(destination: .filesFolder)
                ),
                folderBookmark: bookmark
            )
        #expect(filesResult.records.count == 2)
        #expect(filesResult.records.allSatisfy {
            $0.localURL?.deletingLastPathComponent().standardizedFileURL
                == files.standardizedFileURL
        })

        let shareRoot = root.appending(path: "Shares", directoryHint: .isDirectory)
        let shareExporter = ExportManager(
            documentsRootURL: documents,
            shareRootURL: shareRoot
        )
        let shareJob = subtitlesOnlyJob(
            configuration: subtitlesOnlyConfiguration(destination: .share)
        )
        let shareResult = try await exportFlow(shareExporter, root: root)
            .exportSubtitlesOnly(
                prepared: sources,
                filenames: standaloneNames(sources),
                duplicateHandling: .ask,
                job: shareJob,
                folderBookmark: nil
            )
        #expect(shareResult.result.fileURL == nil)
        #expect(shareResult.result.shareRequest?.fileURLs.count == 2)
        #expect(Set(shareResult.result.shareRequest?.fileURLs.map(\.pathExtension) ?? []) == [
            "vtt", "srt",
        ])
        try await shareExporter.finishShare(jobID: shareJob.id, state: .completed)
        #expect(await shareExporter.pendingShareRequest(jobID: shareJob.id, title: shareJob.title) == nil)
    }

    @Test
    func duplicateSkipOverwriteNumberAndVideoIDStayAtomic() async throws {
        for handling in [
            DuplicateHandling.skip,
            .overwrite,
            .addNumber,
            .addVideoID,
        ] {
            let root = try temporaryDirectory("Duplicate-\(handling.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let sources = try writePreparedSubtitles(in: root)
            let names = standaloneNames(sources)
            for name in names {
                try Data("existing".utf8).write(
                    to: documents.appending(path: name)
                )
            }
            let exporter = ExportManager(documentsRootURL: documents)
            let result = try await exportFlow(exporter, root: root)
                .exportSubtitlesOnly(
                    prepared: sources,
                    filenames: names,
                    duplicateHandling: handling,
                    job: subtitlesOnlyJob(),
                    folderBookmark: nil
                )
            if handling == .skip {
                #expect(result.result.outcome == .duplicateSkipped)
                #expect(result.records.isEmpty)
                for name in names {
                    #expect(try Data(contentsOf: documents.appending(path: name)) == Data("existing".utf8))
                }
            } else {
                #expect(result.records.count == 2)
                #expect(result.records.allSatisfy {
                    $0.localURL.map { FileManager.default.fileExists(atPath: $0.path) }
                        == true
                })
                if handling == .overwrite {
                    #expect(result.records.map(\.filename) == names)
                } else if handling == .addNumber {
                    #expect(result.records.allSatisfy { $0.filename.contains(" 2.") })
                } else {
                    #expect(result.records.allSatisfy { $0.filename.contains("-dQw4w9WgXcQ") })
                }
            }
            #expect(try hiddenTransactionFiles(in: documents).isEmpty)
        }
    }

    @Test
    func duplicateAskCancelAndLaterFailurePublishNoPartialSet() async throws {
        let root = try temporaryDirectory("AskRollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let sources = try writePreparedSubtitles(in: root)
        let names = standaloneNames(sources)
        for name in names {
            try Data("existing-\(name)".utf8).write(
                to: documents.appending(path: name)
            )
        }
        let recorder = SubtitleExportEventRecorder()
        let askExporter = ExportManager(documentsRootURL: documents)
        let askFlow = DownloadExportFlow(
            exporter: askExporter,
            diagnostics: DiagnosticStore(rootURL: root.appending(path: "AskDiagnostics")),
            notifications: UserNotificationService(),
            eventSink: recorder.record
        )
        let job = subtitlesOnlyJob()
        let askTask = Task {
            try await askFlow.exportSubtitlesOnly(
                prepared: sources,
                filenames: names,
                duplicateHandling: .ask,
                job: job,
                folderBookmark: nil
            )
        }
        let conflict = try await recorder.waitForConflict(jobID: job.id)
        await askFlow.resolveDuplicate(requestID: conflict.id, handling: nil)
        await #expect(throws: CancellationError.self) {
            try await askTask.value
        }
        for name in names {
            #expect(
                try Data(contentsOf: documents.appending(path: name))
                    == Data("existing-\(name)".utf8)
            )
        }

        let failingExporter = ExportManager(
            documentsRootURL: documents,
            transactionObserver: { event in
                if event == .didCommit(0) {
                    throw SubtitleTestFailure.injectedTransactionFailure
                }
            }
        )
        await #expect(throws: SubtitleTestFailure.self) {
            try await exportFlow(failingExporter, root: root)
                .exportSubtitlesOnly(
                    prepared: sources,
                    filenames: names,
                    duplicateHandling: .overwrite,
                    job: subtitlesOnlyJob(),
                    folderBookmark: nil
                )
        }
        for name in names {
            #expect(
                try Data(contentsOf: documents.appending(path: name))
                    == Data("existing-\(name)".utf8)
            )
        }
        #expect(try hiddenTransactionFiles(in: documents).isEmpty)
    }

    @Test
    func lifecycleIdentityRetryAndHistoryOwnEverySubtitleFile() throws {
        var job = subtitlesOnlyJob()
        let first = URL(filePath: "/tmp/first.vtt")
        let second = URL(filePath: "/tmp/second.srt")
        job.subtitleSidecars = [
            SubtitleSidecarRecord(
                selection: subtitlesOnlyManual,
                kind: .webVTT,
                filename: first.lastPathComponent,
                localURL: first
            ),
            SubtitleSidecarRecord(
                selection: subtitlesOnlyAutomatic,
                kind: .subRip,
                filename: second.lastPathComponent,
                localURL: second
            ),
        ]
        for state in [
            DownloadJobState.queued,
            .running,
            .failed,
            .cancelled,
            .completed,
        ] {
            job.state = state
            #expect(job.effectiveOutputIdentity == .subtitlesOnly)
            let history = HistoryRecord(job: job)
            #expect(history.effectiveOutputIdentity == .subtitlesOnly)
            #expect(history.ownedFileURLs == [first, second])
            #expect(history.fileURL == nil)
            #expect(history.probe == nil)
        }
        let data = try JSONEncoder.illucetEncoder.encode(job)
        let restored = try JSONDecoder.illucetDecoder.decode(
            DownloadJob.self,
            from: data
        )
        #expect(restored.configuration == job.configuration)
        #expect(restored.configuration.subtitleSelections == [
            subtitlesOnlyManual,
            subtitlesOnlyAutomatic,
        ])
        #expect(restored.effectiveOutputIdentity == .subtitlesOnly)
    }
}

private func subtitlesOnlyConfiguration(
    delivery: SubtitleDelivery = .sidecarVTT,
    destination: ExportDestination = .appDocuments
) -> DownloadConfiguration {
    var configuration = DownloadConfiguration.standard
    configuration.requestKind = .subtitlesOnly
    configuration.subtitleDelivery = delivery
    configuration.subtitleSelections = [
        subtitlesOnlyManual,
        subtitlesOnlyAutomatic,
    ]
    configuration.destination = destination
    return OutputCapabilityMatrix.normalized(configuration)
}

private func subtitlesOnlyJob(
    configuration: DownloadConfiguration = subtitlesOnlyConfiguration()
) -> DownloadJob {
    DownloadJob(
        id: UUID(),
        sourceURL: DeveloperFixtures.media.canonicalURL,
        videoID: DeveloperFixtures.media.videoID,
        title: "Subtitle Fixture",
        channel: "Fixture",
        thumbnailURL: nil,
        createdAt: .now,
        updatedAt: .now,
        configuration: configuration,
        state: .queued,
        stage: .waiting,
        progress: .zero,
        priority: 0,
        retryCount: 0,
        maximumRetries: 1,
        errorCode: nil,
        errorMessage: nil,
        outputURL: nil,
        outputProbe: nil,
        selectedFormatIDs: [],
        extractorVersion: "fixture"
    )
}

private func preparedSubtitles(
    at root: URL
) -> [PreparedSubtitleSidecar] {
    [
        PreparedSubtitleSidecar(
            selection: subtitlesOnlyManual,
            kind: .webVTT,
            temporaryURL: root.appending(path: "manual.vtt")
        ),
        PreparedSubtitleSidecar(
            selection: subtitlesOnlyAutomatic,
            kind: .subRip,
            temporaryURL: root.appending(path: "automatic.srt")
        ),
    ]
}

private func writePreparedSubtitles(
    in root: URL
) throws -> [PreparedSubtitleSidecar] {
    let prepared = preparedSubtitles(at: root)
    try subtitlesOnlyVTT.write(to: prepared[0].temporaryURL)
    try Data(
        "1\n00:00:00,000 --> 00:00:01,000\nCaption\n".utf8
    ).write(to: prepared[1].temporaryURL)
    return prepared
}

private func standaloneNames(
    _ prepared: [PreparedSubtitleSidecar]
) -> [String] {
    try! SubtitleFilenamePlanner.filenames(
        title: "Subtitle Fixture",
        sidecars: prepared
    )
}

private func exportFlow(
    _ exporter: ExportManager,
    root: URL
) -> DownloadExportFlow {
    DownloadExportFlow(
        exporter: exporter,
        diagnostics: DiagnosticStore(rootURL: root.appending(path: "Diagnostics-\(UUID().uuidString)")),
        notifications: UserNotificationService(),
        eventSink: { _ in }
    )
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let URL = FileManager.default.temporaryDirectory.appending(
        path: "Illucet-P8-15-\(name)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: URL,
        withIntermediateDirectories: true
    )
    return URL
}

private func hiddenTransactionFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
    ).filter { $0.lastPathComponent.hasPrefix(".illucet-export-transaction-") }
}

private actor SubtitlesJobBox {
    private var job: DownloadJob?

    init(_ job: DownloadJob) {
        self.job = job
    }

    func value() -> DownloadJob? { job }

    func set(_ job: DownloadJob) {
        self.job = job
    }
}

private func subtitlesPipelineContext(
    box: SubtitlesJobBox, flow: DownloadExportFlow
) -> DownloadPipelineContext {
    DownloadPipelineContext(
        currentJob: { _ in await box.value() },
        settingsSnapshot: { .defaults },
        folderBookmarkSnapshot: { nil },
        persistJob: { await box.set($0) },
        checkpointJob: { job, _, _, _, _ in
            await box.set(job)
            return job
        },
        authorizeNetwork: { _ in true },
        streamNetworkPolicy: { _ in .unrestricted },
        acquireTransferPermit: { _ in },
        releaseTransferPermit: { _ in },
        acquireProcessingPermit: { _ in },
        releaseProcessingPermit: { _ in },
        recordTransferProgress: { _, _, _ in },
        recordProcessingProgress: { _, _, _ in },
        persistPublication: { job in await box.set(job); return job },
        publishOutput: { job, plan, root in
            try await DownloadPublicationWorkflow(exportFlow: flow).run(job: job, plan: plan, root: root,
                context: subtitlesPipelineContext(box: box, flow: flow))
        },
        completeDuplicateSkip: { job in
            var completed = job
            completed.state = .completed
            completed.stage = .complete
            completed.exportOutcome = .duplicateSkipped
            await box.set(completed)
            return completed
        },
        checkpointExport: { job, probe, result in
            var checkpoint = job
            checkpoint.outputURL = result.fileURL
            checkpoint.outputProbe = probe
            checkpoint.exportOutcome = result.outcome
            checkpoint.shareCompletionState = result.shareRequest == nil
                ? nil
                : .pending
            await box.set(checkpoint)
            return checkpoint
        },
        checkpointPartialFile: { job, URL, probe in
            var checkpoint = job
            checkpoint.outputURL = URL
            checkpoint.outputProbe = probe
            await box.set(checkpoint)
            return checkpoint
        },
        completeExport: { job, probe, result, _, shareRequest, temporaryRoot in
            var completed = job
            try? FileManager.default.removeItem(at: temporaryRoot)
            completed.outputURL = result.fileURL
            completed.outputProbe = probe
            completed.exportOutcome = result.outcome
            completed.shareCompletionState = shareRequest == nil ? nil : .pending
            completed.state = .completed
            completed.stage = .complete
            completed.progress.overallFraction = 1
            await box.set(completed)
            return completed
        }
    )
}

private final class SubtitlesExtractor: ExtractorEngine, @unchecked Sendable {
    let metadata: MediaMetadata

    init(_ metadata: MediaMetadata) {
        self.metadata = metadata
    }

    func versions() async throws -> ExtractorVersions {
        ExtractorVersions(python: "fixture", ytDLP: "fixture", ejs: "fixture")
    }

    func analyze(url: URL) async throws -> MediaMetadata { metadata }
    func cancel(requestID: UInt64) {}
}

private actor SubtitlesRuntime: RuntimeProviding {
    let extractor: any ExtractorEngine
    let resolver: any StreamResolver

    init(extractor: any ExtractorEngine, resolver: any StreamResolver) {
        self.extractor = extractor
        self.resolver = resolver
    }

    func makeExtractor() async throws -> any ExtractorEngine { extractor }
    func makeResolver() async throws -> any StreamResolver { resolver }
}

private actor CountingSubtitlesResolver: StreamResolver {
    private(set) var callCount = 0

    func resolve(
        url: URL,
        formatIDs: [String]
    ) async throws -> ResolvedStreamSet {
        callCount += 1
        throw SubtitleTestFailure.mediaOwnershipTouched
    }
}

private actor CountingSubtitlesDownloader: StreamDownloading {
    private(set) var downloadCount = 0
    private(set) var networkPolicyCount = 0

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        downloadCount += 1
        throw SubtitleTestFailure.mediaOwnershipTouched
    }

    func setNetworkPolicy(
        _ policy: StreamTransferNetworkPolicy,
        jobID: UUID
    ) async {
        networkPolicyCount += 1
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

private actor CountingSubtitlesProcessor: MediaProcessor {
    private(set) var processCount = 0
    private(set) var probeCount = 0

    func process(
        _ request: MediaProcessingRequest,
        progress: @escaping MediaProcessingProgressHandler
    ) async throws -> MediaProcessingResult {
        processCount += 1
        throw SubtitleTestFailure.mediaOwnershipTouched
    }

    func probe(
        _ fileURL: URL,
        verificationClass: MediaVerificationClass
    ) async throws -> MediaProbeResult {
        probeCount += 1
        throw SubtitleTestFailure.mediaOwnershipTouched
    }

    func cancel(operationID: UUID) async {}
}

private struct SubtitlesPlaybackVerifier: ApplePlaybackVerifying {
    func verify(fileURL: URL) async throws -> ApplePlaybackVerification {
        throw SubtitleTestFailure.mediaOwnershipTouched
    }
}

private actor CountingSubtitleTransport: SubtitleTransporting {
    private var results: [Data]
    private(set) var callCount = 0

    init(_ results: [Data]) {
        self.results = results
    }

    func download(from URL: URL) async throws -> Data {
        callCount += 1
        guard !results.isEmpty else {
            throw SubtitlePipelineError.HTTPFailure
        }
        return results.removeFirst()
    }
}

private final class SubtitleExportEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var conflicts: [DuplicateConflict] = []

    func record(_ event: DownloadCoordinatorEvent) {
        guard case let .requestDuplicate(conflict) = event else { return }
        lock.withLock { conflicts.append(conflict) }
    }

    func waitForConflict(jobID: UUID) async throws -> DuplicateConflict {
        for _ in 0..<200 {
            if let conflict = lock.withLock({
                conflicts.first(where: { $0.jobID == jobID })
            }) {
                return conflict
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SubtitleTestFailure.timeout
    }
}

private enum SubtitleTestFailure: Error {
    case mediaOwnershipTouched
    case injectedTransactionFailure
    case timeout
}
