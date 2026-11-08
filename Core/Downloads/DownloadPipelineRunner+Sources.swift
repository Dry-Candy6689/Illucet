import Foundation

enum ProductionSourceResolution: Sendable {
    case direct(SelectedSourceFact, ResolvedStream)
    case DASH(SelectedSourceFact, ResolvedDASHFragmentPlan)
    case HLS(SelectedSourceFact, ResolvedHLSPlaylistSelection)

    var selection: SelectedSourceFact {
        switch self {
        case let .direct(selection, _),
             let .DASH(selection, _),
             let .HLS(selection, _):
            selection
        }
    }

    var expectedBytes: Int64? {
        switch self {
        case let .direct(_, stream): stream.expectedBytes
        case let .DASH(_, plan): plan.expectedBytes
        case .HLS: nil
        }
    }
}

struct DASHProductionAcquisition: Sendable {
    let fileURL: URL
    let stagingDirectoryURL: URL
}

struct HLSProductionAcquisition: Sendable {
    let fileURL: URL
}

extension DownloadPipelineRunner {
    func sourceDestination(
        for selection: SelectedSourceFact,
        jobID: UUID,
        temporaryRoot: URL
    ) throws -> URL {
        // Format identity stays exact. Lossy filename sanitization could make
        // two distinct selected streams overwrite or reuse the same file.
        let formatID = selection.formatID
        guard
            !formatID.isEmpty,
            formatID != ".",
            formatID != "..",
            !formatID.contains("/"),
            !formatID.contains("\\"),
            !formatID.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw StreamTransferDescriptorError.invalidStreamID
        }
        let extensionValue = FilenameSystem.sanitizeComponent(
            selection.fileExtension ?? "media"
        )
        let filename = "\(formatID).\(extensionValue)"
        let root = temporaryRoot.standardizedFileURL
        let destination = root.appending(
            path: filename,
            directoryHint: .notDirectory
        )
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            root.isFileURL,
            root.lastPathComponent == "Illucet-\(jobID.uuidString)",
            rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true,
            destination.lastPathComponent == filename,
            destination.deletingLastPathComponent() == root,
            (try? fileManager.destinationOfSymbolicLink(
                atPath: destination.path
            )) == nil,
            destination.resolvingSymlinksInPath()
                .deletingLastPathComponent().path
                == root.resolvingSymlinksInPath().path
        else {
            throw StreamTransferDescriptorError.invalidDestination
        }
        return destination
    }

    func reusableSourceFile(
        _ URL: URL,
        expectedBytes: Int64?,
        allowedRoot: URL
    ) -> URL? {
        let candidate = URL.standardizedFileURL
        let root = allowedRoot.standardizedFileURL
        guard
            candidate.path.hasPrefix(root.path + "/"),
            let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            candidate.resolvingSymlinksInPath().path.hasPrefix(
                root.resolvingSymlinksInPath().path + "/"
            )
        else {
            return nil
        }
        guard let reusable = reusableFile(candidate) else { return nil }
        if let expectedBytes, fileSize(reusable) != expectedBytes {
            try? fileManager.removeItem(at: reusable)
            return nil
        }
        return reusable
    }

    func resolveSources(
        _ selections: [SelectedSourceFact],
        sourceURL: URL,
        expectedVideoID: String,
        accountID: UUID? = nil,
        reuseToken: String? = nil
    ) async throws -> [ProductionSourceResolution] {
        let directSelections = selections.filter {
            $0.transport == .directHTTP
        }
        var directByFormatID: [String: ResolvedStream] = [:]
        if !directSelections.isEmpty {
            let resolver = try await runtime.makeResolver(accountID: accountID)
            let resolved = try await resolver.resolve(
                url: sourceURL,
                formatIDs: directSelections.map(\.formatID),
                reuseToken: reuseToken
            )
            guard resolved.videoID == expectedVideoID else {
                throw StreamResolutionError.invalidResponse
            }
            for stream in resolved.streams {
                guard directByFormatID[stream.formatID] == nil else {
                    throw StreamResolutionError.invalidResponse
                }
                directByFormatID[stream.formatID] = stream
                await diagnostics?.record(
                    .info,
                    subsystem: "transport",
                    event: "stream_resolved",
                    detail: StreamTransportDiagnosticFacts(
                        stream: stream
                    ).resolutionDetail
                )
            }
        }

        let hasDASH = selections.contains {
            $0.transport == .DASHFragments
        }
        let DASHResolver = hasDASH
            ? try await runtime.makeDASHFragmentResolver(accountID: accountID)
            : nil
        let hasHLS = selections.contains {
            $0.transport == .HLSResources
        }
        let HLSResolver = hasHLS
            ? try await runtime.makeHLSPlaylistResolver(accountID: accountID)
            : nil
        var result: [ProductionSourceResolution] = []
        result.reserveCapacity(selections.count)
        for selection in selections {
            switch selection.transport {
            case .directHTTP:
                guard
                    let stream = directByFormatID[selection.formatID],
                    selection.matches(stream)
                else {
                    throw StreamResolutionError.invalidResponse
                }
                result.append(.direct(selection, stream))
            case .DASHFragments:
                guard let DASHResolver else {
                    throw DASHFragmentResolutionError.bridgeUnavailable
                }
                let plan = try await DASHResolver.resolveDASHFragments(
                    url: sourceURL,
                    formatID: selection.formatID
                )
                guard
                    plan.videoID == expectedVideoID,
                    selection.matches(plan)
                else {
                    throw DASHFragmentResolutionError.invalidResponse
                }
                await diagnostics?.record(
                    .info,
                    subsystem: "transport",
                    event: "dash_stream_resolved",
                    detail: DASHTransportDiagnosticFacts(
                        plan: plan
                    ).resolutionDetail
                )
                result.append(.DASH(selection, plan))
            case .HLSResources:
                guard let HLSResolver else {
                    throw HLSPlaylistResolutionError.bridgeUnavailable
                }
                let resolved = try await HLSResolver.resolveHLSPlaylist(
                    ExactHLSPlaylistRequest(
                        sourceURL: sourceURL,
                        formatID: selection.formatID
                    )
                )
                guard
                    resolved.videoID == expectedVideoID,
                    selection.matches(resolved)
                else {
                    throw HLSPlaylistResolutionError.identityMismatch
                }
                await diagnostics?.record(
                    .info,
                    subsystem: "transport",
                    event: "hls_stream_resolved",
                    detail: HLSTransportDiagnosticFacts(
                        selection: resolved
                    ).resolutionDetail
                )
                result.append(.HLS(selection, resolved))
            }
        }
        guard result.count == selections.count else {
            throw StreamResolutionError.invalidResponse
        }
        return result
    }

    func acquireDASHSource(
        _ plan: ResolvedDASHFragmentPlan,
        selectedSource: SelectedSourceFact,
        sourceURL: URL,
        jobID: UUID,
        temporaryRoot: URL,
        baseBytes: Int64,
        combinedExpectedBytes: Int64?,
        context: DownloadPipelineContext
    ) async throws -> DASHProductionAcquisition {
        try await FragmentURLRecovery.run(initial: plan, refresh: {
            guard let currentJob = await context.currentJob(jobID) else { throw CancellationError() }
            let refreshed = try await self.resolveSources([selectedSource], sourceURL: sourceURL,
                                                          expectedVideoID: plan.videoID, accountID: currentJob.configuration.accountID)
            guard case let .DASH(_, exactPlan) = refreshed.first else {
                throw DASHFragmentResolutionError.invalidResponse
            }
            return exactPlan
        }, beforeRefresh: {
            try await self.consumeFragmentRefreshBudget(jobID: jobID, formatID: selectedSource.formatID, context: context)
        }, acquire: { current in
            try await self.acquireDASHSourceAttempt(current, jobID: jobID,
                temporaryRoot: temporaryRoot, baseBytes: baseBytes,
                combinedExpectedBytes: combinedExpectedBytes, context: context)
        })
    }

    func acquireHLSSource(
        _ selection: ResolvedHLSPlaylistSelection,
        selectedSource: SelectedSourceFact,
        sourceURL: URL,
        jobID: UUID,
        temporaryRoot: URL,
        destinationURL: URL,
        baseBytes: Int64,
        combinedExpectedBytes: Int64?,
        context: DownloadPipelineContext
    ) async throws -> HLSProductionAcquisition {
        try await FragmentURLRecovery.run(initial: selection, refresh: {
            guard let currentJob = await context.currentJob(jobID) else { throw CancellationError() }
            let refreshed = try await self.resolveSources([selectedSource], sourceURL: sourceURL,
                                                          expectedVideoID: selection.videoID, accountID: currentJob.configuration.accountID)
            guard case let .HLS(_, exactSelection) = refreshed.first else {
                throw HLSPlaylistResolutionError.identityMismatch
            }
            return exactSelection
        }, beforeRefresh: {
            try await self.consumeFragmentRefreshBudget(jobID: jobID, formatID: selectedSource.formatID, context: context)
        }, acquire: { current in
            try await self.acquireHLSSourceAttempt(current, jobID: jobID,
                temporaryRoot: temporaryRoot, destinationURL: destinationURL,
                baseBytes: baseBytes, combinedExpectedBytes: combinedExpectedBytes, context: context)
        })
    }

    private func consumeFragmentRefreshBudget(
        jobID: UUID, formatID: String, context: DownloadPipelineContext
    ) async throws {
        try Task.checkCancellation()
        guard var current = await context.currentJob(jobID) else { throw CancellationError() }
        var checkpoint = current.pipelineCheckpoint ?? DownloadPipelineCheckpoint(phase: .transferring)
        var counts = checkpoint.fragmentURLRefreshCounts ?? [:]
        let used = counts[formatID] ?? 0
        guard used >= 0 && used < 2 else { throw FragmentRecoveryError.expiryRefreshExhausted }
        counts[formatID] = used + 1
        checkpoint.fragmentURLRefreshCounts = counts
        checkpoint.updatedAt = .now
        current.pipelineCheckpoint = checkpoint
        await context.persistJob(current)
        await diagnostics?.record(.info, subsystem: "transport", event: "fragment_url_refresh",
                                  detail: "job=\(jobID.uuidString), attempt=\(used + 1)")
    }

    private func acquireDASHSourceAttempt(
        _ plan: ResolvedDASHFragmentPlan,
        jobID: UUID,
        temporaryRoot: URL,
        baseBytes: Int64,
        combinedExpectedBytes: Int64?,
        context: DownloadPipelineContext
    ) async throws -> DASHProductionAcquisition {
        guard let DASHDownloader, let DASHAssembler else {
            throw DASHFragmentResolutionError.bridgeUnavailable
        }
        let safeFormatID = FilenameSystem.sanitizeComponent(plan.formatID)
        guard !safeFormatID.isEmpty else {
            throw DASHFragmentDownloadError.invalidPlan
        }
        let stagingDirectoryURL = temporaryRoot.appending(
            path: ".dash-fragments-\(safeFormatID)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var assembledURL: URL?
        do {
            try fileManager.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true
            )
            let staging = try await DASHDownloader.downloadDASHFragments(
                plan,
                jobID: jobID,
                stagingDirectoryURL: stagingDirectoryURL
            ) { progress in
                let fragment = progress.fragmentProgress
                let total = progress.completedBytesBeforeFragment
                    .addingReportingOverflow(fragment.totalBytesWritten)
                guard !total.overflow else { return }
                let verified = progress.verifiedReusableBytesBeforeFragment
                    .addingReportingOverflow(fragment.verifiedReusableBytes)
                guard !verified.overflow else { return }
                let aggregate = StreamTransferProgress(
                    jobID: jobID,
                    streamID: plan.formatID,
                    bytesWritten: fragment.bytesWritten,
                    totalBytesWritten: total.partialValue,
                    totalBytesExpected: plan.expectedBytes,
                    instantaneousBytesPerSecond:
                        fragment.instantaneousBytesPerSecond,
                    verifiedReusableBytes: verified.partialValue,
                    networkBytesReceived: fragment.networkBytesReceived
                )
                Task {
                    await context.recordTransferProgress(
                        aggregate,
                        baseBytes,
                        combinedExpectedBytes
                    )
                }
            }
            try Task.checkCancellation()
            let transferStage = await context.currentJob(jobID)?.stage ?? .downloadingVideo
            try await context.acquireProcessingPermit(jobID)
            guard let beforeAssembly = await context.currentJob(jobID) else { throw CancellationError() }
            _ = try await context.update(beforeAssembly, state: .running, stage: .verifyingSources)
            let assembly = try await DASHAssembler.assemble(
                DASHLocalStreamAssemblyInput(
                    plan: plan,
                    stagingResult: staging,
                    destinationDirectoryURL: temporaryRoot,
                    verificationClass: .fastStructural
                )
            )
            assembledURL = assembly.fileURL
            await context.releaseProcessingPermit(jobID)
            guard let afterAssembly = await context.currentJob(jobID) else { throw CancellationError() }
            _ = try await context.update(afterAssembly, state: .running, stage: transferStage)
            try Task.checkCancellation()
            return DASHProductionAcquisition(
                fileURL: assembly.fileURL,
                stagingDirectoryURL: stagingDirectoryURL
            )
        } catch {
            await context.releaseProcessingPermit(jobID)
            try? fileManager.removeItem(at: stagingDirectoryURL)
            if let assembledURL {
                try? fileManager.removeItem(at: assembledURL)
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func acquireHLSSourceAttempt(
        _ selection: ResolvedHLSPlaylistSelection,
        jobID: UUID,
        temporaryRoot: URL,
        destinationURL: URL,
        baseBytes: Int64,
        combinedExpectedBytes: Int64?,
        context: DownloadPipelineContext
    ) async throws -> HLSProductionAcquisition {
        guard let HLSDownloader, let HLSAssembler else {
            throw HLSPlaylistResolutionError.bridgeUnavailable
        }
        let expectedResourceCount = selection.resourcePlan.events.count {
            $0.resource != nil
        }
        guard expectedResourceCount > 0 else {
            throw HLSResourceStagingError.invalidPlan
        }
        var stagingResult: HLSResourceStagingResult?
        var assembledURL: URL?
        do {
            let staging = try await HLSDownloader.downloadHLSResources(
                selection,
                jobID: jobID
            ) { progress in
                guard
                    progress.jobID == jobID,
                    progress.formatID == selection.formatID,
                    progress.resourcePosition >= 0,
                    progress.resourceCount == expectedResourceCount,
                    (1...expectedResourceCount).contains(
                        progress.completedResourceCount
                    ),
                    progress.completedBytes >= 0
                else {
                    return
                }
                let aggregate = StreamTransferProgress(
                    jobID: jobID,
                    streamID: selection.formatID,
                    bytesWritten: progress.completedBytes,
                    totalBytesWritten: progress.completedBytes,
                    totalBytesExpected: nil,
                    instantaneousBytesPerSecond: nil,
                    verifiedReusableBytes: progress.verifiedReusableBytes,
                    networkBytesReceived: 0
                )
                Task {
                    await context.recordTransferProgress(
                        aggregate,
                        baseBytes,
                        combinedExpectedBytes
                    )
                }
            }
            stagingResult = staging
            try Task.checkCancellation()
            let transferStage = await context.currentJob(jobID)?.stage ?? .downloadingVideo
            try await context.acquireProcessingPermit(jobID)
            guard let beforeAssembly = await context.currentJob(jobID) else { throw CancellationError() }
            _ = try await context.update(beforeAssembly, state: .running, stage: .verifyingSources)
            let assembly = try await HLSAssembler.assemble(
                HLSLocalStreamAssemblyInput(
                    selection: selection,
                    stagingResult: staging,
                    verificationClass: .fastStructural,
                    jobLocalDestinationURL: destinationURL,
                    jobTemporaryRootURL: temporaryRoot
                )
            )
            assembledURL = assembly.fileURL
            await context.releaseProcessingPermit(jobID)
            guard let afterAssembly = await context.currentJob(jobID) else { throw CancellationError() }
            _ = try await context.update(afterAssembly, state: .running, stage: transferStage)
            guard
                assembly.videoID == selection.videoID,
                assembly.formatID == selection.formatID,
                assembly.fileURL.standardizedFileURL
                    == destinationURL.standardizedFileURL,
                assembly.byteCount > 0,
                fileSize(assembly.fileURL) == assembly.byteCount,
                assembly.probe.fileURL.standardizedFileURL
                    == assembly.fileURL.standardizedFileURL,
                assembly.probe.fileSize == assembly.byteCount
            else {
                throw HLSLocalStreamAssemblyError.invalidInput
            }
            try Task.checkCancellation()
            try discardHLSStaging(staging)
            stagingResult = nil
            try Task.checkCancellation()
            return HLSProductionAcquisition(fileURL: assembly.fileURL)
        } catch {
            await context.releaseProcessingPermit(jobID)
            var cleanupFailed = false
            if let stagingResult {
                do {
                    try discardHLSStaging(stagingResult)
                } catch {
                    cleanupFailed = true
                }
            }
            if let assembledURL,
               fileManager.fileExists(atPath: assembledURL.path) {
                try? fileManager.removeItem(at: assembledURL)
                cleanupFailed = cleanupFailed
                    || fileManager.fileExists(atPath: assembledURL.path)
            }
            if cleanupFailed {
                throw HLSResourceStagingError.couldNotCleanStaging
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func discardHLSStaging(
        _ result: HLSResourceStagingResult
    ) throws {
        let roots = StreamTransferDestinationRoots.live(
            fileManager: fileManager
        )
        let identity = try roots.identity(for: result.stagingDirectoryURL)
        let canonical = try roots.URL(for: identity)
        guard
            identity.root == .applicationSupport,
            canonical.path
                == result.stagingDirectoryURL.resolvingSymlinksInPath()
                    .standardizedFileURL.path,
            isValidHLSStagingRelativePath(identity.relativePath)
        else {
            throw HLSResourceStagingError.invalidStagingDestination
        }
        if fileManager.fileExists(atPath: result.stagingDirectoryURL.path) {
            guard
                (try? fileManager.destinationOfSymbolicLink(
                    atPath: result.stagingDirectoryURL.path
                )) == nil,
                let values = try? result.stagingDirectoryURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw HLSResourceStagingError.invalidStagingDestination
            }
            try fileManager.removeItem(at: result.stagingDirectoryURL)
        }
        guard !fileManager.fileExists(atPath: result.stagingDirectoryURL.path)
        else {
            throw HLSResourceStagingError.couldNotCleanStaging
        }
    }

    private func isValidHLSStagingRelativePath(
        _ relativePath: String
    ) -> Bool {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            components.count == 2,
            components[0] == "HLS-Staging",
            components[1].hasPrefix("task-")
        else {
            return false
        }
        let UUIDs = components[1].dropFirst("task-".count)
        guard UUIDs.utf8.count == 73 else { return false }
        let separator = UUIDs.index(UUIDs.startIndex, offsetBy: 36)
        guard UUIDs[separator] == "-" else { return false }
        let first = UUIDs[..<separator]
        let second = UUIDs[UUIDs.index(after: separator)...]
        guard
            let firstUUID = UUID(uuidString: String(first)),
            let secondUUID = UUID(uuidString: String(second))
        else {
            return false
        }
        return firstUUID.uuidString.lowercased() == first
            && secondUUID.uuidString.lowercased() == second
    }

    func completionDiagnosticDetail(
        for source: ProductionSourceResolution,
        actualBytes: Int64,
        rollingBytesPerSecond: Double?,
        reusedSource: Bool,
        transferResult: StreamDownloadResult?
    ) -> String {
        switch source {
        case let .direct(_, stream):
            StreamTransportDiagnosticFacts(stream: stream)
                .completionDetail(
                    actualBytes: actualBytes,
                    rollingBytesPerSecond: rollingBytesPerSecond,
                    reusedSource: reusedSource,
                    transferStrategy: transferResult?.strategy,
                    plannedRangeCount:
                        transferResult?.plannedRangeCount ?? 0,
                    requestedRangeCount:
                        transferResult?.requestedRangeCount ?? 0,
                    verifiedReusableBytes: reusedSource
                        ? actualBytes
                        : transferResult?.verifiedReusableBytes ?? 0,
                    networkBytesReceived:
                        transferResult?.networkBytesReceived ?? 0
                )
        case let .DASH(_, plan):
            DASHTransportDiagnosticFacts(plan: plan).completionDetail(
                actualBytes: actualBytes,
                rollingBytesPerSecond: rollingBytesPerSecond,
                reusedSource: reusedSource
            )
        case let .HLS(_, selection):
            HLSTransportDiagnosticFacts(selection: selection).completionDetail(
                actualBytes: actualBytes,
                rollingBytesPerSecond: rollingBytesPerSecond,
                reusedSource: reusedSource
            )
        }
    }

    func exactSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
