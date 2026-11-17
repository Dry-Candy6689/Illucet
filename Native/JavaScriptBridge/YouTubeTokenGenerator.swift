import Foundation
import WebKit
import UIKit
import CryptoKit

/// Ephemeral challenge data. Never add this to app settings, job snapshots or diagnostics.
struct YouTubeProofRequest: Decodable, Sendable {
    let client: String
    let context: String
    let videoID: String
    let binding: String
    let sessionBinding: String

    var isValid: Bool {
        ["WEB", "MWEB", "WEB_EMBEDDED_PLAYER", "WEB_CREATOR", "WEB_REMIX"].contains(client)
            && ["gvs", "player", "subs"].contains(context)
            && videoID.utf8.count == 11 && !binding.isEmpty && binding.utf8.count <= 4096
            && sessionBinding.utf8.count <= 4096
    }
    func key(scope: UUID?) -> String {
        let components = [scope?.uuidString ?? "guest", client, context, videoID, binding, sessionBinding]
        return SHA256.hash(data: (try? JSONEncoder().encode(components)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

struct YouTubeProofToken: Decodable, Sendable {
    let token: String
    let expires: TimeInterval
    let setupMilliseconds: Int
    let mintMilliseconds: Int
    var isValid: Bool {
        (40...4096).contains(token.utf8.count) && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 61].contains($0)
        } && expires > Date.now.timeIntervalSince1970 + 30
    }
}

enum YouTubeTokenError: LocalizedError, Sendable {
    case unavailable, needsForeground, invalidRequest
    var errorDescription: String? {
        switch self {
        case .unavailable: "Local YouTube token generation did not complete. Try again later or choose another available client."
        case .needsForeground: "Open Illucet to generate the YouTube token needed for this item. Other downloads can continue."
        case .invalidRequest: "The extractor requested an unsupported YouTube token."
        }
    }
}

actor YouTubeTokenBroker {
    static let shared = YouTubeTokenBroker()
    private struct CacheKey: Hashable {
        let scope: UUID?
        let digest: String
    }
    private var cached: [CacheKey: YouTubeProofToken] = [:]
    private var pending: [CacheKey: Task<YouTubeProofToken, Error>] = [:]
    private var revokedAccounts: Set<UUID> = []
    private var tail: Task<Void, Never>?

    func token(for request: YouTubeProofRequest, scope: UUID?) async throws -> YouTubeProofToken {
        guard request.isValid else { throw YouTubeTokenError.invalidRequest }
        if let scope, revokedAccounts.contains(scope) { throw AccountError.unavailable }
        let key = CacheKey(scope: scope, digest: request.key(scope: scope))
        if let token = cached[key], token.isValid { return token }
        if let task = pending[key] {
            let token = try await task.value
            if let scope, revokedAccounts.contains(scope) { throw AccountError.unavailable }
            try Task.checkCancellation()
            return token
        }
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await YouTubeTokenGenerator.shared.generate(request, scope: scope)
        }
        pending[key] = task
        tail = Task { _ = try? await task.value }
        defer { pending.removeValue(forKey: key) }
        let token = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        if let scope, revokedAccounts.contains(scope) { throw AccountError.unavailable }
        guard token.isValid else { throw YouTubeTokenError.unavailable }
        cached = cached.filter { $0.value.isValid }
        if cached.count >= 128 { cached.removeAll() }
        cached[key] = token
        return token
    }

    func invalidateAccount(_ id: UUID) async {
        // No durable token cache and no token may survive profile removal.
        revokedAccounts.insert(id)
        for (key, task) in pending where key.scope == id { task.cancel() }
        pending = pending.filter { $0.key.scope != id }
        cached = cached.filter { $0.key.scope != id }
        await YouTubeTokenGenerator.shared.reset(account: id)
    }
}

@MainActor
final class YouTubeTokenGenerator: NSObject, WKNavigationDelegate {
    static let shared = YouTubeTokenGenerator()
    private var webView: WKWebView?
    private var owner: UUID?
    private var loaded = false
    private var continuation: CheckedContinuation<YouTubeProofToken, Error>?
    private var timeout: Task<Void, Never>?
    private var binding: String?
    private var operationID: UUID?

    func generate(_ request: YouTubeProofRequest, scope: UUID?) async throws -> YouTubeProofToken {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw YouTubeTokenError.needsForeground }
        guard continuation == nil else { throw YouTubeTokenError.unavailable }
        if webView != nil && owner != scope { reset() }
        owner = scope
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.addUserScript(WKUserScript(
                source: "globalThis.console={log:()=>{},debug:()=>{},info:()=>{},warn:()=>{},error:()=>{}};",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            webView = view
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                operationID = id
                binding = request.binding
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(40))
                    guard !Task.isCancelled, self?.operationID == id else { return }
                    self?.finish(.failure(YouTubeTokenError.unavailable), discard: true)
                }
                if loaded { mint() }
                else {
                    // The browser executes only the bundled adapter and the
                    // service's attestation script. No signed-in data store.
                    let html = """
                    <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; connect-src https://www.youtube.com https://www.google.com https://www.gstatic.com https://jnn-pa.googleapis.com">
                    """
                    webView?.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.finish(.failure(CancellationError()), discard: true)
            }
        }
    }

    func reset() {
        finish(.failure(CancellationError()), discard: true)
    }
    func reset(account: UUID) {
        if owner == account { reset() }
    }

    private func mint() {
        guard let view = webView, let binding, let id = operationID,
              let resource = Bundle.main.url(forResource: "illucet-token", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8), script.utf8.count <= 64 * 1024 else {
            finish(.failure(YouTubeTokenError.unavailable), discard: true); return
        }
        let source = "if (typeof globalThis.illucetMintToken !== 'function') {\n\(script)\n}\nreturn await globalThis.illucetMintToken(binding);"
        view.callAsyncJavaScript(source,
            arguments: ["binding": binding], in: nil, in: .page) { [weak self] result in
                guard let self, self.operationID == id else { return }
                switch result {
                case let .success(value):
                    guard let value = value as? String, value.utf8.count <= 8192,
                          let token = try? JSONDecoder().decode(YouTubeProofToken.self, from: Data(value.utf8)), token.isValid else {
                        #if DEBUG
                        if let value = value as? String,
                           let failure = (try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String])?["failure"],
                           ["setup", "challenge", "interpreter", "attestation", "integrity", "minter", "mint"].contains(failure) {
                            NSLog("ILLUCET_TOKEN_FAILURE stage=%@", failure)
                        }
                        #endif
                        self.finish(.failure(YouTubeTokenError.unavailable), discard: true); return
                    }
                    self.finish(.success(token), discard: false)
                case let .failure(error):
                    #if DEBUG
                    NSLog("ILLUCET_TOKEN_FAILURE script_error=%d", (error as NSError).code)
                    #endif
                    self.finish(.failure(YouTubeTokenError.unavailable), discard: true)
                }
            }
    }

    private func finish(_ result: Result<YouTubeProofToken, Error>, discard: Bool) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil; binding = nil; operationID = nil
        if discard { webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil; loaded = false }
        pending?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        loaded = true
        if continuation != nil { mint() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(YouTubeTokenError.unavailable), discard: true)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(YouTubeTokenError.unavailable), discard: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(YouTubeTokenError.unavailable), discard: true)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let allowed = ["www.youtube.com", "youtube.com", "consent.youtube.com"]
        if url?.absoluteString == "about:blank" { return .allow }
        return url?.scheme == "https" && allowed.contains(url?.host?.lowercased() ?? "") ? .allow : .cancel
    }
}
