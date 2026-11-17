import Foundation

enum Aria2TransferError: LocalizedError, Sendable {
    case unavailable, failed(Int32), invalidOutput
    var errorDescription: String? {
        switch self {
        case .unavailable: "aria2 could not start. Choose Native or retry."
        case .failed: "aria2 could not download this file. Retry or choose Native."
        case .invalidOutput: "aria2 returned an incomplete or invalid file."
        }
    }
}

/// Unsafe bridge calls and session ownership stay on one dedicated native worker.
struct NativeAria2Downloader: Aria2Downloading, Sendable {
    static let shared = Self()
    var certificateURL: URL? = nil
    func cancel(jobID: UUID) async { await Aria2Worker.shared.cancel(jobID: jobID) }

    func download(_ stream: ResolvedStream, jobID: UUID, destinationURL: URL,
                  expectedBytes: Int64?, speedLimit: Int64?,
                  progress: @escaping StreamTransferProgressHandler) async throws -> URL {
        let certificate = certificateURL ?? Bundle.main.url(forResource: "cacert", withExtension: "pem",
                                                           subdirectory: "PythonPackages/certifi")
        guard let certificate, FileManager.default.isReadableFile(atPath: certificate.path),
              Aria2TransferPolicy.permits(stream: stream, accountID: nil) else { throw Aria2TransferError.unavailable }
        let roots = StreamTransferDestinationRoots.live()
        let identity = try roots.identity(for: destinationURL)
        guard identity.root == .temporary,
              identity.relativePath.split(separator: "/").first == Substring("Illucet-" + jobID.uuidString) else {
            throw Aria2TransferError.invalidOutput
        }
        let cancelled = Aria2Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Aria2Worker.shared.start(stream: stream, jobID: jobID, destination: destinationURL,
                    expected: expectedBytes, limit: speedLimit, certificate: certificate, cancelled: cancelled,
                    progress: progress, continuation: continuation)
            }
        } onCancel: { cancelled.cancel() }
    }
}

private final class Aria2Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private final class Aria2Worker: @unchecked Sendable {
    static let shared = Aria2Worker()
    private let queue = DispatchQueue(label: "Illucet.aria2", qos: .utility)
    private var session: OpaquePointer?
    private var sessionCertificate: URL?
    private var active: [UInt64: Transfer] = [:]
    private var pumping = false
    private var cancellationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    private final class Transfer {
        let stream: ResolvedStream
        let jobID: UUID
        let destination: URL
        let staging: URL
        let expected: Int64?
        let destinationIdentity: StreamTransferDestinationIdentity
        let cancelled: Aria2Cancellation
        let progress: StreamTransferProgressHandler
        let continuation: CheckedContinuation<URL, any Error>
        var previousBytes: Int64 = 0
        var removalRequested = false
        init(stream: ResolvedStream, jobID: UUID, destination: URL, destinationIdentity: StreamTransferDestinationIdentity,
             staging: URL, expected: Int64?,
             cancelled: Aria2Cancellation, progress: @escaping StreamTransferProgressHandler,
             continuation: CheckedContinuation<URL, any Error>) {
            self.stream = stream; self.jobID = jobID; self.destination = destination; self.staging = staging
            self.expected = expected; self.cancelled = cancelled; self.progress = progress
            self.destinationIdentity = destinationIdentity
            self.continuation = continuation
        }
    }

    func start(stream: ResolvedStream, jobID: UUID, destination: URL, expected: Int64?, limit: Int64?,
               certificate: URL, cancelled: Aria2Cancellation, progress: @escaping StreamTransferProgressHandler,
               continuation: CheckedContinuation<URL, any Error>) {
        queue.async {
            let staging = destination.deletingLastPathComponent().appending(path: ".aria2-" + UUID().uuidString)
            do {
                if cancelled.isCancelled { throw CancellationError() }
                let identity = try StreamTransferDestinationRoots.live().identity(for: destination)
                guard identity.root == .temporary,
                      identity.relativePath.split(separator: "/").first == Substring("Illucet-" + jobID.uuidString) else {
                    throw Aria2TransferError.invalidOutput
                }
                // A previous process cannot own a live aria2 session. Remove only our orphaned, job-local stages.
                let retained = Set(self.active.values.map(\.staging))
                for orphan in try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(),
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    where orphan.lastPathComponent.hasPrefix(".aria2-") && !retained.contains(orphan)
                        && UUID(uuidString: String(orphan.lastPathComponent.dropFirst(7))) != nil {
                    let values = try orphan.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true { try FileManager.default.removeItem(at: orphan) }
                }
                if self.session == nil {
                    self.session = certificate.path.withCString { illucet_aria2_create($0) }
                    self.sessionCertificate = certificate
                }
                guard self.sessionCertificate == certificate else { throw Aria2TransferError.unavailable }
                guard let session = self.session else { throw Aria2TransferError.unavailable }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                       attributes: BackgroundFileProtection.attributes)
                let headers = stream.HTTPHeaders.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "\n")
                var identifier: UInt64 = 0
                let result = stream.URL.absoluteString.withCString { url in
                    staging.path.withCString { directory in
                        headers.withCString { header in
                            illucet_aria2_add(session, url, directory, header, limit ?? 0, &identifier)
                        }
                    }
                }
                guard result == 0, identifier != 0 else { throw Aria2TransferError.unavailable }
                self.active[identifier] = Transfer(stream: stream, jobID: jobID, destination: destination,
                    destinationIdentity: identity,
                    staging: staging, expected: expected, cancelled: cancelled, progress: progress, continuation: continuation)
                if !self.pumping { self.pumping = true; self.queue.async { self.pump() } }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                continuation.resume(throwing: error)
                self.closeIfIdle()
            }
        }
    }

    func cancel(jobID: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async {
                let matching = self.active.values.filter { $0.jobID == jobID }
                guard !matching.isEmpty else { continuation.resume(); return }
                for transfer in matching { transfer.cancelled.cancel() }
                self.cancellationWaiters[jobID, default: []].append(continuation)
            }
        }
    }

    private func pump() {
        guard let session else { pumping = false; return }
        for (identifier, transfer) in active where transfer.cancelled.isCancelled && !transfer.removalRequested {
            illucet_aria2_cancel(session, identifier)
            transfer.removalRequested = true
        }
        let result = illucet_aria2_poll(session)
        if result < 0 {
            illucet_aria2_close(session)
            self.session = nil
            for transfer in active.values { finish(transfer, snapshot: .init(state: 2, errorCode: -1, completedBytes: 0, totalBytes: 0)) }
            active.removeAll()
        } else {
            for (identifier, transfer) in Array(active) {
                let snapshot = illucet_aria2_snapshot(session, identifier)
                let bytes = max(0, snapshot.completedBytes)
                let total = transfer.expected ?? (snapshot.totalBytes > 0 ? snapshot.totalBytes : nil)
                if !transfer.cancelled.isCancelled && (bytes != transfer.previousBytes || snapshot.state == 1) {
                    transfer.progress(.init(jobID: transfer.jobID, streamID: transfer.stream.formatID,
                        bytesWritten: max(0, bytes - transfer.previousBytes), totalBytesWritten: bytes,
                        totalBytesExpected: total, instantaneousBytesPerSecond: nil))
                    transfer.previousBytes = bytes
                }
                if snapshot.state != 0 {
                    active.removeValue(forKey: identifier)
                    finish(transfer, snapshot: snapshot)
                }
            }
        }
        if active.isEmpty { pumping = false; closeIfIdle() }
        else { queue.asyncAfter(deadline: .now() + .milliseconds(50)) { self.pump() } }
        acknowledgeCancelledJobs()
    }

    private func finish(_ transfer: Transfer, snapshot: IllucetAria2Snapshot) {
        let result: Result<URL, any Error>
        do {
            if transfer.cancelled.isCancelled || snapshot.state == 3 { throw CancellationError() }
            guard snapshot.state == 1 else { throw Aria2TransferError.failed(snapshot.errorCode) }
            let payload = transfer.staging.appending(path: "payload")
            let directory = try transfer.staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let values = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard directory.isDirectory == true, directory.isSymbolicLink != true,
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0,
                  transfer.expected.map({ $0 == Int64(size) }) ?? true,
                  snapshot.totalBytes == 0 || snapshot.totalBytes == Int64(size),
                  payload.resolvingSymlinksInPath().deletingLastPathComponent() == transfer.staging.resolvingSymlinksInPath() else {
                throw Aria2TransferError.invalidOutput
            }
            // Recheck containment after transfer; publication to the user's destination is still owned by the pipeline.
            guard try StreamTransferDestinationRoots.live().identity(for: transfer.destination) == transfer.destinationIdentity else {
                throw Aria2TransferError.invalidOutput
            }
            if FileManager.default.fileExists(atPath: transfer.destination.path) {
                let old = try transfer.destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard old.isRegularFile == true, old.isSymbolicLink != true else { throw Aria2TransferError.invalidOutput }
                try FileManager.default.removeItem(at: transfer.destination)
            }
            try FileManager.default.moveItem(at: payload, to: transfer.destination)
            try BackgroundFileProtection.protect(transfer.destination,
                under: FileManager.default.temporaryDirectory.appending(path: "Illucet-" + transfer.jobID.uuidString))
            result = .success(transfer.destination)
        } catch {
            result = .failure(error is CancellationError || error is Aria2TransferError ? error : Aria2TransferError.invalidOutput)
        }
        // Completing the Swift request is the teardown acknowledgement, so cleanup must precede it.
        do {
            if FileManager.default.fileExists(atPath: transfer.staging.path) {
                let identity = try StreamTransferDestinationRoots.live().identity(for: transfer.staging)
                guard identity.root == .temporary,
                      identity.relativePath.split(separator: "/").first == Substring("Illucet-" + transfer.jobID.uuidString) else {
                    throw Aria2TransferError.invalidOutput
                }
                try FileManager.default.removeItem(at: transfer.staging)
            }
            transfer.continuation.resume(with: result)
        } catch { transfer.continuation.resume(throwing: Aria2TransferError.invalidOutput) }
    }

    private func acknowledgeCancelledJobs() {
        let activeIDs = Set(active.values.map(\.jobID))
        for id in Array(cancellationWaiters.keys) where !activeIDs.contains(id) {
            for waiter in cancellationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        }
    }

    private func closeIfIdle() {
        if active.isEmpty, let session { illucet_aria2_close(session); self.session = nil; sessionCertificate = nil }
    }
}
