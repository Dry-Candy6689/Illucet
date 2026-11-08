import Foundation

enum DownloadBatchControllerEvent: Sendable {
    case upsertBatch(DownloadBatch)
    case removeBatch(UUID)
    case upsertArchive(DownloadArchiveEntry)
    case removeArchive(String)
}

struct DownloadBatchJobCommands: Sendable {
    let pause: @Sendable (UUID) async -> Void
    let resume: @Sendable (UUID) async -> Void
    let cancel: @Sendable (UUID) async -> Void
    let retry: @Sendable (UUID) async -> Void
}

typealias BatchExtractorVersionProvider =
    @Sendable () async -> String?

actor DownloadBatchController {
    nonisolated let updates: AsyncStream<DownloadBatchControllerEvent>

    private struct ExpansionTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let continuation:
        AsyncStream<DownloadBatchControllerEvent>.Continuation
    private let childFactory: PlaylistChildJobFactory
    private let commands: DownloadBatchJobCommands
    private let extractorVersion: BatchExtractorVersionProvider

    private var batches: [UUID: DownloadBatch] = [:]
    private var jobs: [UUID: DownloadJob] = [:]
    private var archive: [String: DownloadArchiveEntry] = [:]
    private var expansionTasks: [UUID: ExpansionTask] = [:]
    private var pausedBatchIDs: Set<UUID> = []

    init(
        childFactory: PlaylistChildJobFactory,
        commands: DownloadBatchJobCommands,
        extractorVersion: @escaping BatchExtractorVersionProvider = {
            nil
        }
    ) {
        var captured:
            AsyncStream<DownloadBatchControllerEvent>.Continuation!
        updates = AsyncStream { captured = $0 }
        continuation = captured
        self.childFactory = childFactory
        self.commands = commands
        self.extractorVersion = extractorVersion
    }

    deinit {
        for entry in expansionTasks.values {
            entry.task.cancel()
        }
        continuation.finish()
    }

    @discardableResult
    func createBatch(
        analysis: PlaylistAnalysis,
        selection: PlaylistSelection,
        configuration: DownloadConfiguration,
        itemOverrides: [String: DownloadConfiguration] = [:],
        destinationStructure: BatchDestinationStructure,
        skipArchivedItems: Bool
    ) throws -> DownloadBatch {
        let entries = try selection.resolvedEntries(
            in: analysis,
            maximumItems: configuration.maximumPlaylistItems
        )
        var batch = DownloadBatch(
            analysis: analysis,
            selection: selection,
            configuration: configuration,
            itemOverrides: itemOverrides,
            destinationStructure: destinationStructure,
            continueOnError: configuration.continuePlaylistOnError,
            skipArchivedItems: skipArchivedItems,
            numberFilenames: configuration.numberPlaylistFilenames,
            filenameIndexWidth: Self.indexWidth(
                entries: entries
            ),
            entries: entries
        )
        applyArchiveSkips(to: &batch)
        batch.state = batch.items.allSatisfy(\.state.isTerminal)
            ? .completed
            : .preparing
        batch.progress = BatchProgressAggregator.progress(
            items: batch.items,
            jobsByID: jobs
        )
        batches[batch.id] = batch
        continuation.yield(.upsertBatch(batch))
        startExpansion(batchID: batch.id)
        return batch
    }

    func restore(
        _ restoredBatches: [DownloadBatch],
        jobs restoredJobs: [DownloadJob],
        archive restoredArchive: [DownloadArchiveEntry]
    ) {
        jobs = Dictionary(
            uniqueKeysWithValues: restoredJobs.map { ($0.id, $0) }
        )
        let result = BatchRestoration.reconcile(
            batches: restoredBatches,
            jobs: restoredJobs,
            archive: restoredArchive
        )
        batches = Dictionary(
            uniqueKeysWithValues: result.batches.map { ($0.id, $0) }
        )
        archive = Dictionary(
            uniqueKeysWithValues: result.archive.map { ($0.id, $0) }
        )
        pausedBatchIDs = Set(result.batches.filter { $0.admissionPaused == true || $0.state == .paused }.map(\.id))
        for batch in result.batches {
            continuation.yield(.upsertBatch(batch))
        }
        for entry in result.archive {
            continuation.yield(.upsertArchive(entry))
        }
        for batchID in result.resumableBatchIDs {
            startExpansion(batchID: batchID)
        }
    }

    func receive(_ job: DownloadJob) async {
        if let previous = jobs[job.id], previous.updatedAt > job.updatedAt { return }
        guard let membership = job.batchMembership,
              var batch = batches[membership.batchID],
              let itemIndex = batch.items.firstIndex(where: {
                  $0.id == membership.entryID
              })
        else {
            return
        }
        let explicitRetry = job.retryRequestID.map { batch.stoppedRetryRequests?[job.id.uuidString] != $0 } == true
        // A queued event from before Stop cannot reopen a child. Only an
        // explicit retry carries a new durable request identity.
        if [.cancelled, .failed].contains(batch.state), !explicitRetry,
           !job.state.isTerminal { return }
        jobs[job.id] = job
        if (batch.state == .cancelled || batch.state == .failed),
           explicitRetry, !job.state.isTerminal, job.state != .needsAttention {
            batch.state = .queued
            batch.errorMessage = nil
            batch.admissionPaused = false
            pausedBatchIDs.remove(batch.id)
        }
        let previousItem = batch.items[itemIndex]
        let wasExplicitlySkipped = previousItem.state == .skipped
        let wasStoppedAfterFailure =
            previousItem.state == .cancelled
                && previousItem.errorCode == "stopped_after_failure"
        if !wasExplicitlySkipped && (!wasStoppedAfterFailure || explicitRetry) {
            batch.items[itemIndex] = BatchProgressAggregator.updatedItem(
                batch.items[itemIndex],
                from: job
            )
        }
        if job.state == .completed,
           job.exportOutcome != .duplicateSkipped,
           !wasExplicitlySkipped {
            let record = DownloadArchiveEntry.youtube(
                videoID: job.videoID,
                completedAt: job.updatedAt,
                batchID: batch.id
            )
            archive[record.id] = record
            continuation.yield(.upsertArchive(record))
        }
        let shouldStop = job.state == .failed && !batch.continueOnError && batch.state != .cancelled
        if shouldStop {
            batch.stoppedRetryRequests = retryRequests(in: batch)
            batch.state = .failed
            batch.errorMessage =
                "Stopped after \(job.title) failed."
            markRemainingItemsStopped(in: &batch)
        }
        recompute(&batch)
        if shouldStop {
            batch.state = .failed
        }
        batches[batch.id] = batch
        continuation.yield(.upsertBatch(batch))
        if shouldStop {
            cancelExpansion(batchID: batch.id)
            await cancelChildren(
                in: batch,
                excluding: job.id
            )
        }
    }

    /// Stop expansion for all current batches before awaiting child controls.
    func holdAdmissions() -> [UUID] {
        let ids = batches.values.filter { !$0.state.isTerminal }.map(\.id)
        for id in ids {
            guard var batch = batches[id] else { continue }
            pausedBatchIDs.insert(id)
            batch.admissionPaused = true
            cancelExpansion(batchID: id)
            recompute(&batch)
            batches[id] = batch
            continuation.yield(.upsertBatch(batch))
        }
        return ids
    }

    func pause(_ batchID: UUID) async {
        guard var batch = batches[batchID],
              !batch.state.isTerminal
        else {
            return
        }
        batch.admissionPaused = true
        pausedBatchIDs.insert(batchID)
        cancelExpansion(batchID: batchID)
        let childJobs = childJobs(in: batch)
        let hasUnpausableProcessing = childJobs.contains {
            $0.state == .running && !$0.stage.supportsTransferPause
        }
        batch.state = hasUnpausableProcessing ? .running : .paused
        batch.errorMessage = hasUnpausableProcessing
            ? "Active processing cannot be paused; no new items will start."
            : nil
        batch.updatedAt = .now
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        for job in childJobs where !job.state.isTerminal {
            await commands.pause(job.id)
        }
    }

    func resume(_ batchID: UUID) async {
        guard var batch = batches[batchID],
              !batch.state.isTerminal
        else {
            return
        }
        pausedBatchIDs.remove(batchID)
        batch.admissionPaused = false
        batch.state = .queued
        batch.errorMessage = nil
        batch.updatedAt = .now
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        startExpansion(batchID: batchID)
        let ids = childJobs(in: batch).filter { $0.state == .paused }.map(\.id)
        let commands = commands
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await commands.resume(id) } }
        }
    }

    func cancel(_ batchID: UUID) async {
        guard var batch = batches[batchID],
              !batch.state.isTerminal
        else {
            return
        }
        batch.admissionPaused = false
        batch.stoppedRetryRequests = retryRequests(in: batch)
        pausedBatchIDs.remove(batchID)
        cancelExpansion(batchID: batchID)
        for index in batch.items.indices
            where !batch.items[index].state.isTerminal {
            batch.items[index].state = .cancelled
            batch.items[index].errorCode = "user_cancelled"
            batch.items[index].errorMessage = "Cancelled"
        }
        batch.state = .cancelled
        batch.progress = BatchProgressAggregator.progress(
            items: batch.items,
            jobsByID: jobs
        )
        batch.updatedAt = .now
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        await cancelChildren(in: batch)
    }

    func retryFailed(_ batchID: UUID) async {
        guard var batch = batches[batchID] else { return }
        pausedBatchIDs.remove(batchID)
        var jobsToRetry: [UUID] = []
        for index in batch.items.indices {
            let item = batch.items[index]
            let stoppedAfterFailure =
                item.state == .cancelled
                    && item.errorCode == "stopped_after_failure"
            guard item.isDismissedFromQueue != true && (item.state == .failed
                    || item.state == .needsAttention
                    || stoppedAfterFailure)
            else {
                continue
            }
            if let jobID = item.jobID, jobs[jobID] != nil {
                jobsToRetry.append(jobID)
                batch.items[index].state = .queued
            } else {
                batch.items[index].jobID = nil
                batch.items[index].state = .pendingAnalysis
            }
            batch.items[index].errorCode = nil
            batch.items[index].errorMessage = nil
        }
        batch.admissionPaused = false
        batch.stoppedRetryRequests = nil
        batch.state = .queued
        batch.errorMessage = nil
        recompute(&batch)
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        for jobID in jobsToRetry {
            await commands.retry(jobID)
        }
        startExpansion(batchID: batchID)
    }

    @discardableResult
    func dismissCompletedItems(_ batchID: UUID) -> Set<UUID> {
        dismissTerminalItems(batchID, itemIDs: nil, completedOnly: true)
    }

    @discardableResult
    func dismissTerminalItems(_ batchID: UUID, itemIDs: Set<String>?, completedOnly: Bool = false) -> Set<UUID> {
        guard var batch = batches[batchID],
              batch.destinationStructure != .zipArchive
                || batch.packageURL != nil
        else {
            return []
        }
        var removedJobIDs: Set<UUID> = []
        var didDismissItem = false
        for index in batch.items.indices
            where (completedOnly ? batch.items[index].state == .completed : batch.items[index].state.isTerminal)
                && (itemIDs?.contains(batch.items[index].id) ?? true)
                && batch.items[index].isDismissedFromQueue != true {
            didDismissItem = true
            if let jobID = batch.items[index].jobID {
                removedJobIDs.insert(jobID)
                jobs[jobID] = nil
            }
            batch.items[index].jobID = nil
            batch.items[index].isDismissedFromQueue = true
        }
        guard didDismissItem else { return [] }
        recompute(&batch)
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        return removedJobIDs
    }

    func skipItem(batchID: UUID, itemID: String) async {
        guard var batch = batches[batchID],
              let index = batch.items.firstIndex(where: {
                  $0.id == itemID
              }),
              !batch.items[index].state.isTerminal
        else {
            return
        }
        let jobID = batch.items[index].jobID
        batch.items[index].state = .skipped
        batch.items[index].errorCode = nil
        batch.items[index].errorMessage = nil
        recompute(&batch)
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
        if let jobID {
            await commands.cancel(jobID)
        }
    }

    @discardableResult
    func remove(_ batchID: UUID) async -> Set<UUID> {
        guard let batch = batches[batchID],
              batch.state.isTerminal,
              !childJobs(in: batch).contains(where: { !$0.state.isTerminal || $0.isAwaitingTransferCleanup })
        else {
            return []
        }
        cancelExpansion(batchID: batchID)
        await cancelChildren(in: batch)
        let childJobIDs = Set(batch.items.compactMap(\.jobID))
        for jobID in childJobIDs {
            jobs[jobID] = nil
        }
        batches[batchID] = nil
        continuation.yield(.removeBatch(batchID))
        return childJobIDs
    }

    func removeArchiveEntry(site: String, videoID: String) {
        let id = "\(site.lowercased()):\(videoID)"
        guard archive.removeValue(forKey: id) != nil else { return }
        continuation.yield(.removeArchive(id))
    }

    func recordPackageResult(
        batchID: UUID,
        packageURL: URL?,
        errorMessage: String?
    ) {
        guard var batch = batches[batchID],
              batch.destinationStructure == .zipArchive
        else {
            return
        }
        batch.packageURL = packageURL
        batch.packageErrorMessage = errorMessage.map {
            String($0.prefix(512))
        }
        batch.updatedAt = .now
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
    }

    func retryPackage(_ batchID: UUID) {
        guard var batch = batches[batchID],
              batch.state.isTerminal,
              batch.destinationStructure == .zipArchive
        else {
            return
        }
        batch.packageURL = nil
        batch.packageErrorMessage = nil
        batch.updatedAt = .now
        batches[batchID] = batch
        continuation.yield(.upsertBatch(batch))
    }

    func currentBatches() -> [DownloadBatch] {
        batches.values.sorted { $0.createdAt < $1.createdAt }
    }

    func currentArchive() -> [DownloadArchiveEntry] {
        archive.values.sorted { $0.completedAt < $1.completedAt }
    }

    private func startExpansion(batchID: UUID) {
        guard expansionTasks[batchID] == nil,
              let batch = batches[batchID],
              !batch.state.isTerminal,
              !pausedBatchIDs.contains(batchID),
              batch.items.contains(where: {
                  $0.state == .pendingAnalysis
              })
        else {
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.expand(batchID: batchID, token: token)
        }
        expansionTasks[batchID] = ExpansionTask(
            token: token,
            task: task
        )
    }

    private func expand(batchID: UUID, token: UUID) async {
        defer {
            if expansionTasks[batchID]?.token == token {
                expansionTasks[batchID] = nil
            }
        }
        while !Task.isCancelled {
            guard var batch = batches[batchID],
                  !batch.state.isTerminal,
                  !pausedBatchIDs.contains(batchID),
                  let itemIndex = batch.items.firstIndex(where: {
                      $0.state == .pendingAnalysis
                  })
            else {
                return
            }
            batch.items[itemIndex].state = .analyzing
            batch.state = .running
            batch.updatedAt = .now
            batches[batchID] = batch
            continuation.yield(.upsertBatch(batch))

            let item = batch.items[itemIndex]
            let entry = Self.entry(from: item)
            do {
                let job = try await childFactory.enqueueChild(
                    entry: entry,
                    in: batch,
                    extractorVersion: await extractorVersion()
                )
                if Task.isCancelled
                    || batches[batchID]?.state == .cancelled {
                    await commands.cancel(job.id)
                    return
                }
                jobs[job.id] = job
                guard var latest = batches[batchID],
                      let latestIndex = latest.items.firstIndex(where: {
                          $0.id == item.id
                      }),
                      latest.items[latestIndex].state == .analyzing
                else {
                    await commands.cancel(job.id)
                    continue
                }
                latest.items[latestIndex] =
                    BatchProgressAggregator.updatedItem(
                        latest.items[latestIndex],
                        from: job
                    )
                recompute(&latest)
                batches[batchID] = latest
                continuation.yield(.upsertBatch(latest))
            } catch is CancellationError {
                if var latest = batches[batchID],
                   let latestIndex = latest.items.firstIndex(where: {
                       $0.id == item.id
                   }),
                   latest.items[latestIndex].state == .analyzing {
                    latest.items[latestIndex].state =
                        latest.state == .cancelled
                        ? .cancelled
                        : .pendingAnalysis
                    recompute(&latest)
                    batches[batchID] = latest
                    continuation.yield(.upsertBatch(latest))
                }
                return
            } catch {
                guard var latest = batches[batchID],
                      let latestIndex = latest.items.firstIndex(where: {
                          $0.id == item.id
                      })
                else {
                    return
                }
                latest.items[latestIndex].state = .failed
                latest.items[latestIndex].errorCode =
                    Self.errorCode(error)
                latest.items[latestIndex].errorMessage =
                    Self.safeMessage(error)
                recompute(&latest)
                if !latest.continueOnError {
                    markRemainingItemsStopped(in: &latest)
                    latest.state = .failed
                    latest.errorMessage =
                        "Stopped while preparing \(item.title)."
                }
                batches[batchID] = latest
                continuation.yield(.upsertBatch(latest))
                if !latest.continueOnError {
                    await cancelChildren(in: latest)
                    return
                }
            }
        }
    }

    private func recompute(_ batch: inout DownloadBatch) {
        batch.progress = BatchProgressAggregator.progress(
            items: batch.items,
            jobsByID: jobs
        )
        if !batch.items.isEmpty, batch.items.allSatisfy(\.state.isTerminal) {
            pausedBatchIDs.remove(batch.id)
            batch.admissionPaused = false
            if batch.state == .paused { batch.state = .queued }
        }
        let explicitState: DownloadBatchState? = {
            if batch.state == .cancelled || batch.state == .failed {
                return batch.state
            }
            if pausedBatchIDs.contains(batch.id),
               !childJobs(in: batch).contains(where: {
                   $0.state == .running
                       && !$0.stage.supportsTransferPause
               }) {
                return .paused
            }
            return nil
        }()
        batch.state = BatchProgressAggregator.state(
            items: batch.items,
            explicitState: explicitState
        )
        batch.updatedAt = .now
    }

    private func applyArchiveSkips(to batch: inout DownloadBatch) {
        guard batch.skipArchivedItems else { return }
        for index in batch.items.indices {
            guard let videoID = batch.items[index].videoID,
                  archive["youtube:\(videoID)"] != nil
            else {
                continue
            }
            batch.items[index].state = .archivedSkipped
        }
    }

    private func cancelExpansion(batchID: UUID) {
        expansionTasks.removeValue(forKey: batchID)?.task.cancel()
    }

    private func cancelChildren(
        in batch: DownloadBatch,
        excluding excludedJobID: UUID? = nil
    ) async {
        for job in childJobs(in: batch)
            where !job.state.isTerminal && job.id != excludedJobID {
            await commands.cancel(job.id)
        }
    }

    private func retryRequests(in batch: DownloadBatch) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: childJobs(in: batch).compactMap { job in
            job.retryRequestID.map { (job.id.uuidString, $0) }
        })
    }

    private func childJobs(in batch: DownloadBatch) -> [DownloadJob] {
        batch.items.compactMap {
            $0.jobID.flatMap { jobs[$0] }
        }
    }

    private func markRemainingItemsStopped(
        in batch: inout DownloadBatch
    ) {
        for index in batch.items.indices
            where !batch.items[index].state.isTerminal {
            batch.items[index].state = .cancelled
            batch.items[index].errorCode = "stopped_after_failure"
            batch.items[index].errorMessage =
                "Not started because an earlier item failed."
        }
    }

    private static func entry(
        from item: DownloadBatchItem
    ) -> PlaylistEntry {
        PlaylistEntry(
            id: item.id,
            index: item.playlistIndex,
            videoID: item.videoID,
            canonicalURL: item.sourceURL,
            title: item.title,
            creator: nil,
            durationSeconds: nil,
            thumbnailURL: item.thumbnailURL,
            estimatedBytes: item.estimatedBytes,
            availability: item.sourceURL == nil
                ? .unavailable
                : .available
        )
    }

    private static func indexWidth(entries: [PlaylistEntry]) -> Int {
        max(2, String(entries.map(\.index).max() ?? 1).count)
    }

    private static func errorCode(_ error: any Error) -> String {
        if let factoryError = error as? PlaylistChildJobFactoryError {
            switch factoryError {
            case .unavailableEntry:
                return "playlist_item_unavailable"
            case .missingSourceURL:
                return "playlist_item_missing_url"
            case .entryNotInBatch:
                return "playlist_item_identity_mismatch"
            case .identityMismatch:
                return "playlist_item_identity_mismatch"
            }
        }
        if let extractionError = error as? ExtractionError {
            switch extractionError {
            case .invalidURL:
                return "invalid_url"
            case .unsupportedSite:
                return "unsupported_site"
            case .cancelled:
                return "cancelled"
            case let .extractorFailure(code, _, _):
                return String(code.prefix(128))
            case .invalidResponse:
                return "invalid_extractor_response"
            }
        }
        return "playlist_item_analysis_failed"
    }

    private static func safeMessage(_ error: any Error) -> String {
        let message = error.localizedDescription
        guard !message.localizedCaseInsensitiveContains("http"),
              !message.localizedCaseInsensitiveContains("cookie"),
              !message.localizedCaseInsensitiveContains("token"),
              !message.localizedCaseInsensitiveContains("signature")
        else {
            return "Playlist item analysis failed. Details were redacted."
        }
        return String(message.prefix(512))
    }
}
