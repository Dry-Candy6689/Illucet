import Foundation

enum QueueDisplayEntry: Equatable, Identifiable, Sendable {
    case job(DownloadJob)
    case batch(DownloadBatch)

    var id: String {
        switch self {
        case .job(let job): "job.\(job.id.uuidString)"
        case .batch(let batch): "batch.\(batch.id.uuidString)"
        }
    }

    var createdAt: Date {
        switch self {
        case .job(let job): job.createdAt
        case .batch(let batch): batch.createdAt
        }
    }
}

enum BatchQueueOrdering {
    /// Sorting affects presentation only. A playlist remains one row, including
    /// during its final package creation after all child transfers have finished.
    static func activeFirstEntries(jobs: [DownloadJob], batches: [DownloadBatch],
                                   packaging: Set<UUID>, newestFirst: Bool) -> [QueueDisplayEntry] {
        let activeBatches = Set(jobs.filter(\.isWorkingInQueue)
            .compactMap { $0.batchMembership?.batchID }).union(packaging)
        func active(_ entry: QueueDisplayEntry) -> Bool {
            switch entry {
            case .job(let job): job.isWorkingInQueue
            case .batch(let batch): activeBatches.contains(batch.id) || batch.state == .preparing
                || batch.items.contains { $0.state == .analyzing }
            }
        }
        let ordered = chronologicalEntries(jobs: jobs, batches: batches, newestFirst: newestFirst)
        return ordered.filter { active($0) } + ordered.filter { !active($0) }
    }

    /// Presentation order never changes scheduling priority or moves a row when its state changes.
    static func chronologicalEntries(jobs: [DownloadJob], batches: [DownloadBatch],
                                     newestFirst: Bool) -> [QueueDisplayEntry] {
        let entries = jobs.filter { $0.batchMembership == nil }.map(QueueDisplayEntry.job)
            + batches.map(QueueDisplayEntry.batch)
        return entries.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
    }

    static func reorderUnbatchedJobs(
        in orderedJobs: [DownloadJob],
        fromOffsets offsets: IndexSet,
        toOffset: Int
    ) -> [UUID]? {
        let active = orderedJobs.filter { !$0.state.isTerminal }
        var unbatched = active.filter { $0.batchMembership == nil }
        let validOffsets = offsets.filter {
            unbatched.indices.contains($0)
        }
        guard !validOffsets.isEmpty else { return nil }
        let moving = validOffsets.map { unbatched[$0] }
        for index in validOffsets.sorted(by: >) {
            unbatched.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.count {
            $0 < toOffset
        }
        let insertion = min(
            max(0, toOffset - removedBeforeDestination),
            unbatched.count
        )
        unbatched.insert(contentsOf: moving, at: insertion)

        var replacementIndex = 0
        return active.map { job -> UUID in
            guard job.batchMembership == nil else {
                return job.id
            }
            defer { replacementIndex += 1 }
            return unbatched[replacementIndex].id
        }
    }
}

extension DownloadJob {
    var isWorkingInQueue: Bool {
        state == .running && ![DownloadStage.waiting, .waitingForTransfer,
            .waitingForProcessing, .waitingForBackgroundTime, .waitingToRetry, .complete].contains(stage)
    }
}
