import Foundation
import Testing
@testable import Illucet

private final class MemoryAccountStorage: AccountSecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failWrites = false
    init(data: Data? = nil) { self.data = data }
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if failWrites { throw AccountError.storageUnavailable }
            self.data = data
        }
    }
}

@Suite("Secure account sessions")
struct AccountStoreTests {
    private func cookies(_ value: String = "synthetic-session", expires: Int64? = nil) -> [YouTubeAccountCookie] {
        ["LOGIN_INFO", "SAPISID"].map {
            YouTubeAccountCookie(domain: ".youtube.com", path: "/", name: $0,
                value: value, secure: true, expires: expires)
        }
    }

    @Test func persistenceIsolationAndRemoval() async throws {
        let storage = MemoryAccountStorage()
        let store = AccountStore(storage: storage)
        let first = try await store.add(name: "First", cookies: cookies("first"))
        let second = try await store.add(name: "Second", cookies: cookies("second"))
        let reopened = AccountStore(storage: storage)
        #expect(try await reopened.session(for: first).first?.value == "first")
        #expect(try await reopened.session(for: second).first?.value == "second")
        try await reopened.remove(first)
        await #expect(throws: AccountError.unavailable) { try await store.session(for: first) }
        #expect(try await store.session(for: second).first?.value == "second")
    }

    @Test func expirationRequiresNewSession() async throws {
        let store = AccountStore(storage: MemoryAccountStorage())
        let id = try await store.add(name: "Account", cookies: cookies())
        try await store.expire(id)
        #expect(try await store.profiles().first?.expired == true)
        await #expect(throws: AccountError.expired) { try await store.session(for: id) }
        #expect(throws: AccountError.expired) { try YouTubeAccountCookie.validated(cookies(expires: 1)) }
    }

    @Test func corruptAndFailedStorageNeverBecomesAnonymous() async throws {
        let storage = MemoryAccountStorage(data: Data("corrupt".utf8))
        let store = AccountStore(storage: storage)
        await #expect(throws: AccountError.storageUnavailable) { try await store.profiles() }
        await #expect(throws: AccountError.storageUnavailable) { try await store.add(name: "New", cookies: cookies()) }
        #expect(try storage.read() == Data("corrupt".utf8))
        let failing = MemoryAccountStorage()
        failing.failWrites = true
        await #expect(throws: AccountError.storageUnavailable) {
            try await AccountStore(storage: failing).add(name: "New", cookies: cookies())
        }
    }

    @Test func removedDuringRequestDiscardsResponse() async throws {
        let store = AccountStore(storage: MemoryAccountStorage())
        let id = try await store.add(name: "First", cookies: cookies())
        let auth = AccountAuthentication(id: id, store: store)
        await #expect(throws: AccountError.unavailable) {
            try await auth.execute(requestJSON: #"{"action":"extract_metadata"}"#) { _ in
                try await store.remove(id)
                return #"{"ok":true}"#
            }
        }
    }

    @Test func bindsOnlySelectedAccountAndMapsExpiration() async throws {
        let store = AccountStore(storage: MemoryAccountStorage())
        let id = try await store.add(name: "First", cookies: cookies("first"))
        _ = try await store.add(name: "Second", cookies: cookies("second"))
        let auth = AccountAuthentication(id: id, store: store)
        await #expect(throws: AccountError.expired) {
            try await auth.execute(requestJSON: #"{"action":"resolve_streams"}"#) { request in
                #expect(request.contains("first"))
                #expect(!request.contains("second"))
                return #"{"ok":false,"error":{"code":"session_expired"}}"#
            }
        }
        #expect(try await store.profiles().first?.expired == true)
    }

    @Test func missingAccountNeverCallsTransport() async throws {
        let auth = AccountAuthentication(id: UUID(), store: AccountStore(storage: MemoryAccountStorage()))
        await #expect(throws: AccountError.unavailable) {
            try await auth.execute(requestJSON: "{}") { _ in
                Issue.record("Missing account reached the network")
                return "{}"
            }
        }
    }

    @Test func restrictedContentDoesNotInvalidateValidSession() async throws {
        let store = AccountStore(storage: MemoryAccountStorage())
        let id = try await store.add(name: "Account", cookies: cookies())
        let auth = AccountAuthentication(id: id, store: store)
        let result = try await auth.execute(requestJSON: "{}") { _ in
            #"{"ok":false,"error":{"code":"login_required"}}"#
        }
        #expect(result.contains("login_required"))
        #expect(try await store.profiles().first?.expired == false)
    }

    @Test func legacyConfigurationAndOpaqueJobBinding() throws {
        var config = DownloadConfiguration.standard
        let legacy = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DownloadConfiguration.self, from: legacy).accountID == nil)
        let id = UUID()
        config.accountID = id
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DownloadConfiguration.self, from: data).accountID == id)
        #expect(!String(decoding: data, as: UTF8.self).contains("cookie"))
    }

    @Test func browserSnapshotExcludesOtherSites() throws {
        let google = try #require(HTTPCookie(properties: [.domain: ".google.com", .path: "/", .name: "SID", .value: "google-only"]))
        let youtube = cookies().map { HTTPCookie(properties: [.domain: $0.domain, .path: $0.path, .name: $0.name, .value: $0.value, .secure: "TRUE"])! }
        let selected = try YouTubeAccountCookie.snapshot(youtube + [google])
        #expect(selected.count == 2)
        #expect(!selected.contains { $0.value == "google-only" })
        #expect(throws: AccountError.invalidSession) { try YouTubeAccountCookie.validated(cookies() + cookies()) }
    }

    @Test func realKeychainRoundTrip() async throws {
        let storage = KeychainAccountStorage(service: "com.local.illucet.tests." + UUID().uuidString)
        let store = AccountStore(storage: storage)
        let id = try await store.add(name: "Synthetic test", cookies: cookies())
        let reopened = AccountStore(storage: storage)
        #expect(try await reopened.session(for: id) == cookies())
        try await reopened.remove(id)
        #expect(try await store.profiles().isEmpty)
    }
}
