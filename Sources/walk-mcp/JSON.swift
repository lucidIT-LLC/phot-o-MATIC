import Foundation

/// A JSON value that is `Sendable`, so a request can cross a task boundary.
///
/// WHY NOT `[String: Any]` AND `JSONSerialization`. Foundation's obvious path
/// hands back `Any`, which is not `Sendable`, and this server answers requests
/// on concurrent tasks so that a 30-second folder scan does not block a ping.
/// A non-Sendable payload would have to be either serialized back to `Data` at
/// every hand-off or forced across with an unsafe annotation. An enum is the
/// honest shape.
///
/// WHY NOT A HAND-WRITTEN SERIALIZER EITHER. String escaping is where hand-rolled
/// JSON breaks — a control character, a lone surrogate, a backslash in a
/// Windows-style path — and it breaks by emitting something the client cannot
/// parse, on one input, months later. `Codable` delegates escaping to Foundation.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        // Int BEFORE Double: decoding 2 as a Double and re-emitting it as 2.0
        // changes a JSON-RPC id, and an id that changes shape is an id the
        // client cannot correlate.
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):
            // NaN AND INFINITY BECOME null, NOT ZERO.
            //
            // JSON has no way to spell either, and `JSONEncoder` throws on them.
            // Zero would be a lie: WalkKit uses NaN to mean "this measurement
            // could not be made" — `HLGGrade.Reading.valid` exists for exactly
            // that — and a measurement that could not be made must not arrive at
            // a language model as the number nought.
            try d.isFinite ? c.encode(d) : c.encodeNil()
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}

extension JSON {
    public var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i):  return i != 0
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public subscript(_ key: String) -> JSON? { objectValue?[key] }

    /// Convenience for building numbers without choosing a case at every site.
    public static func number(_ d: Double) -> JSON { .double(d) }
    public static func optional(_ d: Double?) -> JSON { d.map { .double($0) } ?? .null }
    public static func optional(_ i: Int?) -> JSON { i.map { .int($0) } ?? .null }
    public static func optional(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    public static func optional(_ b: Bool?) -> JSON { b.map { .bool($0) } ?? .null }

    /// Serialize to one line. NO pretty-printing, ever: the stdio binding says
    /// messages "MUST NOT contain embedded newlines", so a pretty-printer here
    /// would split one message into many unparseable ones.
    public func line() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }
}
