import Foundation
import SwiftUI

extension IllucetAppModel {
    func sceneActivityChanged(id: UUID, active: Bool) {
        let eligible = ContinuedProcessingController.shared.setSceneActive(id, active: active)
        sceneEventRevision &+= 1
        let revision = sceneEventRevision
        Task {
            await coordinator.setForegroundEligibility(eligible, revision: revision)
            if eligible && !fixtureMode { await refreshQueueOnActivation() }
            if !active { await persistImmediately() }
        }
    }

    func observeCoordinator() {
        updateTask = Task { [weak self, coordinator] in
            var lastRendered: [UUID: Date] = [:]
            for await event in coordinator.updates {
                guard let self else { return }
                var currentEvent = event
                if case let .upsertJob(job) = event {
                    // A suspended UI consumer can have old progress queued behind
                    // ActivityKit work. Render the authoritative snapshot immediately.
                    if let latest = await coordinator.currentJob(job.id) {
                        guard lastRendered[job.id] != latest.updatedAt else { continue }
                        lastRendered[job.id] = latest.updatedAt
                        currentEvent = .upsertJob(latest)
                        handle(currentEvent)
                    }
                } else {
                    handle(event)
                }
                if case let .upsertJob(job) = currentEvent, !fixtureMode {
                    await liveActivityController.synchronize(jobs: await coordinator.currentJobs(), enabled: settings.liveActivities)
                    await ContinuedProcessingController.shared.update(job: job)
                    // Notification delivery is system IPC. It must not hold up
                    // the next authoritative Queue/Live Activity transition.
                    let notificationSettings = settings
                    Task { [notifications] in await notifications.observe(job: job, settings: notificationSettings) }
                }
                var shareCleanup: (UUID, ShareCompletionState)?
                if case let .addHistory(record) = event, record.destination == .share,
                   let state = record.shareCompletionState, state == .completed || state == .cancelled {
                    shareCleanup = (record.jobID, state)
                } else if case let .updateShareLifecycle(jobID, state, _) = event,
                          state == .completed || state == .cancelled {
                    shareCleanup = (jobID, state)
                }
                if let (jobID, state) = shareCleanup {
                    do {
                        try await saveSnapshot()
                        await coordinator.acknowledgeSharePersistence(jobID: jobID, state: state)
                    } catch {
                        await diagnostics.record(.error, subsystem: "persistence", event: "share_outcome_save_failed")
                    }
                }
                if case let .removeJob(id) = event {
                    await notifications.forget(id)
                    await liveActivityController.synchronize(jobs: jobs, enabled: settings.liveActivities && !fixtureMode)
                }
            }
        }
    }

    func refreshQueueOnActivation() async {
        guard startupState == .ready else { return }
        await coordinator.resumeForegroundJobs()
        let latest = await coordinator.currentJobs()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for job in latest { handle(.upsertJob(job)) }
        }
        await liveActivityController.synchronize(jobs: jobs, enabled: settings.liveActivities && !fixtureMode)
        await resumeDeferredShortcuts()
    }

    func observeBatchController() {
        batchUpdateTask = Task { [weak self, batchController] in
            for await event in batchController.updates {
                guard let self else { return }
                handle(event)
                if case let .upsertBatch(batch) = event, !fixtureMode {
                    await notifications.observe(batch: batch, settings: settings)
                }
            }
        }
    }

    func handle(_ event: DownloadCoordinatorEvent) {
        switch event {
        case let .foregroundCompletion(jobID, time):
            if !fixtureMode, settings.pipPreferences.enabled,
               settings.pipPreferences.frequency == .downloadUpdates {
                foregroundDownloadCompletions[jobID] = time
            }
            return
        case let .upsertJob(job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                guard job.updatedAt > jobs[index].updatedAt else { return }
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            if job.state.isTerminal {
                discardActionPresentations(for: job.id)
            }
            if selectedJob?.id == job.id {
                selectedJob = job
            }
            Task { await batchController.receive(job) }
        case .addHistory(var record):
            record.outputReferences = outputResolver.references(for: record.ownedFileURLs,
                previous: record.outputReferences, folderBookmark: snapshot.filesFolderBookmark)
            history.removeAll { $0.jobID == record.jobID }
            history.insert(record, at: 0)
            if selectedHistoryRecord?.jobID == record.jobID { selectedHistoryRecord = record }
            presentExportFeedback(for: record)
            requestStorageRefresh()
        case let .removeJob(id):
            jobs.removeAll { $0.id == id }
        case let .requestDuplicate(conflict):
            enqueuePresentation(.duplicate(conflict))
        case let .requestNetworkAccess(request):
            enqueuePresentation(.network(request))
        case let .cellularPromptPreferenceChanged(enabled):
            settings.askBeforeCellular = enabled
        case let .presentShare(request):
            enqueuePresentation(.share(request))
        case let .updateShareLifecycle(jobID, state, errorDescription):
            if let index = history.firstIndex(where: {
                $0.jobID == jobID
            }) {
                history[index].shareCompletionState = state
                history[index].shareUpdatedAt = .now
                history[index].shareErrorMessage = errorDescription.map {
                    String($0.prefix(256))
                }
                switch state {
                case .unconfirmed:
                    history[index].exportOutcome = .shareUnconfirmed
                case .pending:
                    history[index].exportOutcome = .sharePending
                case .completed:
                    history[index].exportOutcome = .shared
                    history[index].fileURL = nil
                case .cancelled:
                    history[index].exportOutcome = .shareCancelled
                    history[index].fileURL = nil
                case .failed:
                    history[index].exportOutcome = .shareFailed
                }
                if selectedHistoryRecord?.jobID == jobID { selectedHistoryRecord = history[index] }
            }
        }
        scheduleSave()
        updateIdleTimer()
    }

    private func presentExportFeedback(for record: HistoryRecord) {
        if record.status == .completed, record.savedToPhotos {
            alert = AppAlert(
                title: "Saved to Photos",
                message: record.destination == .filesAndPhotos
                    ? "The verified output was saved to the selected Files folder and Photos."
                    : "The verified output was saved to Photos."
            )
        } else if record.status == .failed,
                  record.destination == .filesAndPhotos,
                  record.fileURL != nil,
                  let errorMessage = record.errorMessage,
                  errorMessage.localizedCaseInsensitiveContains("Photos") {
            alert = AppAlert(
                title: "Saved to Files; Photos failed",
                message: errorMessage
            )
        }
    }

    private func handle(_ event: DownloadBatchControllerEvent) {
        switch event {
        case let .upsertBatch(batch):
            if let index = batches.firstIndex(where: {
                $0.id == batch.id
            }) {
                batches[index] = batch
            } else {
                batches.append(batch)
            }
            beginPackagingIfNeeded(batch)
        case let .removeBatch(id):
            batches.removeAll { $0.id == id }
            packageTasks.removeValue(forKey: id)?.cancel()
            packagingBatchIDs.remove(id)
        case let .upsertArchive(entry):
            downloadArchive.removeAll { $0.id == entry.id }
            downloadArchive.append(entry)
        case let .removeArchive(id):
            downloadArchive.removeAll { $0.id == id }
        }
        scheduleSave()
    }

    private func beginPackagingIfNeeded(_ batch: DownloadBatch) {
        guard batch.state == .completed,
              batch.destinationStructure == .zipArchive,
              batch.packageURL == nil,
              batch.packageErrorMessage == nil,
              packageTasks[batch.id] == nil
        else {
            return
        }
        packagingBatchIDs.insert(batch.id)
        let jobs = jobs.filter {
            $0.batchMembership?.batchID == batch.id
        }
        let bookmark = snapshot.filesFolderBookmark
        let duplicateHandling = settings.duplicateHandling
        packageTasks[batch.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await batchPackageService
                    .createAndExport(
                        batch: batch,
                        jobs: jobs,
                        filesFolderBookmark: bookmark,
                        duplicateHandling: duplicateHandling
                    )
                packagingBatchIDs.remove(batch.id)
                packageTasks[batch.id] = nil
                await batchController.recordPackageResult(
                    batchID: batch.id,
                    packageURL: result.packageURL,
                    errorMessage: nil
                )
                await diagnostics.record(
                    .info,
                    subsystem: "batch",
                    event: "zip_package_complete",
                    detail:
                        "batch_id=\(batch.id.uuidString), entries=\(result.entryCount), bytes=\(result.archiveBytes)"
                )
            } catch is CancellationError {
                packagingBatchIDs.remove(batch.id)
                packageTasks[batch.id] = nil
            } catch {
                packagingBatchIDs.remove(batch.id)
                packageTasks[batch.id] = nil
                await batchController.recordPackageResult(
                    batchID: batch.id,
                    packageURL: nil,
                    errorMessage: error.localizedDescription
                )
                await diagnostics.record(
                    .error,
                    subsystem: "batch",
                    event: "zip_package_failed",
                    detail: "batch_id=\(batch.id.uuidString)"
                )
            }
        }
    }
}
