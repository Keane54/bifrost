# The debug bench

The bench measures the frame rate, the missed frames, the memory and the CPU of the native app
while chats stream. It uses the timeline and the measurement method of the prototype gate
(`docs/archive/gates/integrated-prototype/RESULTS.md`). Phase 3b Task 5 uses it for the
performance gates, and Task 6 compares the native app with the Electron app on the same timeline.

## Safety

- The bench runs only in a Debug build, with a test home and the fake claude
  (`scripts/fake-claude/claude`). The app refuses a bench run when the claude that it runs does
  not resolve to that file. So a bench run never attaches to a real session and never uses the
  real home.
- The test port request never names a path. The app writes the results only to
  `<test home>/bench/<name>.jsonl`.
- `run.sh` starts only the app and `caffeinate`, and stops them by their pids. It never builds
  or starts the Release app.
- A run covers the main display for about 2 minutes (the gate plan). Nobody must use the Mac
  during a run.

## Run the bench

```sh
tools/bench/run.sh --optimised gate 8 .build/bench/gate-1.jsonl
tools/bench/run.sh --optimised --trace gate 8 .build/bench/gate-traced-1.jsonl
tools/bench/run.sh short 8 .build/bench/short.jsonl
tools/bench/run.sh --optimised --no-blur --no-background gate 8 .build/bench/effects-off.jsonl
```

The arguments are the plan (`gate`, 92 s, or `short`, 30 s), the number of chats (1 to 8) and
the results file. The script removes an old results file first, so a failed run leaves none.
The script builds the Debug app with the paths of `scripts/check.sh`. Then it starts the app on
the main display, runs the plan through the test port and prints the summary.

The options give the variant of a run:

| Option | Effect |
|---|---|
| `--no-blur` | No blur behind the frames. |
| `--no-background` | The background stays still. |
| `--no-list` | No frame of the session list under the chats. |
| `--minimised N` | N chats go to the side bar. The drag chat stays. |
| `--streaming N` | Only N chats stream. The other chats stay quiet. |
| `--metal N` | Only N chats draw with Metal. The other chats use Core Graphics. |
| `--scrollback N` | Each chat keeps N lines of scrollback (0 to 10,000). |
| `--normal-screen` | The stream stays on the normal screen and fills the scrollback. |
| `--idle-wait S` | Wait at most S seconds until no build and no test runs (default 600). |
| `--optimised` | Build the Debug app with the optimisation of a release (see below). |
| `--trace` | Record the drag and the resize with Instruments (see below). |

### The optimised build

The plain Debug build has no optimisation. Then the terminal code of SwiftTerm uses about 8 times
the instructions of an optimised build: 8 streaming chats use about 150 % of one core in place
of about 70 %. The shipped app is optimised, so the gates of phase 3 use `--optimised`.

`--optimised` builds the Debug configuration with `SWIFT_OPTIMIZATION_LEVEL=-O` and
`SWIFT_COMPILATION_MODE=wholemodule` in `.build/xcode-opt`, so the build of `scripts/check.sh`
does not change. The app keeps the Debug bundle ID, the test port and the bench. It also gets
`ENABLE_HARDENED_RUNTIME=NO`, as the plain Debug app: an optimised build has no debug dylib, and
with the hardened runtime the app refuses the ad hoc signature of the Sparkle framework.

### The Instruments trace

`--trace` records the app with the template "Animation Hitches" of Instruments for 25 s, from
4 s before the drag phase. The run needs 20 GB free in `/tmp` (a trace uses 5 to 8 GB), else it
gives no result. One trace runs at a time.

- Instruments needs the Developer Tools access. Without it, xctrace waits for a password. A
  watchdog waits for the time limit and 60 s. With no trace file at that time, it stops xctrace
  by its pid and prints "Instruments needs Developer Tools access". The run then keeps the frame
  counter result. The script never runs `DevToolsSecurity` or `sudo` and never changes the
  authorization database.
- With a trace, the script exports the table of contents and the tables `time-info`,
  `hitches-lifetime-interval`, `hitches-summary` and `display-surface-swap` to
  `<out without .jsonl>.trace-export/`. Then it deletes the trace at once. The cleanup also
  deletes it after a signal or a failure.
- `hitches.py` converts the export and the results file of the run to
  `<out without .jsonl>.hitches.json`, and the summary of the run uses it. The method is in
  `docs/archive/phase-records/phase-3-performance.md`.

The first form of `hitches.py` was not checked against a real trace (the night runs had no
Developer Tools access). It refuses a result that it cannot trust: a phase with no frame, a
phase that the trace does not cover, or more frames than the display can show. The export stays
next to the results, so a fix of `hitches.py` needs no new trace:

```sh
python3 -I tools/bench/hitches.py .build/bench/gate-traced-1.trace-export \
    .build/bench/gate-traced-1.jsonl >.build/bench/gate-traced-1.hitches.json
```

The exit codes:

- 0: the results are in the results file.
- 1: the harness failed (the build, the app, the test port or the run, for example a chat that
  ended).
- 3: no result. The screen is locked, the window does not show on the main display, the
  display is not at 120 Hz, or a build, a test or another bench ran. Do the step again later.

## The checks before and during a run

1. One bench at a time: the run holds the lock `/tmp/bk-bench.lock`, a symbolic link whose
   target is the pid of the run. A lock whose pid is gone is taken over. A lock with no pid
   counts as held. A bench of the Electron app must take the same lock.
2. No build and no test runs: `xcodebuild`, `swift-build`, `swift-test`, `swift-frontend`,
   `swiftc`, `xctest`, `clang`, `ld`, `xctrace`, Stryker and vitest. The script waits for them.
3. The screen is not locked.
4. The window shows on the main display, and no other window covers all of it. The bench window
   floats above the windows of the other apps. It never activates the app.
5. A warm-up of 2 s gives a display period of 1/120 s within 2 % (the median gap).
6. The bench writes into each chat only after its attach and its first output.
7. During the run: the screen stays unlocked, no build or test starts, the window stays visible
   at the end of each phase, and each chat stays attached and not ended. From the stream phase
   to the end of the resize phase, the script sends no state request and checks each 4 s.
8. The state of the test port marks a failed check of the display or of the window with
   `"check":true`. Then the script gives no result (exit 3). Each other failure is exit 1.

`caffeinate -dimsu -w <app pid>` keeps the display awake while the app runs.

## The timeline

| Phase | Gate | Short | What happens |
|---|---|---|---|
| start | 10 s | 3 s | The chats attach and stream. |
| quiet | 4 s | 2 s | Ctrl+C in each streaming chat: the streams stop. |
| idle | 12 s | 3 s | No output and no input. The background moves. |
| warm | 6 s | 2 s | Return in each streaming chat: the streams start again. |
| stream | 12 s | 3 s | Each streaming chat streams 30 lines a second. |
| drag | 12 s | 4 s | The drag chat moves along the benchmark path (420 x 220 points). |
| resize | 8 s | 3 s | The drag chat resizes at its bottom-right corner (180 x 120 points). |
| typeprep | 3 s | 2 s | Ctrl+C in the typing chat. Its frame comes to the front. |
| typing | 25 s | 8 s | 10 keys a second (200 at most) into the typing chat. |

The chats open in the slots of the prototype layout: 8 frames of 520 x 500 points in two rows,
so each frame overlaps its neighbours. The session list (overview:1) is under them. The drag
chat and the typing chat are the chat of slot 5. The fake claude streams on the alternate
screen, as `claude attach` does. With `--normal-screen`, it first prints 1,200 lines, so the
scrollback fills.

## The results file

Each line is one `BenchSample` (JSON) for one phase:

| Field | Meaning |
|---|---|
| `phase` | The name of the phase. |
| `seconds` | The time of the phase. |
| `frames` | The display frames of the window (CADisplayLink). |
| `missed` | The missed frames: a gap of n display periods counts n - 1. |
| `excludedSeconds` | The frame gaps that a snapshot of the counters caused. |
| `appFootprint` | The highest phys_footprint of the app in the phase, in bytes. |
| `childFootprint` | The highest footprint of the PTY children of the app, in bytes. |
| `appInstructions` | The instructions of the app in the phase. |
| `appCPUSeconds` | The CPU time (user and system) of the app in the phase. |
| `start` | The start of the phase: the host time in seconds (`CACurrentMediaTime`). |
| `startDate` | The start of the phase: the wall time in seconds since 1970. |

## The summary

```sh
python3 -I tools/bench/summary.py .build/bench/gate-1.jsonl .build/bench/gate-2.jsonl
python3 -I tools/bench/summary.py --hitches .build/bench/gate-traced-1.hitches.json \
    --hitches .build/bench/gate-traced-2.hitches.json .build/bench/gate-traced-*.jsonl
```

`summary.py` prints the median of the runs for each phase and the gates: drag and resize at
least 118 fps and at most 2.0 missed frames a second, and the app and its children under
300 MB. The method is in `docs/archive/phase-records/phase-3-performance.md`. With
`--hitches`, the drag and resize gates use the Instruments result, and the frame counter result
is the second result. `--hitches` can come more than one time: the runs of all the files count.
`tools/bench/test-summary.sh` is the self-test of `summary.py` and `hitches.py`.
