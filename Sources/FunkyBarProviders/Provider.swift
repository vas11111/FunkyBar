import Foundation
import FunkyBarCore

/// A snapshot of one provider's state.
public struct ProviderUpdate: Sendable, Equatable {
    /// Item id, or the template id for a repeated item.
    public let itemID: String
    /// Fields available to templates as `{name}`.
    public var values: [String: String]
    /// Expansion set for a dynamic `repeat`.
    public var expansion: [String]?
    /// Per-clone field overrides, keyed by full item id.
    public var perItem: [String: [String: String]]
    /// Popup contents. `nil` means "unchanged"; empty means "no rows".
    public var rows: [PopupRow]?

    public init(
        itemID: String,
        values: [String: String] = [:],
        expansion: [String]? = nil,
        perItem: [String: [String: String]] = [:],
        rows: [PopupRow]? = nil
    ) {
        self.itemID = itemID
        self.values = values
        self.expansion = expansion
        self.perItem = perItem
        self.rows = rows
    }
}

/// How often a provider needs to run.
public enum UpdatePolicy: Sendable, Equatable {
    /// Fully push-driven; no timer at all.
    case event
    /// Joins the shared timer wheel.
    case interval(seconds: Double)
}

/// A source of bar state.
///
/// Providers replace plugin scripts. The contract is deliberately narrow: read
/// state, hand back fields. Everything about *when* to run is the runtime's
/// business, so a provider cannot accidentally spin its own timer.
@MainActor
public protocol Provider: AnyObject {
    /// Config key this provider answers to, e.g. `clock`.
    static var kind: String { get }

    var itemID: String { get }
    var policy: UpdatePolicy { get }

    /// Called once when the bar starts. Event-driven providers register their
    /// observers here and call `emit` whenever state changes.
    func start(emit: @escaping @MainActor (ProviderUpdate) -> Void)

    /// Called on each tick for `.interval` providers, and once after `start`.
    func refresh() -> ProviderUpdate?

    /// Handle a `provider:command` action from a click.
    func handle(command: String)

    func stop()
}

public extension Provider {
    func handle(command: String) {}
    func stop() {}
}

/// Everything a provider needs from its config entry.
public struct ProviderContext: Sendable {
    public let itemID: String
    public let options: TOMLTable
    public let interval: Double?

    public init(itemID: String, options: TOMLTable, interval: Double?) {
        self.itemID = itemID
        self.options = options
        self.interval = interval
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = options[key]?.value { return value }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if case .integer(let value)? = options[key]?.value { return value }
        return nil
    }

    public func strings(_ key: String) -> [String]? {
        guard case .array(let elements)? = options[key]?.value else { return nil }
        return elements.compactMap { if case .string(let s) = $0.value { s } else { nil } }
    }

    public func ints(_ key: String) -> [Int]? {
        guard case .array(let elements)? = options[key]?.value else { return nil }
        return elements.compactMap { if case .integer(let i) = $0.value { i } else { nil } }
    }
}
