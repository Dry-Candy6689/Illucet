import Foundation

enum AccountError: LocalizedError, Equatable, Sendable {
    case unavailable, expired, invalidSession, invalidName, storageUnavailable, limitReached
    var errorDescription: String? {
        switch self {
        case .unavailable: "This download's account was removed. Sign in and create a new download."
        case .expired: "This account session expired. Sign in again and create a new download."
        case .invalidSession: "Finish signing in to YouTube before saving the account."
        case .invalidName: "Choose a nonempty, unique label for this account."
        case .storageUnavailable: "Secure account storage is unavailable. Unlock this device and try again."
        case .limitReached: "Remove an account before adding another. Up to 10 accounts can be saved."
        }
    }
}

struct AccountProfile: Identifiable, Equatable, Sendable {
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

    static func snapshot(_ cookies: [HTTPCookie], now: Date = .now) throws -> [Self] {
        let values = cookies.compactMap { cookie -> Self? in
            guard domains.contains(cookie.domain), cookie.path == "/" else { return nil }
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
        return try validated(values, now: now)
    }

    static func validated(_ cookies: [Self], now: Date = .now) throws -> [Self] {
        guard (1...128).contains(cookies.count) else { throw AccountError.invalidSession }
        var identities = Set<String>()
        var total = 0
        for c in cookies {
            guard domains.contains(c.domain), c.path == "/",
                  (1...128).contains(c.name.utf8.count),
                  c.name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  (1...16_384).contains(c.value.utf8.count),
                  c.value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 }),
                  identities.insert(c.domain + "/" + c.name).inserted,
                  c.expires == nil || (c.expires! > 0 && c.expires! <= 253_402_300_799)
            else { throw AccountError.invalidSession }
            total += c.value.utf8.count
        }
        guard total <= 131_072 else { throw AccountError.invalidSession }
        let current = cookies.filter { $0.expires == nil || Double($0.expires!) > now.timeIntervalSince1970 }
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
            guard data.count <= 2_000_000 else { throw AccountError.storageUnavailable }
            let records = try JSONDecoder().decode([Record].self, from: data)
            guard records.count <= 10, Set(records.map(\.id)).count == records.count else { throw AccountError.storageUnavailable }
            return records
        } catch { throw AccountError.storageUnavailable }
    }
    private func save(_ records: [Record]) throws {
        do {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 2_000_000 else { throw AccountError.storageUnavailable }
            try storage.write(data)
        }
        catch { throw AccountError.storageUnavailable }
    }
    func profiles() throws -> [AccountProfile] {
        try records().map { record in
            AccountProfile(id: record.id, name: record.name,
                expired: record.invalidated || (try? YouTubeAccountCookie.validated(record.cookies)) == nil)
        }
    }
    func add(name: String, cookies: [YouTubeAccountCookie]) throws -> UUID {
        let cookies = try YouTubeAccountCookie.validated(cookies)
        var all = try records()
        guard all.count < 10 else { throw AccountError.limitReached }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !all.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw AccountError.invalidName }
        let record = Record(id: UUID(), name: name, cookies: cookies)
        all.append(record)
        try save(all)
        return record.id
    }
    func session(for id: UUID) throws -> [YouTubeAccountCookie] {
        guard let record = try records().first(where: { $0.id == id }) else { throw AccountError.unavailable }
        guard !record.invalidated else { throw AccountError.expired }
        return try YouTubeAccountCookie.validated(record.cookies)
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
}

/// Bound to one immutable profile ID. Credentials are loaded for every request,
/// and removal during an in-flight request prevents its response being used.
struct AccountAuthentication: Sendable {
    let id: UUID
    let store: AccountStore
    func execute(requestJSON: String, send: @Sendable (String) async throws -> String) async throws -> String {
        let cookies = try await store.session(for: id)
        guard var request = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        else { throw AccountError.invalidSession }
        request["account_cookies"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cookies))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try await send(encoded)
        _ = try await store.session(for: id)
        if let envelope = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
           envelope["ok"] as? Bool == false,
           let error = envelope["error"] as? [String: Any],
           ["session_expired", "invalid_session"].contains(error["code"] as? String ?? "") {
            try await store.expire(id)
            throw AccountError.expired
        }
        return response
    }
}

extension PythonEngine {
    func executeAuthenticated(requestID: UInt64, requestJSON: String,
                              authentication: AccountAuthentication?) async throws -> String {
        guard let authentication else { return try await execute(requestID: requestID, requestJSON: requestJSON) }
        return try await authentication.execute(requestJSON: requestJSON) { request in
            try await self.execute(requestID: requestID, requestJSON: request)
        }
    }
}
