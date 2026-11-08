import Foundation

enum BatchProgressAggregator {
    static func updatedItem(
        _ item: DownloadBatchItem,
        from job: DownloadJob
    ) -> DownloadBatchItem {
        var updated = item
        updated.jobID = job.id
        updated.title = job.title
        updated.thumbnailURL = job.thumbnailURL ?? item.thumbnailURL
        updated.state = itemState(for: job)
        if job.state == .failed || job.state == .needsAttention {
            updated.errorCode = job.errorCode
            updated.errorMessage = job.errorMessage
        } else {
            updated.errorCode = nil
            updated.errorMessage = nil
        }
        return updated
    }

    static func progress(
        items: [DownloadBatchItem],
        jobsByID: [UUID: DownloadJob]
    ) -> DownloadBatchProgress {
        let completed = items.count { $0.state == .completed }
        let failed = items.count {
            $0.state == .failed || $0.state == .unavailable
        }
        let skipped = items.count {
            $0.state == .archivedSkipped || $0.state == .skipped
        }
        let active = items.count {
            $0.state == .analyzing || $0.state == .running
        }
        let childJobs = items.compactMap {
            $0.jobID.flatMap { jobsByID[$0] }
        }
        let bytesDownloaded = childJobs.reduce(into: Int64(0)) {
            $0 += max(0, $1.progress.bytesDownloaded)
        }

        var hasUnknownTotal = false
        var totalBytes: Int64 = 0
        for item in items {
            if item.state == .archivedSkipped
                || item.state == .skipped
                || item.state == .unavailable {
                continue
            }
            let job = item.jobID.flatMap { jobsByID[$0] }
            if let total = job?.progress.totalBytes ?? item.estimatedBytes,
               total >= 0 {
                totalBytes += total
            } else {
                hasUnknownTotal = true
            }
        }

        let fractions = items.map { item -> Double in
            if item.state.isTerminal {
                return 1
            }
            guard let jobID = item.jobID,
                  let job = jobsByID[jobID],
                  let value = job.progress.overallFraction,
                  value.isFinite
            else {
                return 0
            }
            return min(max(value, 0), 1)
        }
        let overall = items.isEmpty
            ? 1
            : fractions.reduce(0, +) / Double(items.count)
        return DownloadBatchProgress(
            totalItems: items.count,
            completedItems: completed,
            failedItems: failed,
            skippedItems: skipped,
            activeItems: active,
            bytesDownloaded: bytesDownloaded,
            totalBytes: hasUnknownTotal ? nil : totalBytes,
            overallFraction: overall
        )
    }

    static func state(
        items: [DownloadBatchItem],
        explicitState: DownloadBatchState?
    ) -> DownloadBatchState {
        if explicitState == .cancelled {
            return .cancelled
        }
        if explicitState == .paused {
            return .paused
        }
        if explicitState == .failed {
            return .failed
        }
        guard !items.isEmpty else {
            return .failed
        }
        if items.allSatisfy(\.state.isTerminal) {
            let failures = items.count {
                $0.state == .failed || $0.state == .unavailable
            }
            let cancellations = items.count { $0.state == .cancelled }
            let successes = items.count {
                $0.state == .completed
                    || $0.state == .archivedSkipped
                    || $0.state == .skipped
            }
            if failures > 0 || (cancellations > 0 && successes > 0) {
                return .completedWithFailures
            }
            if cancellations == items.count {
                return .cancelled
            }
            if failures == items.count {
                return .failed
            }
            return .completed
        }
        if items.contains(where: { $0.state == .needsAttention }) {
            return .needsAttention
        }
        if items.contains(where: {
            $0.state == .running || $0.state == .analyzing
        }) {
            return .running
        }
        if items.allSatisfy({
            $0.state == .paused || $0.state.isTerminal
        }) {
            return .paused
        }
        if items.contains(where: { $0.state == .queued }) {
            return .queued
        }
        return .preparing
    }

    private static func itemState(
        for job: DownloadJob
    ) -> DownloadBatchItemState {
        switch job.state {
        case .queued, .waitingForNetwork, .waitingForWiFi,
             .waitingForCellularApproval, .waitingForRetry,
             .waitingForPower:
            return .queued
        case .running:
            return .running
        case .paused:
            return .paused
        case .needsAttention:
            return .needsAttention
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .completed:
            return job.exportOutcome == .duplicateSkipped
                ? .skipped
                : .completed
        }
    }
}
