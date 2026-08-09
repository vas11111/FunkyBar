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

let renderSuites: [Suite] = [textRenderingTests]
