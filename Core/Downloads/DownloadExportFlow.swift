import Foundation

enum DuplicateResolution {
    case proceed(DuplicateHandling)
    case skip
    case cancel
}

struct MediaFileTransactionResult: Equatable, Sendable {
    let primary: ExportResult
    let additionalFileURLs: [URL]
}

private struct DuplicateContinuationEntry {
    let jobID: UUID
    let continuation: CheckedContinuation<DuplicateHandling?, Never>
}

/// Owns duplicate decisions and calls into the export service. UI
/// presentations stay FIFO because every request is emitted through the
/// coordinator's single event stream.
actor DownloadExportFlow {
    private let exporter: ExportManager
    nonisolated let exportManager: ExportManager
    private let diagnostics: DiagnosticStore
    private let notifications: UserNotificationService
    private let eventSink:
        @Sendable (DownloadCoordinatorEvent) -> Void
    private var duplicateContinuations: [
        UUID: DuplicateContinuationEntry
    ] = [:]

    init(
        exporter: ExportManager,
        diagnostics: DiagnosticStore,
        notifications: UserNotificationService,
        eventSink: @escaping
            @Sendable (DownloadCoordinatorEvent) -> Void
    ) {
        self.exporter = exporter
        exportManager = exporter
        self.diagnostics = diagnostics
        self.notifications = notifications
        self.eventSink = eventSink
    }

    func cancelDuplicateRequests(jobID: UUID) {
        let requestIDs = duplicateContinuations.compactMap {
            requestID, entry in
            entry.jobID == jobID ? requestID : nil
        }
        for requestID in requestIDs {
            duplicateContinuations.removeValue(
                forKey: requestID
            )?.continuation.resume(returning: nil)
        }
    }

    func resolveDuplicate(
        requestID: UUID,
        handling: DuplicateHandling?
    ) {
        duplicateContinuations.removeValue(
            forKey: requestID
        )?.continuation.resume(returning: handling)
    }

    func duplicateResolution(
        job: DownloadJob,
        filename: String,
        fileExtension: String,
        defaultHandling: DuplicateHandling,
        folderBookmark: Data?
    ) async throws -> DuplicateResolution {
        let preflight = try await exporter.preflight(
            destination: job.configuration.destination,
            filename: filename,
            fileExtension: fileExtension,
            folderBookmark: folderBookmark,
            relativeDirectory:
                job.batchMembership?.relativeOutputDirectory
        )
        guard preflight.hasCollision, let desiredURL = preflight.desiredURL else {
            return .proceed(defaultHandling)
        }
        switch defaultHandling {
        case .ask:
            return try await requestDuplicateResolution(
                job: job,
                desiredURL: desiredURL
            )
        case .skip:
            return .skip
        case let handling:
            return .proceed(handling)
        }
    }

    func exportPrimary(
        sourceURL: URL,
        filename: String,
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        assetKind: ExportAssetKind,
        folderBookmark: Data?
    ) async throws -> ExportResult {
        do {
            return try await exporter.export(
                sourceURL: sourceURL,
                destination: job.configuration.destination,
                filename: filename,
                folderBookmark: folderBookmark,
                duplicateHandling: duplicateHandling,
                videoID: job.videoID,
                jobID: job.id,
                title: job.title,
                assetKind: assetKind,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            )
        } catch let ExportError.duplicateDecisionRequired(desiredURL) {
            let resolution = try await requestDuplicateResolution(
                job: job,
                desiredURL: desiredURL
            )
            switch resolution {
            case let .proceed(handling):
                return try await exporter.export(
                    sourceURL: sourceURL,
                    destination: job.configuration.destination,
                    filename: filename,
                    folderBookmark: folderBookmark,
                    duplicateHandling: handling,
                    videoID: job.videoID,
                    jobID: job.id,
                    title: job.title,
                    assetKind: assetKind,
                    relativeDirectory:
                        job.batchMembership?.relativeOutputDirectory
                )
            case .skip:
                return Self.duplicateSkippedResult
            case .cancel:
                throw CancellationError()
            }
        }
    }

    func exportCompanion(
        sourceURL: URL,
        filename: String,
        mediaFileURL: URL?,
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> ExportResult {
        do {
            return try await exporter.exportCompanionImage(
                sourceURL: sourceURL,
                filename: filename,
                destination: job.configuration.destination,
                mediaFileURL: mediaFileURL,
                folderBookmark: folderBookmark,
                duplicateHandling: duplicateHandling,
                videoID: job.videoID,
                jobID: job.id,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            )
        } catch let ExportError.duplicateDecisionRequired(desiredURL) {
            let resolution = try await requestDuplicateResolution(
                job: job,
                desiredURL: desiredURL
            )
            switch resolution {
            case let .proceed(handling):
                return try await exporter.exportCompanionImage(
                    sourceURL: sourceURL,
                    filename: filename,
                    destination: job.configuration.destination,
                    mediaFileURL: mediaFileURL,
                    folderBookmark: folderBookmark,
                    duplicateHandling: handling,
                    videoID: job.videoID,
                    jobID: job.id,
                    relativeDirectory:
                        job.batchMembership?.relativeOutputDirectory
                )
            case .skip:
                return Self.duplicateSkippedResult
            case .cancel:
                throw CancellationError()
            }
        }
    }

    func exportAdditionalMedia(
        sourceURL: URL,
        filename: String,
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> ExportResult {
        do {
            return try await exporter.export(
                sourceURL: sourceURL,
                destination: job.configuration.destination,
                filename: filename,
                folderBookmark: folderBookmark,
                duplicateHandling: duplicateHandling,
                videoID: job.videoID,
                jobID: job.id,
                title: job.title,
                assetKind: .video,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            )
        } catch let ExportError.duplicateDecisionRequired(desiredURL) {
            let resolution = try await requestDuplicateResolution(
                job: job,
                desiredURL: desiredURL
            )
            switch resolution {
            case let .proceed(handling):
                return try await exporter.export(
                    sourceURL: sourceURL,
                    destination: job.configuration.destination,
                    filename: filename,
                    folderBookmark: folderBookmark,
                    duplicateHandling: handling,
                    videoID: job.videoID,
                    jobID: job.id,
                    title: job.title,
                    assetKind: .video,
                    relativeDirectory:
                        job.batchMembership?.relativeOutputDirectory
                )
            case .skip:
                return Self.duplicateSkippedResult
            case .cancel:
                throw CancellationError()
            }
        }
    }

    func exportMediaFileTransaction(
        primarySourceURL: URL,
        primaryFilename: String,
        additionalItems: [ExportFileTransactionItem],
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> MediaFileTransactionResult {
        let items = [
            ExportFileTransactionItem(
                sourceURL: primarySourceURL,
                filename: primaryFilename
            ),
        ] + additionalItems
        guard let handling = try await transactionHandling(
            items: items,
            initialHandling: Array(
                repeating: duplicateHandling,
                count: items.count
            ),
            job: job,
            folderBookmark: folderBookmark
        ) else {
            return MediaFileTransactionResult(
                primary: Self.duplicateSkippedResult,
                additionalFileURLs: []
            )
        }
        let outcome = try await exporter.exportFileTransaction(
            items: items,
            destination: job.configuration.destination,
            folderBookmark: folderBookmark,
            duplicateHandling: handling,
            videoID: job.videoID,
            relativeDirectory:
                job.batchMembership?.relativeOutputDirectory
        )
        switch outcome {
        case .duplicateSkipped:
            return MediaFileTransactionResult(
                primary: Self.duplicateSkippedResult,
                additionalFileURLs: []
            )
        case let .committed(URLs):
            guard URLs.count == items.count, let primaryURL = URLs.first else {
                throw IllucetError.filesDestinationUnavailable
            }
            return MediaFileTransactionResult(
                primary: ExportResult(
                    fileURL: primaryURL,
                    photoAssetLocalIdentifiers: [],
                    shareRequest: nil,
                    outcome: .file
                ),
                additionalFileURLs: Array(URLs.dropFirst())
            )
        }
    }

    func exportSubtitlesOnly(
        prepared: [PreparedSubtitleSidecar],
        filenames: [String],
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> SubtitleFileSetExport {
        guard job.configuration.isSubtitlesOnly,
              job.configuration.destination.supportsSubtitlesOnly,
              !prepared.isEmpty,
              prepared.count == filenames.count
        else {
            throw SubtitlePipelineError.exportFailed
        }
        let items = try zip(prepared, filenames).map { sidecar, filename in
            let filenameURL = URL(filePath: filename)
            guard filenameURL.pathExtension.lowercased()
                == sidecar.kind.rawValue,
                filenameURL.deletingPathExtension().lastPathComponent
                    .nilIfEmpty != nil
            else {
                throw SubtitlePipelineError.invalidSelection
            }
            return ExportFileTransactionItem(
                sourceURL: sidecar.temporaryURL,
                filename: filenameURL.deletingPathExtension()
                    .lastPathComponent
            )
        }

        let exportedURLs: [URL]
        let result: ExportResult
        if job.configuration.destination == .share {
            let request = try await exporter.stageShareFileTransaction(
                items: items,
                jobID: job.id,
                title: job.title
            )
            exportedURLs = request.fileURLs
            result = ExportResult(
                fileURL: nil,
                photoAssetLocalIdentifiers: [],
                shareRequest: request,
                outcome: .sharePending
            )
        } else {
            guard let handling = try await transactionHandling(
                items: items,
                initialHandling: Array(
                    repeating: duplicateHandling,
                    count: items.count
                ),
                job: job,
                folderBookmark: folderBookmark
            ) else {
                return SubtitleFileSetExport(
                    records: [],
                    result: Self.duplicateSkippedResult
                )
            }
            switch try await exporter.exportFileTransaction(
                items: items,
                destination: job.configuration.destination,
                folderBookmark: folderBookmark,
                duplicateHandling: handling,
                videoID: job.videoID,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            ) {
            case .duplicateSkipped:
                return SubtitleFileSetExport(
                    records: [],
                    result: Self.duplicateSkippedResult
                )
            case let .committed(URLs):
                exportedURLs = URLs
                result = ExportResult(
                    fileURL: nil,
                    photoAssetLocalIdentifiers: [],
                    shareRequest: nil,
                    outcome: .file
                )
            }
        }
        guard exportedURLs.count == prepared.count else {
            throw SubtitlePipelineError.exportFailed
        }
        let records = zip(prepared, exportedURLs).map { sidecar, URL in
            SubtitleSidecarRecord(
                selection: sidecar.selection,
                kind: sidecar.kind,
                filename: URL.lastPathComponent,
                localURL: URL
            )
        }
        return SubtitleFileSetExport(records: records, result: result)
    }

    func exportPackageDirectory(
        sourceURL: URL,
        filename: String,
        duplicateHandling: DuplicateHandling,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> ExportResult {
        do {
            return try await exporter.exportDirectory(
                sourceURL: sourceURL,
                destination: job.configuration.destination,
                filename: filename,
                folderBookmark: folderBookmark,
                duplicateHandling: duplicateHandling,
                videoID: job.videoID,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            )
        } catch let ExportError.duplicateDecisionRequired(desiredURL) {
            let resolution = try await requestDuplicateResolution(
                job: job,
                desiredURL: desiredURL
            )
            switch resolution {
            case let .proceed(handling):
                return try await exporter.exportDirectory(
                    sourceURL: sourceURL,
                    destination: job.configuration.destination,
                    filename: filename,
                    folderBookmark: folderBookmark,
                    duplicateHandling: handling,
                    videoID: job.videoID,
                    relativeDirectory:
                        job.batchMembership?.relativeOutputDirectory
                )
            case .skip:
                return Self.duplicateSkippedResult
            case .cancel:
                throw CancellationError()
            }
        }
    }

    nonisolated func prepareShareCompletion(
        job: DownloadJob?, state: ShareCompletionState, errorDescription: String?
    ) -> DownloadJob? {
        guard var job, job.configuration.destination == .share else { return nil }
        job.shareCompletionState = state
        job.shareErrorMessage = errorDescription.map {
            String($0.prefix(256))
        }
        switch state {
        case .unconfirmed:
            job.exportOutcome = .shareUnconfirmed
        case .pending:
            job.exportOutcome = .sharePending
        case .completed:
            job.exportOutcome = .shared
            job.outputURL = nil
            job.subtitleSidecars = job.subtitleSidecars?.map {
                var value = $0
                value.localURL = nil
                return value
            }
        case .cancelled:
            job.exportOutcome = .shareCancelled
            job.outputURL = nil
            job.subtitleSidecars = job.subtitleSidecars?.map {
                var value = $0
                value.localURL = nil
                return value
            }
        case .failed:
            job.exportOutcome = .shareFailed
        }
        job.updatedAt = .now
        return job
    }

    func presentPendingShare(
        jobID: UUID,
        title: String
    ) async -> Bool {
        guard let request = await exporter.pendingShareRequest(
            jobID: jobID,
            title: title
        ) else {
            return false
        }
        eventSink(.presentShare(request))
        return true
    }

    nonisolated func prepareDuplicateSkip(
        _ input: DownloadJob
    ) -> DownloadJob {
        var job = input
        job.outputURL = nil
        job.outputProbe = nil
        job.exportOutcome = .duplicateSkipped
        job.photosAssetLocalIdentifiers = []
        job.shareCompletionState = nil
        job.shareErrorMessage = nil
        job.subtitleSidecars = nil
        job.chapterOutputs = nil
        job.packageURL = nil
        if var application = job.sponsorBlockApplication,
           application.status == .requested {
            application.status = .notApplied
            job.sponsorBlockApplication = application
        }
        job.activeTransferDescriptors = nil
        let receipts = job.pipelineCheckpoint?.publicationReceipts
        let revision = job.pipelineCheckpoint?.publicationRevision
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .complete)
        job.pipelineCheckpoint?.publicationReceipts = receipts
        job.pipelineCheckpoint?.publicationRevision = revision
        job.state = .completed
        job.stage = .complete
        job.progress.overallFraction = 1
        job.updatedAt = .now
        return job
    }

    func recordDuplicateSkip(_ job: DownloadJob) async {
        await diagnostics.record(
            .info,
            subsystem: "exports",
            event: "duplicate_skipped",
            detail: "job=\(job.id.uuidString), video_id=\(job.videoID)"
        )
    }

    nonisolated func checkpoint(
        _ input: DownloadJob,
        probe: MediaProbeResult?,
        result: ExportResult
    ) -> DownloadJob {
        var job = input
        job.outputURL = result.fileURL
        job.outputProbe = probe
        job.exportOutcome = result.outcome
        job.photosAssetLocalIdentifiers = result.photoAssetLocalIdentifiers
        job.shareCompletionState = result.shareRequest == nil
            ? nil
            : .pending
        job.shareErrorMessage = nil
        job.updatedAt = .now
        return job
    }

    nonisolated func checkpointPartialFile(
        _ input: DownloadJob,
        fileURL: URL,
        probe: MediaProbeResult?
    ) -> DownloadJob {
        var job = input
        job.outputURL = fileURL
        job.outputProbe = probe
        job.exportOutcome = .file
        job.photosAssetLocalIdentifiers = []
        job.shareCompletionState = nil
        job.shareErrorMessage = nil
        job.updatedAt = .now
        return job
    }

    nonisolated func prepareCompletion(
        _ input: DownloadJob,
        probe: MediaProbeResult?,
        result: ExportResult,
        photoIdentifiers: [String],
        shareRequest: SharePresentationRequest?
    ) -> DownloadJob {
        var job = input
        job.outputURL = result.fileURL
        job.outputProbe = probe
        job.exportOutcome = result.outcome
        job.photosAssetLocalIdentifiers = photoIdentifiers
        job.shareCompletionState = shareRequest == nil ? nil : .pending
        job.shareErrorMessage = nil
        job.activeTransferDescriptors = nil
        let receipts = job.pipelineCheckpoint?.publicationReceipts
        let revision = job.pipelineCheckpoint?.publicationRevision
        job.pipelineCheckpoint = DownloadPipelineCheckpoint(phase: .complete)
        job.pipelineCheckpoint?.publicationReceipts = receipts
        job.pipelineCheckpoint?.publicationRevision = revision
        job.state = .completed
        job.stage = .complete
        job.progress.overallFraction = 1
        job.progress.processingFraction = probe == nil ? nil : 1
        job.updatedAt = .now
        return job
    }

    /// Called only after the coordinator commits completion and publishes History.
    func finishCompletion(
        _ job: DownloadJob,
        shareRequest: SharePresentationRequest?,
        notifyDownloadComplete: Bool
    ) async {
        if let time = await notifications.routeCompletion(
            job: job, notifyWhenBackgrounded: notifyDownloadComplete
        ) {
            eventSink(.foregroundCompletion(jobID: job.id, at: time))
        }
        await diagnostics.record(
            .info,
            subsystem: "downloads",
            event: "job_completed",
            detail: "job=\(job.id.uuidString), formats=\(job.selectedFormatIDs.joined(separator: ","))"
        )
        if let shareRequest {
            eventSink(.presentShare(shareRequest))
        }
    }

    private func requestDuplicateResolution(
        job: DownloadJob,
        desiredURL: URL
    ) async throws -> DuplicateResolution {
        let conflict = DuplicateConflict(
            id: UUID(),
            job: job,
            desiredURL: desiredURL
        )
        let response = await withCheckedContinuation { continuation in
            duplicateContinuations[conflict.id] = DuplicateContinuationEntry(
                jobID: job.id,
                continuation: continuation
            )
            eventSink(.requestDuplicate(conflict))
        }
        try Task.checkCancellation()
        guard let response else { return .cancel }
        return response == .skip ? .skip : .proceed(response)
    }

    func transactionHandling(
        items: [ExportFileTransactionItem],
        initialHandling: [DuplicateHandling],
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> [DuplicateHandling]? {
        guard items.count == initialHandling.count else {
            throw IllucetError.filesDestinationUnavailable
        }
        var handling = initialHandling
        for (index, item) in items.enumerated() {
            let preflight = try await exporter.preflight(
                destination: job.configuration.destination,
                filename: item.filename,
                fileExtension: item.sourceURL.pathExtension,
                folderBookmark: folderBookmark,
                relativeDirectory:
                    job.batchMembership?.relativeOutputDirectory
            )
            guard preflight.hasCollision,
                  let desiredURL = preflight.desiredURL
            else {
                continue
            }
            switch handling[index] {
            case .ask:
                let resolution = try await requestDuplicateResolution(
                    job: job,
                    desiredURL: desiredURL
                )
                switch resolution {
                case let .proceed(selected):
                    handling[index] = selected
                case .skip:
                    return nil
                case .cancel:
                    throw CancellationError()
                }
            case .skip:
                return nil
            case .overwrite, .addNumber, .addVideoID:
                break
            }
        }
        return handling
    }

    private static let duplicateSkippedResult = ExportResult(
        fileURL: nil,
        photoAssetLocalIdentifiers: [],
        shareRequest: nil,
        outcome: .duplicateSkipped
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
