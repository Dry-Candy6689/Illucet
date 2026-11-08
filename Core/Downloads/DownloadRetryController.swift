import Foundation

typealias DownloadRetrySleeper =
    @Sendable (_ delaySeconds: Double) async throws -> Void

/// Converts typed failures into retry actions, checkpoints the visible retry
/// state, and owns backoff waiting. A retry always re-enters the pipeline at
/// analysis/resolution, so expiring signed media URLs are never persisted.
struct DownloadRetryController: Sendable {
    private let policy: DownloadRetryPolicy
    private let sleeper: DownloadRetrySleeper

    init(
        policy: DownloadRetryPolicy = DownloadRetryPolicy(),
        sleeper: @escaping DownloadRetrySleeper = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.policy = policy
        self.sleeper = sleeper
    }

    func isCancellation(_ error: any Error) -> Bool {
        policy.classify(error) == .cancelled
    }

    func exhausted(error: any Error, job: DownloadJob) -> Bool {
        guard job.maximumRetries > 0, job.retryCount >= job.maximumRetries,
              case .retryable = policy.classify(error) else { return false }
        return true
    }

    func disposition(
        for error: any Error,
        job: DownloadJob
    ) -> DownloadRetryDisposition {
        policy.disposition(
            for: error,
            retriesAlreadyUsed: job.retryCount,
            maximumRetries: job.maximumRetries
        )
    }

    func checkpoint(
        _ job: DownloadJob,
        reason: DownloadRetryReason,
        delay: Double,
        now: Date = .now
    ) -> DownloadJob {
        var checkpointed = job
        checkpointed.retryCount += 1
        checkpointed.lastRetryReason = reason
        checkpointed.retryAvailableAt = now.addingTimeInterval(delay)
        checkpointed.state = .waitingForRetry
        checkpointed.stage = .waitingToRetry
        checkpointed.errorCode = nil
        checkpointed.errorMessage =
            "Temporary failure. Retry \(checkpointed.retryCount) of \(checkpointed.maximumRetries) is scheduled."
        checkpointed.updatedAt = now
        return checkpointed
    }

    func wait(delay: Double) async throws {
        try await sleeper(delay)
    }
}
