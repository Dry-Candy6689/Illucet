import Foundation

extension StreamDownloadService {
    func hasRegisteredOneGETTask(
        jobID: UUID,
        streamID: String,
        destination: StreamTransferDestinationIdentity
    ) -> Bool {
        let key = StreamTransferKey(
            jobID: jobID,
            streamID: streamID,
            destination: destination,
            mediaRole: nil,
            expectedTotalBytes: nil,
            byteRange: nil,
            rangeChunkBytes: nil,
            stagingDestination: nil
        )
        return lifecycle.hasLiveTask(for: key)
    }

    func downloadRanges(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        destinationIdentity: StreamTransferDestinationIdentity,
        role: StreamTransferMediaRole,
        plan: StreamRangePlan,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> StreamDownloadResult {
        let stagingDirectory = StreamRangeStaging.directory(
            for: destinationURL,
            role: role,
            totalBytes: plan.totalBytes
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        var chunksByRange: [StreamByteRange: URL] = [:]
        for range in plan.ranges {
            let chunkURL = StreamRangeStaging.chunkURL(
                in: stagingDirectory,
                range: range
            )
            guard validatedStagingIdentity(
                for: chunkURL,
                destination: destinationIdentity,
                role: role,
                totalBytes: plan.totalBytes,
                range: range
            ) != nil else {
                throw StreamDownloadError.rangeAssemblyFailure
            }
            if isVerifiedChunk(chunkURL, range: range) {
                chunksByRange[range] = chunkURL
            } else if fileManager.fileExists(atPath: chunkURL.path) {
                try? fileManager.removeItem(at: chunkURL)
            }
        }
        let initiallyReusableBytes = chunksByRange.keys.reduce(into: Int64(0)) {
            $0 += $1.length
        }
        var verifiedBytes = initiallyReusableBytes
        var requestedRangeCount = 0
        var networkBytesReceived: Int64 = 0
        progress(
            StreamTransferProgress(
                jobID: jobID,
                streamID: stream.formatID,
                bytesWritten: 0,
                totalBytesWritten: verifiedBytes,
                totalBytesExpected: plan.totalBytes,
                instantaneousBytesPerSecond: nil,
                verifiedReusableBytes: verifiedBytes,
                networkBytesReceived: 0
            )
        )

        let missing = plan.ranges.filter { chunksByRange[$0] == nil }
        let measurements = RangeTransferMeasurements(jobID: jobID, streamID: stream.formatID,
            total: plan.totalBytes, reusable: initiallyReusableBytes)
        // Confirm the server honors Range before queuing the remainder. A 200
        // response then needs only one full download, rather than 128 copies.
        var remaining = missing
        var confirmedRangeSupport = false
        while !remaining.isEmpty {
            // Foreground rate limits keep their small, paced requests. Once
            // backgrounded, hand off the remaining batch without timer pacing.
            let count = confirmedRangeSupport && bandwidthLimiter.permitsRequestBatch(jobID: jobID) ? remaining.count : 1
            let batch = Array(remaining.prefix(count))
            remaining.removeFirst(count)
            var prepared: [(StreamByteRange, PreparedStreamTransfer)] = []
            do {
                for range in batch {
                    try Task.checkCancellation()
                    let chunkURL = StreamRangeStaging.chunkURL(in: stagingDirectory, range: range)
                    guard let stagingIdentity = validatedStagingIdentity(for: chunkURL,
                        destination: destinationIdentity, role: role, totalBytes: plan.totalBytes, range: range) else {
                        throw StreamDownloadError.rangeAssemblyFailure
                    }
                    let transfer = try await prepareTransferTask(stream, jobID: jobID,
                        destinationIdentity: destinationIdentity, mediaRole: role,
                        expectedTotalBytes: plan.totalBytes, byteRange: range,
                        rangeChunkBytes: plan.chunkBytes, stagingDestination: stagingIdentity)
                    prepared.append((range, transfer))
                }
                // The durable descriptors exist before any task in this batch
                // starts. The daemon can run the whole batch while we sleep.
                try await persistTransferPlan(jobID: jobID, transfers: prepared.map { $0.1 })
                requestedRangeCount += prepared.count
                let fullResponse = try await withThrowingTaskGroup(of: (StreamByteRange, URL).self) { group in
                    for (range, transfer) in prepared {
                        group.addTask {
                            let file = try await self.awaitTransfer(transfer, logicalExpectedBytes: range.length) { event in
                                progress(measurements.record(range: range, event: event))
                            }
                            return (range, file)
                        }
                    }
                    while let (range, downloaded) = try await group.next() {
                        if downloaded.standardizedFileURL == destinationURL.standardizedFileURL {
                            group.cancelAll()
                            return true
                        }
                        let chunkURL = StreamRangeStaging.chunkURL(in: stagingDirectory, range: range)
                        guard downloaded.standardizedFileURL == chunkURL.standardizedFileURL,
                              isVerifiedChunk(downloaded, range: range) else {
                            group.cancelAll()
                            throw StreamDownloadError.invalidPartialContent
                        }
                        chunksByRange[range] = downloaded
                        verifiedBytes += range.length
                        progress(measurements.accept(range: range))
                    }
                    return false
                }
                if fullResponse {
                    // No sibling is allowed to write the full destination after
                    // this method returns or while staging is being deleted.
                    await cancelPreparedTransfers(prepared.map { $0.1 })
                    try? fileManager.removeItem(at: stagingDirectory)
                    return StreamDownloadResult(fileURL: destinationURL, strategy: .rangeIgnoredFullResponse,
                        plannedRangeCount: plan.ranges.count, requestedRangeCount: requestedRangeCount,
                        verifiedReusableBytes: initiallyReusableBytes,
                        networkBytesReceived: max(plan.totalBytes, measurements.networkBytes))
                }
                confirmedRangeSupport = true
            } catch {
                await cancelPreparedTransfers(prepared.map { $0.1 })
                throw error
            }
        }
        networkBytesReceived = measurements.networkBytes
        // Concatenation is in-process work; completed native chunks remain
        // available when iOS does not grant processing time yet.
        try await requireExecution(jobID: jobID)

        let chunks = try plan.ranges.map { range -> StreamRangeChunk in
            guard let URL = chunksByRange[range] else {
                throw StreamDownloadError.rangeAssemblyFailure
            }
            return StreamRangeChunk(range: range, fileURL: URL)
        }
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                guard isVerifiedFile(
                    destinationURL,
                    expectedLength: plan.totalBytes
                ) else {
                    throw StreamDownloadError.rangeAssemblyFailure
                }
            } else {
                try StreamRangeAssembler.assemble(
                    plan: plan,
                    chunks: chunks,
                    destinationURL: destinationURL,
                    fileManager: fileManager
                )
            }
        } catch {
            throw StreamDownloadError.rangeAssemblyFailure
        }
        guard isVerifiedFile(
            destinationURL,
            expectedLength: plan.totalBytes
        ) else {
            try? fileManager.removeItem(at: destinationURL)
            throw StreamDownloadError.rangeAssemblyFailure
        }
        try? fileManager.removeItem(at: stagingDirectory)
        return StreamDownloadResult(
            fileURL: destinationURL,
            strategy: .boundedRanges,
            plannedRangeCount: plan.ranges.count,
            requestedRangeCount: requestedRangeCount,
            verifiedReusableBytes: initiallyReusableBytes,
            networkBytesReceived: networkBytesReceived
        )
    }

}

/// Cumulative per-range observations prevent out-of-order callbacks from
/// double-counting completed bytes or making aggregate progress move backward.
private final class RangeTransferMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private let jobID: UUID
    private let streamID: String
    private let total: Int64
    private let reusable: Int64
    private var received: [StreamByteRange: Int64] = [:]
    private var accepted: Set<StreamByteRange> = []

    init(jobID: UUID, streamID: String, total: Int64, reusable: Int64) {
        self.jobID = jobID; self.streamID = streamID; self.total = total; self.reusable = reusable
    }

    var networkBytes: Int64 { lock.withLock { received.values.reduce(0, +) } }

    func record(range: StreamByteRange, event: StreamTransferProgress) -> StreamTransferProgress {
        lock.withLock {
            received[range] = max(received[range] ?? 0, max(0, event.networkBytesReceived))
            return snapshot()
        }
    }

    func accept(range: StreamByteRange) -> StreamTransferProgress {
        lock.withLock {
            accepted.insert(range)
            received[range] = max(received[range] ?? 0, range.length)
            return snapshot()
        }
    }

    private func snapshot() -> StreamTransferProgress {
        let verified = reusable + accepted.reduce(0) { $0 + $1.length }
        let pending = received.reduce(Int64(0)) { sum, entry in
            sum + (accepted.contains(entry.key) ? 0 : min(entry.key.length, entry.value))
        }
        return StreamTransferProgress(jobID: jobID, streamID: streamID, bytesWritten: 0,
            totalBytesWritten: min(total, verified + pending), totalBytesExpected: total,
            instantaneousBytesPerSecond: nil, verifiedReusableBytes: verified,
            networkBytesReceived: received.values.reduce(0, +))
    }
}
