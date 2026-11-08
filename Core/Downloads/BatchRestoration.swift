import Foundation

struct BatchRestorationResult: Equatable, Sendable {
    let batches: [DownloadBatch]
    let archive: [DownloadArchiveEntry]
    let resumableBatchIDs: Set<UUID>
}

enum BatchRestoration {
    static func reconcile(
        batches: [DownloadBatch],
        jobs: [DownloadJob],
        archive: [DownloadArchiveEntry],
        now: Date = .now
    ) -> BatchRestorationResult {
        let jobsByID = Dictionary(
            uniqueKeysWithValues: jobs.map { ($0.id, $0) }
        )
        let jobsByMembership = Dictionary(
            grouping: jobs.compactMap { job -> DownloadJob? in
                job.batchMembership == nil ? nil : job
            },
            by: {
                MembershipKey(
                    batchID: $0.batchMembership!.batchID,
                    entryID: $0.batchMembership!.entryID
                )
            }
        )
        var archiveByID = Dictionary(
            uniqueKeysWithValues: archive.map { ($0.id, $0) }
        )
        var resumableBatchIDs: Set<UUID> = []
        let restored = batches.map { original -> DownloadBatch in
            var batch = original
            var explicitState: DownloadBatchState? = batch.state
            if jobs.contains(where: { job in
                job.batchMembership?.batchID == batch.id && !job.state.isTerminal && job.state != .needsAttention
                    && job.retryRequestID.map { batch.stoppedRetryRequests?[job.id.uuidString] != $0 } == true
            }) && batch.state.isTerminal {
                explicitState = nil
                batch.admissionPaused = false
                batch.errorMessage = nil
            }
            for index in batch.items.indices {
                var item = batch.items[index]
                let key = MembershipKey(
                    batchID: batch.id,
                    entryID: item.id
                )
                let candidates = jobsByMembership[key] ?? []
                let persistedJob = item.jobID.flatMap { jobsByID[$0] }
                let matchingJob: DownloadJob?
                if let persistedJob,
                   persistedJob.batchMembership?.batchID == batch.id,
                   persistedJob.batchMembership?.entryID == item.id {
                    matchingJob = persistedJob
                } else if candidates.count == 1 {
                    matchingJob = candidates[0]
                } else {
                    matchingJob = nil
                }

                if candidates.count > 1 {
                    item.state = .needsAttention
                    item.errorCode = "duplicate_batch_child"
                    item.errorMessage =
                        "Several jobs claim this playlist item."
                } else if let matchingJob, ![.skipped, .archivedSkipped, .unavailable].contains(item.state) {
                    item = BatchProgressAggregator.updatedItem(
                        item,
                        from: matchingJob
                    )
                    if matchingJob.state == .completed,
                       matchingJob.exportOutcome != .duplicateSkipped {
                        let record = DownloadArchiveEntry.youtube(
                            videoID: matchingJob.videoID,
                            completedAt: matchingJob.updatedAt,
                            batchID: batch.id
                        )
                        archiveByID[record.id] = record
                    }
                } else if item.jobID != nil,
                          !item.state.isTerminal {
                    item.state = .needsAttention
                    item.errorCode = "missing_batch_child"
                    item.errorMessage =
                        "The persisted child job could not be restored."
                } else if (
                    item.state == .analyzing
                        || item.state == .queued
                        || item.state == .running
                        || item.state == .paused
                ) && explicitState?.isTerminal != true {
                    item.jobID = nil
                    item.state = .pendingAnalysis
                    item.errorCode = nil
                    item.errorMessage = nil
                }

                if batch.skipArchivedItems,
                   item.jobID == nil,
                   let videoID = item.videoID,
                   archiveByID["youtube:\(videoID)"] != nil,
                   !item.state.isTerminal {
                    item.state = .archivedSkipped
                    item.errorCode = nil
                    item.errorMessage = nil
                }
                batch.items[index] = item
            }
            batch.progress = BatchProgressAggregator.progress(
                items: batch.items,
                jobsByID: jobsByID
            )
            if batch.admissionPaused == true, !batch.items.isEmpty,
               batch.items.allSatisfy(\.state.isTerminal) {
                batch.admissionPaused = false
                if explicitState == .paused { explicitState = nil }
            }
            if batch.admissionPaused == true {
                explicitState = jobs.contains { $0.batchMembership?.batchID == batch.id && $0.state == .running && !$0.stage.supportsTransferPause }
                    ? nil : .paused
            }
            batch.state = BatchProgressAggregator.state(
                items: batch.items,
                explicitState: explicitState
            )
            if batch.admissionPaused != true, [.preparing, .queued, .running].contains(batch.state),
               batch.items.contains(where: {
                   $0.state == .pendingAnalysis
               }) {
                resumableBatchIDs.insert(batch.id)
            }
            batch.updatedAt = now
            return batch
        }
        return BatchRestorationResult(
            batches: restored,
            archive: archiveByID.values.sorted {
                if $0.completedAt == $1.completedAt {
                    return $0.id < $1.id
                }
                return $0.completedAt < $1.completedAt
            },
            resumableBatchIDs: resumableBatchIDs
        )
    }

    private struct MembershipKey: Hashable {
        let batchID: UUID
        let entryID: String
    }
}
