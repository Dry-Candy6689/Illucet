import Foundation

/// Publishes verified local outputs with an awaited durable receipt around each external effect.
struct DownloadPublicationWorkflow: Sendable {
    let exportFlow: DownloadExportFlow

    func run(job input: DownloadJob, plan supplied: ExportPublicationPlan, root: URL,
             context: DownloadPipelineContext) async throws -> DownloadJob {
        try await context.requireExecution(input.id)
        var job = input
        let plan = supplied.items.allSatisfy { !$0.digest.isEmpty }
            ? supplied : try supplied.prepared(jobID: job.id, root: root)
        try plan.validate(root: root)
        for item in plan.items {
            try BackgroundFileProtection.protectTree(item.sourceURL, under: root)
        }
        var checkpoint = job.pipelineCheckpoint ?? DownloadPipelineCheckpoint(phase: .exporting)
        checkpoint.phase = .exporting
        checkpoint.publicationPlan = plan
        let steps = Self.steps(plan)
        guard !steps.isEmpty else { throw ExportPublicationError.inputsUnavailable }
        if let existing = checkpoint.publicationReceipts {
            guard existing.count == steps.count,
                  Set(existing.map(\.id)) == Set(steps.map(\.id)),
                  existing.allSatisfy({ receipt in
                      steps.contains { $0.id == receipt.id && $0.destination == receipt.destination }
                        && receipt.fileURLs.allSatisfy(\.isFileURL)
                  }) else { throw ExportPublicationError.inputsUnavailable }
        }
        if checkpoint.publicationReceipts == nil { checkpoint.publicationReceipts = steps }
        job.pipelineCheckpoint = checkpoint
        job.outputProbe = plan.probe
        job = try await context.persistPublication(job)
        for step in steps {
            try Task.checkCancellation()
            try await context.requireExecution(job.id)
            guard let index = job.pipelineCheckpoint?.publicationReceipts?.firstIndex(where: { $0.id == step.id }),
                  var receipt = job.pipelineCheckpoint?.publicationReceipts?[index] else {
                throw ExportPublicationError.inputsUnavailable
            }
            if receipt.state == .committed {
                if receipt.destination == .files || receipt.destination == .share {
                    guard receipt.fileURLs.count == plan.items.count else { throw ExportPublicationError.inputsUnavailable }
                } else if receipt.photoIdentifiers.isEmpty { throw ExportPublicationError.inputsUnavailable }
                continue
            }
            guard receipt.state == .notStarted else { throw ExportPublicationError.outcomeUnknown }
            var handling = plan.items.map(\.handling)
            if step.destination == .files && !plan.directory {
                guard let resolved = try await exportFlow.transactionHandling(items: plan.items.map {
                    ExportFileTransactionItem(sourceURL: $0.sourceURL, filename: $0.filename)
                }, initialHandling: handling, job: job, folderBookmark: plan.folderBookmark) else {
                    try? FileManager.default.removeItem(at: root)
                    return await context.completeDuplicateSkip(job)
                }
                handling = resolved
            }
            receipt.state = .committing
            receipt.failureCode = nil
            job.stage = step.destination == .photos ? .savingPhotos : .savingFiles
            job.pipelineCheckpoint?.publicationReceipts?[index] = receipt
            job = try await context.persistPublication(job)
            try Task.checkCancellation()
            var skipped = false
            do {
                switch step.destination {
                case .files:
                    if plan.directory {
                        let item = plan.items[0]
                        let result = try await exportFlow.exportPackageDirectory(sourceURL: item.sourceURL,
                            filename: item.filename, duplicateHandling: item.handling,
                            job: job, folderBookmark: plan.folderBookmark)
                        receipt.fileURLs = result.fileURL.map { [$0] } ?? []
                        skipped = result.skippedDuplicate
                    } else {
                        let outcome = try await exportFlow.exportManager.exportFileTransaction(
                            items: plan.items.map { ExportFileTransactionItem(sourceURL: $0.sourceURL, filename: $0.filename) },
                            destination: plan.destination == .filesAndPhotos ? .filesFolder : plan.destination,
                            folderBookmark: plan.folderBookmark, duplicateHandling: handling,
                            videoID: job.videoID, relativeDirectory: job.batchMembership?.relativeOutputDirectory)
                        switch outcome {
                        case let .committed(urls): receipt.fileURLs = urls
                        case .duplicateSkipped: skipped = true
                        }
                    }
                case .photos:
                    guard let itemIndex = Int(step.id.dropFirst("photos.".count)), plan.items.indices.contains(itemIndex) else {
                        throw ExportPublicationError.inputsUnavailable
                    }
                    let item = plan.items[itemIndex]
                    let result = try await exportFlow.exportManager.export(sourceURL: item.sourceURL,
                        destination: .photos, filename: item.filename, folderBookmark: nil,
                        duplicateHandling: .addNumber, videoID: job.videoID, jobID: job.id,
                        title: job.title, assetKind: item.assetKind)
                    receipt.photoIdentifiers = result.photoAssetLocalIdentifiers
                case .share:
                    let request = try await exportFlow.exportManager.stageShareFileTransaction(
                        items: plan.items.map { ExportFileTransactionItem(sourceURL: $0.sourceURL, filename: $0.filename) },
                        jobID: job.id, title: job.title)
                    receipt.fileURLs = request.fileURLs
                }
            } catch {
                // Known Photos errors acknowledge failure. Uncertain provider/file outcomes
                // stay non-replayable rather than assuming a rollback succeeded.
                let code = (error as? IllucetError) == .photosPermissionDenied
                    ? "photos_permission_denied" : "save_failed"
                receipt.failureCode = code
                receipt.state = step.destination == .photos && error is IllucetError ? .notStarted : .outcomeUnknown
                job.pipelineCheckpoint?.publicationReceipts?[index] = receipt
                job = Self.project(job, plan: plan)
                _ = try await context.persistPublication(job)
                if error is CancellationError { throw error }
                if receipt.state == .outcomeUnknown { throw ExportPublicationError.outcomeUnknown }
                throw ExportPublicationError.destinationFailed(step.destination, code)
            }
            receipt.state = .committed
            job.pipelineCheckpoint?.publicationReceipts?[index] = receipt
            job = Self.project(job, plan: plan)
            // A failed acknowledgement leaves committing on disk; do not start another effect.
            job = try await context.persistPublication(job)
            if skipped { return await context.completeDuplicateSkip(job) }
        }
        try Task.checkCancellation()
        try await context.requireExecution(job.id)
        job = Self.project(job, plan: plan)
        let shareURLs = job.pipelineCheckpoint?.publicationReceipts?.first { $0.destination == .share }?.fileURLs
        let share = shareURLs.map { SharePresentationRequest(jobID: job.id, title: job.title, fileURLs: $0) }
        let result = ExportResult(fileURL: job.outputURL, photoAssetLocalIdentifiers: job.photosAssetLocalIdentifiers ?? [],
            shareRequest: share, outcome: job.exportOutcome ?? .file)
        return await context.completeExport(job, plan.probe, result,
            result.photoAssetLocalIdentifiers, share, root)
    }

    static func steps(_ plan: ExportPublicationPlan) -> [ExportPublicationReceipt] {
        switch plan.destination {
        case .appDocuments, .filesFolder: return [.init(id: "files", destination: .files)]
        case .share: return [.init(id: "share", destination: .share)]
        case .photos, .filesAndPhotos:
            let photos = plan.items.indices.filter { [.primary, .thumbnail].contains(plan.items[$0].role) }.map {
                ExportPublicationReceipt(id: "photos.\($0)", destination: .photos)
            }
            return (plan.destination == .filesAndPhotos ? [.init(id: "files", destination: .files)] : []) + photos
        case .askEveryTime: return []
        }
    }

    static func project(_ input: DownloadJob, plan: ExportPublicationPlan) -> DownloadJob {
        var job = input
        let receipts = job.pipelineCheckpoint?.publicationReceipts ?? []
        let files = receipts.first { ($0.destination == .files || $0.destination == .share) && $0.state == .committed }?.fileURLs ?? []
        let photos = receipts.filter { $0.state == .committed }.flatMap(\.photoIdentifiers)
        job.photosAssetLocalIdentifiers = photos
        job.outputProbe = plan.probe
        for (item, url) in zip(plan.items, files) {
            switch item.role {
            case .primary: job.outputURL = url
            case .package: job.outputURL = url; job.packageURL = url
            case .thumbnail: break
            case .subtitle: break
            case .chapter: break
            case .metadata: break
            }
        }
        job.subtitleSidecars = zip(plan.items, files).compactMap { item, url in
            guard let subtitle = item.subtitle else { return nil }
            return SubtitleSidecarRecord(selection: subtitle.selection, kind: subtitle.kind, filename: url.lastPathComponent, localURL: url)
        }
        job.chapterOutputs = zip(plan.items, files).compactMap { item, url in
            guard let chapter = item.chapter else { return nil }
            return ChapterOutputRecord(title: chapter.title, startSeconds: chapter.startSeconds,
                endSeconds: chapter.endSeconds, filename: url.lastPathComponent, localURL: url)
        }
        job.metadataSidecars = zip(plan.items, files).compactMap { item, url in
            guard item.role == .metadata || item.role == .thumbnail else { return nil }
            return MetadataSidecarRecord(kind: item.metadataKind, localURL: url)
        }
        if !files.isEmpty && plan.destination == .share {
            job.exportOutcome = .sharePending; job.shareCompletionState = .pending
        } else if !photos.isEmpty { job.exportOutcome = files.isEmpty ? .photos : .filesAndPhotos }
        else if !files.isEmpty { job.exportOutcome = .file }
        job.outputReferences = SavedOutputResolver().references(for: HistoryRecord(job: job).ownedFileURLs,
            previous: job.outputReferences, folderBookmark: plan.folderBookmark)
        return job
    }
}
