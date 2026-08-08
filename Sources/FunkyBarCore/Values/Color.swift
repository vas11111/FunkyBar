import CoreGraphics
import Foundation

/// An sRGB colour with straight (non-premultiplied) alpha.
///
/// Accepted literals:
///
/// - `#rgb`        shorthand, opaque
/// - `#rrggbb`     opaque
/// - `#aarrggbb`   alpha first, matching the `0xAARRGGBB` order SketchyBar uses
/// - `0xAARRGGBB`  accepted verbatim, so a config ported from sketchybarrc
///                 keeps working during migration
public struct Color: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)

    // MARK: - Parsing

    public enum ParseFailure: Error, Equatable, Sendable {
        case missingPrefix
        case badLength(Int)
        case badDigits

        public var message: String {
            switch self {
            case .missingPrefix:
                "colour must start with '#' or '0x'"
            case .badLength(let n):
                "colour has \(n) hex digits; expected 3 (#rgb), 6 (#rrggbb) or 8 (#aarrggbb)"
            case .badDigits:
                "colour contains a character that is not a hex digit"
            }
        }

        public var hint: String {
            "example: #f4d35e, #ff141414, or 0xfff4d35e"
        }
    }

    public static func parse(_ text: String) -> Result<Color, ParseFailure> {
        var digits = text.trimmingCharacters(in: .whitespaces)

        if digits.hasPrefix("#") {
            digits.removeFirst()
        } else if digits.lowercased().hasPrefix("0x") {
            digits.removeFirst(2)
        } else {
            return .failure(.missingPrefix)
        }

        guard digits.allSatisfy(\.isHexDigit) else {
            return .failure(.badDigits)
        }

        func channel(_ slice: Substring) -> Double {
            Double(UInt8(slice, radix: 16) ?? 0) / 255.0
        }

        let chars = Array(digits)
        switch chars.count {
        case 3:
            // #rgb expands each nibble: f -> ff
            let expanded = digits.flatMap { [$0, $0] }
            let s = String(expanded)
            let i = s.startIndex
            return .success(Color(
                red: channel(s[i ..< s.index(i, offsetBy: 2)]),
                green: channel(s[s.index(i, offsetBy: 2) ..< s.index(i, offsetBy: 4)]),
                blue: channel(s[s.index(i, offsetBy: 4) ..< s.index(i, offsetBy: 6)])
            ))

        case 6:
            let i = digits.startIndex
            return .success(Color(
                red: channel(digits[i ..< digits.index(i, offsetBy: 2)]),
                green: channel(digits[digits.index(i, offsetBy: 2) ..< digits.index(i, offsetBy: 4)]),
                blue: channel(digits[digits.index(i, offsetBy: 4) ..< digits.index(i, offsetBy: 6)])
            ))

        case 8:
            let i = digits.startIndex
            return .success(Color(
                red: channel(digits[digits.index(i, offsetBy: 2) ..< digits.index(i, offsetBy: 4)]),
                green: channel(digits[digits.index(i, offsetBy: 4) ..< digits.index(i, offsetBy: 6)]),
                blue: channel(digits[digits.index(i, offsetBy: 6) ..< digits.index(i, offsetBy: 8)]),
                alpha: channel(digits[i ..< digits.index(i, offsetBy: 2)])
            ))

        default:
            return .failure(.badLength(chars.count))
        }
    }

    // MARK: - Derivation

    public func withAlpha(_ alpha: Double) -> Color {
        Color(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Linear interpolation in sRGB space. Good enough for hover and
    /// active-state tinting; not colour-managed blending.
    public func blended(with other: Color, amount: Double) -> Color {
        let t = amount.clamped01
        return Color(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// `#aarrggbb`, round-tripping through `parse`.
    public var hexString: String {
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return String(
            format: "#%02x%02x%02x%02x",
            byte(alpha), byte(red), byte(green), byte(blue)
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var isTransparent: Bool { alpha <= 0.001 }
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
