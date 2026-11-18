/// A JSON value as sent to or returned by the Transcript Dock API.
///
/// Responses are kept as `[String: JSONValue]` so fields added to the API later
/// are never dropped. Read nested values with subscripts and typed accessors:
///
/// ```swift
/// let status = job["status"]?.stringValue
/// let start = transcript["words"]?[0]?["start_ms"]?.intValue
/// ```
///
/// Build request bodies with literal syntax:
///
/// ```swift
/// let body: [String: JSONValue] = ["source": ["url": "https://example.com/video"], "max_credits": 1]
/// ```
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    /// A whole number that fits in 64 bits, kept exact.
    case integer(Int64)
    /// Any other JSON number.
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Integers and other numbers compare by numeric value, so `1` equals `1.0`.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.integer(a), .number(b)), let (.number(b), .integer(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        default: return false
        }
    }

    /// The member named `key` when this value is an object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }

    /// The element at `index` when this value is an array and the index exists.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let value) = self, value.indices.contains(index) { return value[index] }
        return nil
    }

    /// The string, when this value is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The boolean, when this value is a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The number as `Int`, when it is a whole number that fits.
    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value): return Int(exactly: value)
        default: return nil
        }
    }

    /// The number as `Double`, when this value is a number.
    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    /// The elements, when this value is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The members, when this value is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// True when this value is JSON `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
