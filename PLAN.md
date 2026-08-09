# funkybar

A Swift rewrite of SketchyBar: same capabilities, one tenth the moving parts,
measurably cheaper on battery and memory, and free of the structural bugs that
generate most of upstream's open issue list.

Target: macOS 26 (Tahoe) and later, Apple Silicon, SIP enabled.

---

## 1. What exists today

### 1.1 Upstream SketchyBar

Cloned at `../SketchyBar`, at `6284ee8` (v2.24.0, 2026-06-04).

| Metric | Value |
| --- | --- |
| Source | 12,437 lines of C / Objective-C across 62 files |
| Largest units | `bar_item.c` 1267, `bar_manager.c` 1127, `message.c` 781, `text.c` 586 |
| Config surface | 164 string keywords parsed by hand in `message.c` |
| Open issues | 57 |
| Private frameworks | SkyLight, DisplayServices, MediaRemote |

The architecture that matters:

- **One SkyLight window per bar item.** `window.c` calls
  `SLSNewWindowWithOpaqueShapeAndContext` for every item, every popup, and every
  popup row. A typical config has 15 to 40 live windows per display, each with its
  own backing surface at 2x scale, each moved and resized independently.
- **Manual update batching.** `windows_freeze()` / `windows_unfreeze()` wrap
  changes in `SLSDisableUpdate` plus a `SLSTransaction`. Three separate code paths
  exist for macOS 12 / 13 / 14 / 26.
- **Mach OOL messaging** for the CLI and for pushing script output back, with
  `MACH_MSG_TIMEOUT_NONE` on both sides.
- **`vfork()` + `execvp("/usr/bin/env sh -c ...")`** for every script invocation,
  with no `setsid()`.
- **Config is an executable shell script** run once at startup; all dynamic
  behaviour is shelled out from there.

### 1.2 The configuration measured

`~/.config/sketchybar` is a symlink into `dotfiles/sketchybar`. It contains a
217-line `sketchybarrc` and 15 bash plugins totalling 321 lines.

Items in play:

| Item | Mechanism | Cost |
| --- | --- | --- |
| 7 aerospace workspaces | `aerospace_workspace_change` event, one script per item | 7 forks + 7 AeroSpace IPC calls per switch |
| front app | `front_app_switched` event | 1 fork per switch |
| clock | `update_freq=10` | 3 execs every 10s |
| battery | `update_freq=120` + power events | 7 execs every 120s |
| 3 push-driven pills | `update_freq=60` + a push event from an external app | 2 execs each per minute |
| status toggle | `update_freq=30` + a push event from an external app | 3 execs every 30s |
| ports | `update_freq=5` | 8 execs every 5s, including `lsof` and `python3` |

Three brackets (workspaces, front app, and a repeated group), one popup built
by regenerating its item rows on every open, and a hand-rolled
`mouse.exited.global` dismissal.

### 1.3 Measured cost (this machine, M5 Max, macOS 26.6)

Daemon, sampled over 26 hours of uptime:

```
pid 1012   elapsed 1d 02:11:25   cpu 4:18.48   rss 52 MB   phys_footprint 36 MB
                                 => 0.27% of one core sustained
```

Plugin scripts, benchmarked at 10 iterations each:

| Script | CPU per run | Runs/min | Sustained |
| --- | --- | --- | --- |
| port scan (`lsof`) | 94 ms | 12 | **1.88% of a core** |
| `clock` plugin | 6 ms | 6 | 0.06% |
| push-based plugins x3 | 6 ms | 3 | 0.03% |
| a status-file plugin | 7 ms | 2 | 0.02% |
| `battery` plugin | 18 ms | 0.5 | 0.02% |
| `workspace` plugin | 12 ms | per switch x7 | 147 ms latency per switch |

**Totals: roughly 2.3% of one performance core burned continuously, and about
130 process spawns per minute (190,000 per day).** The port-scanning plugin alone accounts
for 82% of the CPU, almost all of it inside `lsof` walking every process's file
descriptor table twelve times a minute.

None of this work is inherently expensive. Listening TCP ports are readable
in-process via `proc_listpids` + `proc_pidinfo`. Battery state is a
`IOPSNotificationCreateRunLoopSource` callback with zero polling. The cost is
entirely an artifact of the shell-out architecture.

---

## 2. Goals

1. **Structural bug elimination.** Fix the flicker, wake crashes, stuck
   `drawing`, blur bleed, and IPC deadlocks by removing the architecture that
   causes them, not by patching symptoms.
2. **Battery and memory.** Idle CPU under 0.05%, resident memory under 20 MB,
   zero subprocess spawns for anything built in, full suspension when the
   display sleeps.
3. **Simplicity and modifiability.** One typed, declarative, hot-reloading
   config file. Native providers for everything common. A clean escape hatch for
   everything else.
4. **Full capability parity plus the two most-requested extras** (graphs,
   now-playing media).

### Non-goals

- CLI compatibility with `sketchybar --add/--set`. Clean break, per decision.
- Running with SIP disabled. Not required, and never will be.
- Supporting macOS before 26.

---

## 3. Rendering architecture

This is the single most consequential decision, so it gets the most detail.

### 3.1 The change

**One `NSPanel` per display containing one `CALayer` tree**, instead of one
SkyLight window per item.

```
NSPanel                              (borderless, .nonactivatingPanel)
  level = .statusBar + 1
  collectionBehavior = [.canJoinAllSpaces, .stationary,
                        .fullScreenAuxiliary, .ignoresCycle]
  isOpaque = false, backgroundColor = .clear, hasShadow = false
  isReleasedWhenClosed = false, hidesOnDeactivate = false
  │
  └─ BarRootLayer
       ├─ NSVisualEffectView          (blur, masked to the bar's corner radius)
       ├─ GroupLayer "workspaces_pill"
       │    ├─ ItemLayer space.1 … space.7
       │    └─ BackgroundLayer        (drawn behind, sized from children)
       ├─ GroupLayer "app_pill"
       └─ …
```

### 3.2 Why this is better, concretely

| Upstream problem | Cause | Resolution here |
| --- | --- | --- |
| Flicker on workspace switch (#726, #834, #808) | N independent windows moved in N separate SkyLight calls; the compositor sees intermediate states | All layout changes land in one `CATransaction`. The compositor never sees a partial frame. |
| Crash on wake (#691) | `window_close` calls `CFRelease` on a context the display server already invalidated | No per-item window lifecycle exists to get invalidated. |
| `drawing` stuck (#787) | Window creation/destruction races with display reconfiguration | `drawing` maps to `layer.isHidden`, a pure in-process property. |
| Blur bleeds past radius (#827, #839) | `SLSSetWindowBackgroundBlurRadius` blurs the whole window rect | `NSVisualEffectView` with a `CAShapeLayer` mask follows the exact corner path. |
| Hangs during sleep (#776) | `SLSDisableUpdate` waits on the display server; `enable_updates_common timed out` floods the log | No `SLSDisableUpdate`. `CATransaction` is process-local. |
| Bracket needs `background.height` (#639) | Brackets are a post-hoc rectangle, not a layout node | `Group` is a real container node that sizes to its children plus insets. |

Memory: 15-40 backing surfaces at 2x collapse to one per display. Combined with
Swift value types replacing the malloc'd struct graph, the 36 MB footprint should
land comfortably under 20 MB.

### 3.3 Where private SkyLight still earns its place

Private API use is fine (all of it works with SIP enabled, as SketchyBar
demonstrates today), but it is confined to one target, `CSkyLight`, behind a
protocol:

```swift
protocol SystemSurface {
    func elevate(_ window: NSWindow, above: WindowLevelPolicy)
    func spaceTopology() -> [Display: [Space]]
    func captureMenuBarItem(_ id: MenuBarItemID) -> CGImage?
}
```

Two implementations: `PublicSurface` (AppKit only) and `SkyLightSurface`. The
public one is the default; the private one is selected per-capability at runtime
with a `dlsym` availability check and a graceful public fallback.

Capabilities that genuinely need private API:

| Capability | Symbol | Public alternative? |
| --- | --- | --- |
| Native macOS Spaces enumeration | `SLSCopyManagedDisplaySpaces` | None. Required for the `space` component and `associated_space`. |
| Menu-bar item mirroring (`alias`) | `SLSCaptureWindowsContentsToRectWithOptions` | None. Also needs Screen Recording permission. |
| Guaranteed level above native fullscreen | `SLSSetWindowLevel` above `kCGMaximumWindowLevel` | `.fullScreenAuxiliary` probably suffices. **Spike required.** |
| Now-playing metadata and artwork | MediaRemote | `MPNowPlayingInfoCenter` is publishing-only. |

Everything else (blur, shadows, ordering, stickiness, mouse tracking, drawing)
uses public API and gets a better result.

### 3.4 Cost model

`CALayer` compositing runs on the GPU and costs zero CPU when nothing changes.
The redraw path is diff-gated: a provider emitting the identical string does not
mark anything dirty. Text is rendered to a cached `CTLine` keyed by
`(string, font, color)`, so re-laying out an unchanged label is a pointer
comparison.

---

## 4. Layout engine

A single measure-then-arrange pass over an immutable tree. No mutation during
layout, so it is trivially testable without a display.

```swift
indirect enum Node {
    case item(ItemID)
    case group(GroupID, [Node])       // bracket, but a real container
    case spacer(Length)               // fixed, flexible, or fill
}

struct BarLayout {
    var axis: Axis                    // .horizontal | .vertical  (fixes #240)
    var leading:  [Node]
    var center:   [Node]
    var trailing: [Node]
}
```

Three fixes fall out of doing this properly:

**Margin and padding are separate.** `margin` is outside the background and
affects sibling spacing; `padding` is inside and insets content. Upstream
conflates them, which is why `background.padding_left` silently overwrites
`padding_left` (#796) and why your config carries this comment:

```
# padding_left=6 because the bracket contributes no margin of its own
# (brackets swallow their members' outer margins)
```

With groups as real nodes, a group has its own margin and its children keep
theirs. That comment becomes unnecessary.

**Groups size themselves.** A group's frame is the union of its children's
frames plus its insets. `background.height` becomes optional everywhere (#639).

**Declaration order is visual order.** Upstream inserts `right` items
rightmost-first, which is why a sketchybarrc has to declare that side backwards
to get the intended order. In funkybar, `position = "right"` items render left
to right in declaration order.

---

## 5. Provider system

This replaces plugin scripts. A provider owns one piece of state and pushes
updates to the items bound to it.

```swift
protocol Provider: Sendable {
    static var id: String { get }
    var policy: UpdatePolicy { get }
    func run(_ sink: ProviderSink) async throws
}

enum UpdatePolicy {
    case event                                   // fully push-driven
    case interval(Duration, leeway: Duration)    // joins the shared timer wheel
    case hybrid(event: Void, floor: Duration)    // event-driven with a safety poll
}
```

### 5.1 Built-in providers (no subprocess, ever)

| Provider | Mechanism | Replaces |
| --- | --- | --- |
| `clock` | `DispatchSourceTimer` aligned to the minute boundary | `clock` plugin |
| `battery` | `IOPSNotificationCreateRunLoopSource`, fully event-driven | `battery` plugin |
| `cpu` | `host_processor_info` tick deltas | `cpu` plugin |
| `memory` | `host_statistics64` | new |
| `network` | `getifaddrs` byte deltas + `NWPathMonitor` | new |
| `disk` | `statfs` | new |
| `frontApp` | `NSWorkspace.didActivateApplicationNotification` | `front app` plugin |
| `aerospace` | AeroSpace `exec-on-workspace-change` hook into our socket, one query per switch | `workspace` plugin |
| `spaces` | `SLSCopyManagedDisplaySpaces` + space-change notification | native spaces |
| `windows` | `NSWorkspace` + accessibility observers | `app_windows` |
| `volume` | CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` listener | `volume` plugin |
| `wifi` | CoreWLAN + `NWPathMonitor` | wifi events |
| `media` | MediaRemote listener with artwork decode | `media_change` |
| `ports` | `proc_listpids` + `proc_pidinfo(PROC_PIDLISTFDS)` | `ports` plugin **(the big win)** |
| `process` | `proc_listpids` name match | `pgrep` calls |
| `graph` | ring buffer feeding a `CAShapeLayer` | `graph` component |

The `ports` provider deserves a note. `lsof -nP -iTCP:... -sTCP:LISTEN` costs
94 ms because it stats every descriptor of every process on the system and then
filters. Reading only socket descriptors and filtering on `TSI_S_LISTEN`
in-process costs single-digit milliseconds. At the same 5-second interval that is
roughly a 30x reduction; combined with the shared timer wheel it takes your
single most expensive item from 1.88% of a core to under 0.05%.

### 5.2 Escape hatches

**`command` provider.** Runs a shell command on an interval or in response to an
event. Fixes the upstream spawn path outright:

```swift
var attr = posix_spawnattr_t(nil)
posix_spawnattr_init(&attr)
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
```

`POSIX_SPAWN_SETSID` gives the child its own session, which is precisely what
issue #807 asks for (Homebrew's `Hardware::CPU.cores` fails under session 0 on
Tahoe). Plus: hard wall-clock timeout, output size cap, a global concurrency
limit so a wedged script cannot fork-bomb the bar, and structured stdout parsing
(`text`, `json`, or `kv`).

**`push` provider.** External apps connect to funkybar's socket and push JSON.
This replaces the entire hybrid state-file + `--trigger` + safety-poll dance
documented in your `INTEGRATION.md`:

```
an external app  --connect--> ~/.local/state/funkybar/funkybar.sock
         --send-->    {"push":{"provider":"myapp","state":"ON"}}
```

The connection itself is the liveness signal, so "app crashed while connected"
resolves to a defined state instead of a stale file. A `seed_file` option keeps
the file-backed cold-start behaviour you already rely on.

This also removes the `Process` pipe-deadlock pitfall your INTEGRATION.md warns
about, since there is no subprocess to drain: it is a socket write.

---

## 6. Configuration

One TOML file at `~/.config/funkybar/funkybar.toml`, parsed into a `Codable`
Swift schema, hot-reloaded on change.

```toml
[bar]
height     = 36
position   = "top"
y_offset   = 4
displays   = "all"
sticky     = true
topmost    = "window"

[theme]
pill_bg     = "#141414"
pill_border = "#3d2f1a"
accent      = "#f4d35e"
accent_dim  = "#7a6a4a"
text        = "#f1d9a4"
app_name    = "#ffb87c"
ok          = "#56d364"
warn        = "#d29922"
error       = "#ff7b72"
idle        = "#6e7681"

[theme.pill]
corner_radius = 12
height        = 24
border_width  = 1
background    = "$pill_bg"
border        = "$pill_border"

[defaults]
icon.font  = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 14 }
label.font = { family = "JetBrainsMono Nerd Font", style = "Bold", size = 12 }
icon.color = "$text"
label.color = "$text"
margin = { left = 3, right = 3 }

# ---- left ----
[[group]]
id       = "workspaces_pill"
position = "left"
style    = "$theme.pill"
padding  = { left = 7, right = 7 }

  [[group.item]]
  provider = "aerospace"
  repeat   = "workspace"          # one item per workspace, ids 1..7
  icon     = "$workspace.id"
  color    = { active = "$accent", inactive = "$accent_dim" }
  on_click = { workspace = "$workspace.id" }

[[group]]
id       = "app_pill"
position = "left"
style    = "$theme.pill"

  [[group.item]]
  id   = "chevron"
  icon = "›"
  icon.color = "$accent_dim"

  [[group.item]]
  id       = "front_app"
  provider = "frontApp"
  label    = "$app.name"
  label.color = "$app_name"
  label.font.size = 13

# ---- right, in visual left-to-right order ----
[[item]]
id       = "ports"
position = "right"
provider = "ports"
ports    = [3000, 3001, 5173, 8080]
watch    = ["proc-a", "proc-b"]
interval = "5s"
icon     = "󰒍"
popup    = { on = "click", dismiss = ["mouse_exit", "click_outside"] }

[[item]]
id       = "status"
position = "right"
provider = "push"
channel  = "status"
seed_file = "~/.local/state/myapp-status"
on_click  = { left = "status:toggle", right = "status:settings" }

  [item.states.ON]        = { icon = "󰦝", label = "STATUS", color = "$ok" }
  [item.states.CONNECTING] = { icon = "󰦝", label = "…",  color = "$warn" }
  [item.states.ERROR]      = { icon = "󰦝", label = "ERR", color = "$error" }
  [item.states.OFF]        = { icon = "󰦞", label = "OFF", color = "$idle" }

[[group]]
id       = "a repeated group"
position = "right"
style    = "$theme.pill"
provider = "push"
channel  = "prices"

  [[group.item]]
  repeat = ["c", "b", "a"]
  background.image = "~/.config/funkybar/icons/$item.png"
  background.image.scale = 0.38
  label = "$$$price"

[[item]]
id       = "battery"
position = "right"
provider = "battery"
label    = "$battery.percent%"
icon     = { ramp = ["󰂃","󰁻","󰁾","󰂀","󰂂"], charging = "󰂄" }

[[item]]
id       = "clock"
position = "right"
provider = "clock"
format   = "HH:mm  EEE dd"
```

Notes on the design:

- **Token references (`$accent`, `$theme.pill`)** kill the colour repetition in
  your current rc, where `0xff141414` appears seven times.
- **`repeat`** replaces the shell `for` loops that generate workspace and coin
  items.
- **State tables** replace the `case "$STATE" in` blocks in a status-file plugin, and the
  same shape covers the push and ports colour logic.
- **Colours are `#rrggbb` / `#aarrggbb`,** not `0xaarrggbb`, with a typed parser
  and an error pointing at the offending line.
- **Popups are declarative**, with a `dismiss` policy, so your hand-rolled
  `mouse.exited.global` subscription and the `python3` JSON query in
  `ports` plugin both disappear (this is also issue #835).
- **Symlinks are resolved and never executed**, fixing #553 for nix users.
- `funkybar check` validates without applying; `funkybar reload` applies
  atomically or rejects the whole file.

---

## 7. IPC and CLI

Replace Mach OOL messaging with a **Unix domain socket** at
`~/.local/state/funkybar/funkybar.sock`, carrying length-prefixed JSON.

Why this fixes the deadlock class (#794):

- Upstream's `mach_send_message` uses `MACH_MSG_TIMEOUT_NONE` on both ends. When
  the daemon sends to a subscriber whose queue is full while that subscriber is
  simultaneously sending back, both block forever.
- funkybar's daemon **never performs a blocking write on the event loop.** Each
  client connection has a bounded write buffer with a drop-oldest policy for
  event streams and back-pressure signalling for request/response. Deadlock is
  not merely unlikely, it is unrepresentable.

Secondary benefits: debuggable with `nc -U`, no bootstrap namespace
registration, works identically under launchd and in a terminal.

```
funkybar check                    # validate config, exit non-zero on error
funkybar reload                   # atomic config reload
funkybar query [selector]         # JSON dump of bar / item / provider state
funkybar set <selector> k=v ...   # runtime override (not persisted)
funkybar push <channel> <json>    # what an external app / another external app call
funkybar watch                    # live event stream, for debugging
funkybar doctor                   # permissions, fonts, aerospace hook, perms
```

---

## 8. Efficiency design

Explicit budget, measured in CI on every build:

| Metric | Today | Target |
| --- | --- | --- |
| Sustained CPU (daemon + scripts) | ~2.3% of a core | < 0.05% |
| Resident memory | 36 MB | < 20 MB |
| Process spawns/day | ~190,000 | 0 for built-ins |
| Wakeups/min at idle | ~25 (uncoalesced) | 1-2 (coalesced) |
| Workspace-switch latency | 147 ms, 7 forks | < 5 ms, 0 forks |

Mechanisms:

1. **Shared coalescing timer wheel.** All interval providers register on one
   `DispatchSourceTimer` with generous `leeway` and boundary alignment. On Apple
   Silicon, generous leeway lets the SoC coalesce timer interrupts and stay in a
   deep idle state; N independent 1-second timers defeat that entirely, which is
   what upstream's per-item `update_freq` plus the 1 Hz `bar_manager` clock does
   today.
2. **Full suspension when nothing is visible.** Subscribe to
   `NSWorkspace.willSleepNotification`, `screensDidSleepNotification`,
   `sessionDidResignActiveNotification`, and `NSWindow.occlusionState`. Suspend
   the timer wheel and all polling providers. On wake, do one forced relayout and
   redraw, which is the explicit fix for #783 and #776.
3. **Diff-gated redraw.** Providers emit values; the item state machine compares
   and only marks changed layers dirty. An unchanged clock string costs nothing.
4. **Text and image caching.** `CTLine` cache keyed by `(string, font, color)`.
   `CGImage` cache for background images, keyed by path and mtime.
5. **No polling where an event exists.** Battery, volume, wifi, front app, media,
   spaces, and workspaces are all fully event-driven. Only `cpu`, `memory`,
   `network`, `disk`, and `ports` poll, and they poll in-process.

---

## 9. Issue triage

Every open upstream issue, mapped to a disposition. Full table in
[docs/ISSUE-TRIAGE.md](docs/ISSUE-TRIAGE.md). Summary:

| Disposition | Count |
| --- | --- |
| Structurally impossible in the new design | 14 |
| Fixed by an explicit design decision | 20 |
| Delivered as a first-class config feature | 20 |
| Not applicable (docs, packaging, non-technical) | 3 |

The 14 in the first bucket are the ones worth naming, because they are the
reason for the rewrite rather than a patch: #691 (wake crash), #787 (stuck
drawing), #776 (sleep hang), #834, #827, #839, #808 (flicker and blur),
#726 (workspace flicker), #794 (deadlock), #639, #796 (bracket and padding
model), #836 (leak), #553 (symlink config), #240 (vertical bar).

---

## 10. Package layout

```
funkybar/
├── Package.swift
├── funkybar.toml.example
├── Sources/
│   ├── funkybar/              CLI client, thin
│   ├── FunkyBarDaemon/        main(), launchd lifecycle, NSApplication(.accessory)
│   ├── FunkyBarCore/          config schema, item model, layout engine, diff
│   ├── FunkyBarRender/        NSPanel, layer tree, text, blur, animation
│   ├── FunkyBarProviders/     every provider
│   ├── FunkyBarIPC/           socket server + protocol types
│   └── CSkyLight/             module.modulemap + private symbol declarations
└── Tests/
    ├── LayoutTests/           headless, no display required
    ├── ConfigTests/           golden-file parse + error message tests
    └── ProviderTests/         fake clocks, no real subprocesses
```

Toolchain note: you have Command Line Tools 6.3.3 but not full Xcode. SwiftPM
builds fine; `swift build -c release` plus `codesign -s -` produces a working
binary, and the daemon runs as a plain launchd executable calling
`NSApplication.shared.setActivationPolicy(.accessory)` rather than as an
`.app` bundle. No Xcode dependency anywhere.

---

## 11. Milestones

**M0 - Spikes (1-2 days).** Three questions that change the design if they fail:

1. Does `NSPanel` with `.fullScreenAuxiliary` + `.canJoinAllSpaces` at
   `.statusBar + 1` reliably draw over native fullscreen apps on 26.6? If not,
   `SkyLightSurface.elevate` becomes the default rather than the fallback.
2. Can AeroSpace's `exec-on-workspace-change` be pointed at `funkybar push`
   cleanly, and does 0.21.3-Beta emit on empty-workspace transitions (#754)?
3. Does MediaRemote still respond on 26.6, and what does it cost at idle?

**M1 - Core (visible bar).** Daemon, socket IPC, TOML config with hot reload,
one `NSPanel` per display, layout engine, text and background rendering, click
and hover. Ships your exact bar minus popups, driven by `clock`, `frontApp`,
`battery`, `aerospace` providers. This is the point where funkybar replaces
sketchybar on your machine day to day.

**M2 - Providers and popups.** `ports`, `push`, `command`, `volume`, `wifi`,
`cpu`, `memory`, `network`. Declarative popups with dismissal policies. Your
config fully migrated, including ports kill actions and the ExampleApp/STATUS push
integration. `funkybar doctor`.

**M3 - Parity.** Graphs, sliders, native Spaces, `alias` menu-bar mirroring,
media with artwork, Core Animation transitions, multi-display edge cases,
vertical bar axis.

**M4 - Polish.** Efficiency instrumentation and CI budget enforcement, launchd
agent + Homebrew formula, config reference docs, migration guide from
sketchybarrc.

---

## 12. Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `.fullScreenAuxiliary` insufficient over fullscreen | Bar hidden in fullscreen apps | M0 spike; `SkyLightSurface` fallback already designed in |
| `alias` capture needs Screen Recording permission | Menu-bar mirroring fails silently | `funkybar doctor` checks and prompts; feature degrades, bar does not |
| MediaRemote is private and unversioned | Now-playing breaks on an OS update | `dlsym` guarded, feature-flagged, bar unaffected if it vanishes |
| AeroSpace beta API churn | Workspace provider breaks | Provider is 150 lines behind a protocol; `command` fallback always available |
| Scope is large (full parity + extras) | Slips | M1 is independently useful and replaces your current setup; M3 parity items are additive |

---

## 13. Migration path for your config

Nothing gets deleted until funkybar runs. Sequence:

1. funkybar reads `~/.config/funkybar/funkybar.toml`; sketchybar keeps reading
   `~/.config/sketchybar`. Both can run, at different `y_offset`, during M1.
2. `funkybar migrate ~/.config/sketchybar/sketchybarrc` produces a best-effort
   TOML starting point (item names, positions, colours, fonts, paddings). Scripts
   are emitted as `command` providers, then replaced with built-ins one at a
   time.
3. external status-writing apps: add a `funkybar push` call alongside the existing
   `sketchybar --trigger`. Both work simultaneously; drop the old one when ready.
   The `Process` pipe-drain workaround in your `SketchybarBridge.swift` becomes
   a single socket write.
4. When the last item is on a built-in provider, `brew services stop sketchybar`.
