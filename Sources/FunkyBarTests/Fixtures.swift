import Foundation
import FunkyBarCore

/// A config that exercises the features the regression tests care about,
/// owned by the tests rather than borrowed from the shipped example.
///
/// The example config is documentation: it should stay generic and is free to
/// change. Assertions about specific glyphs, provider commands and seed
/// splitting need a fixture that will not move under them, and that carries no
/// one user's application paths.
enum Fixture {

    /// Nerd font codepoints, written as escapes so a 5-hex-digit scalar cannot
    /// be truncated to 4 the way the real config's once were.
    static let network = "\u{F048D}"
    static let shieldOn = "\u{F099D}"
    static let shieldOff = "\u{F099E}"
    static let batteryRamp = ["\u{F0083}", "\u{F007B}", "\u{F007E}", "\u{F0080}", "\u{F0082}"]
    static let batteryCharging = "\u{F0084}"

    static let toml = """
    [bar]
    height = 36
    offset = { x = 0, y = 4 }
    padding = { left = 10, right = 10 }

    [theme]
    pill_bg = "#141414"
    accent  = "#f4d35e"
    text    = "#f1d9a4"
    ok      = "#56d364"
    idle    = "#6e7681"

    [theme.pill]
    color         = "$pill_bg"
    corner_radius = 12
    height        = 24

    [defaults]
    margin = { left = 3, right = 3 }

    [defaults.icon]
    font    = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 14 }
    color   = "$text"
    padding = { left = 10, right = 4 }

    [defaults.label]
    font    = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 12 }
    color   = "$text"
    padding = { left = 4, right = 10 }

    [defaults.style]
    color         = "$pill_bg"
    corner_radius = 12
    height        = 24

    [[item]]
    id       = "ports"
    position = "right"
    icon     = "\(network)"

      [item.label]
      text = "{label}"

      [item.provider]
      kind  = "ports"
      ports = [3000, 5173]
      watch = []

      [item.popup]
      on   = "click"
      rows = "columns"

    [[item]]
    id       = "toggle"
    position = "right"

      [item.provider]
      kind      = "push"
      channel   = "toggle"
      seed_file = "/tmp/funkybar-test-state"

        [item.provider.commands]
        flip = "echo flip > /tmp/funkybar-test-command"

      [item.on_click]
      left = "toggle:flip"

      [item.states.ON]
      icon  = "\(shieldOn)"
      label = "ON"
      color = "$ok"

      [item.states.OFF]
      icon  = "\(shieldOff)"
      label = "OFF"
      color = "$idle"

    [[group]]
    id       = "meters"
    position = "right"
    style    = "$pill"
    padding  = { left = 3, right = 3 }

      [[group.item]]
      id     = "meter"
      repeat = ["a", "b", "c"]

        [group.item.provider]
        kind       = "push"
        channel    = "meters"
        seed_file  = "/tmp/funkybar-test-meters"
        seed_keys  = ["a", "b", "c"]
        seed_field = "value"

        [group.item.label]
        text = "${value}"

        [group.item.style.image]
        path  = "/tmp/funkybar-icons/{repeat}.png"
        scale = 0.38

    [[item]]
    id       = "battery"
    position = "right"

      [item.icon]
      text = "{icon}"

      [item.label]
      text = "{percent}%"

      [item.provider]
      kind     = "battery"
      ramp     = ["\(batteryRamp[0])", "\(batteryRamp[1])", "\(batteryRamp[2])", "\(batteryRamp[3])", "\(batteryRamp[4])"]
      charging = "\(batteryCharging)"
    """

    static func decoded() throws -> ConfigDecoder.Outcome {
        ConfigDecoder.decode(try TOMLParser.parse(toml))
    }

    static func config() throws -> Config {
        try decoded().config
    }

    static func item(_ id: String) throws -> ItemConfig? {
        try config().allItems.first { $0.id == id }
    }
}
