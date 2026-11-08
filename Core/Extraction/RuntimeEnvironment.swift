import Foundation

actor RuntimeEnvironment {
    let accounts: AccountStore
    private var python: PythonEngine?
    private var extractorEngine: YTDLPExtractorEngine?
    private var playlistAnalyzerEngine: YTDLPPlaylistAnalyzer?
    private var resolverEngine: YTDLPStreamResolver?
    private var hlsPlaylistResolverEngine: YTDLPHLSPlaylistResolver?
    private let recorder = PythonEventRecorder()
    private let packageStore: ExtractorPackageStore
    private var startupTask: Task<RuntimeStartup, Error>?
    private var activeManifest: ExtractorPackageManifest?
    private var startupMessage: String?
    private var activeContract: LiveExtractorContract = .bundled

    init(packageStore: ExtractorPackageStore = .init(), accounts: AccountStore = AccountStore()) {
        self.accounts = accounts
        self.packageStore = packageStore
    }

    private struct RuntimeStartup: Sendable {
        let engine: PythonEngine
        let manifest: ExtractorPackageManifest?
        let recovered: Bool
        let contract: LiveExtractorContract
    }

    func activePackageManifest() async throws -> ExtractorPackageManifest? {
        _ = try await startedPython()
        return activeManifest
    }

    func activationMessage() -> String? { startupMessage }

    func hasInstalledPackages() throws -> Bool {
        try packageStore.requiresRuntimeActivation()
    }

    func testExtractor() async throws {
        let engine = try await startedPython()
        _ = try await engine.execute(requestID: PythonRequestIDAllocator.next(),
            requestJSON: #"{"action":"validate_extractor_runtime"}"#)
    }

    #if DEBUG
    func probeYouTubeSession(_ request: YouTubeSessionProbeRequest) async throws -> YouTubeSessionProbeResult {
        let engine = try await startedPython()
        let data = try JSONEncoder().encode(request)
        let response = try await engine.execute(requestID: PythonRequestIDAllocator.next(),
            requestJSON: String(decoding: data, as: UTF8.self))
        let envelope = try JSONDecoder().decode(YouTubeSessionProbeEnvelope.self,
            from: Data(response.utf8))
        guard envelope.ok, let result = envelope.data else {
            throw ExtractionError.extractorFailure(code: envelope.error?.code ?? "probe_failed",
                message: envelope.error?.message ?? "The session test did not complete.", retryable: false)
        }
        return result
    }
    #endif

    func inspectMasterArchive(_ archive: ExtractorPackageArchive) async throws -> ExtractorMasterRequirements {
        let engine = try await startedPython()
        let request: [String: Any] = [
            "action": "inspect_master_extractor_archive",
            "archive": packageRequest(archive),
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try await engine.execute(requestID: PythonRequestIDAllocator.next(),
            requestJSON: String(decoding: data, as: UTF8.self))
        return try JSONDecoder().decode(BridgeEnvelope<ExtractorMasterRequirements>.self,
            from: Data(response.utf8)).data
    }

    func stagePackages(_ archives: [ExtractorPackageArchive], at directory: URL)
        async throws -> ExtractorInstalledVersions {
        let engine = try await startedPython()
        let request: [String: Any] = [
            "action": "stage_extractor_packages",
            "destination": directory.path,
            "archives": archives.map(packageRequest),
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try await engine.execute(requestID: PythonRequestIDAllocator.next(),
            requestJSON: String(decoding: data, as: UTF8.self))
        let envelope = try JSONDecoder().decode(BridgeEnvelope<ExtractorInstalledVersions>.self,
            from: Data(response.utf8))
        let versions = envelope.data
        let contract: [String: Any] = ["schemaVersion": 1, "ytDLP": versions.ytDLP,
            "ejs": versions.ejs, "certifi": versions.certifi, "quickJS": DependencyVersions.quickJS]
        try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys])
            .write(to: directory.appending(path: "_illucet_runtime.json"), options: .atomic)
        return versions
    }

    private func packageRequest(_ archive: ExtractorPackageArchive) -> [String: String] {
        ["package": archive.package, "version": archive.version, "sha256": archive.sha256,
         "path": archive.fileURL.path, "format": archive.format.rawValue]
    }

    func extractor(accountID: UUID? = nil) async throws -> YTDLPExtractorEngine {
        if let accountID {
            _ = try await accounts.session(for: accountID)
            let engine = try await startedPython()
            let authentication = AccountAuthentication(id: accountID, store: accounts)
            return YTDLPExtractorEngine(python: engine, contract: activeContract, authentication: authentication)
        }
        if let extractorEngine {
            return extractorEngine
        }
        let engine = try await startedPython()
        let extractor = YTDLPExtractorEngine(python: engine, contract: activeContract)
        extractorEngine = extractor
        return extractor
    }

    func resolver(accountID: UUID? = nil) async throws -> YTDLPStreamResolver {
        if let accountID {
            _ = try await accounts.session(for: accountID)
            let engine = try await startedPython()
            let authentication = AccountAuthentication(id: accountID, store: accounts)
            return YTDLPStreamResolver(python: engine, authentication: authentication)
        }
        if let resolverEngine {
            return resolverEngine
        }
        let engine = try await startedPython()
        let resolver = YTDLPStreamResolver(python: engine)
        resolverEngine = resolver
        return resolver
    }

    func playlistAnalyzer(accountID: UUID? = nil) async throws -> YTDLPPlaylistAnalyzer {
        if let accountID {
            _ = try await accounts.session(for: accountID)
            let engine = try await startedPython()
            let authentication = AccountAuthentication(id: accountID, store: accounts)
            return YTDLPPlaylistAnalyzer(python: engine, authentication: authentication)
        }
        if let playlistAnalyzerEngine {
            return playlistAnalyzerEngine
        }
        let engine = try await startedPython()
        let analyzer = YTDLPPlaylistAnalyzer(python: engine)
        playlistAnalyzerEngine = analyzer
        return analyzer
    }

    func hlsPlaylistResolver(accountID: UUID? = nil) async throws -> YTDLPHLSPlaylistResolver {
        if let accountID {
            _ = try await accounts.session(for: accountID)
            let engine = try await startedPython()
            let authentication = AccountAuthentication(id: accountID, store: accounts)
            return YTDLPHLSPlaylistResolver(python: engine, authentication: authentication)
        }
        if let hlsPlaylistResolverEngine {
            return hlsPlaylistResolverEngine
        }
        let engine = try await startedPython()
        let resolver = YTDLPHLSPlaylistResolver(python: engine)
        hlsPlaylistResolverEngine = resolver
        return resolver
    }

    func shutdown() async {
        guard let python else { return }
        try? await python.shutdown()
        self.python = nil
        startupTask = nil
        extractorEngine = nil
        playlistAnalyzerEngine = nil
        resolverEngine = nil
        hlsPlaylistResolverEngine = nil
    }

    private func startedPython() async throws -> PythonEngine {
        if let python {
            return python
        }
        if let startupTask {
            return try await finishStartup(startupTask.value)
        }
        let store = packageStore
        let recorder = recorder
        let task = Task { try await Self.bootstrap(store: store, recorder: recorder) }
        startupTask = task
        do { return try await finishStartup(task.value) }
        catch { startupTask = nil; throw error }
    }

    private func finishStartup(_ result: RuntimeStartup) -> PythonEngine {
        python = result.engine
        activeManifest = result.manifest
        activeContract = result.contract
        startupMessage = result.recovered
            ? "The update could not start. The previous working extractor was restored." : nil
        return result.engine
    }

    private static func bootstrap(store: ExtractorPackageStore, recorder: PythonEventRecorder)
        async throws -> RuntimeStartup {
        guard let resources = Bundle.main.resourceURL else {
            throw RuntimeEnvironmentError.missingBundleResources
        }
        var selection = try store.prepareForLaunch()
        var recovered = false
        while true {
            let writable = try selection?.sitePackages ?? prepareWritablePackages()
            let engine = try PythonEngine(
                pythonHome: resources.appending(path: "python"),
                bundledApp: resources.appending(path: "PythonApp"),
                bundledPackages: resources.appending(path: "PythonPackages"),
                writablePackages: writable, recorder: recorder)
            do {
                try await engine.start()
                let response = try await engine.execute(requestID: PythonRequestIDAllocator.next(),
                    requestJSON: #"{"action":"validate_extractor_runtime"}"#)
                let contract = try JSONDecoder().decode(BridgeEnvelope<LiveExtractorContract>.self,
                    from: Data(response.utf8)).data
                guard contract.ytDLP == (selection?.manifest.versions.ytDLP ?? DependencyVersions.ytDLP),
                      contract.ejs == (selection?.manifest.versions.ejs ?? DependencyVersions.ejs),
                      contract.quickJS == DependencyVersions.quickJS,
                      ExtractorPackageManifest.matches(contract.ejsCoreSHA3512, "[a-f0-9]{128}"),
                      ExtractorPackageManifest.matches(contract.ejsLibrarySHA3512, "[a-f0-9]{128}")
                else { throw ExtractorPackageError.incompatiblePackage }
                if let selection { try store.confirmLaunch(generation: selection.manifest.generation) }
                return RuntimeStartup(engine: engine, manifest: selection?.manifest, recovered: recovered, contract: contract)
            } catch {
                try? await engine.shutdown()
                guard let failed = selection else { throw error }
                selection = try store.rejectLaunch(generation: failed.manifest.generation)
                recovered = true
            }
        }
    }

    private static func prepareWritablePackages() throws -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "\(AppIdentity.storageDirectoryName)/Python/bundled-empty",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
enum RuntimeEnvironmentError: LocalizedError, Sendable {
    case missingBundleResources

    var errorDescription: String? {
        "The embedded runtime resources are missing from the application bundle."
    }
}
