import Foundation

/// Webpage recognition is shared by manual entry, clipboard, imports and intents.
/// This recognizes an input route; extraction still establishes media identity.
enum MediaSite: String, Codable, CaseIterable, Identifiable, Sendable {
    case youtube, tiktok, instagram, x, reddit, facebook, bluesky
    case vimeo, dailymotion, twitch, soundcloud, pinterest
    var id: String { rawValue }
    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .x: "X"
        case .reddit: "Reddit"
        case .facebook: "Facebook"
        case .bluesky: "Bluesky"
        case .vimeo: "Vimeo"
        case .dailymotion: "Dailymotion"
        case .twitch: "Twitch"
        case .soundcloud: "SoundCloud"
        case .pinterest: "Pinterest"
        }
    }
    var domains: [String] {
        switch self {
        case .youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .tiktok: ["tiktok.com"]
        case .instagram: ["instagram.com"]
        case .x: ["x.com", "twitter.com", "t.co"]
        case .reddit: ["reddit.com", "redd.it"]
        case .facebook: ["facebook.com", "fb.watch", "fb.com"]
        case .bluesky: ["bsky.app"]
        case .vimeo: ["vimeo.com"]
        case .dailymotion: ["dailymotion.com", "dai.ly"]
        case .twitch: ["twitch.tv"]
        case .soundcloud: ["soundcloud.com", "snd.sc"]
        case .pinterest: ["pinterest.com", "pin.it"]
        }
    }
    var loginURL: URL { URL(string: "https://\(domains[0])/")! }
    static let accountSites: [Self] = [.youtube, .instagram, .tiktok, .facebook, .x, .reddit, .twitch, .vimeo, .soundcloud, .dailymotion]
    func owns(host: String) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func recognize(_ url: URL) -> Self? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.user == nil, c.password == nil, c.port == nil || [80,443].contains(c.port!),
              url.absoluteString.utf8.count <= 4_096, let host = c.host?.lowercased(),
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return allCases.first { $0.owns(host: host) }
    }
    static func canonicalWebpage(_ url: URL) -> URL? {
        guard let site = recognize(url),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"; c.host = c.host?.lowercased(); c.port = nil; c.fragment = nil
        // Keep only webpage identity parameters, never transport/authentication data.
        let identityParameters: Set<String> = switch site {
        case .youtube: ["v", "list"]
        case .facebook: ["v", "story_fbid", "id", "fbid", "video_id"]
        case .dailymotion: ["video"]
        default: []
        }
        c.queryItems = c.queryItems?.filter { item in
            identityParameters.contains(item.name) && item.value.map {
                (1...128).contains($0.utf8.count) && $0.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }
            } == true
        }
        if site == .soundcloud && c.path.split(separator:"/").count > 2 { return nil }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url
    }
}

enum SourceMediaKind: String, Codable, Sendable { case video, audio, image }

struct MediaSourceIdentity: Codable, Equatable, Hashable, Sendable {
    let site: MediaSite
    let postID: String
    let assetID: String
    let kind: SourceMediaKind
    var archiveID: String { "\(site.rawValue):\(postID):\(kind.rawValue):\(assetID)" }
    var isValid: Bool {
        [postID, assetID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
}

enum DownloadEngineChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, native, ytDLP, aria2
    var id: String { rawValue }
    var label: String { switch self { case .automatic: "Automatic"; case .native: "Native"; case .ytDLP: "yt-dlp"; case .aria2: "aria2" } }
}

enum JavaScriptSolverChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, quickJS, webKit
    var id: String { rawValue }
    var label: String { switch self { case .automatic: "Automatic"; case .quickJS: "QuickJS"; case .webKit: "Apple WebKit" } }
}

enum AccountAccessPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, guestOnly, selectedAccount
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic — guest first"
        case .guestOnly: "Guest only"
        case .selectedAccount: "Use preferred account"
        }
    }
    /// Only explicit access requirements authorize Automatic to use credentials.
    /// Bot challenges, HTTP failures and rate limits are deliberately excluded.
    static func permitsAccountRetry(_ response: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              object["ok"] as? Bool == false,
              let error = object["error"] as? [String: Any], let code = error["code"] as? String else { return false }
        return ["private_media", "login_required", "age_restriction", "membership_required"].contains(code)
    }
}

enum YouTubeTokenMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, automatic
    var id: String { rawValue }
    var label: String { self == .automatic ? "Automatic when needed" : "Off" }
}

struct EnginePreferences: Codable, Equatable, Sendable {
    // Missing in old job snapshots: preserve their existing explicit binding.
    var accountAccess: AccountAccessPolicy? = .automatic
    var poTokens: YouTubeTokenMode? = .automatic
    var download: DownloadEngineChoice = .automatic
    var javaScript: JavaScriptSolverChoice = .automatic
    var youtubeClient: String = "default"
    var removeImageMetadata = false
}

struct SiteDownloadDefaults: Codable, Equatable, Sendable {
    var accountAccess: AccountAccessPolicy? = nil
    var engine: DownloadEngineChoice? = nil
    var accountID: UUID?
    var preset: String = "best"
}
