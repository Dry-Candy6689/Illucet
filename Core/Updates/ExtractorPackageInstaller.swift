import CryptoKit
import Foundation

actor ExtractorPackageInstaller {
    typealias ExtractAndValidate = @Sendable ([ExtractorPackageArchive], URL) async throws -> ExtractorInstalledVersions
    typealias InspectMaster = @Sendable (ExtractorPackageArchive) async throws -> ExtractorMasterRequirements
    private let store: ExtractorPackageStore
    private let catalog: ExtractorPackageCatalog
    private var installing = false

    init(store: ExtractorPackageStore = .init(),
         fetch: @escaping ExtractorPackageCatalog.Fetch = ExtractorPackageTransport.fetch) {
        self.store = store
        catalog = ExtractorPackageCatalog(fetch: fetch)
    }

    /// Publication only queues a generation. This method never changes imports
    /// in the interpreter already serving downloads.
    func stage(release: ExtractorRelease,
               inspectMaster: InspectMaster = { _ in throw ExtractorPackageError.invalidArchive },
               extractAndValidate: ExtractAndValidate) async throws -> ExtractorPackageManifest {
        guard !installing else { throw ExtractorPackageError.invalidState }
        installing = true
        defer { installing = false }
        try Task.checkCancellation()
        let version = release.version
        let channel = release.channel
        let staging = try store.createStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let packages = staging.appendingPathComponent("site-packages", isDirectory: true)
        let downloads = staging.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        var archives: [ExtractorPackageArchive] = []
        let artifacts: [ExtractorPackageCatalog.Artifact]
        if channel == .master {
            guard let source = release.masterSource, source.isValid,
                  let url = ExtractorRelease.MasterSource.url(version: version)
            else { throw ExtractorPackageError.invalidMetadata }
            let artifact = ExtractorPackageCatalog.Artifact(package: "yt-dlp", version: version,
                filename: ExtractorRelease.MasterSource.filename, url: url, sha256: source.sha256, size: source.size)
            let archive = try await download(artifact, format: .masterSource, to: downloads)
            let metadata = try await inspectMaster(archive)
            guard ExtractorPackageCatalog.supportsPython(metadata.requiresPython)
            else { throw ExtractorPackageError.incompatiblePackage }
            archives.append(archive)
            artifacts = try await catalog.resolveDependencies(requirements: metadata.requirements)
        } else {
            artifacts = try await catalog.resolve(release: version, channel: channel)
        }
        for artifact in artifacts {
            archives.append(try await download(artifact, format: .wheel, to: downloads))
        }
        let versions = try await extractAndValidate(archives, packages)
        try Task.checkCancellation()
        guard versions.ytDLP == version,
              versions.ejs == artifacts.first(where: { $0.package == "yt-dlp-ejs" })?.version,
              versions.certifi == artifacts.first(where: { $0.package == "certifi" })?.version
        else { throw ExtractorPackageError.incompatiblePackage }
        try FileManager.default.removeItem(at: downloads)
        let hashes = try ExtractorPackageStore.hashTree(packages)
        let manifest = ExtractorPackageManifest(
            generation: UUID().uuidString, channel: channel, versions: versions,
            installedAt: .now,
            packages: archives.map { ExtractorPackageRecord(package: $0.package,
                                                           version: $0.version, sha256: $0.sha256) },
            fileHashes: hashes
        )
        try manifest.validate()
        try Task.checkCancellation()
        try store.publish(manifest, staging: staging)
        return manifest
    }

    private func download(
        _ artifact: ExtractorPackageCatalog.Artifact, format: ExtractorPackageArchive.Format, to downloads: URL
    ) async throws -> ExtractorPackageArchive {
        try Task.checkCancellation()
        let data = try await catalog.fetch(artifact.url, artifact.size)
        guard data.count == artifact.size else { throw ExtractorPackageError.sizeLimit }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw ExtractorPackageError.checksumMismatch }
        let fileURL = downloads.appendingPathComponent(artifact.filename)
        #if os(iOS)
        try data.write(to: fileURL, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.withoutOverwriting])
        #endif
        return .init(package: artifact.package, version: artifact.version, sha256: artifact.sha256,
                     fileURL: fileURL, format: format)
    }
}
