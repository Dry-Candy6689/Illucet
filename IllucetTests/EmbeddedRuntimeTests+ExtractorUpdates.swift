import Foundation
import Testing
@testable import Illucet

// Keep the same serialized suite: all tests share the embedded interpreter.
extension EmbeddedRuntimeTests {
    @Test
    func installedRuntimeImportsSelectedGenerationAndRestoresBundledAfterRelaunch() async throws {
        let store = runtimeFixtureStore()
        defer { removeRuntimeFixture(store.root) }
        let manifest = try publishRuntimeFixture(store: store, mismatchedContract: false)
        #expect(try store.pendingSelection()?.manifest == manifest)
        let runtime = RuntimeEnvironment(packageStore: store)
        do {
            // Both callers cross the startup suspension while no interpreter
            // exists. They must share one initialization and one activation.
            async let extractor = runtime.extractor()
            async let resolver = runtime.resolver()
            let (readyExtractor, _) = try await (extractor, resolver)
            let versions = try await readyExtractor.versions()
            #expect(versions.ytDLP == manifest.versions.ytDLP)
            #expect(versions.ytDLP != DependencyVersions.ytDLP)
            #expect(versions.ejs == manifest.versions.ejs)
            #expect(try await runtime.activePackageManifest() == manifest)
            #expect(try store.currentSelection()?.manifest == manifest)
            #expect(try store.pendingSelection() == nil)
            #expect(await runtime.activationMessage() == nil)
            let service = ExtractorUpdateService(store: store)
            let activeStatus = try await service.refreshed(.initial, runtime: runtime)
            #expect(activeStatus.activeChannel == manifest.channel)
            // Executes the real initialized QuickJS/EJS provider smoke proof.
            try await runtime.testExtractor()

            try store.restoreBundled()
            let stagedStatus = try await service.refreshed(activeStatus, runtime: runtime)
            #expect(stagedStatus.state == .staged)
            #expect(stagedStatus.activeChannel == manifest.channel)
            #expect(try store.pendingResetToBundled())
            #expect(try await readyExtractor.versions().ytDLP == manifest.versions.ytDLP)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()

        let relaunched = RuntimeEnvironment(packageStore: store)
        do {
            let extractor = try await relaunched.extractor()
            let versions = try await extractor.versions()
            #expect(versions.ytDLP == DependencyVersions.ytDLP)
            #expect(versions.ejs == DependencyVersions.ejs)
            #expect(try await relaunched.activePackageManifest() == nil)
            #expect(try !store.pendingResetToBundled())
            #expect(try store.currentSelection() == nil)
            let restoredStatus = try await ExtractorUpdateService(store: store).refreshed(.initial, runtime: relaunched)
            #expect(restoredStatus.activeChannel == nil)
            try await relaunched.testExtractor()
        } catch {
            await relaunched.shutdown()
            throw error
        }
        await relaunched.shutdown()
    }

    @Test
    func installedRuntimeContractFailureFallsBackToBundledWithoutNetwork() async throws {
        let store = runtimeFixtureStore()
        defer { removeRuntimeFixture(store.root) }
        let rejected = try publishRuntimeFixture(store: store, mismatchedContract: true)
        // Hashes and manifest are internally valid: this failure must occur
        // when the embedded interpreter checks the actual imported version.
        #expect(try store.pendingSelection()?.manifest == rejected)
        let runtime = RuntimeEnvironment(packageStore: store)
        do {
            let extractor = try await runtime.extractor()
            let versions = try await extractor.versions()
            #expect(versions.ytDLP == DependencyVersions.ytDLP)
            #expect(versions.ejs == DependencyVersions.ejs)
            #expect(try await runtime.activePackageManifest() == nil)
            #expect(await runtime.activationMessage() != nil)
            #expect(try store.currentSelection() == nil)
            #expect(try store.pendingSelection() == nil)
            try await runtime.testExtractor()
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    @Test("Explicit official extractor download and activation",
          .enabled(if: ExtractorUpdateLiveTestGate.isEnabled))
    func officialExtractorUpdateStagesActivatesAndRestoresBundled() async throws {
        let sourceURL = if let path = ProcessInfo.processInfo.environment["ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH"] {
            try AuthorizedLiveTestConfigurationLoader.decode(Data(contentsOf: URL(filePath: path)),
                source: .environmentPath).standardVideoURL
        } else {
            URL(string: "https://www.youtube.com/watch?v=YE7VzlLtp-4")!
        }
        let store = runtimeFixtureStore()
        defer { removeRuntimeFixture(store.root) }
        let service = ExtractorUpdateService(store: store)
        let runtime = RuntimeEnvironment(packageStore: store)
        var staged = UpdateStatus.initial
        let offeredVersion: String
        var comparisonConfiguration: DownloadConfiguration?
        var baselineFailure: (any Error)?
        do {
            let extractor = try await runtime.extractor()
            let bundled = try await extractor.versions()
            #expect(bundled.ytDLP == DependencyVersions.ytDLP)
            #expect(try await runtime.activePackageManifest() == nil)
            if ExtractorUpdateLiveTestGate.compareBundled {
                let metadata = try await extractor.analyze(url: sourceURL)
                var configuration = compatibleUpdateTestConfiguration()
                configuration.thumbnailBehavior = .includeVideoThumbnail
                if let requested = ProcessInfo.processInfo.environment["ILLUCET_UPDATER_TEST_FORMATS"] {
                    let ids = requested.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    try #require((1...2).contains(ids.count) && Set(ids).count == ids.count)
                    try #require(ids.allSatisfy { $0.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#,
                                                          options: .regularExpression) != nil })
                    let video = try #require(metadata.formats.first { $0.formatID == ids[0] && $0.hasVideo })
                    configuration.selectedVideoFormatID = video.formatID
                    if ids.count == 2 {
                        let audio = try #require(metadata.formats.first {
                            $0.formatID == ids[1] && $0.hasAudio && !$0.hasVideo
                        })
                        try #require(!video.hasAudio)
                        configuration.selectedAudioFormatID = audio.formatID
                    } else {
                        configuration.mode = video.hasAudio ? .videoAndAudio : .videoOnly
                        configuration.selectedAudioFormatID = nil
                    }
                } else {
                    FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
                }
                try #require(!configuration.selectedFormatIDs.isEmpty)
                configuration = OutputCapabilityMatrix.normalized(configuration)
                // Freeze identity across both runs, including pipeline reanalysis.
                configuration.formatSelectionProvenance = .manual
                comparisonConfiguration = configuration
                do {
                    try await verifyAuthorizedDownload(runtime: runtime, extractorVersion: bundled.ytDLP,
                                                       sourceURL: sourceURL, configuration: configuration)
                    print("extractor_comparison bundled=PASS")
                } catch {
                    baselineFailure = error
                    print("extractor_comparison bundled=FAIL")
                }
            }
            let channel = ExtractorUpdateLiveTestGate.channel
            let checked = await service.check(current: .initial, channel: channel)
            try #require(checked.state == .updateAvailable,
                         "Official channel did not offer an installable release; live installation was not exercised.")
            offeredVersion = try #require(checked.availableRelease?.version)
            staged = try await service.install(current: checked, channel: channel,
                                               confirmedOlderVersion: true, runtime: runtime)
            #expect(staged.state == .staged)
            #expect(staged.activeYTDLPVersion == bundled.ytDLP)
            #expect(try await extractor.versions().ytDLP == bundled.ytDLP)
            #expect(try await runtime.activePackageManifest() == nil)
            #expect(try store.currentSelection() == nil)
            let pending = try #require(try store.pendingSelection())
            #expect(pending.manifest.versions.ytDLP == offeredVersion)
            #expect(pending.manifest.channel == channel)
            print("extractor_update_live staged=\(pending.manifest.versions.ytDLP) ejs=\(pending.manifest.versions.ejs) certifi=\(pending.manifest.versions.certifi) files=\(pending.manifest.fileHashes.count)")
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()

        let relaunched = RuntimeEnvironment(packageStore: store)
        var downloadFailure: (any Error)?
        do {
            let extractor = try await relaunched.extractor()
            let versions = try await extractor.versions()
            let active = try #require(try await relaunched.activePackageManifest())
            #expect(active.versions.ytDLP == offeredVersion)
            #expect(active.channel == ExtractorUpdateLiveTestGate.channel)
            #expect(versions.ytDLP == offeredVersion)
            #expect(versions.ejs == active.versions.ejs)
            #expect(try store.pendingSelection() == nil)
            #expect(await relaunched.activationMessage() == nil)
            try await relaunched.testExtractor()
            let refreshed = try await service.refreshed(staged, runtime: relaunched)
            #expect(refreshed.activeYTDLPVersion == offeredVersion)
            #expect(refreshed.lastSuccessfulUpdateAt != nil)
            print("extractor_update_live activated=\(versions.ytDLP) provider=PASS")
            do {
                try await verifyAuthorizedDownload(runtime: relaunched, extractorVersion: offeredVersion,
                                                   sourceURL: sourceURL, configuration: comparisonConfiguration)
                print("extractor_comparison installed=PASS")
            } catch {
                downloadFailure = error
                print("extractor_comparison installed=FAIL")
            }
            _ = try await service.resetToBundled(refreshed, runtime: relaunched)
            #expect(try await extractor.versions().ytDLP == offeredVersion)
            #expect(try store.pendingResetToBundled())
        } catch {
            await relaunched.shutdown()
            throw error
        }
        await relaunched.shutdown()

        let restored = RuntimeEnvironment(packageStore: store)
        do {
            let extractor = try await restored.extractor()
            let versions = try await extractor.versions()
            #expect(versions.ytDLP == DependencyVersions.ytDLP)
            #expect(versions.ejs == DependencyVersions.ejs)
            #expect(try await restored.activePackageManifest() == nil)
            #expect(try store.currentSelection() == nil)
            #expect(try !store.pendingResetToBundled())
            try await restored.testExtractor()
            print("extractor_update_live restored=\(versions.ytDLP) provider=PASS")
        } catch {
            await restored.shutdown()
            throw error
        }
        await restored.shutdown()
        if let downloadFailure { throw downloadFailure }
        if let baselineFailure { throw baselineFailure }
    }

    @Test("Explicit saved-account public download",
          .enabled(if: ProcessInfo.processInfo.environment["ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME"] != nil))
    func savedAccountDownloadsAuthorizedPublicVideoAfterRelaunch() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME"])
        let runtime = RuntimeEnvironment()
        do {
            let profiles = try await runtime.accounts.profiles().filter { $0.name == name }
            try #require(profiles.count == 1)
            let id = try #require(profiles.first?.id)
            _ = try await runtime.accounts.session(for: id)
            let extractor = try await runtime.extractor(accountID: id)
            let version = try await extractor.versions().ytDLP
            try await verifyAuthorizedDownload(runtime: runtime, extractorVersion: version, accountID: id)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    /// Called only from explicit live tests.
    /// Uses the same public Blender Foundation fixture as the existing live gate.
    private func verifyAuthorizedDownload(runtime: RuntimeEnvironment, extractorVersion: String,
                                          accountID: UUID? = nil,
                                          sourceURL: URL = URL(string: "https://www.youtube.com/watch?v=YE7VzlLtp-4")!,
                                          configuration suppliedConfiguration: DownloadConfiguration? = nil) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Illucet-UpdatedExtractorDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = StreamDownloadService(sessionIdentifier: "com.local.illucet.update-live.\(UUID().uuidString)")
        let processor = NativeFFmpegMediaProcessor()
        let publicationStore = IllucetPersistence(rootURL: root.appending(path: "PublicationState"))
        let diagnostics = DiagnosticStore(rootURL: root.appending(path: "Diagnostics"))
        let coordinator = DownloadCoordinator(runtime: runtime, downloader: downloader,
            DASHDownloader: downloader, DASHAssembler: DASHLocalStreamAssembler(mediaProcessor: processor),
            HLSDownloader: downloader, HLSAssembler: HLSLocalStreamAssembler(mediaProcessor: processor),
            mediaProcessor: processor, storage: StorageManager(),
            exporter: ExportManager(documentsRootURL: root.appending(path: "Documents"),
                                    shareRootURL: root.appending(path: "Share")),
            thumbnails: ThumbnailService(), diagnostics: diagnostics,
            notifications: UserNotificationService())
        var settings = AppSettings.defaults
        settings.minimumFreeSpaceReserveBytes = 0
        settings.notifyDownloadComplete = false
        settings.notifyProcessingComplete = false
        settings.notifyFailure = false
        settings.notifyNeedsAttention = false
        settings.notifyLowStorage = false
        settings.liveActivities = false
        settings.automaticRetryCount = 0
        settings.keepTemporaryFilesAfterFailure = false
        await coordinator.configure(settings: settings, folderBookmark: nil)
        await coordinator.setPublicationWriter { job in
            var snapshot = try await publicationStore.load()
            snapshot.jobs.removeAll { $0.id == job.id }
            snapshot.jobs.append(job)
            try await publicationStore.save(snapshot)
        }
        await coordinator.restore([])
        await coordinator.resumeForegroundJobs()

        do {
            let extractor = try await runtime.extractor(accountID: accountID)
            #expect(try await extractor.versions().ytDLP == extractorVersion)
            let extraction = try await extractor.analyzeWithEvidence(url: sourceURL, retainForDownload: true)
            let metadata = extraction.metadata
            let providerEvidence = extraction.providerEvidence
            print("extractor_provider_evidence extractor=\(extractorVersion) requests=\(providerEvidence.challengeRequestCount) responses=\(providerEvidence.challengeResponseCount) provider_errors=\(providerEvidence.providerFailureCount) runtime_errors=\(providerEvidence.runtimeErrorCount)")
            var configuration = suppliedConfiguration ?? compatibleUpdateTestConfiguration()
            configuration.accountID = accountID
            if configuration.selectedFormatIDs.isEmpty {
                FormatSelection.applyAutomaticSelection(to: &configuration, metadata: metadata)
            }
            let facts = try FormatSelection.selectedSourceFacts(configuration: configuration, metadata: metadata)
            // Format IDs and transport names are safe; descriptors/headers are not.
            print("extractor_download_selection extractor=\(extractorVersion) sources=\(facts.map { "\($0.formatID):\($0.transport.rawValue)" }) locked=\(configuration.formatSelectionProvenance == .manual)")
            let job = try await coordinator.enqueue(metadata: metadata, configuration: configuration,
                                                    extractorVersion: extractorVersion)
            let terminal = try await withThrowingTaskGroup(of: DownloadJob.self) { group in
                group.addTask {
                    for await event in coordinator.updates {
                        if case let .upsertJob(value) = event, value.id == job.id, value.state.isTerminal {
                            return value
                        }
                    }
                    throw ExtractorUpdateDownloadTestFailure.noTerminalResult
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(600))
                    throw ExtractorUpdateDownloadTestFailure.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            // Emit the typed error code and event names without source descriptors.
            guard terminal.state == .completed else {
                let events = await diagnostics.allEntries().map(\.event)
                print("extractor_download_failure state=\(terminal.state.rawValue) code=\(terminal.errorCode ?? "unknown") events=\(events)")
                throw ExtractorUpdateDownloadTestFailure.pipelineFailed
            }
            let output = try #require(terminal.outputURL)
            let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            try #require(values.isRegularFile == true && values.isSymbolicLink != true)
            try #require((values.fileSize ?? 0) > 0)
            let probe = try #require(terminal.outputProbe)
            try #require(probe.videoStreamCount > 0)
            if configuration.mode == .videoOnly {
                try #require(probe.audioStreamCount == 0)
            } else {
                try #require(probe.audioStreamCount > 0)
            }
            #expect(terminal.extractorVersion == extractorVersion)
            #expect(terminal.configuration.accountID == accountID)
            let evidence = accountID == nil ? "extractor_update_live" : "saved_account_live"
            print("\(evidence) download=PASS bytes=\(values.fileSize ?? 0) video_streams=\(probe.videoStreamCount) audio_streams=\(probe.audioStreamCount) extractor=\(extractorVersion)")
        } catch {
            await coordinator.cancelAll()
            throw error
        }
        await coordinator.clearCompleted()
    }

    private func compatibleUpdateTestConfiguration() -> DownloadConfiguration {
        // Match the compatible output exercised by the simulator smoke test.
        // Extractor activation proof should be independent of AV1 decoding.
        var configuration = PDR1LiveSmokeMode.videoAndAudio.configuration
        configuration.preset = .compatible
        configuration.videoCodec = .h264
        configuration.audioCodec = .aac
        configuration.container = .mp4
        configuration.filenameTemplate = "updated-extractor-video-audio"
        return OutputCapabilityMatrix.normalized(configuration)
    }

    private func runtimeFixtureStore() -> ExtractorPackageStore {
        ExtractorPackageStore(root: FileManager.default.temporaryDirectory
            .appending(path: "Illucet-ActivationTest-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func publishRuntimeFixture(
        store: ExtractorPackageStore, mismatchedContract: Bool
    ) throws -> ExtractorPackageManifest {
        let resources = try #require(Bundle.main.resourceURL)
        let bundled = resources.appending(path: "PythonPackages")
        let staging = try store.createStagingDirectory()
        let packages = staging.appending(path: "site-packages")
        try FileManager.default.copyItem(at: bundled, to: packages)
        // The synthetic version proves sys.path selected these copied files,
        // while all actual extractor/provider implementations remain intact.
        let fixtureVersion = "2099.12.30.235959"
        let distribution = try ExtractorPackageCatalog.distributionVersion(release: fixtureVersion, channel: .nightly)
        let versionURL = packages.appending(path: "yt_dlp/version.py")
        let versionSource = try String(contentsOf: versionURL, encoding: .utf8)
        let versionPattern = #"(?m)^__version__ = ['\"][^'\"]+['\"]$"#
        try #require(versionSource.range(of: versionPattern, options: .regularExpression) != nil)
        let updatedSource = versionSource.replacingOccurrences(of: versionPattern,
            with: "__version__ = '\(fixtureVersion)'", options: .regularExpression)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: versionURL.path)
        try updatedSource.write(to: versionURL, atomically: true, encoding: .utf8)

        var distributionVersions: [String: String] = [:]
        let children = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)
        for directory in children where directory.lastPathComponent.hasSuffix(".dist-info") {
            let metadataURL = directory.appending(path: "METADATA")
            let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
            let lines = metadata.split(separator: "\n")
            guard let nameLine = lines.first(where: { $0.hasPrefix("Name: ") }),
                  let versionLine = lines.first(where: { $0.hasPrefix("Version: ") }) else {
                throw ExtractorPackageError.invalidMetadata
            }
            let name = String(nameLine.dropFirst(6)).replacingOccurrences(of: "_", with: "-")
            distributionVersions[name] = String(versionLine.dropFirst(9))
            if name == "yt-dlp" {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
                try metadata.replacingOccurrences(of: String(versionLine), with: "Version: \(distribution)")
                    .write(to: metadataURL, atomically: true, encoding: .utf8)
                try FileManager.default.moveItem(at: directory,
                    to: packages.appending(path: "yt_dlp-\(distribution).dist-info"))
                distributionVersions[name] = distribution
            }
        }
        let ejs = try #require(distributionVersions["yt-dlp-ejs"])
        let certifi = try #require(distributionVersions["certifi"])
        let versions = ExtractorInstalledVersions(ytDLP: fixtureVersion, ejs: ejs, certifi: certifi)
        let contract: [String: Any] = ["schemaVersion": 1,
            "ytDLP": mismatchedContract ? "2099.12.31.235959" : fixtureVersion,
            "ejs": ejs, "certifi": certifi, "quickJS": DependencyVersions.quickJS]
        try JSONSerialization.data(withJSONObject: contract).write(
            to: packages.appending(path: "_illucet_runtime.json"), options: .atomic)
        // This test bypasses transport with trusted bundle fixtures. Installed
        // file hashes, store activation, and Python contract checks remain real.
        let manifest = ExtractorPackageManifest(generation: UUID().uuidString, channel: .nightly,
            versions: versions, installedAt: .now,
            packages: ["yt-dlp", "yt-dlp-ejs", "certifi"].map {
                ExtractorPackageRecord(package: $0, version: distributionVersions[$0]!,
                                       sha256: String(repeating: "a", count: 64))
            }, fileHashes: try ExtractorPackageStore.hashTree(packages))
        try store.publish(manifest, staging: staging)
        return manifest
    }

    private func removeRuntimeFixture(_ root: URL) {
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   attributes[.type] as? FileAttributeType == .typeDirectory {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

}

private enum ExtractorUpdateLiveTestGate {
    static let isEnabled = ProcessInfo.processInfo.environment[
        "ILLUCET_EXTRACTOR_UPDATE_TESTS"
    ] == "1"
    static let channel = UpdateChannel(rawValue: ProcessInfo.processInfo.environment["ILLUCET_UPDATER_CHANNEL"] ?? "")
        ?? .nightly
    static let compareBundled = ProcessInfo.processInfo.environment["ILLUCET_UPDATER_COMPARE_BUNDLED"] == "1"
}

private enum ExtractorUpdateDownloadTestFailure: Error {
    case timeout, noTerminalResult, pipelineFailed
}
