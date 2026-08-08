import CoreGraphics
import Foundation

/// Space on the four sides of a box.
///
/// funkybar keeps `Insets` for two distinct roles that SketchyBar conflates:
///
/// - **margin**  sits outside the background and separates siblings
/// - **padding** sits inside the background and insets content
///
/// Upstream issue #796 is exactly this conflation: setting
/// `background.padding_left` silently overwrites the item's `padding_left`.
/// Two fields of the same type on different properties cannot do that.
public struct Insets: Equatable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    /// The same value on all four sides.
    public init(all value: Double) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    public init(horizontal: Double = 0, vertical: Double = 0) {
        self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public static let zero = Insets()

    public var horizontal: Double { leading + trailing }
    public var vertical: Double { top + bottom }

    public func adding(_ other: Insets) -> Insets {
        Insets(
            top: top + other.top,
            leading: leading + other.leading,
            bottom: bottom + other.bottom,
            trailing: trailing + other.trailing
        )
    }
}

/// A two-dimensional displacement.
///
/// Upstream issue #733 asks for `y_offset` to become a tuple so both axes can
/// be expressed. Here it always was one.
public struct Offset: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = Offset()
}

/// The axis a bar or popup lays out along.
///
/// Upstream issue #240 (vertical bar) has been open since 2022 because the
/// horizontal assumption is baked into every call site. Here it is a value.
public enum Axis: String, Equatable, Hashable, Sendable, CaseIterable {
    case horizontal
    case vertical

    /// The extent that grows as items are added.
    public func length(of size: CGSize) -> Double {
        self == .horizontal ? size.width : size.height
    }

    /// The extent fixed by the bar's thickness.
    public func breadth(of size: CGSize) -> Double {
        self == .horizontal ? size.height : size.width
    }

    public func size(length: Double, breadth: Double) -> CGSize {
        self == .horizontal
            ? CGSize(width: length, height: breadth)
            : CGSize(width: breadth, height: length)
    }
}

/// Which end of the bar a node is anchored to.
public enum Position: String, Equatable, Hashable, Sendable, CaseIterable {
    case left
    case center
    case right

    /// Alias so a vertical bar reads sensibly.
    public static let top = Position.left
    public static let bottom = Position.right
}

/// Where the bar sits on its display.
public enum BarEdge: String, Equatable, Hashable, Sendable, CaseIterable {
    case top
    case bottom

    public var axis: Axis { .horizontal }
}

/// How a corner is drawn.
///
/// Upstream issue #632 asks for inverted corners; making this an enum rather
/// than a bare radius leaves room for it.
public enum CornerStyle: String, Equatable, Hashable, Sendable, CaseIterable {
    case round
    case inverted
    case squircle
}

public struct Corner: Equatable, Hashable, Sendable {
    public var radius: Double
    public var style: CornerStyle

    public init(radius: Double = 0, style: CornerStyle = .round) {
        self.radius = radius
        self.style = style
    }

    public static let square = Corner()
}
