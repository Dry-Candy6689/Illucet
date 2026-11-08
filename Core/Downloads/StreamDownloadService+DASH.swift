import Foundation

extension StreamDownloadService {
    func downloadDASHFragments(
        _ plan: ResolvedDASHFragmentPlan,
        jobID: UUID,
        stagingDirectoryURL: URL,
        progress: @escaping DASHFragmentTransferProgressHandler
    ) async throws -> DASHFragmentStagingResult {
        try Task.checkCancellation()
        guard
            stagingDirectoryURL.isFileURL,
            YTDLPStreamResolver.isValidDASHFragmentPlan(plan)
        else {
            throw DASHFragmentDownloadError.invalidPlan
        }

        // Resume validation is also a media request; it must respect the same
        // deadline as a new fragment transfer.
        try await MediaAvailability.waitUntilReady(plan.availableAt)

        let lease = try FragmentSourceLeases.shared.acquire(jobID: jobID, formatID: plan.formatID)
        defer { FragmentSourceLeases.shared.release(lease) }
        let checkpoint = try fragmentCheckpoint(jobID: jobID, formatID: plan.formatID,
                                                fields: Self.DASHResumeFields(plan))

        let destinations: [URL]
        do {
            destinations = try plan.fragments.map { fragment in
                let destination = stagingDirectoryURL.appending(
                    path: String(
                        format: "fragment-%06d.part",
                        fragment.position
                    ),
                    directoryHint: .notDirectory
                )
                _ = try destinationRoots.identity(for: destination)
                return destination
            }
        } catch {
            throw DASHFragmentDownloadError.invalidStagingDestination
        }
        guard Set(destinations.map(\.standardizedFileURL)).count
            == destinations.count
        else {
            throw DASHFragmentDownloadError.invalidStagingDestination
        }

        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        var stagedFragments: [StagedDASHFragment] = []
        stagedFragments.reserveCapacity(plan.fragments.count)
        var completedBytes: Int64 = 0
        var reusedBytes: Int64 = 0
        for (fragment, destination) in zip(plan.fragments, destinations) {
            try Task.checkCancellation()
            try discardDASHFragment(at: destination)
            let restored = try await restoreFragment(checkpoint: checkpoint,
                position: fragment.position, remoteURL: fragment.URL, headers: plan.HTTPHeaders,
                destination: destination, jobID: jobID, expectedBytes: fragment.expectedBytes)
            let staged: StagedDASHFragment
            if let restored {
                staged = StagedDASHFragment(position: fragment.position, fileURL: destination, byteCount: restored)
                progress(DASHFragmentTransferProgress(jobID: jobID, formatID: plan.formatID,
                    fragmentPosition: fragment.position, completedFragmentCount: stagedFragments.count,
                    completedBytesBeforeFragment: completedBytes, fragmentCount: plan.fragments.count,
                    fragmentProgress: StreamTransferProgress(jobID: jobID, streamID: plan.formatID,
                        bytesWritten: 0, totalBytesWritten: restored, totalBytesExpected: fragment.expectedBytes,
                        instantaneousBytesPerSecond: nil, verifiedReusableBytes: restored, networkBytesReceived: 0),
                    verifiedReusableBytesBeforeFragment: reusedBytes))
                let reused = reusedBytes.addingReportingOverflow(restored)
                guard !reused.overflow else { throw DASHFragmentDownloadError.couldNotStageFragment }
                reusedBytes = reused.partialValue
            } else {
                staged = try await stageDASHFragment(
                fragment,
                plan: plan,
                destinationURL: destination,
                completedFragmentCount: stagedFragments.count,
                completedBytesBeforeFragment: completedBytes,
                verifiedReusableBytesBeforeFragment: reusedBytes,
                jobID: jobID,
                progress: progress,
                checkpoint: checkpoint
                )
            }
            stagedFragments.append(staged)
            let addition = completedBytes.addingReportingOverflow(
                staged.byteCount
            )
            guard !addition.overflow else {
                try discardDASHFragments(stagedFragments)
                throw DASHFragmentDownloadError.couldNotStageFragment
            }
            completedBytes = addition.partialValue
        }
        if let expectedBytes = plan.expectedBytes {
            var actualBytes: Int64 = 0
            do {
                for staged in stagedFragments {
                    guard let size = exactFileSize(staged.fileURL) else {
                        throw DASHFragmentDownloadError
                            .couldNotStageFragment
                    }
                    let addition = actualBytes.addingReportingOverflow(size)
                    guard !addition.overflow else {
                        throw DASHFragmentDownloadError
                            .couldNotStageFragment
                    }
                    actualBytes = addition.partialValue
                }
                guard actualBytes == expectedBytes else {
                    throw DASHFragmentDownloadError
                        .aggregateByteCountMismatch(
                            expected: expectedBytes,
                            actual: actualBytes
                        )
                }
            } catch {
                try discardDASHFragments(stagedFragments)
                throw error
            }
        }
        return DASHFragmentStagingResult(
            videoID: plan.videoID,
            formatID: plan.formatID,
            fragments: stagedFragments
        )
    }

    private func stageDASHFragment(
        _ fragment: ResolvedDASHFragment,
        plan: ResolvedDASHFragmentPlan,
        destinationURL: URL,
        completedFragmentCount: Int,
        completedBytesBeforeFragment: Int64,
        verifiedReusableBytesBeforeFragment: Int64,
        jobID: UUID,
        progress: @escaping DASHFragmentTransferProgressHandler,
        checkpoint: FragmentResumeCheckpoint
    ) async throws -> StagedDASHFragment {
        try discardDASHFragment(at: destinationURL)
        let transport = ResolvedStream(
            formatID: plan.formatID,
            URL: fragment.URL,
            HTTPHeaders: plan.HTTPHeaders,
            fileExtension: nil,
            protocolName: "https",
            sourceType: "direct_http",
            hasVideo: plan.hasVideo,
            hasAudio: plan.hasAudio,
            expectedBytes: fragment.expectedBytes,
            httpChunkSize: nil,
            availableAt: plan.availableAt
        )
        var retriesUsed = 0
        while true {
            try Task.checkCancellation()
            do {
                fragmentResponseValidators.watch(destinationURL)
                let downloaded = try await download(
                    transport,
                    jobID: jobID,
                    destinationURL: destinationURL,
                    verifiedExpectedBytes: fragment.expectedBytes
                ) { fragmentProgress in
                    progress(
                        DASHFragmentTransferProgress(
                            jobID: jobID,
                            formatID: plan.formatID,
                            fragmentPosition: fragment.position,
                            completedFragmentCount: completedFragmentCount,
                            completedBytesBeforeFragment:
                                completedBytesBeforeFragment,
                            fragmentCount: plan.fragments.count,
                            fragmentProgress: fragmentProgress,
                            verifiedReusableBytesBeforeFragment: verifiedReusableBytesBeforeFragment
                        )
                    )
                }
                guard downloaded.fileURL.standardizedFileURL
                    == destinationURL.standardizedFileURL
                else {
                    throw DASHFragmentDownloadError
                        .couldNotStageFragment
                }
                guard let actualBytes = exactFileSize(destinationURL) else {
                    throw DASHFragmentDownloadError
                        .couldNotStageFragment
                }
                if let expectedBytes = fragment.expectedBytes {
                    guard actualBytes == expectedBytes else {
                        throw DASHFragmentDownloadError
                            .fragmentByteCountMismatch(
                                position: fragment.position,
                                expected: expectedBytes,
                                actual: actualBytes
                            )
                    }
                }
                try checkpoint.accept(position: fragment.position, fileURL: destinationURL,
                    remoteURL: fragment.URL, validator: fragmentResponseValidators.take(destinationURL))
                return StagedDASHFragment(
                    position: fragment.position,
                    fileURL: destinationURL,
                    byteCount: actualBytes
                )
            } catch {
                _ = fragmentResponseValidators.take(destinationURL)
                try discardDASHFragment(at: destinationURL)
                try Task.checkCancellation()
                guard
                    dashFragmentRetryPolicy.permitsRetry(of: error),
                    retriesUsed < dashFragmentRetryPolicy.maximumRetries
                else {
                    throw error
                }
                retriesUsed += 1
                try await dashFragmentRetrySleeper(
                    dashFragmentRetryPolicy.delay(
                        forRetryNumber: retriesUsed
                    )
                )
            }
        }
    }

    private func discardDASHFragment(at URL: URL) throws {
        guard fileManager.fileExists(atPath: URL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: URL)
        } catch {
            throw DASHFragmentDownloadError.couldNotDiscardRejectedBytes
        }
        guard !fileManager.fileExists(atPath: URL.path) else {
            throw DASHFragmentDownloadError.couldNotDiscardRejectedBytes
        }
    }

    private func discardDASHFragments(
        _ fragments: [StagedDASHFragment]
    ) throws {
        var deletionFailed = false
        for fragment in fragments {
            do {
                try discardDASHFragment(at: fragment.fileURL)
            } catch {
                deletionFailed = true
            }
        }
        if deletionFailed {
            throw DASHFragmentDownloadError.couldNotDiscardRejectedBytes
        }
    }

    func exactFileSize(_ URL: URL) -> Int64? {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: URL.path
            ),
            let sizeNumber = attributes[.size] as? NSNumber
        else {
            return nil
        }
        let size = sizeNumber.int64Value
        guard
            size >= 0
        else {
            return nil
        }
        return size
    }

}
