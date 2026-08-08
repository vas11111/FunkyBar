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
    /// Layout width, matching sketchybar: ink bounds, then floor(w + 1.5).
    public let width: CGFloat
    /// Layout height, same rule.
    public let height: CGFloat
    /// Typographic metrics, used for the baseline.
    public let ascent: CGFloat
    public let descent: CGFloat

    /// Distance from the bottom of a `height`-tall box to the text baseline.
    ///
    /// sketchybar places the baseline at `centreY - (ascent - descent) / 2`.
    /// Given a box centred on `centreY`, that is this far above its bottom
    /// edge. Deriving it keeps the two implementations agreeing even though
    /// the box height comes from ink bounds and the baseline from typographic
    /// metrics.
    public var baselineOffset: CGFloat { (height - ascent + descent) / 2 }
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
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        // Match sketchybar exactly (src/text.c, text_prepare_line):
        //
        //   bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds)
        //   width  = (uint32_t)(bounds.size.width + 1.5)
        //
        // Ink bounds, not the typographic advance. For a digit in
        // JetBrainsMono Bold 14 the advance is 8.4 but the ink is narrower, and
        // the difference compounds across a row of items. The cast to uint32_t
        // truncates, so `+ 1.5` then floor is the same operation.
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        return ShapedText(
            line: line,
            width: (ink.width + 1.5).rounded(.down),
            height: (ink.height + 1.5).rounded(.down),
            ascent: ascent,
            descent: descent
        )
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
        return CGSize(width: shaped.width, height: shaped.height)
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
    /// Mirrors sketchybar's `CGContextSetAllowsFontSmoothing`, off by default.
    var allowsFontSmoothing = false {
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
            allowsFontSmoothing = other.allowsFontSmoothing
        }
    }

    required init?(coder: NSCoder) { nil }

    override func draw(in ctx: CGContext) {
        guard let shaped else { return }

        ctx.saveGState()
        // sketchybar sets only this one and leaves antialiasing at its default
        // (src/context.c). Matching that exactly matters: smoothing alters stem
        // weight without altering any metric.
        ctx.setAllowsFontSmoothing(allowsFontSmoothing)
        ctx.textMatrix = .identity
        ctx.setFillColor(color)

        ctx.textPosition = CGPoint(x: 0, y: shaped.baselineOffset)

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
                positions[index].y += shaped.baselineOffset
            }
            CTFontDrawGlyphs(font, glyphs, positions, count, ctx)
        }

        ctx.restoreGState()
    }
}
