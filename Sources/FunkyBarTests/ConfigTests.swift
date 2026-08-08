import Foundation
import TestKit
import FunkyBarCore

// MARK: - Helpers

private func decode(_ source: String) throws -> ConfigDecoder.Outcome {
    ConfigDecoder.decode(try TOMLParser.parse(source))
}

private func item(_ outcome: ConfigDecoder.Outcome, _ id: String) -> ItemConfig? {
    outcome.config.allItems.first { $0.id == id }
}

private func group(_ outcome: ConfigDecoder.Outcome, _ id: String) -> GroupConfig? {
    for case .group(let g) in outcome.config.nodes where g.id == id { return g }
    return nil
}

/// The package root, derived from this file's compile-time path.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)          // .../Sources/FunkyBarTests/ConfigTests.swift
        .deletingLastPathComponent()          // .../Sources/FunkyBarTests
        .deletingLastPathComponent()          // .../Sources
        .deletingLastPathComponent()          // package root
}

// MARK: - Colour

let colorTests = Suite("Colour") { s in

    s.test("parses #rrggbb") { t in
        let color = try t.require(try? Color.parse("#f4d35e").get())
        t.expect(abs(color.red - 244.0 / 255) < 0.001, "red channel")
        t.expect(abs(color.green - 211.0 / 255) < 0.001, "green channel")
        t.expect(abs(color.blue - 94.0 / 255) < 0.001, "blue channel")
        t.expectEqual(color.alpha, 1.0)
    }

    s.test("parses #rgb shorthand by doubling each nibble") { t in
        let short = try t.require(try? Color.parse("#fa0").get())
        let long = try t.require(try? Color.parse("#ffaa00").get())
        t.expectEqual(short, long)
    }

    s.test("parses #aarrggbb with alpha first") { t in
        let color = try t.require(try? Color.parse("#80141414").get())
        t.expect(abs(color.alpha - 128.0 / 255) < 0.001, "alpha channel")
        t.expect(abs(color.red - 20.0 / 255) < 0.001, "red channel")
    }

    s.test("accepts sketchybar's 0xAARRGGBB so a ported config keeps working") { t in
        t.expectEqual(try? Color.parse("0xfff4d35e").get(), try? Color.parse("#fff4d35e").get())
    }

    s.test("fully transparent is detected") { t in
        t.expectEqual((try? Color.parse("#00000000").get())?.isTransparent, true)
        t.expectEqual((try? Color.parse("#ff000000").get())?.isTransparent, false)
    }

    s.test("rejects a missing prefix") { t in
        guard case .failure(let f) = Color.parse("f4d35e") else {
            t.fail("expected failure")
            return
        }
        t.expectEqual(f, .missingPrefix)
    }

    s.test("rejects a bad digit count with the count in the message") { t in
        guard case .failure(let f) = Color.parse("#12345") else {
            t.fail("expected failure")
            return
        }
        t.expectEqual(f, .badLength(5))
        t.expectContains(f.message, "5 hex digits")
    }

    s.test("rejects non-hex characters") { t in
        guard case .failure(let f) = Color.parse("#gggggg") else {
            t.fail("expected failure")
            return
        }
        t.expectEqual(f, .badDigits)
    }

    s.test("hexString round-trips") { t in
        let original = try t.require(try? Color.parse("#80f4d35e").get())
        t.expectEqual(try? Color.parse(original.hexString).get(), original)
    }
}

// MARK: - Template

let templateTests = Suite("Template") { s in

    s.test("a plain string is constant") { t in
        let template = Template("STATUS")
        t.expectEqual(template.isConstant, true)
        t.expectEqual(template.render([:]), "STATUS")
    }

    s.test("interpolates fields") { t in
        t.expectEqual(Template("{time}  {date}").render(["time": "09:41", "date": "Fri 08"]),
                      "09:41  Fri 08")
    }

    s.test("a literal dollar survives beside a field, which is why ${price} works") { t in
        t.expectEqual(Template("${price}").render(["price": "1234"]), "$1234")
    }

    s.test("double braces escape to a literal brace") { t in
        t.expectEqual(Template("{{x}}").render([:]), "{x}")
    }

    s.test("an unknown field renders empty rather than failing") { t in
        t.expectEqual(Template("[{missing}]").render([:]), "[]")
    }

    s.test("an unterminated brace stays literal so a stray { cannot break the bar") { t in
        t.expectEqual(Template("100% {").render([:]), "100% {")
    }

    s.test("reports referenced fields in first-appearance order") { t in
        t.expectEqual(Template("{b} {a} {b}").fields, ["b", "a"])
    }
}

// MARK: - Insets and duration

let readerValueTests = Suite("Config values") { s in

    s.test("a bare number becomes insets on all four sides") { t in
        let outcome = try decode("[bar]\npadding = 6\n")
        t.expectEqual(outcome.config.bar.padding, Insets(all: 6))
    }

    s.test("named sides map onto leading and trailing") { t in
        let outcome = try decode("[bar]\npadding = { left = 10, right = 4 }\n")
        t.expectEqual(outcome.config.bar.padding.leading, 10)
        t.expectEqual(outcome.config.bar.padding.trailing, 4)
    }

    s.test("margin can be zero, which upstream cannot express") { t in
        // Upstream issue #779.
        let outcome = try decode("[bar]\nmargin = 0\n")
        t.expectEqual(outcome.config.bar.margin, Insets(all: 0))
        t.expectEqual(outcome.diagnostics.hasErrors, false)
    }

    s.test("parses suffixed durations") { t in
        t.expectEqual(ConfigReader.parseDuration("5s"), 5)
        t.expectEqual(ConfigReader.parseDuration("250ms"), 0.25)
        t.expectEqual(ConfigReader.parseDuration("2m"), 120)
        t.expectEqual(ConfigReader.parseDuration("30"), 30)
        t.expectNil(ConfigReader.parseDuration("soon"))
    }

    s.test("parses the Family:Style:Size font shorthand") { t in
        let font = try t.require(FontSpec.parse("JetBrainsMono Nerd Font:Bold:14.0"))
        t.expectEqual(font.family, "JetBrainsMono Nerd Font")
        t.expectEqual(font.style, "Bold")
        t.expectEqual(font.size, 14)
    }

    s.test("rejects a negative length with a located error") { t in
        let outcome = try decode("[bar]\nheight = -5\n")
        t.expectEqual(outcome.diagnostics.hasErrors, true)
        t.expectContains(try t.require(outcome.diagnostics.errors.first).message, "must not be negative")
    }

    s.test("reports a type mismatch rather than coercing") { t in
        let outcome = try decode("[bar]\nheight = \"tall\"\n")
        t.expectContains(try t.require(outcome.diagnostics.errors.first).message, "should be a number")
    }
}

// MARK: - Tokens

let tokenTests = Suite("Theme tokens") { s in

    s.test("substitutes a scalar token") { t in
        let outcome = try decode("""
        [theme]
        accent = "#f4d35e"
        [bar]
        color = "$accent"
        """)
        t.expectEqual(outcome.diagnostics.hasErrors, false)
        t.expectEqual(outcome.config.bar.color, try? Color.parse("#f4d35e").get())
    }

    s.test("substitutes a whole table token") { t in
        let outcome = try decode("""
        [theme.pill]
        color = "#141414"
        corner_radius = 12
        height = 24
        [[group]]
        id = "g"
        style = "$pill"
        [[group.item]]
        id = "i"
        """)
        let g = try t.require(group(outcome, "g"))
        t.expectEqual(g.style.corner.radius, 12)
        t.expectEqual(g.style.height, 24)
    }

    s.test("resolves a token that references another token") { t in
        let outcome = try decode("""
        [theme]
        base = "#141414"
        [theme.pill]
        color = "$base"
        [[item]]
        id = "i"
        [item.style]
        color = "$pill.color"
        """)
        t.expectEqual(outcome.diagnostics.hasErrors, false)
        t.expectEqual(item(outcome, "i")?.style.color, try? Color.parse("#141414").get())
    }

    s.test("a leading theme. prefix is optional") { t in
        let outcome = try decode("""
        [theme]
        accent = "#f4d35e"
        [bar]
        color = "$theme.accent"
        """)
        t.expectEqual(outcome.config.bar.color, try? Color.parse("#f4d35e").get())
    }

    s.test("an unknown token is an error naming what is available") { t in
        let outcome = try decode("""
        [theme]
        accent = "#f4d35e"
        [bar]
        color = "$acent"
        """)
        let error = try t.require(outcome.diagnostics.errors.first)
        t.expectContains(error.message, "unknown theme token '$acent'")
        t.expectContains(try t.require(error.hint), "$accent")
    }

    s.test("a token cycle is reported rather than hanging") { t in
        let outcome = try decode("""
        [theme]
        a = "$b"
        b = "$a"
        [bar]
        height = 36
        """)
        t.expect(outcome.diagnostics.hasErrors, "a cycle must be reported")
    }

    s.test("a template is not mistaken for a token") { t in
        let outcome = try decode("""
        [[item]]
        id = "coin"
        label = "${price}"
        """)
        t.expectEqual(outcome.diagnostics.hasErrors, false)
        t.expectEqual(item(outcome, "coin")?.label.template.render(["price": "42"]), "$42")
    }
}

// MARK: - Decoding

let decoderTests = Suite("Config decoding") { s in

    s.test("decodes the bar block") { t in
        let outcome = try decode("""
        [bar]
        height = 36
        edge = "top"
        offset = { x = 0, y = 4 }
        sticky = true
        topmost = "window"
        displays = "all"
        """)
        t.expectEqual(outcome.diagnostics.hasErrors, false)
        t.expectEqual(outcome.config.bar.height, 36)
        t.expectEqual(outcome.config.bar.edge, .top)
        t.expectEqual(outcome.config.bar.offset, Offset(x: 0, y: 4))
        t.expectEqual(outcome.config.bar.sticky, true)
        t.expectEqual(outcome.config.bar.topmost, .window)
        t.expectEqual(outcome.config.bar.displays, .all)
    }

    s.test("accepts 'position' as an alias for 'edge'") { t in
        t.expectEqual(try decode("[bar]\nposition = \"bottom\"\n").config.bar.edge, .bottom)
    }

    s.test("items inherit defaults and can override them") { t in
        let outcome = try decode("""
        [defaults.label]
        color = "#f1d9a4"
        padding = { left = 4, right = 10 }
        [[item]]
        id = "a"
        [[item]]
        id = "b"
        [item.label]
        color = "#ffb87c"
        """)
        t.expectEqual(item(outcome, "a")?.label.color, try? Color.parse("#f1d9a4").get())
        t.expectEqual(item(outcome, "a")?.label.padding.leading, 4)
        t.expectEqual(item(outcome, "b")?.label.color, try? Color.parse("#ffb87c").get())
        // Overriding colour must not discard inherited padding.
        t.expectEqual(item(outcome, "b")?.label.padding.leading, 4)
    }

    s.test("declaration order is render order, across items and groups alike") { t in
        let outcome = try decode("""
        [[item]]
        id = "ports"
        position = "right"
        [[group]]
        id = "coins"
        position = "right"
        [[group.item]]
        id = "c"
        [[item]]
        id = "clock"
        position = "right"
        """)
        t.expectEqual(outcome.config.nodes(at: .right).map(\.id), ["ports", "coins", "clock"])
    }

    s.test("expands a fixed repeat into one item per value") { t in
        let outcome = try decode("""
        [[group]]
        id = "coins"
        [[group.item]]
        id = "meter"
        repeat = ["c", "b", "a"]
        """)
        let g = try t.require(group(outcome, "coins"))
        t.expectEqual(g.items.map(\.id), ["meter.c", "meter.b", "meter.a"])
        t.expectEqual(g.items.map(\.repeatValue), ["c", "b", "a"])
    }

    s.test("a dynamic repeat stays a single template for the runtime to expand") { t in
        let outcome = try decode("""
        [[item]]
        id = "space"
        provider = "aerospace"
        repeat = "workspace"
        """)
        t.expectEqual(item(outcome, "space")?.repeatSource, .dynamic("workspace"))
    }

    s.test("decodes state tables, replacing shell case blocks") { t in
        let outcome = try decode("""
        [[item]]
        id = "status"
        [item.states.ON]
        label = "STATUS"
        color = "#56d364"
        [item.states.OFF]
        label = "OFF"
        color = "#6e7681"
        """)
        let status = try t.require(item(outcome, "status"))
        t.expectEqual(status.states.count, 2)
        t.expectEqual(status.states["ON"]?.label?.source, "STATUS")
        t.expectEqual(status.states["OFF"]?.color, try? Color.parse("#6e7681").get())
    }

    s.test("decodes per-button click actions") { t in
        let outcome = try decode("""
        [[item]]
        id = "status"
        [item.on_click]
        left = "status:toggle"
        right = "status:settings"
        middle = "echo hello"
        """)
        let status = try t.require(item(outcome, "status"))
        t.expectEqual(status.actions[.left], .provider(name: "status", command: "toggle"))
        t.expectEqual(status.actions[.right], .provider(name: "status", command: "settings"))
        // Upstream issue #681: middle click has no representation at all.
        t.expectEqual(status.actions[.middle], .shell("echo hello"))
    }

    s.test("decodes a popup with a dismissal policy") { t in
        let outcome = try decode("""
        [[item]]
        id = "ports"
        [item.popup]
        on = "click"
        dismiss = ["mouse_exit", "click_outside", "timeout:5s"]
        """)
        let popup = try t.require(item(outcome, "ports")?.popup)
        t.expectEqual(popup.trigger, .click)
        t.expectEqual(popup.dismiss, [.mouseExit, .clickOutside, .timeout(seconds: 5)])
    }

    s.test("a style with no height means size-to-content, not invisible") { t in
        // Upstream issue #639: a bracket without background.height disappears.
        let outcome = try decode("""
        [[group]]
        id = "pill"
        [group.style]
        color = "#141414"
        corner_radius = 12
        [[group.item]]
        id = "x"
        """)
        let g = try t.require(group(outcome, "pill"))
        t.expectNil(g.style.height, "height should stay unset")
        t.expectEqual(g.style.isVisible, true)
    }

    s.test("margin and padding are independent, unlike upstream") { t in
        // Upstream issue #796: background.padding overwrites item padding.
        let outcome = try decode("""
        [[item]]
        id = "a"
        margin = { left = 3, right = 3 }
        padding = { left = 20, right = 8 }
        [item.style]
        padding = { left = 67, right = 76 }
        """)
        let a = try t.require(item(outcome, "a"))
        t.expectEqual(a.margin.leading, 3)
        t.expectEqual(a.padding.leading, 20)
        t.expectEqual(a.style.padding.leading, 67)
    }

    s.test("reports a duplicate id") { t in
        let outcome = try decode("[[item]]\nid = \"a\"\n[[item]]\nid = \"a\"\n")
        t.expectContains(try t.require(outcome.diagnostics.errors.first).message, "duplicate id 'a'")
    }

    s.test("an item with neither id nor provider is an error") { t in
        let outcome = try decode("[[item]]\nlabel = \"orphan\"\n")
        t.expectContains(try t.require(outcome.diagnostics.errors.first).message, "needs an 'id'")
    }

    s.test("warns about an unknown key and suggests the nearest real one") { t in
        let outcome = try decode("[bar]\nheigth = 36\n")
        let warning = try t.require(outcome.diagnostics.warnings.first)
        t.expectContains(warning.message, "unknown key 'bar.heigth'")
        t.expectContains(try t.require(warning.hint), "did you mean 'height'?")
    }

    s.test("a typo is a warning, not an error, so the bar still starts") { t in
        let outcome = try decode("[bar]\nheight = 36\nwibble = 1\n")
        t.expectEqual(outcome.diagnostics.hasErrors, false)
        t.expectEqual(outcome.isUsable, true)
        t.expect(!outcome.diagnostics.warnings.isEmpty, "should warn")
    }

    s.test("collects every error in one pass rather than stopping at the first") { t in
        let outcome = try decode("""
        [bar]
        height = "tall"
        color = "not-a-colour"
        blur_radius = -3
        """)
        t.expect(outcome.diagnostics.errors.count >= 3,
                 "expected at least 3 errors, got \(outcome.diagnostics.errors.count)")
    }
}

// MARK: - End to end

let exampleConfigTests = Suite("Example config") { s in

    s.test("funkybar.toml.example parses and decodes without errors") { t in
        let url = packageRoot.appendingPathComponent("funkybar.toml.example")
        let source = try String(contentsOf: url, encoding: .utf8)
        let outcome = ConfigDecoder.decode(try TOMLParser.parse(source))

        if outcome.diagnostics.hasErrors {
            t.fail("example config has errors:\n" + outcome.diagnostics.render(path: url.path, source: source))
        }
        if !outcome.diagnostics.warnings.isEmpty {
            t.fail("example config has warnings:\n" + outcome.diagnostics.render(path: url.path, source: source))
        }
    }

    s.test("the example reproduces the current bar's layout") { t in
        let url = packageRoot.appendingPathComponent("funkybar.toml.example")
        let source = try String(contentsOf: url, encoding: .utf8)
        let outcome = ConfigDecoder.decode(try TOMLParser.parse(source))
        let config = outcome.config

        t.expectEqual(config.bar.height, 36)
        t.expectEqual(config.bar.offset.y, 4)
        t.expectEqual(config.bar.color.isTransparent, true, "the bar itself is transparent; items are pills")

        t.expectEqual(config.nodes(at: .left).map(\.id), ["workspaces_pill", "app_pill"])
        t.expectEqual(config.nodes(at: .right).map(\.id),
                      ["ports", "status", "meters_pill", "battery", "clock"])

        // The three coin pills are expanded at load; workspaces at runtime.
        let coins = try t.require(group(outcome, "meters_pill"))
        t.expectEqual(coins.items.map(\.repeatValue), ["c", "b", "a"])

        let workspaces = try t.require(group(outcome, "workspaces_pill"))
        t.expectEqual(workspaces.items.count, 1, "a dynamic repeat stays one template")
        t.expectEqual(workspaces.items.first?.repeatSource, .dynamic("workspace"))
    }

    s.test("every item that needs live data has a provider bound") { t in
        let url = packageRoot.appendingPathComponent("funkybar.toml.example")
        let source = try String(contentsOf: url, encoding: .utf8)
        let config = ConfigDecoder.decode(try TOMLParser.parse(source)).config

        let bound = Dictionary(uniqueKeysWithValues: config.allItems.map { ($0.id, $0.provider?.kind) })
        t.expectEqual(bound["clock"], "clock")
        t.expectEqual(bound["battery"], "battery")
        t.expectEqual(bound["front_app"], "frontApp")
        t.expectEqual(bound["ports"], "ports")
        t.expectEqual(bound["status"], "push")
        t.expectEqual(bound["space"], "aerospace")
        // The chevron is decoration and correctly has none.
        t.expectEqual(bound["chevron"] ?? nil, nil)
    }
}

let configSuites: [Suite] = [
    colorTests,
    templateTests,
    readerValueTests,
    tokenTests,
    decoderTests,
    exampleConfigTests,
]
