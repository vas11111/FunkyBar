# Benchmarks

All figures measured on this machine: Apple M5 Max, macOS 26.6 (25G72), on AC
power, with the same bar contents on both sides of the comparison.

Method matters for the CPU numbers: process CPU time is sampled twice, 120 to
180 seconds apart, and the rate is computed from the delta. Sampling once and
dividing by elapsed time would fold process startup into the steady-state rate
and flatter the result.

## Standing cost

| | SketchyBar today | funkybar M1 | Change |
| --- | --- | --- | --- |
| CPU, sustained | 2.3% of one P-core | **0.117%** | **20x less** |
| Memory, phys_footprint | 36 MB | **12 MB** | **3x less** |
| Process spawns | ~190,000/day | ~17,000/day | 11x less |
| Windows on screen | 1 per item (15-40) | **1 per display (2)** | |

The SketchyBar figure is the daemon (0.27%, sampled over 26 hours of real
uptime) plus its plugin scripts (2.0%, benchmarked at 10 iterations each). The
funkybar figure is the whole thing: there are no scripts.

```
window:     180s
cpu delta:  0.21s
cpu pct:    0.117%
rss:        40 MB
footprint:  12 MB
```

RSS is 40 MB but phys_footprint is 12 MB; the difference is shared framework
pages that AppKit maps and every process on the system shares. Footprint is the
number worth comparing, and it is what the plan set a target against.

## Per-operation

| Operation | SketchyBar | funkybar | Method |
| --- | --- | --- | --- |
| Listening-port scan | 94 ms | **2.72 ms** | 20 iterations, warm |
| Workspace switch | 7 forks + 7 IPC calls, 147 ms | 1 query, 1 transaction | |
| Clock update | 3 execs / 10 s | 1 formatter call / 60 s | |
| Battery update | 2 `pmset` execs / 120 s | 0 (kernel notification) | |
| Front app switch | 1 fork | 0 (NSWorkspace notification) | |

The port scan is the headline case. `lsof -nP -iTCP:... -sTCP:LISTEN` is slow
because it stats every descriptor of every process and then filters; asking the
kernel only for socket descriptors via `proc_pidinfo` and filtering on
`TSI_S_LISTEN` does the same job in-process. **35x faster**, and it is asserted
by a test that opens a real listening socket and finds it.

## Timer coalescing

The running bar reports:

```
providers: 7 (battery, clock, front_app, ports, space, and two push items)
timers:    4 on a 5.0s shared tick
```

Four interval providers share one `DispatchSourceTimer` at the GCD of their
intervals, with 20% leeway. Upstream would run four independent timers plus its
own 1 Hz bar-manager clock.

## Where the remaining 0.117% goes

The plan set a target of under 0.05%. **M1 lands at 0.117%, so the target is not
met yet.** Worth being precise about why.

The obvious suspect was the `aerospace` provider, which is the one remaining
subprocess (AeroSpace exposes no API but its CLI). Relaxing its poll from 5s to
60s, cutting 12 subprocess spawns per minute down to 1, was measured:

```
aerospace at 5s:   0.117%
aerospace at 60s:  0.125%
```

No improvement, and the difference is inside the noise floor of this method. So
**the subprocess is not the cost**, which was not the expected answer.

What is left, in order of likely size:

1. The `ports` scan at 5 s: 2.72 ms x 12/min is 0.033 CPU-s/min, roughly 0.054%,
   or about half the total. This is the largest single item and the interval is
   arbitrary; dev ports do not appear and disappear every five seconds.
2. AppKit run-loop and window-server overhead for two panels, which is a floor
   any AppKit process pays.
3. Layout and diff work per tick, which the diff gate should already make near
   zero when nothing changes; this has not been isolated.

Cheapest paths to the target, in order:

- Raise the `ports` interval to 15-30 s. Alone this should take roughly 0.04%
  off, most of the gap.
- Skip the whole provider pass when the bar is occluded, using
  `NSWindow.occlusionState`. Designed in the plan, not yet wired.
- Profile the idle run loop rather than guessing at item 3 above.

None of these needs new architecture, which is the useful conclusion: the
20x improvement came from removing the shell layer, and closing the last 2.4x is
tuning.

## Reproducing

```sh
swift build -c release
swift run funkybar-test "ports"     # per-operation scan benchmark

# Standing cost, two-sample delta.
.build/release/funkybard --config ~/.config/funkybar/funkybar.toml --duration 260 &
PID=$!; sleep 20
T1=$(ps -o time= -p $PID); sleep 180; T2=$(ps -o time= -p $PID)
footprint -p $PID | grep phys_footprint:
kill $PID
```
