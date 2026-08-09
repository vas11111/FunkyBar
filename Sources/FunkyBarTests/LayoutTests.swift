import CoreGraphics
import Foundation
import TestKit
import FunkyBarCore

// MARK: - Helpers

/// 10pt font, 0.5 advance ratio, 1.0 line height: every glyph is 5 wide and
/// 10 tall, so expected sizes are trivial to compute by hand.
private let measurer = FixedAdvanceMeasurer(advanceRatio: 0.5, lineHeightRatio: 1.0)
private let testFont = FontSpec(family: "Test", size: 10)

private func makeItem(
    _ id: String,
    icon: String = "",
    label: String = "",
    position: Position = .left
) -> ResolvedItem {
    var item = ResolvedItem(id: id, position: position)
    item.icon = icon
    item.label = label
    item.iconFont = testFont
    item.labelFont = testFont
    return item
}

private func bar(height: Double = 40, padding: Insets = .zero) -> BarConfig {
    var config = BarConfig()
    config.height = height
    config.padding = padding
    return config
}

private func layout(
    _ nodes: [ResolvedNode],
    bar barConfig: BarConfig = bar(),
    width: Double = 1000
) -> BarLayout {
    LayoutEngine.layout(nodes: nodes, bar: barConfig, width: width, measuring: measurer)
}

private func pillStyle(height: Double? = nil, padding: Insets = .zero) -> StyleSpec {
    var style = StyleSpec()
    style.color = (try? Color.parse("#141414").get()) ?? .black
    style.corner.radius = 12
    style.height = height
    style.padding = padding
    return style
}

// MARK: - Measurement

let layoutMeasurementTests = Suite("Layout measurement") { s in

    s.test("an icon-only item is icon width plus its paddings") { t in
        var item = makeItem("a", icon: "ABC")            // 3 glyphs -> 15 wide
        item.iconPadding = Insets(horizontal: 7)         // +14
        let result = layout([.item(item)])
        t.expectEqual(try t.require(result.item("a")).frame.width, 29)
    }

    s.test("icon and label widths add, each with its own padding") { t in
        var item = makeItem("a", icon: "AB", label: "CDEF")   // 10 + 20
        item.iconPadding = Insets(leading: 10, trailing: 4)         // +14
        item.labelPadding = Insets(leading: 4, trailing: 10)        // +14
        t.expectEqual(try t.require(layout([.item(item)]).item("a")).frame.width, 58)
    }

    s.test("item padding wraps the content box") { t in
        var item = makeItem("a", label: "AB")            // 10
        item.padding = Insets(horizontal: 5)             // +10
        t.expectEqual(try t.require(layout([.item(item)]).item("a")).frame.width, 20)
    }

    s.test("a fixed width overrides measurement") { t in
        var item = makeItem("a", label: "ABCDEFGH")
        item.width = .fixed(30)
        t.expectEqual(try t.require(layout([.item(item)]).item("a")).frame.width, 30)
    }

    s.test("a hidden label contributes nothing, not even its padding") { t in
        var item = makeItem("a", icon: "AB", label: "IGNORED")
        item.labelDrawing = false
        item.labelPadding = Insets(horizontal: 50)
        t.expectEqual(try t.require(layout([.item(item)]).item("a")).frame.width, 10)
    }

    s.test("an empty item is dropped entirely") { t in
        let result = layout([.item(makeItem("ghost")), .item(makeItem("b", label: "X"))])
        t.expectNil(result.item("ghost"))
        t.expectEqual(result.items.count, 1)
    }
}

// MARK: - Ordering

let layoutOrderingTests = Suite("Layout ordering") { s in

    s.test("left items run left to right in declaration order") { t in
        let nodes: [ResolvedNode] = [
            .item(makeItem("a", label: "AA")),   // 10
            .item(makeItem("b", label: "BB")),   // 10
            .item(makeItem("c", label: "CC")),   // 10
        ]
        let result = layout(nodes, bar: bar(padding: Insets(leading: 10, trailing: 10)))
        t.expectEqual(try t.require(result.item("a")).frame.minX, 10)
        t.expectEqual(try t.require(result.item("b")).frame.minX, 20)
        t.expectEqual(try t.require(result.item("c")).frame.minX, 30)
    }

    s.test("right items also run left to right in declaration order") { t in
        // Upstream inserts right items rightmost-first, which is why a
        // sketchybarrc has to declare the right side backwards.
        let nodes: [ResolvedNode] = [
            .item(makeItem("ports", label: "AA", position: .right)),
            .item(makeItem("status", label: "BB", position: .right)),
            .item(makeItem("clock", label: "CC", position: .right)),
        ]
        let result = layout(nodes, bar: bar(padding: Insets(leading: 10, trailing: 10)), width: 1000)

        let ports = try t.require(result.item("ports"))
        let status = try t.require(result.item("status"))
        let clock = try t.require(result.item("clock"))

        t.expect(ports.frame.minX < status.frame.minX, "ports should sit left of status")
        t.expect(status.frame.minX < clock.frame.minX, "status should sit left of clock")
        // The stack ends flush against the bar's right padding.
        t.expectEqual(clock.frame.maxX, 990)
    }

    s.test("centre items are centred as a block") { t in
        let nodes: [ResolvedNode] = [
            .item(makeItem("a", label: "AA", position: .center)),
            .item(makeItem("b", label: "BB", position: .center)),
        ]
        let result = layout(nodes, width: 1000)
        t.expectEqual(try t.require(result.item("a")).frame.minX, 490)
        t.expectEqual(try t.require(result.item("b")).frame.maxX, 510)
    }

    s.test("margins separate siblings without affecting their widths") { t in
        var a = makeItem("a", label: "AA")
        a.margin = Insets(leading: 3, trailing: 3)
        var b = makeItem("b", label: "BB")
        b.margin = Insets(leading: 3, trailing: 3)

        let result = layout([.item(a), .item(b)], bar: bar(padding: .zero))
        let frameA = try t.require(result.item("a"))
        let frameB = try t.require(result.item("b"))

        t.expectEqual(frameA.frame.minX, 3)
        t.expectEqual(frameA.frame.width, 10, "margin must not change the item's own width")
        // 3 trailing + 3 leading between them.
        t.expectEqual(frameB.frame.minX, frameA.frame.maxX + 6)
    }
}

// MARK: - Groups

let layoutGroupTests = Suite("Layout groups") { s in

    s.test("a group sizes to its children with no explicit height") { t in
        // Upstream issue #639: a bracket without background.height vanishes.
        let group = ResolvedGroup(
            id: "pill",
            style: pillStyle(),
            items: [makeItem("a", label: "AA"), makeItem("b", label: "BB")]
        )
        let result = layout([.group(group)])
        let frame = try t.require(result.group("pill"))

        t.expectEqual(frame.frame.width, 20)
        t.expectEqual(frame.background.width, 20, "the background must be drawn, not collapsed")
        t.expectEqual(frame.background.height, 10)
    }

    s.test("an explicit style height wins and stays vertically centred") { t in
        let group = ResolvedGroup(id: "pill", style: pillStyle(height: 24), items: [makeItem("a", label: "AA")])
        let frame = try t.require(layout([.group(group)], bar: bar(height: 40)).group("pill"))
        t.expectEqual(frame.background.height, 24)
        t.expectEqual(frame.background.midY, 20)
    }

    s.test("group padding insets its children") { t in
        let group = ResolvedGroup(
            id: "pill",
            padding: Insets(horizontal: 7),
            items: [makeItem("a", label: "AA")]
        )
        let result = layout([.group(group)], bar: bar(padding: .zero))
        t.expectEqual(try t.require(result.group("pill")).frame.width, 24)
        t.expectEqual(try t.require(result.item("a")).frame.minX, 7)
    }

    s.test("a group's box includes its children's outer margins") { t in
        // Measured from sketchybar's own item windows, which are readable from
        // the window server: the workspaces bracket sits at x=10 w=195 with its
        // first child at x=13 and the last ending at 202. The bracket extends
        // 3pt past the children on each side, which is exactly the children's
        // margin. An earlier version of this test asserted the opposite, on a
        // misreading of the sketchybarrc comment about brackets swallowing
        // member margins.
        var a = makeItem("a", label: "AA")          // 10 wide
        a.margin = Insets(leading: 4, trailing: 4)
        var b = makeItem("b", label: "BB")          // 10 wide
        b.margin = Insets(leading: 4, trailing: 4)

        let group = ResolvedGroup(id: "pill", margin: Insets(leading: 10, trailing: 10), items: [a, b])
        let result = layout([.group(group)], bar: bar(padding: .zero))

        let groupFrame = try t.require(result.group("pill"))
        let frameA = try t.require(result.item("a"))
        let frameB = try t.require(result.item("b"))

        t.expectEqual(groupFrame.frame.minX, 10, "the group's own margin positions it")
        t.expectEqual(groupFrame.frame.width, 36, "4 + 10 + 4 twice")
        t.expectEqual(frameA.frame.minX - groupFrame.frame.minX, 4, "child margin inset at the leading edge")
        t.expectEqual(groupFrame.frame.maxX - frameB.frame.maxX, 4, "and at the trailing edge")
        t.expectEqual(frameB.frame.minX - frameA.frame.maxX, 8, "interior gap is 4 + 4")
    }

    s.test("a lone child is still inset by its own margin") { t in
        var only = makeItem("a", label: "AA")       // 10 wide
        only.margin = Insets(leading: 7, trailing: 7)

        let group = ResolvedGroup(id: "pill", items: [only])
        let result = layout([.group(group)], bar: bar(padding: .zero))

        t.expectEqual(try t.require(result.group("pill")).frame.width, 24, "7 + 10 + 7")
        t.expectEqual(try t.require(result.item("a")).frame.minX, 7)
    }

    s.test("group padding stacks on top of child margins") { t in
        // How a group reproduces a per-item `padding_left=6` without per-clone
        // overrides: group padding 3 plus the inherited child margin 3 gives
        // the same 6pt inset.
        var only = makeItem("a", label: "AA")
        only.margin = Insets(leading: 3, trailing: 3)

        let group = ResolvedGroup(id: "pill", padding: Insets(leading: 3, trailing: 3), items: [only])
        let result = layout([.group(group)], bar: bar(padding: .zero))

        let groupFrame = try t.require(result.group("pill"))
        t.expectEqual(groupFrame.frame.width, 22, "3 + 3 + 10 + 3 + 3")
        t.expectEqual(try t.require(result.item("a")).frame.minX - groupFrame.frame.minX, 6)
    }

    s.test("a group reports its children in order") { t in
        let group = ResolvedGroup(
            id: "pill",
            items: [makeItem("a", label: "A"), makeItem("b", label: "B"), makeItem("c", label: "C")]
        )
        t.expectEqual(try t.require(layout([.group(group)]).group("pill")).itemIDs, ["a", "b", "c"])
    }

    s.test("a group with no visible children is dropped") { t in
        let group = ResolvedGroup(id: "empty", style: pillStyle(), items: [makeItem("ghost")])
        t.expectNil(layout([.group(group)]).group("empty"))
    }

    s.test("group spacing sits between children only") { t in
        let group = ResolvedGroup(
            id: "pill",
            spacing: 6,
            items: [makeItem("a", label: "AA"), makeItem("b", label: "BB")]
        )
        let result = layout([.group(group)], bar: bar(padding: .zero))
        t.expectEqual(try t.require(result.group("pill")).frame.width, 26)
        t.expectEqual(try t.require(result.item("b")).frame.minX, 16)
    }
}

// MARK: - Backgrounds

let layoutBackgroundTests = Suite("Layout backgrounds") { s in

    s.test("style padding expands the background beyond the content") { t in
        var item = makeItem("a", label: "AA")
        item.style = pillStyle(padding: Insets(horizontal: 8, vertical: 4))

        let frame = try t.require(layout([.item(item)], bar: bar(padding: .zero)).item("a"))
        t.expectEqual(frame.frame.width, 10)
        t.expectEqual(frame.background.width, 26)
        t.expectEqual(frame.background.height, 18)
        t.expectEqual(frame.background.minX, -8, "the background overhangs the content box")
    }

    s.test("an invisible style produces no background rect") { t in
        var item = makeItem("a", label: "AA")
        item.style.drawing = false
        t.expectEqual(try t.require(layout([.item(item)]).item("a")).background, .zero)
    }

    s.test("style padding does not disturb item padding") { t in
        // Upstream issue #796: background.padding overwrites item padding.
        var item = makeItem("a", label: "AA")
        item.padding = Insets(horizontal: 5)
        item.style = pillStyle(padding: Insets(horizontal: 20))

        let frame = try t.require(layout([.item(item)]).item("a"))
        t.expectEqual(frame.frame.width, 20, "item padding still applies")
        t.expectEqual(frame.background.width, 60, "style padding applies on top")
    }
}

// MARK: - Vertical placement

let layoutVerticalTests = Suite("Layout vertical placement") { s in

    s.test("items are centred on the bar") { t in
        let frame = try t.require(layout([.item(makeItem("a", label: "AA"))], bar: bar(height: 40)).item("a"))
        t.expectEqual(frame.frame.midY, 20)
    }

    s.test("the bar offset moves the bar, not the content inside it") { t in
        // sketchybar's y_offset positions the bar window: its windows sit at
        // screen y=4 with y_offset=4. Applying it to the contents instead left
        // every pill 8pt high on screen while every item still agreed with
        // every other item, so per-item comparison could never see it.
        var config = bar(height: 40)
        config.offset = Offset(x: 0, y: 4)

        let withOffset = try t.require(layout([.item(makeItem("a", label: "AA"))], bar: config).item("a"))
        let without = try t.require(layout([.item(makeItem("a", label: "AA"))], bar: bar(height: 40)).item("a"))

        t.expectEqual(withOffset.frame.midY, 20, "content stays centred in the bar")
        t.expectEqual(withOffset.frame.midY, without.frame.midY,
                      "the bar offset must not move content relative to the bar")
    }

    s.test("a per-item offset applies on both axes") { t in
        var item = makeItem("a", label: "AA")
        item.offset = Offset(x: 5, y: -2)
        let frame = try t.require(layout([.item(item)], bar: bar(height: 40, padding: .zero)).item("a"))
        t.expectEqual(frame.frame.minX, 5)
        t.expectEqual(frame.frame.midY, 18)
    }

    s.test("icon and label are individually centred and offsettable") { t in
        var item = makeItem("a", icon: "AB", label: "CD")
        item.iconOffset = Offset(x: 0, y: 3)
        let frame = try t.require(layout([.item(item)], bar: bar(height: 40)).item("a"))
        t.expectEqual(frame.icon.midY, 23)
        t.expectEqual(frame.label.midY, 20)
    }
}

// MARK: - Resolution

let resolverTests = Suite("Item resolution") { s in

    s.test("renders templates from provider values") { t in
        var config = ItemConfig(id: "clock")
        config.label.template = Template("{time}  {date}")
        let resolved = ItemResolver.resolve(config, values: ["time": "09:41", "date": "Fri 08"])
        t.expectEqual(resolved.label, "09:41  Fri 08")
    }

    s.test("a state overrides icon, label and colour") { t in
        var config = ItemConfig(id: "status")
        config.label.template = Template("unset")
        var state = StateSpec()
        state.label = Template("STATUS")
        state.color = try? Color.parse("#56d364").get()
        config.states["ON"] = state

        let resolved = ItemResolver.resolve(config, values: ["state": "ON"])
        t.expectEqual(resolved.label, "STATUS")
        t.expectEqual(resolved.labelColor, try? Color.parse("#56d364").get())
        t.expectEqual(resolved.iconColor, try? Color.parse("#56d364").get())
    }

    s.test("a specific state colour beats the general one") { t in
        var config = ItemConfig(id: "space")
        var state = StateSpec()
        state.color = try? Color.parse("#111111").get()
        state.iconColor = try? Color.parse("#f4d35e").get()
        config.states["active"] = state

        let resolved = ItemResolver.resolve(config, values: ["state": "active"])
        t.expectEqual(resolved.iconColor, try? Color.parse("#f4d35e").get())
        t.expectEqual(resolved.labelColor, try? Color.parse("#111111").get())
    }

    s.test("truncation counts grapheme clusters, not bytes") { t in
        // Upstream issue #784 cuts CJK mid-character.
        t.expectEqual(ItemResolver.truncate("日本語テキスト", to: 3), "日本語…")
        t.expectEqual(ItemResolver.truncate("hello", to: 10), "hello")
        t.expectEqual(ItemResolver.truncate("hello", to: 0), "hello")
    }

    s.test("a repeat value is addressable as {repeat}") { t in
        var config = ItemConfig(id: "meter.b")
        config.repeatValue = "b"
        config.label.template = Template("{repeat}")
        t.expectEqual(ItemResolver.resolve(config).label, "b")
    }
}

let configResolverTests = Suite("Config resolution") { s in

    s.test("expands a dynamic repeat from what the provider reports") { t in
        var template = ItemConfig(id: "space")
        template.repeatSource = .dynamic("workspace")
        template.icon.template = Template("{workspace}")

        var config = Config()
        config.nodes = [.group({
            var group = GroupConfig(id: "workspaces")
            group.items = [template]
            return group
        }())]

        let inputs = ConfigResolver.Inputs(repeats: ["space": ["1", "2", "3"]])
        let nodes = ConfigResolver.resolve(config, inputs: inputs)

        guard case .group(let group) = nodes[0] else {
            t.fail("expected a group")
            return
        }
        t.expectEqual(group.items.map(\.id), ["space.1", "space.2", "space.3"])
        t.expectEqual(group.items.map(\.icon), ["1", "2", "3"])
    }

    s.test("a workspace that empties disappears on the next report") { t in
        // Upstream issue #754: the item persists until a manual reload.
        var template = ItemConfig(id: "space")
        template.repeatSource = .dynamic("workspace")
        template.icon.template = Template("{workspace}")

        var config = Config()
        config.nodes = [.item(template)]

        let before = ConfigResolver.resolve(config, inputs: .init(repeats: ["space": ["1", "2", "3"]]))
        let after = ConfigResolver.resolve(config, inputs: .init(repeats: ["space": ["1", "3"]]))

        guard case .group(let a) = before[0], case .group(let b) = after[0] else {
            t.fail("expected implicit groups")
            return
        }
        t.expectEqual(a.items.map(\.id), ["space.1", "space.2", "space.3"])
        t.expectEqual(b.items.map(\.id), ["space.1", "space.3"])
    }

    s.test("per-clone values win over shared template values") { t in
        var template = ItemConfig(id: "space")
        template.repeatSource = .dynamic("workspace")
        template.label.template = Template("{state}")

        var config = Config()
        config.nodes = [.item(template)]

        let inputs = ConfigResolver.Inputs(
            values: ["space": ["state": "inactive"], "space.2": ["state": "active"]],
            repeats: ["space": ["1", "2"]]
        )
        guard case .group(let group) = ConfigResolver.resolve(config, inputs: inputs)[0] else {
            t.fail("expected a group")
            return
        }
        t.expectEqual(group.items.map(\.label), ["inactive", "active"])
    }

    s.test("an unreported dynamic repeat renders nothing rather than a placeholder") { t in
        var template = ItemConfig(id: "space")
        template.repeatSource = .dynamic("workspace")

        var config = Config()
        config.nodes = [.item(template)]

        guard case .group(let group) = ConfigResolver.resolve(config)[0] else {
            t.fail("expected a group")
            return
        }
        t.expectEqual(group.items.isEmpty, true)
    }
}

// MARK: - End to end

let layoutIntegrationTests = Suite("Layout integration") { s in

    s.test("the example config lays out with both sides in visual order") { t in
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("funkybar.toml.example")
        let source = try String(contentsOf: url, encoding: .utf8)
        let config = ConfigDecoder.decode(try TOMLParser.parse(source)).config

        let inputs = ConfigResolver.Inputs(
            values: [
                "clock": ["time": "09:41", "date": "Fri 08"],
                "front_app": ["name": "Ghostty"],
                "battery": ["percent": "80", "state": "charging", "icon": "B"],
                "ports": ["state": "idle", "label": "IDLE"],
                "space": ["state": "inactive"],
                "space.2": ["state": "active"],
            ],
            repeats: ["space": ["1", "2", "3", "4", "5", "6", "7"]]
        )

        let nodes = ConfigResolver.resolve(config, inputs: inputs)
        let result = LayoutEngine.layout(
            nodes: nodes, bar: config.bar, width: 1512, measuring: measurer
        )

        // Seven workspaces expanded from one template.
        let workspaces = try t.require(result.group("workspaces_pill"))
        t.expectEqual(workspaces.itemIDs.count, 7)
        t.expectEqual(workspaces.itemIDs.first, "space.1")

        // The active workspace picked up its state colour.
        t.expectEqual(
            try t.require(nodes.compactMap { node -> ResolvedItem? in
                guard case .group(let g) = node else { return nil }
                return g.items.first { $0.id == "space.2" }
            }.first).iconColor,
            try? Color.parse("#f4d35e").get()
        )

        // Right side reads ports, status, coins, battery, clock, left to right.
        let order = ["ports", "battery", "clock"]
        var lastX = -Double.infinity
        for id in order {
            let x = result.item(id)?.frame.minX ?? result.group(id)?.frame.minX
            let minX = try t.require(x, "no frame for \(id)")
            t.expect(minX > lastX, "\(id) should sit right of the previous item")
            lastX = minX
        }

        // Nothing overflows the display.
        for frame in result.items {
            t.expect(frame.frame.minX >= 0, "\(frame.id) starts off-screen at \(frame.frame.minX)")
            t.expect(frame.frame.maxX <= 1512, "\(frame.id) overflows at \(frame.frame.maxX)")
        }
    }
}

let hitTestTests = Suite("Hit testing") { s in

    s.test("a point inside an item returns that item") { t in
        var a = makeItem("a", label: "AAAA")   // 20 wide
        a.style = pillStyle(height: 24)
        let result = layout([.item(a)], bar: bar(height: 40, padding: .zero))
        let frame = try t.require(result.item("a"))

        t.expectEqual(result.hitTest(CGPoint(x: frame.frame.midX, y: 20)), "a")
    }

    s.test("the background box is clickable, not just the text box") { t in
        // The pill is 24 tall but the text is only 10, so most of the visible
        // target is background. Hit testing only the content box would make the
        // top and bottom of every pill dead.
        var a = makeItem("a", label: "AAAA")
        a.style = pillStyle(height: 24, padding: Insets(horizontal: 8))
        let result = layout([.item(a)], bar: bar(height: 40, padding: .zero))
        let frame = try t.require(result.item("a"))

        t.expect(frame.background.height > frame.frame.height, "precondition: pill is taller than its text")
        t.expectEqual(result.hitTest(CGPoint(x: frame.background.midX, y: frame.background.minY + 2)), "a")
        t.expectEqual(result.hitTest(CGPoint(x: frame.background.minX + 2, y: 20)), "a",
                      "style padding is part of the target")
    }

    s.test("a point outside every item returns nothing") { t in
        let result = layout([.item(makeItem("a", label: "AA"))], bar: bar(height: 40, padding: .zero))
        t.expectNil(result.hitTest(CGPoint(x: 500, y: 20)))
        t.expectNil(result.hitTest(CGPoint(x: 5, y: 39)), "above the pill")
    }

    s.test("each item in a group is individually addressable") { t in
        // Every workspace number has to be separately clickable, since each one
        // switches to a different workspace.
        let group = ResolvedGroup(
            id: "pill",
            items: (1 ... 7).map { makeItem("space.\($0)", icon: "\($0)") }
        )
        let result = layout([.group(group)], bar: bar(height: 40, padding: .zero))

        for n in 1 ... 7 {
            let frame = try t.require(result.item("space.\(n)"))
            t.expectEqual(result.hitTest(CGPoint(x: frame.frame.midX, y: 20)), "space.\(n)")
        }
    }

    s.test("the right side is hit-testable at its real coordinates") { t in
        // A regression guard for coordinate-space mistakes: right-anchored
        // items sit near the far edge, so an origin or flip error shows up here
        // long before it shows up on the left.
        var clock = makeItem("clock", label: "19:13  Sat 08", position: .right)
        clock.style = pillStyle(height: 24)
        let result = layout([.item(clock)], bar: bar(height: 40, padding: Insets(leading: 10, trailing: 10)), width: 1512)
        let frame = try t.require(result.item("clock"))

        t.expect(frame.frame.minX > 1300, "clock should be near the right edge, got \(frame.frame.minX)")
        t.expectEqual(result.hitTest(CGPoint(x: frame.frame.midX, y: 20)), "clock")
        t.expectNil(result.hitTest(CGPoint(x: frame.frame.minX - 30, y: 20)))
    }
}

let layoutSuites: [Suite] = [
    hitTestTests,
    layoutMeasurementTests,
    layoutOrderingTests,
    layoutGroupTests,
    layoutBackgroundTests,
    layoutVerticalTests,
    resolverTests,
    configResolverTests,
    layoutIntegrationTests,
]
