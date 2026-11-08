import Foundation

/// Reconciles durable job checkpoints with URLSession tasks and reconstructs
/// conservative progress after relaunch. Signed stream URLs remain outside
/// persisted state.
final class DownloadRestorationController: @unchecked Sendable {
    private let downloader: any StreamDownloading
    private let fileManager: FileManager

    init(
        downloader: any StreamDownloading,
        fileManager: FileManager = .default
    ) {
        self.downloader = downloader
        self.fileManager = fileManager
    }

    func restore(_ restoredJobs: [DownloadJob], continuingJobIDs: Set<UUID>? = nil) async -> [DownloadJob] {
        let registrations = await downloader.reconcileBackgroundTasks()
        let running = Dictionary(uniqueKeysWithValues: restoredJobs.filter { $0.state == .running || $0.state == .queued }
            .map { ($0.id, $0) })
        for jobID in Set(registrations.map(\.descriptor.jobID)) {
            // Do not turn a system background wake into a user pause. Unknown,
            // terminal and explicitly gated jobs retain conservative suspension.
            let valid = running[jobID].map { job in
                registrations.filter { $0.descriptor.jobID == jobID }.allSatisfy {
                    job.selectedFormatIDs.contains($0.descriptor.streamID)
                }
            } ?? false
            if !valid || continuingJobIDs.map({ !$0.contains(jobID) }) == true {
                _ = await downloader.pause(jobID: jobID)
            }
        }
        let registrationsByJob = Dictionary(
            grouping: registrations,
            by: { $0.descriptor.jobID }
        )
        return restoredJobs.map { restored in
            let active = registrationsByJob[restored.id] ?? []
            var job = restored
            job.activeTransferDescriptors = active.isEmpty
                ? nil
                : active.map(\.descriptor)
            return reconciled(job, registrations: active)
        }
    }

    private func reconciled(
        _ restored: DownloadJob,
        registrations: [StreamTransferRegistration]
    ) -> DownloadJob {
        var job = restored
        var checkpoint = job.pipelineCheckpoint
        if job.state == .completed || (checkpoint?.phase == .complete && job.exportOutcome != nil) {
            job.state = .completed; job.stage = .complete
            job.activeTransferDescriptors = nil
            return job
        }
        if var receipts = checkpoint?.publicationReceipts {
            for index in receipts.indices where receipts[index].state == .committing {
                receipts[index].state = .outcomeUnknown
            }
            checkpoint?.publicationReceipts = receipts
            job.pipelineCheckpoint = checkpoint
            if job.hasUnknownPublication {
                job.state = .needsAttention; job.stage = .waiting
                job.foregroundResumeReason = nil
                job.errorCode = "export_outcome_unknown"
                job.errorMessage = ExportPublicationError.outcomeUnknown.localizedDescription
                job.updatedAt = .now
                return job
            }
        }
        let persistedDescriptors =
            job.activeTransferDescriptors ?? []
        let descriptors = registrations.map(\.descriptor)
            + persistedDescriptors
        if checkpoint == nil, !descriptors.isEmpty {
            checkpoint = DownloadPipelineCheckpoint(
                phase: .transferring
            )
        }
        let roots = StreamTransferDestinationRoots.live(
            fileManager: fileManager
        )
        for descriptor in descriptors {
            guard
                let URL = try? descriptor.destinationURL(in: roots),
                reusableFile(URL) != nil
            else {
                continue
            }
            checkpoint?.sourceFiles[descriptor.streamID] = URL
        }
        job.pipelineCheckpoint = checkpoint
        reconstructTransferProgress(
            for: &job,
            registrations: registrations
        )

        switch job.state {
        case .running:
            if checkpoint != nil || !registrations.isEmpty {
                job.state = .queued
                job.stage = .restoring
                job.errorCode = nil
                job.errorMessage = nil
            } else {
                job.state = .needsAttention
                job.stage = .waiting
                job.errorCode = "app_was_terminated"
                job.errorMessage =
                    "The app stopped before a safe recovery checkpoint was saved. Retry to restart this job."
            }
        case .waitingForRetry, .waitingForCellularApproval:
            job.state = .queued
            job.stage = .restoring
        case .paused:
            if registrations.isEmpty {
                // Keep user pause intent across relaunch. Resume will enqueue a
                // fresh plan and validate completed fragment checkpoints.
                job.resumableTransferStage = nil
                job.stage = .restoring
            }
        case .queued, .waitingForNetwork, .waitingForWiFi,
             .waitingForPower, .needsAttention, .failed, .cancelled,
             .completed:
            break
        }
        job.updatedAt = .now
        return job
    }

    private func reconstructTransferProgress(
        for job: inout DownloadJob,
        registrations: [StreamTransferRegistration]
    ) {
        guard !registrations.isEmpty else { return }
        let activeStreamIDs = Set(
            registrations.map(\.descriptor.streamID)
        )
        let completedBytes = job.pipelineCheckpoint?.sourceFiles.reduce(
            into: Int64(0)
        ) { total, entry in
            guard !activeStreamIDs.contains(entry.key),
                  let reusable = reusableFile(entry.value)
            else {
                return
            }
            total += fileSize(reusable)
        } ?? 0
        // Every live range registration reports the same verified staging
        // baseline and full-source total. Count that baseline once per source.
        let bySource = Dictionary(grouping: registrations) { $0.descriptor.destination }
        var receivedBytes: Int64 = 0, verifiedRangeBytes: Int64 = 0
        var activeTotals: [Int64] = []
        for source in bySource.values {
            let verified = source.map(\.verifiedReusableBytes).max() ?? 0
            let inFlight = source.reduce(Int64(0)) { $0 + max(0, $1.bytesReceived - $1.verifiedReusableBytes) }
            receivedBytes = StorageByteArithmetic.adding(receivedBytes, StorageByteArithmetic.adding(verified, inFlight))
            verifiedRangeBytes = StorageByteArithmetic.adding(verifiedRangeBytes, verified)
            if source.allSatisfy({ $0.totalBytesExpected == source.first?.totalBytesExpected }),
               let expected = source.first?.totalBytesExpected { activeTotals.append(expected) }
        }
        let reconstructedBytes = StorageByteArithmetic.adding(completedBytes, receivedBytes)
        let reconstructedVerifiedBytes = StorageByteArithmetic.adding(completedBytes, verifiedRangeBytes)
        let reconstructedTotal: Int64? = {
            if let persisted = job.progress.totalBytes, persisted > 0 { return persisted }
            guard activeTotals.count == bySource.count else { return nil }
            return activeTotals.reduce(completedBytes, StorageByteArithmetic.adding)
        }()

        job.progress.bytesDownloaded = reconstructedTotal.map {
            min(reconstructedBytes, $0)
        } ?? reconstructedBytes
        job.progress.verifiedReusableBytes = reconstructedTotal.map {
            min(reconstructedVerifiedBytes, $0)
        } ?? reconstructedVerifiedBytes
        job.progress.totalBytes = reconstructedTotal
        job.progress.instantaneousBytesPerSecond = nil
        job.progress.smoothedBytesPerSecond = nil
        job.progress.downloadETASeconds = nil
        job.progress.overallETASeconds = nil
        job.progress.sampleCount = 0
        job.progress.currentStream = registrations.first?
            .descriptor.streamID
        if let reconstructedTotal, reconstructedTotal > 0 {
            job.progress.overallFraction = min(
                0.78,
                Double(job.progress.bytesDownloaded)
                    / Double(reconstructedTotal) * 0.78
            )
        } else {
            job.progress.overallFraction = nil
        }
    }

    private func reusableFile(_ URL: URL?) -> URL? {
        guard
            let URL,
            URL.isFileURL,
            fileManager.fileExists(atPath: URL.path),
            fileSize(URL) > 0
        else {
            return nil
        }
        return URL
    }

    private func fileSize(_ URL: URL) -> Int64 {
        (
            try? URL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        ).map(Int64.init) ?? 0
    }
}
