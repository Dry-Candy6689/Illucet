import Foundation

struct DownloadPipelineFinalizationInput: Sendable {
    let job: DownloadJob
    let processedFileURL: URL
    let probe: MediaProbeResult
    let metadata: MediaMetadata
    let filename: String
    let primaryDuplicateHandling: DuplicateHandling
    let artworkURL: URL?
    let preparedSidecars: [PreparedSubtitleSidecar]
    let chapterSplits: [ChapterSplitOutput]
    let usesSponsorBlockTimeline: Bool
    let finalTimelineChapters: [MediaChapter]
    let finalTimelineDuration: Double?
    let localFiles: [String: URL]
    let temporaryRoot: URL
}

/// Sequences package construction and transactional export after all media and
/// feature workflows have produced verified final artifacts.
final class DownloadPipelineFinalizer: @unchecked Sendable {
    private let exportFlow: DownloadExportFlow
    private let subtitleWorkflow: SubtitleSidecarWorkflow
    private let packageWorkflow: MediaPackageWorkflow
    private let fileManager: FileManager

    init(
        exportFlow: DownloadExportFlow,
        subtitleWorkflow: SubtitleSidecarWorkflow,
        packageWorkflow: MediaPackageWorkflow,
        fileManager: FileManager
    ) {
        self.exportFlow = exportFlow
        self.subtitleWorkflow = subtitleWorkflow
        self.packageWorkflow = packageWorkflow
        self.fileManager = fileManager
    }

    func finalize(
        _ input: DownloadPipelineFinalizationInput,
        context: DownloadPipelineContext
    ) async throws {
        var job = input.job
        let processed = input.processedFileURL
        let probe = input.probe
        let metadata = input.metadata
        let filename = input.filename
        let artworkURL = input.artworkURL
        let preparedSidecars = input.preparedSidecars
        let chapterSplits = input.chapterSplits
        let temporaryRoot = input.temporaryRoot

        if [.packageFolder, .zip].contains(job.configuration.bundleStyle) {
            job = try await context.update(
                job,
                state: .running,
                stage: .packaging
            )
            let packagedChapters = input.usesSponsorBlockTimeline
                ? input.finalTimelineChapters
                : try ChapterWorkflow.normalized(
                    metadata.chapters,
                    durationSeconds: metadata.durationSeconds
                )
            let activeJobID = job.id
            let package = try await context.reportingProcessingProgress(
                operationID: activeJobID,
                expectedStage: .packaging
            ) { progress in
                try packageWorkflow.buildFolder(
                    mediaURL: processed,
                    thumbnailURL: artworkURL,
                    subtitles: preparedSidecars,
                    chapterSplits: chapterSplits,
                    chapters: packagedChapters,
                    metadata: metadata,
                    packageName: filename,
                    temporaryRoot: temporaryRoot,
                    durationSeconds: input.usesSponsorBlockTimeline
                        ? input.finalTimelineDuration
                        : nil
                ) { fraction in
                    progress(
                        MediaProcessingProgress(
                            operationID: activeJobID,
                            stage: .finalizing,
                            completedFraction: fraction,
                            processedMediaSeconds: nil,
                            totalMediaSeconds: nil,
                            processedBytes: nil,
                            estimatedRemainingSeconds: nil
                        )
                    )
                }
            }
            let sourceURL: URL
            if job.configuration.bundleStyle == .zip {
                job = try await context.update(
                    job,
                    state: .running,
                    stage: .zipping
                )
                let archive = try await context
                    .reportingProcessingProgress(
                        operationID: activeJobID,
                        expectedStage: .zipping
                    ) { progress in
                        try await packageWorkflow.zipFinalizedFolder(
                            package,
                            to: temporaryRoot.appending(
                                path: "\(filename) Package.zip"
                            )
                        ) { ZIPProgress in
                            progress(
                                MediaProcessingProgress(
                                    operationID: activeJobID,
                                    stage: .muxing,
                                    completedFraction:
                                        ZIPProgress.fraction,
                                    processedMediaSeconds: nil,
                                    totalMediaSeconds: nil,
                                    processedBytes: Int64(
                                        min(
                                            ZIPProgress.completedSourceBytes,
                                            UInt64(Int64.max)
                                        )
                                    ),
                                    estimatedRemainingSeconds: nil
                                )
                            )
                        }
                    }
                sourceURL = archive.archiveURL
            } else {
                sourceURL = package.folderURL
            }
            job = try await context.update(
                job,
                state: .running,
                stage: .savingFiles
            )
            let item = ExportPublicationItem(sourceURL: sourceURL, filename: "\(filename) Package",
                role: .package, assetKind: .image, handling: input.primaryDuplicateHandling)
            let plan = ExportPublicationPlan(items: [item], probe: probe,
                destination: job.configuration.destination, folderBookmark: await context.folderBookmarkSnapshot(),
                directory: job.configuration.bundleStyle == .packageFolder)
            _ = try await context.publishOutput(job, plan, temporaryRoot)
            return
        }

        let extraSidecars = try MetadataSidecarWriter.prepare(
            kinds: job.configuration.metadataSidecars ?? [], metadata: metadata,
            mediaURL: processed,
            root: temporaryRoot)

        var companionDuplicateHandling: DuplicateHandling?
        if job.configuration.savesThumbnailSeparately,
           let artworkURL {
            let settings = await context.settingsSnapshot()
            let companionDuplicate =
                try await exportFlow.duplicateResolution(
                    job: job,
                    filename: "\(filename)-thumbnail",
                    fileExtension: artworkURL.pathExtension,
                    defaultHandling: settings.duplicateHandling,
                    folderBookmark:
                        await context.folderBookmarkSnapshot()
                )
            switch companionDuplicate {
            case let .proceed(handling):
                companionDuplicateHandling = handling
            case .skip:
                companionDuplicateHandling = nil
            case .cancel:
                throw CancellationError()
            }
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
            sourceFiles: input.localFiles,
            artworkURL: artworkURL,
            processedFileURL: processed
        )
        var items = [ExportPublicationItem(sourceURL: processed, filename: filename,
            role: .primary, assetKind: job.configuration.mode == .audioOnly ? .audio : .video,
            handling: input.primaryDuplicateHandling)]
        items += chapterSplits.map {
            ExportPublicationItem(sourceURL: $0.fileURL, filename: "\(filename) - \($0.filename)",
                role: .chapter, assetKind: .video, handling: input.primaryDuplicateHandling, chapter: $0.chapter)
        }
        items += extraSidecars.map {
            ExportPublicationItem(sourceURL: $0.url,
                filename: $0.kind == .info ? filename + ".info" : $0.kind == .description ? filename + ".description" : filename,
                role: .metadata, assetKind: .image, handling: input.primaryDuplicateHandling, metadataKind: $0.kind)
        }
        if let handling = companionDuplicateHandling, let artworkURL {
            items.append(ExportPublicationItem(sourceURL: artworkURL, filename: "\(filename)-thumbnail",
                role: .thumbnail, assetKind: .image, handling: handling))
        }
        if job.configuration.subtitleDelivery.isSidecar && !preparedSidecars.isEmpty {
            let names = try SubtitleFilenamePlanner.filenames(
                mediaURL: URL(filePath: "\(filename).\(processed.pathExtension)"), sidecars: preparedSidecars)
            items += zip(preparedSidecars, names).map { sidecar, name in
                ExportPublicationItem(sourceURL: sidecar.temporaryURL,
                    filename: URL(filePath: name).deletingPathExtension().lastPathComponent,
                    role: .subtitle, assetKind: .image, handling: input.primaryDuplicateHandling,
                    subtitle: .init(selection: sidecar.selection, kind: sidecar.kind))
            }
        }
        let plan = ExportPublicationPlan(items: items, probe: probe,
            destination: job.configuration.destination, folderBookmark: await context.folderBookmarkSnapshot())
        _ = try await context.publishOutput(job, plan, temporaryRoot)
    }
}

private extension SubtitleDelivery {
    var isSidecar: Bool {
        self == .sidecarVTT || self == .sidecarSRT
    }
}
