import Foundation

/// A 1-based position in a source file.
public struct SourceLocation: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let unknown = SourceLocation(line: 0, column: 0)

    public var description: String { "\(line):\(column)" }
}

/// A parsed TOML value.
///
/// Deliberately a subset: tables, arrays, strings, integers, floats and
/// booleans. Datetimes are rejected at parse time rather than silently
/// coerced, because nothing in the funkybar schema uses them and a
/// misparsed date would be worse than a clear error.
public indirect enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLNode])
    case table(TOMLTable)

    /// Human-facing name, used in "expected X, found Y" diagnostics.
    public var typeName: String {
        switch self {
        case .string:  "string"
        case .integer: "integer"
        case .double:  "float"
        case .boolean: "boolean"
        case .array:   "array"
        case .table:   "table"
        }
    }
}

/// A value plus where it came from.
public struct TOMLNode: Sendable, Equatable {
    public let value: TOMLValue
    public let location: SourceLocation

    public init(_ value: TOMLValue, at location: SourceLocation) {
        self.value = value
        self.location = location
    }
}

/// An order-preserving TOML table.
///
/// Key order matters here: bar items render in declaration order, so the
/// parser must not hand the schema layer an unordered dictionary.
public struct TOMLTable: Sendable, Equatable {
    public private(set) var keys: [String]
    private var storage: [String: TOMLNode]
    public let location: SourceLocation

    public init(keys: [String] = [], storage: [String: TOMLNode] = [:], location: SourceLocation = .unknown) {
        self.keys = keys
        self.storage = storage
        self.location = location
    }

    public subscript(key: String) -> TOMLNode? {
        storage[key]
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    /// Key/value pairs in declaration order.
    public var entries: [(key: String, node: TOMLNode)] {
        keys.compactMap { key in storage[key].map { (key, $0) } }
    }

    public mutating func insert(_ node: TOMLNode, for key: String) {
        if storage[key] == nil { keys.append(key) }
        storage[key] = node
    }
}
