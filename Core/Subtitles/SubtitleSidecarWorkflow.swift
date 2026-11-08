import Foundation

final class SubtitleSidecarWorkflow: @unchecked Sendable {
    private let transport: any SubtitleTransporting
    private let exporter: ExportManager
    private let fileManager: FileManager
    private let maximumRefreshAttempts: Int

    init(
        transport: any SubtitleTransporting,
        exporter: ExportManager,
        fileManager: FileManager = .default,
        maximumRefreshAttempts: Int = 1
    ) {
        self.transport = transport
        self.exporter = exporter
        self.fileManager = fileManager
        self.maximumRefreshAttempts = min(
            max(maximumRefreshAttempts, 0),
            1
        )
    }

    static func live(
        exporter: ExportManager,
        fileManager: FileManager = .default
    ) -> SubtitleSidecarWorkflow {
        SubtitleSidecarWorkflow(
            transport: SecureSubtitleTransport(
                resolver: SystemSubtitleDNSResolver(),
                networking: URLSessionSubtitleHTTPClient()
            ),
            exporter: exporter,
            fileManager: fileManager
        )
    }

    func prepare(
        plans: [SubtitleDownloadPlan],
        sourceURL: URL,
        expectedVideoID: String,
        extractor: any ExtractorEngine,
        temporaryRoot: URL
    ) async throws -> [PreparedSubtitleSidecar] {
        guard !plans.isEmpty else { return [] }
        let directory = temporaryRoot.appending(
            path: "Subtitles",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var prepared: [PreparedSubtitleSidecar] = []
        do {
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                let output = try await downloadAndProcess(
                    plan: plan,
                    sourceURL: sourceURL,
                    expectedVideoID: expectedVideoID,
                    extractor: extractor
                )
                let finalURL = directory.appending(
                    path: "subtitle-\(index)-\(UUID().uuidString).\(plan.kind.rawValue)"
                )
                let partialURL = finalURL.appendingPathExtension(
                    "\(UUID().uuidString).partial"
                )
                do {
                    try output.write(to: partialURL, options: .withoutOverwriting)
                    try Task.checkCancellation()
                    try fileManager.moveItem(at: partialURL, to: finalURL)
                } catch {
                    try? fileManager.removeItem(at: partialURL)
                    try? fileManager.removeItem(at: finalURL)
                    throw error
                }
                prepared.append(
                    PreparedSubtitleSidecar(
                        selection: plan.selection,
                        kind: plan.kind,
                        temporaryURL: finalURL
                    )
                )
            }
            return prepared
        } catch {
            cleanup(prepared)
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func export(
        _ prepared: [PreparedSubtitleSidecar],
        mediaResult: ExportResult,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> SubtitleSidecarExport {
        guard !prepared.isEmpty else {
            return SubtitleSidecarExport(
                records: [],
                shareRequest: mediaResult.shareRequest
            )
        }
        guard let mediaURL = mediaResult.fileURL else {
            throw SubtitlePipelineError.exportFailed
        }
        let filenames = try SubtitleFilenamePlanner.filenames(
            mediaURL: mediaURL,
            sidecars: prepared
        )
        do {
            let URLs = try await exporter.exportSubtitleSidecars(
                sourceURLs: prepared.map(\.temporaryURL),
                filenames: filenames,
                destination: job.configuration.destination,
                mediaFileURL: mediaURL,
                folderBookmark: folderBookmark,
                jobID: job.id
            )
            let records = zip(zip(prepared, filenames), URLs).map {
                pair, URL in
                SubtitleSidecarRecord(
                    selection: pair.0.selection,
                    kind: pair.0.kind,
                    filename: pair.1,
                    localURL: URL
                )
            }
            let shareRequest: SharePresentationRequest?
            if job.configuration.destination == .share {
                shareRequest = await exporter.pendingShareRequest(
                    jobID: job.id,
                    title: job.title
                )
            } else {
                shareRequest = mediaResult.shareRequest
            }
            guard job.configuration.destination != .share
                || shareRequest != nil
            else {
                throw SubtitlePipelineError.exportFailed
            }
            return SubtitleSidecarExport(
                records: records,
                shareRequest: shareRequest
            )
        } catch {
            if job.configuration.destination == .share {
                try? await exporter.discardPendingShare(jobID: job.id)
            }
            throw error
        }
    }

    func exportForRetainedFilesCopy(
        _ prepared: [PreparedSubtitleSidecar],
        mediaURL: URL,
        job: DownloadJob,
        folderBookmark: Data?
    ) async throws -> [SubtitleSidecarRecord] {
        let partialResult = ExportResult(
            fileURL: mediaURL,
            photoAssetLocalIdentifiers: [],
            shareRequest: nil,
            outcome: .file
        )
        return try await export(
            prepared,
            mediaResult: partialResult,
            job: job,
            folderBookmark: folderBookmark
        ).records
    }

    func cleanup(_ prepared: [PreparedSubtitleSidecar]) {
        for sidecar in prepared {
            try? fileManager.removeItem(at: sidecar.temporaryURL)
        }
    }

    private func downloadAndProcess(
        plan: SubtitleDownloadPlan,
        sourceURL: URL,
        expectedVideoID: String,
        extractor: any ExtractorEngine
    ) async throws -> Data {
        var activePlan = plan
        var refreshCount = 0
        while true {
            do {
                let body = try await transport.download(
                    from: activePlan.transportURL
                )
                return try WebVTTProcessor.processTransportResponse(
                    body,
                    as: activePlan.kind
                )
            } catch let error as SubtitlePipelineError {
                guard error.permitsExactTransportRefresh,
                      refreshCount < maximumRefreshAttempts
                else {
                    throw error
                }
                refreshCount += 1
                let refreshed = try await extractor.analyze(url: sourceURL)
                activePlan = try SubtitleSelectionPlanner.refreshedPlan(
                    selection: plan.selection,
                    kind: plan.kind,
                    metadata: refreshed,
                    expectedVideoID: expectedVideoID
                )
            }
        }
    }
}
