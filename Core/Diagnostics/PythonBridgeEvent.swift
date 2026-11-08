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

    func record(requestID: UInt64, data: Data) {
        guard let raw = try? JSONDecoder().decode(
            RawPythonBridgeEvent.self,
            from: data
        ) else {
            return
        }

        lock.lock()
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
