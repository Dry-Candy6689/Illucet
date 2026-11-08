import Combine
import Foundation
import UIKit

extension IllucetAppModel {
    var outputFolderBookmark: Data? { snapshot.filesFolderBookmark }

    func reauthorizeOutput(_ record: HistoryRecord, folder: URL) async throws -> HistoryRecord {
        let selection = try await exporter.bookmarkSelection(for: folder)
        var updated = record
        updated.outputReferences = try outputResolver.reauthorizedReferences(for: record, folderURL: folder,
            bookmark: selection.data, previousBookmark: snapshot.filesFolderBookmark)
        if let index = history.firstIndex(where: { $0.id == record.id }) { history[index] = updated }
        if selectedHistoryRecord?.id == record.id { selectedHistoryRecord = updated }
        if let index = jobs.firstIndex(where: { $0.id == record.jobID }) { jobs[index].outputReferences = updated.outputReferences }
        if let references = updated.outputReferences {
            await coordinator.updateOutputReferences(jobID: record.jobID, references: references)
        }
        try await saveSnapshot()
        return updated
    }

    func pause(_ job: DownloadJob) {
        Task { await coordinator.pause(job.id) }
    }

    func resume(_ job: DownloadJob) {
        Task {
            do {
                let overLimit = try await approveTransferAdmission(excluding: job.id)
                await coordinator.resume(job.id, transferLimitOverride: overLimit)
            } catch is CancellationError {} catch { alert = .error(error) }
        }
    }

    func cancel(_ job: DownloadJob) {
        discardActionPresentations(for: job.id)
        Task { await coordinator.cancel(job.id) }
    }

    func retry(_ job: DownloadJob) {
        Task {
            do {
                let overLimit = try await approveTransferAdmission(excluding: job.id)
                await coordinator.retry(job.id, transferLimitOverride: overLimit)
            } catch is CancellationError {} catch { alert = .error(error) }
        }
    }

    func resolveDuplicate(
        _ conflict: DuplicateConflict,
        handling: DuplicateHandling?
    ) {
        guard userPresentationState.beginDuplicateResolution(
            requestID: conflict.id
        ) else {
            return
        }
        Task {
            await coordinator.resolveDuplicate(
                requestID: conflict.id,
                handling: handling
            )
        }
    }

    func duplicateDialogDidDismiss(requestID: UUID?) {
        guard let dismissal = updateUserPresentationState({ state in
            state.dismissDuplicate(requestID: requestID)
        }) else {
            return
        }
        if dismissal.needsCancellation {
            Task {
                await coordinator.resolveDuplicate(
                    requestID: dismissal.value.id,
                    handling: nil
                )
            }
        }
        finishPresentationDismissal()
    }

    func resolveNetworkAccess(
        _ request: NetworkAccessRequest,
        choice: NetworkAccessChoice
    ) {
        guard userPresentationState.beginNetworkResolution(
            requestID: request.id
        ) else {
            return
        }
        Task {
            await coordinator.resolveNetworkAccess(
                requestID: request.id,
                choice: choice
            )
        }
    }

    func networkDialogDidDismiss(requestID: UUID?) {
        guard let dismissal = updateUserPresentationState({ state in
            state.dismissNetwork(requestID: requestID)
        }) else {
            return
        }
        if dismissal.needsCancellation {
            Task {
                await coordinator.resolveNetworkAccess(
                    requestID: dismissal.value.id,
                    choice: .cancel
                )
            }
        }
        finishPresentationDismissal()
    }

    func finishShare(
        _ request: SharePresentationRequest,
        state: ShareCompletionState,
        errorDescription: String?
    ) {
        guard activeShareOutcomes[request.jobID] === request.outcome else { return }
        request.outcome.recordUIKit(state, error: errorDescription)
        guard let outcome = request.outcome.take() else { return }
        _ = updateUserPresentationState { $0.beginShareCompletion(requestID: request.id) }
        Task {
            await coordinator.shareDidFinish(jobID: request.jobID, state: outcome.state, errorDescription: outcome.error)
        }
    }

    func shareSheetDidDismiss() {
        guard let dismissal = updateUserPresentationState({ $0.dismissShare() }) else { return }
        if let outcome = dismissal.value.outcome.take(dismissing: true) {
            Task {
                await coordinator.shareDidFinish(jobID: dismissal.value.jobID, state: outcome.state, errorDescription: outcome.error)
            }
        }
        finishPresentationDismissal()
    }

    func retryExport(_ record: HistoryRecord) {
        selectedTab = .queue
        Task { await coordinator.retry(record.jobID) }
    }

    func retryShare(_ record: HistoryRecord) {
        Task {
            let presented = await coordinator.presentPendingShare(
                jobID: record.jobID,
                title: record.title
            )
            if !presented {
                alert = AppAlert(
                    title: "Share file unavailable",
                    message: "The staged share file is no longer present. Download the item again to recreate it."
                )
            }
        }
    }

    func saveHistoryCopyToPhotos(_ record: HistoryRecord) async {
        guard let original = record.fileURL else { return }
        guard let sourceURL = URL(string: "https://www.youtube.com/watch?v=\(record.videoID)") else { return }
        let id = UUID()
        do {
            let resolver = outputResolver, bookmark = outputFolderBookmark
            let access = await Task.detached { resolver.open(record, fallbackBookmark: bookmark) }.value
            defer { withExtendedLifetime(access) {} }
            let source = try access.read(original) { $0 }
            let result = try await exporter.export(sourceURL: source, destination: .photos,
                filename: FilenameSystem.sanitizeComponent(record.title), folderBookmark: nil,
                duplicateHandling: .addNumber, videoID: record.videoID, jobID: id,
                title: record.title, assetKind: record.isThumbnailOnly ? .image : .video)
            var configuration = record.configuration
            configuration.destination = .photos
            configuration.metadataSidecars = nil
            configuration.bundleStyle = .mediaOnly
            var job = DownloadJob(id: id, sourceURL: sourceURL,
                videoID: record.videoID, title: record.title, channel: record.channel, thumbnailURL: record.thumbnailURL,
                createdAt: .now, updatedAt: .now, configuration: configuration, state: .completed, stage: .complete,
                progress: .zero, priority: 0, retryCount: 0, maximumRetries: 0, errorCode: nil, errorMessage: nil,
                outputURL: nil, outputProbe: record.probe, selectedFormatIDs: [], extractorVersion: nil)
            job.photosAssetLocalIdentifiers = result.photoAssetLocalIdentifiers
            job.exportOutcome = result.outcome
            history.insert(HistoryRecord(job: job), at: 0)
            scheduleSave()
            alert = AppAlert(title: "Saved to Photos", message: "A copy was saved to Photos. The original file was kept.")
        } catch { alert = .error(error) }
    }

    func openPhotos() {
        guard let URL = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(URL) { [weak self] opened in
            guard !opened else { return }
            self?.alert = AppAlert(
                title: "Couldn’t open Photos",
                message: "Open the Photos app to view the saved item."
            )
        }
    }

    func prioritize(_ job: DownloadJob) {
        Task { await coordinator.prioritize(job.id) }
    }

    func moveJobs(from offsets: IndexSet, to offset: Int) {
        Task {
            await coordinator.move(
                fromOffsets: offsets,
                toOffset: offset
            )
        }
    }

    func moveUnbatchedJobs(
        from offsets: IndexSet,
        to offset: Int
    ) {
        guard let mergedIDs =
            BatchQueueOrdering.reorderUnbatchedJobs(
                in: orderedJobs,
                fromOffsets: offsets,
                toOffset: offset
            )
        else {
            return
        }
        Task {
            await coordinator.reorderActiveJobs(mergedIDs)
        }
    }

    func pauseAll() {
        Task {
            let held = await batchController.holdAdmissions()
            await coordinator.pauseAll()
            for id in held { await batchController.pause(id) }
        }
    }

    func resumeAll() {
        let pausedBatches = batches.filter { $0.state == .paused || $0.admissionPaused == true }
        let batchController = batchController
        let coordinator = coordinator
        Task {
            await withTaskGroup(of: Void.self) { group in
                for batch in pausedBatches {
                    group.addTask { await batchController.resume(batch.id) }
                }
                group.addTask { await coordinator.resumeAll() }
            }
        }
    }

    func cancelAll() {
        let duplicateJobIDs: Set<UUID> = Set(
            pendingUserPresentations.requests.compactMap {
                guard case let .duplicate(conflict) = $0 else {
                    return nil
                }
                return conflict.jobID
            }
        )
        for jobID in duplicateJobIDs {
            discardDuplicatePresentations(for: jobID)
        }
        let activeBatches = batches.filter { !$0.state.isTerminal }
        Task {
            for batch in activeBatches {
                await batchController.cancel(batch.id)
            }
            await coordinator.cancelAll()
        }
    }

    func clearCompletedJobs() {
        let terminalBatches = batches.filter(\.state.isTerminal)
        Task {
            for batch in terminalBatches {
                await batchController.remove(batch.id)
            }
            await coordinator.clearCompleted()
        }
    }

    func redownload(_ record: HistoryRecord) {
        cancelQuickStartInputRecovery()
        pendingRedownloadConfiguration = record.configuration
        URLText = "https://www.youtube.com/watch?v=\(record.videoID)"
        selectedTab = .download
        analyze()
    }

    func deleteHistoryRecord(_ record: HistoryRecord) {
        history.removeAll { $0.id == record.id }
        selectedHistoryRecord = nil
        scheduleSave()
    }

    func deleteHistoryFile(_ record: HistoryRecord) {
        Task { await removeHistoryRecords([record.id], includingFiles: true) }
    }

    func removeHistoryRecords(_ ids: Set<UUID>, includingFiles: Bool) async {
        guard !isRemovingHistoryFiles, !isDeletingIllucetFiles else { return }
        isRemovingHistoryFiles = true
        defer { isRemovingHistoryFiles = false }
        let records = history.filter { ids.contains($0.id) }
        if includingFiles, records.contains(where: { protectedTemporaryJobIDs.contains($0.jobID) }) {
            alert = AppAlert(title: "Files are still in use",
                message: "Finish or cancel these downloads before deleting their files.")
            return
        }
        let bookmark = snapshot.filesFolderBookmark
        let result: HistoryFileRemoval.Result?
        if includingFiles {
            result = await Task.detached(priority: .userInitiated) {
                HistoryFileRemoval.remove(records: records, folderBookmark: bookmark)
            }.value
        } else { result = nil }
        let removed = result?.removedRecordIDs ?? ids
        history.removeAll { removed.contains($0.id) }
        if let selectedHistoryRecord, removed.contains(selectedHistoryRecord.id) {
            self.selectedHistoryRecord = nil
        }
        scheduleSave()
        if includingFiles {
            do {
                let deletedJobIDs = Set(records.filter { removed.contains($0.id) }.map(\.jobID))
                try await storageManager.clearTemporaryFiles(
                    excludingJobIDs: protectedTemporaryJobIDs, onlyJobIDs: deletedJobIDs)
            } catch { alert = .error(error) }
            await refreshStorage()
        }
        if let result, !result.failedRecordIDs.isEmpty {
            alert = AppAlert(title: "Some files could not be deleted", message:
                "Removed \(result.removedRecordIDs.count) records. Kept \(result.failedRecordIDs.count) records because \(result.failedFileCount) files could not be deleted. Some files may already have been removed; retry the remaining records. Photos library items are kept.")
        }
    }

    func manageQueue(jobIDs: Set<UUID>, batchIDs: Set<UUID>, cancel: Bool) async {
        for batch in batches where batchIDs.contains(batch.id) {
            if cancel && !batch.state.isTerminal {
                await batchController.cancel(batch.id)
            } else if !cancel && batch.state.isTerminal {
                let children = await batchController.remove(batch.id)
                await coordinator.removeTerminalJobs(children)
            }
        }
        for job in jobs where jobIDs.contains(job.id) && job.batchMembership == nil {
            if cancel && !job.state.isTerminal {
                discardActionPresentations(for: job.id)
                await coordinator.cancel(job.id)
            } else if !cancel && job.state.isTerminal {
                await coordinator.removeTerminalJobs([job.id])
            }
        }
    }

    func enqueuePresentation(_ presentation: PendingUserPresentation) {
        if case let .share(request) = presentation { activeShareOutcomes[request.jobID] = request.outcome }
        updateUserPresentationState { state in
            state.enqueue(presentation)
        }
    }

    private func finishPresentationDismissal() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            updateUserPresentationState { state in
                state.finishDismissal()
            }
        }
    }

    func discardDuplicatePresentations(for jobID: UUID) {
        let discardedActive = updateUserPresentationState { state in
            state.discardDuplicateRequests(jobID: jobID)
        }
        if discardedActive {
            finishPresentationDismissal()
        }
    }

    func discardActionPresentations(for jobID: UUID) {
        let discardedActive = updateUserPresentationState { state in
            state.discardRequests(jobID: jobID)
        }
        if discardedActive {
            finishPresentationDismissal()
        }
    }

    private func updateUserPresentationState<Result>(
        _ update: (inout IllucetAppPresentationState) -> Result
    ) -> Result {
        var updatedState = userPresentationState
        let result = update(&updatedState)
        if updatedState != userPresentationState {
            objectWillChange.send()
            userPresentationState = updatedState
        }
        return result
    }
}
