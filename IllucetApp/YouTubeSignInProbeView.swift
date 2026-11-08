import SwiftUI
import WebKit

/// App-owned temporary browser. Saving a profile requires an explicit UI action.
@MainActor
final class YouTubeSignInSession: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var webView: WKWebView
    @Published var location = "Not opened"
    @Published var status = "Sign in, then test extraction."
    @Published var testing = false
    @Published var testURL = "https://www.youtube.com/watch?v=YE7VzlLtp-4"

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func open() {
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!))
    }

    #if DEBUG
    func test(using runtime: RuntimeEnvironment) async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        status = "Checking temporary session…"
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let records = cookies.compactMap { cookie -> YouTubeSessionProbeCookie? in
            guard ["youtube.com", ".youtube.com", "www.youtube.com", "m.youtube.com"].contains(cookie.domain),
                  cookie.path == "/" else { return nil }
            var expires: Int64?
            if let date = cookie.expiresDate {
                let seconds = date.timeIntervalSince1970
                guard seconds.isFinite, seconds > Date().timeIntervalSince1970,
                      seconds <= 253_402_300_799 else { return nil }
                expires = Int64(seconds)
            }
            return YouTubeSessionProbeCookie(domain: cookie.domain, path: cookie.path,
                name: cookie.name, value: cookie.value, secure: cookie.isSecure, expires: expires)
        }
        guard !records.isEmpty else {
            status = "No YouTube session. Open YouTube and sign in first."
            return
        }
        do {
            let result = try await runtime.probeYouTubeSession(.init(url: testURL, cookies: records))
            guard result.sessionRecognized, result.metadataExtracted, result.formatCount > 0 else {
                status = "Session test FAIL: incomplete result."
                return
            }
            status = "PASS: yt-dlp recognized login cookies and extracted \(result.formatCount) formats. Account-only access is not verified."
        } catch {
            // Do not render arbitrary bridge errors: they may contain transport details.
            if case let ExtractionError.extractorFailure(code, _, _) = error {
                switch code {
                case "login_required": status = "No complete login session. Finish signing in on YouTube."
                case "invalid_session": status = "Session is invalid or expired. Clear and sign in again."
                default: status = "Session test FAIL: extraction did not complete."
                }
            } else {
                status = "Session test FAIL: runtime could not complete the check."
            }
        }
    }

    #endif

    func clear() async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        let previous = webView
        previous.stopLoading()
        previous.navigationDelegate = nil
        let store = previous.configuration.websiteDataStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        location = "Session cleared"
        status = "Session cleared. Sign in to test again."
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        location = webView.url?.host() ?? "Local page"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code != NSURLErrorCancelled && !testing { status = "Page could not load. Try Open YouTube again." }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.scheme == "https" || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

struct YouTubeSignInBrowser: UIViewRepresentable {
    let session: YouTubeSignInSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#if DEBUG
struct YouTubeSignInProbeView: View {
    let runtime: RuntimeEnvironment
    @StateObject private var session = YouTubeSignInSession()

    var body: some View {
        VStack(spacing: 8) {
            Text("YouTube sign-in test").font(.headline)
            Text("Temporary session • no saved profile").font(.caption)
            HStack {
                Button("Open YouTube") { session.open() }
                Button("Test extraction") { Task { await session.test(using: runtime) } }
                Button("Clear") { Task { await session.clear() } }
            }.buttonStyle(.bordered).disabled(session.testing)
            TextField("Authorized video URL", text: $session.testURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sessionProbe.url").disabled(session.testing)
            Text(session.location).font(.caption).accessibilityIdentifier("sessionProbe.location")
            Text(session.status).font(.caption).accessibilityIdentifier("sessionProbe.status")
            YouTubeSignInBrowser(session: session).id(ObjectIdentifier(session.webView))
                .allowsHitTesting(!session.testing)
        }.padding(.horizontal, 8).padding(.top)
    }
}
#endif
