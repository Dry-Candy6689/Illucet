import Foundation

/// Imports only YouTube session cookies. The caller never copies the source file
/// into app storage and passes the validated values directly to AccountStore.
enum CookieFileImport {
    static let maximumBytes = 262_144
    static func parse(_ data: Data, now: Date = .now) throws -> [YouTubeAccountCookie] {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("# Netscape HTTP Cookie File") || text.hasPrefix("# HTTP Cookie File")
        else { throw AccountError.invalidSession }
        var cookies: [YouTubeAccountCookie] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if line.hasPrefix("#HttpOnly_") { line.removeFirst(10) }
            else if line.hasPrefix("#") || line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { throw AccountError.invalidSession }
            // Unrelated browser cookies never enter the account profile.
            guard YouTubeAccountCookie.domains.contains(fields[0]) else { continue }
            guard ["TRUE", "FALSE"].contains(fields[1]), ["TRUE", "FALSE"].contains(fields[3]),
                  let expiry = Int64(fields[4]), expiry >= 0 else { throw AccountError.invalidSession }
            cookies.append(YouTubeAccountCookie(domain: fields[0], path: fields[2],
                name: fields[5], value: fields[6], secure: fields[3] == "TRUE",
                expires: expiry == 0 ? nil : expiry))
        }
        return try YouTubeAccountCookie.validated(cookies, now: now)
    }
}
