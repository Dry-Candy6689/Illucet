import Foundation
import UIKit

extension IllucetAppModel {
    func persistPublicationCheckpoint(_ job: DownloadJob) async throws {
        if case .blocked = startupState { throw ExportPublicationError.persistenceUnavailable }
        let previous = jobs.first { $0.id == job.id }
        let filesChanged = previous.map { HistoryRecord(job: $0).ownedFileURLs } != HistoryRecord(job: job).ownedFileURLs
        let newlyCompleted = job.state == .completed && previous?.state != .completed
        saveTask?.cancel()
        handle(.upsertJob(job))
        if job.state == .completed || job.state == .failed {
            history.removeAll { $0.jobID == job.id }
            history.insert(HistoryRecord(job: job), at: 0)
        }
        try await saveSnapshot()
        if filesChanged || newlyCompleted { requestStorageRefresh() }
    }

    func persistImmediately() async {
        saveTask?.cancel()
        await saveNow()
    }

    func addRecent(_ metadata: MediaMetadata) {
        addRecent(
            URL: metadata.canonicalURL,
            title: metadata.title,
            thumbnailURL: metadata.thumbnails.last?.url
        )
    }

    func addRecent(
        URL: URL,
        title: String,
        thumbnailURL: URL?
    ) {
        recentLinks.removeAll { $0.url == URL }
        recentLinks.insert(
            RecentLink(
                url: URL,
                title: title,
                thumbnailURL: thumbnailURL
            ),
            at: 0
        )
        recentLinks = Array(recentLinks.prefix(8))
        scheduleSave()
    }

    var protectedTemporaryJobIDs: Set<UUID> {
        Set(
            jobs.compactMap { job in
                if !job.state.isTerminal || job.isAwaitingTransferCleanup
                    || job.shareCompletionState == .pending
                    || (job.state != .completed && job.pipelineCheckpoint?.publicationPlan != nil) {
                    return job.id
                }
                return nil
            }
        )
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        guard !startupState.blocksInteraction else { return }
        do {
            try await saveSnapshot()
        } catch {
            await diagnostics.record(.error, subsystem: "persistence", event: "save_failed", detail: nil)
        }
    }

    func saveSnapshot() async throws {
        let writeRevision = (snapshot.writeRevision ?? 0) + 1
        snapshot = IllucetAppPersistedState(
            settings: settings,
            jobs: jobs,
            batches: batches,
            downloadArchive: downloadArchive,
            history: history,
            recentLinks: recentLinks,
            quickStartPresets: quickStartPresets,
            firstRunState: firstRunState,
            updateStatus: updateStatus
        ).applying(to: snapshot)
        snapshot.writeRevision = writeRevision
        try await persistence.save(snapshot)
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            settings.keepScreenAwake && activeJobCount > 0
    }

    static var validationTarget: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        "iPhone"
        #endif
    }
}
