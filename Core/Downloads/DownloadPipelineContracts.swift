import Foundation

enum DownloadPipelineControl: Error {
    case deferredForNetwork
    case restartAfterExecutionGrant
}

struct BackgroundExecutionUnavailable: Error { let status: ContinuedProcessingStatus }

struct DownloadPipelineContext: Sendable {
    var requireExecution: @Sendable (UUID) async throws -> Void = { _ in }
    let currentJob:
        @Sendable (UUID) async -> DownloadJob?
    let settingsSnapshot:
        @Sendable () async -> AppSettings
    let folderBookmarkSnapshot:
        @Sendable () async -> Data?
    let persistJob:
        @Sendable (DownloadJob) async -> Void
    let checkpointJob:
        @Sendable (
            DownloadJob,
            DownloadPipelinePhase,
            [String: URL]?,
            URL?,
            URL?
        ) async -> DownloadJob
    let authorizeNetwork:
        @Sendable (UUID) async throws -> Bool
    let streamNetworkPolicy:
        @Sendable (DownloadJob) async -> StreamTransferNetworkPolicy
    let acquireTransferPermit:
        @Sendable (UUID) async throws -> Void
    let releaseTransferPermit:
        @Sendable (UUID) async -> Void
    let acquireProcessingPermit:
        @Sendable (UUID) async throws -> Void
    let releaseProcessingPermit:
        @Sendable (UUID) async -> Void
    let recordTransferProgress:
        @Sendable (
            StreamTransferProgress,
            Int64,
            Int64?
        ) async -> Void
    let recordProcessingProgress:
        @Sendable (
            MediaProcessingProgress,
            UUID,
            DownloadStage
        ) async -> Void
    let persistPublication: @Sendable (DownloadJob) async throws -> DownloadJob
    let publishOutput: @Sendable (DownloadJob, ExportPublicationPlan, URL) async throws -> DownloadJob
    let completeDuplicateSkip:
        @Sendable (DownloadJob) async -> DownloadJob
    let checkpointExport:
        @Sendable (
            DownloadJob,
            MediaProbeResult?,
            ExportResult
        ) async -> DownloadJob
    let checkpointPartialFile:
        @Sendable (
            DownloadJob,
            URL,
            MediaProbeResult?
        ) async -> DownloadJob
    let completeExport:
        @Sendable (
            DownloadJob,
            MediaProbeResult?,
            ExportResult,
            [String],
            SharePresentationRequest?,
            URL
        ) async -> DownloadJob

    func update(
        _ job: DownloadJob,
        state: DownloadJobState,
        stage: DownloadStage
    ) async throws -> DownloadJob {
        try Task.checkCancellation()
        if stage.requiresInProcessExecution { try await requireExecution(job.id) }
        var updated = job
        let current = await currentJob(job.id)
        if let current {
            updated.progress = current.progress
            updated.activeTransferDescriptors =
                current.activeTransferDescriptors
        }
        if (current?.stage ?? job.stage) != stage {
            updated.progress.processingFraction = nil
            updated.progress.processingETASeconds = nil
        }
        updated.state = state
        updated.stage = stage
        updated.updatedAt = .now
        await persistJob(updated)
        return await currentJob(job.id) ?? updated
    }

    func checkpoint(
        _ job: DownloadJob,
        phase: DownloadPipelinePhase,
        sourceFiles: [String: URL]? = nil,
        artworkURL: URL? = nil,
        processedFileURL: URL? = nil
    ) async -> DownloadJob {
        await checkpointJob(
            job,
            phase,
            sourceFiles,
            artworkURL,
            processedFileURL
        )
    }

    func reportingProcessingProgress<Result: Sendable>(
        operationID: UUID,
        expectedStage: DownloadStage,
        operation: (
            @escaping MediaProcessingProgressHandler
        ) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let relay = ProcessingProgressRelay { progress in
            await recordProcessingProgress(
                progress,
                operationID,
                expectedStage
            )
        }
        do {
            let result = try await operation(relay.report)
            await relay.finish()
            return result
        } catch {
            relay.invalidate()
            throw error
        }
    }
}
