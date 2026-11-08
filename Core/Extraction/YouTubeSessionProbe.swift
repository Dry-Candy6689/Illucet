#if DEBUG
import Foundation

struct YouTubeSessionProbeCookie: Encodable, Sendable {
    let domain: String
    let path: String
    let name: String
    let value: String
    let secure: Bool
    let expires: Int64?

    enum CodingKeys: String, CodingKey { case domain, path, name, value, secure, expires }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(path, forKey: .path)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(secure, forKey: .secure)
        if let expires { try container.encode(expires, forKey: .expires) }
        else { try container.encodeNil(forKey: .expires) }
    }
}

struct YouTubeSessionProbeRequest: Encodable, Sendable {
    let action = "probe_youtube_session"
    let download = false
    let url: String
    let cookies: [YouTubeSessionProbeCookie]
}

struct YouTubeSessionProbeResult: Decodable, Sendable {
    let sessionRecognized: Bool
    let metadataExtracted: Bool
    let formatCount: Int
}

struct YouTubeSessionProbeEnvelope: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    let ok: Bool
    let data: YouTubeSessionProbeResult?
    let error: Failure?
}
#endif
