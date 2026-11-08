import Foundation

extension IllucetAppModel {
    var hasCancellableWork: Bool {
        jobs.contains { !$0.state.isTerminal } || batches.contains { !$0.state.isTerminal }
    }

    var queueSelectableItems: Set<SelectionItem> {
        var items = Set(jobs.filter { $0.batchMembership == nil && $0.state.isTerminal && !$0.isAwaitingTransferCleanup }.map { SelectionItem.job($0.id) })
        for batch in batches {
            guard !packagingBatchIDs.contains(batch.id) else { continue }
            if batch.state.isTerminal {
                if !jobs.contains(where: { $0.batchMembership?.batchID == batch.id && (!$0.state.isTerminal || $0.isAwaitingTransferCleanup) }) {
                    items.insert(.batch(batch.id))
                }
            } else {
                guard batch.destinationStructure != .zipArchive || batch.packageURL != nil else { continue }
                for item in batch.items where item.state.isTerminal && item.isDismissedFromQueue != true {
                    if let id = item.jobID, jobs.contains(where: { $0.id == id && $0.isAwaitingTransferCleanup }) { continue }
                    items.insert(.batchItem(batch.id, item.id))
                }
            }
        }
        return items
    }

    func removeQueueSelection() async {
        let selected = queueSelection.selected.intersection(queueSelectableItems)
        var jobIDs: Set<UUID> = [], batchIDs: Set<UUID> = []
        var children: [UUID: Set<String>] = [:]
        for item in selected {
            switch item {
            case .job(let id): jobIDs.insert(id)
            case .batch(let id): batchIDs.insert(id)
            case .batchItem(let batch, let id): children[batch, default: []].insert(id)
            case .history: break
            }
        }
        await manageQueue(jobIDs: jobIDs, batchIDs: batchIDs, cancel: false)
        for (batch, ids) in children where !batchIDs.contains(batch) {
            let jobs = await batchController.dismissTerminalItems(batch, itemIDs: ids)
            await coordinator.removeTerminalJobs(jobs)
        }
        queueSelection.cancel()
    }
}
