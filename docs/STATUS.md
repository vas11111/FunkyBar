# Status

Updated 2026-08-08.

M1 is running. The bar draws on both displays from native providers, with no
shell plugins. What follows is what works, what was measured, and what is not
built yet.

## Try it

```sh
swift build -c release

# Validate a config without touching the display (works over ssh).
.build/release/funkybard --config funkybar.toml.example --check

# Verify the bar is really on screen, then exit.
.build/release/funkybard --selftest

# Run it for 30 seconds alongside your existing sketchybar.
cp funkybar.toml.example ~/.config/funkybar/funkybar.toml
.build/release/funkybard --duration 30

# Tests.
swift run funkybar-test            # all
swift run funkybar-test "ports"    # filtered
```

`funkybar.toml.example` is a full port of the current `sketchybarrc`. It is
decoded end-to-end by the suite, so it cannot silently rot.

## Built and tested

| Area | State |
| --- | --- |
| TOML parser | Hand-written, no dependency. Tables, arrays of tables, dotted keys, inline tables, multi-line strings, all integer radices. Datetimes rejected explicitly. |
| Diagnostics | Compiler-style, with the source line and a caret. Collected, not thrown at the first error. |
| Config schema | Bar, theme tokens, defaults, items, groups, states, actions, popups, `repeat`. Unknown keys warn with a "did you mean". |
| Layout engine | Measure-then-arrange, headless. Groups are real containers. Declaration order is visual order on both sides. |
| Render | One `NSPanel` per display, one `CALayer` tree, one `CATransaction` per update, diffed. CoreText shaping with explicit baselines. |
| Providers | `clock`, `frontApp`, `battery`, `aerospace`, `ports`, `push`. |
| Timer wheel | One `DispatchSourceTimer` at the GCD of all intervals, 20% leeway, suspended on sleep. |
| Process runner | `posix_spawn` with `POSIX_SPAWN_SETSID`, concurrent pipe drain, hard deadline, concurrency cap. |
| Daemon | Hot reload following symlinks, sleep/wake suspension, coalesced redraws, `--check`, `--selftest`, `--dump`, `--capture`. |
| Popups | Rows from providers, kill actions, dismissal on mouse-exit / click-outside / timeout, anchored to the display clicked on. |

192 tests, all passing.

## Measured

Benchmarks from the suite and from the running daemon, on this machine
(M5 Max, macOS 26.6).

| | SketchyBar today | funkybar M1 |
| --- | --- | --- |
| Listening-port scan | 94 ms (`lsof` + 2 `pgrep` + `awk` + `sort`) | **2.72 ms** (`proc_pidinfo`) |
| Workspace switch | 7 forks, 7 AeroSpace IPC calls, 147 ms | 1 query, all layers in one transaction |
| Timers | ~25 uncoalesced wakeups/min | 4 providers on **one 5 s tick** |
| Windows | 1 SkyLight window **per item** (15-40) | **1 per display** (2 here) |

The window count is verified by the window server itself, not inferred:

```
$ funkybard --selftest
AppKit windows: 2
  frame=(0,1293 2056x36) level=25 visible=true opaque=false
  frame=(-1041,3453 3840x36) level=25 visible=true opaque=false
window server: 2 window(s) owned by this process
  ok  the server reports it on screen
  ok  one window per display, not one per item: 2 window(s) for 2 display(s)
all checks passed
```

### Standing cost

| | SketchyBar today | funkybar M1 |
| --- | --- | --- |
| CPU, sustained | 2.3% of one P-core | **0.117%** (20x less) |
| Memory, phys_footprint | 36 MB | **12 MB** (3x less) |

The plan's CPU target was under 0.05%, so this is close but **not there yet**.
The expected culprit was the `aerospace` subprocess poll, but relaxing it from
5 s to 60 s measured no improvement, so it is not the cost. About half the
remainder is the `ports` scan running every 5 s, an interval that is arbitrary
and easy to raise. See [BENCHMARK.md](BENCHMARK.md) for the method, the
isolation experiment, and the paths to closing the gap.

## Not built yet

Everything here is planned, not missing by accident. Config options for
unbuilt features now emit a warning naming the gap, rather than decoding
silently and doing nothing.

- ~~Popups.~~ **Built.** The ports popup draws, lists live ports and
  watched processes, and its rows kill what they name.
- **Socket IPC and the `funkybar` CLI.** `push` providers seed from a file but
  have nothing to receive from yet, so `status` and `meter` show their seeded
  or empty state. This is the next piece of work.
- **`command` provider.** `ProcessRunner` underneath it is built and tested;
  the provider wrapper is not wired.
- **M3 parity items**: graphs, sliders, `alias` menu-bar mirroring, media,
  native Spaces, vertical bars, animations.

## Open decisions for you

1. **The fullscreen spike is unresolved.** The panel uses
   `.canJoinAllSpaces + .stationary` and is verified on screen, but whether it
   draws over a *native fullscreen* app on 26.6 needs a human to look at it.
   Open something fullscreen, run `funkybard --duration 30`, and see. If it is
   hidden, set `show_in_fullscreen = true` under `[bar]` and retry; if it is
   still hidden, `SkyLightSurface.elevate` becomes the default path as the plan
   anticipated.

2. **The AeroSpace push hook is not installed.** Adding this to
   `~/.config/aerospace/aerospace.toml` makes workspace switches instant and
   lets the poll relax to a minute, but it edits your config, so it is left for
   you:

   ```toml
   exec-on-workspace-change = ['/bin/bash', '-c',
     'funkybar push aerospace focused=$AEROSPACE_FOCUSED_WORKSPACE']
   ```

   It needs the socket layer first, so it is not useful yet.

3. **Test framework.** XCTest and swift-testing both ship inside Xcode, so
   `swift test` cannot link on this machine (`ld: library '_TestingInterop' not
   found`). `Sources/TestKit` is a small harness with a swift-testing-shaped
   API; the suites port by find-and-replace if you ever install Xcode. Say the
   word if you would rather install Xcode and use the real thing.

## Nothing was removed

sketchybar is untouched and still running. funkybar reads
`~/.config/funkybar/funkybar.toml`; sketchybar reads `~/.config/sketchybar`.
Both can run at once, which is how the port was checked.
