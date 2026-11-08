import Foundation

enum ProofStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case blocked = "BLOCKED"
    case notRun = "NOT RUN"

    fileprivate var inspectionPriority: Int {
        switch self {
        case .fail: 0
        case .blocked: 1
        case .notRun: 2
        case .pass: 3
        }
    }
}
struct Stage0Check: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: ProofStatus
    let evidence: String
}

struct Stage0ProofReport: Codable, Sendable {
    let generatedAt: Date
    let target: String
    let checks: [Stage0Check]
    let events: [PythonBridgeEvent]

    var passedCount: Int {
        checks.count { $0.status == .pass }
    }

    var failedCount: Int {
        checks.count { $0.status == .fail }
    }

    var blockedCount: Int {
        checks.count { $0.status == .blocked }
    }

    var notRunCount: Int {
        checks.count { $0.status == .notRun }
    }

    var checksForInspection: [Stage0Check] {
        checks.enumerated().sorted { left, right in
            let leftPriority = left.element.status.inspectionPriority
            let rightPriority = right.element.status.inspectionPriority
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}

struct BridgeEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let action: String
    let data: Value
}

struct BasicPythonProof: Decodable, Sendable {
    let addition: Int
    let bundleOrigin: String
    let certifiVersion: String
    let ejsVersion: String
    let isMainThread: Bool
    let platform: String
    let platformDetail: String
    let pythonVersion: String
    let sslVersion: String
    let writableOrigin: String
    let ytDLPVersion: String

    enum CodingKeys: String, CodingKey {
        case addition
        case bundleOrigin = "bundle_origin"
        case certifiVersion = "certifi_version"
        case ejsVersion = "ejs_version"
        case isMainThread = "is_main_thread"
        case platform
        case platformDetail = "platform_detail"
        case pythonVersion = "python_version"
        case sslVersion = "ssl_version"
        case writableOrigin = "writable_origin"
        case ytDLPVersion = "yt_dlp_version"
    }
}

struct DelayPythonProof: Decodable, Sendable {
    let finished: Double
    let isMainThread: Bool
    let started: Double

    enum CodingKeys: String, CodingKey {
        case finished
        case isMainThread = "is_main_thread"
        case started
    }
}

struct QuickJSProof: Decodable, Sendable {
    let answer: Int
    let coreSHA256: String
    let ejsVersion: String
    let elapsed: Double
    let emptyResponseCount: Int
    let emptyResultType: String
    let failClosedCases: [String: Bool]
    let failClosedDirector: Bool
    let libSHA256: String
    let providerAvailable: Bool
    let providerKey: String
    let providerRegistered: Bool
    let quickjsVersion: String
    let sensitiveDirectorLogFound: Bool
    let thrownTextRedacted: Bool
    let unicode: String
    let ytdlpVersion: String

    enum CodingKeys: String, CodingKey {
        case answer
        case coreSHA256 = "core_sha256"
        case ejsVersion = "ejs_version"
        case elapsed
        case emptyResponseCount = "empty_response_count"
        case emptyResultType = "empty_result_type"
        case failClosedCases = "fail_closed_cases"
        case failClosedDirector = "fail_closed_director"
        case libSHA256 = "lib_sha256"
        case providerAvailable = "provider_available"
        case providerKey = "provider_key"
        case providerRegistered = "provider_registered"
        case quickjsVersion = "quickjs_version"
        case sensitiveDirectorLogFound = "sensitive_director_log_found"
        case thrownTextRedacted = "thrown_text_redacted"
        case unicode
        case ytdlpVersion = "ytdlp_version"
    }
}

struct QuickJSTimeoutProof: Decodable, Sendable {
    let elapsed: Double
    let errorType: String
    let providerErrorType: String

    enum CodingKeys: String, CodingKey {
        case elapsed
        case errorType = "error_type"
        case providerErrorType = "provider_error_type"
    }
}
