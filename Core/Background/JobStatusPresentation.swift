import Foundation

/// Queue activity, without treating a paused or gated job as a live transfer.
enum QueueTabBadge: String, Equatable, Sendable {
    case attention, downloading, processing, waiting, paused, completed

    var accessibilityLabel: String {
        switch self {
        case .attention: "Needs attention"
        case .downloading: "Downloading"
        case .processing: "Processing"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .completed: "New downloads completed"
        }
    }

    var systemImage: String {
        switch self {
        case .attention: "exclamationmark"
        case .downloading: "arrow.down"
        case .processing: "gearshape.fill"
        case .waiting: "clock"
        case .paused: "pause.fill"
        case .completed: "circle.fill"
        }
    }

    /// Native iPad tabs accept text badges; iPhone renders the matching SF Symbol.
    var nativeText: String {
        switch self {
        case .attention: "!"
        case .downloading: "↓"
        case .processing: "↻"
        case .waiting: "◷"
        case .paused: "Ⅱ"
        case .completed: "•"
        }
    }

    static func resolve(jobs: [DownloadJob], batches: [DownloadBatch],
                        packaging: Set<UUID>, hasPendingAction: Bool,
                        hasNewCompletion: Bool) -> Self? {
        if hasPendingAction || jobs.contains(where: {
            [.failed, .needsAttention, .waitingForCellularApproval].contains($0.state)
        }) || batches.contains(where: {
            [.failed, .needsAttention, .completedWithFailures].contains($0.state) || $0.packageErrorMessage != nil
        }) { return .attention }
        let running = jobs.filter { $0.state == .running }
        if running.contains(where: { $0.stage.presentsTransferMetrics }) { return .downloading }
        let waitingStages: Set<DownloadStage> = [.waiting, .waitingForTransfer, .waitingForProcessing,
            .waitingForBackgroundTime, .waitingToRetry]
        if running.contains(where: { !waitingStages.contains($0.stage) })
            || !packaging.isEmpty || batches.contains(where: {
                [.preparing, .running].contains($0.state)
                    || ($0.state == .completed && $0.destinationStructure == .zipArchive && $0.packageURL == nil)
            }) { return .processing }
        if !running.isEmpty || jobs.contains(where: {
            [.queued, .waitingForNetwork, .waitingForWiFi, .waitingForRetry, .waitingForPower].contains($0.state)
        }) || batches.contains(where: { $0.state == .queued }) { return .waiting }
        if jobs.contains(where: { $0.state == .paused }) || batches.contains(where: { $0.state == .paused }) { return .paused }
        return hasNewCompletion ? .completed : nil
    }
}

/// A bounded, secret-free presentation; never includes URLs, headers or raw errors.
struct JobStatusPresentation: Equatable, Sendable {
    let stage: String
    let fraction: Double?
    let speed: String?
    let remaining: String?

    /// System-owned task UI uses percent, never an unexplained synthetic count.
    static func updateSystemProgress(_ progress: Progress, stage: String, fraction: Double?) {
        progress.localizedDescription = stage
        if let fraction, fraction.isFinite {
            let percent = Int64(min(1, max(0, fraction)) * 100)
            progress.totalUnitCount = 100
            progress.completedUnitCount = percent
            progress.localizedAdditionalDescription = "\(percent)% complete"
        } else {
            progress.completedUnitCount = 0
            progress.totalUnitCount = 0
            progress.localizedAdditionalDescription = stage
        }
    }

    init(job: DownloadJob) {
        let running = job.state == .running
        if job.resumesOnForeground { stage = "Open Illucet to continue" }
        else {
            switch job.state {
            case .running: stage = job.stage.rawValue
            case .queued: stage = "Queued"
            case .waitingForNetwork: stage = "Waiting for a connection"
            case .waitingForWiFi: stage = "Waiting for Wi-Fi"
            case .waitingForPower: stage = "Waiting for charging"
            case .waitingForCellularApproval: stage = "Open Illucet to approve cellular data"
            case .waitingForRetry: stage = "Waiting to retry"
            case .needsAttention: stage = "Needs attention"
            case .paused: stage = "Paused"
            case .failed: stage = "Download failed"
            case .completed: stage = "Download completed"
            case .cancelled: stage = "Download cancelled"
            }
        }
        let transfer = running && job.stage.presentsTransferMetrics
        let processing = running && job.stage.isProcessingWork
        let candidate = (transfer || job.isWaitingForTransferSlot) ? job.progress.totalBytes.flatMap { total in
            total > 0 ? Double(job.progress.bytesDownloaded) / Double(total) : nil
        } : processing ? job.progress.processingFraction : job.state == .completed ? 1 : nil
        fraction = candidate.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        if transfer, job.progress.sampleCount >= 2,
           let value = job.progress.smoothedBytesPerSecond, value.isFinite, value > 0,
           value < Double(Int64.max) {
            speed = ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
        } else { speed = nil }
        let eta = transfer ? job.progress.downloadETASeconds : processing ? job.progress.processingETASeconds : nil
        if let eta, eta.isFinite, eta > 0, eta < 604_800 {
            remaining = "\(transfer ? "Transfer" : "Processing"): ≈ \(Self.remainingDuration(eta)) left"
        } else { remaining = nil }
    }

    /// Avoid suggesting second-level precision for estimates several minutes away.
    static func remainingDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 604_800 else { return "Unknown" }
        let step = seconds < 60 ? 5.0 : seconds < 3_600 ? 15.0 : 60.0
        let rounded = Int(ceil(seconds / step) * step)
        if rounded < 60 { return "\(rounded)s" }
        if rounded < 3_600 {
            return rounded % 60 == 0 ? "\(rounded / 60)m" : "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded / 3_600)h \((rounded % 3_600) / 60)m"
    }
}
