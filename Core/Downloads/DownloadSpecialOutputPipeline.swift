import Foundation

/// Sequences output modes that intentionally bypass media resolution and
/// FFmpeg processing while retaining the durable pipeline callbacks.
final class DownloadSpecialOutputPipeline: @unchecked Sendable {
    private let downloader: any StreamDownloading
    private let aria2Downloader: any Aria2Downloading
    private let diagnostics: DiagnosticStore?
    private let storage: StorageManager
    private let exportFlow: DownloadExportFlow
    private let thumbnails: ThumbnailService
    private let subtitleWorkflow: SubtitleSidecarWorkflow
    private let fileManager: FileManager

    init(
        downloader: any StreamDownloading,
        storage: StorageManager,
        exportFlow: DownloadExportFlow,
        thumbnails: ThumbnailService,
        subtitleWorkflow: SubtitleSidecarWorkflow,
        fileManager: FileManager,
        aria2Downloader: any Aria2Downloading = NativeAria2Downloader.shared,
        diagnostics: DiagnosticStore? = nil
    ) {
        self.downloader = downloader
        self.aria2Downloader = aria2Downloader
        self.diagnostics = diagnostics
        self.storage = storage
        self.exportFlow = exportFlow
        self.thumbnails = thumbnails
        self.subtitleWorkflow = subtitleWorkflow
        self.fileManager = fileManager
    }

    func runSubtitlesOnly(
        job initialJob: DownloadJob,
        metadata: MediaMetadata,
        extractor: any ExtractorEngine,
        context: DownloadPipelineContext
    ) async throws -> DownloadJob {
        var job = initialJob
        let plans = try SubtitleSelectionPlanner.plans(
            configuration: job.configuration,
            metadata: metadata
        )
        let settings = await context.settingsSnapshot()
        let requiredBytes = Int64(plans.count)
            * Int64(WebVTTProcessor.maximumInputBytes * 2)
        try await storage.preflight(
            requiredBytes: requiredBytes,
            reserveBytes: settings.minimumFreeSpaceReserveBytes
        )
        job.selectedFormatIDs = []
        job.configuration.selectedVideoFormatID = nil
        job.configuration.selectedAudioFormatID = nil
        await context.persistJob(job)
        job = try await context.update(
            job,
            state: .running,
            stage: .preparing
        )
        let temporaryRoot = temporaryRoot(for: job.id)
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: BackgroundFileProtection.attributes
        )
        try BackgroundFileProtection.protect(temporaryRoot, under: temporaryRoot, fileManager: fileManager)

        var prepared: [PreparedSubtitleSidecar] = []
        defer {
            subtitleWorkflow.cleanup(prepared)
        }
        try await context.acquireTransferPermit(job.id)
        do {
            guard try await context.authorizeNetwork(job.id) else {
                throw DownloadPipelineControl.deferredForNetwork
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .downloadingSubtitles
            )
            job = await context.checkpoint(job, phase: .transferring)
            prepared = try await subtitleWorkflow.prepare(
                plans: plans,
                sourceURL: job.sourceURL,
                expectedVideoID: job.videoID,
                extractor: extractor,
                temporaryRoot: temporaryRoot
            )
        } catch {
            await context.releaseTransferPermit(job.id)
            throw error
        }
        await context.releaseTransferPermit(job.id)
        try Task.checkCancellation()

        let filenames = try SubtitleFilenamePlanner.filenames(
            title: metadata.title,
            sidecars: prepared
        )
        job = try await context.update(
            job,
            state: .running,
            stage: .savingFiles
        )
        job = await context.checkpoint(job, phase: .exporting)
        let items = zip(prepared, filenames).map { sidecar, name in
            ExportPublicationItem(sourceURL: sidecar.temporaryURL,
                filename: URL(filePath: name).deletingPathExtension().lastPathComponent,
                role: .subtitle, assetKind: .image, handling: settings.duplicateHandling,
                subtitle: .init(selection: sidecar.selection, kind: sidecar.kind))
        }
        let plan = ExportPublicationPlan(items: items, probe: nil,
            destination: job.configuration.destination, folderBookmark: await context.folderBookmarkSnapshot())
        return try await context.publishOutput(job, plan, temporaryRoot)
    }

    func runThumbnailOnly(
        job initialJob: DownloadJob,
        metadata: MediaMetadata,
        context: DownloadPipelineContext
    ) async throws -> DownloadJob {
        var job = initialJob
        let settings = await context.settingsSnapshot()
        try await storage.preflight(
            requiredBytes: 50 * 1_024 * 1_024,
            reserveBytes: settings.minimumFreeSpaceReserveBytes
        )
        job = try await context.update(
            job,
            state: .running,
            stage: .preparing
        )
        let temporaryRoot = temporaryRoot(for: job.id)
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: BackgroundFileProtection.attributes
        )
        try BackgroundFileProtection.protect(temporaryRoot, under: temporaryRoot, fileManager: fileManager)
        let thumbnail: URL
        try await context.acquireTransferPermit(job.id)
        do {
            guard try await context.authorizeNetwork(job.id) else {
                throw DownloadPipelineControl.deferredForNetwork
            }
            if let current = await context.currentJob(job.id) {
                await downloader.setNetworkPolicy(
                    await context.streamNetworkPolicy(current),
                    jobID: job.id
                )
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .downloadingThumbnail
            )
            job = await context.checkpoint(
                job,
                phase: .transferring
            )
            thumbnail = try await thumbnails.download(
                from: metadata.thumbnails,
                selectedID: job.configuration.thumbnailID,
                to: temporaryRoot.appending(path: "thumbnail"),
                outputFormat: job.configuration.thumbnailFormat,
                cropSquare: job.configuration.cropArtworkSquare
            )
            job = await context.checkpoint(
                job,
                phase: .sourcesReady,
                artworkURL: thumbnail
            )
        } catch {
            await context.releaseTransferPermit(job.id)
            throw error
        }
        await context.releaseTransferPermit(job.id)
        try Task.checkCancellation()

        let filename = FilenameSystem.render(
            template: job.configuration.filenameTemplate,
            metadata: metadata,
            configuration: job.configuration,
            format: nil
        )
        let duplicate = try await exportFlow.duplicateResolution(
            job: job,
            filename: filename,
            fileExtension: thumbnail.pathExtension,
            defaultHandling: settings.duplicateHandling,
            folderBookmark: await context.folderBookmarkSnapshot()
        )
        let handling: DuplicateHandling
        switch duplicate {
        case let .proceed(value):
            handling = value
        case .skip:
            try? fileManager.removeItem(at: temporaryRoot)
            return await context.completeDuplicateSkip(job)
        case .cancel:
            throw CancellationError()
        }

        job = try await context.update(
            job,
            state: .running,
            stage: job.configuration.destination == .photos
                ? .savingPhotos
                : .savingFiles
        )
        job = await context.checkpoint(
            job,
            phase: .exporting,
            artworkURL: thumbnail
        )
        job.selectedFormatIDs = []
        let item = ExportPublicationItem(sourceURL: thumbnail, filename: filename,
            role: .primary, assetKind: .image, handling: handling)
        let plan = ExportPublicationPlan(items: [item], probe: nil,
            destination: job.configuration.destination, folderBookmark: await context.folderBookmarkSnapshot())
        return try await context.publishOutput(job, plan, temporaryRoot)
    }

    func runImage(job initialJob: DownloadJob, metadata: MediaMetadata,
                  runtime: any ExternalMediaProviding, context: DownloadPipelineContext) async throws -> DownloadJob {
        var job = initialJob
        try OutputCapabilityMatrix.validate(job.configuration, metadata: metadata)
        let root = temporaryRoot(for: job.id)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: BackgroundFileProtection.attributes)
        try BackgroundFileProtection.protect(root, under: root, fileManager: fileManager)
        let source = try await runtime.externalSource(url: job.sourceURL, configuration: job.configuration,
                                                      formatID: DownloadConfiguration.originalImageFormatID)
        guard ["http", "https"].contains(source.protocolName) else { throw StreamResolutionError.unsupportedProtocol(source.protocolName) }
        let settings = await context.settingsSnapshot()
        if let bytes = source.expectedBytes { try await storage.preflight(requiredBytes: bytes, reserveBytes: settings.minimumFreeSpaceReserveBytes) }
        let extensionValue = source.fileExtension?.lowercased() ?? "image"
        guard ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "image"].contains(extensionValue) else { throw StreamResolutionError.invalidResponse }
        let destination = root.appending(path: "image.\(extensionValue)")
        try await context.acquireTransferPermit(job.id)
        let downloaded: URL
        do {
            guard try await context.authorizeNetwork(job.id) else { throw DownloadPipelineControl.deferredForNetwork }
            if let current = await context.currentJob(job.id) {
                await downloader.setNetworkPolicy(await context.streamNetworkPolicy(current), jobID: job.id)
            }
            job = try await context.update(job, state: .running, stage: .downloadingThumbnail)
            job = await context.checkpoint(job, phase: .transferring)
            if let file = try await Aria2TransferPolicy.downloadIfSelected(source.stream, job: job, destination: destination,
                expectedBytes: source.expectedBytes, baseBytes: 0, combinedExpectedBytes: source.expectedBytes,
                downloader: aria2Downloader, context: context, diagnostics: diagnostics) {
                downloaded = file
            } else {
                let result = try await downloader.download(source.stream, jobID: job.id, destinationURL: destination,
                    verifiedExpectedBytes: source.expectedBytes) { progress in
                    Task { await context.recordTransferProgress(progress, 0, source.expectedBytes) }
                }
                downloaded = result.fileURL
            }
        } catch {
            await context.releaseTransferPermit(job.id)
            throw error
        }
        await context.releaseTransferPermit(job.id)
        try Task.checkCancellation()
        try await context.requireExecution(job.id)
        let removeMetadata = job.configuration.enginePreferences?.removeImageMetadata == true
        try await context.acquireProcessingPermit(job.id)
        let image: URL
        do {
            job = try await context.update(job, state: .running, stage: .verifyingSources)
            let processing = Task.detached {
                try NativeImageProcessor.verifyContent(downloaded, expectedSHA256: source.expectedSHA256)
                return try NativeImageProcessor.prepare(downloaded, removeMetadata: removeMetadata, directory: root)
            }
            image = try await withTaskCancellationHandler {
                try await processing.value
            } onCancel: {
                processing.cancel()
            }
        } catch {
            await context.releaseProcessingPermit(job.id)
            throw error
        }
        await context.releaseProcessingPermit(job.id)
        try Task.checkCancellation()
        try await context.requireExecution(job.id)
        let filename = FilenameSystem.render(template: job.configuration.filenameTemplate,
            metadata: metadata, configuration: job.configuration, format: nil)
        let handling: DuplicateHandling
        switch try await exportFlow.duplicateResolution(job: job, filename: filename,
            fileExtension: image.pathExtension, defaultHandling: job.configuration.duplicateHandlingOverride ?? settings.duplicateHandling,
            folderBookmark: await context.folderBookmarkSnapshot()) {
        case let .proceed(value): handling = value
        case .skip: return await context.completeDuplicateSkip(job)
        case .cancel: throw CancellationError()
        }
        job = await context.checkpoint(job, phase: .sourcesReady, artworkURL: image)
        let plan = ExportPublicationPlan(items: [.init(sourceURL: image, filename: filename, role: .primary,
            assetKind: .image, handling: handling)], probe: nil, destination: job.configuration.destination,
            folderBookmark: await context.folderBookmarkSnapshot())
        return try await context.publishOutput(job, plan, root)
    }

    private func temporaryRoot(for jobID: UUID) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "Illucet-\(jobID.uuidString)",
            directoryHint: .isDirectory
        )
    }
}
