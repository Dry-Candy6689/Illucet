import Foundation

struct ExternalMediaPost: Decodable, Sendable { let assets: [MediaMetadata] }

/// Ephemeral transport only. Intentionally does not conform to Encodable.
struct ExternalResolvedAsset: Decodable, Sendable {
    var requiresPython: Bool? = nil
    var expectedSHA256: String? = nil
    let identity: MediaSourceIdentity
    let formatID: String
    let url: URL
    let headers: [String: String]
    let fileExtension: String?
    let protocolName: String
    let hasVideo: Bool
    let hasAudio: Bool
    let expectedBytes: Int64?
    var stream: ResolvedStream {
        .init(formatID: formatID, URL: url, HTTPHeaders: headers,
              fileExtension: fileExtension, protocolName: protocolName,
              sourceType: "direct_http", hasVideo: hasVideo, hasAudio: hasAudio,
              expectedBytes: expectedBytes)
    }
    func validate(identity expected: MediaSourceIdentity, formatID: String) throws {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let allowedHeaders: Set<String> = ["user-agent", "referer", "origin", "accept", "accept-language", "sec-fetch-mode"]
        guard identity == expected, expected.isValid, self.formatID == formatID,
              ["http", "https"].contains(c?.scheme ?? ""), c?.user == nil, c?.password == nil,
              c?.host != nil, url.absoluteString.utf8.count <= 16_384,
              headers.count <= 10, headers.allSatisfy({ allowedHeaders.contains($0.key.lowercased()) && $0.value.utf8.count <= 4096 && !$0.value.contains("\r") && !$0.value.contains("\n") }),
              expectedBytes.map({ $0 > 0 }) ?? true else { throw StreamResolutionError.invalidResponse }
    }
}

protocol ExternalMediaProviding: Sendable {
    func externalPost(url: URL, accountID: UUID?, preferences: EnginePreferences) async throws -> ExternalMediaPost
    func externalMetadata(url: URL, configuration: DownloadConfiguration) async throws -> MediaMetadata
    func externalSource(url: URL, configuration: DownloadConfiguration, formatID: String) async throws -> ExternalResolvedAsset
    func downloadExternal(url: URL, configuration: DownloadConfiguration, formatID: String,
                          jobID: UUID, directory: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
}

extension ExternalMediaProviding {
    func externalPost(url: URL, accountID: UUID?, preferences: EnginePreferences) async throws -> ExternalMediaPost { throw ExtractionError.unsupportedSite }
    func externalMetadata(url: URL, configuration: DownloadConfiguration) async throws -> MediaMetadata { throw ExtractionError.unsupportedSite }
    func externalSource(url: URL, configuration: DownloadConfiguration, formatID: String) async throws -> ExternalResolvedAsset { throw ExtractionError.unsupportedSite }
    func downloadExternal(url: URL, configuration: DownloadConfiguration, formatID: String, jobID: UUID, directory: URL,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL { throw ExtractionError.unsupportedSite }
}

private struct ExternalEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let action: String
    let data: Value?
    let error: Failure?
    struct Failure: Decodable { let code: String; let message: String; let retryable: Bool }
}

extension RuntimeEnvironment: ExternalMediaProviding {
    func verifyAccount(id: UUID, site: MediaSite) async throws {
        struct Verification: Decodable { let verified: Bool }
        var preferences = EnginePreferences(); preferences.accountAccess = .selectedAccount
        let result: Verification = try await externalRequest("validate_account_session", url: site.loginURL,
            accountID: id, configuration: nil, preferences: preferences)
        guard result.verified else { throw AccountError.invalidSession }
    }
    func externalPost(url: URL, accountID: UUID?, preferences: EnginePreferences = .init()) async throws -> ExternalMediaPost {
        let value: ExternalMediaPost = try await externalRequest("extract_post", url: url, accountID: accountID,
            configuration: nil, preferences: preferences)
        guard (1...500).contains(value.assets.count),
              Set(value.assets.compactMap(\.sourceIdentity)).count == value.assets.count else { throw ExtractionError.invalidResponse("Invalid post inventory.") }
        for metadata in value.assets { try validateExternalMetadata(metadata, url: url) }
        return value
    }
    func externalMetadata(url: URL, configuration: DownloadConfiguration) async throws -> MediaMetadata {
        let value: MediaMetadata = try await externalRequest("extract_asset", url: url, accountID: configuration.accountID, configuration: configuration)
        try validateExternalMetadata(value, url: url)
        guard value.sourceIdentity == configuration.sourceIdentity, value.assetFingerprint == configuration.assetFingerprint else {
            throw ExtractionError.invalidResponse("The selected asset changed.")
        }
        return value
    }
    func externalSource(url: URL, configuration: DownloadConfiguration, formatID: String) async throws -> ExternalResolvedAsset {
        guard let identity = configuration.sourceIdentity else { throw StreamResolutionError.invalidResponse }
        let value: ExternalResolvedAsset = try await externalRequest("resolve_asset", url: url, accountID: configuration.accountID,
            configuration: configuration, extra: ["format_id": formatID])
        try value.validate(identity: identity, formatID: formatID)
        if let digest = value.expectedSHA256 {
            guard digest == configuration.assetFingerprint else {
                throw ExtractionError.invalidResponse("The selected image changed. Review this post again.")
            }
        }
        return value
    }
    func downloadExternal(url: URL, configuration: DownloadConfiguration, formatID: String, jobID: UUID, directory: URL,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        struct Output: Decodable { let filename: String; let bytes: Int64 }
        let engine = try await startedPython()
        let token = recorder.observeAssetProgress(jobID: jobID, progress)
        defer { recorder.removeAssetObserver(token) }
        let output: Output = try await externalRequest("download_asset", url: url, accountID: configuration.accountID,
            configuration: configuration, extra: ["format_id": formatID, "job_id":jobID.uuidString, "directory":directory.path])
        _ = engine
        guard output.filename == URL(fileURLWithPath: output.filename).lastPathComponent,
              !output.filename.contains("/"), output.bytes > 0 else { throw StreamResolutionError.invalidResponse }
        let file = directory.appending(path: output.filename)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == Int(output.bytes),
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw StreamResolutionError.invalidResponse }
        return file
    }
    private func externalRequest<Value: Decodable>(_ action: String, url: URL, accountID: UUID?, configuration: DownloadConfiguration?,
        preferences: EnginePreferences = .init(), extra: [String: Any] = [:]) async throws -> Value {
        guard let site = MediaSite.recognize(url) else { throw ExtractionError.unsupportedSite }
        let resolvedPreferences = configuration?.enginePreferences ?? preferences
        let access = resolvedPreferences.accountAccess ?? .automatic
        if access == .selectedAccount && accountID == nil {
            throw AccountError.invalidSession
        }
        var request: [String: Any] = ["action":action, "url":url.absoluteString,
            "youtube_client":resolvedPreferences.youtubeClient]
        request["engine_preferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolvedPreferences))
        if let identity = configuration?.sourceIdentity {
            guard identity.site == site, identity.isValid else { throw ExtractionError.invalidResponse("Invalid source identity.") }
            request["identity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        }
        if let fingerprint = configuration?.assetFingerprint { request["asset_fingerprint"] = fingerprint }
        request.merge(extra) { _, new in new }
        let engine = try await startedPython()
        let requestID = PythonRequestIDAllocator.next()
        let JSON = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response: String
        if let accountID {
            response = try await AccountAuthentication(id: accountID, store: accounts).execute(
                requestJSON: JSON, policy: access, site: site, cookieKey: "site_cookies") { value in
                    try await self.executeExternal(engine: engine, requestID: requestID, requestJSON: value)
                }
        } else { response = try await executeExternal(engine: engine, requestID: requestID, requestJSON: JSON) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["ILLUCET_MULTISITE_LIVE"] == "1" {
            for event in recorder.events(for:requestID) where event.kind == "asset_failure" {
                if let data = try? JSONEncoder().encode(event.payload) { print("ILLUCET_MULTISITE_DETAIL " + String(decoding:data,as:UTF8.self)) }
            }
        }
        #endif
        guard response.utf8.count <= 8 * 1_024 * 1_024 else { throw ExtractionError.invalidResponse("Post inventory exceeded its limit.") }
        let envelope = try JSONDecoder().decode(ExternalEnvelope<Value>.self, from: Data(response.utf8))
        guard envelope.action == action else { throw ExtractionError.invalidResponse("Unexpected operation.") }
        guard envelope.ok, let data = envelope.data else {
            throw ExtractionError.extractorFailure(code: envelope.error?.code ?? "extraction_failed",
                message: envelope.error?.message ?? "This media could not be read.", retryable: envelope.error?.retryable ?? false)
        }
        return data
    }

    private func executeExternal(engine: PythonEngine, requestID: UInt64, requestJSON: String) async throws -> String {
        let response = try await engine.execute(requestID: requestID, requestJSON: requestJSON)
        struct BrowserRecovery: Decodable {
            struct Failure: Decodable { let code: String }
            let error: Failure?
        }
        guard let recovery = try? JSONDecoder().decode(BrowserRecovery.self, from: Data(response.utf8)),
              recovery.error?.code == "reddit_browser_required",
              var request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any],
              let address = request["url"] as? String, let url = URL(string: address),
              MediaSite.recognize(url) == .reddit else { return try await finalizeImageFingerprints(response) }
        let cookieData = try JSONSerialization.data(withJSONObject: request["site_cookies"] ?? [])
        let cookies = try JSONDecoder().decode([YouTubeAccountCookie].self, from: cookieData)
        request["reddit_page"] = try await RedditPageLoader().load(url: url, cookies: cookies)
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: request)
        guard data.count <= 512 * 1024 else { throw ExtractionError.invalidResponse("This Reddit post exceeds the supported size.") }
        return try await finalizeImageFingerprints(engine.execute(requestID: requestID, requestJSON: String(decoding: data, as: UTF8.self)))
    }

    private func finalizeImageFingerprints(_ response: String) async throws -> String {
        guard var envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              envelope["ok"] as? Bool == true, var data = envelope["data"] as? [String: Any] else { return response }
        var byteBudget = 64 * 1024 * 1024
        if var assets = data["assets"] as? [[String: Any]] {
            guard assets.filter({ $0["_image_content_source"] != nil }).count <= 50 else {
                throw ExtractionError.invalidResponse("This slideshow exceeds the supported photo limit.")
            }
            for index in assets.indices {
                if let address = assets[index].removeValue(forKey: "_image_content_source") as? String {
                    let result = try await NativeImageProcessor.contentFingerprint(address, maximumBytes: min(byteBudget, 8 * 1024 * 1024))
                    byteBudget -= result.bytes
                    assets[index]["asset_fingerprint"] = result.digest
                }
            }
            data["assets"] = assets
        } else if let address = data.removeValue(forKey: "_image_content_source") as? String {
            data["asset_fingerprint"] = try await NativeImageProcessor.contentFingerprint(address, maximumBytes: 8 * 1024 * 1024).digest
        } else if data.removeValue(forKey: "needsContentFingerprint") as? Bool == true,
                  let address = data["url"] as? String {
            data["expectedSHA256"] = try await NativeImageProcessor.contentFingerprint(address, maximumBytes: 8 * 1024 * 1024).digest
        }
        envelope["data"] = data
        return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }
    private func validateExternalMetadata(_ metadata: MediaMetadata, url: URL) throws {
        guard let identity = metadata.sourceIdentity, identity.isValid,
              identity.site == MediaSite.recognize(url), MediaSite.recognize(metadata.canonicalURL) == identity.site,
              metadata.videoID == identity.assetID, !metadata.title.isEmpty, metadata.title.utf8.count <= 512,
              metadata.formats.count <= 2000, metadata.thumbnails.isEmpty,
              identity.kind == .image || (!metadata.formats.isEmpty && Set(metadata.formats.map(\.formatID)).count == metadata.formats.count),
              metadata.assetFingerprint.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else {
            throw ExtractionError.invalidResponse("Invalid source metadata.")
        }
    }
}
