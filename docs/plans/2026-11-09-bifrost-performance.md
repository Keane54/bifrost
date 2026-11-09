# Bifrost Performance panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Performance panel with a health headline (OK, Warning, Problem) for Bifrost, a Details section (Bifrost processes, Claude sessions, the Mac, the network, limits and disk), and a side bar dot.

**Architecture:** A new main-process module `src/main/performance/` samples Electron, Node and macOS data every 15 s (every 2 s while the panel shows), keeps 60 minutes of samples in memory, runs the health checks with pure functions, and pushes a snapshot on `performance:update`. Existing modules report poll results, save results and crashes to one small health log. The renderer panel shows the snapshot and reports its own state (showing, focus, open chat panels, frame rate).

**Tech Stack:** Electron 44 (`app.getAppMetrics`, `powerMonitor`, `net`), Node 24 (`perf_hooks`, `os`, `fs.statfs`), macOS commands with absolute paths, React 19, Tailwind 4, Vitest, Playwright. No new library.

**Spec:** `docs/specs/2026-11-09-bifrost-performance-design.md`. Main spec: `docs/specs/2026-11-04-bifrost-design.md`. The approved mockup: `/Users/dev-user/Developer/bifrost/.superpowers/brainstorm/74668-1794218564/content/performance-panel-v4.html`.

**Code map:** `/private/tmp/claude-501/-Users-dev-user-Developer-claude-statusline/b72dc96f-be42-469c-abbe-a0fee6807fa2/scratchpad/performance-code-map.md` (and `reviews-code-map.md` next to it for general conventions). Read the sections that a task names.

## Global Constraints

- All prose, comments, docs and commit bodies in ASD-STE100. Never the em dash (in a test string write `\u2014`). Conventional Commits. Commit body lines of 100 characters or less.
- Text in the app is plain, friendly English. The OK text is exactly "Bifrost is using <RAM> RAM and <CPU> CPU." (user decision, 2026-11-09), for example "Bifrost is using 712 MB RAM and 2% CPU."
- ESM TypeScript only. Add no library. Each macOS command runs with its absolute path through `execFile` (`src/main/claude/cli.ts`): `/bin/ps`, `/usr/sbin/sysctl`, `/usr/bin/pmset`, `/usr/sbin/netstat`, `/sbin/route`, `/usr/sbin/networksetup`, `/usr/bin/du`. All are read only.
- Modules under `src/main/performance/` never import `electron`. They take each Electron, Node or command function as a dep. Only `ipc.ts` and `index.ts` bind them.
- The monitor stays below 1% of one core on average and below 10 MB of memory. No `ps` or command call runs more often than the interval of section 7 of the design.
- The response-time requests use `net.fetch` with method `HEAD`, `credentials: 'omit'`, `cache: 'no-store'`, and a 5 s `AbortSignal.timeout`. They send no token and no cookie.
- In a test home, the monitor makes no network request and no `gh` call. System reads are allowed.
- Colours: OK uses the `ctx-low` token, Warning `ctx-mid`, Problem `ctx-high`. No new colour token. Build each `className` with `cx()`. Square corners.
- IPC: each handler uses `fromPage` and checks each value. The renderer sends booleans, numbers and view IDs that match `CHAT_VIEW`, never a path or a command.
- Each long-lived part (timers, `powerMonitor` and `app` listeners, the event loop histogram) stops in `stopRegistry()`.
- Run `pnpm check`, `pnpm typecheck` and `pnpm test` before each commit. Commit with explicit paths. Never use `git stash`, `git checkout --`, `git restore` or `git reset`.
- Never run, signal or drive the user's dev Bifrost. Never run the real `claude`. Work only in `.worktrees/performance`.

## Decisions (controller rulings, 2026-11-09)

| ID | Decision |
|---|---|
| P1 | `PtyManager` gets `list(): Array<{ viewId: string; pid: number }>`. The monitor never sets the single-slot `onData`, `onClose` or `onExit` callbacks. |
| P2 | Orphan terminal: the renderer reports the IDs of its open chat panels on each change. A `chat:` PTY whose view ID is not in that list for more than 60 s is an orphan. A `send:` PTY that stays open for more than 60 s is an orphan. |
| P3 | CPU of a process from `ps` is the change of its cumulative CPU time (`time=`) divided by the time between two samples, because the `%cpu` of macOS `ps` is an average. Electron processes use `getAppMetrics()` `cpu.percentCPUUsage`. |
| P4 | Bifrost RAM is the sum of `getAppMetrics()` `memory.workingSetSize` (KB) of all Electron processes and the `ps` RSS (KB) of the PTY processes. The two measures differ a little; the plan accepts that. |
| P5 | One health log (`src/main/performance/health-log.ts`) gets all events: poll results, save results, crashes and Live details start errors. Each existing module gets one optional dep (default: no-op) and calls it. |
| P6 | A save failure gives one reason for each store while its last failure is less than 60 minutes old: "Bifrost couldn't save <store> at 14:05." A later good save of the same store does not clear it early. The stores: settings, UI state (layouts), registry, window state, Reviews state. |
| P7 | Poll results: the session list counts each active poll. Reviews counts `error` availability as a failure and `no-gh` or `logged-out` as no data. Account usage counts a fetch error, a 5xx answer and a timeout as a failure, and a 401, 403, 429 or missing token as no data. Service status counts a round where every service failed as one failure. While offline, the network parts (Reviews, account usage, Service status) give no failure. |
| P8 | A crash is `render-process-gone` of the main window, or `child-process-gone` with `type === 'GPU'`, with a reason other than `clean-exit`. No load event counts. |
| P9 | The renderer reports `{ showing, focused, chatPanels }` on each change, and the frame rate once a second while showing and focused. Main samples every 2 s while `showing` is true, else every 15 s. |
| P10 | `UiStore` gets `performance: { detailsOpen: boolean }` with the default `false` and a parser. |
| P11 | The Reviews poll asks `rateLimit { cost limit remaining resetAt }`. `PollData` gets `rateLimit`. `ReviewsWatcher` gets `rateLimit(): RateLimit | null`. With Reviews off and the panel showing, the monitor runs `gh api rate_limit` (it costs no points) at most every 60 s, through the same `createGh` instance (hoisted in `ipc.ts`). |

## Review Focus

1. **The monitor itself is heavy.** A test must show that one sample tick runs at most one `ps` call and that no command runs while the panel is closed except at the 15 s tick. Owner: Task 4.
2. **A check with no data says OK.** With no samples (just started) or with a module off, no reason appears, and the OK text shows only measured values. Owner: Task 3, `no data gives no reason and the OK text names only measured values`.
3. **The leak check fires on chat windows.** Opening three chat windows (300 MB of PTYs) must not give a growth reason. Owner: Task 3, `chat terminals do not count in the growth trend`.
4. **Offline floods the headline.** With `isOnline` false, ten failed Reviews polls give no reason. Owner: Task 3.
5. **A Stop on an external session.** The Stop button never shows for an external or parked row. Owner: Task 5 (source test) and the existing `actionStateFor` rules.

---

### Task 1: System readers

**Files:**
- Create: `src/main/performance/system.ts`
- Test: `test/main/performance/system.test.ts`, fixtures inline in the test

**Interfaces:**
- Produces (all pure parsers plus readers that take `exec: ExecFn`):
  - `export interface ProcRow { pid: number; ppid: number; rssKb: number; cpuSeconds: number }`
  - `export const PS_STATS_ARGS = ['-axo', 'pid=,ppid=,rss=,time=,comm=']`
  - `export function parsePsStats(stdout: string): Map<number, ProcRow>` (the `time=` field is `M:SS.cc` or `H:MM:SS` or `D-HH:MM:SS`; `comm` is last and may hold spaces)
  - `export function treeSum(table: Map<number, ProcRow>, root: number): { rssKb: number; cpuSeconds: number; pids: number[] }` (the root and all its children, each once)
  - `export function cpuPercent(prevSeconds: number, nextSeconds: number, elapsedMs: number): number` (percent of one core, never below 0)
  - `export type Pressure = 'normal' | 'warn' | 'critical'`; `export function parsePressureLevel(stdout: string): Pressure | null` (`sysctl -n kern.memorystatus_vm_pressure_level`: 1, 2, 4)
  - `export function parseSwap(stdout: string): { usedMb: number; totalMb: number } | null` (`sysctl -n vm.swapusage`)
  - `export function parseBattery(stdout: string): { percent: number; charging: boolean; onBattery: boolean } | null` (`pmset -g batt`; a Mac with no battery gives null)
  - `export function parseDefaultInterface(stdout: string): string | null` (`route -n get default`, the `interface:` line)
  - `export function parseHardwarePorts(stdout: string): Map<string, string>` (`networksetup -listallhardwareports`: device to port name)
  - `export type LinkKind = 'wifi' | 'ethernet' | 'vpn' | 'other'`; `export function linkKind(device: string, ports: Map<string, string>): LinkKind` (`utun*` and `ipsec*` are `vpn`; port name `Wi-Fi` is `wifi`; a port name with `Ethernet` or `Thunderbolt` is `ethernet`)
  - `export function parseNetBytes(stdout: string, device: string): { inBytes: number; outBytes: number } | null` (`netstat -ib`, the `<Link#n>` row of the device)
  - `export function cpuLoad(prev: os.CpuInfo[], next: os.CpuInfo[]): number` (percent of the whole Mac, 0 to 100)
  - `export function parseDuKb(stdout: string): number | null` (`du -sk <path>`)
  - Readers: `readPsStats(exec)`, `readPressure(exec)`, `readSwap(exec)`, `readBattery(exec)`, `readLink(exec)` (default interface and kind), `readNetBytes(exec, device)`, `readDuKb(exec, path)`. Each returns null on any failure and never throws. Absolute paths and args are exported constants.

- [ ] **Step 1: Write the failing tests** with real-looking command output for each parser: `parsePsStats` reads three rows, one with a `comm` that has spaces, and the three `time` formats; `treeSum` sums a root with two children and one grandchild and ignores a sibling; `cpuPercent(10, 13, 2000)` is 150; `parsePressureLevel('2\n')` is `warn`; `parseSwap('total = 6144.00M  used = 4605.06M  free = 1538.94M  (encrypted)')` gives 4605 and 6144; `parseBattery` for "82%; charging" on AC power, for a discharging battery, and null for a desktop answer; `parseDefaultInterface` finds `en0`; `linkKind('utun3', ports)` is `vpn` and `linkKind('en0', ports with Wi-Fi)` is `wifi`; `parseNetBytes` picks the `Link#` row of `en0`; `cpuLoad` gives 25 for one busy core of four; each reader gives null for code 1 and for empty output.
- [ ] **Step 2: Run** `pnpm vitest run test/main/performance/system.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** `system.ts`. Model the shape on `src/main/registry/terminal-app.ts` (`PS`, `PS_TABLE_ARGS`, `parseProcessTable`).
- [ ] **Step 4: Run** the file, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(performance): read process, memory, battery and network data from macOS`.

### Task 2: The health log and its hooks

**Files:**
- Create: `src/main/performance/health-log.ts`
- Modify: `src/main/pty/pty-manager.ts` (P1), `src/main/registry/service.ts`, `src/main/reviews/watcher.ts`, `src/main/account-usage/poller.ts`, `src/main/service-status/monitor.ts`, `src/main/live/live-control.ts`, `src/main/store/settings-store.ts`, `src/main/store/ui-store.ts`, `src/main/window/window-state.ts`, `src/main/reviews/state-store.ts`, `src/main/ipc.ts`, `src/main/index.ts`
- Test: `test/main/performance/health-log.test.ts`, and one new test in the test file of each modified module

**Interfaces:**
- Produces in `health-log.ts`:
  - `export type PollPart = 'sessions' | 'reviews' | 'account-usage' | 'service-status'`
  - `export type StorePart = 'settings' | 'ui-state' | 'registry' | 'window-state' | 'reviews-state'`
  - `export interface HealthEvents { poll(part: PollPart, result: 'ok' | 'failed' | 'no-data'): void; save(part: StorePart, ok: boolean): void; crash(kind: 'window' | 'gpu', reason: string): void; liveStartFailed(message: string): void }`
  - `export interface HealthLog extends HealthEvents { view(now: number): HealthLogView }`
  - `export interface HealthLogView { failsInARow: Record<PollPart, number>; saveFailedAt: Partial<Record<StorePart, number>>; crashes: Array<{ kind: 'window' | 'gpu'; reason: string; at: number }>; liveStartFailedAt: number | null }` (crashes and save failures older than 60 minutes are dropped)
  - `export function createHealthLog(now: () => number): HealthLog`
  - `export const NO_HEALTH: HealthEvents` (every method does nothing; the default dep)
- Produces in `pty-manager.ts`: `list(): Array<{ viewId: string; pid: number }>`.
- Each modified module takes one new optional dep `health?: Pick<HealthEvents, ...>` (default `NO_HEALTH`) and calls it at the place that the code map section 3 and 4 names, with the P6 and P7 rules. `poll(part, 'no-data')` does not change `failsInARow`; `'ok'` resets it; `'failed'` adds 1.
- `ipc.ts` creates one health log in `registerIpc`, passes it to each module, adds `(_e, details)` to the `render-process-gone` listener of `attachWindow` (P8), and exports `getHealthLog(): HealthLog | null` for Task 4. `index.ts` adds `app.on('child-process-gone', ...)` for `details.type === 'GPU'` (P8) and calls the log.

- [ ] **Step 1: Write the failing tests:** `health-log.test.ts` (failures in a row, reset on ok, no-data keeps the count, a crash and a save failure drop after 60 minutes); `pty-manager.test.ts` `list gives each open PTY once and drops a closed one`; for each modified module, one test that a failure and a success reach the fake `health` dep with the P6 or P7 meaning (for example the account usage poller reports `no-data` for a 401 and `failed` for a 500).
- [ ] **Step 2: Run** the new tests. Expected: FAIL.
- [ ] **Step 3: Implement** the log, `list()`, the deps and the wiring.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(performance): record poll, save and crash events for the health checks`.

### Task 3: The health model (pure)

**Files:**
- Create: `src/shared/performance.ts`, `src/main/performance/health.ts`
- Test: `test/main/performance/health.test.ts`

**Interfaces:**
- Produces in `src/shared/performance.ts` (main and renderer):
  - `export type HealthState = 'ok' | 'warning' | 'problem'`
  - `export interface Reason { level: 'warning' | 'problem'; text: string }`
  - `export interface ProcGroup { name: string; count: number; ramMb: number; cpu: number }`
  - `export interface SessionUse { sessionId: string; name: string; ramMb: number; cpu: number }`
  - `export interface PerformanceSnapshot { state: HealthState; reasons: Reason[]; okText: string | null; bifrost: { ramMb: number; cpu: number; groups: ProcGroup[]; trend: Array<{ at: number; ramMb: number; cpu: number }>; fps: number | null; delayMs: number | null } | null; sessions: { ramMb: number; cpu: number; top: SessionUse[]; more: { count: number; ramMb: number; cpu: number } } | null; mac: { pressure: 'normal' | 'warn' | 'critical' | null; swap: { usedMb: number; totalMb: number } | null; cpuLoad: number | null; thermal: string | null; battery: { percent: number; charging: boolean } | null } | null; network: { online: boolean; kind: 'wifi' | 'ethernet' | 'vpn' | 'other' | null; downBps: number | null; upBps: number | null; anthropicMs: number | 'no-answer' | 'unreachable' | null; githubMs: number | 'no-answer' | 'unreachable' | null } | null; limits: { github: { remaining: number; limit: number; resetAt: number } | { unavailable: string } | null; freeDiskGb: number | null; clonesMb: number | null } }`
  - `export const EMPTY_PERFORMANCE: PerformanceSnapshot` (state `ok`, no reasons, `okText` null, every part null)
- Produces in `health.ts`:
  - `export interface Sample { at: number; bifrostRamMb: number; bifrostRamNoTermMb: number; bifrostCpuNoTerm: number }`
  - `export const LIMITS` (every number of design section 6: RAM 1024 and 1536 MB; growth 300 and 800 MB per hour; CPU 50 and 100; fps 30 for 10 s; delay 200 and 1000 ms; poll fails 3 and 10; orphan 60 s; window 60 minutes; trend needs 30 minutes)
  - `export function trendMbPerHour(samples: Sample[], now: number): number | null` (least squares over the last 60 minutes of `bifrostRamNoTermMb`; null with less than 30 minutes of samples)
  - `export interface HealthInput { now: number; samples: Sample[]; fpsLow10s: boolean; delayP99Ms: number | null; log: HealthLogView; online: boolean; orphans: number }`
  - `export function healthReasons(input: HealthInput): Reason[]` (problem reasons first, then warning reasons; each text one short sentence with the facts, in friendly English)
  - `export function healthState(reasons: Reason[]): HealthState`
  - `export function okText(sample: Sample | undefined): string | null` (the exact text of the Global Constraints; null without a sample)

- [ ] **Step 1: Write the failing tests,** one `it` for each row of design section 6 at the warning edge and at the problem edge, and:
  - `no data gives no reason and the OK text names only measured values`
  - `chat terminals do not count in the growth trend`
  - `the trend needs 30 minutes of samples`
  - `offline network polls give no reason, the session list still does`
  - `problem reasons come before warning reasons`
  - `a crash reason clears after 60 minutes`
- [ ] **Step 2: Run** the file. Expected: FAIL.
- [ ] **Step 3: Implement** both modules as pure code.
- [ ] **Step 4: Run** the file, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(performance): compute the health state and its reasons`.

### Task 4: The monitor, the Reviews rate limit, and the IPC

**Files:**
- Create: `src/main/performance/monitor.ts`
- Modify: `src/main/reviews/query.ts`, `src/main/reviews/pr-data.ts`, `src/main/reviews/watcher.ts` (P11), the Reviews fixtures that the query test and the smoke use, `src/main/ipc.ts`, `src/shared/api.ts`, `src/preload/index.ts`
- Test: `test/main/performance/monitor.test.ts`, `test/main/reviews/query.test.ts`, `test/main/reviews/watcher.test.ts`

**Interfaces:**
- Consumes: Task 1 readers, Task 2 `HealthLog`, `PtyManager.list()`, Task 3 model and types.
- Produces in `monitor.ts`:
  - `export const TICK_MS = 15_000`, `export const FAST_TICK_MS = 2_000`, `export const PROBE_MS = 60_000`, `export const BATTERY_MS = 60_000`, `export const DISK_MS = 60_000`, `export const CLONES_MS = 600_000`, `export const HISTORY_MS = 3_600_000`
  - `export interface MonitorDeps { exec: ExecFn; appMetrics(): Array<{ pid: number; type: string; cpu: { percentCPUUsage: number }; memory: { workingSetSize: number } }>; ptys(): Array<{ viewId: string; pid: number }>; rows(): SessionRow[]; cpus(): os.CpuInfo[]; thermal(): string | null; online(): boolean; freeDiskBytes(): Promise<number | null>; probe(url: string): Promise<number | 'no-answer' | 'unreachable'>; rateLimit(): { remaining: number; limit: number; resetAt: number } | null; ghRateLimit(): Promise<{ remaining: number; limit: number; resetAt: number } | { unavailable: string }>; clonesPath: string | null; health: HealthLog; delayP99(): number | null; now(): number; emit(s: PerformanceSnapshot): void; network: boolean }` (`network` false in a test home: no probes, no `gh`)
  - `export interface PerformanceMonitor { start(): void; stop(): void; current(): PerformanceSnapshot; view(v: { showing: boolean; focused: boolean; chatPanels: string[] }): void; fps(value: number): void }`
  - `export function createPerformanceMonitor(deps: MonitorDeps): PerformanceMonitor`
- Behaviour: one tick reads `appMetrics`, `ptys`, one `readPsStats`, the rows, the CPU times, pressure and swap; it keeps a `Sample` in a 60-minute ring; it groups the Electron types into Main process (`Browser`), Window (`Tab`), GPU (`GPU`), Chat terminals (the PTYs), and Other helpers (all other types); it builds the three heaviest Claude sessions by tree RAM (registry rows with a pid, P3, P4) and the "N more" total; it reads network bytes only while showing; probes, battery, disk and clones follow their own intervals; it runs the model and emits. The tick interval follows P9. `stop()` clears all timers.
- Produces in Reviews: `PollData.rateLimit: { cost: number; limit: number; remaining: number; resetAt: number } | null`; `ReviewsWatcher.rateLimit()` (null after `stop()`).
- Produces in `api.ts` (`BifrostApi`): `performance: { snapshot(): Promise<PerformanceSnapshot>; onUpdate(cb: (s: PerformanceSnapshot) => void): () => void; view(v: { showing: boolean; focused: boolean; chatPanels: string[] }): Promise<void>; fps(value: number): Promise<void> }`. Channels `performance:snapshot`, `performance:update`, `performance:view`, `performance:fps`. `view` refuses a chat panel ID that does not match `CHAT_VIEW` (`refused: bad chat panel`), with a friendly text in `FRIENDLY_ERRORS`. `fps` accepts a finite number from 0 to 1000.
- Wiring in `ipc.ts`: create the monitor in `registerIpc` after the PTY manager and the registry, bind the Electron functions (`app.getAppMetrics`, `powerMonitor.getCurrentThermalState`, `net.isOnline`, `os.cpus`, `fs.statfs` of the home folder, `net.fetch` HEAD for the probe, a `perf_hooks.monitorEventLoopDelay` histogram that resets every 60 s), hoist `createGh` for `ghRateLimit`, set `network: home === null`, start it, and stop it and the histogram in `stopRegistry()`.

- [ ] **Step 1: Write the failing tests** with fake timers and fake deps:
  - `one tick runs one ps call and no network read while the panel is closed`
  - `the tick is 2 s while showing and 15 s after the panel closes`
  - `groups Electron processes and chat terminals, and sums each session tree once`
  - `cpu of a ps process is the change of its cpu time`
  - `the three heaviest sessions and the rest`
  - `an orphan chat terminal after 60 s` and `a send terminal open for more than 60 s is an orphan`
  - `no probe and no gh call when network is false`
  - `uses the Reviews rate limit, else gh rate_limit at most every 60 s while showing`
  - `stop clears every timer`
  - `query.test.ts`: `parsePoll` reads `rateLimit` with `resetAt` in ms; `watcher.test.ts`: `rateLimit()` gives the last value and null after stop.
- [ ] **Step 2: Run** the files. Expected: FAIL.
- [ ] **Step 3: Implement** the monitor, the Reviews change, the IPC and the preload.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(performance): sample Bifrost and the Mac and push the health snapshot`.

### Task 5: The Performance panel

**Files:**
- Create: `src/renderer/src/performance/use-performance.ts`, `src/renderer/src/performance/PerformancePanel.tsx`, `src/renderer/src/performance/TrendLine.tsx`, `src/renderer/src/performance/format.ts`
- Modify: `src/renderer/src/wm/state.ts`, `src/renderer/src/panels/panels.tsx`, `src/renderer/src/wm/SideBar.tsx`, `src/renderer/src/wm/layout.ts` (P10), `src/renderer/src/wm/WindowManager.tsx` (save `detailsOpen`, report open chat panels), and the wm tests that build `UiStore` objects
- Test: `test/renderer/performance/format.test.ts`, `test/renderer/performance/panel-source.test.ts`, `test/renderer/wm/state.test.ts`, `test/renderer/wm/layout.test.ts`

**Interfaces:**
- Consumes: `window.bifrost.performance` (Task 4), `PerformanceSnapshot` (Task 3), `useActions().run('stop', id)` with `actionStateFor` (code map section 6).
- Produces:
  - `PanelKind` `'performance'`, panel ID `performance`, `DEFAULT_SIZES.performance = { h: 460, w: 520 }`, title `Performance`.
  - A side bar button (lucide `Activity` icon, label `Performance`) with a dot in `ctx-mid` (warning) or `ctx-high` (problem). One app-wide subscription feeds the side bar and the panel (a provider or a module store), not two.
  - `format.ts`: `export function mb(value: number): string` (`712 MB`, `1.31 GB` from 1000 MB), `export function percent(value: number): string` (`2%`, rounds), `export function rate(bytesPerSecond: number): string` (`84 KB/s`, `1.2 MB/s`), `export function ms(value: number | 'no-answer' | 'unreachable' | null): string` (`142 ms`, `No answer`, `Can't reach`, `-`), `export function thermalText(state: string | null): string` (`Normal`, `Fair`, `Serious`, `Critical`, `-`), `export function pressureText(p): string` (`Normal`, `Medium`, `High`).
- Behaviour (design section 5, mockup v4):
  - The headline: `OK` with `okText`, or `Warning` or `Problem` with a list of reasons. Each reason is its own item with a 6 px gap, and a small square in `ctx-mid` (warning) or `ctx-high` (problem).
  - One `Details` row with an arrow under the headline, in every state. It opens or closes all sections. Closed is the default. The value saves in `UiStore.performance.detailsOpen` (P10). The row has a bottom border only while open.
  - The sections of design 5.2, in order. The trend line is an inline SVG polyline with `stroke='currentColor'` and token classes, for the last 10 minutes of the snapshot `trend`.
  - The Stop button shows only when `actionStateFor('stop', row, ctx)` allows it. It runs `run('stop', sessionId)` with the normal confirm.
  - While mounted, the panel reports `view({ showing: true, focused, chatPanels })` and the frame rate once a second (a `requestAnimationFrame` counter) while the window has the focus. On unmount it reports `showing: false`. The window manager reports the open chat panel IDs on each change also while the panel is closed (P2).

- [ ] **Step 1: Write the failing tests:** `format.test.ts` for each function with the exact strings above; `state.test.ts` `panelKind('performance')` and its size; `layout.test.ts` `parseUiStore keeps performance.detailsOpen and defaults it to false`; `panel-source.test.ts` checks the reason list gap and squares, the Details border rule (only when open), `actionStateFor` before the Stop button, and that the panel and the side bar share one subscription.
- [ ] **Step 2: Run** the files. Expected: FAIL.
- [ ] **Step 3: Implement** the panel, the hook, the trend line, the registration, the side bar button and the reports.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(performance): add the Performance panel`.

### Task 6: Smoke test and the spec

**Files:**
- Create: `test/smoke/performance.spec.ts`
- Modify: `docs/specs/2026-11-04-bifrost-design.md` (panel table 8.2, a short Performance section, the files list), `docs/specs/2026-11-09-bifrost-performance-design.md` (status line "Built, 2026-11-09.")

- [ ] **Step 1: Write the smoke spec:** start the app with the test home; open Performance from the side bar; expect a headline (`OK`, `Warning` or `Problem`) within 20 s; expect the Details row closed; click it and expect the Bifrost section with at least one process row; click it again and expect the sections hidden; expect an empty `unknown.log` and unchanged `realFiles()`.
- [ ] **Step 2: Run** `pnpm smoke`. Expected: PASS (all specs).
- [ ] **Step 3: Update** the specs in ASD-STE100. Run the STE checker on the changed lines.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`, `pnpm smoke`. Expected: PASS.
- [ ] **Step 5: Commit** `test(performance): add the Performance smoke test` and `docs(spec): describe the Performance panel`.

## Exit check

- All checks pass: `pnpm test`, `pnpm typecheck`, `pnpm check`, `pnpm smoke`.
- The user opens the Performance panel in his own Bifrost after the merge. The controller does not drive his app.
