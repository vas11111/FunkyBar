import CoreGraphics
import Foundation

/// Measures rendered text.
///
/// Injected rather than called directly so the layout engine can be tested
/// headlessly, with no display, no font loading and no CoreText.
public protocol TextMeasuring: Sendable {
    func size(of text: String, font: FontSpec) -> CGSize
}

/// A deterministic stand-in for tests: every glyph is `advance` wide and every
/// line `lineHeight` tall, both scaled by font size.
public struct FixedAdvanceMeasurer: TextMeasuring {
    public let advanceRatio: Double
    public let lineHeightRatio: Double

    public init(advanceRatio: Double = 0.6, lineHeightRatio: Double = 1.2) {
        self.advanceRatio = advanceRatio
        self.lineHeightRatio = lineHeightRatio
    }

    public func size(of text: String, font: FontSpec) -> CGSize {
        guard !text.isEmpty else { return .zero }
        // Count grapheme clusters, so a nerd-font glyph or an emoji counts once.
        let count = Double(text.count)
        return CGSize(
            width: (count * font.size * advanceRatio).rounded(),
            height: (font.size * lineHeightRatio).rounded()
        )
    }
}

/// Caches measurements keyed by text and font.
///
/// Re-laying out an unchanged label should cost a dictionary lookup, not a
/// text-shaping pass. The bar re-measures on every provider tick, and most
/// ticks change nothing.
public final class CachingTextMeasurer: TextMeasuring, @unchecked Sendable {
    private struct Key: Hashable {
        let text: String
        let family: String
        let style: String
        let size: Double
    }

    private let base: any TextMeasuring
    private let lock = NSLock()
    private var cache: [Key: CGSize] = [:]
    private let limit: Int

    public init(_ base: any TextMeasuring, limit: Int = 2048) {
        self.base = base
        self.limit = limit
    }

    public func size(of text: String, font: FontSpec) -> CGSize {
        let key = Key(text: text, family: font.family, style: font.style, size: font.size)

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let measured = base.size(of: text, font: font)

        lock.lock()
        // Crude eviction: text content churns slowly, so a full clear on
        // overflow is cheaper than tracking recency.
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[key] = measured
        lock.unlock()

        return measured
    }

    public func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
