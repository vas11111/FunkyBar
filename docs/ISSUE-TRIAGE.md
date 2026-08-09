# Upstream issue triage

All 57 open issues on `FelixKratz/SketchyBar` as of 2026-08-08, mapped to a
disposition in the funkybar design.

Dispositions:

- **STRUCTURAL** - the bug cannot occur in the new architecture. No code is
  written to fix it; the code that caused it does not exist.
- **STRUCTURAL (designed, not built)** - the architecture forecloses the bug,
  but the feature it concerns is not implemented yet, so the claim is about the
  design rather than about running code. Marked explicitly, because "cannot
  happen" and "does not exist yet" are not the same statement.
- **DESIGN** - fixed by a specific, deliberate design decision. Named below.
- **FEATURE** - a request that becomes a first-class config option.
- **N/A** - documentation, packaging, or non-technical.

---

## STRUCTURAL (11 built, 3 designed but not built)

| # | Title | Why it cannot happen |
| --- | --- | --- |
| 839 | Blur not working after 2.24.0 | **Designed, not built.** Blur is planned as `NSVisualEffectView` rather than `SLSSetWindowBackgroundBlurRadius`; no blur is implemented yet, so there is nothing to break and nothing to credit. `bar.blur_radius` warns that it has no effect. |
| 836 | Leak: `CGWindowListCopyWindowInfo` not released | ARC and `CFBridgingRelease` at the single `CSkyLight` boundary. Manual `CFRelease` sites do not exist. |
| 834 | Unexpected flickering / shadow / border | One window, one layer tree, one `CATransaction`. The compositor never observes a partial frame. |
| 827 | Blur bleeds past bar radius, causes flicker | **Designed, not built.** Same as #839: the masking approach is planned, no blur exists yet. |
| 808 | Dynamic wallpaper causes flashing | No per-frame window capture and no per-item window reshaping, which is what the wallpaper daemon was racing. |
| 796 | `background.padding` overwrites `padding` | `margin` (outside) and `padding` (inside) are distinct fields on distinct types. Neither can write the other. |
| 794 | Deadlock when a callback calls `set()` mid-event | Socket IPC with bounded, non-blocking writes. The daemon never blocks on a client write. Mutual send-block is unrepresentable. |
| 787 | `drawing` sometimes unchangeable since Tahoe | `drawing` is `layer.isHidden`, an in-process property. No window creation race to lose. |
| 776 | Locks/beachballs during sleep with external displays | `SLSDisableUpdate` is never called, so `enable_updates_common timed out` has no source. Timers suspend on `willSleep`. |
| 726 | Workspace switch flicker (aerospace) | One provider query updates all workspace layers inside one transaction. Upstream forks 7 scripts that each race to repaint. |
| 691 | Crash on wake (`CFRelease` NULL in `window_close`) | There are no per-item windows to close, so `window_close` has no analogue. |
| 639 | Brackets require `background.height`, padding ignored | A group is a real layout container that sizes to its children plus insets. |
| 553 | Cannot run when the config is an executable symlink | The config is data, not an executable. Symlinks are resolved for watching and never `chmod`ed. |
| 240 | Vertical bar | **Designed, not built.** `Axis` exists as a value type, but `LayoutEngine` is horizontal-only and never reads it. `bar.axis` warns that it has no effect. |

---

## DESIGN (20)

| # | Title | Design decision |
| --- | --- | --- |
| 830 | macOS 27 beta regression in workspace badge / `lsappinfo` | No `lsappinfo` shell-out. `NSWorkspace` + accessibility observers. |
| 807 | `vfork()` without `setsid()` breaks child `waitpid()` | `posix_spawn` with `POSIX_SPAWN_SETSID` and `POSIX_SPAWN_CLOEXEC_DEFAULT`. |
| 784 | `max_chars` breaks CJK | Truncation operates on grapheme clusters via `CTLineCreateTruncatedLine`, never bytes. |
| 783 | Items do not update on wake | Explicit `didWake` handler performs one forced relayout and full redraw. |
| 779 | Cannot set `margin` to 0 | Typed `Int` schema. `0` is a valid value, not a sentinel for "unset". |
| 761 | Conflicts with Raycast | Window level and `collectionBehavior` are configurable per bar; `funkybar doctor` reports the effective level. |
| 754 | Aerospace workspace stale when emptied | The `aerospace` provider re-queries the full workspace list on every change and diffs, rather than each item polling its own state. |
| 742 | Popup drawn on the focused display, not the clicked one | Popups anchor to the layer tree of the display their item lives on. |
| 737 | Does not notice new/closed/minimized apps | `windows` provider observes `NSWorkspace` app lifecycle plus AX window notifications. |
| 735 | `media_change` does not fire when album is blank | Provider emits on any metadata delta; empty fields are valid values, not skip conditions. |
| 731 | `media_change` fires only for some sources | MediaRemote now-playing observation is client-agnostic, with a low-frequency reconcile poll as a floor. |
| 727 | `space_windows_change` inconsistent | Single native `windows` provider is the only source of truth; the event is derived from its diff. |
| 708 | `media_change` not firing | Same as 731 and 735. |
| 681 | `$BUTTON` has no middle click | Click payload carries the full `NSEvent.buttonNumber`, modifiers, and click count. |
| 649 | Support `margin_left` / `margin_right` on the bar | Bar has typed `margin` and `padding` insets with four sides each. |
| 555 | How to add an item to an existing bracket | Groups are declarative containers in the config; `funkybar set` can also insert at runtime. |
| 543 | Add an item before/after a specific item | Declaration order is authoritative; `funkybar set` supports `before:`/`after:` selectors. |
| 535 | `mouse.scrolled` incompatible with scroll-smoothing apps | Scroll events carry `hasPreciseScrollingDeltas`, `phase`, and `momentumPhase`; the config chooses what to honour. |
| 521 | Separate mouse-scroll from trackpad-scroll events | Same payload as 535; `source = "mouse" \| "trackpad" \| "any"` per item. |
| 472 | More powerful display and space selectors | Selectors are predicates over display and space attributes rather than 32-bit masks. |

---

## FEATURE (20)

| # | Title | Config surface |
| --- | --- | --- |
| 840 | Alias name for items | `alias = "…"` on any item. |
| 837 | Animate popup drawing state | Popup show/hide is a `CAAnimation`; `popup.animation = { kind, duration }`. |
| 835 | Auto-hiding popups | `popup.dismiss = ["mouse_exit", "click_outside", "timeout:5s"]`. |
| 774 | Menu bar too easy to trigger accidentally | `bar.hover.activation_delay = "250ms"`. |
| 750 | Refresh aliases on demand | `funkybar refresh <selector>`. |
| 741 | Reverse graph direction | `graph.direction = "leading" \| "trailing"`. |
| 736 | Workspace indicator for AeroSpace | First-class `aerospace` provider. |
| 733 | `y_offset` as a tuple | `offset = { x = 0, y = 4 }`. |
| 730 | Vertical slider | `slider.axis = "vertical"`. |
| 705 | `blur_radius` for shadow | `shadow = { radius, opacity, offset, color }` mapped onto `CALayer`. |
| 664 | Infinite rotate animation | `animation = { kind = "rotate", repeat = "infinite" }`. |
| 663 | Trackpad events | Gesture payloads (`magnify`, `swipe`) alongside scroll. |
| 655 | Detect clicks outside the bar | Global `NSEvent` monitor feeding an `outside_click` event. |
| 648 | Popups with multiple brackets, vertical and horizontal | A popup is a nested `BarLayout` with its own axis and groups. |
| 632 | Inverted rounded corners | `corner = { radius, style = "round" \| "inverted" \| "squircle" }` on the shape path. |
| 593 | Tooltip on hover | `tooltip = "…"` with a delay, rendered in the same layer tree. |
| 589 | Multi-colour graphs | `graph.fill = { gradient = [...] }` or per-segment colours. |
| 575 | `alias.cutoff` | `alias.crop = { left, right, top, bottom }`. |
| 565 | Item underline | `decoration.underline = { color, width, offset }`. |
| 532 | Gradient support for element colour | Any colour field accepts a gradient literal, backed by `CAGradientLayer`. |

---

## N/A (3)

| # | Title | Note |
| --- | --- | --- |
| 829 | Potential attempt at serving malware | Not a technical issue in the codebase. |
| 562 | `--clone` man page change | Upstream docs. |
| 534 | Mention `$BAR_NAME` in events docs | Upstream docs. |
