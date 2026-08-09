# funkybar

A status bar for macOS, written in Swift. A reimplementation of
[SketchyBar](https://github.com/FelixKratz/SketchyBar) with the same
capabilities, a declarative config, and native providers in place of shell
plugins.

> **Status: early.** It renders a full bar, matches SketchyBar's geometry to the
> point, and runs as a launchd agent. Several SketchyBar features are not built
> yet — see [what's missing](#not-built-yet). Treat it as usable-if-you-are-
> curious, not as a drop-in replacement.

---

## Why

SketchyBar drives everything through shell plugins, and creates one window per
bar item. Both choices cost more than they need to.

Measured on an M5 Max running macOS 26.6, comparing the same bar contents:

| | SketchyBar | funkybar |
| --- | --- | --- |
| Sustained CPU | 2.3% of one P-core | 0.167% |
| Process spawns | ~190,000/day | ~0 for built-in providers |
| Memory (phys_footprint) | 36 MB | 13 MB |
| Windows on screen | 1 per item (15-40) | 1 per display |
| Listening-port scan | 94 ms (`lsof`) | 2.7 ms (`proc_pidinfo`) |
| Workspace repaint | 7 forks + 7 IPC calls | 0 subprocesses, straight from the event |

Full method and the two targets not yet met are in [BENCHMARK.md](docs/BENCHMARK.md).

Most of that comes from one decision: state is read in-process rather than by
forking a shell. A port list comes from `proc_pidinfo`, battery from an
`IOPSNotification` run-loop source, workspaces from `aerospace subscribe`
held open as a stream. Interval providers share a single coalescing timer, and
everything suspends when the screens sleep.

The single-window layer tree is the other half. One `CATransaction` per update
means the compositor never sees a partially updated bar.

## Install

Requires macOS 26 (Tahoe) or later on Apple Silicon, and Swift 6.3 or later.
Command Line Tools is sufficient; full Xcode is not needed.

```sh
git clone https://github.com/vas11111/FunkyBar.git
cd FunkyBar
swift build -c release

mkdir -p ~/.config/funkybar
cp funkybar.toml.example ~/.config/funkybar/funkybar.toml

.build/release/funkybard --check      # validate the config
.build/release/funkybard              # run it
```

To run it at login, install a launch agent pointing at the binary and your
config, with `RunAtLoad` and `KeepAlive` set.

## Configure

One TOML file. Items declare what they show and which provider feeds them;
declaration order is left-to-right order on both sides of the bar.

```toml
[bar]
height = 36
offset = { x = 0, y = 4 }

[theme]
accent = "#f4d35e"
text   = "#f1d9a4"

[[item]]
id       = "clock"
position = "right"
provider = "clock"

  [item.label]
  text = "{time}  {date}"

  [item.provider]
  kind = "clock"
  time = "HH:mm"
  date = "EEE dd"
```

Two substitution syntaxes, deliberately distinct: `$name` is a theme token
substituted once at load, and `{field}` is a provider value substituted on every
update. See [funkybar.toml.example](funkybar.toml.example) for a complete,
commented starting config.

Config errors are located and collected, so one run reports everything wrong:

```
funkybar.toml:12:9: error: 'bar.color' is not a valid colour: colour must start with '#' or '0x'
   |
12 | color = "nope"
   |         ^
   = hint: example: #f4d35e, #ff141414, or 0xfff4d35e
```

Unknown keys are warnings with a "did you mean", so a typo never stops the bar
from starting.

## Providers

| Provider | Source | Cost |
| --- | --- | --- |
| `clock` | `DateFormatter` on the shared timer | one call per minute |
| `battery` | `IOPSNotificationCreateRunLoopSource` | event-driven, no polling |
| `frontApp` | `NSWorkspace` notification | event-driven |
| `aerospace` | `aerospace subscribe`, held open | event-driven, one process |
| `ports` | `proc_listpids` + `proc_pidinfo` | in-process, no fork |
| `push` | a file another program writes, watched | event-driven |

`push` is the escape hatch: point it at a status file some other program already
maintains and the bar follows it, with named commands a click can invoke. No
changes needed in the other program.

## Tooling

```sh
swift run funkybar-test            # the test suite
.build/release/funkybard --check   # validate a config, no display needed
.build/release/funkybard --dump    # what every item will draw, with codepoints
.build/release/funkybard --capture PATH   # render the bar to a PNG
.build/release/funkybar-measure    # compare geometry and style against a running sketchybar
.build/release/funkybar-diff PNG   # pixel-diff two bars in one screenshot
```

The last two exist because comparing *reported* values missed several real
bugs: clipped glyphs, a doubled pen offset, the whole bar eight points high.
Every one of those left all reported values correct.

## Not built yet

- Socket IPC and the `funkybar` CLI (`reload`, `query`, `set`, `push`, `watch`)
- A `command` provider for arbitrary shell one-liners
- Graphs, sliders, now-playing media, menu-bar item mirroring
- Vertical bars, blur, inverted corners

Config options for unbuilt features warn rather than decoding silently:

```
funkybar.toml:3:15: warning: 'bar.blur_radius' has no effect: blur is not implemented yet
```

## Relationship to SketchyBar

funkybar is a reimplementation, not a fork: no SketchyBar code is copied
verbatim, and the architecture is deliberately different. It is nonetheless
**derived work**. Parts of the rendering were written by reading SketchyBar's
source in order to match it exactly:

- Text width: ink bounds via `kCTLineBoundsUseGlyphPathBounds`, then
  `floor(width + 1.5)` (`src/text.c`)
- Baseline placement: `(uint32_t)(y - (ascent - descent) / 2)`, truncated
  (`src/text.c`)
- Background bounds and the inset-then-stroke rule (`src/background.c`)
- Font smoothing disabled on the drawing context (`src/context.c`)

Those details are why the two bars measure identical, and they are the reason
this project is GPLv3 rather than permissively licensed.

Thanks to [Felix Kratz](https://github.com/FelixKratz) for SketchyBar, which is
both the reference and the reason this was worth writing.

## Documents

- [docs/STATUS.md](docs/STATUS.md) — what runs today and what does not
- [docs/BENCHMARK.md](docs/BENCHMARK.md) — measurements and method
- [docs/ISSUE-TRIAGE.md](docs/ISSUE-TRIAGE.md) — every open SketchyBar issue, and
  whether this design addresses it
- [PLAN.md](PLAN.md) — the original architecture plan
- [CONTRIBUTING.md](CONTRIBUTING.md) — commit convention and branching

## License

GPLv3. See [LICENSE](LICENSE).
