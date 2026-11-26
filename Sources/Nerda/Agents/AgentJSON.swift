import Foundation

/// A JSON value, as agents send and get them: the wire between the shim and
/// the app (`AgentWire`), MCP's JSON-RPC (`AgentMCP`) and a verb's
/// arguments and tool schema (`AgentVerb`). Sendable, so it crosses from the
/// socket's threads to the main thread and back.
nonisolated enum AgentJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSON])
    case object([String: AgentJSON])

    subscript(key: String) -> AgentJSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? { number.flatMap { Int(exactly: $0) } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [AgentJSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: AgentJSON]? { if case .object(let value) = self { value } else { nil } }

    /// One line of JSON, keys sorted, slashes left alone.
    var line: String { String(decoding: data, as: UTF8.self) }

    var data: Data {
        // Encoding a value of this enum can't fail.
        (try? Self.encoder.encode(self)) ?? Data("null".utf8)
    }

    init(line: String) throws { try self.init(data: Data(line.utf8)) }

    init(data: Data) throws { self = try JSONDecoder().decode(AgentJSON.self, from: data) }

    private static let encoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

nonisolated extension AgentJSON: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AgentJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AgentJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers as whole numbers: JSON-RPC ids are compared as written.
            if let whole = Int(exactly: value) { try container.encode(whole) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated extension AgentJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: AgentJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, AgentJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(nilLiteral: ()) { self = .null }
}
