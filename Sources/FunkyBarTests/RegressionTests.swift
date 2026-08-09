import Foundation
import TestKit
import FunkyBarCore

// Regressions for defects found by looking at the bar next to sketchybar.
// Each one was invisible to the rest of the suite, which is the point.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func exampleConfig() throws -> Config {
    let source = try String(
        contentsOf: packageRoot.appendingPathComponent("funkybar.toml.example"),
        encoding: .utf8
    )
    return ConfigDecoder.decode(try TOMLParser.parse(source)).config
}

private func item(_ config: Config, _ id: String) -> ItemConfig? {
    config.allItems.first { $0.id == id }
}

let glyphRegressionTests = Suite("Glyph integrity") { s in

    // The nerd-font icons are 5 hex digits (U+F048D). An earlier version of the
    // config had every one of them truncated to 4 digits with the fifth leaking
    // through as a stray ASCII character, so `U+F099E` became `U+F099` + "E".
    // The bar rendered a wrong glyph followed by a letter and nothing caught it.
    let expected: [(item: String, state: String?, codepoint: UInt32, name: String)] = [
        ("ports", nil,     0xF048D, "network"),
        ("status", "ON",         0xF099D, "shield-check"),
        ("status", "CONNECTING", 0xF099D, "shield-check"),
        ("status", "ERROR",      0xF099D, "shield-check"),
        ("status", "OFF",        0xF099E, "shield-off"),
    ]

    for entry in expected {
        let label = entry.state.map { "\(entry.item).\($0)" } ?? entry.item
        s.test("\(label) icon is exactly U+\(String(entry.codepoint, radix: 16, uppercase: true))") { t in
            let config = try exampleConfig()
            let target = try t.require(item(config, entry.item), "no item '\(entry.item)'")

            let text: String
            if let state = entry.state {
                let spec = try t.require(target.states[state], "no state '\(state)'")
                text = try t.require(spec.icon, "state has no icon").source
            } else {
                text = target.icon.template.source
            }

            let scalars = Array(text.unicodeScalars)
            t.expectEqual(scalars.count, 1, "\(label) icon should be one scalar, got \(scalars.count): \(text.debugDescription)")
            guard let first = scalars.first else { return }
            t.expectEqual(first.value, entry.codepoint, "expected \(entry.name)")
        }
    }

    s.test("the battery ramp is five single-scalar glyphs, low to high") { t in
        let config = try exampleConfig()
        let battery = try t.require(item(config, "battery"))
        let options = try t.require(battery.provider?.options)

        guard case .array(let nodes)? = options["ramp"]?.value else {
            t.fail("battery provider has no ramp array")
            return
        }
        let glyphs: [String] = nodes.compactMap { if case .string(let g) = $0.value { g } else { nil } }
        t.expectEqual(glyphs.count, 5)

        // From battery.sh: empty, low, mid, high, full.
        let expected: [UInt32] = [0xF0083, 0xF007B, 0xF007E, 0xF0080, 0xF0082]
        for (glyph, want) in zip(glyphs, expected) {
            let scalars = Array(glyph.unicodeScalars)
            t.expectEqual(scalars.count, 1, "ramp glyph \(glyph.debugDescription) should be one scalar")
            t.expectEqual(scalars.first?.value, want)
        }

        guard case .string(let charging)? = options["charging"]?.value else {
            t.fail("battery provider has no charging glyph")
            return
        }
        t.expectEqual(Array(charging.unicodeScalars).count, 1)
        t.expectEqual(charging.unicodeScalars.first?.value, 0xF0084)
    }

    s.test("no icon or label in the example config carries a stray ASCII tail") { t in
        // The general shape of the corruption: a private-use scalar immediately
        // followed by an ASCII character. Nothing in this config legitimately
        // does that.
        let config = try exampleConfig()

        func check(_ text: String, _ where_: String) {
            let scalars = Array(text.unicodeScalars)
            for (index, scalar) in scalars.enumerated() where (0xE000 ... 0xFFFFD).contains(scalar.value) {
                guard index + 1 < scalars.count else { continue }
                let next = scalars[index + 1]
                t.expect(
                    !(next.value < 0x80 && next.value > 0x20),
                    "\(where_): private-use U+\(String(scalar.value, radix: 16, uppercase: true)) "
                    + "followed by ASCII '\(Character(next))' looks like a truncated codepoint"
                )
            }
        }

        for target in config.allItems {
            check(target.icon.template.source, "\(target.id).icon")
            check(target.label.template.source, "\(target.id).label")
            for (name, state) in target.states {
                if let icon = state.icon { check(icon.source, "\(target.id).states.\(name).icon") }
                if let label = state.label { check(label.source, "\(target.id).states.\(name).label") }
            }
        }
    }
}

let renderRegressionTests = Suite("Render regressions") { s in

    s.test("ports renders a label, not just an icon") { t in
        // The ports provider emits a `label` field. Nothing consumed it, so the
        // item drew an icon and no text where sketchybar shows "1P".
        let ports = try t.require(item(try exampleConfig(), "ports"))
        t.expect(!ports.label.template.source.isEmpty, "ports has no label template")
        t.expectEqual(ports.label.template.fields.contains("label"), true)
    }

    s.test("a transparent fill with an image still counts as visible") { t in
        // The coin pills set drawing = false to hide the fill. That suppressed
        // the whole background layer, and the image rides on it, so the coin
        // icons never drew.
        var style = StyleSpec()
        style.color = .clear
        style.borderWidth = 0
        style.image = ImageSpec(path: Template("/tmp/x.png"))
        t.expectEqual(style.isVisible, true, "an image alone should be worth drawing")

        style.drawing = false
        t.expectEqual(style.isVisible, false, "drawing = false still wins")
    }

    s.test("image paths substitute provider fields") { t in
        // `icons/{repeat}.png` was stored as a literal String, so every coin
        // asked for a file called "{repeat}.png".
        var config = ItemConfig(id: "meter.c")
        config.repeatValue = "c"
        var style = StyleSpec()
        style.image = ImageSpec(path: Template("/icons/{repeat}.png"))
        config.style = style

        let resolved = ItemResolver.resolve(config)
        t.expectEqual(resolved.style.image?.resolvedPath, "/icons/btc.png")
    }

    s.test("image paths expand a leading tilde after substitution") { t in
        var config = ItemConfig(id: "a")
        var style = StyleSpec()
        style.image = ImageSpec(path: Template("~/icons/x.png"))
        config.style = style

        let resolved = try t.require(ItemResolver.resolve(config).style.image?.resolvedPath)
        t.expect(!resolved.hasPrefix("~"), "tilde should be expanded, got \(resolved)")
        t.expectContains(resolved, "/icons/x.png")
    }

    s.test("the coin pills declare their real on-screen order") { t in
        // Upstream declared btc/eth/sol and relied on right-side reverse
        // insertion. Here declaration order is visual order, so the same list
        // would come out backwards.
        let config = try exampleConfig()
        var coins: [String] = []
        for case .group(let group) in config.nodes where group.id == "meters_pill" {
            coins = group.items.compactMap(\.repeatValue)
        }
        t.expectEqual(coins, ["a", "b", "c"])
    }

    s.test("every coin has artwork on disk under the configured path") { t in
        let config = try exampleConfig()
        var checked = 0
        for case .group(let group) in config.nodes where group.id == "meters_pill" {
            for coin in group.items {
                guard coin.style.image != nil else {
                    t.fail("\(coin.id) has no image")
                    continue
                }
                let path = try t.require(ItemResolver.resolve(coin).style.image?.resolvedPath)
                t.expect(
                    FileManager.default.fileExists(atPath: path),
                    "missing artwork for \(coin.id): \(path)"
                )
                checked += 1
            }
        }
        t.expectEqual(checked, 3)
    }
}

let seedRegressionTests = Suite("Seed file regressions") { s in

    s.test("battery consumes the provider's icon field") { t in
        // [item.icon] set only padding, so the ramp glyph the provider emits
        // had no template to land in and the battery drew no icon at all.
        let battery = try t.require(item(try exampleConfig(), "battery"))
        t.expectEqual(battery.icon.template.fields.contains("icon"), true,
                      "battery icon template is \(battery.icon.template.source.debugDescription)")
    }

    s.test("the meter seed splits on whitespace by default") { t in
        // The state file holds "75.85 1916.11 64943", exactly what
        // `read -r FSOL FETH FBTC < file` expects. An earlier version assumed
        // a middle-dot separator, so the whole line landed in the first coin.
        let config = try exampleConfig()
        var options: TOMLTable?
        for case .group(let group) in config.nodes where group.id == "meters_pill" {
            options = group.items.first?.provider?.options
        }
        let opts = try t.require(options, "meter has no provider options")

        guard case .array(let keys)? = opts["seed_keys"]?.value else {
            t.fail("meter has no seed_keys")
            return
        }
        let names: [String] = keys.compactMap { if case .string(let k) = $0.value { k } else { nil } }
        t.expectEqual(names, ["a", "b", "c"], "seed order must match declaration order")
        t.expectNil(opts["seed_separator"], "whitespace is the default; an explicit separator is wrong here")
    }
}

let popupAlignmentTests = Suite("Popup row alignment") { s in

    s.test("defaults to columns, and the option is honoured") { t in
        let base = """
        [[item]]
        id = "x"
        [item.popup]
        on = "click"
        """
        var outcome = ConfigDecoder.decode(try TOMLParser.parse(base))
        t.expectEqual(outcome.config.allItems.first?.popup?.rowAlignment, .columns)

        outcome = ConfigDecoder.decode(try TOMLParser.parse(base + "\nrows = \"compact\"\n"))
        t.expectEqual(outcome.config.allItems.first?.popup?.rowAlignment, .compact)
        t.expectEqual(outcome.diagnostics.hasErrors, false)
    }

    s.test("an unknown alignment is rejected with the options listed") { t in
        let outcome = ConfigDecoder.decode(try TOMLParser.parse("""
        [[item]]
        id = "x"
        [item.popup]
        on = "click"
        rows = "sideways"
        """))
        let error = try t.require(outcome.diagnostics.errors.first)
        t.expectContains(error.message, "not one of the allowed values")
        t.expectContains(try t.require(error.hint), "compact")
    }

    s.test("the example config states its choice rather than relying on a default") { t in
        // The difference from sketchybar's popup is deliberate, so the config
        // says so out loud; an unexplained difference is indistinguishable
        // from a bug.
        let popup = try t.require(item(try exampleConfig(), "ports")?.popup)
        t.expectEqual(popup.rowAlignment, .columns)
    }
}

let regressionSuites: [Suite] = [
    popupAlignmentTests,
    providerCommandTests,
    seedRegressionTests,
    glyphRegressionTests,
    renderRegressionTests,
]

let providerCommandTests = Suite("Provider commands") { s in

    s.test("the status item binds a toggle command the provider can find") { t in
        // The click and the action both resolved correctly in the event trace,
        // so a dead button means the command never reached the provider.
        let config = try exampleConfig()
        let status = try t.require(item(config, "status"))
        let binding = try t.require(status.provider, "status has no provider")

        guard case .table(let commands)? = binding.options["commands"]?.value else {
            t.fail("provider options have no [commands] table; keys: \(binding.options.keys)")
            return
        }
        t.expect(commands["toggle"] != nil, "no toggle command; have \(commands.keys)")
        t.expect(commands["settings"] != nil, "no settings command; have \(commands.keys)")

        guard case .string(let toggle)? = commands["toggle"]?.value else {
            t.fail("toggle is not a string")
            return
        }
        // StatusApp.app watches this file; the --toggle flag it does not use.
        t.expectContains(toggle, "status-command")
        t.expect(!toggle.contains("--toggle"), "should not call the flag the app ignores")
    }

    s.test("the left click resolves to that provider command") { t in
        let status = try t.require(item(try exampleConfig(), "status"))
        t.expectEqual(status.actions[.left], .provider(name: "status", command: "toggle"))
        t.expectEqual(status.actions[.right], .provider(name: "status", command: "settings"))
    }
}
