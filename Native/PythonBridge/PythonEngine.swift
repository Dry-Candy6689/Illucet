import Foundation

enum PythonBridgeError: LocalizedError, Equatable, Sendable {
    case creationFailed
    case startupFailed(String)
    case executionFailed(String)
    case cancelled(String)
    case notRunning(String)
    case shutdownFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            "Could not create the embedded Python engine."
        case let .startupFailed(message):
            "Python startup failed: \(message)"
        case let .executionFailed(message):
            "Python request failed: \(message)"
        case let .cancelled(message):
            "Python request cancelled: \(message)"
        case let .notRunning(message):
            "Python is not running: \(message)"
        case let .shutdownFailed(message):
            "Python shutdown failed: \(message)"
        }
    }
}

private func pythonEventCallback(
    context: UnsafeMutableRawPointer?,
    requestID: UInt64,
    utf8: UnsafePointer<CChar>?,
    length: Int
) {
    guard
        let context,
        let utf8,
        length >= 0
    else {
        return
    }

    let recorder = Unmanaged<PythonEventRecorder>
        .fromOpaque(context)
        .takeUnretainedValue()
    recorder.record(
        requestID: requestID,
        data: Data(bytes: utf8, count: length)
    )
}

final class PythonExecutionCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var finished = false

    @discardableResult
    func requestCancellation() -> Bool {
        lock.withLock {
            guard !cancellationRequested else {
                return false
            }
            cancellationRequested = true
            return true
        }
    }

    var shouldSkipEnqueue: Bool {
        lock.withLock { cancellationRequested }
    }

    var shouldKeepSignalling: Bool {
        lock.withLock { cancellationRequested && !finished }
    }

    func finish() {
        lock.withLock {
            finished = true
        }
    }
}

private final class PythonRequestIDState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 0x8000_0000_0000_0000

    func next() -> UInt64 {
        lock.withLock {
            precondition(
                nextValue != UInt64.max,
                "Illucet exhausted the native Python request-ID space."
            )
            defer { nextValue += 1 }
            return nextValue
        }
    }
}

enum PythonRequestIDAllocator {
    private static let state = PythonRequestIDState()

    static func next() -> UInt64 {
        state.next()
    }
}

final class PythonEngine: @unchecked Sendable {
    private let handle: OpaquePointer
    private let recorder: PythonEventRecorder
    private let stateLock = NSLock()
    private var didShutdown = false

    init(
        pythonHome: URL,
        bundledApp: URL,
        bundledPackages: URL,
        writablePackages: URL,
        recorder: PythonEventRecorder
    ) throws {
        self.recorder = recorder
        let context = Unmanaged.passUnretained(recorder).toOpaque()

        let created = pythonHome.path.withCString { pythonHomePath in
            bundledApp.path.withCString { bundledAppPath in
                bundledPackages.path.withCString { bundledPackagesPath in
                    writablePackages.path.withCString { writablePackagesPath in
                        illucet_python_engine_create(
                            pythonHomePath,
                            bundledAppPath,
                            bundledPackagesPath,
                            writablePackagesPath,
                            pythonEventCallback,
                            context
                        )
                    }
                }
            }
        }

        guard let created else {
            throw PythonBridgeError.creationFailed
        }
        handle = created
    }

    deinit {
        illucet_python_engine_destroy(handle)
    }

    func start() async throws {
        let result = await Task.detached(priority: .userInitiated) {
            self.startBlocking()
        }.value
        if result.code != Int32(ILLUCET_PYTHON_OK) {
            throw PythonBridgeError.startupFailed(
                result.message ?? "Unknown startup error"
            )
        }
    }

    func execute(
        requestID: UInt64,
        requestJSON: String
    ) async throws -> String {
        let cancellationState = PythonExecutionCancellationState()
        return try await withTaskCancellationHandler {
            defer { cancellationState.finish() }
            try Task.checkCancellation()

            let result = await Task.detached(priority: .userInitiated) {
                guard !cancellationState.shouldSkipEnqueue else {
                    return (
                        code: Int32(ILLUCET_PYTHON_CANCELLED),
                        response: Optional<String>.none,
                        message: Optional(
                            "Cancellation acknowledged before enqueue."
                        )
                    )
                }
                return self.executeBlocking(
                    requestID: requestID,
                    requestJSON: requestJSON
                )
            }.value

            try Task.checkCancellation()
            switch result.code {
            case Int32(ILLUCET_PYTHON_OK):
                guard let response = result.response else {
                    throw PythonBridgeError.executionFailed(
                        "The bridge returned no JSON response."
                    )
                }
                return response
            case Int32(ILLUCET_PYTHON_CANCELLED):
                throw PythonBridgeError.cancelled(
                    result.message ?? "Cancellation acknowledged"
                )
            case Int32(ILLUCET_PYTHON_NOT_RUNNING):
                throw PythonBridgeError.notRunning(
                    result.message ?? "The interpreter is unavailable."
                )
            default:
                throw PythonBridgeError.executionFailed(
                    result.message ?? "Unknown execution error"
                )
            }
        } onCancel: {
            guard cancellationState.requestCancellation() else {
                return
            }
            self.cancel(requestID: requestID)

            // Cancellation can arrive after Swift's preflight check but before
            // the blocking C call has enqueued its job. Keep signalling until
            // that call finishes so the first post-enqueue signal cannot be
            // lost in that narrow handoff window.
            Task.detached(priority: .userInitiated) {
                while cancellationState.shouldKeepSignalling {
                    self.cancel(requestID: requestID)
                    try? await Task<Never, Never>.sleep(
                        nanoseconds: 10_000_000
                    )
                }
            }
        }
    }

    func cancel(requestID: UInt64) {
        illucet_python_engine_cancel(handle, requestID)
    }

    func shutdown() async throws {
        let shouldShutdown = stateLock.withLock {
            if didShutdown {
                return false
            }
            didShutdown = true
            return true
        }
        guard shouldShutdown else {
            return
        }

        let result = await Task.detached(priority: .utility) {
            self.shutdownBlocking()
        }.value
        if result.code != Int32(ILLUCET_PYTHON_OK) {
            throw PythonBridgeError.shutdownFailed(
                result.message ?? "Unknown shutdown error"
            )
        }
    }

    private func startBlocking() -> (
        code: Int32,
        message: String?
    ) {
        var rawError: UnsafeMutablePointer<CChar>?
        let code = illucet_python_engine_start(handle, &rawError)
        defer { illucet_python_string_free(rawError) }
        return (code, rawError.map { String(cString: $0) })
    }

    private func executeBlocking(
        requestID: UInt64,
        requestJSON: String
    ) -> (
        code: Int32,
        response: String?,
        message: String?
    ) {
        var rawResponse: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        let code = requestJSON.withCString { request in
            illucet_python_engine_execute(
                handle,
                requestID,
                request,
                &rawResponse,
                &rawError
            )
        }
        defer {
            illucet_python_string_free(rawResponse)
            illucet_python_string_free(rawError)
        }
        return (
            code,
            rawResponse.map { String(cString: $0) },
            rawError.map { String(cString: $0) }
        )
    }

    private func shutdownBlocking() -> (
        code: Int32,
        message: String?
    ) {
        var rawError: UnsafeMutablePointer<CChar>?
        let code = illucet_python_engine_shutdown(handle, &rawError)
        defer { illucet_python_string_free(rawError) }
        return (code, rawError.map { String(cString: $0) })
    }
}
