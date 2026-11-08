import Foundation

/// Contains only a public webpage URL; never a media transport URL or credentials.
struct SharedLink: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let createdAt: Date
    var presentedAt: Date? = nil
    var isShortcutRequest: Bool? = nil
    var resumeOnForeground: Bool? = nil
    var foregroundMessage: String? = nil
}

enum SharedLinkParser {
    static func webpageURL(in text: String) -> URL? {
        guard text.utf8.count <= 16_384 else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let candidates = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return candidates.compactMap(canonicalURL).first
    }
    static func canonicalURL(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 4096, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.user == nil, c.password == nil,
              c.port == nil || c.port == 80 || c.port == 443, let host = c.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        let items = c.queryItems ?? []
        func safe(_ text: String, length: ClosedRange<Int>) -> Bool {
            length.contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }
        let list = items.first { $0.name == "list" }?.value
        let video = host.hasSuffix("youtu.be") ? parts.first : c.path == "/watch" ? items.first { $0.name == "v" }?.value : parts.count == 2 && ["shorts", "live", "embed", "v"].contains(parts[0]) ? parts[1] : nil
        if let video, safe(video, length: 11...11) {
            var result = URLComponents(string: "https://www.youtube.com/watch")!
            result.queryItems = [URLQueryItem(name: "v", value: video)]
            if let list, safe(list, length: 2...128) { result.queryItems?.append(URLQueryItem(name: "list", value: list)) }
            return result.url
        }
        if let list, safe(list, length: 2...128), c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "playlist" {
            return URL(string: "https://www.youtube.com/playlist?list=" + list)
        }
        let baseCount = parts.first?.hasPrefix("@") == true ? 1 : 2
        if list == nil, let first = parts.first, first.hasPrefix("@") || ["channel", "c", "user"].contains(first),
           parts.count == baseCount || parts.count == baseCount + 1,
           parts.prefix(baseCount).allSatisfy({ $0.utf8.count <= 128 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95,64,46].contains($0) } }) {
            let tab = parts.count > baseCount ? parts[baseCount] : "videos"
            guard ["videos", "shorts", "streams"].contains(tab) else { return nil }
            return URL(string: "https://www.youtube.com/" + parts.prefix(baseCount).joined(separator: "/") + "/" + tab)
        }
        return nil
    }
}

struct SharedLinkInbox: Sendable {
    let directory: URL
    static func live() throws -> Self {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "IllucetSharedGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return Self(directory: root.appendingPathComponent("LinkInbox", isDirectory: true))
    }
    func save(_ url: URL) throws {
        _ = try save(url, shortcut: false)
    }
    @discardableResult
    func save(_ url: URL, shortcut: Bool) throws -> SharedLink {
        guard let safe = SharedLinkParser.canonicalURL(url) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, try pending().count < 50 else { throw CocoaError(.fileWriteNoPermission) }
        let link = SharedLink(id: UUID(), url: safe, createdAt: .now, isShortcutRequest: shortcut ? true : nil)
        try JSONEncoder().encode(link).write(to: directory.appendingPathComponent(link.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return link
    }
    func pending() throws -> [SharedLink] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        return files.filter { $0.pathExtension == "json" }.prefix(100).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return nil }
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8192 else { return nil }
            guard let data = try? Data(contentsOf: url), let link = try? JSONDecoder().decode(SharedLink.self, from: data) else { return nil }
            guard url.deletingPathExtension().lastPathComponent == link.id.uuidString,
                  SharedLinkParser.canonicalURL(link.url) == link.url else { return nil }
            return link
        }.sorted { $0.createdAt < $1.createdAt }
    }
    func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    func deferUntilForeground(_ id: UUID, automatic: Bool, message: String) throws {
        guard var link = try pending().first(where: { $0.id == id }) else { return }
        link.resumeOnForeground = automatic
        link.foregroundMessage = String(message.prefix(256))
        link.presentedAt = nil
        try JSONEncoder().encode(link).write(to: directory.appendingPathComponent(id.uuidString + ".json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Keep the URL recoverable, but offer it automatically only once, including
    /// across process launches. Older inbox records decode with no presentation.
    func markPresented(_ id: UUID) throws {
        guard var link = try pending().first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        link.presentedAt = .now
        try JSONEncoder().encode(link).write(
            to: directory.appendingPathComponent(id.uuidString + ".json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
