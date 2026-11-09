# Bifrost Live details (Claude Code mod) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in "Live details" Claude Code mod sends each session event to a Bifrost socket, and it replaces the global shell hooks and the statusLine wrapper. The poll of `claude agents --json` stays the base.

**Architecture:** The mod `bifrost-live` is one TypeScript hooks module in `resources/live-mod/`. It sends one JSON line for each event as an HTTP POST over the Unix socket `~/.bifrost/live.sock`, and it never waits for a send before the engine continues. The main process listens on the socket, checks each line, maps it to the M1 state machine events and to usage data, and runs the `claude plugin` commands that install, turn on, turn off and remove the mod. Bifrost removes an old hook install with the M1 uninstall, and it no longer installs hooks, writes `active` or `quiet` files, or reads event files and status files.

**Tech Stack:** Electron 44, Node 24 (`node:http`, `node:net`, `node:fs`), TypeScript 5.9, React 19, Vitest, Biome. The mod uses the Claude Code mod API of 2.1.318 (early access) and its test kit `claude-code/testing`. This plan adds no library.

**Spec:** `docs/specs/2026-11-04-bifrost-design.md` (sections 4, 5, 6, 7, 11, 12, 13, 15, 16, 20, 21 item 6). Read also `.superpowers/research-mods-hooks.md` and `.superpowers/mod-spike-findings.md`. The spike mod `.m0-sandbox/mod-spike/plugin/hooks/register.ts` and its listener `.m0-sandbox/mod-spike/listener.ts` show a working send and a working listener.

**Order:** This plan runs after M4 and before M5a. The worktree is `.worktrees/live` on the branch `live` from `main` at 2231a0a (M4 and the tab colours merged). M4 changes `registry.ts`, `service.ts` and `ipc.ts` (for example `forget`, `markStopped`, `lastActive`, `readProcessTable`, the watchlist), and adds `src/main/actions/`. Read the merged code for the exact form. This plan gives no line numbers for that reason. `main` moves to `live` only after the final review of this plan, not after each task: a half-done branch reads no hook files and has no install path yet.

## Global Constraints

- Write all prose, comments and commit bodies in ASD-STE100. Never use the em dash (also not in test strings: write `\u2014`). Wrap commit body lines at 100 characters. Use Conventional Commits.
- Write ESM TypeScript only. Do not write CommonJS. The mod is one file, `hooks/register.ts`. It imports only types from `claude-code` (`import type`). It imports no other file.
- Add no library. Node gives the socket server. The mod test kit comes with Claude Code.
- Names and paths (fixed, D1): plugin `bifrost-live`, marketplace `bifrost-local`, plugin ID `bifrost-live@bifrost-local`, scope `user`. Socket `<home>/.bifrost/live.sock` with mode 0600 in a directory with mode 0700. Mod folder `<home>/.bifrost/mod` (directories 0700, files 0600). The source of the mod is `resources/live-mod/`.
- Wire (D3): HTTP `POST http://bifrost/v1/event` over the socket, one JSON object in each request, `v: 1`. The server accepts a body of at most 65,536 bytes. The mod cuts `answer` to 4,000 characters and each other text to 200 characters.
- Times: the mod reads the usage again 2,500 ms after a main-loop `turn.complete`. It sends usage each 30,000 ms. A row is live for 90,000 ms after its last line. The `session.end` hook waits at most 200 ms for its send. The server request timeout is 5,000 ms. Each `claude plugin` command has a timeout of 30,000 ms.
- Bifrost runs `claude` only with the M4 list of arguments and these: `plugin list --json`, `plugin marketplace list --json`, `plugin marketplace add <absolute mod folder> --scope user --json`, `plugin install bifrost-live@bifrost-local --scope user --json`, `plugin enable bifrost-live@bifrost-local --scope user --json`, `plugin disable bifrost-live@bifrost-local --scope user --json`, `plugin uninstall bifrost-live@bifrost-local --scope user --json`, `plugin marketplace remove bifrost-local --scope user --json`.
- Live details needs Claude Code 2.1.290 or later. The minimum version of the app stays 2.1.281 (spec 11.5).
- The poll of `claude agents --json` stays the source of `kind`, `name`, `pid`, `cwd`, `status` and `waitingFor`. A red box for a `waiting` session needs no mod. The mod never sets `kind`.
- Safety: Vitest tests use temporary directories and a fake `RunClaude`. They never touch `~/.claude` or `~/.bifrost`. The mod tests answer `http.fetch` and `env.get` in the test, so no line reaches a real socket. Every `claude` call that an implementer or the controller types goes through `~/Developer/bifrost/.m0-sandbox/cl.sh`, also `plugin validate` and `plugin test`. (The running app uses its own `claude` path, as in M1 to M4.) No task installs the mod at user scope, except Task 9 Part B, and only after the user says yes (O1). Do not write files under `~/.claude/dev-mods/`.
- Test sessions: the name starts with `bifrost-test-`, `--model haiku`, the directory `~/Developer/bifrost/.m0-sandbox`. Never send input, a signal, `/reload-plugins`, `claude stop` or `claude rm` to another session. The user has real sessions open.
- Context isolation and the sandbox stay on. Each new IPC handler uses `fromPage`. The renderer sends no path and no command.
- `pnpm test`, `pnpm typecheck` and `pnpm check` pass after each task.
- Text that a person reads inside the app (panel lines, button names, error messages that reach the renderer) is plain, friendly English, not STE. It says "folder", not "directory". Keep the facts exact. The exact texts of this plan are allowed as written.
- A dev or check app always runs with its own `--user-data-dir` in the scratchpad: `pnpm exec electron-vite dev -- --user-data-dir=<dir> --remote-debugging-port=9333`. Quit it with SIGTERM to its own Electron main PID only. Never use `osascript`: the user's own Bifrost has the same bundle ID.
- Implementers never use `git stash`, `git checkout --`, `git restore` or `git reset`. Commit with `git commit -- <paths>` or after `git add` of the named paths only.

## Review Focus

1. Bifrost is closed, crashed or hung: the socket file is missing, stale, or a listener accepts and never answers. Expected: no hook waits for a send, Claude Code shows nothing, and tools and turns are not slower. Owner: Task 2 (`a hook does not wait for a send that never ends`, `a failed send changes nothing`) and Task 3 (`a request with no end is closed after the request timeout`).
2. Another program, or a second Bifrost (a dev build and a packaged build have different single-instance locks), uses `~/.bifrost/live.sock`, or the path is a normal file. Expected: Bifrost does not take a socket that answers, never deletes a file that is not a socket, and shows the reason in the status. Owner: Task 3 (`start does not take a socket that answers`, `start never deletes a file that is not a socket`).
3. Two sends race and arrive out of order, an error comes two times (`turn.complete` with `error` and `classic.StopFailure`), or a newer mod sends `v: 2`. Expected: the box follows the newest event, a repeated error keeps its box time and flash state, and Bifrost ignores the unknown version. Owner: Task 1 (`parseLiveLine refuses bad lines`) and Task 4 (`applyEvents drops a state event older than the newest applied event`, `a second StopFailure keeps the error box`).
4. `/clear`, a resume in the session, or `/reload-plugins` in a live session. Expected: after `/clear` the lines carry the new session ID, and a reload (it runs `session.start` again) does not clear a box. Owner: Task 2 (`each line carries the session id at the time of the send`) and Task 4 (`SessionStart keeps the box of a running session`).
5. The user stops a turn (Esc, or Interrupt in Bifrost) in a live session, and a session with no mod goes from `busy` to `idle`. Expected: no yellow box for a stopped turn, and a yellow box for the poll-only session (O3). Owner: Task 4 (`a live session gets no poll yellow after a stopped turn`, `a poll-only session gets a yellow box at busy to idle`).

## Decisions in this plan

The controller copies these lines into the assumptions table of the overnight log.

| # | Decision | Reason |
|---|---|---|
| D1 | Names and paths as in Global Constraints. The marketplace name `bifrost-local` is not `bifrost`, so a clash with another marketplace is less likely. Bifrost refuses a `bifrost-local` marketplace that has another path. | A fixed ID for the CLI calls. `marketplace remove` uninstalls every plugin of that marketplace. |
| D2 | The source of the mod is `resources/live-mod/` (electron-builder already unpacks `resources/**`). Bifrost copies exactly four files (`MOD_FILES`) to `~/.bifrost/mod` and adds that folder as the marketplace. Claude Code reads a plugin of a folder marketplace in place. At each start, when the plugin is on and the folder differs, Bifrost copies the files again. A running session gets the new files after `/reload-plugins` or a restart. | A path that does not move with the app, has no spaces, and is not inside a signed app bundle. No version bump is necessary for an in-place plugin. |
| D3 | Wire kinds: `session.start`, `session.end` (`reason`), `turn.start`, `ask`, `tool.done` (`tool`), `permission` (`tool`), `turn.complete` (`reason`, `answer`), `stop.failure` (`error`), `usage` (`model`, `context`, `costUsd`, `rateLimits`). Each line also has `v`, `kind`, `sid`, `at`, `seq`. The mod sends facts. The main process maps them (Task 1 table). | A thin mod. A change of the box rules needs no new mod. |
| D4 | Order: the registry drops a state event that is older than the newest applied event of the session (`at`, then `seq` when both events have one). | Each send is its own request. Two sends can arrive in the other order. One producer for each session makes "newest wins" correct. |
| D5 | Events that are not `classic.*` give all states. `classic.PermissionRequest` only makes the red box for a permission prompt faster (it arrives before the dialog). `classic.StopFailure` only repeats the error of `turn.complete`. `tool.check` gives no box, because in auto mode an `ask` goes to the classifier. Fallback where the guard `cc-plugin-sec-default` skips `classic.*`: the poll gives the permission red box within 2 s, and nothing else changes. | Spike: `classic.*` hooks do not run on Team or Enterprise logins. The poll already gives `waiting`. |
| D6 | Turn ends of the main loop: `answer` and `refusal` give a yellow box and keep `answer` as the last message. `aborted` gives `idle`, no box, and keeps the partial answer (the M1 hooks also gave no Stop for Esc). `error` gives the red error box. A subagent turn (`agentId`) changes nothing. `tool.done` of any loop gives Working (as `PostToolUse`). `ask` gives the red prompt box. | Parity with the M1 hook rules (spec 6.2, 7). A stop by the user needs no alert. |
| D7 | `session.start` from the mod only ends the parked state. For a running session it changes nothing. | The mod runs `session.start` again at each reload. A reload must not clear a box. A resume of a parked session starts a new process. |
| D8 | Usage comes from `session.start`, `session.measure`, one read 2,500 ms after each main-loop `turn.complete`, and a 30 s heartbeat. A usage line is not activity (`lastActivity` ignores it). The registry keeps the last usage line of each session and maps the model ID to a display name (`modelName`). | Spike gap 2: the cost changes about 2 s after the turn. Without the heartbeat, idle rows have no model, context or cost after a Bifrost start. The heartbeat also keeps the `live` flag of an idle row. |
| D9 | Bifrost listens on the socket only while the plugin is on (or the plugin state is unknown and the mod folder exists, or `BIFROST_LIVE_LISTEN=1` is set for a check). Turn off stops the server at once. Then the sends of running sessions fail in about 1 ms. | `enabledPlugins` does not reach a running session. The server is the switch that acts at once. |
| D10 | Install, Turn on and Remove first remove an old hook install with the M1 `uninstall`. A failure stops the action, and Bifrost then runs no `claude plugin` command. Bifrost no longer installs hooks or the wrapper. It makes no `active` file, reads no event files or status files, and writes no `quiet` files. It keeps `statusline-original.json` and the backups. | The user's decision: the mod replaces the hooks and the wrapper. One data path. An old install without `active` does nothing. |
| D11 | API for M5a: `live.status()`, `live.install()`, `live.enable()`, `live.disable()`, `live.uninstall()`, each with `LiveStatus` (Task 6). `enable` refuses when the plugin is not installed. A Live details switch in M5a calls `install` when `plugin` is `not-installed`, else `enable` or `disable`. | A clear API. M5a owns the UI. |
| D12 | Rate limits: the parser keeps `five_hour` and `seven_day` as `RateLimits` (the type that M5b Task 1 names) and drops other windows. The registry keeps them in the usage of each session. This plan adds no Usage HUD. | M5b reads them from the registry, not from status files. |
| D13 | New session always passes `--settings NO_STATUSLINE_SETTINGS` (Task 7). M4 passed it only when the wrapper was not installed (spec 22). After this plan, Bifrost never installs the wrapper and reads no status files, so the wrapper gives Bifrost nothing. Resume and Take control still add no flags. | O4 option a. The user chose "flag only without the wrapper" while the wrapper still gave Bifrost the usage data. The mod now gives that data. |
| D14 | The spec gets a new section 23 for this plan. Section 22 (M4) keeps its text, with a note that section 23 changes its statusline line. | M4 already used section 22. |

## Open points (each waits for the user)

| # | Question | Recommendation | Where it acts |
|---|---|---|---|
| O1 | May a controller task install the mod at user scope for a short time (spike step 3, and the real install, enable, disable and remove)? Waits for the user. | Yes. Run it as Task 9 Part B, only after Part A passes. Save `~/.claude/settings.json`, `~/.claude/plugins/installed_plugins.json` and `~/.claude/plugins/known_marketplaces.json` first, and record their SHA-256. Do not run `/reload-plugins` in the user's sessions. After Remove, compare the settings with `jq -S` and record each difference. | Task 9 Part B. Without a yes, Part B does not run, and the install path has only the fake-CLI tests of Tasks 5 and 6. |
| O2 | Run `/plugin` in one of the user's sessions. Is `cc-plugin-sec-default` in the Built-in list? Waits for the user. | The user runs it once. The plan does not depend on the answer (D5). If the guard is there, the permission red box comes from the poll (up to 2 s later). | Task 9 records the answer. No code change. |
| O3 | Poll-only yellow box: when no mod runs for a session, does a change from `busy` (or `waiting`) to `idle` set a yellow box? Waits for the user. | Yes. A turn that starts and ends between two polls gives no box. The first sample after a Bifrost start gives no box. | Task 4. If the user says no before Task 4 runs, leave out the rule and its two tests, and Task 8 leaves out spec rule 11. |
| O4 | With no wrapper, Claude Code runs your own statusLine command again in every session, also in owned background sessions, and chat windows show its row. Spec 20 item 1 goes away. Is that correct? Waits for the user. | Accept it now. A mod cannot stop the statusLine command (the mod API has no status line hook). Later options: Bifrost starts owned sessions with a `--settings` statusLine override (not tested), or `claude-statusline` skips a session that Bifrost marks. | Task 7 removes the `quiet` marker. Task 8 changes spec 6.3 and 20 item 1. |

## Effects on later plans

- M5a Task 4 (setup dialog, Settings > Integration): use `live.*` and `LiveStatus` in place of `integration.*`, `IntegrationStatus` and `InstallPreview`. The setup dialog offers "Turn on Live details" or "Skip". It lists what Bifrost does: the old hook removal (when `oldInstall` is true), the folder `~/.bifrost/mod`, and the `claude plugin` commands. `previewInstall`, `backupDir`, `hookTotal`, `wrapperCommand` and the `integrationNotice` repair rules go away. Show a notice when `oldInstall` is true. Show `Sessions that run now get the change after /reload-plugins or a restart.` after Install and Turn on. The M5a test home must also give the mod folder and the socket under the test home.
- M5b Task 1: the model, context %, cost and rate limits come from the live usage in the registry, not from status files. The transcript path, the effort, the Claude Code version and the permission mode are not in the live data. M5b adds them to the mod (`v: 1` can get new optional fields) or leaves them out. The Event log (spec 8.7) shows the live state events.
- The M4 list of `claude` arguments gets the plugin commands of Global Constraints.

---

## File structure

| File | Responsibility |
|---|---|
| `src/shared/uuid.ts` | `UUID_PATTERN` and `isUuid`. It replaces the export of `src/main/integration/scripts.ts`. |
| `src/main/live/live-event.ts` | The wire contract: check one line and map it to a state event or a usage line. |
| `src/main/live/model-name.ts` | The display name of a model ID. |
| `src/main/live/live-server.ts` | The HTTP server on the Unix socket: take the path safely, limits, stop. |
| `src/main/live/plugin-cli.ts` | The `claude plugin` commands and their JSON output. |
| `src/main/live/mod-folder.ts` | Copy, compare and remove `~/.bifrost/mod`. |
| `src/main/live/live-control.ts` | Install, Turn on, Turn off, Remove, the status, and the start rule. |
| `resources/live-mod/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `hooks/hooks.json`, `hooks/register.ts` | The mod (the four `MOD_FILES`). |
| `resources/live-mod/tests/register.test.ts` | The mod tests for `claude plugin test`. Bifrost does not copy them. |
| `docs/live-findings.md` | Results of Task 9. |

Changed: `src/shared/types.ts`, `src/shared/api.ts`, `src/preload/index.ts`, `src/main/ipc.ts`, `src/main/claude/version.ts`, `src/main/registry/hook-event.ts`, `state-machine.ts`, `registry.ts`, `service.ts`, `src/main/integration/integration.ts`, `settings-plan.ts`, `src/renderer/src/panels/IntegrationPanel.tsx`, `.gitignore`, `biome.json`, `docs/specs/2026-11-04-bifrost-design.md`.

Deleted: `src/main/registry/event-dir.ts`, `src/main/registry/status-file.ts`, `src/main/integration/active-marker.ts`, `src/main/integration/quiet-marker.ts`, `src/main/integration/scripts.ts`, and their tests (`event-dir.test.ts`, `status-file.test.ts`, `hook-event.test.ts`, `active-marker.test.ts`, `quiet-marker.test.ts`, `scripts.test.ts`).

Names from earlier milestones (read the code for the exact form): M4 `RegistryService.forget`, `markStarted`, `markStopped`, `waitForRow`, `SessionRegistry.forget`, `ServiceDeps.readProcessTable`. M1 `HookEvent`, `HookEventName`, `onHookEvent`, `onStatus`, `MachineState`, `SessionRegistry.applyAgents`, `applyAllAgents`, `applyEvents`, `RegistryService`, `ServiceDeps`, `SERVICE_TIMING`, `PENDING_EVENT_MS`, `uninstall`, `checkInstall`, `planUninstall`, `HOOK_ROWS`, `defaultPaths`, `createSerialRunner`, `fromPage`, `RunClaude`, `ExecResult`, `checkClaudeVersion`, `compareVersions`.

---

### Task 1: Wire contract and model names

**Files:**
- Create: `src/shared/uuid.ts`, `src/main/live/live-event.ts`, `src/main/live/model-name.ts`
- Modify: `src/shared/types.ts`, `src/main/registry/hook-event.ts`, `src/main/integration/scripts.ts` (re-export `UUID_PATTERN` from `src/shared/uuid.ts` until Task 7 deletes the file)
- Test: `test/shared/uuid.test.ts`, `test/main/live/live-event.test.ts`, `test/main/live/model-name.test.ts`

**Interfaces:**
- Consumes: `HookEvent`, `HookEventName` (M1).
- Produces:
  - `src/shared/uuid.ts`: `UUID_PATTERN` (the M1 text), `isUuid(value: unknown): value is string`.
  - `src/shared/types.ts`: `interface RateWindow { usedPercent: number; resetsAt: number }` (`resetsAt` in ms), `interface RateLimits { fiveHour?: RateWindow; sevenDay?: RateWindow }`.
  - `hook-event.ts`: `HookEventName` adds `'TurnAborted'` (comment: no hook has this name; the mod gives it for a turn that the user stopped). `HookEvent` adds `seq?: number`. Leave `parseHookEvent` for Task 4.
  - `live-event.ts`: `LIVE_VERSION = 1`, `ANSWER_MAX = 4000`, `TEXT_MAX = 200`, `AT_DRIFT_MS = 10_000`, `interface LiveUsage { model?: string; contextPercent?: number; contextTokens?: number; contextWindow?: number; costUsd?: number; rateLimits?: RateLimits }`, `type LiveEvent = { type: 'state'; event: HookEvent } | { type: 'usage'; sessionId: string; at: number; usage: LiveUsage }`, `parseLiveLine(text: string, receivedAt: number): LiveEvent | null`.
  - `model-name.ts`: `modelName(id: string): string`.

The wire table. Put it in the header comment of `live-event.ts`. It is the contract with the mod (Task 2).

| `kind` | Fields (also `v`, `kind`, `sid`, `at`, `seq`) | Result |
|---|---|---|
| `session.start` | none | `SessionStart` |
| `session.end` | `reason` (string) | `SessionEnd` |
| `turn.start` | none | `UserPromptSubmit` |
| `ask` | none | `PreToolUse`, `toolName: 'AskUserQuestion'` |
| `tool.done` | `tool` (string) | `PostToolUse`, `toolName` |
| `permission` | `tool` (string) | `PermissionRequest`, `toolName` |
| `turn.complete` | `reason`: `answer` or `refusal` | `Stop`, `lastAssistantMessage` = `answer` when not empty |
| `turn.complete` | `reason`: `aborted` | `TurnAborted`, `lastAssistantMessage` = `answer` when not empty |
| `turn.complete` | `reason`: `error` | `StopFailure` |
| `stop.failure` | `error` (string, optional) | `StopFailure` |
| `usage` | `model`, `context { tokens?, window, percent? }`, `costUsd?`, `rateLimits [{ kind, percentUsed, resetsAt? }]` | usage line |

Rules for `parseLiveLine`:
- Return null when the text is not a JSON object, `v !== 1`, `kind` is not in the table, `sid` is not a UUID, or `at` is not a finite number. Return null for a missing required field of a state kind (`tool` of `tool.done` and `permission`, `reason` of `session.end`, a `reason` of `turn.complete` that is not one of the four words).
- `at`: when `Math.abs(at - receivedAt) > AT_DRIFT_MS`, use `receivedAt`.
- `seq`: keep it only when it is a safe integer of 0 or more.
- Cut `answer` to `ANSWER_MAX` and `tool`, `reason`, `error` and `model` to `TEXT_MAX` characters.
- A usage line leaves out each bad field and keeps the line: `model` a string that is not empty; `context.percent` finite, 0 to 100; `context.tokens` a safe integer of 0 or more; `context.window` finite above 0; `costUsd` finite, 0 or more. `rateLimits`: keep `five_hour` as `fiveHour` and `seven_day` as `sevenDay` when `percentUsed` is finite, 0 to 100, and `Date.parse(resetsAt)` is finite. Leave out other kinds (for example `spend_limit`). With no window, leave out `rateLimits`.

`modelName` rules: `^claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$` gives the family with a capital letter, the major number, `.minor` when there is one, and ` (1M context)` for `[1m]`. Any other ID gives the ID.

- [ ] **Step 1: Write the failing tests**

`test/shared/uuid.test.ts`:
- `isUuid accepts a UUID and refuses other values`: `73b5ca76-a4a8-4f97-9764-e41657296414` gives true. `73b5ca76`, `''`, `1` and `null` give false.

`test/main/live/live-event.test.ts` (with `S = '73b5ca76-a4a8-4f97-9764-e41657296414'`, `line = (o) => JSON.stringify({ v: 1, sid: S, at: 1000, seq: 3, ...o })`, `receivedAt` 1005):
- `parseLiveLine maps each state kind` (one `test.each` row for each state row of the wire table). Examples:
  - `{ kind: 'turn.complete', reason: 'answer', answer: 'ALPHA' }` gives `{ type: 'state', event: { name: 'Stop', sessionId: S, at: 1000, seq: 3, lastAssistantMessage: 'ALPHA' } }`.
  - `{ kind: 'turn.complete', reason: 'aborted', answer: '1\n2' }` gives `name: 'TurnAborted'` and `lastAssistantMessage: '1\n2'`.
  - `{ kind: 'turn.complete', reason: 'error', answer: '' }` gives `name: 'StopFailure'` and no `lastAssistantMessage`.
  - `{ kind: 'ask' }` gives `name: 'PreToolUse'`, `toolName: 'AskUserQuestion'`.
  - `{ kind: 'permission', tool: 'Bash' }` gives `name: 'PermissionRequest'`, `toolName: 'Bash'`.
- `parseLiveLine reads a usage line`: `{ kind: 'usage', model: 'claude-haiku-5-5', context: { tokens: 58151, window: 1000000, percent: 6 }, costUsd: 0.00691591, rateLimits: [{ kind: 'seven_day', percentUsed: 15, resetsAt: '2026-11-07T02:00:00.000Z' }] }` gives `{ type: 'usage', sessionId: S, at: 1000, usage: { model: 'claude-haiku-5-5', contextTokens: 58151, contextWindow: 1000000, contextPercent: 6, costUsd: 0.00691591, rateLimits: { sevenDay: { usedPercent: 15, resetsAt: Date.parse('2026-11-07T02:00:00.000Z') } } } }`.
- `parseLiveLine leaves out a bad usage field and keeps the line`: `percent: 101`, `costUsd: -1`, a `spend_limit` window and a window with `resetsAt: 'soon'` give `usage: { contextTokens: 58151, contextWindow: 1000000, model: ... }` with no `contextPercent`, `costUsd` or `rateLimits`.
- `parseLiveLine refuses bad lines`: `not json`, `[]`, `null`, `v: 2`, `kind: 'hello'`, `sid: 'abc'`, `at: 'x'`, `tool.done` with no `tool`, `turn.complete` with `reason: 'other'`. Each gives null.
- `parseLiveLine cuts long texts`: an `answer` of 5,000 characters gives 4,000. A `tool` of 300 characters gives 200.
- `parseLiveLine uses the receive time for a far time`: `at: 1000 + 20_000` with `receivedAt` 1005 gives `at: 1005`.
- `parseLiveLine drops a bad seq`: `seq: -1` and `seq: 1.5` give no `seq`.

`test/main/live/model-name.test.ts`:
- `modelName gives the display name for each family`: `claude-haiku-5-5` gives `Haiku 5.5`. `claude-opus-5-5` gives `Opus 5.5`. `claude-sonnet-4-5-20250929` gives `Sonnet 4.5`. `claude-opus-4` gives `Opus 4`. `claude-opus-5-5[1m]` gives `Opus 5.5 (1M context)`. `claude-fable-5-5` gives `Fable 5.5`.
- `modelName gives the ID for an unknown model`: `us.anthropic.claude-x-v1:0` and `gpt-5` stay the same.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/shared/uuid.test.ts test/main/live`
Expected: FAIL (the modules do not exist).

- [ ] **Step 3: Implement `isUuid`, the types, `parseLiveLine` and `modelName`**

Use `isUuid` in `parseLiveLine`. Change `scripts.ts` to `export { UUID_PATTERN } from '../../shared/uuid'`, so its old imports still work.

- [ ] **Step 4: Run all checks**

Run: `pnpm test && pnpm typecheck && pnpm check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/shared src/main/live src/main/registry/hook-event.ts src/main/integration/scripts.ts test/shared test/main/live
git commit -m "feat(live): read the lines of the Live details mod" \
  -m "Bifrost checks each line of the mod and ignores bad data. It maps each line to a state" \
  -m "event or to usage data. It also gives a display name for a model ID."
```

---

### Task 2: The mod

**Files:**
- Create: `resources/live-mod/.claude-plugin/plugin.json`, `resources/live-mod/.claude-plugin/marketplace.json`, `resources/live-mod/hooks/hooks.json`, `resources/live-mod/hooks/register.ts`, `resources/live-mod/tests/register.test.ts`
- Modify: `.gitignore` (add `resources/live-mod/.claude-plugin/types/` and `resources/live-mod/tsconfig.json`; the engine can write them), `biome.json` (add `resources/live-mod/**/*` to `files.includes`, and `!**/live-mod/.claude-plugin/types/**/*`)

**Interfaces:**
- Consumes: the wire table of Task 1 (the mod has its own copy of the kinds; it imports nothing from `src`).
- Produces: the four `MOD_FILES` that Task 5 copies. The mod hooks `session.start`, `session.end`, `turn.start`, `turn.complete`, `tool.call`, `session.measure`, `classic.PermissionRequest` and `classic.StopFailure`, and calls `$.http.fetch`, `$.env.get("HOME")`, `$.session.id`, `$.session.model`, `$.session.usage`, `$.clock.after`, `$.clock.every` and `$.clock.sleep`.

Read the API in the type file of this Claude Code build before you write code. Find it with `ls /private/tmp/claude-501/bundled-skills/*/*/plugin-authoring/types/claude-code.d.ts`. If the list is empty, load the `plugin-authoring` skill with the Skill tool: its text names the file. Grep the file for `'turn.complete'`, `TurnCompleteFields`, `SessionUsage`, `SessionMeasureInput`, `SessionEndInput`, `HttpInit`, `export const mock` and `claude-code/testing`. Use the spike mod `.m0-sandbox/mod-spike/plugin/hooks/register.ts` as an example of a working send.

Manifests (exact):
- `plugin.json`: `{ "name": "bifrost-live", "version": "1.0.0", "description": "Live details for Bifrost. Sends session events to the Bifrost socket on this Mac." }`
- `marketplace.json`: `{ "name": "bifrost-local", "owner": { "name": "Bifrost" }, "plugins": [{ "name": "bifrost-live", "source": "./" }] }`
- `hooks.json`: `{ "modules": ["./register.ts"] }`

Rules for `register.ts` (`export const register: Register = on => { ... }`):
- Constants: `URL = 'http://bifrost/v1/event'`, `SOCKET = '/.bifrost/live.sock'` (after HOME), `ANSWER_MAX = 4000`, `TEXT_MAX = 200`, `USAGE_DELAY_MS = 2500`, `HEARTBEAT_MS = 30_000`, `END_WAIT_MS = 200`.
- `send($, kind, data, sid?)`: take `at = Date.now()` and `seq = ++seq` before the first `await`. Then read the session ID (`sid` when given, else `await $.session.id()` at each send) and HOME (one `$.env.get("HOME")` for each module load, kept as a promise). No HOME: send nothing. Then `$.http.fetch(URL, { method: 'POST', socketPath, headers: { 'content-type': 'application/json' }, body: JSON.stringify({ v: 1, kind, sid, at, seq, ...data }) })`. The promise that `send` gives never rejects.
- `sendUsage($, figures?)`: the model from `$.session.model()`, and the figures of `session.measure` or else of `$.session.usage()`. Send `usage` with `model`, `context` (`tokens`, `window`, `percent`; never `breakdown`), `costUsd` (from `cost.usd`) and `rateLimits`. It never rejects.
- No hook waits for a send, except `session.end`. Each hook calls `void send(...)`, then `return next(e)`. Register each hook with `.catch(($, e, next) => next(e))`.
- `session.start`: `const r = await next(e)`. Then send `session.start`, send usage, and start `$.clock.every(HEARTBEAT_MS, () => void sendUsage($))`. Return `r`.
- `session.end`: `const r = await next(e)`. Then `await Promise.race([send($, 'session.end', { reason: e.reason }, e.sessionId), $.clock.sleep(END_WAIT_MS).catch(() => {})])`. Return `r`.
- `turn.start`: only with no `e.agentId`, send `turn.start`.
- `turn.complete`: only with no `e.agentId`, send `turn.complete` with `reason` and `answer.slice(0, ANSWER_MAX)`, and start `$.clock.after(USAGE_DELAY_MS, () => void sendUsage($))`.
- `tool.call`: for `e.tool === 'AskUserQuestion'`, send `ask` before `next`. After `await next(e)`, send `tool.done` with `tool: String(e.tool).slice(0, TEXT_MAX)` (all loops). Return the result of `next`.
- `session.measure`: send usage with the figures of `e`.
- `classic.PermissionRequest`: send `permission` with `tool: e.tool_name` (cut). `classic.StopFailure`: send `stop.failure` with `error: String(e.error)` (cut).
- A comment at the top says: the mod sends one line for each event to the Bifrost socket; it never waits for a send before the engine continues; a missing socket fails in about 1 ms and shows nothing.

- [ ] **Step 1: Write the manifests and the failing tests**

`tests/register.test.ts` imports `test`, `expect` and `mock` from `claude-code/testing`. Each test: `mock.env(on, { HOME: '/h' })`, `mock.clock(on)` where a test moves time, an `http.fetch` hook beneath the plugin that records `JSON.parse(e.init.body)` and answers `{ value: { status: 204, ok: true, headers: {}, text: '' } }`, and hooks that answer `session.id` (`S`), `session.model` (`'claude-haiku-5-5'`) and `session.usage`. Assert each fetch has the URL `http://bifrost/v1/event`, `method: 'POST'` and `socketPath: '/h/.bifrost/live.sock'`.
- `turn.complete sends the answer and the reason`: one line `{ v: 1, kind: 'turn.complete', sid: S, reason: 'answer', answer: 'ALPHA' }` with a number `at` and a number `seq`.
- `a subagent turn sends no turn line`: `turn.start` and `turn.complete` with `agentId: 'a1'` give no `turn.*` line.
- `the answer is cut to 4000 characters`
- `tool.call sends ask before an AskUserQuestion call and tool.done after each call`: the kinds are `['ask', 'tool.done']` for `AskUserQuestion` and `['tool.done']` for `Bash`. The `ask` line comes before the engine hook of `tool.call` runs.
- `a hook does not wait for a send that never ends`: the `http.fetch` hook gives a promise that never settles. `$.tool.call`, `$.turn.complete` and `$.session.start` still resolve with the engine results.
- `a failed send changes nothing`: the `http.fetch` hook throws an `ENOENT` error. The results are the engine results. No error reaches the test.
- `each line carries the session id at the time of the send`: `session.id` answers `S1`, then `S2` after a `session.end` with `reason: 'clear'`. The `session.end` line has `S1` (from `e.sessionId`). The next `turn.start` line has `S2`.
- `turn.complete reads the usage again after 2500 ms`: no `usage` line after `advance(2499)`, one after `advance(1)`, with `model: 'claude-haiku-5-5'` and `costUsd`.
- `session.start sends session.start and usage, then usage each 30 s`: the kinds are `['session.start', 'usage']`. `advance(30_000)` adds one `usage` line. `advance(30_000)` adds one more.
- `session.end sends the ending session id and waits at most 200 ms`: with a fetch that never settles, `$.session.end(...)` resolves after `advance(200)`.
- `classic events send permission and stop.failure`: `PermissionRequest` with `tool_name: 'Bash'` gives `{ kind: 'permission', tool: 'Bash' }`. `StopFailure` with `error: 'server_error'` gives `{ kind: 'stop.failure', error: 'server_error' }`.
- `session.measure sends the context, the cost and the rate limits`: `context { tokens: 58151, window: 1000000, percent: 6 }`, `cost { usd: 0.0069 }`, `rateLimits [{ kind: 'seven_day', percentUsed: 15, resetsAt: '2026-11-07T02:00:00.000Z' }]` give a `usage` line with those values and `costUsd: 0.0069`.
- `no HOME gives no send`: `mock.env(on, {})` and a `turn.complete` give no fetch.

- [ ] **Step 2: Run the tests and see them fail**

Run: `~/Developer/bifrost/.m0-sandbox/cl.sh plugin test "$PWD/resources/live-mod"`
Expected: exit 1. The tests fail, because `register.ts` has no hooks yet (write it with an empty `register` first).

- [ ] **Step 3: Implement `register.ts`**

- [ ] **Step 4: Run the mod checks**

Run: `~/Developer/bifrost/.m0-sandbox/cl.sh plugin test "$PWD/resources/live-mod"`
Expected: exit 0. All tests pass.

Run: `~/Developer/bifrost/.m0-sandbox/cl.sh plugin validate "$PWD/resources/live-mod"`
Expected: exit 0, no error. The report lists the 8 hooks and the `$` calls of the Interfaces block, and the env name `HOME`.

Write a tsconfig in your scratchpad, not in the repository: the options of the type file header, and `"include": ["<type file>", "<absolute path>/resources/live-mod/hooks", "<absolute path>/resources/live-mod/tests"]`. Run: `pnpm exec tsc -p <that tsconfig>`
Expected: no error.

Run: `pnpm test && pnpm typecheck && pnpm check`
Expected: PASS. `git status` shows no `.claude-plugin/types/` file.

- [ ] **Step 5: Commit**

```bash
git add resources/live-mod .gitignore biome.json
git commit -m "feat(mod): add the Live details mod" \
  -m "The mod sends one JSON line for each session event to the Bifrost socket." \
  -m "It never waits for a send before the engine continues. It sends the usage again" \
  -m "2.5 s after a turn and each 30 s."
```

---

### Task 3: Socket server

**Files:**
- Create: `src/main/live/live-server.ts`
- Test: `test/main/live/live-server.test.ts`

**Interfaces:**
- Consumes: `parseLiveLine`, `LiveEvent` (Task 1).
- Produces:
  - `LIVE_PATH = '/v1/event'`, `LIVE_BODY_MAX = 65_536`, `REQUEST_TIMEOUT_MS = 5000`, `MAX_CONNECTIONS = 64`
  - `interface LiveServerState { listening: boolean; error?: string }`
  - `interface LiveServer { start(): Promise<LiveServerState>; stop(): void; state(): LiveServerState }`
  - `createLiveServer(opts: { socketPath: string; onEvent(ev: LiveEvent): void; now(): number; requestTimeoutMs?: number; checkIntervalMs?: number }): LiveServer`

Rules:
- `start` (a second call while it listens gives the state):
  1. Make the directory of the socket with mode 0700. If it exists, set its mode to 0700.
  2. `lstat` the path. A missing path: listen. A socket: try `net.connect` (500 ms limit). A connection: do not listen, and give `{ listening: false, error: 'Another program listens on <path>.' }`. `ECONNREFUSED`: delete the stale file, then listen. Another error: do not listen, and give its message. Not a socket: do not listen, and give `{ listening: false, error: '<path> exists and is not a socket. Bifrost did not change it.' }`.
  3. Listen with `http.createServer({ requestTimeout, headersTimeout: requestTimeout, connectionsCheckingInterval })` (defaults 5000 ms and 1000 ms). Set `maxConnections` to 64. After `listen`, set the mode of the socket to 0600.
- A request: only `POST` to `/v1/event`. Else answer 404. Collect the body. Over 65,536 bytes: answer 413 and destroy the request. At the end: answer 204 first, then `parseLiveLine(body, now())`. Call `onEvent` only for a result that is not null. A throw in `onEvent` goes to `console.error` and does not stop the server. A bad line also gets 204 (the mod does nothing with the answer).
- `stop` is synchronous (Bifrost calls it in `will-quit`): close the server and all its connections, and delete the socket file only when this server made it. A second call does nothing.

- [ ] **Step 1: Write the failing tests**

Each test makes a short directory with `mkdtemp(join(tmpdir(), 'bl-'))` (the socket path must stay under 100 bytes) and sends with `http.request({ socketPath, method, path })`.
- `start listens on the socket with mode 0600 in a directory with mode 0700`
- `a POST of a good line gives 204 and one event`: a `turn.complete` line gives `onEvent` one time with `{ type: 'state', event: { name: 'Stop' } }` (match).
- `a bad line gives 204 and no event`
- `another path or method gives 404 and no event`: `GET /v1/event` and `POST /other`.
- `a body over 65536 bytes gives 413 and no event`
- `a request with no end is closed after the request timeout`: `requestTimeoutMs: 200`, `checkIntervalMs: 50`. Write the headers and part of a body, and do not end. The socket closes within 1 s. `onEvent` is not called.
- `start replaces a stale socket file`: a child `node -e` process listens on the path and kills itself with SIGKILL, so the file stays. `start` gives `listening: true`.
- `start does not take a socket that answers`: another `net` server listens on the path. `start` gives `listening: false` and the error text. The other server still accepts a connection after `stop`.
- `start never deletes a file that is not a socket`: a normal file at the path stays with its content.
- `stop closes the server and removes the socket file`, and `a second stop does nothing`.
- `a throw in onEvent does not stop the server`: the next good line still gives an event.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/main/live/live-server.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `createLiveServer`**

- [ ] **Step 4: Run all checks**

Run: `pnpm test && pnpm typecheck && pnpm check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/live/live-server.ts test/main/live/live-server.test.ts
git commit -m "feat(live): listen for the mod on a Unix socket" \
  -m "The server answers each line at once and checks it. It does not take a socket that" \
  -m "another program uses, and it never deletes a file that is not a socket."
```

---

### Task 4: Live events and usage in the registry

**Files:**
- Modify: `src/main/registry/hook-event.ts` (delete `parseHookEvent` and `NAMES`; keep the types), `src/main/registry/state-machine.ts`, `src/main/registry/registry.ts`, `src/main/registry/service.ts`, `src/main/ipc.ts`, `src/shared/types.ts`
- Delete: `src/main/registry/event-dir.ts`, `src/main/registry/status-file.ts`, `src/main/integration/active-marker.ts`, `test/main/registry/event-dir.test.ts`, `test/main/registry/status-file.test.ts`, `test/main/registry/hook-event.test.ts`, `test/main/integration/active-marker.test.ts`
- Test: `test/main/registry/state-machine.test.ts`, `test/main/registry/registry.test.ts`, `test/main/registry/service.test.ts`

**Interfaces:**
- Consumes: `HookEvent` with `seq` and `TurnAborted`, `LiveEvent`, `LiveUsage`, `modelName` (Task 1); `SessionRegistry.forget` (M4).
- Produces:
  - `src/shared/types.ts`: `SessionRow.live?: true` (the session sent a line in the last 90 s).
  - `state-machine.ts`: the sample of `onStatus` becomes `{ status: string; waitingFor?: string; sampledAt: number; prevStatus?: string; live?: boolean }`.
  - `registry.ts`: `LIVE_FRESH_MS = 90_000`; `applyEvents(events: HookEvent[], now: number): void` (now with the order rule); `applyUsage(sessionId: string, usage: LiveUsage, at: number): void`; `liveCount(): number`. `applyStatusFiles` goes away.
  - `service.ts`: `RegistryService.pushLive(ev: LiveEvent): void`, `RegistryService.liveCount(): number`. `ServiceDeps` loses `drainEvents` and `readStatus`. `SERVICE_TIMING` loses `eventsMs` and `statusMs`.

Rules for the state machine:
- `SessionStart` (D7): a parked session goes to `idle` with no box. Any other state stays as it is.
- `TurnAborted` (D6): `idle`, no box. `lastMessage` becomes `lastAssistantMessage` when the event has one.
- `StopFailure`: when the box is the red error box already, return the state as it is (box time, flash state). Else as before.
- `onStatus`, poll-only yellow (O3): apply the M1 rules first. When the result has no box, the state is not parked, `sample.live` is not true, and `sample.prevStatus` is `busy` or `waiting`, give a yellow box at `sampledAt` with `confirmed: true`, state `needs-you`, and keep `lastMessage`.

Rules for the registry:
- Keep two maps by session ID, also for a session that the registry does not know yet: `liveAt` (the newest `at` of any line) and `usage` (the newest usage line with `updatedAt`). Keep `clock`, the newest time of `applyAgents`, `applyEvents`, `applyUsage` and `tick`. A session is live when `clock - liveAt <= LIVE_FRESH_MS`.
- `applyEvents` (D4): set `liveAt` for each event. Skip the state change of an event when `ev.at < s.lastEventAt`, or when `ev.at === s.lastEventAt`, both events have a `seq`, and `ev.seq <= s.lastEventSeq`. Else apply it and keep its `at` and `seq`. Pending events of unknown sessions follow the same rule when they apply.
- `applyUsage`: set `liveAt` and `usage`. It does not change `lastEventAt`, so it is not activity.
- `applyAgents`: give `onStatus` the `prevStatus` (the status of the session before this sample; `undefined` for a new session) and `live`.
- `toRow`: `model` is `modelName(usage.model)`, and `contextPercent` and `costUsd` come from the usage. `live: true` for a live row. `lastActivity` is `max(startedAt, lastEventAt, statusChangedAt)`. The name order loses the status file step.
- `applyAllAgents` removes the `usage` and `liveAt` entries of a session that is not `known()`, as for the names. `forget` removes them too.
- `liveCount()`: the number of rows that are live and not parked.

Rules for the service and `ipc.ts`:
- `pushLive`: a `state` event goes to `applyEvents([ev.event], now())`, a `usage` line to `applyUsage(ev.sessionId, ev.usage, ev.at)`. Then `changed()`. So the update limit of 4 each second stays.
- Delete the events loop and the status loop. In `ipc.ts`, delete `startScripts` (the clean of the event directory and of the status temporary files, and the active marker) and the `drainEvents` and `readStatus` deps. `stopRegistry` no longer deletes a marker. Keep the quiet marker until Task 7.

- [ ] **Step 1: Write the failing tests**

`state-machine.test.ts` (change and add):
- Replace `SessionStart gives idle with no box` with `SessionStart keeps the box of a running session`: a yellow box at 1, then `SessionStart` at 2, gives the same state (`toEqual`). Keep `a parked session ignores status and leaves only on SessionStart`.
- `TurnAborted gives idle with no box and keeps the partial answer`: Working, then `TurnAborted` at 10 with `lastAssistantMessage: 'part'`, gives `{ state: 'idle', box: 'none', acknowledged: true, lastMessage: 'part' }`.
- `a second StopFailure keeps the error box, its time and its flash state`: `StopFailure` at 5, `onAcknowledge`, `StopFailure` at 6 gives `boxSince: 5` and `acknowledged: true`.
- `an idle sample after busy gives a yellow box for a poll-only session`: a busy sample at 1000, then `{ status: 'idle', sampledAt: 3000, prevStatus: 'busy', live: false }` gives `{ state: 'needs-you', box: 'yellow', boxSince: 3000, confirmed: true, acknowledged: false }`.
- `an idle sample after waiting gives a yellow box for a poll-only session`: a waiting sample at 1000 (red, confirmed), then idle at 3000 with `prevStatus: 'waiting'`, gives yellow at 3000.
- `an idle sample gives no yellow box for a live session, after idle, or as the first sample`: `live: true`, `prevStatus: 'idle'` and no `prevStatus` each give `box: 'none'`.

`registry.test.ts` (add; the old `applyStatusFiles` tests use `applyUsage`; change each test that expects `SessionStart` to clear the box of a running session):
- `applyEvents drops a state event older than the newest applied event`: `Stop` at 300, then `PostToolUse` at 200. The row stays yellow.
- `applyEvents uses seq for two events with the same time`: `Stop` at 300 with `seq` 5. `PostToolUse` at 300 with `seq` 4 changes nothing. `PostToolUse` at 300 with `seq` 6 gives Working.
- `applyUsage gives the model name, the context and the cost to the row`: `{ model: 'claude-haiku-5-5', contextPercent: 6, costUsd: 0.01 }` gives `model: 'Haiku 5.5'`, `contextPercent: 6`, `costUsd: 0.01`.
- `a usage line is not activity`: `lastActivity` does not change.
- `a usage line for an unknown session shows when the session comes`
- `a row is live for 90 s after its last line`: a usage line at 1000. After `tick(91_000)` the row has `live: true` and `liveCount()` is 1. After `tick(91_001)` the row has no `live` and `liveCount()` is 0.
- `a poll-only session gets a yellow box at busy to idle`: samples `busy` at 1000 and `idle` at 3000 give yellow.
- `a live session gets no poll yellow after a stopped turn`: `busy` at 1000, `UserPromptSubmit` at 1500, `TurnAborted` at 2500, `idle` at 3000 give `idle` with no box.
- `the first sample after the start gives no yellow box`
- `applyAllAgents removes the usage of a session that left all lists`, and `forget removes the usage of the session`

`service.test.ts` (the fakes lose `drainEvents` and `readStatus`; delete the tests of those loops):
- `pushLive applies a state event and sends an update`: after the first poll, a `Stop` event gives an update with a yellow box.
- `pushLive applies a usage line`: the next update has the cost.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/main/registry`
Expected: FAIL.

- [ ] **Step 3: Implement the machine rules, the registry maps, `pushLive`, and remove the file readers**

- [ ] **Step 4: Run all checks**

Run: `pnpm test && pnpm typecheck && pnpm check`
Expected: PASS. `rg -n "event-dir|status-file|active-marker|drainEvents|readStatus" src test` gives no match.

- [ ] **Step 5: Commit**

```bash
git add -A src/main/registry src/main/integration/active-marker.ts src/main/ipc.ts src/shared/types.ts test/main/registry test/main/integration/active-marker.test.ts
git commit -m "feat(registry): use the live events and the usage lines of the mod" \
  -m "The registry applies the newest event of each session and keeps its usage line." \
  -m "A session with no mod gets a yellow box when the poll shows busy and then idle." \
  -m "Bifrost no longer reads event files or status files, and makes no active file."
```

---

### Task 5: Plugin commands and the mod folder

**Files:**
- Create: `src/main/live/plugin-cli.ts`, `src/main/live/mod-folder.ts`
- Test: `test/main/live/plugin-cli.test.ts`, `test/main/live/mod-folder.test.ts`

**Interfaces:**
- Consumes: `RunClaude`, `ExecResult` (M1).
- Produces:
  - `plugin-cli.ts`: `PLUGIN_NAME = 'bifrost-live'`, `MARKETPLACE_NAME = 'bifrost-local'`, `PLUGIN_ID = 'bifrost-live@bifrost-local'`, `PLUGIN_TIMEOUT_MS = 30_000`, `interface PluginEntry { enabled: boolean; folder?: string; errors: string[] }`, `interface MarketplaceEntry { source: string; path?: string }`, `checkCliResult(result: ExecResult): void`, `interface PluginCli { plugin(): Promise<PluginEntry | null>; marketplace(): Promise<MarketplaceEntry | null>; addMarketplace(dir: string): Promise<void>; install(): Promise<void>; enable(): Promise<void>; disable(): Promise<void>; uninstall(): Promise<void>; removeMarketplace(): Promise<void> }`, `createPluginCli(run: RunClaude): PluginCli`.
  - `mod-folder.ts`: `MOD_FILES = ['.claude-plugin/plugin.json', '.claude-plugin/marketplace.json', 'hooks/hooks.json', 'hooks/register.ts'] as const`, `modSourceDir(appPath: string): string`, `modFolderCurrent(source: string, dest: string): Promise<boolean>`, `syncModFolder(source: string, dest: string): Promise<void>`, `removeModFolder(dest: string): Promise<void>`.

Rules for `plugin-cli.ts`:
- Each method runs exactly one command of Global Constraints with `{ timeoutMs: PLUGIN_TIMEOUT_MS }`.
- `plugin()` and `marketplace()`: an exit code other than 0, or output with no JSON array (start at the first line that begins with `[`, as `parseAgents` does), rejects with `claude plugin list failed: <stderr, or the exit code>`. `plugin()` gives the entry with `id === PLUGIN_ID` as `{ enabled, folder: readFromFolder, errors: errors ?? [] }`, or null. `marketplace()` gives the entry with `name === MARKETPLACE_NAME` as `{ source, path }`, or null.
- `checkCliResult`: parse the last line of stdout that is not empty. `outcome: 'ok'` passes. `failureCode: 'already_in_goal_state'` passes (enable and disable exit 1 for it). Else throw an Error with the `message` of that line, else the stderr, else `claude exited with code <n>`.
- `addMarketplace(dir)` refuses a path that is not absolute or that holds a line break, before it runs a command.

Rules for `mod-folder.ts`:
- `modSourceDir(appPath)` gives `join(appPath.replace(/app\.asar$/, 'app.asar.unpacked'), 'resources', 'live-mod')`.
- `modFolderCurrent`: true only when each of the four files of `dest` has the same bytes as in `source`.
- `syncModFolder`: nothing when the folder is current. Else read all four source files first (a missing file rejects before any change). Write them to `<dest>.<uuid>.tmp/` (directories 0700, files 0600). Rename `dest` to `<dest>.<uuid>.old` when it exists, rename the temporary folder to `dest`, then remove the old folder. A failure removes the temporary folder and leaves `dest` as it was.
- `removeModFolder`: remove `dest` and its content. A missing folder is not an error.

- [ ] **Step 1: Write the failing tests**

`plugin-cli.test.ts` (a fake `RunClaude` records each argument list and gives a set `ExecResult`):
- `plugin runs plugin list --json and finds the Bifrost plugin`: the output `[{"id":"bifrost-live@bifrost-local","version":"1.0.0","scope":"user","enabled":true,"installPath":"","readFromFolder":"/h/.bifrost/mod"}]` gives `{ enabled: true, folder: '/h/.bifrost/mod', errors: [] }`. The arguments are `['plugin', 'list', '--json']` with `timeoutMs: 30000`.
- `plugin gives null when the list has no Bifrost plugin`, and `plugin rejects for exit 1 or output that is not JSON`
- `marketplace finds bifrost-local with its path`: `[{"name":"bifrost-local","source":"directory","path":"/h/.bifrost/mod"}]`.
- `each command uses the exact arguments`: one `test.each` row for `addMarketplace('/h/.bifrost/mod')`, `install`, `enable`, `disable`, `uninstall` and `removeMarketplace`, with the lists of Global Constraints.
- `enable and disable pass for already_in_goal_state`: exit 1 with the last line `{"command":"enable","outcome":"failed","message":"Plugin \"bifrost-live\" is already enabled","failureCode":"already_in_goal_state","alreadyInGoalState":true}` resolves.
- `a failed result rejects with its message`: `{"command":"install","outcome":"failed","message":"Plugin not found"}` rejects with `Plugin not found`.
- `checkCliResult reads only the last line`: a first line `Run this command now?` and a JSON last line.
- `addMarketplace refuses a relative path and a line break`: `mod` and `/h/a\nb` reject, and the fake records no call.

`mod-folder.test.ts` (temporary directories):
- `syncModFolder copies only the four mod files`: a source with `tests/register.test.ts`, `.claude-plugin/types/x.d.ts` and `tsconfig.json` gives a `dest` with only the four files, files 0600 and directories 0700.
- `modFolderCurrent is true after a sync and false after a change of one file`
- `syncModFolder replaces an old folder and leaves no temporary folder`: an extra old file in `dest` is gone. The parent has no `.tmp` and no `.old` entry.
- `syncModFolder changes nothing when a source file is missing`
- `removeModFolder removes the folder and accepts a missing folder`
- `modSourceDir uses app.asar.unpacked in the packaged app`: `/A/Resources/app.asar` gives `/A/Resources/app.asar.unpacked/resources/live-mod`. `/repo` gives `/repo/resources/live-mod`.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/main/live/plugin-cli.test.ts test/main/live/mod-folder.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `createPluginCli`, `checkCliResult` and the mod folder functions**

- [ ] **Step 4: Run all checks**

Run: `pnpm test && pnpm typecheck && pnpm check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/live/plugin-cli.ts src/main/live/mod-folder.ts test/main/live/plugin-cli.test.ts test/main/live/mod-folder.test.ts
git commit -m "feat(live): run the plugin commands and copy the mod folder" \
  -m "Bifrost runs only the plugin commands of the plan, with fixed arguments. It copies the" \
  -m "four mod files to ~/.bifrost/mod and replaces the old folder in one rename."
```

---

### Task 6: Turn Live details on and off from Bifrost

**Files:**
- Create: `src/main/live/live-control.ts`
- Modify: `src/shared/types.ts`, `src/shared/api.ts`, `src/preload/index.ts`, `src/main/ipc.ts`, `src/main/claude/version.ts`, `src/main/integration/integration.ts`, `src/renderer/src/panels/IntegrationPanel.tsx`
- Test: `test/main/live/live-control.test.ts`, `test/main/claude/version.test.ts`, `test/main/integration/integration.test.ts`

**Interfaces:**
- Consumes: `createLiveServer`, `LiveServer` (Task 3); `RegistryService.pushLive`, `liveCount` (Task 4); `createPluginCli`, `PluginCli`, `modSourceDir`, `modFolderCurrent`, `syncModFolder`, `removeModFolder` (Task 5); `uninstall`, `checkInstall`, `HOOK_ROWS`, `defaultPaths`, `createSerialRunner`, `fromPage`, `checkClaudeVersion` (M1).
- Produces:
  - `src/shared/types.ts`: `type LivePluginState = 'not-installed' | 'disabled' | 'enabled' | 'unknown'` and `interface LiveStatus { plugin: LivePluginState; modCurrent: boolean; oldInstall: boolean; listening: boolean; liveSessions: number; claudeVersion: string | null; versionOk: boolean; error?: string }`.
  - `version.ts`: `checkClaudeVersion(run: RunClaude, minimum = MIN_CLAUDE_VERSION): Promise<ClaudeVersion>`.
  - `integration.ts`: `oldInstallStatus(paths: IntegrationPaths): Promise<{ found: boolean; error?: string }>`. `found` is true when the settings have at least one Bifrost hook row or the Bifrost wrapper.
  - `live-control.ts`: `LIVE_MIN_CLAUDE_VERSION = '2.1.290'`, `RELOAD_NOTE = 'Sessions that run now get the change after /reload-plugins or a restart.'`, `interface LiveControlDeps { cli(): Promise<PluginCli | null>; version(): Promise<ClaudeVersion>; server: LiveServer; modSource: string; modDir: string; oldInstall(): Promise<{ found: boolean; error?: string }>; removeOldInstall(): Promise<void>; liveSessions(): number; forceListen: boolean }`, `interface LiveControl { start(): Promise<void>; status(): Promise<LiveStatus>; install(): Promise<LiveStatus>; enable(): Promise<LiveStatus>; disable(): Promise<LiveStatus>; uninstall(): Promise<LiveStatus>; stop(): void }`, `createLiveControl(deps: LiveControlDeps): LiveControl`.
  - `src/shared/api.ts` and preload: `live: { status(): Promise<LiveStatus>; install(): Promise<LiveStatus>; enable(): Promise<LiveStatus>; disable(): Promise<LiveStatus>; uninstall(): Promise<LiveStatus> }` on the IPC channels `live:status`, `live:install`, `live:enable`, `live:disable`, `live:uninstall`. Each action rejects with the message of its failure.

Rules for `live-control.ts`:
- `status()`: `plugin` is `not-installed` for a null entry, `enabled` or `disabled` from the entry, and `unknown` when `cli()` gives null or `plugin()` rejects (the message goes to `error`). `modCurrent` is `modFolderCurrent(modSource, modDir)` and, when the entry has a `folder`, `resolve(folder) === resolve(modDir)`. `oldInstall` and its error come from `deps.oldInstall()`. `listening` and the server error come from `server.state()`. `claudeVersion` and `versionOk` come from `deps.version()`. Join several errors with a space.
- The version check of `install` and `enable`: `versionOk` false rejects with `Live details needs Claude Code 2.1.290 or later. This Mac has <version>.` (`claude was not found` in place of the version when it is null).
- `install()`, in this order: version check; when `oldInstall().found`, `removeOldInstall()` (a rejection stops the action here); `syncModFolder`; `marketplace()`: null gives `addMarketplace(modDir)`, a `path` equal to `modDir` gives nothing, any other entry rejects with `A marketplace with the name bifrost-local already exists at <path or source>. Bifrost did not change it.`; `plugin()` null gives `install()`; an entry that is not enabled gives `enable()`; `server.start()`; return `status()`.
- `enable()`: version check; `plugin()` null rejects with `Live details is not installed.`; old install removal as in `install`; `syncModFolder`; `cli.enable()`; `server.start()`; `status()`.
- `disable()`: when `plugin()` is not null, `cli.disable()`. Then `server.stop()` and `status()`.
- `uninstall()`: `server.stop()`; when `plugin()` is not null, `cli.uninstall()`; when `marketplace()` has the path `modDir`, `removeMarketplace()` (never for another path); `removeModFolder(modDir)`; when `oldInstall().found`, `removeOldInstall()`; `status()`.
- `start()` (D9) never rejects and logs a failure with `console.warn`. `forceListen`: `server.start()`. An enabled plugin: `syncModFolder` when the folder is not current, then `server.start()`. `cli()` null or `plugin()` rejects: `server.start()` only when `<modDir>/.claude-plugin/plugin.json` exists. Else no server.
- `stop()`: `server.stop()`.

Rules for `ipc.ts`:
- Make one server: `createLiveServer({ socketPath: join(paths.bifrostHome, 'live.sock'), onEvent: ev => liveService?.pushLive(ev), now })`.
- Make the control with `cli` from the resolved `run` (`createPluginCli`), `version` from `checkClaudeVersion(run, LIVE_MIN_CLAUDE_VERSION)` (no `claude` gives `{ version: null, ok: false, minimum }`), `modSource: modSourceDir(app.getAppPath())`, `modDir: join(paths.bifrostHome, 'mod')`, `oldInstall: () => oldInstallStatus(paths)`, `removeOldInstall: () => uninstall(paths, new Date()).then(() => {})`, `liveSessions: () => liveService?.liveCount() ?? 0`, `forceListen: process.env.BIFROST_LIVE_LISTEN === '1'`.
- Call `control.start()` after `startService` resolves, so an event finds the service.
- `live:status` uses `fromPage`. The four actions use `fromPage` and the same serial runner as the M1 integration handlers, so an old-install removal and a plugin command never run at the same time.
- `stopRegistry()` also calls `control.stop()`.

Debug panel (`IntegrationPanel.tsx`; M5a replaces it): a "Live details" block above the M1 block. One line for each `LiveStatus` field, the error line, and the buttons Install, Turn on, Turn off and Remove (one action at a time, with the existing `run` helper). After Install and Turn on, show `RELOAD_NOTE` (copy the text into the renderer; the renderer does not import main code).

- [ ] **Step 1: Write the failing tests**

`live-control.test.ts` (a fake CLI and a fake server record each call in one `calls` list; the mod folders are temporary directories with the four files):
- `install removes an old hook install, copies the mod, adds the marketplace, installs and listens`: `oldInstall` found, no marketplace, and no plugin (the fake gives an enabled entry after `install`). The write calls in `calls` are, in this order, `['removeOldInstall', 'addMarketplace /m', 'install', 'server.start']`, with no `enable`. The mod folder is current before `addMarketplace`.
- `install stops when the old hook removal fails`: the removal rejects with `X`. `install` rejects with `X`. The fake CLI records no write command and the server does not start.
- `install refuses a bifrost-local marketplace with another path`: path `/other` rejects with `A marketplace with the name bifrost-local already exists at /other. Bifrost did not change it.` No `install` call.
- `install skips addMarketplace when bifrost-local has the mod path`
- `install refuses Claude Code below 2.1.290`: version `2.1.289` gives `Live details needs Claude Code 2.1.290 or later. This Mac has 2.1.289.` and no other call.
- `enable rejects when the plugin is not installed`: `Live details is not installed.`
- `disable runs plugin disable and stops the server`
- `uninstall stops the server, removes the plugin, the marketplace, the mod folder and the old install`
- `uninstall leaves a bifrost-local marketplace with another path`
- `start listens for an enabled plugin and copies an old mod folder again`
- `start listens when the CLI fails and the mod folder exists`, and `start does not listen for a disabled plugin`
- `start listens with forceListen whatever the plugin state`
- `status gives each field`: an enabled entry with `folder` equal to `modDir`, a current folder, no old install, a listening server, `liveSessions` 2 and version `2.1.318` give `{ plugin: 'enabled', modCurrent: true, oldInstall: false, listening: true, liveSessions: 2, claudeVersion: '2.1.318', versionOk: true }`.
- `status gives unknown and the message when plugin list fails`

`version.test.ts` (add): `checkClaudeVersion uses the given minimum`: `2.1.289` with the minimum `2.1.290` gives `ok: false` and `minimum: '2.1.290'`.

`integration.test.ts` (add): `oldInstallStatus finds a Bifrost hook or the wrapper` (one `Stop` row only; the wrapper only), `oldInstallStatus gives found false with no Bifrost entry`, `oldInstallStatus gives the error for a settings file that is not valid JSON`.

- [ ] **Step 2: Run the tests and see them fail**

Run: `pnpm vitest run test/main/live/live-control.test.ts test/main/claude/version.test.ts test/main/integration/integration.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement the control, the IPC handlers, the API, the preload and the panel block**

- [ ] **Step 4: Run all checks and the build**

Run: `pnpm test && pnpm typecheck && pnpm check && pnpm exec electron-vite build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/main/live/live-control.ts src/shared src/preload/index.ts src/main/ipc.ts src/main/claude/version.ts src/main/integration/integration.ts src/renderer/src/panels/IntegrationPanel.tsx test/main
git commit -m "feat(live): turn Live details on and off from Bifrost" \
  -m "Install, Turn on, Turn off and Remove run the plugin commands. They first remove an old" \
  -m "hook install. Bifrost listens on the socket only while the mod is on."
```

---

### Task 7: Remove the hook install and keep its removal

**Files:**
- Delete: `src/main/integration/scripts.ts`, `src/main/integration/quiet-marker.ts`, `test/main/integration/scripts.test.ts`, `test/main/integration/quiet-marker.test.ts`
- Modify: `src/main/integration/settings-plan.ts` (delete `planInstall`), `src/main/integration/integration.ts` (delete `previewInstall`, `install`, `integrationStatus` and the script helpers; keep `uninstall`, `oldInstallStatus`, `defaultPaths`, `IntegrationPaths`, `InstallHooks` and the file helpers that `uninstall` uses), `src/shared/types.ts` (delete `IntegrationStatus` and `InstallPreview`), `src/shared/api.ts` and `src/preload/index.ts` (delete `integration`), `src/main/ipc.ts` (delete the `integration:*` handlers, the quiet marker and the `integrationStatus` dep of the session actions), `src/main/actions/session-actions.ts` (D13), `src/renderer/src/panels/IntegrationPanel.tsx` (delete the M1 block), each file that imports `UUID_PATTERN` from `integration/scripts` (import it from `src/shared/uuid`), `test/main/integration/integration.test.ts`, `test/main/integration/settings-plan.test.ts`, the session-actions tests

**Interfaces:**
- Consumes: `oldInstallStatus` (Task 6).
- Produces: `newSessionArgs(spec: NewSessionSpec): string[]` (the `wrapper` parameter goes away). `SessionActionsDeps` loses `integrationStatus`. After this task, the only way to change `~/.claude/settings.json` from Bifrost is `uninstall` (through Install, Turn on and Remove of Live details) and the `claude plugin` commands.

Rules:
- `uninstall` keeps its M1 behaviour and its tests: one backup before the change, the byte check before the rename, a refusal when the wrapper is set and `statusline-original.json` is missing or not valid.
- `checkInstall`, `planUninstall`, `HOOK_COMMAND`, `STATUSLINE_COMMAND` and `HOOK_ROWS` stay. They find and remove an old install.
- D13: `newSessionArgs` always starts with `['--bg', '--settings', NO_STATUSLINE_SETTINGS]`. Delete `wrapperInstalled` and its comment. Resume and Take control still pass no `--settings`.

- [ ] **Step 1: Delete the files and the code, and change the tests**

Delete the tests of `install`, `previewInstall`, `integrationStatus`, `planInstall`, the scripts and the quiet marker. Keep each test of `uninstall`, `planUninstall`, `checkInstall` and `oldInstallStatus`. Replace the M4 tests of the wrapper rule with one test: `newSessionArgs always turns the statusline off for a new session` (the arguments start with `--bg`, `--settings`, `NO_STATUSLINE_SETTINGS`). Keep the tests that resume and Take control pass no `--settings`.

- [ ] **Step 2: Run all checks and the build**

Run: `pnpm test && pnpm typecheck && pnpm check && pnpm exec electron-vite build`
Expected: PASS.

Run: `rg -n "planInstall|previewInstall|integrationStatus|HOOK_SCRIPT|statuslineScript|QUIET_FILE|ACTIVE_FILE|IntegrationStatus|InstallPreview|integration:|integration/scripts|wrapperInstalled" src test`
Expected: no match.

- [ ] **Step 3: Commit**

```bash
git add -A src test
git commit -m "refactor(integration): remove the hook install and keep its removal" \
  -m "Bifrost no longer writes hooks, the statusLine wrapper or quiet files. The M1 uninstall" \
  -m "stays, so Live details can remove an old hook install cleanly."
```

---

### Task 8: Spec text for Live details

**Files:**
- Modify: `docs/specs/2026-11-04-bifrost-design.md`

**Interfaces:**
- Consumes: the decisions D1 to D12 and the answers to O1 to O4 that the user gave before this task. For an open point with no answer, write the recommendation and add `(waits for the user)` at the end of the line.

Write each change in ASD-STE100. Change only these sections:
- 3 (Data row): `claude agents --json` is the base. The optional Live details mod adds events and usage data.
- 4 (facts): the mod facts of the spike. A mod loads at the session start or at `/reload-plugins`. `session.start` cannot tell a background session from an interactive one. `$.session.model()` gives an ID. The cost can change about 2 s after a turn. `classic.*` hooks do not run where `cc-plugin-sec-default` loads. A missing socket makes a send fail in about 1 ms with no message.
- 5 (diagram and 5.1): the registry listens on `~/.bifrost/live.sock`. The Integration part installs, turns on, turns off and removes the mod, and removes an old hook install.
- 5.3 (files): remove `bin/bifrost-hook`, `bin/bifrost-statusline`, `events/`, `sessions/<id>/status.json`, `active` and `quiet`. Add `~/.bifrost/mod/` and `~/.bifrost/live.sock`. Keep `statusline-original.json` and `backups/` for the removal of an old hook install.
- 6.2 becomes "Live events": the wire table of Task 1 (kind to result), the rules (one line for each event, no wait for a send, `v: 1`, the limits, the order rule D4, the classic fallback D5).
- 6.3 becomes "Usage data": the sources and times of D8, the model name map, and the O4 result (spec 20 item 1).
- 7: the causes in the state table name the live events. Rule 7: external sessions get boxes from the mod, because it is installed at user scope. Add the stopped-turn rule (D6), the reload rule (D7), and rule 11, the poll-only yellow box (O3).
- 8.7 and 8.8: the Event log shows the live state events. The Usage HUD uses the newest live usage line.
- 11: the setup dialog offers Live details or Skip (M5a builds it). Install, Turn on, Turn off, Remove and the old install removal (D9, D10, D11), the reload note, and the start check (D9, version 2.1.290 for Live details).
- 12: the Integration row becomes `Live details: Install, Turn on, Turn off, Remove`.
- 13: add `The mod starts no process. A hook spends less than 1 ms before next.`
- 15: the Script row becomes `Mod | claude plugin test | the hooks module, with a fake http.fetch`.
- 16: add the row "Live - Live details" between M4 and M5, with the exit criteria of Task 9.
- 20 item 1: add a note that section 23 changes it.
- 22: add a note to its statusline line that section 23 changes it (D13).
- Add section 23 "Decisions on 2026-11-05 (Live details)": one line for each decision D1 to D14 and each answer to O1 to O4.

- [ ] **Step 1: Write the changes**
- [ ] **Step 2: Check the text**

Run: `rg -n "bifrost-hook|bifrost-statusline|status file|event directory|quiet" docs/specs/2026-11-04-bifrost-design.md`
Expected: matches only in sections 18 to 23 (the history) and in the old-install text of section 11.

Run: `rg -n "\x{2014}" docs/specs/2026-11-04-bifrost-design.md` (the em dash)
Expected: no match.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/2026-11-04-bifrost-design.md
git commit -m "docs(spec): describe Live details" \
  -m "The mod replaces the global hooks and the statusLine wrapper. The poll of claude agents" \
  -m "stays the base. Section 22 records the decisions."
```

---

### Task 9: Check Live details with real test sessions (controller)

**Files:**
- Create: `docs/live-findings.md`, `docs/live-findings/` (screenshots)

The controller runs this task (or one check agent that the controller briefs). It starts `pnpm exec electron-vite dev -- --user-data-dir=<scratchpad>/live-check-ud --remote-debugging-port=9333` in the worktree and reads the rows with `agent-browser eval "window.bifrost.registry.rows()"` (the M1 method). It quits Bifrost with SIGTERM to its own Electron main PID only. It never uses `osascript`: the user's own Bifrost has the same bundle ID. Interactive sessions use `TestPty` of `scripts/m0/lib.ts` with `M0_CLAUDE=~/Developer/bifrost/.m0-sandbox/cl.sh`. The user's own Bifrost (main at 4c5a1fd or later, without this plan) has no live server, so the check app is the only listener on `~/.bifrost/live.sock`. If the check app gives `listening: false` with "Another program", stop the check and record it.

Safety:
- Part A installs nothing. Before and after Part A, record the SHA-256 of `~/.claude/settings.json` and `~/.claude/plugins/installed_plugins.json`. They must not change.
- Copy the four `MOD_FILES` to `~/Developer/bifrost/.m0-sandbox/live-check/bifrost-live/`. Load the mod only with `--plugin-dir` on that copy. Then the engine writes its types into the sandbox, not into the repository.
- Never run `/reload-plugins` or any input in a session of the user.
- Part B runs only after the user says yes to O1.

Part A, with `BIFROST_LIVE_LISTEN=1` (no install):
- [ ] **Step 1: Socket.** Start Bifrost. Expected: `~/.bifrost/live.sock` exists, mode 0600. `window.bifrost.live.status()` gives `listening: true`, `plugin: 'not-installed'`.
- [ ] **Step 2: Yellow box.** `cl.sh --bg --plugin-dir <copy> --model haiku --name bifrost-test-la "Reply with exactly the word ALPHA."` Expected: a yellow box, Last message `ALPHA`, `live: true`, model `Haiku 5.5`, a context % and a cost. `boxSince` is earlier than the first row update with `status: 'idle'`.
- [ ] **Step 3: Red box.** `bifrost-test-lp` with `--permission-mode manual` and the prompt `Run the shell command: touch perm-check-lp.txt`. Expected: a red box. `boxSince` is earlier than the first row update with `status: 'waiting'`. Do not answer.
- [ ] **Step 4: Interactive.** `TestPty` session `bifrost-test-li` with `--plugin-dir <copy>`. (a) `Count from 1 to 300, one number on each line.`, then Esc after the numbers show. Expected: `idle`, no box, Last message with the first numbers. (b) `Use the AskUserQuestion tool to ask me to pick red or blue. Do nothing else.` Expected: a red box. Press Enter. Expected: then a yellow box. (c) `/reload-plugins` while the yellow box shows. Expected: the box stays. (d) `/clear`, then `Reply with BRAVO.` Expected: the row of the new session ID gets a yellow box.
- [ ] **Step 5: Heartbeat.** Quit and start Bifrost. Expected: within 35 s the idle row of `bifrost-test-la` shows the model and the cost again, with `live: true`.
- [ ] **Step 6: Bifrost closed.** Quit Bifrost. In `bifrost-test-li` send `Reply with CHARLIE.` Expected: the screen shows no error line. `rg -n "bifrost-live|ENOENT|ECONNREFUSED|hook error"` on its transcript gives no match.
- [ ] **Step 7: Poll-only yellow (only when O3 is yes).** Start Bifrost. `bifrost-test-lq` with no `--plugin-dir`: `Reply with DELTA.` Expected: a yellow box after the poll shows `idle`, and no `live`.
- [ ] **Step 8: Hashes.** The two SHA-256 values are the same as before.

Part B, user-scope install (only after the user says yes to O1; Bifrost without `BIFROST_LIVE_LISTEN`):
- [ ] **Step 9: Before.** `live.status()` gives `oldInstall: false` (if true, skip Part B and record it for the user). Copy `~/.claude/settings.json`, `~/.claude/plugins/installed_plugins.json` and `~/.claude/plugins/known_marketplaces.json` to `.m0-sandbox/live-real-backup/` and record their SHA-256. Start `bifrost-test-lo` (background, no `--plugin-dir`). Record `ps -axo pid,lstart,command | rg "claude bg-spare"`.
- [ ] **Step 10: Install.** Click Install in the debug panel. Expected: `~/.bifrost/mod` has the four files. `cl.sh plugin list --json` shows `bifrost-live@bifrost-local`, `enabled: true`, `readFromFolder` `~/.bifrost/mod`. `cl.sh plugin marketplace list --json` shows `bifrost-local` with that path. `live.status()` gives `listening: true`.
- [ ] **Step 11: Spike step 3.** Record if `bifrost-test-lo` sends lines (it must not before a reload). Run `cl.sh respawn <id of lo>` and record if it sends after that. Start `bifrost-test-lc` (background, no `--plugin-dir`, `Reply with ECHO.`). Expected: its row is live. If it is not live, record the `bg-spare` processes again.
- [ ] **Step 12: Turn off and Turn on.** Turn off: the socket is gone, `plugin list` shows `enabled: false`, and a new background session does not send. Turn on: the socket is back, and a new background session sends.
- [ ] **Step 13: Remove.** Click Remove. Expected: no `bifrost-live` in `plugin list`, no `bifrost-local` in `marketplace list`, no `~/.bifrost/mod`, no socket. Compare `jq -S . ~/.claude/settings.json` with the backup and record each difference.

Part C:
- [ ] **Step 14: Clean up.** For each `bifrost-test-` entry of `cl.sh agents --json --all`, read the list again, check the name, then run `cl.sh stop` (only with a `pid`) and `cl.sh rm`. Remove `.m0-sandbox/perm-check-lp.txt` and `.m0-sandbox/live-check/`. Check `git worktree list`.
- [ ] **Step 15: Write the results.** `docs/live-findings.md`: one row for each step with the method, the result and the time values. Add the answers of O1 to O4 and each item for the user.
- [ ] **Step 16: Commit**

```bash
git add docs/live-findings.md docs/live-findings
git commit -m "docs(live): record the Live details checks"
```

---

## Self-review notes

- Spec coverage: section 4 facts (Task 8), 5 (Tasks 3, 6, 8), 6.1 stays, 6.2 and 6.3 (Tasks 1, 2, 4, 8), 7 (Task 4), 11 (Tasks 6, 7, 8), 12 (Task 8; the UI is M5a), 13 (Tasks 2, 9), 15 (Tasks 2, 8), 16 (Task 8), 20 item 1 (O4, Tasks 7, 8), 21 item 6 (all).
- The names cross the tasks as the Interfaces blocks give them: `parseLiveLine`, `LiveEvent`, `LiveUsage`, `modelName`, `createLiveServer`, `pushLive`, `liveCount`, `applyUsage`, `createPluginCli`, `syncModFolder`, `modFolderCurrent`, `createLiveControl`, `LiveStatus`, `oldInstallStatus`.
- Each Review Focus line has its test in Tasks 1 to 4.


---

## The user's answers (2026-11-05)

These replace the "waits for the user" marks above.

- **O1 (user-scope install test): yes.** Task 9 Part B runs, with backups, SHA-256 values and no `/reload-plugins` in the user's sessions.
- **O2 (`/plugin` check): `cc-plugin-sec-default` is not listed.** The guard does not apply. `classic.*` events are usable.
- **O3 (poll-only yellow box): yes.** When no mod runs, a change from `busy` to `idle` seen by the poll sets a yellow box. A session that is idle at the first poll gets no box. A later `busy` sample clears it (spec 7 rule 10 confirmation rules stay). With the mod on, `turn.complete` sets the box, and the poll rule adds nothing.
- **O4 (statusline in chat windows): option a.** Bifrost starts its own new sessions with `--settings '{"statusLine":{"type":"command","command":"true"}}'` (test: works; the user's statusline does not run for that session). Do NOT pass the flag on `--resume`: a resume with the flag starts a copy with a new session ID. A follow-up test checks that a session started with the flag keeps the hidden statusline when it resumes without the flag (results in `.superpowers/statusline-override-test.md`).
- **O4 follow-up test (done):** a session started with the flag and resumed WITHOUT flags keeps its ID and the hidden statusline (Claude Code saves the start options). A plain session (a Warp session after Take control) resumed without flags keeps its ID and shows the user's statusline. Rule: add the flag only on a new start; resume and Take control use no extra flags. A taken-over session keeps the statusline in its chat window (accepted).
