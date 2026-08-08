import AppKit
import CoreText
import FunkyBarCore

/// Resolves a `FontSpec` to a concrete font, with a cache.
///
/// Font lookup by family plus face is not cheap, and the bar asks for the same
/// handful of fonts on every update.
public enum FontResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [FontSpec: NSFont] = [:]

    public static func font(for spec: FontSpec) -> NSFont {
        lock.lock()
        if let hit = cache[spec] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = resolve(spec)

        lock.lock()
        cache[spec] = resolved
        lock.unlock()
        return resolved
    }

    private static func resolve(_ spec: FontSpec) -> NSFont {
        let size = CGFloat(spec.size)

        // `.face` matches the style name a user would read in Font Book
        // ("Bold", "Regular", "Heavy"), which is the same vocabulary
        // sketchybarrc uses.
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: spec.family,
            .face: spec.style,
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        if let font = NSFont(name: spec.family, size: size) {
            return font
        }
        // A missing font must not take the bar down; fall back and let
        // `funkybar doctor` report it.
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static func isAvailable(_ spec: FontSpec) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(spec.family)
    }
}

/// A shaped line plus the metrics needed to place it.
public struct ShapedText {
    public let line: CTLine
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat

    public var height: CGFloat { ascent + descent }
}

/// Shapes and measures text with CoreText.
public struct CoreTextShaper: Sendable {
    public init() {}

    public func shape(_ text: String, font spec: FontSpec) -> ShapedText? {
        guard !text.isEmpty else { return nil }

        let font = FontResolver.font(for: spec)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        return ShapedText(line: line, width: CGFloat(width), ascent: ascent, descent: descent)
    }
}

/// The production `TextMeasuring`, backed by CoreText.
///
/// Wrap in `CachingTextMeasurer` for the bar; unwrapped it re-shapes on every
/// call, which is only appropriate for one-off measurement.
public struct CoreTextMeasurer: TextMeasuring {
    private let shaper = CoreTextShaper()

    public init() {}

    public func size(of text: String, font: FontSpec) -> CGSize {
        guard let shaped = shaper.shape(text, font: font) else { return .zero }
        // Round up so a fractional advance never clips the final glyph.
        return CGSize(width: shaped.width.rounded(.up), height: shaped.height.rounded(.up))
    }
}

/// Draws one shaped line, with the baseline placed explicitly.
///
/// A `CATextLayer` would be less code but aligns to the top of its bounds and
/// applies its own rounding, which shows up as a 1pt vertical wobble between
/// items of different font sizes. Owning the baseline avoids that.
final class TextLayer: CALayer {
    var shaped: ShapedText? {
        didSet { setNeedsDisplay() }
    }
    var color: CGColor = NSColor.white.cgColor {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        // Text is redrawn only when its content changes, so an implicit
        // fade on every property set is wasted work and looks like a flicker.
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TextLayer {
            shaped = other.shaped
            color = other.color
        }
    }

    required init?(coder: NSCoder) { nil }

    override func draw(in ctx: CGContext) {
        guard let shaped else { return }

        ctx.saveGState()
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(false)   // stem darkening looks wrong on a translucent bar
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        ctx.setFillColor(color)

        // The layer's height is ascent + descent, so the baseline sits exactly
        // `descent` above the bottom edge.
        ctx.textPosition = CGPoint(x: 0, y: shaped.descent)

        for run in CTLineGetGlyphRuns(shaped.line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[NSAttributedString.Key.font as NSString] as! CTFont? else { continue }

            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            // Draw glyphs directly rather than via CTLineDraw so the fill
            // colour set above wins over any colour baked into the run.
            for index in 0 ..< count {
                positions[index].y += shaped.descent
            }
            CTFontDrawGlyphs(font, glyphs, positions, count, ctx)
        }

        ctx.restoreGState()
    }
}
