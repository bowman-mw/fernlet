import Foundation

/// A JSON value kept verbatim (World-Airports-Spec §11, "Backups across builds"): a key of the passport's bytes
/// that this build does not know, or a sealed-backup record of a kind it does not know, read as plain JSON so a
/// newer Fernlet's data survives a round trip through this build untouched. Never interpreted, never shown.
///
/// **Bounded** (Power of 10): a value nested deeper than ``maxDepth`` (counted by its coding path, so the depth
/// of the whole document) is refused while it is read, never walked. Its size is bounded by the bytes it was read
/// from (``PassportBook/maxEncodedBytes``, or one sealed-backup record).
public nonisolated enum PassportJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// A whole number, kept whole.
    case integer(Int64)
    /// Any other number.
    case number(Double)
    case string(String)
    case array([PassportJSONValue])
    case object([String: PassportJSONValue])

    /// The deepest coding path a value is read at (a passport key is at depth 1).
    public static let maxDepth = 24

    /// Why a value was refused.
    public enum ValueError: Error, Equatable {
        /// Nested deeper than ``PassportJSONValue/maxDepth``.
        case tooDeep
        /// Not a JSON value at all.
        case malformed
    }

    /// Reads one value, refusing one deeper than ``maxDepth``.
    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDepth else { throw ValueError.tooDeep }
        if var list = try? decoder.unkeyedContainer() {
            var values: [PassportJSONValue] = []
            // Bounded: by the elements in the bytes read (at most maxEncodedBytes).
            while !list.isAtEnd {
                values.append(try list.decode(PassportJSONValue.self))
            }
            self = .array(values)
            return
        }
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            var values: [String: PassportJSONValue] = [:]
            // Bounded: by the keys in the bytes read.
            for key in keyed.allKeys {
                values[key.stringValue] = try keyed.decode(PassportJSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            throw ValueError.malformed
        }
    }

    /// Writes the value back as it was read.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .integer(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .number(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .array(let values):
            var list = encoder.unkeyedContainer()
            // Bounded: by the elements read.
            for value in values { try list.encode(value) }
        case .object(let values):
            var keyed = encoder.container(keyedBy: AnyKey.self)
            // Bounded: by the keys read.
            for (key, value) in values { try keyed.encode(value, forKey: AnyKey(key)) }
        }
    }

    /// The object's members, or nil for any other value.
    public var objectValue: [String: PassportJSONValue]? {
        guard case .object(let values) = self else { return nil }
        return values
    }

    /// The string, or nil for any other value.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// A coding key spelled by any string.
    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
