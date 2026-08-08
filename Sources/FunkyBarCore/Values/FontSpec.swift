import Foundation

/// A font request, resolved to a real font by the render layer.
public struct FontSpec: Equatable, Hashable, Sendable {
    public var family: String
    public var style: String
    public var size: Double

    public init(family: String, style: String = "Regular", size: Double = 12) {
        self.family = family
        self.style = style
        self.size = size
    }

    public static let systemDefault = FontSpec(family: "SF Pro Text", style: "Regular", size: 12)

    /// Parses SketchyBar's `"Family:Style:Size"` shorthand, so a font string
    /// copied out of an old sketchybarrc keeps working.
    public static func parse(_ text: String) -> FontSpec? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return FontSpec(family: String(parts[0]))
        case 2:
            guard let size = Double(parts[1]) else { return nil }
            return FontSpec(family: String(parts[0]), size: size)
        case 3:
            guard let size = Double(parts[2]) else { return nil }
            return FontSpec(family: String(parts[0]), style: String(parts[1]), size: size)
        default:
            return nil
        }
    }

    public var shorthand: String { "\(family):\(style):\(size)" }
}
