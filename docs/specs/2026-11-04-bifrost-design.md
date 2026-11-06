# Bifrost - design

"Bifrost for Claude Code". Design document.

| Item | Value |
|---|---|
| Status | Approved on 2026-11-04 |
| Date | 2026-11-04 |
| Owner | Bifrost |
| Repository | `~/Developer/bifrost` (local only) |

## 1. Purpose

Bifrost is a macOS desktop app. It shows all local Claude Code sessions in one window, and it lets you control them.

The user interface uses ideas from the EVE Online client:

- An Overview list of sessions.
- A Selected Item panel with action buttons.
- A right-click menu with submenus.
- Panels that you can move, resize, snap and stack.

Each chat window shows the real Claude Code terminal UI. You move and resize the chat windows to show your priorities.

Bifrost uses the mechanics of the EVE interface. It does not copy EVE art, icons, sounds or logos.

### 1.1 Not in v1

- Windows and Linux.
- Shell commands from Bifrost. Use the `!` prefix in a chat window.
- The Mac App Store and TestFlight.
- Cloud sessions and Remote Control sessions.
- Automatic updates. These come with the S3 update feed.
- A public release.
- Signing, notarization and distribution to colleagues. These come later.

## 2. Terms

| Term | Meaning |
|---|---|
| Session | One Claude Code conversation. |
| Owned session | A session that the Claude Code supervisor runs in the background. Bifrost can attach to it and type into it. |
| External session | An interactive session that a terminal app owns, for example Warp. Bifrost shows its status only. |
| Parked session | A session that has a saved conversation but no process. A parked session comes from `claude stop`, a restart of the computer, or a process that ends. |
| Supervisor | The Claude Code background service that runs owned sessions. |
| Panel | An internal window inside the Bifrost window. |
| Box | An attention mark on an Overview row. A box is yellow or red. |
| Live details | The optional Claude Code mod `bifrost-live`. It sends live lines to Bifrost over a socket. |
| Live line | One JSON object that the mod sends for one event or one usage reading (section 6.2). |

## 3. Summary of decisions

| Topic | Decision |
|---|---|
| Platform | Electron, React, TypeScript, xterm.js and node-pty. |
| Operating system | macOS only in v1. A "Mod" key layer keeps a Windows port possible. |
| Window model | One app window. Internal panels float inside it. |
| Session hosting | Bifrost starts sessions with `claude --bg`. Each chat window runs `claude attach <id>`. |
| External sessions | Status only. The "Take control" action moves them to the supervisor. |
| Data | `claude agents --json` is the base. The optional Live details mod adds events and usage data. |
| Labels | Plain labels and space labels. A setting selects the set. |
| Alerts | Yellow and red boxes flash. A macOS notification and a sound are optional. |
| Scale | 20 sessions and 8 visible chat windows. |
| Name | Bifrost. Subtitle: "for Claude Code". |
| Release | Local builds on your Mac for now. Signing, notarization and distribution come later (section 14.2). |
| Repository | Local and private. `"license": "UNLICENSED"`. |

## 4. Facts about Claude Code

These facts come from Claude Code 2.1.318 and its docs, on 2026-11-04.

- `claude agents --json` prints all active sessions, interactive and background.
- Each entry has `pid`, `cwd`, `kind`, `startedAt`, `sessionId`, `name` and `status`.
- The `status` value is `busy`, `idle` or `waiting`.
- Entries of background sessions also have `state`. Do not use `state`, because it is not reliable.
- An entry can have `waitingFor`. It comes with the `waiting` status. Seen values: `permission prompt`, and `input needed` for an `AskUserQuestion` call. Interactive sessions also report `waiting` at a prompt (M1).
- A new background entry has no `pid` and no `status` for about 2.5 seconds.
- After `claude stop` or a service stop, the `--all` entry has no `pid` and no `status`. It can lose its name.
- `claude --bg` refuses a directory that you did not trust. Claude Code keeps trust for each git root.
- The first `claude --bg` or `claude agents` starts the shared background service.
- All later background sessions get the environment of that first caller.
- `claude --bg` starts a background session and prints its short ID.
- `claude attach <id|name>` opens a background session in a terminal. The session continues after you detach.
- `claude stop`, `claude rm`, `claude logs` and `claude respawn` control background sessions.
- `claude --bg --resume <session-id>` continues a session in the background with the same ID and the same conversation.
- If that session still runs, `claude --bg --resume` starts a copy.
- `/bg`, or ← on an empty prompt, moves an interactive session to the supervisor.
- The supervisor did not stop an idle, unattached session in 75 minutes (M0). In M1, it parked an idle session about 60 minutes after its last turn, with no `SessionEnd` event.
- A background session in a git repository enters a git worktree (`.claude/worktrees/<name>`, branch `worktree-<name>`) before it edits a file. `claude rm` deletes the worktree and the branch (M1).
- Running sessions use a change of the hooks and the statusLine in `settings.json` at once. No restart is necessary (M1).
- A restart of the computer stops all background sessions.
- Hooks in `~/.claude/settings.json` apply to all local sessions.
- The statusLine command gets the session JSON on stdin. The JSON includes the model, the cost, the context window and the rate limits.
- A mod loads at the session start or at `/reload-plugins`. A running session does not load a new mod before one of these.
- `session.start` cannot tell a background session from an interactive one. Both give `isInteractive` `true`.
- `$.session.model()` gives a model ID, not a display name.
- The cost can change about 2 s after a turn ends. A side request of Claude Code makes this cost.
- `classic.*` hooks do not run where the guard `cc-plugin-sec-default` loads. The user checked on 2026-11-05 that this guard is not in his list.
- A send to a missing socket fails in about 1 ms with no message on the screen.
- No documented API lets a program type into an interactive session that a terminal owns.
- The transcript JSONL format is internal. Bifrost does not read transcripts.

## 5. Architecture

```text
+------------------------- Bifrost (Electron) --------------------------+
| Renderer (React)                                                       |
|   Window manager, Overview, Selected Item, Chat windows (xterm.js),    |
|   Show Info, Event log, Usage HUD, dialogs                             |
|                          ^ typed IPC (preload)                         |
| Main process (Node)                                                    |
|   Session registry <-- poll:  claude agents --json                     |
|                    <-- listen: ~/.bifrost/live.sock                    |
|   PTY manager      --> node-pty: claude attach <id>                    |
|   Action runner    --> claude --bg / stop / rm, signals, open -a       |
|   Integration      --> claude plugin ... (install, turn on/off, remove)|
+------------------------------------------------------------------------+
                  ^ live lines (HTTP over the socket)
          Live details mod (~/.bifrost/mod, plugin bifrost-live)
                  ^
                  +--------- Claude Code sessions
```

### 5.1 Main process

| Part | Function |
|---|---|
| Session registry | Merges all data sources into one list of sessions. Runs the state machine. Listens on `~/.bifrost/live.sock`. |
| PTY manager | Starts one `claude attach <id>` process for each open chat window. Also starts the hidden attach for the send box. |
| Action runner | Runs Claude Code commands, sends signals and opens other apps. |
| Integration | Installs, turns on, turns off and removes the Live details mod. Removes an old hook install. |
| Store | Keeps the settings, layouts, priorities and panel positions on disk. |

### 5.2 Renderer

The renderer is one React app. React keeps the state. M2 decided that React state is enough. A reducer keeps the window manager state. Zustand is not used. The main process sends updates of the registry to the renderer. It sends a maximum of 4 updates each second.

Context isolation is on. The preload script supplies a typed API. The renderer has no direct access to Node.

### 5.3 Files and directories

| Path | Content |
|---|---|
| `~/.bifrost/mod/` | The four files of the Live details mod. Folders have mode 0700 and files have mode 0600. |
| `~/.bifrost/live.sock` | The socket where Bifrost listens for live lines. Mode 0600, in a folder with mode 0700. |
| `~/.bifrost/statusline-original.json` | Your statusLine setting from before an old hook install. Bifrost needs it to remove that install. |
| `~/.bifrost/backups/` | Copies of `settings.json` from before each change. Bifrost needs them to remove an old hook install. |
| `~/Library/Application Support/Bifrost/` | Settings, layouts, priorities and panel positions. |

Bifrost uses `~/.bifrost/` because that path has no spaces. The mod folder is also the marketplace folder.

## 6. Data sources

### 6.1 Session list

Bifrost runs `claude agents --json` every 2 seconds. This gives the active sessions and their `status`: `busy`, `idle` or `waiting`.

Bifrost keeps an entry that has no `pid`. Bifrost keys all entries by `sessionId`.

Bifrost uses `status` for the state machine. It does not use `state`.

Bifrost runs `claude agents --json --all` every 30 seconds. This gives the parked sessions. Bifrost keeps the name of each session in its own registry, because `--all` can lose the name.

The `kind` field shows the type of the session: owned or external. Bifrost also keeps a list of the sessions that it started. If one of these sessions is not active, Bifrost shows it as parked.

### 6.2 Live events

The Live details mod sends one live line for each event. The mod sends facts. Bifrost maps each fact to an event. The table gives the result of each kind. The same table is in `src/main/live/live-event.ts`.

| Kind | Fields | Result |
|---|---|---|
| `session.start` | None | Adds the session. Ends the parked state. |
| `session.end` | `reason` | Marks the end of the session. |
| `turn.start` | None | Sets the state to Working. Clears the box. |
| `ask` | None | Sets a red box. Claude asks you a question (`AskUserQuestion`). |
| `tool.done` | `tool` | Sets the state to Working. Clears a red box after you answer a prompt. |
| `permission` | `tool` | Sets a red box. |
| `turn.complete` | `reason` `answer` or `refusal`, `answer` | Sets a yellow box. Keeps `answer` as the last message for the preview. |
| `turn.complete` | `reason` `aborted`, `answer` | Sets the state to Idle with no box. Keeps the partial answer as the last message. |
| `turn.complete` | `reason` `error` | Sets a red box and the state Error. |
| `stop.failure` | `error` | Sets a red box and the state Error. |
| `usage` | `model`, `context`, `costUsd`, `rateLimits`, and the optional `version`, `effort`, `permissionMode`, `transcriptPath` | Updates the usage data (section 6.3). It is not an event. |

Each line also has `v`, `kind`, `sid`, `at` and `seq`. The field `seq` is the order number of the session.

Rules for the live lines:

- The mod sends one line for each event. It sends the line with `POST http://bifrost/v1/event` over the socket.
- A hook does not wait for a send, because a send can fail or take long. The one exception is `session.end`, which waits at most 200 ms.
- Each line has `v: 1`. Bifrost ignores a line with another version, and a line that is not valid.
- The server accepts a body of at most 65,536 bytes. The mod cuts `answer` to 4,000 characters and each other text to 200 characters. It does not cut `transcriptPath`, because a cut path names another file. It leaves out a path of more than 1,024 characters.
- The server closes a request that has no end after 5,000 ms.
- The mod counts the sends that have not settled. At 32 or more, a new send or usage read sends nothing and returns at once. The line is lost. Bifrost gets the state again at the next line or the next heartbeat. The reason: a Bifrost that hangs never answers a send, and its request timeout then does not run.
- Order rule (D4): Bifrost drops a state event that is older than the newest applied event of the session. It compares `at`, then `seq` when both events have one.
- A turn end of a subagent (`agentId`) changes nothing. A `tool.done` event of any loop sets the state to Working.
- No `classic.*` kind goes on the wire. The mod hooks `classic.PermissionRequest` and `classic.StopFailure` as a fallback (D5). It also hooks `classic.Stop` for the usage data (M5b D28).
- `classic.PermissionRequest` sends the kind `permission`. It only makes the red box for a permission prompt earlier.
- `classic.StopFailure` sends the kind `stop.failure`. It only repeats the error of `turn.complete`.
- `classic.Stop` sends nothing and waits for nothing. It keeps `effort.level`, `permission_mode` and `transcript_path` of its input for the next `usage` line of the same session (section 6.3).
- The mod does not use `tool.check`. In auto mode, an `ask` goes to the classifier, so it is not a prompt.
- Where `classic.*` hooks do not run, the poll gives the red box for a permission prompt within 2 s. Nothing else changes.
- Ask order: the mod queues the `ask` line before the tool runs. The line has a lower `seq` than `tool.done`. The mod does not wait for the send.
- The kinds `tool.done` and `permission` need the field `tool`. The kind `session.end` needs the field `reason`.
- Bifrost drops a `turn.complete` line with another `reason`.
- If `at` differs from the receive time by more than 10 s, Bifrost replaces `at` with the receive time.
- The mod starts no process and reads no transcript.

### 6.3 Usage data

The mod sends the usage data of each session. This data is the model, the context, the cost and the rate limits. A `usage` line holds them.

A `usage` line also has four optional fields (M5b D28). Show Info shows them (section 8.6). `v` stays 1, because each new field is optional.

| Field | Source |
|---|---|
| `version` | The `version` of `$.session.version()`. The mod keeps it after the first answer. A usage line waits at most 500 ms for a read. A read that does not settle in that time stays open, and the line goes out without `version`. The next line waits for the same read again. A rejection gives no version, and the next line reads again. An older engine build can lack `$.session.version`. Then the call throws at once. The mod starts the read in a promise step, so that throw is a rejection too, and the line goes out without `version`. |
| `effort` | `effort.level` of the newest `classic.Stop` input of the session of the line. |
| `permissionMode` | `permission_mode` of the newest `classic.Stop` input of the session of the line. |
| `transcriptPath` | `transcript_path` of the newest `classic.Stop` input of the session of the line. |

The mod sends a `usage` line at these times:

- At `session.start` and at `session.measure`.
- 2,500 ms after each `turn.complete` of the main loop. The cost can change about 2 s after a turn.
- 1,000 ms after `session.end` with the reason `clear`. The line has the new session ID. After `/clear`, no `session.start` comes for the new ID. Without this line, the row of the new ID has no live flag, model or cost until the next prompt.
- Each 30,000 ms (the heartbeat). Without it, an idle row has no data after a start of Bifrost.

Rules for the usage data:

- The registry keeps the last `usage` line of each session.
- A `usage` line is not activity. The column "Activity" ignores it.
- A row is live for 90,000 ms after its last live line. The heartbeat keeps an idle row live.
- Turn off and Remove end the live flag of each row directly after the server stops (section 11.2). The usage of each row stays.
- The parser keeps the windows `five_hour` and `seven_day` of the rate limits. It drops other windows.
- The mod gives a model ID. The registry maps it to a name with `modelName`: `claude-haiku-5-5` gives `Haiku 5.5`. The suffix `[1m]` adds ` (1M context)`. An ID with an unknown form stays as it is.
- The mod cannot read the session name. The name comes from `claude agents --json`.
- The mod sends each of the four optional fields only when it knows the value. A line before the first `classic.Stop` of its session has no `effort`, `permissionMode` or `transcriptPath`. A line of an older mod has none of the four fields.
- The mod keeps the three `classic.Stop` values for each session ID (`session_id` of the input). `session.end` removes the values of its session. So after `/clear`, a line of the new session ID never has the values of the old session.
- The parser keeps `version`, `effort` and `permissionMode` when each is a text that is not empty. It cuts each to 200 characters. It keeps `transcriptPath` only when the path starts with `/`, has at most 1,024 characters, and has no C0 control (U+0000 to U+001F, also the line breaks), no DEL (U+007F) and no bidi control (U+202A to U+202E, U+2066 to U+2069). A bidi control can make a path look like another path. It leaves out a bad field and keeps the line.
- Each row gets these fields from its last `usage` line: `contextWindowSize` (from `context.window`), `rateLimits`, `claudeVersion` (from `version`), `effort`, `permissionMode` and `transcriptPath`. A missing value leaves the field out. The rate limits are different (next rule).
- A `usage` line without `rateLimits` keeps the last rate limits of its session and the time of the line that had them. Only a line with `rateLimits` replaces them.
- The newest rate limits (M5b D19) are the rate limits with the newest time, of all sessions. The time is the `at` of the line that had them. A session that is not a row also counts, until the registry forgets it. The name is the row name, or the first 8 characters of the session ID when the session is not a row. No session with rate limits gives null.
- The main process sends the newest rate limits on `usage:update` when they change. The value has the time of the line that had them, so a newer line with the same limits is a change. The update limit is that of the rows: at most 4 updates each second, and the last value always goes out. The check runs after each live line, after each forget and at each tick (1 s). The tick finds the other changes, for example a new row name or a usage line that a list poll removed.
- Without the mod, Bifrost shows no model, context %, cost, rate limit, context window size, Claude Code version, effort, permission mode or transcript path.

Statusline in chat windows (O4, 2026-11-05):

- Bifrost no longer installs the wrapper. So Claude Code runs your own statusLine command in each session again.
- A mod cannot stop that command, because the mod API has no statusline hook.
- Bifrost starts each new session with `--settings '{"statusLine":{"type":"command","command":"true"}}'`. The chat window then shows no statusline row.
- Resume and Take control add no flags. A resume with the flag starts a copy with a new session ID.
- A session that Bifrost started with the flag keeps the hidden statusline when it resumes without the flag.
- A session that Take control moved keeps your statusline in its chat window. The user accepted this.
- Sessions in a terminal app, for example Warp, keep your statusline.

### 6.4 Git branch

Bifrost runs `git -C <cwd> rev-parse --abbrev-ref HEAD` every 10 seconds for each project directory. If the directory is not a git repository, the column is empty.

### 6.5 Environment for `claude`

- Bifrost runs each `claude` command and each PTY with the environment of your login shell. The environment comes from `zsh -lic env`.
- Bifrost removes `CLAUDECODE`, `CLAUDE_CODE_*`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERM_SESSION_ID` and `WARP_*`.
- The reason is that Bifrost can start the shared background service. All background sessions get the environment of that service.

## 7. Session states

| State | Box | Cause |
|---|---|---|
| Working | None | `status` is `busy`, or a `turn.start` or `tool.done` event. |
| Alert | Yellow | A `turn.complete` event with the reason `answer` or `refusal`. Claude finished its turn. Rule 11 also sets it. |
| Alert | Red | `status` is `waiting` with a `waitingFor` value (also without the mod), a `permission` event, an `ask` event, or an old yellow box (rule 4). |
| Error | Red | A `turn.complete` event with the reason `error`, or a `stop.failure` event. |
| Idle | None | `status` is `idle`, and no event set a box. Examples are a new session before the first prompt, and a stopped turn (rule 12). |
| Parked | None | The session has no process. The row is grey. The cause is `claude stop`, a restart of the computer, or a process that ends. |

Box rules:

1. A new box flashes.
2. The box flashes for as long as it exists. The flash stops only when the box clears. A selection or a focus of the chat window does not stop it.
3. The box clears when the session starts to work again.
4. A yellow box changes to red after 10 minutes. The timer starts with the yellow box.
5. The "Escalation time" setting changes the time. The value 0 stops the escalation.
6. Bifrost does not move a row because of a box. Only the sort column of the tab sets the row order.
7. External sessions also get boxes from the mod, because the mod is installed at user scope. Each local session loads it.
8. Parked sessions never get a box.
9. A red box also clears when `status` is no longer `waiting`. Another client can answer a prompt. Examples are the agent view, a terminal and a phone.
10. A `status` sample clears a box only after a sample confirmed that box. `idle` confirms a yellow box and an error box. `waiting` confirms a red prompt box. The reason: Claude Code can report `busy` while the Stop hooks run. Live events clear a box at all times.
11. A session with no live line can get a yellow box from the poll alone (O3).
    1. A change of `status` from `busy` or `waiting` to `idle` sets the box. An Esc at a permission prompt of a session with no live line also gives this box.
    2. A session that is idle at the first poll gets no box.
    3. A turn that starts and ends between two polls gives no box.
    4. A later `busy` sample clears the box.
    5. With the mod on, `turn.complete` sets the box. This rule adds nothing.
12. A stopped turn (Esc, or Interrupt in Bifrost) in a live session gives `turn.complete` with the reason `aborted`. The session goes to Idle with no box. The poll gives no yellow box for a live session (D6).
13. `session.start` from the mod only ends the parked state. For a running session it changes nothing. The mod runs `session.start` again at each `/reload-plugins`, and a reload must not clear a box (D7).

## 8. User interface

### 8.1 Window model

Bifrost has one app window. All panels float inside it.

Panel functions:

- Drag the title bar to move the panel.
- Drag an edge or a corner to resize the panel.
- The panel snaps to the window edges and to other panels at 8 pixels or less. The snap occurs only when you release the mouse button. During the drag, the panel follows the pointer, and a small arrow mark shows at the middle of each edge that will snap. Bifrost shows no long guide line.
- Drop a panel on the title bar of a different panel to stack the two as tabs.
- Drag a tab out of a stack to make a separate panel.
- Minimise a panel to the side bar.
- Lock a panel to prevent moves and resizes.
- Only the panel background is translucent. Text and content stay solid. One setting, "Panel transparency", sets the background of all panels (section 12). A panel has no opacity control of its own.

Position memory:

- Each panel has a fixed identity, for example `overview:1`, `selected-item` or `chat:<session-id>`.
- When you close a panel, Bifrost keeps its position and size.
- When you open the panel again, Bifrost puts it in the same position.
- A panel without a saved position opens in the centre of the window.
- If a saved position is outside the window, Bifrost moves the panel into the window.

Layouts:

- You can save the full layout with a name.
- A layout includes the open panels, the stacks and the open chat windows.
- At start, Bifrost restores the last layout.

Display mode:

| Mode | Electron method | Result |
|---|---|---|
| Window | A normal window | A title bar. You can move and resize the window. |
| Borderless | `setSimpleFullScreen(true)` | Bifrost covers the full screen with no title bar and no animation. It stays on the current desktop. |
| Fullscreen | `setFullScreen(true)` | Native macOS full screen on a separate desktop (Space). |

- You can change the mode while Bifrost runs.
- Bifrost keeps the last mode and uses it at the next start.
- The default mode is Window.
- You select Borderless in the View menu or in Settings. Cmd+Ctrl+F toggles Fullscreen (section 9.4).

The side bar is a thin bar on the left edge. It has one button for each panel type. It also holds the minimised panels.

Bifrost uses its own window manager, because the snap and stack rules are specific. M2 can change this decision if a library meets all the rules.

### 8.2 Panels

| Panel | Content |
|---|---|
| Overview | The session list. You can open more than one Overview. Each one has its own tabs and sort. |
| Selected Item | The selected session, its action buttons and the send box. |
| Chat window | The Claude Code terminal UI of one session. |
| Show Info | All details of one session. |
| Event log | All live state events, with their times. |
| Usage HUD | The 5-hour and 7-day rate limits. |
| Watchlist | The sessions that you track, in your own order and colours. |
| Service status | The status of Claude, GitHub and Sentry. |

### 8.3 Overview

Visual layout:

The Overview uses the layout of the EVE Overview, with Bifrost colours, icons and fonts. The reference image is `docs/reference/overview-reference.png`.

- The title bar shows "Overview" and the name of the tab set. A menu button and a minimise button are on the right.
- A row of tabs is below the title bar. Each tab has its own text colour. You can choose the text colour of each tab from 12 colours in Overview Settings.
- A line shows the active tab. A "+" button adds a tab.
- The column headers are small and grey. The sort column shows ▲ or ▼.
- The rows are dense and use the UI font (section 8.10). Text that is too long is cut off. It does not wrap.
- The first column shows a small icon. The icon shape shows the kind of the session: one shape for an owned session, the terminal app icon for an external session, and a dim shape for a parked session. The icon colour shows the project: each project gets a fixed colour from a palette without yellow, red and grey.
- The yellow box and the red box are four corner brackets around the icon, as in EVE. A box flashes until it clears. A yellow box changes to red by the rules of section 7.
- A row can have a background highlight colour.
- The panel background is translucent.

Columns:

| Column | Source |
|---|---|
| Kind icon | `kind`. External rows show the icon of their terminal app (for example Warp or Terminal). An external row with an unknown terminal app shows a `>_` icon. A session that Bifrost started or controls shows the Bifrost logo (a placeholder mark until the logo exists) (user decision, 2026-11-05). |
| Name | `name`. |
| Priority | Bifrost. Values 1 to 5, or none. Each value has a colour. |
| State | The state machine (section 7). |
| Project | `cwd`. The column shows the last two parts of the path. |
| Branch | Git (section 6.4). |
| Model | The model name from the newest live usage line (section 6.3). |
| Context % | The context percent from the newest live usage line. |
| Cost | The cost from the newest live usage line, in US dollars with 2 decimals. A cost above 0 and below one cent shows as `<$0.01`. A cost of 0 shows as `$0.00`. |
| Activity | The time of the latest event from any source. |

Default tabs:

| Tab | Rows |
|---|---|
| All | All sessions except parked sessions. |
| Alerts | Rows with a yellow or red box. |
| Working | Rows with the state Working. |
| Idle | Rows with the state Idle. |
| Parked | Parked sessions. |

The state Alert has the internal ID `needs-you`. Older versions named the second tab "Needs you". When Bifrost loads a saved config, it renames the tab `t2` with that exact name to "Alerts". It changes no other tab name.

Tab rules:

- You can add, remove, rename and move tabs.
- Each tab has its own filter, columns and sort column.
- Click a column header to sort by that column. Click it again to reverse the sort.
- The menu of the Overview (the vertical dots in its title bar) has "Overview settings…". It opens the Overview Settings panel, as in EVE.
- The Overview Settings panel has a tab selector for the Overview tab that you edit, and two tabs. Columns: a checkbox for each column and a drag to change the column order. The kind icon column is always on. Filters: checkboxes for the states, the kinds and the watched sessions that the tab shows. "Reset to default" restores the tab.
- The default columns are Kind, Name, State, Project and Activity. You turn on the other columns in the Overview Settings panel.

Mouse:

| Input | Result |
|---|---|
| Left-click | Selects the session. |
| Double-click | Opens the chat window. |
| Right-click | Opens the right-click menu. |
| Hold a key and left-click | Does the action of that key on the row (section 9.4). |

### 8.4 Selected Item

The panel shows these items, from top to bottom:

1. The name, the state and the priority. A row with no priority shows no priority.
2. A row of icon buttons: Open, Send message, Run slash command, Interrupt, Show Info, Open in terminal and Stop session.
3. The project, the branch, the model and the cost. The Model row shows the model name, then the context bar, then the context percent with the word "context", for example `Opus 5.5  [bar]  28% context`. The bar takes the free width. The model name keeps its width and is cut off only when the row is too narrow. With no percent, the bar is empty and the text is `-`. The cost has its own row.
4. The first 3 lines of the last Claude reply. The `turn.complete` event supplies this text.
5. The send box.

The context bar has three colour bands, as in the statusline. Below 40% the bar is green. From 40% to below 70% it is amber. From 70% it is red. The tokens are `--color-ctx-low`, `--color-ctx-mid` and `--color-ctx-high`. Each token differs from the box yellow and the box red by 0.10 or more in OKLab.

Send box rules:

- Enter sends the text. Shift+Enter adds a new line.
- Text that starts with `/` runs as a slash command.
- If the chat window is open, Bifrost writes into the PTY of that window.
- If the chat window is not open, Bifrost types through a hidden attach.
- Bifrost sends text as a bracketed paste (`ESC[200~` text `ESC[201~`), then CR.
- A hidden attach is ready when its output is quiet for 1.5 seconds.
- Bifrost never sends CR to an empty prompt.
- One attach PTY serves each session.
- A hidden attach opens at the current size of the session (the M3 method). An attach sets the size of the session for all clients (M3 finding). If Bifrost cannot read the size, it sends nothing.
- If the session has a red box of a prompt (a permission prompt or a question), Bifrost blocks Send message, Run slash command and Rename. Typed text can answer a prompt by accident. An escalated yellow box and an error box do not block, because no prompt shows.
- Interrupt sends Esc. It does not wait for quiet output, because a working session is never quiet: through a hidden attach, Bifrost sends Esc 300 ms after the first output of the attach.
- After an Esc, Bifrost waits at least 200 ms before the next write to that session. So the session never gets an Esc and a paste in one chunk.
- The block message is "Answer the prompt in the chat window first."
- The send box is not available for external sessions or parked sessions.

### 8.5 Chat window

- The chat window runs `claude attach <id>` in node-pty and shows it in xterm.js.
- The title bar shows the name, the state colour and the priority.
- When you close the chat window, Bifrost sends SIGHUP to the attach process. The session continues.
- Bifrost debounces resize events, because a resize causes a full redraw.
- Text selection uses Option+drag (`macOptionClickForcesSelection`), because the TUI uses mouse tracking.
- Bifrost sends the replies of the xterm.js terminal to the PTY.
- Bifrost never sends the ← key.
- If the user opens the agent view in a chat window, Bifrost detects it and attaches to the session again.
- A new session of Bifrost shows no statusline row in its chat window (section 6.3).
- Visible chat windows use the WebGL renderer.
- A chat window in a back tab, or a minimised chat window, releases its WebGL context.

Size rule (the user approved this on 2026-11-04; M3 builds it):

- A session has one terminal size for all its clients. The last resize from any client sets it (M0 question 3).
- Only the chat window that has focus sends a resize to the session.
- A chat window with a different size from the session zooms the terminal to fit. The layout stays correct.
- A resize in a terminal app, for example Warp, also sets the size. Bifrost then zooms its chat window to that size.
- M3 test (2026-11-05): yes. Bifrost reads the size from the TTY of the session process (`ps -o tty=`, then `stty -f /dev/<tty> size`) within 80 ms of a resize. A new attach also sets the session size. See `docs/m3-findings.md`.

### 8.6 Show Info

Show Info shows these values for one session:

- Name, session ID, short ID, kind and PID.
- Project directory and transcript path.
- Branch, PR and worktree.
- Model, effort and permission mode.
- Start time and duration.
- Cost, context window size and context use.
- Rate limits and the Claude Code version.

You can open one Show Info panel for each session.

### 8.7 Event log

The Event log shows the live state events with the time, the session and the event name. A `usage` line is not in the log. You can filter it by session. It keeps the last 5,000 events in memory. It does not keep events on disk.

### 8.8 Usage HUD

The Usage HUD shows two bars: the 5-hour limit and the 7-day limit. Each bar shows the use and the reset time. The data comes from the newest live usage line. With no data, the panel shows "No usage data yet."

### 8.9 New session dialog

| Field | Default |
|---|---|
| Directory | The last directory. A list shows recent project directories. A Browse button is also available. |
| Name | The directory name and a short suffix. |
| Model | The last model. |
| Permission mode | The last mode. |
| First prompt | Empty. This field is optional. |
| Worktree | Off. This field is optional. |

Dialog rules:

- Enter accepts the current values.
- Bifrost runs `claude --bg` in the directory, with the flags from the dialog.
- After `claude --bg`, Bifrost waits for the entry in `claude agents --json`. Exit code 0 is not proof of a start.
- If `claude --bg` gives the trust error, the dialog shows the error. It tells the user to run `claude` in that directory one time and accept the trust prompt.
- After the entry appears, Bifrost opens the chat window of the new session.
- M4 test (2026-11-05): `--worktree <name>` works in a trusted repository. See `docs/m4-findings.md`.

### 8.10 Theme

- The theme is dark and neutral, as in the EVE interface: near-black panels, grey title bars and section headers, light grey text and white for emphasis. The panel backgrounds are translucent, with a background blur.
- The accent colour is a light cyan, as in EVE. Bifrost uses the accent on few elements. The top border of each panel is a 1 px cyan line. The focused panel has the full line and a cyan glow above its top edge only. Other panels have a dim line and no glow. A click on a button, a tab or a row gives a short cyan tint with low opacity.
- The focused panel is less transparent than the other panels, so it stands out, as in EVE. The background, the border and the glow change in 250 ms when the focus moves (user decision, 2026-11-05).
- A selected row gets a light, low-opacity cyan background, so it differs from a neutral row. A tab in a panel stack is white with a white underline when it is active. An Overview tab keeps its own text colour (section 8.3), and the active Overview tab has an underline in that colour, as in EVE.
- All corners are square, as in EVE: panels, buttons, menus, tooltips, checkboxes, tabs and dots. Square corners leave no gap between panels that snap together (user decision, 2026-11-05).
- The UI font is Geist Mono (OFL licence), bundled with the app (user decision, 2026-11-05). All interface text uses it, also the Overview rows. The chat terminals keep their own font setting (section 12).
- Bifrost uses its own icons and fonts. It does not copy EVE art, icons or fonts.
- One file holds all colour tokens.
- The box yellow, the box red and the parked grey are reserved shades. Other Overview colours can be red, amber or yellow. Each of them differs clearly from the box shades (OKLab distance 0.10 or more). A test checks this.
- The Overview uses no purple and no pink for now. The user keeps purple for a later feature (fleets, as in EVE) (user decision, 2026-11-05). The rule covers only the Overview colours: the `project`, `tab` and `prio` tokens. Other panels may use purple and pink, for example the Watchlist, the Usage HUD and Service status (user decision, 2026-11-06). A test checks the three Overview families only. The M5b panels keep their colours for now.
- The terminal font is a setting.

### 8.12 Watchlist

The Watchlist is like the fleet watchlist in EVE. It holds the sessions that you want to track.

- "Add to watchlist" in the right-click menu and on the Selected Item panel adds a session. You select a colour in a submenu.
- The colours follow the EVE standings colours: dark red, red, amber, yellow, green, light blue, dark blue and white. Light blue and dark blue are like good and excellent standing in EVE. The colours show only as a translucent row background. The watch red and yellow are a different shade from the box colours, and a yellow or red box must stay clearly visible on every watched row, also on a selected one (user decision, 2026-11-05). A saved colour from before this change maps to the nearest new colour.
- The Watchlist panel shows one row for each watched session: the icon with its box, the name and the state. The row background has the watch colour, translucent.
- You drag a row up or down to change the order. The order is your priority. The list shows no numbers.
- A click selects the session. A double-click opens its chat window. The right-click menu has "Change colour" and "Remove from watchlist".
- In the Overview, a watched row also has its watch colour as the row background (section 8.3). A "Watched" tab shows only the watched sessions.
- The watch data belongs to the session. Bifrost keeps it with the session names and priorities. A session that leaves all lists leaves the Watchlist.
- Priority 1 to 5 (section 9.1) is a separate feature.

### 8.11 Service status

- The Service status panel shows the status of Claude, GitHub and Sentry. `claude-statusline` checks the same services.
- Bifrost checks each status page one time each minute. One check serves all sessions.
- An outage shows the service name, the incident name and the impact: minor, major or critical.
- The panel does not use yellow, red or grey for an outage, because these colours have fixed meanings (section 8.10).

## 9. Actions and keys

### 9.1 Actions

| Plain label | Space label | Available for | Method |
|---|---|---|---|
| New session | Launch | - | `claude --bg` (section 8.9). |
| Open | Warp to | Owned | Focus or open the chat window. |
| Send message | Hail | Owned | Type the text into the session. |
| Run slash command | Activate module | Owned | Type `/<command>` into the session. |
| Interrupt | Full stop | Owned | Send Esc to the session. |
| Rename | Set callsign | Owned | Type `/rename <name>` into the session. |
| Set priority | Set threat level | All | Bifrost data only. |
| Resume | Reactivate | Parked | `claude --bg --resume <session-id>`. |
| Resume all | Reactivate all | Parked | Resume each parked session that was active when Bifrost last ran. |
| Show Info | Scan | All | Open the Show Info panel. |
| Copy session ID | Copy transponder ID | All | Copy to the clipboard. |
| Open project | Open cargo hold | All | `open -a <app> <cwd>`. |
| Open in terminal | Jump to terminal | Owned, external | Owned: run `claude attach <id>` in the terminal app. External: bring the terminal app to the front. |
| Take control | Commandeer | External | Section 9.2. |
| Close window | Disengage | Owned, with an open chat window | End the attach process. |
| Stop session | Power down | Owned | `claude stop <id>`. Bifrost asks for confirmation if the session is busy. |
| Delete session | Self-destruct | Owned, parked | `claude rm <id>`. Bifrost always asks for confirmation. |
| Add to watchlist | Track | All | Bifrost data only (section 8.12). |
| Remove from watchlist | Stop tracking | Watched sessions | Bifrost data only (section 8.12). |

The "Labels" setting selects plain labels or space labels. The setting applies to menus, buttons, tooltips and dialogs.

Bifrost disables an action that is not available. The action shows darker and faded in menus and on buttons, as in EVE. Clicks and keys have no effect on it. A tooltip gives the reason.

### 9.2 Take control

Rules:

- The action is available only for an external session that is idle or has a yellow box.
- Bifrost blocks the action when the session is busy. The action would stop the work.
- Bifrost blocks the action when the session has a red box. The end of the process would cancel the open prompt.

Bifrost does these steps:

1. Find the terminal app from the parent processes of the session. Use the `.app` part of the process path for the app name.
2. Show the confirmation: "This ends the {terminal} process and hands control to Bifrost."
3. Send SIGTERM to the session process.
4. Wait for the process to end, for a maximum of 5 seconds.
5. Run `claude --bg --resume <session-id>` in the session directory.
6. Find the new entry by `sessionId`, not by name.
7. Open the chat window of the session.

If the process does not end in 5 seconds, Bifrost stops and shows an error. It does not start a copy of the session.

### 9.3 Key rules

- A shortcut that includes Cmd works at all times, also when a chat window has focus.
- A shortcut with Ctrl but without Cmd goes to Bifrost only when focus is not in a chat window.
- A single-key shortcut acts on the selected session.
- A shortcut for a session, for example Cmd+. or Cmd+Shift+Backspace, acts on the selected session.
- When the focus moves into a chat window, Bifrost selects the session of that window. So a session shortcut in a chat window acts on the session of that window, and the Selected Item panel shows it.
- A single-key shortcut works only when focus is not in a chat window or a text box.
- Hold-key-and-click actions use letter keys and number keys.
- Hold-key-and-click actions do not use Ctrl, because macOS changes Ctrl+click into a right-click.
- You can change all keys in Settings > Keys.
- Bifrost does not use the shortcuts that macOS keeps (section 9.7).

The key map stores "Mod" in place of "Cmd". On macOS, Mod is Cmd. A Windows port can make Mod equal to Ctrl+Shift.

### 9.4 Default key map

Shortcuts that work at all times:

| Keys | Action |
|---|---|
| Cmd+N | New session |
| Cmd+1 to Cmd+9 | Select row 1 to 9 in the focused Overview |
| Cmd+Up, Cmd+Down | Select the previous row, the next row |
| Cmd+0 | Move focus to the Overview |
| Cmd+Enter | Open |
| Cmd+Shift+M | Send message (focus the send box) |
| Cmd+/ | Run slash command |
| Cmd+. | Interrupt |
| Cmd+I | Show Info |
| Cmd+Shift+C | Copy session ID |
| Cmd+Shift+O | Open project in the default app |
| Cmd+Shift+J | Open in terminal |
| Cmd+Shift+T | Take control |
| Cmd+R | Resume |
| Cmd+Shift+R | Resume all |
| Cmd+Ctrl+1 to Cmd+Ctrl+5 | Set priority 1 to 5 |
| Cmd+Ctrl+0 | Clear the priority |
| Cmd+W | Close the focused panel |
| Cmd+Shift+Backspace | Stop session |
| Cmd+Option+Shift+Backspace | Delete session |
| Cmd+[, Cmd+] | Previous tab, next tab in the focused stack |
| Cmd+Option+1 to Cmd+Option+9 | Load layout 1 to 9 |
| Cmd+Option+S | Save the layout |
| Cmd+L | Event log |
| Cmd+U | Usage HUD |
| Cmd+, | Settings |
| Cmd+Ctrl+F | Toggle Fullscreen (the macOS meaning) |

Bifrost binds no default key for Borderless. Select Borderless in the View menu or in Settings.

Close the focused panel and Toggle Fullscreen are shortcuts of the app menu. A menu shortcut needs Cmd. Settings > Keys refuses a menu shortcut without Cmd.

Single keys. These work only when focus is not in a chat window or a text box:

| Key | Action |
|---|---|
| Up, Down | Select the previous row, the next row |
| Tab, Shift+Tab | Next Overview tab, previous Overview tab |
| O or Enter | Open |
| M | Send message |
| / | Run slash command |
| X | Interrupt |
| I | Show Info |
| J | Open in terminal |
| P | Open project |
| C | Copy session ID |
| R | Rename |
| T | Take control |
| 1 to 5 | Set priority |
| 0 | Clear the priority |
| Backspace | Stop session |
| Shift+Backspace | Delete session |
| Esc | Clear the selection, or leave the send box |

Hold a key and left-click a row:

| Hold | Action on the row |
|---|---|
| O | Open |
| M | Send message |
| I | Show Info |
| J | Open in terminal |
| X | Interrupt |
| 1 to 5 | Set priority |

Bifrost uses the hold key that is down when you push the mouse button on the row. If you release the key before the mouse button, the action applies to that row, not to the selected row.

### 9.5 Right-click menu

The menu shows plain labels below. With space labels, the menu uses the space label from section 9.1.

```text
Open
Send message...
Run slash command    >   favourites, recent commands, Other...
Interrupt
-----------------------
Set priority         >   1, 2, 3, 4, 5, None
Rename...
Show Info
Copy session ID
Open project         >   Finder, VS Code, Zed, <terminal app>
Open in terminal
-----------------------
Take control             (external sessions only)
Resume                   (parked sessions only)
Close window             (when the chat window is open)
Stop session...
Delete session...
```

The "Open project" submenu shows only the apps on your Mac.

### 9.6 Slash command favourites

Settings > Slash commands holds your favourite commands. The default list is `/compact`, `/clear` and `/context`. The submenu shows the favourites first, then the 5 most recent commands.

### 9.7 Shortcuts that macOS keeps

Bifrost does not bind these shortcuts:

- Cmd+Tab, Cmd+Space, Cmd+H, Cmd+M and Cmd+Q.
- Cmd+Option+Esc.
- Cmd+Shift+3, Cmd+Shift+4 and Cmd+Shift+5.
- Cmd+Shift+Q and Cmd+Shift+/.
- Cmd+Ctrl+Q.
- Ctrl+Space.

Cmd+Ctrl+F keeps its macOS meaning. In Bifrost, it toggles Fullscreen (section 8.1).

## 10. Alerts

| Alert | Default | Cause |
|---|---|---|
| Row flash | On | A yellow box or red box flashes until it clears. |
| macOS notification | On | A new box when Bifrost is not in focus. |
| Sound | On | A new red box. |

Click a notification to select the session and open its chat window. This also works when the Bifrost window is closed. Bifrost opens the window and keeps the session until the page has loaded. Then it opens the session.

## 11. First-run setup and integration

### 11.1 Setup dialog

At the first start, Bifrost shows the setup dialog (M5a builds it). The dialog shows each change before Bifrost makes it, in the order of Install (section 11.2):

1. The removal of an old hook install, if Bifrost finds one (section 11.3).
2. The folder `~/.bifrost/mod`, where Bifrost copies the four files of the mod.
3. The plugin `bifrost-live@bifrost-local` and the marketplace `bifrost-local`, both at user scope.

You select "Turn on Live details" or "Skip". "Turn on Live details" runs Install. After a good Install, the dialog shows the reload note and a Done button. After Skip or a good Install, the dialog does not show again.

The dialog shows only when no choice is saved and the plugin is not installed, or Bifrost cannot read its state. An installed plugin, on or off, is already a choice. Then Bifrost saves the choice and shows no dialog. Esc and a click outside the dialog do nothing.

### 11.2 Live details actions

Live details needs Claude Code 2.1.290 or later. Bifrost runs `claude plugin` only with the arguments below. Each command has a timeout of 30,000 ms. The API for M5a is `live.status()`, `live.install()`, `live.enable()`, `live.disable()` and `live.uninstall()`.

Install:

1. Check the version of Claude Code. Below 2.1.290, stop.
2. Find `claude`. If Bifrost cannot find it, stop.
3. Run `plugin marketplace list --json`. If `bifrost-local` has another path or no path, stop and show an error. Bifrost has changed nothing at this point.
4. Read `~/.claude/settings.json`. If Bifrost cannot read it, stop and show an error. Bifrost has changed nothing at this point.
5. Remove an old hook install, if Bifrost finds one (section 11.3). If this fails, stop. Bifrost then runs no `claude plugin` command.
6. Copy the four files of `resources/live-mod/` to `~/.bifrost/mod`.
7. If step 3 found no `bifrost-local`, run `plugin marketplace add <mod folder> --scope user --json`.
8. Run `plugin list --json`. If the plugin is not installed, run `plugin install bifrost-live@bifrost-local --scope user --json`, and then run `plugin list --json` again. If the plugin is installed and off, run `plugin enable bifrost-live@bifrost-local --scope user --json`.
9. Start the socket server. If a stop, a Turn off or a Remove came after the start of the Install, Bifrost does not start the server.

Turn on:

1. Check the version of Claude Code. Below 2.1.290, stop.
2. Find `claude`. If Bifrost cannot find it, stop.
3. Run `plugin list --json`. If the plugin is not installed, stop.
4. Read `~/.claude/settings.json`. If Bifrost cannot read it, stop and show an error. Bifrost has changed nothing at this point.
5. Remove an old hook install, if Bifrost finds one. If this fails, stop.
6. Copy the four files of `resources/live-mod/` to `~/.bifrost/mod`.
7. Run `plugin enable bifrost-live@bifrost-local --scope user --json`.
8. Start the socket server. If a stop, a Turn off or a Remove came after the start of Turn on, Bifrost does not start the server.

Turn on refuses when the plugin is not installed. A Live details switch calls Install when `plugin` is `not-installed`. Otherwise it calls Turn on or Turn off.

Turn off:

1. Stop the socket server at once. The server is the switch that acts at once (D9).
2. End the live flag of each row. The poll yellow box (section 7, rule 11) then applies at once, and the status gives 0 live sessions. The usage of each row stays.
3. Run `plugin list --json`. If the plugin is installed, run `plugin disable bifrost-live@bifrost-local --scope user --json`.

If step 3 fails, Turn off shows the error. The server stays stopped.

Remove:

1. Stop the socket server.
2. End the live flag of each row.
3. Run `plugin list --json`. If the plugin is installed, run `plugin uninstall bifrost-live@bifrost-local --scope user --json`.
4. Run `plugin marketplace list --json`. Only if `bifrost-local` has the path of the mod folder, run `plugin marketplace remove bifrost-local --scope user --json`. This also uninstalls each other plugin of that marketplace.
5. Delete `~/.bifrost/mod`.
6. Remove an old hook install, if Bifrost finds one. This is the last step. If Bifrost cannot read `~/.claude/settings.json`, or the removal fails, Remove shows the error after the plugin steps. The reason: a failed removal of the old install must not leave the mod installed.

Rules:

- Bifrost listens on the socket only while the plugin is on (D9). It also listens when the plugin state is unknown and the mod folder exists. `BIFROST_LIVE_LISTEN=1` forces it for a check.
- After Turn off, the sends of running sessions fail in about 1 ms. A running session keeps the mod until a restart or `/reload-plugins`.
- A running session loads a new or changed mod only at its start or at `/reload-plugins`. After Install or Turn on, Bifrost tells the user this.
- Bifrost does not run `/reload-plugins` in a session.
- One action runs at a time. An action that comes while another action runs fails with "Another change is still running. Try again in a moment."
- At each start of Bifrost, the start of Live details (section 11.5) runs first. An action that comes before this start ends waits for it. Then two copies of the mod folder never run at the same time.
- At the timeout of 30,000 ms, the two list commands get SIGKILL. The six write commands get SIGTERM, because a SIGKILL can leave a change half done. A write command that has not ended 10,000 ms after the SIGTERM fails. A timeout gives "Claude Code didn't finish in 30 seconds."
- A stop during a start wins. The server never deletes a file that is not a socket. It never deletes a socket that answers.
- A stop of the server also clears an old server error. After Turn off or Remove, the status shows no old error.
- The name `bifrost-local` is not `bifrost`, so a clash with another marketplace is less likely.

### 11.3 Remove an old hook install

Bifrost no longer installs hooks or the statusline wrapper. It makes no `active` file, reads no event files or status files, and writes no `quiet` files. An old install without `active` does nothing.

If `~/.claude/settings.json` has hook entries that run `~/.bifrost/bin/bifrost-hook`, Bifrost removes them. Bifrost does these steps:

1. Make a new backup in `~/.bifrost/backups/`.
2. Remove each hook entry that runs `~/.bifrost/bin/bifrost-hook`.
3. Restore your statusLine setting from `~/.bifrost/statusline-original.json`.

Bifrost keeps `statusline-original.json` and `backups/` for this step.

At each start, before the start of Live details, Bifrost deletes the data of the old hooks:

- `~/.bifrost/active`, `~/.bifrost/events/` and `~/.bifrost/sessions/`.
- `~/.bifrost/bin/`, but only when `~/.claude/settings.json` has no old hook entry. Old hook entries still run the scripts in `bin/`. Settings that Bifrost cannot read also keep `bin/`.

An older Bifrost (M1 to M4) that runs at the same time also loses these files. The design accepts this, because the old hooks do nothing without `active`.

### 11.4 Skip

If you select "Skip", Bifrost shows only the data from `claude agents --json`. This data is the name, the project and the `status`. Bifrost then shows the red box for a `waiting` session and the poll yellow box (section 7, rule 11). It shows no model, cost or context %.

### 11.5 Checks at start

- Bifrost deletes the data of the old hooks at each start (section 11.3). Then the start of Live details runs.
- Bifrost runs `claude plugin list --json` at each start. If the plugin is on and the mod folder differs from the app files, Bifrost copies the four files again.
- A running session gets the new files after `/reload-plugins` or a restart.
- Bifrost reads `claude --version` at each start. Below the minimum version, Bifrost shows a warning. The minimum version is 2.1.281.
- Live details needs version 2.1.290. Below it, Bifrost shows a warning and does not install the mod.

## 12. Settings

| Setting | Default |
|---|---|
| Labels | Plain |
| Terminal app | The first installed app from this list: Warp, Ghostty, iTerm2, Terminal. |
| Default app for "Open project" | Automatic: VS Code, else Zed, else your terminal app. The select does not list Finder. A saved value `finder` acts as Automatic. The right-click `Open project` submenu still lists Finder. |
| Escalation time | 10 minutes. The value 0 stops the escalation. |
| Row flash | On |
| macOS notification | On |
| Sound for a red box | On |
| Start at login | Off |
| Poll interval | 2 seconds |
| Snap distance | 8 pixels |
| Panel transparency | 15%. A select from 0% to 50% in steps of 5% (the background of all panels; 0% is solid). |
| Interface scale | 100%. A select from 80% to 150% in steps of 10% (Electron zooms the whole page; View menu Zoom In Cmd+=, Zoom Out Cmd+-, Actual Size). |
| Slash commands | `/compact`, `/clear`, `/context` |
| Terminal font | SF Mono, 13 pt |
| Display mode | Window |
| Keys | Section 9.4 |
| Live details | Not installed. The section has Install, Turn on, Turn off and Remove (section 11.2). |

## 13. Performance targets

- 20 sessions in the registry.
- 8 visible chat windows at the same time, with smooth output.
- A maximum of 12 WebGL contexts.
- A maximum of 4 registry updates to the renderer each second.
- Less than 800 MB of memory with 8 open chat windows.
- One `claude agents --json` process at a time. A new poll starts only after the last poll ends.
- The mod starts no process. A hook spends less than 1 ms before next.

## 14. Build and release

### 14.0 Stack

Bifrost uses the same tools as Overseer and Herald where a feature needs them. Bifrost adds a library only when a feature needs it.

| Library | Feature that needs it | Milestone |
|---|---|---|
| Electron, electron-vite, React, TypeScript | The app | M0 |
| node-pty, `@xterm/xterm` and its fit and WebGL addons | Chat windows | M0 |
| Biome | Lint and format | M0 fix wave |
| Vitest | Unit tests | M0 |
| Tailwind CSS v4 | All styles. Bifrost has its own theme and tokens. It does not copy styles from other projects. Version 4.3.3 with `@tailwindcss/vite`. | M2 |
| `@fontsource/geist-mono` | The UI font (section 8.10). Version 5.3.0, OFL-1.1 licence. | M3 |
| Base UI | The right-click menu with submenus, dialogs and tooltips. Version 1.9.0. | M3 |
| TanStack Table | Overview columns, sort, column order and column widths for each tab. Version 9.3.1. | M3 |
| TanStack Hotkeys (beta) | Key map, hold-key-and-click, key editor in Settings. Version 0.16.0 of `@tanstack/react-hotkeys` (with `@tanstack/hotkeys` 0.17.0). | M3 to M5 |
| lucide-react | Icons. Version 1.61.0. | M3 |
| Zustand | Not used. A reducer keeps the window manager state (M2). | M2 |
| Zod | Not used. The hand-written checks stay small (M1). | M1 |
| lefthook and commitlint | Commit message checks. Added in M1. | M1 |
| Playwright for Electron | Smoke test. Version 1.64.1 of `@playwright/test`. The smoke test uses `BIFROST_TEST_HOME` and a fake `claude`. | M5 |

### 14.1 Now

- The tools are pnpm, electron-vite, TypeScript 5.9, React, Biome, `@xterm/xterm`, `node-pty` and electron-builder.
- Biome replaces ESLint and Prettier.
- M1 keeps TypeScript 5.9. TypeScript 7.0.2 failed `pnpm typecheck`: `tsconfig.web.json` uses `baseUrl`, and TypeScript 7 removed it (TS5102 and TS5090). To try TypeScript 7 again, remove `baseUrl` and set the `paths` value to `./src/renderer/src/*`.
- `package.json` has `"engines": { "node": ">=24" }`.
- Scripts are ESM TypeScript files. Node runs them directly.
- Scripts that load `node-pty` run with `ELECTRON_RUN_AS_NODE=1 electron <file>.ts`.
- Bifrost has no CommonJS files.
- `pnpm dev` starts Bifrost from the repository.
- `pnpm dist` makes a DMG for Apple Silicon (arm64) only. The DMG has no Intel code (decision of 2026-11-06).
- Do not start Bifrost under Rosetta (`arch -x86_64`) on an Apple Silicon Mac. macOS 26 then shows a notice that Bifrost "includes a component that will not work with a future release of macOS".
- The build uses an ad-hoc signature, because Apple Silicon does not run code without a signature.
- electron-builder uses `identity: '-'` and `hardenedRuntime: false`. node-pty stays outside the asar. The build leaves out the `darwin-x64` and `win32` node-pty prebuilds.
- The app has no `node-pty/build` folder. That folder holds an arm64 build only, and node-pty loads it before the prebuilds.
- `package.json` has `"private": true` and `"license": "UNLICENSED"`.
- The repository has no remote.
- Bifrost stays on your Mac for now.

### 14.2 Later

- The Account Holder of the company Apple Developer team creates a "Developer ID Application" certificate.
- An Admin with the cloud-managed Developer ID access role can also sign.
- electron-builder signs the app with this certificate and the hardened runtime.
- electron-builder also signs the native files of `node-pty`, which include `spawn-helper`.
- `notarytool` sends the DMG to Apple for notarization.
- The App Store Connect API key comes from environment variables. It is never in the repository.
- You give the DMG to colleagues by hand.
- A later version adds an S3 update feed and `electron-updater`.

## 15. Tests

| Level | Tool | Scope |
|---|---|---|
| Unit | Vitest | The state machine, the registry merge, install and uninstall, and key map conflicts. |
| Mod | `claude plugin test` | The hooks module, with a fake `http.fetch`. |
| Smoke | Playwright for Electron | Bifrost starts with a fake `claude` command on the PATH and shows the sample sessions. Bifrost runs with `BIFROST_TEST_HOME`, so the test does not use the real home. |
| Manual | Checklist | The M0 questions, Take control and the DMG. |

## 16. Milestones

| Milestone | Content | Exit criteria |
|---|---|---|
| M0 - Test | The questions in section 17. | All answers are known. If an answer blocks the design, stop and ask the user. |
| M1 - Data | Hook script, wrapper, install, uninstall, registry, state machine. | The unit tests pass. A debug view shows real sessions with boxes. |
| M2 - Window manager | Panels, drag, resize, snap, stacks, position memory, layouts, display modes. | All panel functions in section 8.1 work. |
| M3 - Core panels | Overview (with the visual layout of section 8.3), Selected Item, right-click menu, chat windows. | You can select, open and use sessions. |
| M4 - Actions | Send box, slash commands, stop, delete, new session, Take control, parked sessions, Resume all. | All actions in section 9.1 work. |
| Live - Live details | The Live details mod, the socket server, the live registry rules, and Install, Turn on, Turn off and Remove. | Part A and Part B of the check with real test sessions pass (`docs/live-findings.md`). Part A: yellow, red and stopped-turn rows, the heartbeat, a closed Bifrost, and the poll-only yellow box. Part B: Install, Turn on, Turn off and Remove, and `settings.json` has no change. |
| M5 - Finish | Keys, label toggle, alerts, Show Info, Event log, Usage HUD, Service status, theme, DMG. | You install the DMG on your Mac and use Bifrost. |

## 17. Questions for M0

The answers are in `docs/m0-findings.md`.

1. Does `claude attach` show correctly in xterm.js through node-pty? Check the colours, the mouse and the resize.
2. Does the statusline show in an attached session?
3. Can two clients attach to one session at the same time? What occurs to the first client?
4. What is the clean method to detach? Is it the end of the attach process, or the ← key?
5. Can a hidden attach type text and Enter correctly? Check bracketed paste for text with more than one line.
6. Which signal ends an interactive session cleanly and keeps the conversation?
7. After that signal, does `claude --bg --resume` keep the same session ID?
8. Which values do `kind` and `status` have in `claude agents --json`?
9. How does `claude agents --json` show a session that the supervisor stopped after 1 hour?
10. Which flags does `claude --bg` accept? Check `--name`, `--model`, `--permission-mode`, a first prompt and a worktree.
11. Does `/rename` exist in Claude Code 2.1.318?
12. Which Claude Code version is the minimum?

## 18. Decisions from the review

The user confirmed these points in the review on 2026-11-04:

1. The escalation timer starts with the yellow box. Your selection does not stop the timer. It does not stop the flash either (changed on 2026-11-06).
2. The Take control confirmation names Bifrost (section 9.2).
3. The space label for "Take control" is "Commandeer".
4. Bifrost disables an action that is not available. The action shows darker and faded, as in EVE (section 9.1).
5. The "All" tab does not show parked sessions.
6. After a new session starts, its chat window opens.
7. Interrupt uses the single key X and the shortcut Cmd+.
8. "Resume all" resumes each parked session that was active when Bifrost last ran.
9. The `claude-statusline` installer always replaces the statusLine block. If you run it again, it removes the wrapper. Bifrost then shows the Repair warning.

## 19. Decisions at the M0 gate

The user approved these changes on 2026-11-04. The M0 findings are in `docs/m0-findings.md`.

1. Part A, 2026-11-04: Bifrost has three display modes: Window, Borderless and Fullscreen (section 8.1).
2. Part B, 2026-11-04: The Overview uses the visual layout of the EVE Overview (section 8.3).
3. Part C, 2026-11-04: Settings has a "Display mode" row (section 12).
4. Part D, 2026-11-04: Cmd+Ctrl+F toggles Fullscreen. Borderless has no default key (sections 9.4 and 9.7).
5. Part E, 2026-11-04: Bifrost adds a library only when a feature needs it (section 14.0).
6. Part F, 2026-11-04: Biome replaces ESLint and Prettier. Scripts are ESM TypeScript (section 14.1).
7. Part H, 2026-11-04: New facts about `status`, `waitingFor`, trust and the shared service (section 4).
8. Part I, 2026-11-04: The session list keeps entries without `pid` and uses `status` (section 6.1).
9. Part J, 2026-11-04: A `waiting` status sets a red box. Parked has no cause "idle for 1 hour" (section 7).
10. Part K, 2026-11-04: The send box uses bracketed paste and waits for a quiet attach (section 8.4).
11. Part L, 2026-11-04: The chat window sends SIGHUP on close and handles the agent view (section 8.5).
12. Part M, 2026-11-04: A new session waits for its entry and shows the trust error (section 8.9).
13. Part N, 2026-11-04: Take control uses SIGTERM and finds the session by `sessionId` (section 9.2).
14. Part O, 2026-11-04: Bifrost runs `claude` with the login-shell environment (section 6.5).
15. Part P, 2026-11-04: The minimum Claude Code version is 2.1.281 (section 11.5).

## 20. Decisions after M1

The user gave these directions on 2026-11-04:

1. Chat windows show no statusline. The wrapper does not run your statusLine command for owned sessions (section 6.3). The reason is the cost: with 10 sessions, each statusline starts many processes each second.
   Section 23 changes this item. The wrapper is gone. Bifrost passes a `--settings` flag to each new session instead.
2. Data that is the same for all sessions goes in separate panels: the Usage HUD and the Service status panel (sections 8.8 and 8.11).
3. Data for one session goes in the Overview and the Selected Item panel (sections 8.3 and 8.4).

## 21. Decisions on 2026-11-05 (UI review)

The user gave these directions after he used the M2 build:

1. The Overview columns can be resized (built in M3).
2. The row icon shows the kind of the session, in a colour for each project. The box is four corner brackets around the icon (section 8.3).
3. A panel snaps only on release, with small arrow marks and no long guide line (section 8.1).
4. A panel has no opacity control. Only the panel background is translucent, and one Settings row sets it (sections 8.1 and 12).
5. The theme follows the neutral EVE look, with a light cyan accent on the panel top borders and for click feedback (section 8.10).
6. Bifrost tries a Claude Code mod as an option that replaces the hooks and the statusLine wrapper. The poll of `claude agents --json` stays as the base.
7. A Watchlist panel holds the sessions that you track, in your drag order and your colours (section 8.12). It comes in M4.
8. The Overview menu opens an Overview Settings panel with column checkboxes and filters. The default columns are fewer (section 8.3).
9. Settings has an Interface scale from 80% to 150% for different screen resolutions (section 12). It comes in M5a.
10. No element has rounded corners (section 8.10).

## 22. Decisions in M4 (2026-11-05)

The user made decisions 1 to 3. The controller made the others during M4. The M4 ledger and `docs/m4-findings.md` give the reasons.

1. A session that Bifrost starts gets the flag that turns its statusline off only when the Bifrost statusline wrapper is not installed. With the wrapper, the `quiet` file hides the statusline in chat windows, and Bifrost still gets the status data (section 6.3).
   Section 23 changes this item (D13). Bifrost now passes the flag for every new session.
2. A watched row has a soft tint and a 3 px stripe in the full watch colour at its left edge. The yellow box and the red box keep a contrast of 3:1 or more on each watched row, also when it is selected or under the pointer. The watch red and yellow are a different shade from the box colours. The red box is `#f5766d`.
3. The focused panel is darker than the other panels. Its glow is above the top edge only. The change takes 250 ms.
4. Text that users read in the app says "folder", not "directory". An error stays until the user closes it. A notice goes away after 5 s. The notice "Deleting the session..." stays while a Delete runs.
5. Only a prompt box blocks Send message, Run slash command and Rename. Take control is blocked by each red box (section 9.2). An Interrupt cancels a send that waits in the queue, then sends the Esc at once.
6. Delete of a worktree session:
   1. The dialog shows the result of a check for unmerged commits and changed files. With unmerged work or a failed check, the confirm needs a second click.
   2. Before the stop of a running session, Bifrost checks the worktree again. Tracked changes stop the Delete, because `claude rm` keeps such a worktree.
   3. When `claude rm` keeps the worktree for commits on no remote, Bifrost runs `claude rm <id> --discard-unpushed <value>`. This happens only when the dialog showed a real check of the same worktree, the kept text names this session and this worktree, the value names the current HEAD, and a check after the stop shows no more commits or changes than the dialog showed.
   4. `claude rm` gets 10 minutes. Then Bifrost sends SIGTERM and waits 30 s more. It never sends SIGKILL to `claude rm`.
   5. Bifrost remembers the worktree root of a session while it runs, because a stopped session reports its start folder.
7. Take control refuses a session with no user message in its transcript, because the resume of such a session fails. After the resume, Bifrost waits 3 s to see that the session runs.
8. Bifrost forgets a session that is gone from Claude Code only after two good `--all` lists in a row without it. A good list is complete, is not empty, has each background session of the active list, and has a background entry while Bifrost knows a parked owned session. A failed read never counts.
9. The terminal icon is the thumbnail of the app bundle, then the file icon of the system.
10. The Watched tab has the id `t0`, so a tab that the user adds can never get the same id. It is the third tab. A saved Overview keeps its tabs. The filter "Only watched sessions" makes such a tab.
11. You can choose the text colour of each Overview tab from 12 colours. Red, amber and yellow are normal Overview colours, but the box red and the box yellow stay reserved shades. Each other colour has an OKLab distance of 0.10 or more from them, so the amber is darker. The project icon colours stay blue and green. A new tab cycles through the first six colours only (user decision, 2026-11-05).

## 23. Decisions on 2026-11-05 (Live details)

The user decided to replace the global hooks and the statusLine wrapper with a Claude Code mod. The poll of `claude agents --json` stays the base. The plan is `docs/plans/2026-11-05-bifrost-live-mod.md`.

1. D1: The plugin is `bifrost-live`, the marketplace is `bifrost-local`, and the scope is `user`. Bifrost refuses a `bifrost-local` marketplace that has another path.
2. D2: The source of the mod is `resources/live-mod/`. Bifrost copies four files to `~/.bifrost/mod` and adds that folder as the marketplace. At each start, Bifrost copies the files again when they differ.
3. D3: The wire kinds are `session.start`, `session.end`, `turn.start`, `ask`, `tool.done`, `permission`, `turn.complete`, `stop.failure` and `usage`. The mod sends facts, and the main process maps them (section 6.2).
4. D4: The registry drops a state event that is older than the newest applied event of the session. It compares `at`, then `seq`.
5. D5: The kinds that other hooks send give all states. The hooks `classic.PermissionRequest` and `classic.StopFailure` send `permission` and `stop.failure`. They only make a permission box earlier and repeat an error. Where they do not run, the poll gives the permission red box within 2 s.
6. D6: `answer` and `refusal` give a yellow box. `aborted` gives Idle with no box. `error` gives the red error box. A subagent turn changes nothing.
7. D7: `session.start` from the mod only ends the parked state. A reload does not clear a box.
8. D8: Usage comes from `session.start`, `session.measure`, one read 2,500 ms after each main-loop `turn.complete`, and a heartbeat each 30 s. A usage line is not activity.
9. D9: Bifrost listens on the socket only while the plugin is on. It also listens while the plugin state is unknown and the mod folder exists. Turn off stops the server at once.
10. D10: Install and Turn on remove an old hook install before the first `claude plugin` command. A failure stops the action. Remove does the old removal last, after the plugin steps and the delete of the mod folder (controller ruling). The reason: a failed removal of the old install must not leave the mod installed. Bifrost keeps `statusline-original.json` and the backups.
11. D11: The API for M5a is `live.status()`, `live.install()`, `live.enable()`, `live.disable()` and `live.uninstall()`. `enable` refuses when the plugin is not installed.
12. D12: The parser keeps `five_hour` and `seven_day` as the rate limits and drops other windows. This work adds no Usage HUD.
13. D13: A new session always gets the `--settings` statusLine override. Section 22 item 1 passed it only without the wrapper. Resume and Take control add no flags.
14. D14: This section holds the decisions of the Live details work. Section 22 keeps its text, with a note that this section changes its statusline line.
15. O1: Yes. A controller task installs the mod at user scope for a short time (Part B of the check). It saves backups and SHA-256 values first, and it runs no `/reload-plugins` in a session of the user.
16. O2: The guard `cc-plugin-sec-default` is not in the list of the user. The `classic.*` events are usable.
17. O3: Yes. With no mod, a change of `status` from `busy` or `waiting` to `idle` seen by the poll sets a yellow box (section 7, rule 11). The O3 question named both changes.
18. O4: Option a. New sessions start with `--settings '{"statusLine":{"type":"command","command":"true"}}'`. Resume and Take control add no flags. A taken-over session keeps your statusline. Spec 20 item 1 goes away (section 6.3).
19. Ask order: the mod queues the `ask` line before the tool runs. The line has a lower `seq` than `tool.done`. The mod does not wait for the send.
20. Socket server: a stop during a start wins. The server never deletes a file that is not a socket. It never deletes a socket that answers (section 11.2).
21. Live flags: Turn off and Remove end the live flag of each row directly after the server stops. The usage stays. The poll yellow box then applies at once, and the status gives 0 live sessions (section 11.2).
22. Start order: the start of Live details runs first in the serial runner of the four actions. An action that comes before the start ends waits for it (section 11.2).
23. Server error: a stop of the server also clears an old server error. The status then shows no old error after Turn off or Remove.
24. Kill signal: the six write commands get SIGTERM at the 30 s timeout, and fail 10 s later if they have not ended. The two list commands keep SIGKILL (section 11.2). A timeout gives "Claude Code didn't finish in 30 seconds."
25. App texts: a second action gives "Another change is still running. Try again in a moment." A failed list names the plugin list or the marketplace list.
26. Sends in flight: the mod drops a new line while 32 or more sends have not settled (section 6.2).
27. Usage after `/clear`: the mod sends a usage line 1 s after `session.end` with the reason `clear`. The line has the new session ID (section 6.3).
28. Cost below one cent: a cost above 0 and below 0.01 USD shows as `<$0.01`. A cost of 0 shows as `$0.00` (section 8.3).

## 24. Decisions in M5a (2026-11-06)

The controller made these decisions in M5a. The M5a ledger, `docs/m5-findings.md` and the final review give the reasons.

1. A focus in a chat window selects its session. The session shortcuts act on the selected session (section 9.3). A hold-key Open on a row opens the chat window of the row. The focus in that window then selects the row.
2. A hold-key click uses the hold key that is down at the push of the mouse button. A release of the key before the mouse button does not act on the selected row (section 9.4).
3. A menu shortcut needs Cmd. This applies to Close the focused panel and Toggle Fullscreen (section 9.4).
4. A click on a notification opens the session also when the Bifrost window was closed (section 10).
5. Panel transparency and Interface scale are selects (section 12).
6. Before the first write over a settings file of a later version, Bifrost copies the file to `settings.v<version>.backup.json` in the same folder, one time, with mode 0600. If the copy fails, Bifrost does not save the settings.
7. Bifrost forgets the hold keys that are down when the key recorder of Settings > Keys starts.
8. With the space labels, the bodies of the Stop and Delete dialogs and the text of an empty Watchlist also use the space labels (section 9.1).
9. Each checkbox of Settings > General has the name of its row as its accessible name.
10. C1: Panel transparency goes from 0% to 50% in steps of 5%. The View menu has Zoom In (Cmd+=), Zoom Out (Cmd+-) and Actual Size for the Interface scale (section 12).
11. C2: The Settings panel has the ID `settings`. The `integration` panel is gone. A saved layout with an `integration` panel loads without that panel.
12. C3: A hold key acts only when the focus is not in a chat window, a text box or a control, for example a button.
13. C4: The Bifrost shortcuts pause while the key recorder of Settings > Keys records. The app menu also gives its keys to the recorder during that time.
14. C7: Settings > Keys refuses a key only when the key adds a conflict that the keys did not have. A conflict in the settings file stays.
15. C9: The setup dialog lists the changes in the order of Install (section 11.1).

## 25. Decisions in M5b (2026-11-06)

The controller made these decisions in M5b. The M5b rulings, `docs/m5-findings.md` and the final review give the reasons.

1. R4: The high bar of the Usage HUD uses amber `#d4730a` (`usage-high`). The Service status colours are greens, teals, blues and amber `#d4730a`. They have no yellow, red or grey. Each one is at least 0.10 from the box red and the box yellow in OKLab. This replaces the colours of D21 and D30 (section 8.11). The user changed the purple and pink part on 2026-11-06: the rule of no purple and no pink covers only the Overview (section 8.10). The M5b panels keep their colours for now.
2. R6: The app bundle has no `node-pty/build` folder. So each chip loads its own node-pty prebuild (section 14.1).
3. R7: The fake `claude` of the smoke test writes the attach line to `attach.log` in the test home. The test reads that file, because WebGL draws the terminal text and the DOM has no text to read (section 15).
4. R13: A check of the app in the real home records a list of `~/.bifrost` with the size and the SHA-256 of each file (not `live.sock`), before and after the run. The smoke test does this check too, in addition to the three Claude files.
5. R18: The DMG has an ad-hoc signature only (`codesign -s -`). Bifrost uses no keychain identity, no notarisation and no upload (section 14.1).
6. A click on the PR in Show Info runs the PR lookup again. The lookup uses the cache while it is fresh. Else `gh` runs again. So the link works also after 5 minutes (section 8.6).
7. A limit whose reset time has passed shows `-` and the reset time, in the Usage HUD and in Show Info. The use of the new window is not known until the next message. This replaces the 0% of D19. A use value that is not a finite number also shows `-` (section 8.8).
8. The Service status panel shows "since <time>" after the level of a service that is not ok. The time is the start of the oldest incident at that level (section 8.11).
