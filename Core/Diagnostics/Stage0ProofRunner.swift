import Foundation

enum Stage0ProofRunner {
    static func run() async -> Stage0ProofReport {
        let recorder = PythonEventRecorder()
        var checks: [Stage0Check] = []

        guard let resources = Bundle.main.resourceURL else {
            checks.append(
                failure(
                    id: "bundle-resources",
                    name: "Locate application resources",
                    evidence: "Bundle.main.resourceURL was nil."
                )
            )
            checks.append(contentsOf: await FFmpegStage0ProofRunner.run())
            return finalizedReport(checks: checks, recorder: recorder)
        }

        let writableRoot: URL
        do {
            writableRoot = try prepareWritablePackage()
            checks.append(
                success(
                    id: "writable-package-created",
                    name: "Prepare versioned writable Python package",
                    evidence: writableRoot.path
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "writable-package-created",
                    name: "Prepare versioned writable Python package",
                    evidence: error.localizedDescription
                )
            )
            checks.append(contentsOf: await FFmpegStage0ProofRunner.run())
            return finalizedReport(checks: checks, recorder: recorder)
        }

        let engine: PythonEngine
        do {
            engine = try PythonEngine(
                pythonHome: resources.appending(path: "python"),
                bundledApp: resources.appending(path: "PythonApp"),
                bundledPackages: resources.appending(path: "PythonPackages"),
                writablePackages: writableRoot,
                recorder: recorder
            )
            try await engine.start()
            checks.append(
                success(
                    id: "python-initialize",
                    name: "Initialize CPython",
                    evidence: "Py_InitializeFromConfig completed on the worker pthread."
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "python-initialize",
                    name: "Initialize CPython",
                    evidence: error.localizedDescription
                )
            )
            checks.append(contentsOf: await FFmpegStage0ProofRunner.run())
            return finalizedReport(checks: checks, recorder: recorder)
        }

        do {
            let json = try await engine.execute(
                requestID: 1,
                requestJSON: #"{"action":"basic"}"#
            )
            let envelope = try JSONDecoder().decode(
                BridgeEnvelope<BasicPythonProof>.self,
                from: Data(json.utf8)
            )
            let basic = envelope.data

            checks.append(
                check(
                    basic.addition == 5,
                    id: "swift-python-call",
                    name: "Swift calls a Python function",
                    evidence: "Python returned 2 + 3 = \(basic.addition)."
                )
            )
            checks.append(
                check(
                    basic.bundleOrigin == "bundled-read-only-package",
                    id: "bundled-import",
                    name: "Import from bundled read-only package",
                    evidence: basic.bundleOrigin
                )
            )
            checks.append(
                check(
                    basic.writableOrigin == "writable-version-1",
                    id: "writable-import",
                    name: "Import from writable versioned package",
                    evidence: basic.writableOrigin
                )
            )
            checks.append(
                check(
                    !basic.isMainThread,
                    id: "off-main-thread",
                    name: "Interpreter never runs on main thread",
                    evidence: "Native pthread reported is_main_thread=\(basic.isMainThread)."
                )
            )
            checks.append(
                check(
                    basic.pythonVersion == "3.14.6",
                    id: "python-version",
                    name: "Pinned CPython runtime",
                    evidence: "\(basic.pythonVersion), \(basic.platformDetail)"
                )
            )
            checks.append(
                check(
                    basic.ytDLPVersion == DependencyVersions.ytDLP &&
                        basic.ejsVersion == "0.8.0",
                    id: "python-package-imports",
                    name: "Import pinned yt-dlp and EJS packages",
                    evidence: "yt-dlp \(basic.ytDLPVersion); EJS \(basic.ejsVersion); certifi \(basic.certifiVersion)"
                )
            )
            checks.append(
                check(
                    !basic.sslVersion.isEmpty,
                    id: "native-extension-import",
                    name: "Import native ssl extension",
                    evidence: basic.sslVersion
                )
            )

            let basicEvents = recorder.events(for: 1)
            checks.append(
                check(
                    basicEvents.contains { $0.kind == "log" } &&
                        basicEvents.contains { $0.kind == "progress" },
                    id: "native-callback",
                    name: "Python calls native event bridge",
                    evidence: "Captured \(basicEvents.count) typed JSON events."
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "basic-python-proof",
                    name: "Basic Python bridge proof",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            let json = try await engine.execute(
                requestID: 6,
                requestJSON: #"{"action":"quickjs"}"#
            )
            let envelope = try JSONDecoder().decode(
                BridgeEnvelope<QuickJSProof>.self,
                from: Data(json.utf8)
            )
            let proof = envelope.data

            checks.append(
                check(
                    proof.quickjsVersion == "0.15.0",
                    id: "quickjs-version",
                    name: "Pinned in-process QuickJS-ng",
                    evidence: "QuickJS-ng \(proof.quickjsVersion); no executable was bundled."
                )
            )
            checks.append(
                check(
                    proof.answer == 42 &&
                        proof.unicode == "Illucet 🔐" &&
                        proof.thrownTextRedacted,
                    id: "quickjs-evaluation",
                    name: "Evaluate JavaScript through native C APIs",
                    evidence: "answer=\(proof.answer), unicode=\(proof.unicode), thrownTextRedacted=\(proof.thrownTextRedacted), elapsed=\(proof.elapsed)s"
                )
            )
            checks.append(
                check(
                    proof.providerAvailable &&
                        proof.emptyResultType == "result" &&
                        proof.emptyResponseCount == 0 &&
                        proof.coreSHA256 == "18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00" &&
                        proof.libSHA256 == "c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577",
                    id: "ejs-load",
                    name: "Load and execute pinned yt-dlp EJS assets",
                    evidence: "EJS \(proof.ejsVersion); initialized provider available; solver=\(proof.emptyResultType) with \(proof.emptyResponseCount) responses; core \(proof.coreSHA256); lib \(proof.libSHA256)"
                )
            )
            checks.append(
                check(
                    proof.providerRegistered &&
                        proof.providerKey == "IllucetQuickJS" &&
                        proof.ytdlpVersion == DependencyVersions.ytDLP &&
                        proof.ejsVersion == "0.8.0",
                    id: "ejs-provider-contract",
                    name: "Register pinned in-process yt-dlp provider",
                    evidence: "\(proof.providerKey), yt-dlp \(proof.ytdlpVersion), EJS \(proof.ejsVersion)"
                )
            )
            checks.append(
                check(
                    proof.failClosedDirector &&
                        !proof.sensitiveDirectorLogFound &&
                        proof.failClosedCases.values.allSatisfy { $0 },
                    id: "ejs-provider-fail-closed",
                    name: "Reject incomplete EJS results before fallback",
                    evidence: "cases=\(proof.failClosedCases.sorted { $0.key < $1.key }); sensitiveLogFound=\(proof.sensitiveDirectorLogFound)"
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "quickjs-ejs-proof",
                    name: "QuickJS and EJS in-process proof",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            let json = try await engine.execute(
                requestID: 7,
                requestJSON: #"{"action":"quickjs_timeout"}"#
            )
            let envelope = try JSONDecoder().decode(
                BridgeEnvelope<QuickJSTimeoutProof>.self,
                from: Data(json.utf8)
            )
            checks.append(
                check(
                    envelope.data.errorType == "TimeoutError" &&
                        envelope.data.providerErrorType ==
                            "IllucetProviderFailure" &&
                        envelope.data.elapsed < 2,
                    id: "quickjs-timeout",
                    name: "Bound QuickJS wall-clock execution",
                    evidence: "\(envelope.data.errorType) after \(envelope.data.elapsed)s"
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "quickjs-timeout",
                    name: "Bound QuickJS wall-clock execution",
                    evidence: error.localizedDescription
                )
            )
        }

        let quickJSCancellationTask = Task {
            try await engine.execute(
                requestID: 8,
                requestJSON: #"{"action":"quickjs_spin"}"#
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        engine.cancel(requestID: 8)
        do {
            _ = try await quickJSCancellationTask.value
            checks.append(
                failure(
                    id: "quickjs-cancellation",
                    name: "Cancel QuickJS through its interrupt handler",
                    evidence: "The infinite loop unexpectedly completed."
                )
            )
        } catch let error as PythonBridgeError {
            checks.append(
                check(
                    {
                        if case .cancelled = error { return true }
                        return false
                    }() &&
                        error.localizedDescription.contains(
                            "IllucetProviderCancelled"
                        ),
                    id: "quickjs-cancellation",
                    name: "Cancel QuickJS through its interrupt handler",
                    evidence: error.localizedDescription
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "quickjs-cancellation",
                    name: "Cancel QuickJS through its interrupt handler",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            _ = try await engine.execute(
                requestID: 2,
                requestJSON: #"{"action":"exception"}"#
            )
            checks.append(
                failure(
                    id: "exception-mapping",
                    name: "Python exception crosses typed bridge",
                    evidence: "The deterministic exception unexpectedly succeeded."
                )
            )
        } catch let error as PythonBridgeError {
            let text = error.localizedDescription
            checks.append(
                check(
                    text.contains("IllucetProofError") &&
                        !text.contains("Traceback"),
                    id: "exception-mapping",
                    name: "Python exception crosses typed bridge",
                    evidence: text
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "exception-mapping",
                    name: "Python exception crosses typed bridge",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            _ = try await engine.execute(
                requestID: 9,
                requestJSON: #"{"action":"sensitive_exception"}"#
            )
            checks.append(
                failure(
                    id: "exception-redaction",
                    name: "Redact sensitive Python error details",
                    evidence: "The sensitive exception unexpectedly succeeded."
                )
            )
        } catch let error as PythonBridgeError {
            let text = error.localizedDescription
            checks.append(
                check(
                    text.contains("[redacted sensitive error detail]") &&
                        !text.localizedCaseInsensitiveContains("COOKIE=") &&
                        !text.localizedCaseInsensitiveContains("Bearer") &&
                        !text.localizedCaseInsensitiveContains("sig=secret"),
                    id: "exception-redaction",
                    name: "Redact sensitive Python error details",
                    evidence: text
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "exception-redaction",
                    name: "Redact sensitive Python error details",
                    evidence: error.localizedDescription
                )
            )
        }

        let cancellationTask = Task {
            try await engine.execute(
                requestID: 3,
                requestJSON: #"{"action":"delay","steps":500,"interval":0.01}"#
            )
        }
        try? await Task.sleep(for: .milliseconds(120))
        engine.cancel(requestID: 3)
        do {
            _ = try await cancellationTask.value
            checks.append(
                failure(
                    id: "cooperative-cancellation",
                    name: "Cooperative cancellation",
                    evidence: "The delay request unexpectedly completed."
                )
            )
        } catch let error as PythonBridgeError {
            checks.append(
                check(
                    {
                        if case .cancelled = error { return true }
                        return false
                    }(),
                    id: "cooperative-cancellation",
                    name: "Cooperative cancellation",
                    evidence: error.localizedDescription
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "cooperative-cancellation",
                    name: "Cooperative cancellation",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            async let firstJSON = engine.execute(
                requestID: 4,
                requestJSON: #"{"action":"delay","steps":12,"interval":0.01}"#
            )
            async let secondJSON = engine.execute(
                requestID: 5,
                requestJSON: #"{"action":"delay","steps":12,"interval":0.01}"#
            )
            let (first, second) = try await (firstJSON, secondJSON)
            let firstEnvelope = try JSONDecoder().decode(
                BridgeEnvelope<DelayPythonProof>.self,
                from: Data(first.utf8)
            )
            let secondEnvelope = try JSONDecoder().decode(
                BridgeEnvelope<DelayPythonProof>.self,
                from: Data(second.utf8)
            )
            let noOverlap =
                firstEnvelope.data.finished <= secondEnvelope.data.started ||
                secondEnvelope.data.finished <= firstEnvelope.data.started
            checks.append(
                check(
                    noOverlap,
                    id: "request-serialization",
                    name: "Concurrent requests are serialized",
                    evidence: "Intervals: [\(firstEnvelope.data.started), \(firstEnvelope.data.finished)] and [\(secondEnvelope.data.started), \(secondEnvelope.data.finished)]."
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "request-serialization",
                    name: "Concurrent requests are serialized",
                    evidence: error.localizedDescription
                )
            )
        }

        checks.append(
            contentsOf: await LiveMetadataStage0ProofRunner.run(
                engine: engine
            )
        )

        do {
            try await engine.shutdown()
            checks.append(
                success(
                    id: "python-shutdown",
                    name: "Shutdown CPython on its worker pthread",
                    evidence: "Py_FinalizeEx returned zero."
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "python-shutdown",
                    name: "Shutdown CPython on its worker pthread",
                    evidence: error.localizedDescription
                )
            )
        }

        do {
            try await engine.start()
            checks.append(
                failure(
                    id: "python-terminal-state",
                    name: "Reject restart after interpreter shutdown",
                    evidence: "A finalized interpreter unexpectedly restarted."
                )
            )
        } catch let error as PythonBridgeError {
            checks.append(
                check(
                    error.localizedDescription.contains("terminal state"),
                    id: "python-terminal-state",
                    name: "Reject restart after interpreter shutdown",
                    evidence: error.localizedDescription
                )
            )
        } catch {
            checks.append(
                failure(
                    id: "python-terminal-state",
                    name: "Reject restart after interpreter shutdown",
                    evidence: error.localizedDescription
                )
            )
        }

        checks.append(contentsOf: await FFmpegStage0ProofRunner.run())

        return finalizedReport(checks: checks, recorder: recorder)
    }

    private static func prepareWritablePackage() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appending(path: "PythonPackages", directoryHint: .isDirectory)
            .appending(path: "v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let module = directory.appending(path: "writable_probe.py")
        try Data("ORIGIN = \"writable-version-1\"\n".utf8).write(
            to: module,
            options: .atomic
        )
        return directory
    }

    private static func persist(_ report: Stage0ProofReport) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        #if targetEnvironment(simulator)
        let reportName = "Stage0SimulatorReport.json"
        #else
        let reportName = "Stage0DeviceReport.json"
        #endif
        try encoder.encode(report).write(
            to: documents.appending(path: reportName),
            options: .atomic
        )
    }

    private static func report(
        checks: [Stage0Check],
        recorder: PythonEventRecorder
    ) -> Stage0ProofReport {
        #if targetEnvironment(simulator)
        let target = "iOS Simulator"
        #else
        let target = "Physical iOS device"
        #endif
        return Stage0ProofReport(
            generatedAt: Date(),
            target: target,
            checks: checks,
            events: recorder.allEvents
        )
    }

    private static func finalizedReport(
        checks: [Stage0Check],
        recorder: PythonEventRecorder
    ) -> Stage0ProofReport {
        let result = report(checks: checks, recorder: recorder)
        try? persist(result)
        return result
    }

    private static func check(
        _ condition: Bool,
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        condition
            ? success(id: id, name: name, evidence: evidence)
            : failure(id: id, name: name, evidence: evidence)
    }

    private static func success(
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        Stage0Check(
            id: id,
            name: name,
            status: .pass,
            evidence: evidence
        )
    }

    private static func failure(
        id: String,
        name: String,
        evidence: String
    ) -> Stage0Check {
        Stage0Check(
            id: id,
            name: name,
            status: .fail,
            evidence: evidence
        )
    }
}
