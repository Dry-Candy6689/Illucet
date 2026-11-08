import Foundation

actor ExtractorUpdateService {
    private let session: URLSession?
    private let store: ExtractorPackageStore
    private let installer: ExtractorPackageInstaller

    init(session: URLSession? = nil, store: ExtractorPackageStore = .init()) {
        self.session = session
        self.store = store
        self.installer = ExtractorPackageInstaller(store: store)
    }

    func previousVersion() throws -> String? { try store.previousSelection()?.manifest.versions.ytDLP }

    func check(current: UpdateStatus, channel: UpdateChannel) async -> UpdateStatus {
        var status = current
        status.invalidateCheck()
        status.lastCheckedChannel = channel
        do {
            let release = try await latestRelease(channel)
            status.lastCheckedAt = .now
            if release.isInstallable(over: status) {
                status.availableRelease = release
                status.state = .updateAvailable
            } else {
                status.state = .current
                status.message = release.isOlder(than: status)
                    ? "You’re running a newer \(channel.rawValue) build."
                    : "You’re up to date on \(channel.rawValue)."
            }
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                return current
            }
            status.lastCheckedAt = .now
            status.state = .failed
            status.message = "Couldn’t check for updates. Try again."
        }
        return status
    }

    func install(
        current: UpdateStatus, channel: UpdateChannel, confirmedOlderVersion: Bool = false,
        runtime: RuntimeEnvironment
    ) async throws -> UpdateStatus {
        guard current.state == .updateAvailable, let offer = current.availableRelease,
              offer.channel == channel, current.lastCheckedChannel == channel,
              offer.isInstallable(over: current)
        else { throw UpdateError.invalidOffer }
        guard !offer.isOlder(than: current) || confirmedOlderVersion else {
            throw UpdateError.olderVersionNeedsConfirmation
        }
        // A stored offer must still match the official latest release and its artifact.
        guard try await latestRelease(channel) == offer else { throw UpdateError.releaseChanged }
        // Start the existing runtime before publishing pending state. A first
        // extraction later in this process must not activate a just-staged update.
        _ = try await runtime.activePackageManifest()
        let manifest = try await installer.stage(release: offer, inspectMaster: { archive in
            try await runtime.inspectMasterArchive(archive)
        }) { archives, directory in
            try await runtime.stagePackages(archives, at: directory)
        }
        var value = current
        value.availableRelease = nil
        value.state = .staged
        value.message = "Close and reopen Illucet to use yt-dlp \(manifest.versions.ytDLP)."
        return value
    }

    func refreshed(_ status: UpdateStatus, runtime: RuntimeEnvironment) async throws -> UpdateStatus {
        let manifest = try await runtime.activePackageManifest()
        var value = status
        let active = manifest?.versions.ytDLP ?? DependencyVersions.ytDLP
        let activeEJS = manifest?.versions.ejs ?? DependencyVersions.ejs
        if value.activeYTDLPVersion != active || value.activeChannel != manifest?.channel
            || value.activeEJSVersion != activeEJS || value.state == .staged {
            value.invalidateCheck()
        }
        value.bundledYTDLPVersion = DependencyVersions.ytDLP
        value.bundledEJSVersion = DependencyVersions.ejs
        value.activeYTDLPVersion = active
        value.activeEJSVersion = activeEJS
        value.activeCertifiVersion = manifest?.versions.certifi ?? DependencyVersions.certifi
        value.previousYTDLPVersion = (try? store.previousSelection())?.manifest.versions.ytDLP
        value.activeChannel = manifest?.channel
        value.lastSuccessfulUpdateAt = manifest?.installedAt
        if try store.pendingResetToBundled() {
            value.state = .staged
            value.message = "Close and reopen Illucet to restore the bundled extractor."
        } else if let pending = try store.pendingSelection() {
            value.state = .staged
            value.message = "Close and reopen Illucet to use yt-dlp \(pending.manifest.versions.ytDLP)."
        } else if let message = await runtime.activationMessage() {
            value.state = .failed
            value.message = message
        }
        return value
    }

    func resetToBundled(_ status: UpdateStatus, runtime: RuntimeEnvironment) async throws -> UpdateStatus {
        _ = try await runtime.activePackageManifest()
        try store.restoreBundled()
        var value = status
        value.availableRelease = nil
        value.state = .staged
        value.message = "Close and reopen Illucet to restore the bundled extractor."
        return value
    }

    func restorePrevious(_ status: UpdateStatus, runtime: RuntimeEnvironment) async throws -> UpdateStatus {
        _ = try await runtime.activePackageManifest()
        try store.restorePrevious()
        var value = status
        value.availableRelease = nil
        value.state = .staged
        value.message = "Close and reopen Illucet to restore the previous extractor."
        return value
    }

    private func latestRelease(_ channel: UpdateChannel) async throws -> ExtractorRelease {
        try Task.checkCancellation()
        let releaseURL = URL(string: "https://api.github.com/repos/yt-dlp/\(channel.releaseRepository)/releases/latest")!
        let limit = 1_048_576
        let data: Data
        if let session {
            var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            request.setValue("\(AppIdentity.fallbackDisplayName)/1", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == releaseURL, body.count <= limit
            else { throw UpdateError.invalidResponse }
            data = body
        } else {
            data = try await ExtractorPackageTransport.fetch(releaseURL, maximum: limit)
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let upstream = try decoder.decode(GitHubRelease.self, from: data)
        guard !upstream.draft, !upstream.prerelease else { throw UpdateError.invalidResponse }
        let version = upstream.tagName.hasPrefix("v") ? String(upstream.tagName.dropFirst()) : upstream.tagName
        _ = try ExtractorPackageCatalog.distributionVersion(release: version, channel: channel)
        var release = ExtractorRelease(channel: channel, version: version, publishedAt: upstream.publishedAt)
        if channel == .master {
            let assets = upstream.assets.filter { $0.name == ExtractorRelease.MasterSource.filename }
            guard upstream.tagName == version, assets.count == 1, let asset = assets.first,
                  let digest = asset.digest, digest.hasPrefix("sha256:"), asset.state == "uploaded",
                  asset.browserDownloadURL == ExtractorRelease.MasterSource.url(version: version)
            else { throw ExtractorPackageError.invalidMetadata }
            let source = ExtractorRelease.MasterSource(sha256: String(digest.dropFirst(7)), size: asset.size)
            guard source.isValid else { throw ExtractorPackageError.invalidMetadata }
            release.masterSource = source
        }
        return release
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
            let size: Int
            let state: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name, digest, size, state
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let publishedAt: Date
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case draft, prerelease, assets
        }
    }
}

extension UpdateStatus {
    mutating func invalidateCheck() {
        availableRelease = nil
        lastCheckedChannel = nil
        lastCheckedAt = nil
        state = .idle
        message = nil
    }

    /// Conservative snapshot projection; runtime startup replaces these labels
    /// with verified active-generation facts before presenting the workspace.
    var reconciledWithBundledRuntime: Self {
        var value = self
        let versionsChanged = bundledYTDLPVersion != DependencyVersions.ytDLP
            || activeYTDLPVersion != DependencyVersions.ytDLP
            || bundledEJSVersion != DependencyVersions.ejs
            || activeEJSVersion != DependencyVersions.ejs
            || activeChannel != nil
        value.bundledYTDLPVersion = DependencyVersions.ytDLP
        value.activeYTDLPVersion = DependencyVersions.ytDLP
        value.bundledEJSVersion = DependencyVersions.ejs
        value.activeEJSVersion = DependencyVersions.ejs
        value.activeChannel = nil
        if versionsChanged || [.checking, .installing, .testing, .installationDisabled].contains(state)
            || (state == .updateAvailable && availableRelease == nil) {
            value.invalidateCheck()
            value.lastSuccessfulUpdateAt = nil
        }
        return value
    }
}

enum UpdateError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidOffer
    case olderVersionNeedsConfirmation
    case releaseChanged

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The official release source returned an invalid response."
        case .invalidOffer: "Check the selected channel again before installing."
        case .olderVersionNeedsConfirmation: "Confirm the older version before switching channels."
        case .releaseChanged: "The latest release changed. Check for updates again."
        }
    }
}
