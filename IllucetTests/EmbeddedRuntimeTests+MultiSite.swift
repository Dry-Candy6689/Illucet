import Foundation
import Testing
import WebKit
@testable import Illucet

extension EmbeddedRuntimeTests {
    @Test("Authorized external asset refresh", .enabled(if: ProcessInfo.processInfo.environment["ILLUCET_ASSET_REFRESH_LIVE"] == "1"))
    @MainActor func authorizedExternalAssetRefresh() async throws {
        let runtime = RuntimeEnvironment()
        do {
            let url = try #require(URL(string: "https://player.vimeo.com/video/98044508"))
            let post = try await runtime.externalPost(url: url, accountID: nil)
            let metadata = try #require(post.assets.first)
            var configuration = DownloadConfiguration.standard
            configuration.sourceIdentity = metadata.sourceIdentity
            configuration.assetFingerprint = metadata.assetFingerprint
            configuration.enginePreferences = .init()
            for _ in 0..<3 {
                let refreshed = try await runtime.externalMetadata(url: metadata.canonicalURL, configuration: configuration)
                #expect(refreshed.sourceIdentity == metadata.sourceIdentity)
            }
            print("ILLUCET_ASSET_REFRESH site=vimeo count=3 state=passed")
            await runtime.shutdown()
        } catch {
            for event in await runtime.recorder.allEvents where event.kind == "asset_failure" {
                if let data = try? JSONEncoder().encode(event.payload) { print("ILLUCET_ASSET_REFRESH_DETAIL " + String(decoding: data, as: UTF8.self)) }
            }
            await runtime.shutdown()
            throw error
        }
    }
    @Test @MainActor func redditBrowserGatesAndPostBindingStayExplicit() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        defer { browser.stopLoading() }
        let cases: [(String, String?)] = [
            ("<main>This is a private community</main>", "private_media"),
            ("<shreddit-post id='t3_abc123' nsfw></shreddit-post>", "age_restriction"),
            ("<shreddit-post id='t3_other'></shreddit-post>", nil)
        ]
        for (body, error) in cases {
            browser.loadHTMLString("<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\">" + body, baseURL: nil)
            for _ in 0..<50 where browser.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            let raw = try await browser.callAsyncJavaScript(RedditPageLoader.readPost,
                arguments: ["postID": "abc123", "hasAccount": false], in: nil, contentWorld: .page)
            let text = try #require(raw as? String)
            let result = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
            #expect(result["error"] == error)
            #expect(result["html"] == nil)
        }
    }

    @Test("Authorized Reddit guest connection probe",
          .enabled(if: ProcessInfo.processInfo.environment["ILLUCET_REDDIT_LIVE"] == "1"))
    func authorizedRedditGuestConnection() async throws {
        let post = "https://www.reddit.com/r/aww/comments/90bu6w/heat_index_was_110_degrees_so_we_offered_him_a/"
        for (kind, address) in [("webpage", post), ("json", post + ".json?raw_json=1")] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: try #require(URL(string: address)))
            request.setValue("ios:com.local.illucet:1.0.5 (Illucet)", forHTTPHeaderField: "User-Agent")
            let (stream, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in stream {
                guard data.count < 1_048_576 else { throw StreamResolutionError.invalidResponse }
                data.append(byte)
            }
            let status = try #require(response as? HTTPURLResponse).statusCode
            let text = String(decoding: data, as: UTF8.self).lowercased()
            let isJSON = (try? JSONSerialization.jsonObject(with: data)) is [Any]
            let blocked = text.contains("blocked by network security") || text.contains("whoa there")
            print("ILLUCET_REDDIT_NATIVE kind=\(kind) http=\(status) bytes=\(data.count) listing=\(isJSON) network_block=\(blocked)")
            #expect((200...599).contains(status))
        }
    }

    @Test("Authorized Reddit guest browser probe",
          .enabled(if: ProcessInfo.processInfo.environment["ILLUCET_REDDIT_LIVE"] == "1"))
    @MainActor func authorizedRedditGuestBrowser() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        defer { browser.stopLoading() }
        let address = ProcessInfo.processInfo.environment["ILLUCET_REDDIT_SAMPLE_URL"]
            ?? "https://www.reddit.com/r/Unexpected/comments/1cl9h0u/the_insurance_claim_will_be_interesting/"
        let post = try #require(URL(string: address))
        let postID = try #require(RedditPageLoader.postID(in: post))
        browser.load(URLRequest(url: post))
        try await Task.sleep(for: .seconds(10))
        let script = #"""
        JSON.stringify({
            ready: document.readyState,
            post: !!document.querySelector('shreddit-post[id="t3_1cl9h0u"]'),
            login: location.pathname.startsWith('/login'),
            blocked: /blocked by network security|whoa there|verify you are human/i.test(document.body.innerText),
            nativeVideo: !!document.querySelector('shreddit-player'),
            postAttributes: document.querySelector('shreddit-post[id="t3_1cl9h0u"]')?.getAttributeNames(),
            playerAttributes: document.querySelector('shreddit-post[id="t3_1cl9h0u"] shreddit-player')?.getAttributeNames(),
            playerData: (() => {
                const player = document.querySelector('shreddit-post[id="t3_1cl9h0u"] shreddit-player');
                const shape = value => Array.isArray(value) ? value.slice(0, 2).map(shape) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([k,v]) => [k,shape(v)])) : typeof value;
                return Object.fromEntries((player?.getAttributeNames() ?? []).filter(k => k.includes('json')).map(k => {
                    try { return [k,shape(JSON.parse(player.getAttribute(k)))]; } catch { return [k,'unparsed']; }
                }));
            })(),
            postBytes: document.querySelector('shreddit-post[id="t3_1cl9h0u"]')?.outerHTML.length,
            imageLayout: (() => {
                const post = document.getElementById('t3_1cl9h0u');
                const host = value => { try { return new URL(value,location.href).hostname; } catch { return ''; } };
                return { type:post?.getAttribute('post-type'), contentHost:host(post?.getAttribute('content-href')),
                    elements:[...(post?.querySelectorAll('*') ?? [])].filter(x => /image|img|gallery|carousel/.test(x.localName)).slice(0,25).map(x => ({tag:x.localName,attributes:x.getAttributeNames(),srcHost:host(x.getAttribute('src')),hrefHost:host(x.getAttribute('href'))})),
                    links:[...(post?.querySelectorAll('a[href]') ?? [])].map(x => ({host:host(x.href),media:new URL(x.href).pathname==='/media'})) };
            })(),
            bytes: document.documentElement.outerHTML.length
        })
        """#.replacingOccurrences(of: "1cl9h0u", with: postID)
        let summary = try await browser.evaluateJavaScript(script)
        print("ILLUCET_REDDIT_WEBKIT \(try #require(summary as? String))")
        let listing = try await browser.callAsyncJavaScript(#"""
        const controller = new AbortController();
        const deadline = setTimeout(() => controller.abort(), 15000);
        try {
            const response = await fetch('/comments/1cl9h0u/.json?raw_json=1', { signal: controller.signal });
            const value = await response.json().catch(() => null);
            return JSON.stringify({ http: response.status, listing: Array.isArray(value),
                post: value?.[0]?.data?.children?.[0]?.data?.id === '1cl9h0u' });
        } finally { clearTimeout(deadline); }
        """#, arguments: [:], in: nil, contentWorld: .page)
        print("ILLUCET_REDDIT_WEBKIT_JSON \(try #require(listing as? String))")
    }

    @Test func legacyDownloadCanPrepareGuestExtractionWithRemovedAccount() async throws {
        let runtime = RuntimeEnvironment()
        let unavailableID = UUID()
        do {
            let extractor = try await runtime.configuredExtractor(accountID: unavailableID, preferences: nil)
            #expect(!(try await extractor.versions()).ytDLP.isEmpty)
            _ = try await runtime.configuredResolver(accountID: unavailableID, preferences: nil)
            _ = try await runtime.configuredDASHResolver(accountID: unavailableID, preferences: nil)
            _ = try await runtime.configuredHLSResolver(accountID: unavailableID, preferences: nil)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    @Test func webKitChallengeBridgeReturnsBoundedRedactedOutput() async throws {
        let resources=try #require(Bundle.main.resourceURL)
        let directory=FileManager.default.temporaryDirectory.appending(path:"WebKitProof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let engine=try PythonEngine(pythonHome:resources.appending(path:"python"),bundledApp:resources.appending(path:"PythonApp"),bundledPackages:resources.appending(path:"PythonPackages"),writablePackages:directory,recorder:PythonEventRecorder())
        try await engine.start()
        do {
            let response=try await engine.execute(requestID:PythonRequestIDAllocator.next(),requestJSON:#"{"action":"webkit_proof"}"#)
            let value=try JSONSerialization.jsonObject(with:Data(response.utf8)) as? [String:Any]
            let data=try #require(value?["data"] as? [String:Any])
            #expect(data["answer"] as? Int == 42)
            #expect(data["redacted"] as? Bool == true)
            #expect(data["bounded"] as? Bool == true)
            #expect(data["timed_out"] as? Bool == true)
            #expect(data["recovered"] as? Bool == true)
            try await engine.shutdown()
        } catch { try? await engine.shutdown(); throw error }
    }
}
