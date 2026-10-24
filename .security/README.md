# Security review and checks

Reviewed 2026-10-24. This directory is part of the repository's verification
workflow. Its existing Cargo, Python and Node policies are retained; those
ecosystems are not dependencies of funkybar.

## Dependency and toolchain inventory

`Package.swift` declares no third-party packages, binary targets or build
plugins. The scanner verifies a fingerprint of that reviewed manifest without
executing it. Manifest changes require another dependency review and an updated
fingerprint. Generated Swift build trees are excluded from dependency discovery.

The project pins **Swift 6.4.1**, the current stable release checked against
[Swift.org](https://www.swift.org/install/macos/) and its
[release announcement](https://forums.swift.org/t/announcing-swift-6-4-1/90029).
CI downloads the official macOS package, checks its recorded SHA-256 and Apple
signature, and extracts it without running its installer. The package's verified
signer is `Developer ID Installer: Swift Open Source (V9AUD2URP3)`.

GitHub Actions use reviewed immutable commits. Checkout is v7.0.1, and runs
without persisted credentials and with read-only repository permissions. The
workflow uses `pull_request`, never `pull_request_target`. Dependabot proposes
action updates; their policy entries must be reviewed alongside the workflow.

If Swift dependencies are added, commit `Package.resolved` and replace the
dependency-free inventory with an appropriate review. The scanner understands
lockfile schemas 1–3, queries the OSV **SwiftURL** ecosystem for repositories
explicitly listed in `swift.public_repositories`, and rejects unreviewed or
revision-only pins. Private repository names are not sent to OSV. Unsupported
lockfiles fail an advisory check rather than silently passing.

## Execution boundaries

- There is no network listener or implemented socket IPC in this version.
- Workspace names and AeroSpace binary paths are passed directly as executable
  arguments, including queries and the event stream. Provider values are not
  interpolated into configured shell actions.
- Port popup actions use native signals, accept only processes from the latest
  scan, reject special PIDs, and compare process start times before TERM/KILL.
  Right-clicking a popup row does not terminate a process.
- A config may intentionally contain shell actions and named commands. It must
  be a regular file owned by the current user or root, without group/other write
  permission. These properties are checked on the opened descriptor, including
  when the config is a symlink. Configs are limited to 1 MiB; seed files are
  regular files limited to 64 KiB. Neither path can block on a FIFO.
- Command capture drains both pipes, enforces a deadline independently of EOF,
  caps retained output, reports signals as failures, and limits concurrent
  commands. Commands are not sandboxed; trusted commands can deliberately create
  detached processes.
- Stream lines are limited to 64 KiB, queued deliveries are bounded, and stopped
  streams receive TERM followed by KILL if needed. Theme expansion is bounded
  in size and depth. Non-finite geometry and unsafe durations are rejected.
- Artwork decoding and its cache are bounded. Removed artwork layers are
  released, and config reloads invalidate cached images.

No unintended remote command execution was identified in the reviewed paths.
The regression suite exercises injection attempts and the boundaries above;
this is not a guarantee that all vulnerabilities are absent. AppKit, ImageIO,
the macOS runtime, and configured external programs also require vendor updates.

## Run the checks

Use Python 3.11+ and the pinned Swift toolchain:

```sh
python3 -m unittest discover -s .security -p 'test_*.py'
python3 .security/check.py --advisories --toolchain swift
swift build -c release
swift run -c release funkybar-test
.build/release/funkybard --config funkybar.toml.example --check
```

`--toolchain` also accepts an absolute Swift executable path. Without that flag,
the scan checks repository pins, not the installed compiler. With no external
packages, a successful scan reports zero public package versions and
`fresh_advisories: false`; it does not claim to have queried a vulnerability
database for nonexistent packages. Network or parsing failures fail the check.

To update Swift, review the official release, update `.swift-version` and the
toolchain version/package digest in `minimum-versions.json`, then run the full
build and tests. Refresh the manifest fingerprint only after reviewing its diff.
