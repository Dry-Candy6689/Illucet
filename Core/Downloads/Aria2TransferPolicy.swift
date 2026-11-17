import Foundation

protocol Aria2Downloading: Sendable {
    func download(_ stream: ResolvedStream, jobID: UUID, destinationURL: URL, expectedBytes: Int64?,
                  speedLimit: Int64?, progress: @escaping StreamTransferProgressHandler) async throws -> URL
    func cancel(jobID: UUID) async
}

enum Aria2TransferPolicy {
    static let explanation = "aria2 handles public HTTP/HTTPS files while Illucet has execution time. Streaming formats and signed-in downloads use Native or yt-dlp. Incomplete aria2 transfers restart after pause or suspension."

    static func permits(stream: ResolvedStream, accountID: UUID?) -> Bool {
        let allowed: Set<String> = ["user-agent", "referer", "origin", "accept", "accept-language", "sec-fetch-mode"]
        return accountID == nil && ["http", "https"].contains(stream.protocolName.lowercased())
            && ["http", "https"].contains(stream.URL.scheme?.lowercased() ?? "")
            && stream.URL.host != nil && stream.URL.user == nil && stream.URL.password == nil
            && stream.URL.absoluteString.utf8.count <= 16_384 && stream.HTTPHeaders.count <= 10
            && stream.HTTPHeaders.allSatisfy { allowed.contains($0.key.lowercased()) && $0.value.utf8.count <= 4096
                && !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }

    static func downloadIfSelected(_ stream: ResolvedStream, job: DownloadJob, destination: URL,
        expectedBytes: Int64?, baseBytes: Int64, combinedExpectedBytes: Int64?,
        downloader: any Aria2Downloading, context: DownloadPipelineContext,
        diagnostics: DiagnosticStore? = nil) async throws -> URL? {
        guard job.configuration.enginePreferences?.download == .aria2 else { return nil }
        guard permits(stream: stream, accountID: job.configuration.accountID) else {
            await diagnostics?.record(.info, subsystem: "transport", event: "aria2_fallback",
                                      detail: "Native handles this protocol or account-bound request.")
            return nil
        }
        let lease = try FragmentSourceLeases.shared.acquire(jobID: job.id, formatID: stream.formatID)
        defer { FragmentSourceLeases.shared.release(lease) }
        try await context.requireExecution(job.id)
        await diagnostics?.record(.info, subsystem: "transport", event: "aria2_transfer_started", detail: "engine=aria2")
        let settings = await context.settingsSnapshot()
        let rates = [settings.downloadSpeedLimitBytesPerSecond, job.configuration.speedLimitBytesPerSecond]
            .compactMap { $0 }.filter { $0 > 0 }
        return try await downloader.download(stream, jobID: job.id, destinationURL: destination,
            expectedBytes: expectedBytes, speedLimit: rates.min()) { progress in
            Task { await context.recordTransferProgress(progress, baseBytes, combinedExpectedBytes) }
        }
    }
}
