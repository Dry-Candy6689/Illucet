import Foundation

/// Executes one durable media pipeline. The coordinator supplies state and
/// network callbacks, while this component owns the ordered analyze → resolve
/// → transfer → process → verify → export sequence.
final class DownloadPipelineRunner: @unchecked Sendable {
    let runtime: any RuntimeProviding
    private let downloader: any StreamDownloading
    let DASHDownloader: (any DASHFragmentDownloading)?
    let DASHAssembler: (any DASHLocalStreamAssembling)?
    let HLSDownloader: (any HLSResourceDownloading)?
    let HLSAssembler: (any HLSLocalStreamAssembling)?
    private let mediaProcessor: any MediaProcessor
    private let conversionWorkflow: DownloadConversionWorkflow
    private let playbackVerifier: any ApplePlaybackVerifying
    private let storage: StorageManager
    private let exportFlow: DownloadExportFlow
    private let thumbnails: ThumbnailService
    private let subtitleWorkflow: SubtitleSidecarWorkflow
    private let subtitleEmbeddingWorkflow: SubtitleEmbeddingWorkflow
    private let subtitleBurnInWorkflow: SubtitleBurnInWorkflow
    private let chapterWorkflow: ChapterWorkflow
    private let trimWorkflow: ManualTrimWorkflow
    private let sponsorBlockWorkflow: SponsorBlockExecutionWorkflow
    private let chapterSplitWorkflow: ChapterSplitWorkflow
    private let specialOutputPipeline: DownloadSpecialOutputPipeline
    private let finalizer: DownloadPipelineFinalizer
    let diagnostics: DiagnosticStore?
    private let sponsorBlockDiagnostics: SponsorBlockDiagnosticLogger?
    let fileManager: FileManager

    init(
        runtime: any RuntimeProviding,
        downloader: any StreamDownloading,
        DASHDownloader: (any DASHFragmentDownloading)? = nil,
        DASHAssembler: (any DASHLocalStreamAssembling)? = nil,
        HLSDownloader: (any HLSResourceDownloading)? = nil,
        HLSAssembler: (any HLSLocalStreamAssembling)? = nil,
        mediaProcessor: any MediaProcessor,
        playbackVerifier: any ApplePlaybackVerifying,
        storage: StorageManager,
        exportFlow: DownloadExportFlow,
        thumbnails: ThumbnailService,
        subtitleWorkflow: SubtitleSidecarWorkflow? = nil,
        diagnostics: DiagnosticStore? = nil,
        sponsorBlockDiagnostics: SponsorBlockDiagnosticLogger? = nil,
        fileManager: FileManager = .default
    ) {
        self.runtime = runtime
        self.downloader = downloader
        self.DASHDownloader = DASHDownloader
        self.DASHAssembler = DASHAssembler
        self.HLSDownloader = HLSDownloader
        self.HLSAssembler = HLSAssembler
        self.mediaProcessor = mediaProcessor
        conversionWorkflow = DownloadConversionWorkflow(
            mediaProcessor: mediaProcessor
        )
        self.playbackVerifier = playbackVerifier
        self.storage = storage
        self.exportFlow = exportFlow
        self.thumbnails = thumbnails
        let activeSubtitleWorkflow = subtitleWorkflow ?? .live(
            exporter: exportFlow.exportManager,
            fileManager: fileManager
        )
        self.subtitleWorkflow = activeSubtitleWorkflow
        subtitleEmbeddingWorkflow = SubtitleEmbeddingWorkflow(
            mediaProcessor: mediaProcessor
        )
        subtitleBurnInWorkflow = SubtitleBurnInWorkflow(
            mediaProcessor: mediaProcessor,
            diagnostics: diagnostics
        )
        chapterWorkflow = ChapterWorkflow(mediaProcessor: mediaProcessor)
        trimWorkflow = ManualTrimWorkflow(mediaProcessor: mediaProcessor)
        sponsorBlockWorkflow = SponsorBlockExecutionWorkflow(
            mediaProcessor: mediaProcessor
        )
        chapterSplitWorkflow = ChapterSplitWorkflow(
            mediaProcessor: mediaProcessor,
            fileManager: fileManager
        )
        specialOutputPipeline = DownloadSpecialOutputPipeline(
            downloader: downloader,
            storage: storage,
            exportFlow: exportFlow,
            thumbnails: thumbnails,
            subtitleWorkflow: activeSubtitleWorkflow,
            fileManager: fileManager
        )
        finalizer = DownloadPipelineFinalizer(
            exportFlow: exportFlow,
            subtitleWorkflow: activeSubtitleWorkflow,
            packageWorkflow: MediaPackageWorkflow(fileManager: fileManager),
            fileManager: fileManager
        )
        self.diagnostics = diagnostics
        self.sponsorBlockDiagnostics = sponsorBlockDiagnostics
        self.fileManager = fileManager
    }

    func run(
        jobID: UUID,
        context: DownloadPipelineContext
    ) async throws {
        guard var job = await context.currentJob(jobID) else { return }
        if job.state == .completed { return }
        if let plan = job.pipelineCheckpoint?.publicationPlan {
            _ = try await context.publishOutput(job, plan, temporaryRoot(for: jobID))
            return
        }
        let playbackCheckpoint = job.pipelineCheckpoint?.phase == .awaitingPlaybackVerification
            ? job.pipelineCheckpoint : nil
        // Capture before analysis/transfer checkpoints change the phase.
        let retainedCheckpoint = job.pipelineCheckpoint
        let retainedOutput = (retainedCheckpoint?.sponsorBlockEditVerified == true
            ? retainedCheckpoint?.processedFileURL
            : retainedCheckpoint?.baseProcessedFileURL ?? playbackCheckpoint?.processedFileURL).flatMap {
            reusableSourceFile($0, expectedBytes: nil, allowedRoot: temporaryRoot(for: jobID))
        }
        let retainedFormatIDs = job.selectedFormatIDs
        let mayReuseRecentAnalysis = job.retryCount == 0
            && (job.pipelineCheckpoint == nil || job.pipelineCheckpoint?.phase == .queued)
        let initialSettings = await context.settingsSnapshot()
        let limiter = (downloader as? StreamDownloadService)?.bandwidthLimiter
        limiter?.configure(global: initialSettings.downloadSpeedLimitBytesPerSecond,
            jobID: jobID, perJob: job.configuration.speedLimitBytesPerSecond)
        defer { limiter?.finish(jobID: jobID) }
        job = try await context.update(
            job,
            state: .running,
            stage: .analyzing
        )
        job = await context.checkpoint(job, phase: .analyzing)
        let extractor = try await runtime.makeExtractor(accountID: job.configuration.accountID)
        let analysis = try await extractor.analyzeForDownload(
            url: job.sourceURL, allowRecent: mayReuseRecentAnalysis
        )
        let metadata = analysis.metadata
        try Task.checkCancellation()
        guard metadata.videoID == job.videoID else {
            throw MediaProcessorError.verificationMismatch(
                "The reanalyzed media identity changed."
            )
        }
        if job.configuration.isSubtitlesOnly {
            try OutputCapabilityMatrix.validate(
                job.configuration,
                metadata: metadata
            )
            _ = try await specialOutputPipeline.runSubtitlesOnly(
                job: job,
                metadata: metadata,
                extractor: extractor,
                context: context
            )
            return
        }
        if job.configuration.thumbnailBehavior == .thumbnailOnly {
            try OutputCapabilityMatrix.validate(
                job.configuration,
                metadata: metadata
            )
            _ = try await specialOutputPipeline.runThumbnailOnly(
                job: job,
                metadata: metadata,
                context: context
            )
            return
        }
        if job.configuration.shouldRefreshAutomaticFormatSelection && playbackCheckpoint == nil
            && retainedCheckpoint?.baseProcessedFileURL == nil && retainedOutput == nil
            && (job.transferRecoveryCount ?? 0) == 0 {
            FormatSelection.applyAutomaticSelection(
                to: &job.configuration,
                metadata: metadata
            )
            job.selectedFormatIDs = job.configuration.selectedFormatIDs
            await context.persistJob(job)
        }
        guard !job.selectedFormatIDs.isEmpty else {
            throw IllucetError.noCompatibleFormat
        }
        try OutputCapabilityMatrix.validate(
            job.configuration,
            metadata: metadata
        )
        let subtitlePlans = try SubtitleSelectionPlanner.plans(
            configuration: job.configuration,
            metadata: metadata
        )
        let outputPlan = try OutputCapabilityMatrix.makePlan(
            configuration: job.configuration,
            metadata: metadata
        )
        let sponsorBlockPlan = try SponsorBlockPlanner.validateLaunch(
            policy: job.configuration.sponsorBlock,
            videoID: metadata.videoID,
            analyzedDuration: metadata.durationSeconds
        )
        if job.sponsorBlockApplication == nil,
           job.configuration.sponsorBlock.needsSegmentReview {
            job.sponsorBlockApplication = job.configuration.sponsorBlock
                .lookupUnavailable
                ? .fallback(
                    mode: job.configuration.sponsorBlock.removalMode,
                    reason: .lookupUnavailable
                )
                : .requested(
                    plan: sponsorBlockPlan,
                    mode: job.configuration.sponsorBlock.removalMode
                )
            await context.persistJob(job)
        }
        try SponsorBlockExecutionSupport.validate(
            plan: sponsorBlockPlan,
            policy: job.configuration.sponsorBlock,
            configuration: job.configuration,
            outputPlan: outputPlan
        )
        let selectedFormat = metadata.formats.first {
            job.selectedFormatIDs.contains($0.formatID)
        }
        let filename = FilenameSystem.render(
            template: job.configuration.filenameTemplate,
            metadata: metadata,
            configuration: job.configuration,
            format: selectedFormat
        )
        let duplicateSettings = await context.settingsSnapshot()
        let primaryDuplicateHandling: DuplicateHandling
        if [.packageFolder, .zip].contains(job.configuration.bundleStyle) {
            primaryDuplicateHandling = duplicateSettings.duplicateHandling
        } else {
            let primaryDuplicate = try await exportFlow.duplicateResolution(
                job: job,
                filename: filename,
                fileExtension: outputPlan.fileExtension,
                defaultHandling: duplicateSettings.duplicateHandling,
                folderBookmark: await context.folderBookmarkSnapshot()
            )
            switch primaryDuplicate {
            case let .proceed(handling):
                primaryDuplicateHandling = handling
            case .skip:
                _ = await context.completeDuplicateSkip(job)
                return
            case .cancel:
                throw CancellationError()
            }
        }

        if let required = FormatSelection.estimatedTemporaryBytes(
            configuration: job.configuration,
            metadata: metadata
        ) {
            let settings = await context.settingsSnapshot()
            try await storage.preflight(
                requiredBytes: required,
                reserveBytes: settings.minimumFreeSpaceReserveBytes
            )
        }

        job = try await context.update(
            job,
            state: .running,
            stage: .preparing
        )
        let selectedSources = try FormatSelection.selectedSourceFacts(
            configuration: job.configuration,
            metadata: metadata
        )
        let resolvedSources = try await resolveSources(
            selectedSources,
            sourceURL: job.sourceURL,
            expectedVideoID: job.videoID,
            accountID: job.configuration.accountID,
            reuseToken: analysis.reuseToken
        )
        var exactExpectedBytesByFormatID: [String: Int64] = [:]
        for format in metadata.formats {
            if let exactBytes = format.exactFileSizeBytes {
                exactExpectedBytesByFormatID[format.formatID] = exactBytes
            }
        }
        let temporaryRoot = temporaryRoot(for: job.id)
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: BackgroundFileProtection.attributes
        )
        try BackgroundFileProtection.protect(temporaryRoot, under: temporaryRoot, fileManager: fileManager)
        job = await context.checkpoint(job, phase: .streamsResolved)
        let expectedTotal = resolvedSources.compactMap(\.expectedBytes)
        let knownExpectedTotal = expectedTotal.count == resolvedSources.count
            ? exactSum(expectedTotal)
            : nil
        job.progress.totalBytes = knownExpectedTotal
        await context.persistJob(job)

        var localFiles: [String: URL] = [:]
        var reusedFormatIDs: Set<String> = []
        var completedBytes: Int64 = 0
        let checkpointSources =
            job.pipelineCheckpoint?.sourceFiles ?? [:]

        try await context.acquireTransferPermit(jobID)
        do {
            guard try await context.authorizeNetwork(jobID) else {
                throw DownloadPipelineControl.deferredForNetwork
            }
            if let current = await context.currentJob(jobID) {
                await downloader.setNetworkPolicy(
                    await context.streamNetworkPolicy(current),
                    jobID: jobID
                )
            }
            job = await context.checkpoint(
                job,
                phase: .transferring,
                sourceFiles: checkpointSources
            )
            for resolvedSource in resolvedSources {
                try Task.checkCancellation()
                var transientDASHStagingURL: URL?
                var uncheckpointedDASHSourceURL: URL?
                var uncheckpointedHLSSourceURL: URL?
                var sourceWasCheckpointed = false
                defer {
                    if let transientDASHStagingURL {
                        try? fileManager.removeItem(
                            at: transientDASHStagingURL
                        )
                    }
                    if !sourceWasCheckpointed,
                       let uncheckpointedDASHSourceURL {
                        try? fileManager.removeItem(
                            at: uncheckpointedDASHSourceURL
                        )
                    }
                    if !sourceWasCheckpointed,
                       let uncheckpointedHLSSourceURL {
                        try? fileManager.removeItem(
                            at: uncheckpointedHLSSourceURL
                        )
                    }
                }
                let selection = resolvedSource.selection
                let reliableExpectedBytes =
                    exactExpectedBytesByFormatID[selection.formatID]
                        .flatMap { exactBytes in
                            resolvedSource.expectedBytes == exactBytes
                                ? exactBytes
                                : nil
                        }
                let stage: DownloadStage = selection.hasVideo
                    ? .downloadingVideo
                    : .downloadingAudio
                job = try await context.update(
                    job,
                    state: .running,
                    stage: stage
                )
                let destination = try sourceDestination(
                    for: selection,
                    jobID: jobID,
                    temporaryRoot: temporaryRoot
                )
                let file: URL
                let reusedSource: Bool
                let transferResult: StreamDownloadResult?
                if let reusable = reusableSourceFile(
                    checkpointSources[selection.formatID] ?? destination,
                    expectedBytes: reliableExpectedBytes,
                    allowedRoot: temporaryRoot
                ) {
                    file = reusable
                    reusedSource = true
                    transferResult = nil
                    reusedFormatIDs.insert(selection.formatID)
                } else {
                    reusedSource = false
                    let baseBytes = completedBytes
                    switch resolvedSource {
                    case let .direct(_, stream):
                        let result = try await downloader.download(
                            stream,
                            jobID: jobID,
                            destinationURL: destination,
                            verifiedExpectedBytes: reliableExpectedBytes
                        ) { progress in
                            Task {
                                await context.recordTransferProgress(
                                    progress,
                                    baseBytes,
                                    knownExpectedTotal
                                )
                            }
                        }
                        file = result.fileURL
                        transferResult = result
                    case let .DASH(_, plan):
                        try await context.requireExecution(jobID)
                        let acquisition = try await acquireDASHSource(
                            plan,
                            selectedSource: selection,
                            sourceURL: job.sourceURL,
                            jobID: jobID,
                            temporaryRoot: temporaryRoot,
                            baseBytes: baseBytes,
                            combinedExpectedBytes: knownExpectedTotal,
                            context: context
                        )
                        file = acquisition.fileURL
                        transientDASHStagingURL =
                            acquisition.stagingDirectoryURL
                        uncheckpointedDASHSourceURL = acquisition.fileURL
                        transferResult = nil
                    case let .HLS(_, HLSSelection):
                        try await context.requireExecution(jobID)
                        let acquisition = try await acquireHLSSource(
                            HLSSelection,
                            selectedSource: selection,
                            sourceURL: job.sourceURL,
                            jobID: jobID,
                            temporaryRoot: temporaryRoot,
                            destinationURL: destination,
                            baseBytes: baseBytes,
                            combinedExpectedBytes: knownExpectedTotal,
                            context: context
                        )
                        file = acquisition.fileURL
                        uncheckpointedHLSSourceURL = acquisition.fileURL
                        transferResult = nil
                    }
                }
                let transferredBytes = fileSize(file)
                if let exactExpectedBytes = reliableExpectedBytes,
                   transferredBytes != exactExpectedBytes {
                    try? fileManager.removeItem(at: file)
                    throw StreamDownloadError.networkFailure
                }
                let rollingBytesPerSecond = await context.currentJob(jobID)?
                    .progress.smoothedBytesPerSecond
                await diagnostics?.record(
                    .info,
                    subsystem: "transport",
                    event: reusedSource
                        ? "stream_source_reused"
                        : "stream_transfer_completed",
                    detail: completionDiagnosticDetail(
                        for: resolvedSource,
                        actualBytes: transferredBytes,
                        rollingBytesPerSecond: rollingBytesPerSecond,
                        reusedSource: reusedSource,
                        transferResult: transferResult
                    )
                )
                localFiles[selection.formatID] = file
                await context.recordTransferProgress(
                    StreamTransferProgress(
                        jobID: jobID,
                        streamID: selection.formatID,
                        bytesWritten: 0,
                        totalBytesWritten: transferredBytes,
                        totalBytesExpected: reliableExpectedBytes,
                        instantaneousBytesPerSecond: nil,
                        verifiedReusableBytes: transferredBytes,
                        networkBytesReceived:
                            transferResult?.networkBytesReceived ?? 0
                    ),
                    completedBytes,
                    knownExpectedTotal
                )
                completedBytes += transferredBytes
                job = await context.checkpoint(
                    job,
                    phase: .transferring,
                    sourceFiles: localFiles
                )
                sourceWasCheckpointed = true
                // Once the assembled source is durably recorded, fragment copies
                // no longer provide recovery value.
                if selection.transport == .DASHFragments {
                    try (DASHDownloader as? any FragmentCheckpointManaging)?
                        .discardFragmentCheckpoints(jobID: jobID, formatID: selection.formatID)
                } else if selection.transport == .HLSResources {
                    try (HLSDownloader as? any FragmentCheckpointManaging)?
                        .discardFragmentCheckpoints(jobID: jobID, formatID: selection.formatID)
                }
            }

            var artworkURL = reusableFile(
                job.pipelineCheckpoint?.artworkURL
            )
            if job.configuration.thumbnailBehavior != .none,
               artworkURL == nil {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .downloadingThumbnail
                )
                let artwork = temporaryRoot.appending(path: "thumbnail")
                artworkURL = try await thumbnails.download(
                    from: metadata.thumbnails,
                    selectedID: job.configuration.thumbnailID,
                    to: artwork,
                    outputFormat: job.configuration.thumbnailBehavior == .includeVideoThumbnail
                        ? .jpeg : job.configuration.thumbnailFormat,
                    cropSquare: job.configuration.cropArtworkSquare
                        && job.configuration.thumbnailBehavior.embeds
                )
            }
            job = await context.checkpoint(
                job,
                phase: .sourcesReady,
                sourceFiles: localFiles,
                artworkURL: artworkURL
            )
        } catch {
            await context.releaseTransferPermit(jobID)
            throw error
        }
        await context.releaseTransferPermit(jobID)
        let artworkURL = job.pipelineCheckpoint?.artworkURL
        let acquiredSources = selectedSources.compactMap { selection in
            localFiles[selection.formatID].map {
                AcquiredMediaSource(selection: selection, fileURL: $0)
            }
        }
        guard acquiredSources.count == selectedSources.count else {
            throw IllucetError.noCompatibleFormat
        }
        let canReuseOutput = retainedOutput != nil
            && Set(retainedFormatIDs) == Set(job.selectedFormatIDs)
            && reusedFormatIDs == Set(job.selectedFormatIDs)
        if !canReuseOutput, job.pipelineCheckpoint?.sponsorBlockEditVerified == true {
            job.pipelineCheckpoint?.sponsorBlockEditVerified = false
            job.pipelineCheckpoint?.sponsorBlockChaptersVerified = false
            job.sponsorBlockApplication = .requested(plan: sponsorBlockPlan,
                mode: job.configuration.sponsorBlock.removalMode)
            await context.persistJob(job)
        }

        var processed: URL
        var probe: MediaProbeResult
        var sponsorBlockEditWasVerified =
            job.pipelineCheckpoint?.sponsorBlockEditVerified == true
        var sponsorBlockChaptersWereVerified =
            job.pipelineCheckpoint?.sponsorBlockChaptersVerified == true
        var finalTimelineChapters =
            job.pipelineCheckpoint?.sponsorBlockChapters ?? []
        var finalTimelineDuration =
            job.pipelineCheckpoint?.sponsorBlockFinalDurationSeconds
        try await context.acquireProcessingPermit(jobID)
        do {
            job = try await context.update(
                job,
                state: .running,
                stage: .verifyingSources
            )
            var sourceProbes: [String: MediaProbeResult] = [:]
            do {
                for (formatID, file) in localFiles {
                    sourceProbes[formatID] = try await mediaProcessor.probe(
                        file,
                        verificationClass: .fastStructural
                    )
                }
                try OutputCapabilityMatrix.validateSourceProbes(
                    configuration: job.configuration,
                    metadata: metadata,
                    probesByFormatID: sourceProbes
                )
            } catch {
                // Cancellation says nothing about source validity. Keep the
                // verified files for continuation rather than deleting them.
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                if case MediaProcessorError.cancelled = error { throw error }
                for formatID in reusedFormatIDs {
                    if let URL = localFiles[formatID] {
                        try? fileManager.removeItem(at: URL)
                    }
                }
                if !reusedFormatIDs.isEmpty {
                    throw StreamDownloadError.networkFailure
                }
                throw error
            }

            let processingSettings = await context.settingsSnapshot()
            if canReuseOutput, let reusable = retainedOutput {
                processed = reusable
                probe = try await mediaProcessor.probe(
                    reusable,
                    verificationClass: .fastStructural
                )
            } else {
                let output = temporaryRoot.appending(
                    path: "output-\(UUID().uuidString).\(outputPlan.fileExtension)"
                )
                job = await context.checkpoint(
                    job,
                    phase: .processing,
                    sourceFiles: localFiles,
                    artworkURL: artworkURL
                )
                let outputResult = try await conversionWorkflow.createOutput(
                    job: job,
                    metadata: metadata,
                    plan: outputPlan,
                    sources: acquiredSources,
                    artworkURL: artworkURL,
                    temporaryRoot: temporaryRoot,
                    outputURL: output,
                    settings: processingSettings,
                    context: context
                )
                job = outputResult.job
                processed = outputResult.fileURL
                probe = outputResult.probe
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .verifyingOutput
            )
            let requestBuilder = MediaConversionRequestBuilder(
                plan: outputPlan,
                configuration: job.configuration,
                metadata: metadata,
                settings: processingSettings
            )
            var finalRequirements = requestBuilder.finalVerification(
                fileURL: processed
            )
            if canReuseOutput {
                finalRequirements = finalRequirements
                    .withRequiredVerificationClass(.fastStructural)
            }
            if sponsorBlockEditWasVerified,
               let finalTimelineDuration {
                finalRequirements = finalRequirements.withExpectedDuration(
                    finalTimelineDuration,
                    tolerance: 1.0
                )
                if sponsorBlockChaptersWereVerified {
                    finalRequirements = finalRequirements
                        .withExpectedChapterCount(
                            finalTimelineChapters.count
                        )
                }
            }
            try MediaOutputVerifier.verify(
                probe,
                requirements: finalRequirements
            )
            if !sponsorBlockEditWasVerified {
                job.pipelineCheckpoint?.baseProcessedFileURL = processed
            }
            if outputPlan.requiresApplePlayback {
                // Structural/decode requirements passed. Retain this exact output
                // if iOS cannot run the final foreground playback check yet.
                job = await context.checkpoint(job, phase: .awaitingPlaybackVerification,
                    sourceFiles: localFiles, artworkURL: artworkURL, processedFileURL: processed)
                _ = try await playbackVerifier.verify(
                    fileURL: processed
                )
            }
            job = await context.checkpoint(
                job,
                phase: .outputVerified,
                sourceFiles: localFiles,
                artworkURL: artworkURL,
                processedFileURL: processed
            )
        } catch {
            await context.releaseProcessingPermit(jobID)
            throw error
        }
        await context.releaseProcessingPermit(jobID)

        let usesSponsorBlockTimeline = SponsorBlockCheckpointPlanner
            .usesTimeline(
                plan: sponsorBlockPlan,
                application: job.sponsorBlockApplication
            )
        let shouldExecuteSponsorBlock = SponsorBlockCheckpointPlanner
            .shouldExecute(
                plan: sponsorBlockPlan,
                application: job.sponsorBlockApplication,
                checkpoint: job.pipelineCheckpoint
            )
        if shouldExecuteSponsorBlock {
            await sponsorBlockDiagnostics?.record(
                event: "execution_started",
                detail: [
                    "selected_entry_count=\(sponsorBlockPlan.entries.count)",
                    "removal_entry_count=\(sponsorBlockPlan.entries.count { $0.action == .remove })",
                    "chapter_entry_count=\(sponsorBlockPlan.entries.count { $0.action == .markAsChapter })",
                    "requested_mode=\(job.configuration.sponsorBlock.removalMode.rawValue)",
                ].joined(separator: ", ")
            )
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .removingSponsorSegments
                )
                let activeJobID = job.id
                let result = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .removingSponsorSegments
                    ) { progress in
                        try await sponsorBlockWorkflow.execute(
                            mediaURL: processed,
                            inputProbe: probe,
                            sponsorPlan: sponsorBlockPlan,
                            policy: job.configuration.sponsorBlock,
                            configuration: job.configuration,
                            outputPlan: outputPlan,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            destinationURL: temporaryRoot.appending(
                                path:
                                    "output-sponsorblock-\(UUID().uuidString)."
                                    + outputPlan.fileExtension
                            ),
                            operationID: activeJobID,
                            progress: progress
                        )
                    }
                processed = result.fileURL
                probe = result.probe
                finalTimelineChapters = result.chapters
                finalTimelineDuration = result.timeline.finalDurationSeconds
                if var application = job.sponsorBlockApplication {
                    application.actualRemovalMode = result.actualMode
                    application.actualRemovalRanges =
                        result.actualRemovalRanges
                    application.removedSegmentCount = Set(
                        sponsorBlockPlan.entries
                            .filter { entry in
                                guard entry.action == .remove else {
                                    return false
                                }
                                return result.actualRemovalRanges.contains {
                                    range in
                                    min(range.endSeconds, entry.endSeconds)
                                        - max(
                                            range.startSeconds,
                                            entry.startSeconds
                                        )
                                        > SponsorBlockTimeline
                                            .boundaryTolerance
                                }
                            }
                            .flatMap(\.sourceSegmentIDs)
                    ).count
                    application.removedDurationSeconds =
                        result.actualRemovalRanges.reduce(0) {
                            $0 + $1.durationSeconds
                        }
                    application.sponsorBlockChapterCount =
                        result.sponsorBlockChapterCount
                    job.sponsorBlockApplication = application
                }
                var checkpoint = job.pipelineCheckpoint
                    ?? DownloadPipelineCheckpoint(
                        phase: .sponsorBlockVerified
                    )
                checkpoint.phase = .sponsorBlockVerified
                checkpoint.processedFileURL = processed
                checkpoint.sponsorBlockEditVerified = true
                checkpoint.sponsorBlockChaptersVerified = false
                checkpoint.sponsorBlockChapters = finalTimelineChapters
                checkpoint.sponsorBlockFinalDurationSeconds =
                    finalTimelineDuration
                checkpoint.updatedAt = .now
                job.pipelineCheckpoint = checkpoint
                job.updatedAt = .now
                await context.persistJob(job)
                sponsorBlockEditWasVerified = true
            } catch {
                await sponsorBlockDiagnostics?.record(
                    .warning,
                    event: "execution_failed",
                    detail: "classification=\(sponsorBlockExecutionFailureClassification(error))"
                )
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
            await sponsorBlockDiagnostics?.record(
                event: "execution_completed",
                detail: [
                    "actual_mode=\(job.sponsorBlockApplication?.actualRemovalMode?.rawValue ?? "none")",
                    "removed_segment_count=\(job.sponsorBlockApplication?.removedSegmentCount ?? 0)",
                    "chapter_count=\(job.sponsorBlockApplication?.sponsorBlockChapterCount ?? 0)",
                ].joined(separator: ", ")
            )
        } else if usesSponsorBlockTimeline {
            guard finalTimelineDuration != nil,
                  job.pipelineCheckpoint?.sponsorBlockChapters != nil
            else {
                throw SponsorBlockExecutionError.invalidAppliedRanges
            }
        }

        if !usesSponsorBlockTimeline,
           (job.configuration.trimStartSeconds != nil
            || job.configuration.trimEndSeconds != nil) {
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .trimming
                )
                let activeJobID = job.id
                let trimmed = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .trimming
                    ) { progress in
                        try await trimWorkflow.trim(
                            mediaURL: processed,
                            inputProbe: probe,
                            plan: outputPlan,
                            range: MediaTrimRange(
                                startSeconds:
                                    job.configuration.trimStartSeconds ?? 0,
                                endSeconds:
                                    job.configuration.trimEndSeconds
                            ),
                            mode: job.configuration.resolvedTrimMode,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            destinationURL: temporaryRoot.appending(
                                path:
                                    "output-trim-\(UUID().uuidString)."
                                    + outputPlan.fileExtension
                            ),
                            operationID: activeJobID,
                            progress: progress
                        )
                    }
                processed = trimmed.fileURL
                probe = trimmed.probe
                job = await context.checkpoint(
                    job,
                    phase: .outputVerified,
                    sourceFiles: localFiles,
                    artworkURL: artworkURL,
                    processedFileURL: processed
                )
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        var preparedSidecars: [PreparedSubtitleSidecar] = []
        if !subtitlePlans.isEmpty {
            try await context.acquireTransferPermit(jobID)
            do {
                guard try await context.authorizeNetwork(jobID) else {
                    throw DownloadPipelineControl.deferredForNetwork
                }
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .downloadingSubtitles
                )
                preparedSidecars = try await subtitleWorkflow.prepare(
                    plans: subtitlePlans,
                    sourceURL: job.sourceURL,
                    expectedVideoID: job.videoID,
                    extractor: extractor,
                    temporaryRoot: temporaryRoot
                )
            } catch {
                await context.releaseTransferPermit(jobID)
                throw error
            }
            await context.releaseTransferPermit(jobID)
        }
        defer {
            subtitleWorkflow.cleanup(preparedSidecars)
        }

        if job.configuration.subtitleDelivery == .embed {
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .embeddingSubtitles
                )
                let activeJobID = job.id
                let embedded = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .embeddingSubtitles
                    ) { progress in
                        try await subtitleEmbeddingWorkflow.embed(
                            preparedSidecars,
                            into: processed,
                            plan: outputPlan,
                            configuration: job.configuration,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            temporaryRoot: temporaryRoot,
                            operationID: activeJobID,
                            progress: progress
                        )
                    }
                processed = embedded.fileURL
                probe = embedded.probe
                job = await context.checkpoint(
                    job,
                    phase: .outputVerified,
                    sourceFiles: localFiles,
                    artworkURL: artworkURL,
                    processedFileURL: processed
                )
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        if job.configuration.subtitleDelivery == .burnIn {
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .burningInSubtitles
                )
                let activeJobID = job.id
                let burned = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .burningInSubtitles
                    ) { progress in
                        try await subtitleBurnInWorkflow.burn(
                            preparedSidecars,
                            into: processed,
                            inputProbe: probe,
                            plan: outputPlan,
                            configuration: job.configuration,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            temporaryRoot: temporaryRoot,
                            operationID: activeJobID,
                            progress: progress
                        )
                    }
                processed = burned.fileURL
                probe = burned.probe
                job = await context.checkpoint(
                    job,
                    phase: .outputVerified,
                    sourceFiles: localFiles,
                    artworkURL: artworkURL,
                    processedFileURL: processed
                )
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        let hasSponsorBlockChapters = usesSponsorBlockTimeline
            && !finalTimelineChapters.isEmpty
        let shouldWriteChapters = job.configuration.preserveChapters
            || job.configuration.writeChapters
            || hasSponsorBlockChapters
        if shouldWriteChapters,
           !job.configuration.splitChapters,
           !(usesSponsorBlockTimeline
                && sponsorBlockChaptersWereVerified) {
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .writingChapters
                )
                let activeJobID = job.id
                let written = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .writingChapters
                    ) { progress in
                        try await chapterWorkflow.write(
                            metadataChapters: metadata.chapters,
                            into: processed,
                            inputProbe: probe,
                            plan: outputPlan,
                            configuration: job.configuration,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            temporaryRoot: temporaryRoot,
                            operationID: activeJobID,
                            resolvedChapters: usesSponsorBlockTimeline
                                ? finalTimelineChapters
                                : nil,
                            expectedDurationSeconds: usesSponsorBlockTimeline
                                ? finalTimelineDuration
                                : nil,
                            progress: progress
                        )
                    }
                processed = written.fileURL
                probe = written.probe
                job = await context.checkpoint(
                    job,
                    phase: usesSponsorBlockTimeline
                        ? .chaptersVerified
                        : .outputVerified,
                    sourceFiles: localFiles,
                    artworkURL: artworkURL,
                    processedFileURL: processed
                )
                if usesSponsorBlockTimeline {
                    var checkpoint = job.pipelineCheckpoint
                        ?? DownloadPipelineCheckpoint(
                            phase: .chaptersVerified
                        )
                    checkpoint.phase = .chaptersVerified
                    checkpoint.processedFileURL = processed
                    checkpoint.sponsorBlockEditVerified = true
                    checkpoint.sponsorBlockChaptersVerified = true
                    checkpoint.sponsorBlockChapters = finalTimelineChapters
                    checkpoint.sponsorBlockFinalDurationSeconds =
                        finalTimelineDuration
                    checkpoint.updatedAt = .now
                    job.pipelineCheckpoint = checkpoint
                    job.updatedAt = .now
                    await context.persistJob(job)
                    sponsorBlockChaptersWereVerified = true
                }
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        var chapterSplits: [ChapterSplitOutput] = []
        if job.configuration.splitChapters {
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .splittingChapters
                )
                let chapters = usesSponsorBlockTimeline
                    ? finalTimelineChapters
                    : try ChapterWorkflow.normalized(
                        metadata.chapters,
                        durationSeconds: metadata.durationSeconds
                    )
                let activeJobID = job.id
                chapterSplits = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .splittingChapters
                    ) { progress in
                        try await chapterSplitWorkflow.split(
                            mediaURL: processed,
                            inputProbe: probe,
                            plan: outputPlan,
                            chapters: chapters,
                            metadata: metadata,
                            settings: await context.settingsSnapshot(),
                            temporaryRoot: temporaryRoot,
                            progress: progress
                        )
                    }
                if usesSponsorBlockTimeline {
                    var checkpoint = job.pipelineCheckpoint
                        ?? DownloadPipelineCheckpoint(
                            phase: .chaptersVerified
                        )
                    checkpoint.phase = .chaptersVerified
                    checkpoint.processedFileURL = processed
                    checkpoint.sponsorBlockEditVerified = true
                    checkpoint.sponsorBlockChaptersVerified = true
                    checkpoint.sponsorBlockChapters = finalTimelineChapters
                    checkpoint.sponsorBlockFinalDurationSeconds =
                        finalTimelineDuration
                    checkpoint.updatedAt = .now
                    job.pipelineCheckpoint = checkpoint
                    job.updatedAt = .now
                    await context.persistJob(job)
                    sponsorBlockChaptersWereVerified = true
                }
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        if usesSponsorBlockTimeline, !sponsorBlockChaptersWereVerified {
            var checkpoint = job.pipelineCheckpoint
                ?? DownloadPipelineCheckpoint(phase: .chaptersVerified)
            checkpoint.phase = .chaptersVerified
            checkpoint.processedFileURL = processed
            checkpoint.sponsorBlockEditVerified = true
            checkpoint.sponsorBlockChaptersVerified = true
            checkpoint.sponsorBlockChapters = finalTimelineChapters
            checkpoint.sponsorBlockFinalDurationSeconds =
                finalTimelineDuration
            checkpoint.updatedAt = .now
            job.pipelineCheckpoint = checkpoint
            job.updatedAt = .now
            await context.persistJob(job)
            sponsorBlockChaptersWereVerified = true
        }
        if usesSponsorBlockTimeline,
           var application = job.sponsorBlockApplication {
            application.status =
                application.removedSegmentCount > 0
                    || application.sponsorBlockChapterCount > 0
                ? .applied
                : .notApplied
            job.sponsorBlockApplication = application
            job.updatedAt = .now
            await context.persistJob(job)
        }

        if job.configuration.thumbnailBehavior == .includeVideoThumbnail {
            guard let artworkURL else { throw OutputCompatibilityError.invalidFormatSelection }
            try await context.acquireProcessingPermit(jobID)
            do {
                job = try await context.update(job, state: .running, stage: .embeddingMetadata)
                let activeJobID = job.id
                let fastStart = await context.settingsSnapshot().fastStartMP4
                let coverSource = processed
                let coverProbe = probe
                let sourceSplits = chapterSplits
                let results = try await context.reportingProcessingProgress(
                    operationID: activeJobID, expectedStage: .embeddingMetadata
                ) { progress in
                    let inputs = [(coverSource, coverProbe)] + sourceSplits.map { ($0.fileURL, $0.probe) }
                    var results: [MediaProcessingResult] = []
                    for (index, input) in inputs.enumerated() {
                        let result = try await conversionWorkflow.includeVideoThumbnail(
                            mediaURL: input.0, inputProbe: input.1, artworkURL: artworkURL,
                            destination: temporaryRoot.appending(path: "covered-\(UUID().uuidString).mp4"),
                            plan: outputPlan, operationID: activeJobID, fastStart: fastStart
                        ) { update in
                            progress(MediaProcessingProgress(
                                operationID: activeJobID, stage: update.stage,
                                completedFraction: update.completedFraction.map { (Double(index) + $0) / Double(inputs.count) },
                                processedMediaSeconds: nil, totalMediaSeconds: nil,
                                processedBytes: nil, estimatedRemainingSeconds: nil
                            ))
                        }
                        results.append(result)
                    }
                    return results
                }
                guard let coveredURL = results.first?.outputURLs.first,
                      let coveredProbe = results.first?.probes.first else { throw OutputCompatibilityError.invalidFormatSelection }
                processed = coveredURL
                probe = coveredProbe
                for index in chapterSplits.indices {
                    let split = chapterSplits[index]
                    let covered = results[index + 1]
                    guard let splitURL = covered.outputURLs.first,
                          let splitProbe = covered.probes.first else { throw OutputCompatibilityError.invalidFormatSelection }
                    chapterSplits[index] = ChapterSplitOutput(
                        chapter: split.chapter, filename: split.filename,
                        fileURL: splitURL, probe: splitProbe
                    )
                }
            } catch {
                await context.releaseProcessingPermit(jobID)
                throw error
            }
            await context.releaseProcessingPermit(jobID)
        }

        try await finalizer.finalize(
            DownloadPipelineFinalizationInput(
                job: job,
                processedFileURL: processed,
                probe: probe,
                metadata: metadata,
                filename: filename,
                primaryDuplicateHandling: primaryDuplicateHandling,
                artworkURL: artworkURL,
                preparedSidecars: preparedSidecars,
                chapterSplits: chapterSplits,
                usesSponsorBlockTimeline: usesSponsorBlockTimeline,
                finalTimelineChapters: finalTimelineChapters,
                finalTimelineDuration: finalTimelineDuration,
                localFiles: localFiles,
                temporaryRoot: temporaryRoot
            ),
            context: context
        )
    }

    private func sponsorBlockExecutionFailureClassification(
        _ error: any Error
    ) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if error is SponsorBlockExecutionError {
            return "execution_validation"
        }
        if error is MediaProcessorError {
            return "media_processing"
        }
        return "unexpected"
    }

    func reusableFile(_ URL: URL?) -> URL? {
        guard
            let URL,
            URL.isFileURL,
            fileManager.fileExists(atPath: URL.path),
            fileSize(URL) > 0
        else {
            return nil
        }
        return URL
    }

    func fileSize(_ URL: URL) -> Int64 {
        (
            try? URL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        ).map(Int64.init) ?? 0
    }

    private func temporaryRoot(for jobID: UUID) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
    }
}
