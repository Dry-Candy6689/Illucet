import Foundation

final class StreamDownloadService:
    NSObject,
    StreamDownloading,
    DASHFragmentDownloading,
    HLSResourceDownloading,
    FragmentCheckpointManaging,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    let bandwidthLimiter = TransferBandwidthLimiter()
    let lifecycle = StreamTransferLifecycleRegistry()
    let hlsLifecycle = HLSResourceTransferLifecycleRegistry()
    let fragmentResponseValidators = FragmentResponseValidators()
    let fragmentValidatorNetworking: any HLSPlaylistNetworking
    let fragmentResumeEvent: FragmentResumeEventHandler
    private let orphanedHLSStaging: HLSOrphanCleanup
    var session: URLSession!
    let fileManager: FileManager
    let sessionIdentifier: String
    let destinationRoots: StreamTransferDestinationRoots
    let hlsAES128KeyLoader: any HLSAES128KeyLoading
    private let hooks: StreamDownloadServiceHooks
    let dashFragmentRetryPolicy: DASHFragmentRetryPolicy
    let dashFragmentRetrySleeper: DASHFragmentRetrySleeper
    private let executionGateLock = NSLock()
    private var executionGate: @Sendable (UUID) async throws -> Void = { _ in }
    private var nativeRequestGate: (@Sendable (UUID) async throws -> Void)?
    let transferAcknowledgements = NativeTransferAcknowledgements()
    private let receiptWriter = NativeReceiptWriter()
    private var taskPlanHandler: @Sendable (UUID, [StreamTransferDescriptor]) async throws -> Void = { _, _ in }
    private var jobAttempts: [UUID: UUID] = [:]
    private var taskAttempts: [Int: UUID] = [:]

    func bindAttempt(jobID: UUID, attempt: UUID) { executionGateLock.withLock { jobAttempts[jobID] = attempt } }
    func setAcknowledgementHandler(_ handler: @escaping @Sendable (UUID, UUID?, NativeFileReceipt) async throws -> Void) {
        receiptWriter.install(handler)
    }

    func setTaskPlanHandler(_ handler: @escaping @Sendable (UUID, [StreamTransferDescriptor]) async throws -> Void) {
        executionGateLock.withLock { taskPlanHandler = handler }
    }

    func rejectPendingReceipts() { receiptWriter.reject() }

    func persistTransferPlan(jobID: UUID, transfers: [PreparedStreamTransfer]) async throws {
        let handler = executionGateLock.withLock { taskPlanHandler }
        try await handler(jobID, transfers.map(\.descriptor))
    }

    func bindNativeTask(_ task: URLSessionTask, jobID: UUID) {
        executionGateLock.withLock { taskAttempts[task.taskIdentifier] = jobAttempts[jobID] }
    }

    private func acknowledgeStagedFile(_ file: URL, taskID: Int, jobID: UUID, formatID: String?) {
        guard let identity = try? destinationRoots.identity(for: file),
              let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            transferAcknowledgements.enqueue(taskID: taskID) {
                throw NativeTransferCheckpointError.persistenceUnavailable
            }
            return
        }
        let attempt = executionGateLock.withLock { taskAttempts[taskID] }
        let receipt = NativeFileReceipt(identity: identity, taskIdentifier: taskID, formatID: formatID,
            byteCount: size.int64Value, recordedAt: .now)
        transferAcknowledgements.enqueue(taskID: taskID) { [receiptWriter] in
            try await receiptWriter.write(jobID: jobID, attempt: attempt, receipt: receipt)
        }
    }

    func setExecutionGate(_ gate: @escaping @Sendable (UUID) async throws -> Void) {
        executionGateLock.withLock { executionGate = gate }
    }

    func setNativeRequestGate(_ gate: @escaping @Sendable (UUID) async throws -> Void) {
        executionGateLock.withLock { nativeRequestGate = gate }
    }

    func requireExecution(jobID: UUID) async throws {
        let gate = executionGateLock.withLock { executionGate }
        try await gate(jobID)
    }

    func setForegroundActive(_ active: Bool) async { bandwidthLimiter.setForegroundActive(active) }

    init(
        fileManager: FileManager = .default,
        sessionIdentifier: String = AppIdentity.backgroundSessionIdentifier,
        configuration: URLSessionConfiguration? = nil,
        destinationRoots: StreamTransferDestinationRoots? = nil,
        hlsAES128KeyLoader: any HLSAES128KeyLoading =
            URLSessionHLSAES128KeyLoader(),
        hooks: StreamDownloadServiceHooks = .none,
        fragmentValidatorNetworking: any HLSPlaylistNetworking = URLSessionHLSPlaylistHTTPClient(),
        fragmentResumeEvent: @escaping FragmentResumeEventHandler = { _, _, _ in },
        dashFragmentRetryPolicy: DASHFragmentRetryPolicy =
            DASHFragmentRetryPolicy(),
        dashFragmentRetrySleeper: @escaping DASHFragmentRetrySleeper = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.fileManager = fileManager
        self.sessionIdentifier = sessionIdentifier
        let resolvedRoots = destinationRoots ?? StreamTransferDestinationRoots.live(
            fileManager: fileManager
        )
        self.destinationRoots = resolvedRoots
        orphanedHLSStaging = HLSOrphanCleanup(
            roots: resolvedRoots,
            fileManager: fileManager
        )
        self.hlsAES128KeyLoader = hlsAES128KeyLoader
        self.hooks = hooks
        self.fragmentValidatorNetworking = fragmentValidatorNetworking
        self.fragmentResumeEvent = fragmentResumeEvent
        self.dashFragmentRetryPolicy = dashFragmentRetryPolicy
        self.dashFragmentRetrySleeper = dashFragmentRetrySleeper
        super.init()
        let activeConfiguration: URLSessionConfiguration
        if let configuration {
            activeConfiguration = configuration
        } else {
            let background = URLSessionConfiguration.background(
                withIdentifier: sessionIdentifier
            )
            background.waitsForConnectivity = true
            background.isDiscretionary = false
            background.sessionSendsLaunchEvents = true
            background.allowsExpensiveNetworkAccess = true
            background.allowsConstrainedNetworkAccess = true
            background.httpMaximumConnectionsPerHost = 3
            activeConfiguration = background
        }
        session = URLSession(
            configuration: activeConfiguration,
            delegate: self,
            delegateQueue: nil
        )
        // Explicit configurations are isolated transports used by fixtures.
        // The production background session always waits for its durable writer.
        if configuration != nil { receiptWriter.install { _, _, _ in } }
    }

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        try await download(
            stream,
            jobID: jobID,
            destinationURL: destinationURL,
            verifiedExpectedBytes: nil,
            progress: progress
        ).fileURL
    }

    func download(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationURL: URL,
        verifiedExpectedBytes: Int64?,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> StreamDownloadResult {
        try Task.checkCancellation()
        let destinationIdentity = try destinationRoots.identity(
            for: destinationURL
        )
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            if let verifiedExpectedBytes,
               isVerifiedFile(
                   destinationURL,
                   expectedLength: verifiedExpectedBytes
               ) {
                return StreamDownloadResult(
                    fileURL: destinationURL,
                    strategy: .oneGET,
                    plannedRangeCount: 0,
                    requestedRangeCount: 0,
                    verifiedReusableBytes: verifiedExpectedBytes,
                    networkBytesReceived: 0
                )
            }
            try fileManager.removeItem(at: destinationURL)
        }
        let rangePlan = StreamRangePlan(
            expectedTotalBytes: verifiedExpectedBytes,
            suggestedChunkBytes: bandwidthLimiter.suggestedChunkBytes(jobID: jobID) ?? stream.httpChunkSize
        )
        let hasRegisteredOneGET = hasRegisteredOneGETTask(
            jobID: jobID,
            streamID: stream.formatID,
            destination: destinationIdentity
        )
        if let plan = rangePlan,
           let role = StreamTransferMediaRole(stream: stream),
           !hasRegisteredOneGET {
            return try await downloadRanges(
                stream,
                jobID: jobID,
                destinationURL: destinationURL,
                destinationIdentity: destinationIdentity,
                role: role,
                plan: plan,
                progress: progress
            )
        }
        let URL = try await performTransferTask(
            stream,
            jobID: jobID,
            destinationIdentity: destinationIdentity,
            mediaRole: StreamTransferMediaRole(stream: stream),
            expectedTotalBytes: verifiedExpectedBytes,
            byteRange: nil,
            rangeChunkBytes: nil,
            stagingDestination: nil,
            progressBaseBytes: 0,
            verifiedBaseBytes: 0,
            networkBaseBytes: 0,
            logicalExpectedBytes: verifiedExpectedBytes,
            progress: progress
        )
        return StreamDownloadResult(
            fileURL: URL,
            strategy: .oneGET,
            plannedRangeCount: 0,
            requestedRangeCount: 0,
            verifiedReusableBytes: 0,
            networkBytesReceived: fileSize(URL)
        )
    }

    func performTransferTask(
        _ stream: ResolvedStream,
        jobID: UUID,
        destinationIdentity: StreamTransferDestinationIdentity,
        mediaRole: StreamTransferMediaRole?,
        expectedTotalBytes: Int64?,
        byteRange: StreamByteRange?,
        rangeChunkBytes: Int64?,
        stagingDestination: StreamTransferDestinationIdentity?,
        progressBaseBytes: Int64,
        verifiedBaseBytes: Int64,
        networkBaseBytes: Int64,
        logicalExpectedBytes: Int64?,
        progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        let transfer = try await prepareTransferTask(stream, jobID: jobID,
            destinationIdentity: destinationIdentity, mediaRole: mediaRole,
            expectedTotalBytes: expectedTotalBytes, byteRange: byteRange,
            rangeChunkBytes: rangeChunkBytes, stagingDestination: stagingDestination)
        do {
            try await persistTransferPlan(jobID: jobID, transfers: [transfer])
        } catch {
            await cancelPreparedTransfers([transfer])
            throw error
        }
        return try await awaitTransfer(transfer, progressBaseBytes: progressBaseBytes,
            verifiedBaseBytes: verifiedBaseBytes, networkBaseBytes: networkBaseBytes,
            logicalExpectedBytes: logicalExpectedBytes, progress: progress)
    }

    struct PreparedStreamTransfer: Sendable {
        let task: URLSessionDownloadTask
        let descriptor: StreamTransferDescriptor
        let retentionToken: UUID
    }

    func prepareTransferTask(
        _ stream: ResolvedStream, jobID: UUID,
        destinationIdentity: StreamTransferDestinationIdentity,
        mediaRole: StreamTransferMediaRole?, expectedTotalBytes: Int64?,
        byteRange: StreamByteRange?, rangeChunkBytes: Int64?,
        stagingDestination: StreamTransferDestinationIdentity?
    ) async throws -> PreparedStreamTransfer {
        try await bandwidthLimiter.waitForAdmission(jobID: jobID)
        try Task.checkCancellation()
        let requestedKey = StreamTransferKey(
            jobID: jobID,
            streamID: stream.formatID,
            destination: destinationIdentity,
            mediaRole: mediaRole,
            expectedTotalBytes: expectedTotalBytes,
            byteRange: byteRange,
            rangeChunkBytes: rangeChunkBytes,
            stagingDestination: stagingDestination
        )

        let task: URLSessionDownloadTask
        let descriptor: StreamTransferDescriptor
        if let known = lifecycle.liveTask(
            for: requestedKey,
            descriptorForTask: { self.decodedDescriptor(for: $0) }
        ) {
            task = known.task
            descriptor = known.descriptor
        } else if let restored = await matchingTask(for: requestedKey) {
            task = restored.task
            descriptor = restored.descriptor
        } else {
            let availableAt = try MediaAvailability.validated(stream.availableAt)
            if session.configuration.identifier == nil {
                try await MediaAvailability.waitUntilReady(availableAt)
            }
            let requestGate = executionGateLock.withLock { nativeRequestGate ?? executionGate }
            try await requestGate(jobID)
            var request = URLRequest(url: stream.URL)
            request.assumesHTTP3Capable = MediaTransportProtocolPolicy.assumesHTTP3Capable(stream.URL)
            request.timeoutInterval = 60
            let networkPolicy = lifecycle.networkPolicy(jobID: jobID)
            request.allowsExpensiveNetworkAccess =
                networkPolicy.allowsExpensiveAccess
            request.allowsConstrainedNetworkAccess =
                networkPolicy.allowsConstrainedAccess
            for (name, value) in stream.HTTPHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let byteRange {
                request.setValue(
                    byteRange.HTTPHeaderValue,
                    forHTTPHeaderField: "Range"
                )
                request.setValue(
                    "identity",
                    forHTTPHeaderField: "Accept-Encoding"
                )
            }
            let created = session.downloadTask(with: request)
            created.earliestBeginDate = availableAt
            let createdDescriptor = try StreamTransferDescriptor(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: created.taskIdentifier,
                jobID: jobID,
                streamID: stream.formatID,
                destination: destinationIdentity,
                mediaRole: mediaRole,
                expectedTotalBytes: expectedTotalBytes,
                byteRange: byteRange,
                rangeChunkBytes: rangeChunkBytes,
                stagingDestination: stagingDestination
            )
            created.taskDescription = try createdDescriptor
                .encodedTaskDescription()
            let selected = lifecycle.selectTask(
                createdTask: created,
                createdDescriptor: createdDescriptor,
                for: requestedKey,
                descriptorForTask: { self.decodedDescriptor(for: $0) }
            )
            task = selected.task
            descriptor = selected.descriptor
        }

        bindNativeTask(task, jobID: jobID)
        return PreparedStreamTransfer(task: task, descriptor: descriptor,
            retentionToken: lifecycle.retainResult(taskIdentifier: task.taskIdentifier))
    }

    func cancelPreparedTransfers(_ transfers: [PreparedStreamTransfer]) async {
        await withTaskGroup(of: Void.self) { group in
            for transfer in transfers {
                group.addTask {
                    await self.lifecycle.cancelAndAwaitTerminal(transfer.task,
                        shouldIssueCancel: transfer.task.state != .completed && transfer.task.state != .canceling)
                    self.lifecycle.releaseResult(taskIdentifier: transfer.task.taskIdentifier, token: transfer.retentionToken)
                }
            }
        }
    }

    func awaitTransfer(
        _ transfer: PreparedStreamTransfer, progressBaseBytes: Int64 = 0,
        verifiedBaseBytes: Int64 = 0, networkBaseBytes: Int64 = 0,
        logicalExpectedBytes: Int64?, progress: @escaping StreamTransferProgressHandler
    ) async throws -> URL {
        let task = transfer.task, descriptor = transfer.descriptor
        defer { lifecycle.releaseResult(taskIdentifier: task.taskIdentifier, token: transfer.retentionToken) }
        let finalURL = try descriptor.transferOutputURL(
            in: destinationRoots
        )
        hooks.beforeWaiterRegistration?(task, descriptor)
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let terminalResult: Result<
                    URL,
                    StreamDownloadError
                >? = lifecycle.registerWaiter(
                    taskIdentifier: task.taskIdentifier,
                    descriptor: descriptor,
                    finalURL: finalURL,
                    waiterID: waiterID,
                    progress: progress,
                    continuation: continuation,
                    progressBaseBytes: progressBaseBytes,
                    verifiedBaseBytes: verifiedBaseBytes,
                    networkBaseBytes: networkBaseBytes,
                    logicalExpectedBytes: logicalExpectedBytes
                )
                if let terminalResult {
                    switch terminalResult {
                    case let .success(URL):
                        continuation.resume(returning: URL)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                } else if Task.isCancelled {
                    lifecycle.cancelWaiter(
                        taskIdentifier: task.taskIdentifier,
                        waiterID: waiterID
                    )
                } else if task.state == .suspended {
                    _ = bandwidthLimiter.resume(task, jobID: descriptor.jobID)
                }
            }
        } onCancel: {
            self.lifecycle.cancelWaiter(
                taskIdentifier: task.taskIdentifier,
                waiterID: waiterID
            )
        }
        try await transferAcknowledgements.wait(taskID: task.taskIdentifier)
        try Task.checkCancellation()
        return result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        hooks.didFinishCollecting?(metrics)
    }

    func reconcileBackgroundTasks() async -> [
        StreamTransferRegistration
    ] {
        let tasks = await session.allTasks
        return await reconcileBackgroundTasks(tasks)
    }

    /// Observation must not await orphan cancellation; that cleanup can itself
    /// be the operation whose missing acknowledgement is being investigated.
    func nativeTaskSnapshot() async -> [StreamTransferRegistration] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard let download = task as? URLSessionDownloadTask,
                  let descriptor = decodedDescriptor(for: task) else { return nil }
            return registration(task: download, descriptor: descriptor)
        }
    }

    func reconcileBackgroundTasks(
        _ tasks: [URLSessionTask]
    ) async -> [StreamTransferRegistration] {
        var registrations: [StreamTransferRegistration] = []
        var discoveredIdentifiers: Set<Int> = []
        var lostHLSResources: [
            (URLSessionDownloadTask, HLSResourceTransferDescriptor)
        ] = []
        for task in tasks {
            guard let downloadTask = task as? URLSessionDownloadTask else {
                continue
            }
            switch backgroundTransferIdentity(for: downloadTask) {
            case let .stream(descriptor):
                if !lifecycle.hasLiveTask(for: StreamTransferKey(descriptor)),
                   descriptor.destination.relativePath.split(separator: "/").contains(where: {
                    $0.hasPrefix(".dash-fragments-")
                }) {
                    lifecycle.register(task: downloadTask, descriptor: descriptor)
                    await lifecycle.cancelAndAwaitTerminal(downloadTask,
                        shouldIssueCancel: downloadTask.state != .completed && downloadTask.state != .canceling)
                    if let partial = try? descriptor.destinationURL(in: destinationRoots) {
                        try? fileManager.removeItem(at: partial)
                    }
                    continue
                }
                discoveredIdentifiers.insert(downloadTask.taskIdentifier)
                lifecycle.register(
                    task: downloadTask,
                    descriptor: descriptor
                )
                registrations.append(
                    registration(
                        task: downloadTask,
                        descriptor: descriptor
                    )
                )
            case let .hlsResource(descriptor):
                guard !hlsLifecycle.isLiveOperation(
                    taskIdentifier: downloadTask.taskIdentifier
                ) else {
                    continue
                }
                hlsLifecycle.registerRestored(
                    task: downloadTask,
                    descriptor: descriptor
                )
                lostHLSResources.append((downloadTask, descriptor))
            case .invalidHLSResource:
                downloadTask.cancel()
            case nil:
                continue
            }
        }
        lifecycle.removeStaleTasks(
            discoveredIdentifiers: discoveredIdentifiers
        )
        for (task, descriptor) in lostHLSResources {
            let shouldCancel = task.state != .completed
                && task.state != .canceling
            await hlsLifecycle.cancelAndAwaitTerminal(
                task,
                shouldIssueCancel: shouldCancel
            )
            _ = cleanupLostHLSOperation(descriptor)
            hlsLifecycle.forgetRestoredTask(
                taskIdentifier: task.taskIdentifier
            )
        }
        // Restored resource tasks have reached terminal state. Only directories
        // captured before this service started can be abandoned operations;
        // staging created by current downloads or handed to assembly is retained.
        orphanedHLSStaging.removeCapturedDirectories()
        return registrations.sorted {
            if $0.descriptor.jobID != $1.descriptor.jobID {
                return $0.descriptor.jobID.uuidString
                    < $1.descriptor.jobID.uuidString
            }
            return $0.descriptor.streamID < $1.descriptor.streamID
        }
    }

    func setNetworkPolicy(
        _ policy: StreamTransferNetworkPolicy,
        jobID: UUID
    ) async {
        lifecycle.setNetworkPolicy(policy, jobID: jobID)
    }

    func cancel(jobID: UUID) async -> StreamTaskControlResult {
        let tasks = await matchingTasks(jobID: jobID)
        var affected = 0
        var acknowledged = 0
        await withTaskGroup(of: Bool.self) { group in
            for task in tasks {
                let shouldCancel = task.state != .completed
                    && task.state != .canceling
                if shouldCancel {
                    affected += 1
                }
                if let descriptor = hlsLifecycle.descriptor(
                    taskIdentifier: task.taskIdentifier
                ), descriptor.jobID == jobID {
                    group.addTask { [weak self] in
                        guard let self else { return false }
                        await self.hlsLifecycle.cancelAndAwaitTerminal(
                            task,
                            shouldIssueCancel: shouldCancel
                        )
                        let cleaned = self.cleanupLostHLSOperation(
                            descriptor
                        )
                        self.hlsLifecycle.forgetRestoredTask(
                            taskIdentifier: task.taskIdentifier
                        )
                        return cleaned
                    }
                    continue
                }
                group.addTask { [weak self] in
                    guard let self else { return false }
                    await self.lifecycle.cancelAndAwaitTerminal(
                        task,
                        shouldIssueCancel: shouldCancel
                    )
                    return true
                }
            }
            for await didAcknowledge in group where didAcknowledge {
                acknowledged += 1
            }
        }
        return StreamTaskControlResult(
            action: .cancel,
            matchedTaskCount: tasks.count,
            affectedTaskCount: affected,
            acknowledgedTaskCount: acknowledged
        )
    }

    func setAdmissionPaused(_ paused: Bool, jobID: UUID) async {
        if paused { _ = bandwidthLimiter.pauseAdmission(jobID: jobID) }
        else { _ = bandwidthLimiter.resumeAdmission(jobID: jobID) }
    }

    func pause(jobID: UUID) async -> StreamTaskControlResult {
        let tasks = await matchingTasks(jobID: jobID)
        let admission = bandwidthLimiter.pauseAdmission(jobID: jobID)
        var affected = 0
        for task in tasks {
            if bandwidthLimiter.pause(task) { affected += 1 }
        }
        let acknowledged = tasks.count {
            $0.state == .suspended
                || $0.state == .completed
                || $0.state == .canceling
        }
        return StreamTaskControlResult(
            action: .pause,
            matchedTaskCount: tasks.count + admission,
            affectedTaskCount: affected + admission,
            acknowledgedTaskCount: acknowledged + admission
        )
    }

    func resume(jobID: UUID) async -> StreamTaskControlResult {
        let admission = bandwidthLimiter.resumeAdmission(jobID: jobID)
        let tasks = await matchingTasks(jobID: jobID)
        var affected = 0
        for task in tasks {
            if bandwidthLimiter.resume(task, jobID: jobID) { affected += 1 }
        }
        let acknowledged = tasks.count {
            $0.state == .running
                || bandwidthLimiter.isThrottled($0)
                || $0.state == .completed
                || $0.state == .canceling
        }
        return StreamTaskControlResult(
            action: .resume,
            matchedTaskCount: tasks.count + admission,
            affectedTaskCount: affected + admission,
            acknowledgedTaskCount: acknowledged + admission
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let jobID = decodedDescriptor(for: downloadTask)?.jobID
            ?? (try? HLSResourceTransferDescriptor.decodeTaskDescription(downloadTask.taskDescription,
                expectedSessionIdentifier: sessionIdentifier, expectedTaskIdentifier: downloadTask.taskIdentifier))?.jobID {
            bandwidthLimiter.throttle(downloadTask, bytes: bytesWritten, jobID: jobID, totalBytes: totalBytesWritten)
        }
        lifecycle.reportProgress(
            taskIdentifier: downloadTask.taskIdentifier,
            bytesWritten: bytesWritten,
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if hlsLifecycle.isLiveOperation(
            taskIdentifier: downloadTask.taskIdentifier
        ) {
            guard
                let resourceDescriptor = hlsLifecycle.descriptor(taskIdentifier: downloadTask.taskIdentifier),
                let inFlightIdentity = hlsLifecycle
                    .acceptableInFlightIdentity(
                        taskIdentifier: downloadTask.taskIdentifier
                    ),
                let HTTPResponse = downloadTask.response as? HTTPURLResponse,
                let finalURL = HTTPResponse.url,
                HLSPlaylistSecurity.isAllowedPlaylistURL(finalURL),
                let inFlightURL = try? destinationRoots.URL(
                    for: inFlightIdentity
                ),
                let redirectCount = hlsLifecycle.redirectCount(
                    taskIdentifier: downloadTask.taskIdentifier
                )
            else {
                try? fileManager.removeItem(at: location)
                hlsLifecycle.record(
                    .failure(HLSResourceStagingError.invalidHTTPResponse),
                    taskIdentifier: downloadTask.taskIdentifier
                )
                return
            }
            do {
                if fileManager.fileExists(atPath: inFlightURL.path) {
                    try fileManager.removeItem(at: inFlightURL)
                }
                try fileManager.moveItem(at: location, to: inFlightURL)
                try BackgroundFileProtection.protect(inFlightURL, under: destinationRoots.applicationSupportDirectory, fileManager: fileManager)
                acknowledgeStagedFile(inFlightURL, taskID: downloadTask.taskIdentifier, jobID: resourceDescriptor.jobID, formatID: nil)
                let headers = HTTPResponse.allHeaderFields.reduce(
                    into: [String: String]()
                ) { result, entry in
                    guard let key = entry.key as? String else { return }
                    result[key] = String(describing: entry.value)
                }
                hlsLifecycle.record(
                    .success(
                        HLSResourceHTTPResponse(
                            statusCode: HTTPResponse.statusCode,
                            headers: headers,
                            finalURL: finalURL,
                            fileURL: inFlightURL,
                            redirectCount: redirectCount
                        )
                    ),
                    taskIdentifier: downloadTask.taskIdentifier
                )
            } catch {
                try? fileManager.removeItem(at: location)
                try? fileManager.removeItem(at: inFlightURL)
                hlsLifecycle.record(
                    .failure(HLSResourceStagingError.couldNotStageResource),
                    taskIdentifier: downloadTask.taskIdentifier
                )
            }
            return
        }
        switch backgroundTransferIdentity(for: downloadTask) {
        case let .hlsResource(descriptor):
            hlsLifecycle.registerRestored(
                task: downloadTask,
                descriptor: descriptor
            )
            try? fileManager.removeItem(at: location)
            _ = cleanupLostHLSOperation(descriptor)
            return
        case .invalidHLSResource:
            try? fileManager.removeItem(at: location)
            downloadTask.cancel()
            return
        case .stream, nil:
            break
        }
        let descriptor = decodedDescriptor(for: downloadTask) ??
            lifecycle.contextDescriptor(
                taskIdentifier: downloadTask.taskIdentifier
            )
        guard let descriptor else { return }
        let HTTPResponse = downloadTask.response as? HTTPURLResponse
        let result = commitDownloadedFile(
            descriptor: descriptor,
            HTTPStatusCode: HTTPResponse?.statusCode,
            HTTPContentRange: HTTPResponse?.value(
                forHTTPHeaderField: "Content-Range"
            ),
            location: location
        )
        if case let .success(destination) = result {
            acknowledgeStagedFile(destination, taskID: downloadTask.taskIdentifier, jobID: descriptor.jobID, formatID: descriptor.streamID)
            fragmentResponseValidators.record(destination, response:
                HTTPResponse?.url == downloadTask.originalRequest?.url ? HTTPResponse : nil)
        }
        lifecycle.recordDownloadedResult(
            result,
            taskIdentifier: downloadTask.taskIdentifier
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        defer { executionGateLock.withLock { taskAttempts[task.taskIdentifier] = nil } }
        bandwidthLimiter.complete(task)
        let wasLiveHLSOperation = hlsLifecycle.isLiveOperation(
            taskIdentifier: task.taskIdentifier
        )
        let HLSDescriptor = hlsLifecycle.descriptor(
            taskIdentifier: task.taskIdentifier
        ) ?? decodedHLSDescriptor(for: task)
        if
            !wasLiveHLSOperation,
            let HLSDescriptor,
            let downloadTask = task as? URLSessionDownloadTask
        {
            hlsLifecycle.registerRestored(
                task: downloadTask,
                descriptor: HLSDescriptor
            )
            _ = cleanupLostHLSOperation(HLSDescriptor)
        }
        if let completion = hlsLifecycle.complete(
            taskIdentifier: task.taskIdentifier,
            transportError: error
        ) {
            completion.resume()
            return
        }
        if HLSResourceTransferDescriptor.hasTypeMarker(
            task.taskDescription
        ) {
            return
        }
        let decoded = decodedDescriptor(for: task)
        let transportFailure: StreamDownloadError? = error.map {
            ($0 as NSError).code == NSURLErrorCancelled
                ? .cancelled
                : .networkFailure
        }
        let dispatch = lifecycle.completeTask(
            taskIdentifier: task.taskIdentifier,
            decodedDescriptor: decoded,
            transportFailure: transportFailure
        ) { descriptor in
            if let descriptor,
               let finalURL = try? descriptor.destinationURL(
                   in: self.destinationRoots
               ),
               self.fileManager.fileExists(atPath: finalURL.path) {
                return .success(finalURL)
            }
            return .failure(.couldNotCommitFile)
        }
        dispatch.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard hlsLifecycle.isLiveOperation(
            taskIdentifier: task.taskIdentifier
        ) else {
            switch backgroundTransferIdentity(for: task) {
            case let .hlsResource(descriptor):
                if let downloadTask = task as? URLSessionDownloadTask {
                    hlsLifecycle.registerRestored(
                        task: downloadTask,
                        descriptor: descriptor
                    )
                }
                completionHandler(nil)
                task.cancel()
            case .invalidHLSResource:
                completionHandler(nil)
                task.cancel()
            case .stream, nil:
                var redirected = request
                redirected.assumesHTTP3Capable = MediaTransportProtocolPolicy.assumesHTTP3Capable(request.url)
                completionHandler(redirected)
            }
            return
        }
        guard let destinationURL = request.url else {
            completionHandler(nil)
            return
        }
        completionHandler(
            hlsLifecycle.redirectedRequest(
                taskIdentifier: task.taskIdentifier,
                destinationURL: destinationURL
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        switch backgroundTransferIdentity(for: task) {
        case .hlsResource, .invalidHLSResource:
            if challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust
            {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case .stream, nil:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @discardableResult
    func commitDownloadedFile(
        taskDescription: String?,
        taskIdentifier: Int,
        HTTPStatusCode: Int?,
        HTTPContentRange: String? = nil,
        location: URL
    ) -> Result<URL, StreamDownloadError> {
        guard let descriptor = decodedStreamDescription(
            taskDescription,
            taskIdentifier: taskIdentifier
        ) else {
            try? fileManager.removeItem(at: location)
            return .failure(.couldNotCommitFile)
        }
        return commitDownloadedFile(
            descriptor: descriptor,
            HTTPStatusCode: HTTPStatusCode,
            HTTPContentRange: HTTPContentRange,
            location: location
        )
    }

    @discardableResult
    func commitDownloadedFile(
        descriptor: StreamTransferDescriptor,
        HTTPStatusCode: Int?,
        HTTPContentRange: String? = nil,
        location: URL
    ) -> Result<URL, StreamDownloadError> {
        guard let HTTPStatusCode else {
            try? fileManager.removeItem(at: location)
            return .failure(.permanentHTTPFailure(statusCode: 0))
        }
        guard (200 ..< 300).contains(HTTPStatusCode) else {
            let failure = StreamDownloadError.HTTPFailure(statusCode: HTTPStatusCode)
            try? fileManager.removeItem(at: location)
            return .failure(failure)
        }
        if let requestedRange = descriptor.byteRange {
            guard let expectedTotalBytes = descriptor.expectedTotalBytes else {
                try? fileManager.removeItem(at: location)
                return .failure(.invalidPartialContent)
            }
            switch HTTPStatusCode {
            case 200:
                guard isVerifiedFile(
                    location,
                    expectedLength: expectedTotalBytes
                ) else {
                    try? fileManager.removeItem(at: location)
                    return .failure(.invalidPartialContent)
                }
                return publishDownloadedFile(
                    descriptor: descriptor,
                    useStagingDestination: false,
                    location: location
                )
            case 206:
                guard
                    let contentRange = try? StreamContentRange.parse(
                        HTTPContentRange
                    ),
                    contentRange.range == requestedRange,
                    contentRange.totalBytes == expectedTotalBytes,
                    isVerifiedFile(
                        location,
                        expectedLength: requestedRange.length
                    )
                else {
                    try? fileManager.removeItem(at: location)
                    return .failure(.invalidPartialContent)
                }
                return publishDownloadedFile(
                    descriptor: descriptor,
                    useStagingDestination: true,
                    location: location
                )
            default:
                try? fileManager.removeItem(at: location)
                return .failure(.invalidPartialContent)
            }
        }
        return publishDownloadedFile(
            descriptor: descriptor,
            useStagingDestination: false,
            location: location
        )
    }

    private func publishDownloadedFile(
        descriptor: StreamTransferDescriptor,
        useStagingDestination: Bool,
        location: URL
    ) -> Result<URL, StreamDownloadError> {
        do {
            let destination = useStagingDestination
                ? try descriptor.transferOutputURL(in: destinationRoots)
                : try descriptor.destinationURL(in: destinationRoots)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(
                at: location,
                to: destination
            )
            let root = descriptor.destination.root == .temporary
                ? destinationRoots.temporaryDirectory : destinationRoots.applicationSupportDirectory
            try BackgroundFileProtection.protect(destination, under: root, fileManager: fileManager)
            return .success(destination)
        } catch {
            try? fileManager.removeItem(at: location)
            return .failure(.couldNotCommitFile)
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        guard sessionIdentifier == AppIdentity.backgroundSessionIdentifier
        else {
            return
        }
        let acknowledged = transferAcknowledgements.captureDeliveryBarrier()
        Task { @MainActor in
            await acknowledged()
            BackgroundSessionEventBroker.shared.finishEvents(
                sessionIdentifier: sessionIdentifier
            )
        }
    }

    private func matchingTask(
        for requestedKey: StreamTransferKey
    ) async -> (
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    )? {
        let tasks = await session.allTasks
        for task in tasks {
            guard
                let downloadTask = task as? URLSessionDownloadTask,
                downloadTask.state != .completed,
                downloadTask.state != .canceling,
                let descriptor = decodedDescriptor(for: downloadTask),
                StreamTransferKey(descriptor) == requestedKey
            else {
                continue
            }
            lifecycle.register(
                task: downloadTask,
                descriptor: descriptor
            )
            return (downloadTask, descriptor)
        }
        return nil
    }

    func backgroundTransferIdentity(
        for task: URLSessionTask
    ) -> BackgroundTransferTaskIdentity? {
        let streamDescriptor = try? StreamTransferDescriptor
            .decodeTaskDescription(
                task.taskDescription,
                expectedSessionIdentifier: sessionIdentifier,
                expectedTaskIdentifier: task.taskIdentifier
            )
        let hasHLSMarker = HLSResourceTransferDescriptor.hasTypeMarker(
            task.taskDescription
        )
        let HLSDescriptor: HLSResourceTransferDescriptor? = if hasHLSMarker {
            try? HLSResourceTransferDescriptor.decodeTaskDescription(
                task.taskDescription,
                expectedSessionIdentifier: sessionIdentifier,
                expectedTaskIdentifier: task.taskIdentifier
            )
        } else {
            nil
        }

        switch (streamDescriptor, HLSDescriptor, hasHLSMarker) {
        case let (descriptor?, nil, false):
            return .stream(descriptor)
        case let (nil, descriptor?, true):
            return .hlsResource(descriptor)
        case (_, _, true):
            return .invalidHLSResource
        default:
            return nil
        }
    }

    private func decodedDescriptor(
        for task: URLSessionTask
    ) -> StreamTransferDescriptor? {
        guard case let .stream(descriptor) = backgroundTransferIdentity(
            for: task
        ) else {
            return nil
        }
        return descriptor
    }

    private func decodedHLSDescriptor(
        for task: URLSessionTask
    ) -> HLSResourceTransferDescriptor? {
        guard case let .hlsResource(descriptor) =
            backgroundTransferIdentity(for: task)
        else {
            return nil
        }
        return descriptor
    }

    private func decodedStreamDescription(
        _ taskDescription: String?,
        taskIdentifier: Int
    ) -> StreamTransferDescriptor? {
        let streamDescriptor = try? StreamTransferDescriptor
            .decodeTaskDescription(
                taskDescription,
                expectedSessionIdentifier: sessionIdentifier,
                expectedTaskIdentifier: taskIdentifier
            )
        guard
            !HLSResourceTransferDescriptor.hasTypeMarker(taskDescription)
        else {
            return nil
        }
        return streamDescriptor
    }

    private func registration(
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    ) -> StreamTransferRegistration {
        let networkBytes = max(0, task.countOfBytesReceived)
        let verifiedBytes = verifiedStagedBytes(for: descriptor)
        let currentChunkCommitted: Bool = {
            guard
                let range = descriptor.byteRange,
                let URL = try? descriptor.transferOutputURL(
                    in: destinationRoots
                )
            else {
                return false
            }
            return isVerifiedChunk(URL, range: range)
        }()
        let usefulBytes = verifiedBytes
            + (currentChunkCommitted ? 0 : networkBytes)
        let expected = descriptor.expectedTotalBytes
            ?? (task.countOfBytesExpectedToReceive > 0
                ? task.countOfBytesExpectedToReceive
                : nil)
        return StreamTransferRegistration(
            descriptor: descriptor,
            state: StreamTransferTaskState(task.state),
            bytesReceived: expected.map { min(usefulBytes, $0) }
                ?? usefulBytes,
            totalBytesExpected: expected,
            verifiedReusableBytes: verifiedBytes,
            networkBytesReceived: networkBytes,
            earliestBeginDate: task.earliestBeginDate
        )
    }

    private func matchingTasks(
        jobID: UUID
    ) async -> [URLSessionTask] {
        var tasks = await session.allTasks
        let known = lifecycle.knownTasks(jobID: jobID)
        let knownIdentifiers = Set(tasks.map(\.taskIdentifier))
        tasks.append(contentsOf: known.filter {
            !knownIdentifiers.contains($0.taskIdentifier)
        })
        let hlsTasks = hlsLifecycle.tasks(jobID: jobID)
        let discoveredIdentifiers = Set(tasks.map(\.taskIdentifier))
        tasks.append(contentsOf: hlsTasks.filter {
            !discoveredIdentifiers.contains($0.taskIdentifier)
        })
        return tasks.filter {
            if hlsLifecycle.owns($0, jobID: jobID) {
                return true
            }
            if
                let downloadTask = $0 as? URLSessionDownloadTask,
                let descriptor = decodedHLSDescriptor(for: downloadTask),
                descriptor.jobID == jobID
            {
                hlsLifecycle.registerRestored(
                    task: downloadTask,
                    descriptor: descriptor
                )
                return true
            }
            guard
                let descriptor = decodedDescriptor(for: $0)
            else {
                return false
            }
            return descriptor.jobID == jobID
        }
    }

    private func verifiedStagedBytes(
        for descriptor: StreamTransferDescriptor
    ) -> Int64 {
        guard
            let expectedTotalBytes = descriptor.expectedTotalBytes,
            descriptor.byteRange != nil,
            let role = descriptor.mediaRole,
            let rangeChunkBytes = descriptor.rangeChunkBytes,
            let plan = StreamRangePlan(
                expectedTotalBytes: expectedTotalBytes,
                suggestedChunkBytes: rangeChunkBytes
            ),
            plan.chunkBytes == rangeChunkBytes,
            let destinationURL = try? descriptor.destinationURL(
                in: destinationRoots
            )
        else {
            return 0
        }
        let directory = StreamRangeStaging.directory(
            for: destinationURL,
            role: role,
            totalBytes: expectedTotalBytes
        )
        var total: Int64 = 0
        for range in plan.ranges {
            let URL = StreamRangeStaging.chunkURL(
                in: directory,
                range: range
            )
            guard
                validatedStagingIdentity(
                    for: URL,
                    destination: descriptor.destination,
                    role: role,
                    totalBytes: expectedTotalBytes,
                    range: range
                ) != nil
            else {
                return 0
            }
            if isVerifiedChunk(URL, range: range) {
                total += range.length
            }
        }
        return total
    }

    func validatedStagingIdentity(
        for URL: URL,
        destination: StreamTransferDestinationIdentity,
        role: StreamTransferMediaRole,
        totalBytes: Int64,
        range: StreamByteRange
    ) -> StreamTransferDestinationIdentity? {
        guard
            let actual = try? destinationRoots.identity(for: URL),
            let expected = try? StreamTransferDescriptor
                .expectedStagingDestination(
                    destination: destination,
                    mediaRole: role,
                    expectedTotalBytes: totalBytes,
                    byteRange: range
                ),
            actual == expected
        else {
            return nil
        }
        return actual
    }

    func isVerifiedChunk(
        _ URL: URL,
        range: StreamByteRange
    ) -> Bool {
        isVerifiedFile(URL, expectedLength: range.length)
    }

    func isVerifiedFile(
        _ URL: URL,
        expectedLength: Int64
    ) -> Bool {
        guard
            fileManager.fileExists(atPath: URL.path),
            (try? fileManager.destinationOfSymbolicLink(atPath: URL.path))
                == nil,
            let values = try? URL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            values.fileSize.map(Int64.init) == expectedLength
        else {
            return false
        }
        return true
    }

    private func fileSize(_ URL: URL) -> Int64 {
        (
            try? URL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        ).map(Int64.init) ?? 0
    }
}
