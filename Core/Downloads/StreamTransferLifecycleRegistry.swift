import Foundation

struct StreamTransferKey: Hashable, Sendable {
    let jobID: UUID
    let streamID: String
    let destination: StreamTransferDestinationIdentity
    let mediaRole: StreamTransferMediaRole?
    let expectedTotalBytes: Int64?
    let byteRange: StreamByteRange?
    let rangeChunkBytes: Int64?
    let stagingDestination: StreamTransferDestinationIdentity?

    init(
        jobID: UUID,
        streamID: String,
        destination: StreamTransferDestinationIdentity,
        mediaRole: StreamTransferMediaRole?,
        expectedTotalBytes: Int64?,
        byteRange: StreamByteRange?,
        rangeChunkBytes: Int64?,
        stagingDestination: StreamTransferDestinationIdentity?
    ) {
        self.jobID = jobID
        self.streamID = streamID
        self.destination = destination
        self.byteRange = byteRange
        if byteRange == nil {
            // Preserve the schema-1 one-GET identity so an in-flight task can
            // still be reattached after an app update.
            self.mediaRole = nil
            self.expectedTotalBytes = nil
            self.rangeChunkBytes = nil
            self.stagingDestination = nil
        } else {
            self.mediaRole = mediaRole
            self.expectedTotalBytes = expectedTotalBytes
            self.rangeChunkBytes = rangeChunkBytes
            self.stagingDestination = stagingDestination
        }
    }

    init(_ descriptor: StreamTransferDescriptor) {
        jobID = descriptor.jobID
        streamID = descriptor.streamID
        destination = descriptor.destination
        byteRange = descriptor.byteRange
        if descriptor.byteRange == nil {
            mediaRole = nil
            expectedTotalBytes = nil
            rangeChunkBytes = nil
            stagingDestination = nil
        } else {
            mediaRole = descriptor.mediaRole
            expectedTotalBytes = descriptor.expectedTotalBytes
            rangeChunkBytes = descriptor.rangeChunkBytes
            stagingDestination = descriptor.stagingDestination
        }
    }
}

private struct StreamTransferWaiter {
    let id: UUID
    let progress: StreamTransferProgressHandler
    let continuation: CheckedContinuation<URL, Error>
}

private final class StreamTransferContext: @unchecked Sendable {
    let descriptor: StreamTransferDescriptor
    let finalURL: URL
    var waiters: [UUID: StreamTransferWaiter] = [:]
    var downloadedResult: Result<URL, StreamDownloadError>?
    var lastDate = Date.now
    var lastBytes: Int64 = 0
    var progressBaseBytes: Int64
    var verifiedBaseBytes: Int64
    var networkBaseBytes: Int64
    var logicalExpectedBytes: Int64?

    init(
        descriptor: StreamTransferDescriptor,
        finalURL: URL,
        progressBaseBytes: Int64 = 0,
        verifiedBaseBytes: Int64 = 0,
        networkBaseBytes: Int64 = 0,
        logicalExpectedBytes: Int64? = nil
    ) {
        self.descriptor = descriptor
        self.finalURL = finalURL
        self.progressBaseBytes = max(0, progressBaseBytes)
        self.verifiedBaseBytes = max(0, verifiedBaseBytes)
        self.networkBaseBytes = max(0, networkBaseBytes)
        self.logicalExpectedBytes = logicalExpectedBytes
    }
}

private struct StreamTransferTerminalTombstone {
    let taskIdentifier: Int
    let descriptor: StreamTransferDescriptor
    let result: Result<URL, StreamDownloadError>
    let completedAt: Date
}

struct StreamTransferCompletionDispatch {
    fileprivate let waiters: [StreamTransferWaiter]
    fileprivate let result: Result<URL, StreamDownloadError>
    fileprivate let terminalWaiters: [CheckedContinuation<Void, Never>]

    func resume() {
        for waiter in terminalWaiters {
            waiter.resume()
        }
        for waiter in waiters {
            switch result {
            case let .success(URL):
                waiter.continuation.resume(returning: URL)
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }
}

final class StreamTransferLifecycleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [Int: StreamTransferContext] = [:]
    private var tasksByKey: [
        StreamTransferKey: URLSessionDownloadTask
    ] = [:]
    private var taskKeysByIdentifier: [Int: StreamTransferKey] = [:]
    private var networkPolicies: [
        UUID: StreamTransferNetworkPolicy
    ] = [:]
    private var terminalResults: [
        StreamTransferKey: StreamTransferTerminalTombstone
    ] = [:]
    private var terminalTaskIdentifiers: [Int: Date] = [:]
    private var downloadedResultsByTaskIdentifier: [
        Int: Result<URL, StreamDownloadError>
    ] = [:]
    private var terminalControlWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var retainedResults: [Int: Set<UUID>] = [:]

    /// A prepared batch owns its results while persistence or another callback
    /// is being awaited. Cache age/size limits apply only after consumption.
    func retainResult(taskIdentifier: Int) -> UUID {
        lock.withLock {
            let token = UUID()
            retainedResults[taskIdentifier, default: []].insert(token)
            return token
        }
    }

    func releaseResult(taskIdentifier: Int, token: UUID) {
        lock.withLock {
            retainedResults[taskIdentifier]?.remove(token)
            if retainedResults[taskIdentifier]?.isEmpty == true { retainedResults[taskIdentifier] = nil }
            pruneTerminalStateLocked()
        }
    }

    func hasLiveTask(for key: StreamTransferKey) -> Bool {
        lock.withLock {
            guard let task = tasksByKey[key] else { return false }
            return task.state != .completed && task.state != .canceling
        }
    }

    func liveTask(
        for key: StreamTransferKey,
        descriptorForTask: (URLSessionDownloadTask) ->
            StreamTransferDescriptor?
    ) -> (
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    )? {
        lock.withLock {
            guard
                let task = tasksByKey[key],
                let descriptor = descriptorForTask(task),
                task.state != .completed,
                task.state != .canceling
            else {
                return nil
            }
            return (task, descriptor)
        }
    }

    func selectTask(
        createdTask: URLSessionDownloadTask,
        createdDescriptor: StreamTransferDescriptor,
        for key: StreamTransferKey,
        descriptorForTask: (URLSessionDownloadTask) ->
            StreamTransferDescriptor?
    ) -> (
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    ) {
        lock.withLock {
            if let existing = tasksByKey[key],
               let existingDescriptor = descriptorForTask(existing),
               existing.state != .completed,
               existing.state != .canceling {
                createdTask.cancel()
                return (existing, existingDescriptor)
            }
            // This is a genuinely new attempt. A terminal result from an
            // older attempt with the same durable identity must not be
            // mistaken for this task's result.
            terminalResults.removeValue(forKey: key)
            registerLocked(
                task: createdTask,
                descriptor: createdDescriptor
            )
            return (createdTask, createdDescriptor)
        }
    }

    func register(
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    ) {
        lock.withLock {
            registerLocked(task: task, descriptor: descriptor)
        }
    }

    func removeStaleTasks(
        discoveredIdentifiers: Set<Int>
    ) {
        lock.withLock {
            let stale = taskKeysByIdentifier.keys.filter {
                !discoveredIdentifiers.contains($0)
                    && contexts[$0] == nil
            }
            for taskIdentifier in stale {
                unregisterLocked(taskIdentifier: taskIdentifier)
            }
        }
    }

    func knownTasks(jobID: UUID) -> [URLSessionDownloadTask] {
        lock.withLock {
            tasksByKey.compactMap { key, task in
                key.jobID == jobID ? task : nil
            }
        }
    }

    func networkPolicy(jobID: UUID) -> StreamTransferNetworkPolicy {
        lock.withLock {
            networkPolicies[jobID] ?? .unrestricted
        }
    }

    func setNetworkPolicy(
        _ policy: StreamTransferNetworkPolicy,
        jobID: UUID
    ) {
        lock.withLock {
            networkPolicies[jobID] = policy
        }
    }

    func contextDescriptor(
        taskIdentifier: Int
    ) -> StreamTransferDescriptor? {
        lock.withLock {
            contexts[taskIdentifier]?.descriptor
        }
    }

    func registerWaiter(
        taskIdentifier: Int,
        descriptor: StreamTransferDescriptor,
        finalURL: URL,
        waiterID: UUID,
        progress: @escaping StreamTransferProgressHandler,
        continuation: CheckedContinuation<URL, Error>,
        progressBaseBytes: Int64,
        verifiedBaseBytes: Int64,
        networkBaseBytes: Int64,
        logicalExpectedBytes: Int64?
    ) -> Result<URL, StreamDownloadError>? {
        lock.withLock {
            pruneTerminalStateLocked()
            let key = StreamTransferKey(descriptor)
            if let terminal = terminalResults.removeValue(forKey: key) {
                return terminal.result
            }
            let context: StreamTransferContext
            if let existing = contexts[taskIdentifier] {
                context = existing
                context.progressBaseBytes = max(0, progressBaseBytes)
                context.verifiedBaseBytes = max(0, verifiedBaseBytes)
                context.networkBaseBytes = max(0, networkBaseBytes)
                context.logicalExpectedBytes = logicalExpectedBytes
            } else {
                context = StreamTransferContext(
                    descriptor: descriptor,
                    finalURL: finalURL,
                    progressBaseBytes: progressBaseBytes,
                    verifiedBaseBytes: verifiedBaseBytes,
                    networkBaseBytes: networkBaseBytes,
                    logicalExpectedBytes: logicalExpectedBytes
                )
                contexts[taskIdentifier] = context
            }
            context.waiters[waiterID] = StreamTransferWaiter(
                id: waiterID,
                progress: progress,
                continuation: continuation
            )
            return nil
        }
    }

    func cancelWaiter(
        taskIdentifier: Int,
        waiterID: UUID
    ) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            guard
                let context = contexts[taskIdentifier],
                let waiter = context.waiters.removeValue(forKey: waiterID)
            else {
                return nil
            }
            return waiter.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func reportProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let events: [
            (
                StreamTransferProgressHandler,
                StreamTransferProgress
            )
        ] = lock.withLock {
            guard let context = contexts[taskIdentifier] else {
                return []
            }
            let now = Date.now
            let elapsed = now.timeIntervalSince(context.lastDate)
            let byteDelta = totalBytesWritten - context.lastBytes
            let speed = elapsed > 0 && byteDelta >= 0
                ? Double(byteDelta) / elapsed
                : nil
            context.lastDate = now
            context.lastBytes = totalBytesWritten
            let expected = context.logicalExpectedBytes
                ?? (totalBytesExpectedToWrite > 0
                    ? totalBytesExpectedToWrite
                    : nil)
            let logicalBytes = context.progressBaseBytes
                + totalBytesWritten
            let boundedLogicalBytes = expected.map {
                min(max(0, logicalBytes), $0)
            } ?? max(0, logicalBytes)
            let progress = StreamTransferProgress(
                jobID: context.descriptor.jobID,
                streamID: context.descriptor.streamID,
                bytesWritten: bytesWritten,
                totalBytesWritten: boundedLogicalBytes,
                totalBytesExpected: expected,
                instantaneousBytesPerSecond: speed,
                verifiedReusableBytes: context.verifiedBaseBytes,
                networkBytesReceived:
                    context.networkBaseBytes + totalBytesWritten
            )
            return context.waiters.values.map {
                ($0.progress, progress)
            }
        }
        for event in events {
            event.0(event.1)
        }
    }

    func recordDownloadedResult(
        _ result: Result<URL, StreamDownloadError>,
        taskIdentifier: Int
    ) {
        lock.withLock {
            downloadedResultsByTaskIdentifier[taskIdentifier] = result
            if let context = contexts[taskIdentifier] {
                context.downloadedResult = result
            }
        }
    }

    func completeTask(
        taskIdentifier: Int,
        decodedDescriptor: StreamTransferDescriptor?,
        transportFailure: StreamDownloadError?,
        fallbackResult: (StreamTransferDescriptor?) ->
            Result<URL, StreamDownloadError>
    ) -> StreamTransferCompletionDispatch {
        lock.withLock {
            pruneTerminalStateLocked()
            let context = contexts.removeValue(forKey: taskIdentifier)
            let descriptor = decodedDescriptor ?? context?.descriptor
            let downloadedResult = downloadedResultsByTaskIdentifier
                .removeValue(forKey: taskIdentifier)
            unregisterLocked(taskIdentifier: taskIdentifier)
            let result: Result<URL, StreamDownloadError>
            if let transportFailure {
                result = .failure(transportFailure)
            } else if let downloadedResult =
                context?.downloadedResult ?? downloadedResult {
                result = downloadedResult
            } else {
                result = fallbackResult(descriptor)
            }
            if let descriptor {
                terminalResults[StreamTransferKey(descriptor)] =
                    StreamTransferTerminalTombstone(
                        taskIdentifier: taskIdentifier,
                        descriptor: descriptor,
                        result: result,
                        completedAt: .now
                    )
            }
            terminalTaskIdentifiers[taskIdentifier] = .now
            let terminalWaiters = terminalControlWaiters.removeValue(
                forKey: taskIdentifier
            ) ?? []
            return StreamTransferCompletionDispatch(
                waiters: context.map {
                    Array($0.waiters.values)
                } ?? [],
                result: result,
                terminalWaiters: terminalWaiters
            )
        }
    }

    func cancelAndAwaitTerminal(
        _ task: URLSessionTask,
        shouldIssueCancel: Bool
    ) async {
        await withCheckedContinuation { continuation in
            let isAlreadyTerminal = lock.withLock {
                pruneTerminalStateLocked()
                if task.state == .completed
                    || terminalTaskIdentifiers[task.taskIdentifier] != nil {
                    return true
                }
                terminalControlWaiters[
                    task.taskIdentifier,
                    default: []
                ].append(continuation)
                return false
            }
            if isAlreadyTerminal {
                continuation.resume()
            } else if shouldIssueCancel {
                task.cancel()
            }
        }
    }

    private func registerLocked(
        task: URLSessionDownloadTask,
        descriptor: StreamTransferDescriptor
    ) {
        let key = StreamTransferKey(descriptor)
        tasksByKey[key] = task
        taskKeysByIdentifier[task.taskIdentifier] = key
    }

    private func unregisterLocked(taskIdentifier: Int) {
        guard let key = taskKeysByIdentifier.removeValue(
            forKey: taskIdentifier
        ) else {
            return
        }
        if tasksByKey[key]?.taskIdentifier == taskIdentifier {
            tasksByKey[key] = nil
        }
    }

    private func pruneTerminalStateLocked() {
        let cutoff = Date.now.addingTimeInterval(-60)
        terminalResults = terminalResults.filter {
            retainedResults[$0.value.taskIdentifier] != nil || $0.value.completedAt >= cutoff
        }
        terminalTaskIdentifiers = terminalTaskIdentifiers.filter {
            retainedResults[$0.key] != nil || $0.value >= cutoff
        }
        if terminalResults.count > 128 {
            let retained = Set(terminalResults
                .filter { retainedResults[$0.value.taskIdentifier] == nil }
                .sorted { $0.value.completedAt > $1.value.completedAt }
                .prefix(128).map(\.key))
            terminalResults = terminalResults.filter {
                retainedResults[$0.value.taskIdentifier] != nil || retained.contains($0.key)
            }
        }
    }
}
