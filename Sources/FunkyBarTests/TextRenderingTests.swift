import AppKit
import Foundation
import TestKit
import FunkyBarCore
import FunkyBarRender

// The layout rect and the drawing box are different things, and conflating
// them clipped glyphs while every geometry and style comparison still passed.
// These assert the drawing box, which nothing else covers.

private let shaper = CoreTextShaper()
private let mono = FontSpec(family: "JetBrainsMono Nerd Font", style: "Bold", size: 14)

let textRenderingTests = Suite("Text rendering") { s in

    s.test("the font actually resolves, so the rest of this suite means something") { t in
        let font = FontResolver.font(for: mono)
        t.expectContains(font.fontName, "JetBrains")
    }

    s.test("ink is not anchored at the pen, which is the whole trap") { t in
        // `›` advances 8.4pt but its ink is narrower and starts right of the
        // pen. A layer sized to the ink box and drawn at its origin loses the
        // right side of the glyph.
        let shaped = try t.require(shaper.shape("›", font: mono))
        t.expect(shaped.ink.minX > 0.5,
                 "expected a left side bearing, got \(shaped.ink.minX)")
        t.expect(shaped.ink.maxX > shaped.width,
                 "ink reaches \(shaped.ink.maxX) but the layout width is \(shaped.width)")
    }

    s.test("the drawing box contains the ink horizontally") { t in
        for text in ["›", "1", "Helium", "$1916.71", "20:28  Sat 08", "\u{f099e}", "\u{f0084}"] {
            let shaped = try t.require(shaper.shape(text, font: mono), "could not shape \(text.debugDescription)")
            let box = shaped.drawingSize
            let pen = shaped.penPoint
            t.expect(pen.x + shaped.ink.maxX <= box.width,
                     "\(text.debugDescription): ink reaches \(pen.x + shaped.ink.maxX) in a \(box.width)-wide box")
        }
    }

    s.test("the drawing box contains the ink vertically") { t in
        for text in ["›", "g", "Helium", "\u{f099e}"] {
            let shaped = try t.require(shaper.shape(text, font: mono))
            let box = shaped.drawingSize
            let pen = shaped.penPoint
            // Ink is measured from the baseline: maxY above it, minY possibly below.
            t.expect(pen.y + shaped.ink.maxY <= box.height,
                     "\(text.debugDescription): ink top at \(pen.y + shaped.ink.maxY) in a \(box.height)-tall box")
            t.expect(pen.y + shaped.ink.minY >= 0,
                     "\(text.debugDescription): ink bottom at \(pen.y + shaped.ink.minY), below the box")
        }
    }

    s.test("layout width follows sketchybar's rule exactly") { t in
        // src/text.c: (uint32_t)(CTLineGetBoundsWithOptions(..useGlyphPathBounds).width + 1.5)
        for text in ["1", "4", "Helium", "20:28  Sat 08"] {
            let shaped = try t.require(shaper.shape(text, font: mono))
            t.expectEqual(shaped.width, (shaped.ink.width + 1.5).rounded(.down),
                          "width rule for \(text.debugDescription)")
        }
    }

    s.test("the baseline lands where sketchybar puts it") { t in
        // sketchybar: baseline = centreY - (ascent - descent) / 2.
        let shaped = try t.require(shaper.shape("Helium", font: mono))
        let centreY: CGFloat = 18
        let expected = centreY - (shaped.ascent - shaped.descent) / 2

        // Reproduce what BarLayerTree.place does.
        let layerMinY = expected - shaped.penPoint.y
        let actual = layerMinY + shaped.penPoint.y
        t.expect(abs(actual - expected) < 0.001, "expected \(expected), got \(actual)")
    }

    s.test("an empty string shapes to nothing rather than a zero-size box") { t in
        t.expectNil(shaper.shape("", font: mono))
    }

    s.test("a missing font falls back instead of crashing") { t in
        let font = FontResolver.font(for: FontSpec(family: "No Such Font Here", size: 12))
        t.expect(font.pointSize == 12, "fallback should keep the requested size")
    }
}



// MARK: - Pixel tests

// Every earlier bug here survived because the suite only checked computed
// values. These render and then measure the result, which is the only way to
// catch a drawing mistake that leaves every input correct: the pen offset was
// applied twice (once via CGContext.textPosition, once per glyph), so the
// numbers all agreed while the glyphs sat 6pt off centre.

@MainActor
private func renderInk(_ text: String, font: FontSpec, boxHeight: CGFloat = 36)
    -> (inkCentre: CGFloat, boxCentre: CGFloat, found: Bool) {
    let shaper = CoreTextShaper()
    guard let shaped = shaper.shape(text, font: font) else { return (0, 0, false) }

    let width = Int((shaped.drawingSize.width + 20) * 2)
    let height = Int(boxHeight * 2)
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return (0, 0, false) }
    ctx.scaleBy(x: 2, y: 2)

    // Place exactly as BarLayerTree.place does, centred on the box.
    let centre = boxHeight / 2
    let layer = TextLayerProbe(shaped: shaped)
    let pen = shaped.penPoint
    let baselineY = centre - (shaped.ascent - shaped.descent) / 2
    layer.frame = CGRect(
        x: 10, y: baselineY - pen.y,
        width: shaped.drawingSize.width, height: shaped.drawingSize.height
    )
    layer.penPoint = pen
    layer.contentsScale = 2

    // Call the drawing code directly rather than through render(in:), which
    // does not reliably invoke draw(in:) on a layer that has never been
    // displayed. Translating by the frame origin reproduces what CoreAnimation
    // does when it hands a layer its context.
    ctx.saveGState()
    ctx.translateBy(x: layer.frame.minX, y: layer.frame.minY)
    layer.draw(in: ctx)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return (0, 0, false) }
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let read = CGContext(
        data: &buffer, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return (0, 0, false) }
    read.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var lo = height, hi = -1
    for y in 0 ..< height {
        for x in 0 ..< width where buffer[(y * width + x) * 4 + 3] > 40 {
            lo = min(lo, y); hi = max(hi, y); break
        }
    }
    guard hi >= 0 else { return (0, centre, false) }
    // Buffer row 0 is the top of the image; convert back to the layer's space.
    let inkCentre = boxHeight - (CGFloat(lo + hi + 1) / 2 / 2)
    return (inkCentre, centre, true)
}

private final class TextLayerProbe: CALayer {
    private let shapedText: ShapedText
    var penPoint: CGPoint = .zero
    init(shaped: ShapedText) {
        self.shapedText = shaped
        super.init()
    }
    override init(layer: Any) { shapedText = (layer as! TextLayerProbe).shapedText; super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        for run in CTLineGetGlyphRuns(shapedText.line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let font = attrs[NSAttributedString.Key.font as NSString] as! CTFont? else { continue }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)
            for i in 0 ..< count { positions[i].x += penPoint.x; positions[i].y += penPoint.y }
            CTFontDrawGlyphs(font, glyphs, positions, count, ctx)
        }
    }
}

let pixelTests = Suite("Text pixels") { s in

    s.test("rendered glyphs land centred on their box") { t in
        // The regression: text sat 6pt high in every pill while every computed
        // value was correct.
        for (text, size) in [("1", 14.0), ("Helium", 13.0), ("20:28  Sat 08", 12.0), ("80%", 12.0)] {
            let font = FontSpec(family: "JetBrainsMono Nerd Font", style: "Bold", size: size)
            let result = MainActor.assumeIsolated { renderInk(text, font: font) }
            guard result.found else {
                t.fail("nothing rendered for \(text.debugDescription)")
                continue
            }
            let offset = result.inkCentre - result.boxCentre
            t.expect(abs(offset) < 1.0,
                     "\(text.debugDescription) ink centre is \(String(format: "%+.2f", offset))pt off the box centre")
        }
    }

    s.test("glyphs actually reach the pixels, not just the metrics") { t in
        let font = FontSpec(family: "JetBrainsMono Nerd Font", style: "Bold", size: 14)
        let result = MainActor.assumeIsolated { renderInk("\u{f099e}", font: font) }
        t.expect(result.found, "the nerd-font shield glyph rendered no pixels at all")
    }
}

let renderSuites: [Suite] = [textRenderingTests, pixelTests]
