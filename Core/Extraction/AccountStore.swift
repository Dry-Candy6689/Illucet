import Foundation

enum AccountError: LocalizedError, Equatable, Sendable {
    case unavailable, expired, invalidSession, invalidName, storageUnavailable, limitReached
    var errorDescription: String? {
        switch self {
        case .unavailable: "This download's account was removed. Sign in and create a new download."
        case .expired: "This account session expired. Sign in again and create a new download."
        case .invalidSession: "Finish signing in to this website before saving the account."
        case .invalidName: "Choose a nonempty, unique label for this account."
        case .storageUnavailable: "Secure account storage is unavailable. Unlock this device and try again."
        case .limitReached: "Remove an account for this website before adding another. Up to 10 accounts per website can be saved."
        }
    }
}

struct AccountProfile: Identifiable, Equatable, Sendable {
    var site: MediaSite = .youtube
    var verified: Bool = false
    let id: UUID
    let name: String
    let expired: Bool
}

struct YouTubeAccountCookie: Codable, Equatable, Sendable {
    let domain: String
    let path: String
    let name: String
    let value: String
    let secure: Bool
    let expires: Int64?

    enum CodingKeys: String, CodingKey { case domain, path, name, value, secure, expires }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(domain, forKey: .domain); try c.encode(path, forKey: .path)
        try c.encode(name, forKey: .name); try c.encode(value, forKey: .value)
        try c.encode(secure, forKey: .secure)
        if let expires { try c.encode(expires, forKey: .expires) }
        else { try c.encodeNil(forKey: .expires) }
    }

    static let domains = ["youtube.com", ".youtube.com", "www.youtube.com", "m.youtube.com"]

    static func snapshot(_ cookies: [HTTPCookie], now: Date = .now, site: MediaSite = .youtube) throws -> [Self] {
        let values = cookies.compactMap { cookie -> Self? in
            guard site == .youtube ? (domains.contains(cookie.domain) && cookie.path == "/") : site.owns(host: cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return nil }
            var expires: Int64?
            if let date = cookie.expiresDate {
                let seconds = date.timeIntervalSince1970
                guard seconds.isFinite, seconds > now.timeIntervalSince1970,
                      seconds <= 253_402_300_799 else { return nil }
                expires = Int64(seconds)
            }
            return Self(domain: cookie.domain, path: cookie.path, name: cookie.name,
                        value: cookie.value, secure: cookie.isSecure, expires: expires)
        }
        return try validated(values, now: now, site: site)
    }

    static func validated(_ cookies: [Self], now: Date = .now, site: MediaSite = .youtube) throws -> [Self] {
        guard (1...128).contains(cookies.count) else { throw AccountError.invalidSession }
        var identities = Set<String>()
        var total = 0
        for c in cookies {
            guard (site == .youtube ? (domains.contains(c.domain) && c.path == "/") : site.owns(host: c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))),
                  c.path.hasPrefix("/"), c.path.utf8.count <= 1024,
                  (1...128).contains(c.name.utf8.count),
                  c.name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  (1...16_384).contains(c.value.utf8.count),
                  c.value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 }),
                  identities.insert(c.domain + c.path + "/" + c.name).inserted,
                  c.expires == nil || (c.expires! > 0 && c.expires! <= 253_402_300_799)
            else { throw AccountError.invalidSession }
            total += c.value.utf8.count
        }
        guard total <= 131_072 else { throw AccountError.invalidSession }
        let current = cookies.filter { $0.expires == nil || Double($0.expires!) > now.timeIntervalSince1970 }
        if site != .youtube {
            guard !current.isEmpty else { throw AccountError.expired }
            return current
        }
        let names = Set(current.filter { $0.domain == ".youtube.com" || $0.domain == "www.youtube.com" }.map(\.name))
        guard names.contains("LOGIN_INFO"), !names.isDisjoint(with: ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"])
        else { throw AccountError.expired }
        return current
    }
}

protocol AccountSecureStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

actor AccountStore {
    private struct Record: Codable {
        var site: MediaSite? = nil
        var verified: Bool? = nil
        let id: UUID
        let name: String
        let cookies: [YouTubeAccountCookie]
        var invalidated = false
    }
    private let storage: any AccountSecureStorage
    init(storage: any AccountSecureStorage = KeychainAccountStorage()) { self.storage = storage }

    private func records() throws -> [Record] {
        do {
            guard let data = try storage.read() else { return [] }
            guard data.count <= 16_000_000 else { throw AccountError.storageUnavailable }
            let records = try JSONDecoder().decode([Record].self, from: data)
            guard records.count <= MediaSite.allCases.count * 10, Set(records.map(\.id)).count == records.count else { throw AccountError.storageUnavailable }
            return records
        } catch { throw AccountError.storageUnavailable }
    }
    private func save(_ records: [Record]) throws {
        do {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 16_000_000 else { throw AccountError.storageUnavailable }
            try storage.write(data)
        }
        catch { throw AccountError.storageUnavailable }
    }
    func profiles() throws -> [AccountProfile] {
        try records().map { record in
            AccountProfile(site: record.site ?? .youtube, verified: record.verified == true && !record.invalidated, id: record.id, name: record.name,
                expired: record.invalidated || (try? YouTubeAccountCookie.validated(record.cookies, site: record.site ?? .youtube)) == nil)
        }
    }
    func add(name: String, cookies: [YouTubeAccountCookie], site: MediaSite = .youtube) throws -> UUID {
        let cookies = try YouTubeAccountCookie.validated(cookies, site: site)
        var all = try records()
        guard all.filter({ ($0.site ?? .youtube) == site }).count < 10 else { throw AccountError.limitReached }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !all.contains(where: { ($0.site ?? .youtube) == site && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw AccountError.invalidName }
        let record = Record(site: site == .youtube ? nil : site, id: UUID(), name: name, cookies: cookies)
        all.append(record)
        try save(all)
        return record.id
    }
    func session(for id: UUID, site: MediaSite = .youtube) throws -> [YouTubeAccountCookie] {
        guard let record = try records().first(where: { $0.id == id }) else { throw AccountError.unavailable }
        guard (record.site ?? .youtube) == site else { throw AccountError.invalidSession }
        guard !record.invalidated else { throw AccountError.expired }
        return try YouTubeAccountCookie.validated(record.cookies, site: site)
    }
    func remove(_ id: UUID) throws {
        try save(records().filter { $0.id != id })
    }
    func expire(_ id: UUID) throws {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].invalidated = true
        try save(all)
    }
    func markVerified(_ id: UUID) throws {
        var all = try records()
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].invalidated else { throw AccountError.unavailable }
        guard all[index].verified != true else { return }
        all[index].verified = true
        try save(all)
    }
}

/// Bound to one immutable profile ID. Credentials are loaded only for an
/// authenticated request and checked again before its response is used.
struct AccountAuthentication: Sendable {
    let id: UUID
    let store: AccountStore
    func execute(requestJSON: String, policy: AccountAccessPolicy = .selectedAccount,
                 site: MediaSite = .youtube, cookieKey: String = "account_cookies",
                 send: @Sendable (String) async throws -> String) async throws -> String {
        if policy == .guestOnly { return try await send(requestJSON) }
        if policy == .automatic {
            let guestResponse = try await send(requestJSON)
            guard AccountAccessPolicy.permitsAccountRetry(guestResponse) else { return guestResponse }
            try Task.checkCancellation()
        }
        let cookies = try await store.session(for: id, site: site)
        guard var request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        else { throw AccountError.invalidSession }
        request[cookieKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cookies))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try await send(encoded)
        _ = try await store.session(for: id, site: site)
        if let envelope = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
           envelope["ok"] as? Bool == false,
           let error = envelope["error"] as? [String: Any],
           ["session_expired", "invalid_session"].contains(error["code"] as? String ?? "") {
            try await store.expire(id)
            await YouTubeTokenBroker.shared.invalidateAccount(id)
            throw AccountError.expired
        }
        let action = request["action"] as? String
        let confirmsSession = action == "validate_account_session"
            || (site == .youtube && ["extract_metadata", "extract_playlist"].contains(action ?? ""))
            || (policy == .automatic && ["extract_post", "extract_asset"].contains(action ?? ""))
        if confirmsSession,
           let envelope = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
           envelope["ok"] as? Bool == true { try await store.markVerified(id) }
        return response
    }
}

extension PythonEngine {
    func executeAuthenticated(requestID: UInt64, requestJSON: String,
                              authentication: AccountAuthentication?, preferences: EnginePreferences? = nil) async throws -> String {
        var configuredJSON = requestJSON
        if let preferences, var object = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] {
            object["engine_preferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences))
            #if DEBUG
            // The opt-in transport proof asks for a token even on a public
            // sample that offers token-free formats.
            if ProcessInfo.processInfo.environment["ILLUCET_LOCAL_TOKEN_DOWNLOAD_LIVE"] == "1" {
                object["verify_local_proof"] = true
            }
            #endif
            configuredJSON = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let enablesProof = preferences.map { ($0.poTokens ?? .automatic) == .automatic } ?? false
        guard let authentication else {
            if preferences?.accountAccess == .selectedAccount { throw AccountError.unavailable }
            return try await executeWithProofRecovery(requestID: requestID, requestJSON: configuredJSON, scope: nil, enabled: enablesProof)
        }
        let access = preferences?.accountAccess ?? (preferences == nil ? .selectedAccount : .automatic)
        return try await authentication.execute(requestJSON: configuredJSON, policy: access) { request in
            let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
            let scope = object?["account_cookies"] == nil ? nil : authentication.id
            return try await self.executeWithProofRecovery(requestID: requestID, requestJSON: request, scope: scope, enabled: enablesProof)
        }
    }

    private func executeWithProofRecovery(requestID: UInt64, requestJSON: String, scope: UUID?, enabled: Bool) async throws -> String {
        var response = try await execute(requestID: requestID, requestJSON: requestJSON)
        guard enabled else { return response }
        struct ProofEnvelope: Decodable {
            struct Failure: Decodable { let code: String }
            let error: Failure?
            let proof_request: YouTubeProofRequest?
        }
        var issued = Set<String>()
        var records: [[String: Any]] = []
        for _ in 0..<3 {
            guard let envelope = try? JSONDecoder().decode(ProofEnvelope.self, from: Data(response.utf8)),
                  envelope.error?.code == "proof_token_required", let challenge = envelope.proof_request,
                  issued.insert(challenge.key(scope: scope)).inserted else { break }
            try Task.checkCancellation()
            let proof = try await YouTubeTokenBroker.shared.token(for: challenge, scope: scope)
            records.append(["client":challenge.client, "context":challenge.context, "videoID":challenge.videoID,
                            "binding":challenge.binding, "sessionBinding":challenge.sessionBinding,
                            "token":proof.token, "expires":proof.expires])
            guard var object = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] else { break }
            object["proof_tokens"] = records
            let next = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            response = try await execute(requestID: requestID, requestJSON: next)
        }
        return response
    }
}
