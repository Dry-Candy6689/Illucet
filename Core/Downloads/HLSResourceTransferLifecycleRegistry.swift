import Foundation

struct HLSResourceDestination {
    let finalURL: URL
    let inFlightURL: URL
    let plaintextInFlightURL: URL
    let plaintextInFlightIdentity: StreamTransferDestinationIdentity
    let stagingDirectoryIdentity: StreamTransferDestinationIdentity
    let inFlightIdentity: StreamTransferDestinationIdentity
}

struct HLSAES128DecryptionMaterial {
    let key: Data
    let initializationVector: Data
}

struct HLSResourceHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let finalURL: URL
    let fileURL: URL
    let redirectCount: Int
}

struct HLSResourceTransferCompletion {
    let continuation: CheckedContinuation<HLSResourceHTTPResponse, Error>?
    let result: Result<HLSResourceHTTPResponse, Error>?
    let terminalWaiters: [CheckedContinuation<Void, Never>]

    func resume() {
        for waiter in terminalWaiters {
            waiter.resume()
        }
        if let continuation, let result {
            continuation.resume(with: result)
        }
    }
}

final class HLSResourceTransferLifecycleRegistry:
    @unchecked Sendable
{
    private struct Context {
        let task: URLSessionDownloadTask
        let descriptor: HLSResourceTransferDescriptor
        let HTTPHeaders: [String: String]
        let byteRange: HLSMediaByteRange?
        let inFlightIdentity: StreamTransferDestinationIdentity
        let maximumRedirects: Int
        let timeoutInterval: TimeInterval
        let allowsExpensiveAccess: Bool
        let allowsConstrainedAccess: Bool
        let continuation: CheckedContinuation<
            HLSResourceHTTPResponse,
            Error
        >
        var visitedURLs: Set<String>
        var redirectCount = 0
        var result: Result<HLSResourceHTTPResponse, Error>?
        var redirectFailure: HLSResourceStagingError?
    }

    private struct RestoredContext {
        let task: URLSessionDownloadTask
        let descriptor: HLSResourceTransferDescriptor
    }

    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private var restoredContexts: [Int: RestoredContext] = [:]
    private var terminalControlWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var terminalTaskIdentifiers: [Int: Date] = [:]

    func register(
        task: URLSessionDownloadTask,
        descriptor: HLSResourceTransferDescriptor,
        HTTPHeaders: [String: String],
        byteRange: HLSMediaByteRange?,
        inFlightIdentity: StreamTransferDestinationIdentity,
        maximumRedirects: Int,
        initialURL: URL?,
        continuation: CheckedContinuation<HLSResourceHTTPResponse, Error>
    ) {
        lock.withLock {
            let visited = initialURL.map { [$0.absoluteString] } ?? []
            restoredContexts.removeValue(forKey: task.taskIdentifier)
            contexts[task.taskIdentifier] = Context(
                task: task,
                descriptor: descriptor,
                HTTPHeaders: HTTPHeaders,
                byteRange: byteRange,
                inFlightIdentity: inFlightIdentity,
                maximumRedirects: maximumRedirects,
                timeoutInterval: task.originalRequest?.timeoutInterval ?? 60,
                allowsExpensiveAccess:
                    task.originalRequest?.allowsExpensiveNetworkAccess ?? true,
                allowsConstrainedAccess:
                    task.originalRequest?.allowsConstrainedNetworkAccess ?? true,
                continuation: continuation,
                visitedURLs: Set(visited)
            )
        }
    }

    func registerRestored(
        task: URLSessionDownloadTask,
        descriptor: HLSResourceTransferDescriptor
    ) {
        lock.withLock {
            guard contexts[task.taskIdentifier] == nil else { return }
            restoredContexts[task.taskIdentifier] = RestoredContext(
                task: task,
                descriptor: descriptor
            )
        }
    }

    func isRegistered(taskIdentifier: Int) -> Bool {
        lock.withLock {
            contexts[taskIdentifier] != nil
                || restoredContexts[taskIdentifier] != nil
        }
    }

    func isLiveOperation(taskIdentifier: Int) -> Bool {
        lock.withLock { contexts[taskIdentifier] != nil }
    }

    func descriptor(
        taskIdentifier: Int
    ) -> HLSResourceTransferDescriptor? {
        lock.withLock {
            contexts[taskIdentifier]?.descriptor
                ?? restoredContexts[taskIdentifier]?.descriptor
        }
    }

    func acceptableInFlightIdentity(
        taskIdentifier: Int
    ) -> StreamTransferDestinationIdentity? {
        lock.withLock {
            guard
                let context = contexts[taskIdentifier],
                context.redirectFailure == nil
            else {
                return nil
            }
            return context.inFlightIdentity
        }
    }

    func redirectedRequest(
        taskIdentifier: Int,
        destinationURL: URL
    ) -> URLRequest? {
        lock.withLock {
            guard var context = contexts[taskIdentifier] else {
                return nil
            }
            guard context.redirectFailure == nil else { return nil }
            do {
                let request = try HLSResourceRedirectValidation
                    .redirectedRequest(
                        destinationURL: destinationURL,
                        HTTPHeaders: context.HTTPHeaders,
                        byteRange: context.byteRange,
                        timeoutInterval: context.timeoutInterval,
                        allowsExpensiveAccess: context.allowsExpensiveAccess,
                        allowsConstrainedAccess:
                            context.allowsConstrainedAccess,
                        visitedURLs: &context.visitedURLs,
                        redirectCount: &context.redirectCount,
                        maximumRedirects: context.maximumRedirects
                    )
                contexts[taskIdentifier] = context
                return request
            } catch let error as HLSResourceStagingError {
                context.redirectFailure = error
                contexts[taskIdentifier] = context
                return nil
            } catch {
                context.redirectFailure = .unsafeRedirect
                contexts[taskIdentifier] = context
                return nil
            }
        }
    }

    func redirectCount(taskIdentifier: Int) -> Int? {
        lock.withLock { contexts[taskIdentifier]?.redirectCount }
    }

    func record(
        _ result: Result<HLSResourceHTTPResponse, Error>,
        taskIdentifier: Int
    ) {
        lock.withLock {
            guard var context = contexts[taskIdentifier] else { return }
            context.result = result
            contexts[taskIdentifier] = context
        }
    }

    func complete(
        taskIdentifier: Int,
        transportError: (any Error)?
    ) -> HLSResourceTransferCompletion? {
        lock.withLock {
            let context = contexts.removeValue(forKey: taskIdentifier)
            let restored = restoredContexts.removeValue(
                forKey: taskIdentifier
            )
            guard context != nil || restored != nil else {
                return nil
            }
            let result: Result<HLSResourceHTTPResponse, Error>? = context.map {
                if let redirectFailure = $0.redirectFailure {
                    return .failure(redirectFailure)
                } else if let transportError {
                    if let URLFailure = transportError as? URLError {
                        return .failure(
                            URLFailure.code == .cancelled
                                ? CancellationError()
                                : URLError(URLFailure.code)
                        )
                    }
                    return .failure(HLSResourceStagingError.networkFailure)
                } else if let recorded = $0.result {
                    return recorded
                } else {
                    return .failure(
                        HLSResourceStagingError.invalidHTTPResponse
                    )
                }
            }
            terminalTaskIdentifiers[taskIdentifier] = .now
            let terminalWaiters = terminalControlWaiters.removeValue(
                forKey: taskIdentifier
            ) ?? []
            return HLSResourceTransferCompletion(
                continuation: context?.continuation,
                result: result,
                terminalWaiters: terminalWaiters
            )
        }
    }

    func tasks(jobID: UUID) -> [URLSessionDownloadTask] {
        lock.withLock {
            let live = contexts.values.compactMap {
                $0.descriptor.jobID == jobID ? $0.task : nil
            }
            let liveIdentifiers = Set(live.map(\.taskIdentifier))
            return live + restoredContexts.values.compactMap {
                $0.descriptor.jobID == jobID
                    && !liveIdentifiers.contains($0.task.taskIdentifier)
                    ? $0.task
                    : nil
            }
        }
    }

    func owns(_ task: URLSessionTask, jobID: UUID) -> Bool {
        lock.withLock {
            contexts[task.taskIdentifier]?.descriptor.jobID == jobID
                || restoredContexts[task.taskIdentifier]?.descriptor.jobID
                    == jobID
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

    func forgetRestoredTask(taskIdentifier: Int) {
        _ = lock.withLock {
            restoredContexts.removeValue(forKey: taskIdentifier)
        }
    }

    private func pruneTerminalStateLocked() {
        let cutoff = Date.now.addingTimeInterval(-60)
        terminalTaskIdentifiers = terminalTaskIdentifiers.filter {
            $0.value >= cutoff
        }
        if terminalTaskIdentifiers.count > 128 {
            let retained = terminalTaskIdentifiers
                .sorted { $0.value > $1.value }
                .prefix(128)
            terminalTaskIdentifiers = Dictionary(
                uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
            )
        }
    }
}


/// Captures abandoned operation roots before the service can start new work.
/// Cleanup runs once, after restored URLSession tasks have been reconciled.
final class HLSOrphanCleanup: @unchecked Sendable {
    private struct Candidate {
        let URL: URL
        let identity: StreamTransferDestinationIdentity
        let inode: UInt64
    }

    private let lock = NSLock()
    private let roots: StreamTransferDestinationRoots
    private let fileManager: FileManager
    private var candidates: [Candidate]

    init(roots: StreamTransferDestinationRoots, fileManager: FileManager) {
        self.roots = roots
        self.fileManager = fileManager
        let directories: [(URL, StreamTransferDestinationRoot, String)] = [
            (roots.applicationSupportDirectory.appending(path: "HLS-Staging"), .applicationSupport, "HLS-Staging"),
            (roots.temporaryDirectory.appending(path: "HLS-Assembly"), .temporary, "HLS-Assembly"),
        ]
        candidates = directories.flatMap { directory, root, relativeDirectory in
            guard Self.isRegularDirectory(directory, fileManager: fileManager) else {
                return [Candidate]()
            }
            let children = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )) ?? []
            return children.compactMap { URL in
                let name = URL.lastPathComponent
                guard Self.isOwnedName(name, root: root),
                      let identity = try? roots.identity(for: URL),
                      identity == StreamTransferDestinationIdentity(
                        root: root, relativePath: "\(relativeDirectory)/\(name)"
                      ),
                      Self.isRegularDirectory(URL, fileManager: fileManager),
                      let inode = Self.inode(URL, fileManager: fileManager)
                else { return nil }
                return Candidate(URL: URL, identity: identity, inode: inode)
            }
        }
    }

    private static func isOwnedName(_ name: String, root: StreamTransferDestinationRoot) -> Bool {
        switch root {
        case .applicationSupport:
            guard name.count == 78, name.hasPrefix("task-"),
                  let jobID = UUID(uuidString: String(name.dropFirst(5).prefix(36))),
                  let operationID = UUID(uuidString: String(name.suffix(36)))
            else { return false }
            return name == "task-\(jobID.uuidString.lowercased())-\(operationID.uuidString.lowercased())"
        case .temporary:
            guard name.count == 45, name.hasPrefix("assembly-"),
                  let operationID = UUID(uuidString: String(name.dropFirst(9)))
            else { return false }
            return name == "assembly-\(operationID.uuidString.lowercased())"
        }
    }

    func removeCapturedDirectories() {
        // Holding the lock through deletion prevents overlapping reconciliation
        // calls from deleting the same captured root concurrently.
        lock.withLock {
            for candidate in candidates {
                guard (try? roots.identity(for: candidate.URL)) == candidate.identity,
                      Self.isRegularDirectory(candidate.URL.deletingLastPathComponent(), fileManager: fileManager),
                      Self.isRegularDirectory(candidate.URL, fileManager: fileManager),
                      Self.inode(candidate.URL, fileManager: fileManager) == candidate.inode
                else { continue }
                try? fileManager.removeItem(at: candidate.URL)
            }
            candidates.removeAll()
        }
    }

    private static func isRegularDirectory(_ URL: URL, fileManager: FileManager) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: URL.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: URL.path)
        else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private static func inode(_ URL: URL, fileManager: FileManager) -> UInt64? {
        let attributes = try? fileManager.attributesOfItem(atPath: URL.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
