import Foundation

struct PythonBridgeEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let requestID: UInt64
    let kind: String
    let payload: [String: JSONValue]

    init(
        id: UUID = UUID(),
        requestID: UInt64,
        kind: String,
        payload: [String: JSONValue]
    ) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.payload = payload
    }
}
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct RawPythonBridgeEvent: Decodable {
    let kind: String
    let payload: [String: JSONValue]
}

final class PythonEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [PythonBridgeEvent] = []
    private var assetObservers: [UUID: (UUID, @Sendable (Int64, Int64?) -> Void)] = [:]

    func observeAssetProgress(jobID: UUID, _ callback: @escaping @Sendable (Int64, Int64?) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { assetObservers[token] = (jobID, callback) }
        return token
    }
    func removeAssetObserver(_ token: UUID) { _ = lock.withLock { assetObservers.removeValue(forKey: token) } }

    func record(requestID: UInt64, data: Data) {
        guard let raw = try? JSONDecoder().decode(
            RawPythonBridgeEvent.self,
            from: data
        ) else {
            return
        }

        if raw.kind == "asset_progress",
           case let .string(jobID) = raw.payload["job_id"],
           case let .number(bytes) = raw.payload["bytes"], bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) {
            let total: Int64?
            if case let .number(value) = raw.payload["total"], value.isFinite, value > 0, value < Double(Int64.max) { total = Int64(value) }
            else { total = nil }
            let callbacks = lock.withLock { assetObservers.values.filter { $0.0.uuidString == jobID }.map { $0.1 } }
            for callback in callbacks { callback(Int64(bytes), total) }
            return
        }
        lock.lock()
        if storedEvents.count >= 4096 { storedEvents.removeFirst(1024) }
        storedEvents.append(
            PythonBridgeEvent(
                requestID: requestID,
                kind: raw.kind,
                payload: raw.payload
            )
        )
        lock.unlock()
    }

    func events(for requestID: UInt64) -> [PythonBridgeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents.filter { $0.requestID == requestID }
    }

    var allEvents: [PythonBridgeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}
