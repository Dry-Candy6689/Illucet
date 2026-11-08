import Foundation

enum TransferAdmissionPolicy {
    /// Every transfer phase consumes one job slot, including the gap between
    /// video/audio transfers. Processing and paused work consume none.
    static func requestsTransfer(_ job: DownloadJob) -> Bool {
        guard job.state == .queued || job.state == .running else { return false }
        return job.stage.presentsTransferMetrics || [DownloadStage.waiting, .analyzing, .preparing,
            .waitingForTransfer, .verifyingSources].contains(job.stage)
    }
}
