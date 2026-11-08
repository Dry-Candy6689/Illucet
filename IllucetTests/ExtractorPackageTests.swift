import CryptoKit
import Foundation
import Testing
@testable import Illucet

struct ExtractorPackageTests {
    @Test
    func previousRestoreStagesSwapsAndRecoversAfterInterruptedActivation() throws {
        let store = ExtractorPackageStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(throws: (any Error).self) { try store.restorePrevious() }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        let second = try publish(store, version: "2026.09.28")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: second.generation)
        #expect(try store.previousSelection()?.manifest == first)
        try store.restorePrevious()
        #expect(try store.currentSelection()?.manifest == second)
        #expect(try store.pendingSelection()?.manifest == first)
        #expect(throws: (any Error).self) { try store.restorePrevious() }
        #expect(try store.prepareForLaunch()?.manifest == first)
        // No confirmLaunch: simulate an interrupted rollback startup.
        #expect(try store.prepareForLaunch()?.manifest == second)
        try store.confirmLaunch(generation: second.generation)
    }

    @Test
    func previousRestoreActivatesAndRetainsCurrentAsFallback() throws {
        let store = ExtractorPackageStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        let second = try publish(store, version: "2026.09.28")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: second.generation)
        try store.restorePrevious()
        #expect(try store.prepareForLaunch()?.manifest == first)
        try store.confirmLaunch(generation: first.generation)
        #expect(try store.previousSelection()?.manifest == second)
    }

    @Test
    func previousRestoreRejectsCorruptedRetainedFiles() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        let second = try publish(store, version: "2026.09.28")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: second.generation)
        let file = store.root.appendingPathComponent(first.generation)
            .appendingPathComponent("site-packages/fixture.py")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("modified".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.restorePrevious() }
        #expect(try store.currentSelection()?.manifest == second)
        #expect(try store.pendingSelection() == nil)
    }

    @Test
    func releaseIdentityIsExactAndChannelSpecific() throws {
        #expect(try ExtractorPackageCatalog.distributionVersion(release: "2026.09.27", channel: .stable)
            == "2026.9.27")
        #expect(try ExtractorPackageCatalog.distributionVersion(release: "2026.09.27.232945", channel: .nightly)
            == "2026.9.27.232945.dev0")
        for version in ["2026.9.27", "2026.09.27\n", "2026.99.27", "../2026.09.27", "2026.09.27.dev0"] {
            #expect(throws: (any Error).self) {
                try ExtractorPackageCatalog.distributionVersion(release: version, channel: .stable)
            }
        }
        #expect(throws: (any Error).self) {
            try ExtractorPackageCatalog.distributionVersion(release: "2026.09.27", channel: .nightly)
        }
        #expect(throws: (any Error).self) {
            try ExtractorPackageCatalog.distributionVersion(release: "2026.09.27.232945", channel: .stable)
        }
    }

    @Test
    func pinsRejectAmbiguityAndUnsupportedRequirements() throws {
        #expect(try ExtractorPackageCatalog.pinnedDependency("yt-dlp-ejs", in: [
            "", "yt-dlp-ejs==0.8.0; extra == 'default'", "yt-dlp-ejs==0.8.0; extra == 'pin'",
        ]) == "0.8.0")
        for requirements in [["yt-dlp-ejs>=0.8.0"], ["yt-dlp-ejs==0.8.*"],
                             ["yt-dlp-ejs==0.8.0", "yt-dlp-ejs==0.9.0"],
                             ["yt-dlp-ejs==0.8.0\n"], ["yt-dlp-ejs==https://other.test/code"]] {
            #expect(throws: (any Error).self) {
                try ExtractorPackageCatalog.pinnedDependency("yt-dlp-ejs", in: requirements)
            }
        }
    }

    @Test
    func artifactMetadataRejectsUnsafeSourcesAndNonUniversalWheels() throws {
        let valid = try metadata()
        #expect(try ExtractorPackageCatalog.artifact(valid, package: "yt-dlp", version: "2026.9.27").size == 4)
        let changes: [[String: Any]] = [
            ["url": "http://files.pythonhosted.org/packages/a/yt_dlp-2026.9.27-py3-none-any.whl"],
            ["url": "https://files.pythonhosted.org.evil.test/packages/a/yt_dlp-2026.9.27-py3-none-any.whl"],
            ["url": "https://user@files.pythonhosted.org/packages/a/yt_dlp-2026.9.27-py3-none-any.whl"],
            ["url": "https://files.pythonhosted.org/packages/a/yt_dlp-2026.9.27-py3-none-any.whl?token=secret"],
            ["url": "https://files.pythonhosted.org/packages/%2e%2e/yt_dlp-2026.9.27-py3-none-any.whl"],
            ["filename": "yt_dlp-2026.9.27-cp314-ios_arm64.whl"],
            ["packagetype": "sdist"], ["yanked": true], ["size": 0],
            ["size": 33 * 1_024 * 1_024], ["digests": ["sha256": "bad"]],
        ]
        for change in changes {
            let value = try metadata(fileOverrides: change)
            #expect(throws: (any Error).self) {
                try ExtractorPackageCatalog.artifact(value, package: "yt-dlp", version: "2026.9.27")
            }
        }
        #expect(throws: (any Error).self) {
            try ExtractorPackageCatalog.artifact(metadata(infoOverrides: ["name": "unrelated"]),
                                                   package: "yt-dlp", version: "2026.9.27")
        }
    }

    @Test
    func stagingOnlyActivatesOnLaunchAndUnconfirmedLaunchRollsBack() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let first = try publish(store, version: "2026.09.27")
        #expect(try store.currentSelection() == nil)
        #expect(try store.pendingSelection()?.manifest == first)
        #expect(try store.prepareForLaunch()?.manifest == first)
        try store.confirmLaunch(generation: first.generation)
        let second = try publish(store, version: "2026.09.28")
        #expect(try store.currentSelection()?.manifest == first)
        #expect(try store.prepareForLaunch()?.manifest == second)
        // A new process observes the durable unfinished activation marker.
        let relaunched = ExtractorPackageStore(root: store.root)
        #expect(try relaunched.prepareForLaunch()?.manifest == first)
        try relaunched.confirmLaunch(generation: first.generation)
        #expect(try relaunched.pendingSelection() == nil)
    }

    @Test
    func importRejectionRetriesPreviousThenBundled() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        let second = try publish(store, version: "2026.09.28")
        _ = try store.prepareForLaunch()
        #expect(try store.rejectLaunch(generation: second.generation)?.manifest == first)
        #expect(try store.rejectLaunch(generation: first.generation) == nil)
        #expect(try store.currentSelection() == nil)
    }

    @Test
    func bundledResetDoesNotChangeTheRunningGeneration() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        _ = try publish(store, version: "2026.09.28")
        try store.restoreBundled()
        #expect(try store.pendingResetToBundled())
        #expect(try store.currentSelection()?.manifest == first)
        #expect(try store.pendingSelection() == nil)
        #expect(try store.prepareForLaunch() == nil)
        #expect(try !store.pendingResetToBundled())
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(first.generation).path))
    }

    @Test
    func corruptedContentsAndSymlinksCannotActivate() throws {
        for useSymlink in [false, true] {
            let store = temporaryStore()
            defer { removeStore(store) }
            let first = try publish(store, version: "2026.09.27")
            _ = try store.prepareForLaunch()
            try store.confirmLaunch(generation: first.generation)
            let second = try publish(store, version: "2026.09.28")
            let target = store.root.appendingPathComponent(second.generation)
                .appendingPathComponent("site-packages/fixture.py")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.deletingLastPathComponent().path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if useSymlink {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            } else {
                try Data("modified".utf8).write(to: target)
            }
            #expect(throws: (any Error).self) { try store.pendingSelection() }
            #expect(try store.requiresRuntimeActivation())
            #expect(try store.prepareForLaunch()?.manifest == first)
        }
    }

    @Test
    func malformedStateIsPreservedAndInterruptedStagingIsInvisible() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let staging = try store.createStagingDirectory()
        try Data("incomplete".utf8).write(to: staging.appendingPathComponent("part"))
        #expect(try store.prepareForLaunch() == nil)
        let stateURL = store.root.appendingPathComponent("state.json")
        let malformed = Data("{malformed".utf8)
        try malformed.write(to: stateURL)
        #expect(throws: (any Error).self) { try store.prepareForLaunch() }
        #expect(throws: (any Error).self) { try store.requiresRuntimeActivation() }
        #expect(throws: (any Error).self) { try store.restoreBundled() }
        #expect(try Data(contentsOf: stateURL) == malformed)
    }

    @Test
    func checksumFailureNeverReachesExtractionOrPublishes() async throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let fetch: ExtractorPackageCatalog.Fetch = { url, _ in
            if url.host == "pypi.org" {
                let components = url.pathComponents
                let package = components[2]
                let version = components[3]
                return try Self.metadataData(package: package, version: version)
            }
            return Data("evil".utf8)
        }
        let installer = ExtractorPackageInstaller(store: store, fetch: fetch)
        do {
            _ = try await installer.stage(release: .init(channel: .stable, version: "2026.09.27", publishedAt: .now)) { _, _ in
                Issue.record("Unverified bytes reached the extraction callback")
                throw ExtractorPackageError.invalidArchive
            }
            Issue.record("Unverified package was staged")
        } catch ExtractorPackageError.checksumMismatch { }
        #expect(try store.pendingSelection() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test
    func extractionFailureCleansUpAndPreservesPriorPending() async throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let original = try publish(store, version: "2026.09.27")
        let fetch: ExtractorPackageCatalog.Fetch = { url, _ in
            if url.host == "pypi.org" {
                return try Self.metadataData(package: url.pathComponents[2], version: url.pathComponents[3])
            }
            return Data("good".utf8)
        }
        let installer = ExtractorPackageInstaller(store: store, fetch: fetch)
        do {
            _ = try await installer.stage(release: .init(channel: .stable, version: "2026.09.28", publishedAt: .now)) { _, directory in
                try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.py"))
                throw ExtractorPackageError.invalidArchive
            }
            Issue.record("Failed extraction was staged")
        } catch ExtractorPackageError.invalidArchive { }
        #expect(try store.pendingSelection()?.manifest == original)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: store.root.path)
            .contains(where: { $0.hasPrefix("staging-") }))
    }

    @Test
    func verifiedStagePublishesImmutableHashedFilesAndWaitsForRelaunch() async throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let installer = ExtractorPackageInstaller(store: store, fetch: { url, _ in
            if url.host == "pypi.org" {
                return try Self.metadataData(package: url.pathComponents[2], version: url.pathComponents[3])
            }
            return Data("good".utf8)
        })
        let manifest = try await installer.stage(release: .init(channel: .stable, version: "2026.09.27", publishedAt: .now)) { wheels, directory in
            #expect(wheels.count == 3)
            for wheel in wheels { #expect(try Data(contentsOf: wheel.fileURL) == Data("good".utf8)) }
            try Data("validated".utf8).write(to: directory.appendingPathComponent("fixture.py"))
            return .init(ytDLP: "2026.09.27", ejs: "0.8.0", certifi: "2026.7.22")
        }
        #expect(try store.currentSelection() == nil)
        let selected = try #require(try store.pendingSelection())
        #expect(selected.manifest == manifest)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: selected.sitePackages.appendingPathComponent("fixture.py").path
        )[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o400)
        #expect(try store.prepareForLaunch()?.manifest == manifest)
        try store.confirmLaunch(generation: manifest.generation)
    }

    @Test
    func startupPrunesOnlyUnreferencedGenerationsAndOldStages() throws {
        let store = temporaryStore()
        defer { removeStore(store) }
        let first = try publish(store, version: "2026.09.27")
        _ = try store.prepareForLaunch()
        try store.confirmLaunch(generation: first.generation)
        let orphan = try publish(store, version: "2026.09.28")
        let latest = try publish(store, version: "2026.09.29")
        let oldStage = try store.createStagingDirectory()
        let freshStage = try store.createStagingDirectory()
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-172_800)],
                                              ofItemAtPath: oldStage.path)
        #expect(try store.prepareForLaunch()?.manifest == latest)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent(orphan.generation).path))
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(first.generation).path))
        #expect(FileManager.default.fileExists(atPath: freshStage.path))
        #expect(!FileManager.default.fileExists(atPath: oldStage.path))
    }

    private func removeStore(_ store: ExtractorPackageStore) {
        if let enumerator = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   attributes[.type] as? FileAttributeType == .typeDirectory {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try? FileManager.default.removeItem(at: store.root)
    }

    private func temporaryStore() -> ExtractorPackageStore {
        ExtractorPackageStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractorPackageTests-" + UUID().uuidString))
    }

    private func publish(_ store: ExtractorPackageStore, version: String) throws -> ExtractorPackageManifest {
        let staging = try store.createStagingDirectory()
        let packages = staging.appendingPathComponent("site-packages")
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: false)
        try Data("fixture \(version)".utf8).write(to: packages.appendingPathComponent("fixture.py"))
        let digest = String(repeating: "a", count: 64)
        let manifest = ExtractorPackageManifest(
            generation: UUID().uuidString, channel: .stable,
            versions: .init(ytDLP: version, ejs: "0.8.0", certifi: "2026.7.22"), installedAt: .now,
            packages: [.init(package: "yt-dlp", version: try ExtractorPackageCatalog.distributionVersion(release: version, channel: .stable), sha256: digest),
                       .init(package: "yt-dlp-ejs", version: "0.8.0", sha256: digest),
                       .init(package: "certifi", version: "2026.7.22", sha256: digest)],
            fileHashes: try ExtractorPackageStore.hashTree(packages)
        )
        try store.publish(manifest, staging: staging)
        return manifest
    }

    private func metadata(fileOverrides: [String: Any] = [:], infoOverrides: [String: Any] = [:]) throws -> ExtractorPackageCatalog.Metadata {
        try JSONDecoder().decode(ExtractorPackageCatalog.Metadata.self,
            from: Self.metadataData(fileOverrides: fileOverrides, infoOverrides: infoOverrides))
    }

    private static func metadataData(package: String = "yt-dlp", version: String = "2026.9.27",
                                     fileOverrides: [String: Any] = [:], infoOverrides: [String: Any] = [:]) throws -> Data {
        let filename = package.replacingOccurrences(of: "-", with: "_") + "-\(version)-py3-none-any.whl"
        var file: [String: Any] = ["filename": filename,
            "url": "https://files.pythonhosted.org/packages/a/\(filename)", "size": 4,
            "packagetype": "bdist_wheel", "yanked": false,
            "digests": ["sha256": SHA256.hash(data: Data("good".utf8)).map { String(format: "%02x", $0) }.joined()]]
        file.merge(fileOverrides) { _, new in new }
        var info: [String: Any] = ["name": package, "version": version, "requires_python": ">=3.10",
                                 "requires_dist": ["yt-dlp-ejs==0.8.0; extra == 'default'", "certifi==2026.7.22; extra == 'pin'"]]
        info.merge(infoOverrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["info": info, "urls": [file]])
    }
}
