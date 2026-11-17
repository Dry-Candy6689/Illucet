import Foundation
import UIKit
import WebKit

enum RedditPageError: Error, LocalizedError {
    case needsForeground
    var errorDescription: String? { "Open Illucet to read this Reddit post. Other downloads can continue." }
}

/// Loads Reddit's ordinary post page. The returned fragment and cookies stay in memory.
@MainActor
final class RedditPageLoader: NSObject, WKNavigationDelegate {
    private var browser: WKWebView?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var polling: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var evaluating = false

    static func postID(in url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { $0 == "comments" || $0 == "gallery" }),
              parts.indices.contains(index + 1) else { return nil }
        let id = parts[index + 1].lowercased()
        return id.range(of: "^[a-z0-9]{3,16}$", options: .regularExpression) != nil ? id : nil
    }

    func load(url: URL, cookies: [YouTubeAccountCookie]) async throws -> [String: String] {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState != .background else { throw RedditPageError.needsForeground }
        guard MediaSite.recognize(url) == .reddit else { throw ExtractionError.unsupportedSite }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        browser.navigationDelegate = self
        if !cookies.isEmpty {
            for value in try YouTubeAccountCookie.validated(cookies, site: .reddit) {
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: value.domain, .path: value.path, .name: value.name,
                    .value: value.value, .secure: value.secure ? "TRUE" : "FALSE"
                ]
                if let expires = value.expires { properties[.expires] = Date(timeIntervalSince1970: Double(expires)) }
                guard let cookie = HTTPCookie(properties: properties) else { throw AccountError.invalidSession }
                await browser.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
        try Task.checkCancellation()
        self.browser = browser
        let expectedID = Self.postID(in: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                browser.load(URLRequest(url: url, timeoutInterval: 20))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finish(.success(["error": "service_challenge"]))
                }
                polling = Task { [weak self] in
                    while let self, self.continuation != nil {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        if UIApplication.shared.applicationState == .background {
                            self.finish(.failure(RedditPageError.needsForeground))
                            return
                        }
                        self.read(expectedID: expectedID, hasAccount: !cookies.isEmpty)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func read(expectedID: String?, hasAccount: Bool) {
        guard !evaluating, let browser, let current = browser.url,
              MediaSite.recognize(current) == .reddit else { return }
        evaluating = true
        let id = expectedID ?? Self.postID(in: current) ?? ""
        browser.callAsyncJavaScript(Self.readPost, arguments: ["postID": id, "hasAccount": hasAccount],
            in: nil, in: .page) { [weak self] reply in
            guard let self, self.continuation != nil else { return }
            self.evaluating = false
            guard case let .success(value) = reply, let text = value as? String, text.utf8.count <= 425_000,
                  let result = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return }
            if result["html"] != nil || result["error"] != nil { self.finish(.success(result)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        polling?.cancel(); polling = nil
        browser?.stopLoading()
        browser?.navigationDelegate = nil
        browser = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        guard let url = action.request.url, url.scheme == "https", MediaSite.recognize(url) == .reddit else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    static let readPost = #"""
    if (document.readyState === 'loading') return '{}';
    const post = postID && document.getElementById('t3_' + postID);
    const gate = post?.querySelector('shreddit-content-gate') ?? (!post && document.querySelector('shreddit-content-gate'));
    if (gate || post?.hasAttribute('nsfw')) {
        const text = gate?.innerText ?? '';
        if (/private community|invited to visit/i.test(text)) return JSON.stringify({error:'private_media'});
        if (gate || !hasAccount) return JSON.stringify({error:'age_restriction'});
    }
    if (post?.tagName === 'SHREDDIT-POST') {
        const html = post.outerHTML;
        return JSON.stringify(new TextEncoder().encode(html).length <= 200000 ? {html} : {error:'invalid_response'});
    }
    const text = document.body?.innerText ?? '';
    if (/this is a private community|you must be invited to visit this community/i.test(text))
        return JSON.stringify({error:'private_media'});
    if (/you must be 18|mature content.*log in/i.test(text))
        return JSON.stringify({error:'age_restriction'});
    if (/blocked by network security|whoa there|verify you are human/i.test(text))
        return JSON.stringify({error:'service_challenge'});
    if (location.pathname.startsWith('/login')) return JSON.stringify({error:'login_required'});
    return '{}';
    """#
}
