import Foundation

/// Resolves only the official universal wheels for the extractor and its pinned dependencies.
/// Master supplies the extractor itself as a separately verified release archive.
struct ExtractorPackageCatalog: Sendable {
    struct Artifact: Sendable {
        let package: String
        let version: String
        let filename: String
        let url: URL
        let sha256: String
        let size: Int
    }

    struct Metadata: Decodable {
        struct Info: Decodable {
            let name: String
            let version: String
            let requiresDist: [String]?
            let requiresPython: String?
            let yanked: Bool?
            enum CodingKeys: String, CodingKey {
                case name, version, yanked
                case requiresDist = "requires_dist", requiresPython = "requires_python"
            }
        }
        struct File: Decodable {
            let filename: String
            let url: URL
            let digests: [String: String]
            let size: Int
            let packagetype: String
            let yanked: Bool
        }
        let info: Info
        let urls: [File]
    }

    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    let fetch: Fetch

    init(fetch: @escaping Fetch = ExtractorPackageTransport.fetch) { self.fetch = fetch }

    func resolve(release: String, channel: UpdateChannel) async throws -> [Artifact] {
        guard channel != .master else { throw ExtractorPackageError.invalidMetadata }
        let version = try Self.distributionVersion(release: release, channel: channel)
        let yt = try await metadata(package: "yt-dlp", version: version)
        let dependencies = try await resolveDependencies(requirements: yt.info.requiresDist ?? [])
        return [try Self.artifact(yt, package: "yt-dlp", version: version)] + dependencies
    }

    func resolveDependencies(requirements: [String]) async throws -> [Artifact] {
        let ejsVersion = try Self.pinnedDependency("yt-dlp-ejs", in: requirements)
        let certifiVersion = try Self.pinnedDependency("certifi", in: requirements)
        // Pins published by yt-dlp provide the reviewed dependency combination;
        // never silently substitute a newer EJS or certificate distribution.
        let ejs = try await metadata(package: "yt-dlp-ejs", version: ejsVersion)
        let certifi = try await metadata(package: "certifi", version: certifiVersion)
        return try [Self.artifact(ejs, package: "yt-dlp-ejs", version: ejsVersion),
                    Self.artifact(certifi, package: "certifi", version: certifiVersion)]
    }

    private func metadata(package: String, version: String) async throws -> Metadata {
        let url = URL(string: "https://pypi.org/pypi/\(package)/\(version)/json")!
        let data = try await fetch(url, 1_048_576)
        guard data.count <= 1_048_576 else { throw ExtractorPackageError.sizeLimit }
        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    static func distributionVersion(release: String, channel: UpdateChannel) throws -> String {
        let pattern = channel == .stable
            ? #"[0-9]{4}\.[0-9]{2}\.[0-9]{2}"#
            : #"[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{1,12}"#
        guard ExtractorPackageManifest.matches(release, pattern) else {
            throw ExtractorPackageError.invalidMetadata
        }
        let parts = release.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count == (channel == .stable ? 3 : 4),
              (1...12).contains(parts[1]), (1...31).contains(parts[2])
        else { throw ExtractorPackageError.invalidMetadata }
        if channel == .master { return release }
        return parts.map(String.init).joined(separator: ".")
            + (channel == .nightly ? ".dev0" : "")
    }

    static func pinnedDependency(_ name: String, in requirements: [String]) throws -> String {
        guard requirements.count <= 500, requirements.allSatisfy({ $0.utf8.count <= 2_048 })
        else { throw ExtractorPackageError.invalidMetadata }
        var versions = Set<String>()
        for requirement in requirements {
            let specifier = requirement.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard specifier.hasPrefix(name + "==") else { continue }
            let version = String(specifier.dropFirst(name.count + 2))
            guard ExtractorPackageManifest.matches(version, #"[0-9]+(?:\.[0-9]+)*"#)
            else { throw ExtractorPackageError.invalidMetadata }
            let parts = version.split(separator: ".").compactMap { UInt64($0) }
            guard parts.count == version.split(separator: ".").count
            else { throw ExtractorPackageError.invalidMetadata }
            versions.insert(parts.map(String.init).joined(separator: "."))
        }
        guard versions.count == 1, let version = versions.first
        else { throw ExtractorPackageError.incompatiblePackage }
        return version
    }

    static func supportsPython(_ requirement: String) -> Bool {
        guard ExtractorPackageManifest.matches(requirement, #">=3\.[0-9]{1,2}"#),
              let minimum = Int(requirement.dropFirst(4)),
              let embedded = DependencyVersions.python.split(separator: ".").dropFirst().first.flatMap({ Int($0) })
        else { return false }
        return minimum <= embedded
    }

    static func artifact(_ metadata: Metadata, package: String, version: String) throws -> Artifact {
        guard ["yt-dlp", "yt-dlp-ejs", "certifi"].contains(package),
              ExtractorPackageManifest.matches(version, #"[0-9]+(?:\.[0-9]+)*(?:\.dev[0-9]+)?"#),
              metadata.info.name.replacingOccurrences(of: "_", with: "-") == package,
              metadata.info.version == version, metadata.info.yanked != true,
              let python = metadata.info.requiresPython,
              supportsPython(python)
        else { throw ExtractorPackageError.incompatiblePackage }
        let filename = package.replacingOccurrences(of: "-", with: "_")
            + "-\(version)-py3-none-any.whl"
        let candidates = metadata.urls.filter { $0.filename == filename }
        guard candidates.count == 1, let wheel = candidates.first,
              wheel.packagetype == "bdist_wheel", !wheel.yanked,
              wheel.size > 0, wheel.size <= ExtractorPackageTransport.maximumArtifactBytes,
              let digest = wheel.digests["sha256"],
              ExtractorPackageManifest.matches(digest, "[a-f0-9]{64}"),
              ExtractorPackageTransport.allowed(wheel.url),
              wheel.url.host == "files.pythonhosted.org",
              wheel.url.lastPathComponent == filename
        else { throw ExtractorPackageError.invalidMetadata }
        return Artifact(package: package, version: version, filename: filename,
                        url: wheel.url, sha256: digest, size: wheel.size)
    }
}

private final class PackageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let initialURL: URL

    init(initialURL: URL) { self.initialURL = initialURL }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // GitHub's exact release download redirects once to its release asset CDN.
        // All other metadata and package URLs are used without redirects.
        guard response.url == initialURL, ExtractorPackageTransport.isMasterArchive(initialURL),
              let url = request.url, ExtractorPackageTransport.isGitHubReleaseAsset(url)
        else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum ExtractorPackageTransport {
    static let maximumArtifactBytes = 32 * 1_024 * 1_024

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              !url.absoluteString.contains("%"), !url.path.contains("\\"),
              !url.path.split(separator: "/").contains("..")
        else { return false }
        if url.host == "files.pythonhosted.org" {
            return url.path.hasPrefix("/packages/") && url.path.hasSuffix(".whl")
        }
        if url.host == "pypi.org" {
            return ExtractorPackageManifest.matches(url.path,
                #"/pypi/(?:yt-dlp|yt-dlp-ejs|certifi)/[0-9]+(?:\.[0-9]+)*(?:\.dev[0-9]+)?/json"#)
        }
        if url.host == "api.github.com" {
            return UpdateChannel.allCases.contains {
                url.path == "/repos/yt-dlp/\($0.releaseRepository)/releases/latest"
            }
        }
        return isMasterArchive(url)
    }

    static func isMasterArchive(_ url: URL) -> Bool {
        url.host == "github.com" && ExtractorPackageManifest.matches(url.path,
            #"/yt-dlp/yt-dlp-master-builds/releases/download/[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{1,12}/yt-dlp\.tar\.gz"#)
    }

    static func isGitHubReleaseAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "release-assets.githubusercontent.com"
            && url.port == nil && url.user == nil && url.password == nil && url.fragment == nil
            && url.path.hasPrefix("/github-production-release-asset/")
    }

    static func fetch(_ url: URL, maximum: Int) async throws -> Data {
        guard allowed(url), maximum > 0, maximum <= maximumArtifactBytes
        else { throw ExtractorPackageError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: PackageRedirects(initialURL: url), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Illucet/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url,
              http.statusCode == 200,
              finalURL == url || (isMasterArchive(url) && isGitHubReleaseAsset(finalURL)),
              response.expectedContentLength <= Int64(maximum)
        else { throw ExtractorPackageError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw ExtractorPackageError.sizeLimit }
            data.append(byte)
        }
        return data
    }
}
