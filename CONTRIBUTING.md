# Contributing

## Commit convention

funkybar uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
A `commit-msg` hook enforces the format, so a malformed message is rejected
before it lands.

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### Types

| Type | Use for |
| --- | --- |
| `feat` | A new user-visible capability (provider, config option, CLI command) |
| `fix` | A bug fix |
| `perf` | A change whose purpose is CPU, memory, wakeups, or spawn count |
| `refactor` | A change that alters neither behaviour nor performance |
| `docs` | Documentation only |
| `test` | Adding or correcting tests only |
| `build` | SwiftPM manifest, toolchain, packaging, Homebrew formula |
| `ci` | CI workflows and automation |
| `style` | Formatting, whitespace, lint fixes with no semantic change |
| `chore` | Repo housekeeping that fits nothing above |
| `revert` | Reverts a previous commit; the body names the reverted SHA |

`perf` is a first-class type here rather than a subset of `refactor`, because the
efficiency budget in [PLAN.md](PLAN.md#8-efficiency-design) is a stated product
requirement. A `perf` commit body should carry a before and after number.

### Scopes

| Scope | Area |
| --- | --- |
| `core` | Config schema, item model, layout engine, diffing |
| `render` | `NSPanel`, layer tree, text, blur, animation |
| `providers` | Any provider, built-in or escape hatch |
| `ipc` | Socket server, wire protocol |
| `cli` | The `funkybar` client binary |
| `daemon` | Process lifecycle, launchd, signal handling |
| `skylight` | The isolated private-API target |
| `config` | The TOML schema and its parser |
| `docs` | Plan, reference, migration guides |
| `tools` | Developer tooling: funkybar-measure, funkybar-diff |
| `deps` | Dependency changes |

Scope is optional but preferred. Omit it only for changes that genuinely span
the whole repo.

### Subject line

- Imperative mood: `add`, not `added` or `adds`.
- No trailing period.
- Lowercase after the colon, unless the first word is a proper noun or a symbol.
- 72 characters or fewer for the whole first line.

### Breaking changes

Append `!` after the scope and explain the break in a `BREAKING CHANGE:` footer.

```
feat(config)!: replace 0xAARRGGBB colours with #RRGGBB

BREAKING CHANGE: colour literals are now CSS-style hex strings. Run
`funkybar migrate` to rewrite an existing config.
```

### Examples

```
feat(providers): add native ports provider via proc_pidinfo

Replaces the lsof shell-out. Filters PROC_PIDLISTFDS on TSI_S_LISTEN
in-process rather than stat-ing every descriptor on the system.

perf: 94ms -> 3ms per scan, closes the 1.88% sustained CPU cost.
```

```
fix(render): keep blur inside the bar corner path

NSVisualEffectView is now masked by the same CAShapeLayer path used to
draw the background, so the blur cannot extend past the radius.

Refs FelixKratz/SketchyBar#827, FelixKratz/SketchyBar#839
```

```
perf(daemon): coalesce interval providers onto one timer wheel

Registers every interval provider on a single DispatchSourceTimer with
boundary alignment and 20% leeway, letting the SoC stay in deep idle.

Before: 25 wakeups/min. After: 2 wakeups/min.
```

## Branching

`main` is the default branch and stays releasable. Work happens on a branch
named for its change:

```
feat/ports-provider
fix/blur-corner-mask
perf/timer-coalescing
docs/config-reference
```

Squash-merge into `main`, using a conventional commit as the squash subject.

## Setup

Enable the hooks once per clone:

```sh
git config core.hooksPath .githooks
```

Verify identity is the GitHub private address before your first commit:

```sh
git config user.email   # 58887500+vas11111@users.noreply.github.com
```
