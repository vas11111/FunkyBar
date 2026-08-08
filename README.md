# funkybar

A Swift rewrite of [SketchyBar](https://github.com/FelixKratz/SketchyBar) for
macOS 26 and later: the same capabilities, one tenth the moving parts,
measurably cheaper on battery and memory, and an architecture in which most of
upstream's open bug list cannot occur.

Status: **planning**. No code yet. See [PLAN.md](PLAN.md).

---

## Why

Measured against a real config on an M5 Max running macOS 26.6:

| | SketchyBar today | funkybar target |
| --- | --- | --- |
| Sustained CPU | 2.3% of one P-core, always | < 0.05% |
| Process spawns | ~190,000 per day | 0 for built-in providers |
| Resident memory | 36 MB | < 20 MB |
| Workspace switch | 147 ms, 7 forks | < 5 ms, 0 forks |

Upstream creates one SkyLight window per bar item, which is the direct cause of
the flicker, wake crashes, stuck `drawing`, and blur bleed reported across its
issue tracker. funkybar uses one `NSPanel` per display with a single `CALayer`
tree, which makes 14 of those 57 open issues structurally impossible rather than
merely fixed.

Private SkyLight API is still used where there is no public equivalent (Spaces
enumeration, menu-bar mirroring, MediaRemote), isolated in one target behind a
protocol. None of it requires disabling SIP.

## Documents

- [PLAN.md](PLAN.md) - architecture, provider system, config format, efficiency
  budget, milestones, risks
- [docs/ISSUE-TRIAGE.md](docs/ISSUE-TRIAGE.md) - all 57 open upstream issues,
  each mapped to a disposition
- [CONTRIBUTING.md](CONTRIBUTING.md) - commit convention and branching

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Swift 6.3 or later (Command Line Tools is sufficient; full Xcode is not needed)
- SIP may stay enabled

## License

TBD.
