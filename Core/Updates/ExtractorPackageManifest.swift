import Foundation

struct ExtractorRelease: Codable, Equatable, Sendable {
    struct MasterSource: Codable, Equatable, Sendable {
        static let filename = "yt-dlp.tar.gz"
        let sha256: String
        let size: Int

        static func url(version: String) -> URL? {
            guard (try? ExtractorPackageCatalog.distributionVersion(release: version, channel: .master)) != nil
            else { return nil }
            return URL(string: "https://github.com/yt-dlp/yt-dlp-master-builds/releases/download/\(version)/\(filename)")
        }

        var isValid: Bool {
            size > 0 && size <= ExtractorPackageTransport.maximumArtifactBytes
                && ExtractorPackageManifest.matches(sha256, "[a-f0-9]{64}")
        }
    }

    let channel: UpdateChannel
    let version: String
    let publishedAt: Date
    var masterSource: MasterSource? = nil

    func isOlder(than status: UpdateStatus) -> Bool {
        version.compare(status.activeYTDLPVersion, options: .numeric) == .orderedAscending
    }

    func isInstallable(over status: UpdateStatus) -> Bool {
        channel != status.runningChannel
            || version.compare(status.activeYTDLPVersion, options: .numeric) == .orderedDescending
    }
}

struct ExtractorInstalledVersions: Codable, Equatable, Sendable {
    let ytDLP: String
    let ejs: String
    let certifi: String
}

struct ExtractorPackageRecord: Codable, Equatable, Sendable {
    let package: String
    let version: String
    let sha256: String
}

struct ExtractorPackageManifest: Codable, Equatable, Sendable {
    let generation: String
    let channel: UpdateChannel
    let versions: ExtractorInstalledVersions
    let installedAt: Date
    let packages: [ExtractorPackageRecord]
    let fileHashes: [String: String]

    func validate() throws {
        guard UUID(uuidString: generation)?.uuidString == generation,
              Self.matches(versions.ytDLP, #"[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?"#),
              Set(packages.map(\.package)) == ["yt-dlp", "yt-dlp-ejs", "certifi"],
              packages.count == 3,
              !fileHashes.isEmpty,
              fileHashes.allSatisfy({ !$0.key.isEmpty
                  && !$0.key.hasPrefix("/") && !$0.key.contains("\\")
                  && $0.key.split(separator: "/", omittingEmptySubsequences: false)
                      .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
                  && Self.matches($0.value, "[a-f0-9]{64}") }),
              packages.allSatisfy({ Self.matches($0.sha256, "[a-f0-9]{64}")
                  && Self.matches($0.version, #"[0-9]+(?:\.[0-9]+)*(?:\.dev[0-9]+)?"#) }),
              packages.first(where: { $0.package == "yt-dlp-ejs" })?.version == versions.ejs,
              packages.first(where: { $0.package == "certifi" })?.version == versions.certifi
        else { throw ExtractorPackageError.invalidManifest }
        let channelVersion = try ExtractorPackageCatalog.distributionVersion(
            release: versions.ytDLP, channel: channel
        )
        guard packages.first(where: { $0.package == "yt-dlp" })?.version == channelVersion
        else { throw ExtractorPackageError.invalidManifest }
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard value.utf8.count <= 256,
              let range = value.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression)
        else { return false }
        return range == value.startIndex..<value.endIndex
    }
}

struct ExtractorPackageArchive: Sendable {
    enum Format: String, Sendable {
        case wheel, masterSource
    }

    let package: String
    let version: String
    let sha256: String
    let fileURL: URL
    var format: Format = .wheel
}

struct ExtractorMasterRequirements: Decodable, Sendable {
    let requiresPython: String
    let requirements: [String]
}

enum ExtractorPackageError: Error, LocalizedError, Sendable {
    case invalidMetadata, invalidManifest, invalidArchive, invalidResponse
    case sizeLimit, checksumMismatch, unsafePath, invalidState, incompatiblePackage

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "The official package metadata was not accepted."
        case .invalidManifest: "The installed package manifest was not accepted."
        case .invalidArchive: "The package archive was not accepted."
        case .invalidResponse: "The official package source returned an invalid response."
        case .sizeLimit: "The package exceeded the permitted size."
        case .checksumMismatch: "The package did not match its official SHA-256 checksum."
        case .unsafePath: "The update storage path was not accepted."
        case .invalidState: "The update state could not be safely changed."
        case .incompatiblePackage: "The package is incompatible with this app's extractor contract."
        }
    }
}
