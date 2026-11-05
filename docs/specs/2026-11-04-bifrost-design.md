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
| Event directory | The directory where the hook script writes one file for each hook event. |
| Status file | The file where the statusline wrapper writes the latest statusLine JSON of a session. |

## 3. Summary of decisions

| Topic | Decision |
|---|---|
| Platform | Electron, React, TypeScript, xterm.js and node-pty. |
| Operating system | macOS only in v1. A "Mod" key layer keeps a Windows port possible. |
| Window model | One app window. Internal panels float inside it. |
| Session hosting | Bifrost starts sessions with `claude --bg`. Each chat window runs `claude attach <id>`. |
| External sessions | Status only. The "Take control" action moves them to the supervisor. |
| Data | Global hooks, a statusline wrapper and `claude agents --json`. |
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
- An entry can have `waitingFor`, for example "permission prompt". It comes with the `waiting` status.
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
- The supervisor did not stop an idle, unattached session in 75 minutes.
- A restart of the computer stops all background sessions.
- Hooks in `~/.claude/settings.json` apply to all local sessions.
- The statusLine command gets the session JSON on stdin. The JSON includes the model, the cost, the context window and the rate limits.
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
|                    <-- watch: ~/.bifrost/events/                       |
|                    <-- watch: ~/.bifrost/sessions/*/status.json        |
|   PTY manager      --> node-pty: claude attach <id>                    |
|   Action runner    --> claude --bg / stop / rm, signals, open -a       |
|   Integration      --> ~/.claude/settings.json (install, uninstall)    |
+------------------------------------------------------------------------+
         ^ hook events                         ^ statusLine JSON
  ~/.bifrost/bin/bifrost-hook        ~/.bifrost/bin/bifrost-statusline
         ^                                     ^
         +--------- Claude Code sessions ------+
```

### 5.1 Main process

| Part | Function |
|---|---|
| Session registry | Merges all data sources into one list of sessions. Runs the state machine. |
| PTY manager | Starts one `claude attach <id>` process for each open chat window. Also starts the hidden attach for the send box. |
| Action runner | Runs Claude Code commands, sends signals and opens other apps. |
| Integration | Installs, repairs and removes the hooks and the statusline wrapper. |
| Store | Keeps the settings, layouts, priorities and panel positions on disk. |

### 5.2 Renderer

The renderer is one React app. React keeps the state. M2 decided that React state is enough. A reducer keeps the window manager state. Zustand is not used. The main process sends updates of the registry to the renderer. It sends a maximum of 4 updates each second.

Context isolation is on. The preload script supplies a typed API. The renderer has no direct access to Node.

### 5.3 Files and directories

| Path | Content |
|---|---|
| `~/.bifrost/bin/bifrost-hook` | The hook script. |
| `~/.bifrost/bin/bifrost-statusline` | The statusline wrapper. |
| `~/.bifrost/events/` | The event directory. Bifrost deletes each file after it reads it. |
| `~/.bifrost/sessions/<session-id>/status.json` | The status file of the session. |
| `~/.bifrost/statusline-original.json` | Your statusLine setting from before the install. |
| `~/.bifrost/active` | Exists while Bifrost runs. The scripts do their work only when it exists. |
| `~/.bifrost/sessions/<session-id>/quiet` | Bifrost makes this file for each owned session. The wrapper then does not run your statusLine command. |
| `~/.bifrost/backups/` | Copies of `settings.json` from before each change. |
| `~/Library/Application Support/Bifrost/` | Settings, layouts, priorities and panel positions. |

The scripts use `~/.bifrost/` because that path has no spaces. So the commands in `settings.json` stay simple.

## 6. Data sources

### 6.1 Session list

Bifrost runs `claude agents --json` every 2 seconds. This gives the active sessions and their `status`: `busy`, `idle` or `waiting`.

Bifrost keeps an entry that has no `pid`. Bifrost keys all entries by `sessionId`.

Bifrost uses `status` for the state machine. It does not use `state`.

Bifrost runs `claude agents --json --all` every 30 seconds. This gives the parked sessions. Bifrost keeps the name of each session in its own registry, because `--all` can lose the name.

The `kind` field shows the type of the session: owned or external. Bifrost also keeps a list of the sessions that it started. If one of these sessions is not active, Bifrost shows it as parked.

### 6.2 Hook events

The installer adds one hook entry for each row below. All entries run the same script, `~/.bifrost/bin/bifrost-hook`.

| Event | Matcher | Result |
|---|---|---|
| `SessionStart` | All | Adds the session. Clears the parked state. |
| `SessionEnd` | All | Marks the end of the session. |
| `UserPromptSubmit` | All | Sets the state to Working. Clears the box. |
| `PreToolUse` | `AskUserQuestion` | Sets a red box. Claude asks you a question. |
| `PermissionRequest` | All | Sets a red box. |
| `PostToolUse` | All | Sets the state to Working. Clears a red box after you answer a prompt. |
| `Notification` | `permission_prompt` | Sets a red box. |
| `Notification` | `idle_prompt` | Keeps the yellow box. |
| `Stop` | All | Sets a yellow box. Keeps `last_assistant_message` for the preview. |
| `StopFailure` | All | Sets a red box and the state Error. |

Rules for the hook script:

- The script is POSIX `sh`. It does not need `jq`, Node or Python.
- If the file `~/.bifrost/active` does not exist, the script exits at once. Bifrost makes this file at start and deletes it when it quits. So no event files collect while Bifrost is closed.
- The script writes its stdin with one `cat` to a new file in the event directory. The file name is `<parent PID>-<PID>.json`. Bifrost sorts the files by their change time.
- The cost of the script does not grow with the size of its input. A tool event can carry 500 KB.
- Bifrost does not use a partial file. A file that is not valid JSON and is younger than 5 seconds stays for the next read. Bifrost deletes an older one.
- At start, Bifrost deletes event files older than 60 seconds and does not read them.
- The script never writes to stdout. Claude Code adds hook stdout to the context for some events.
- The script makes its files with mode 0600 (`umask 077`), because the files hold tool input and output.
- The script always exits with code 0.
- The script must finish in less than 50 ms.
- The hooks are not `async`. An async hook can write its file after the file of a later event, and the box rules need the correct order.

M1 measures the cost of the `PostToolUse` hook. If the cost is too high, Bifrost uses the busy status from `claude agents --json`.

### 6.3 Statusline wrapper

Claude Code sends the live session data only to the statusLine command. The wrapper copies this data for Bifrost.

The wrapper does these steps:

1. Read all of stdin.
2. Find the `session_id` with a strict UUID pattern.
3. Write the JSON to a temporary file.
4. Move the temporary file to the status file.
5. If the session directory has the file `quiet`, stop. Bifrost writes this file for each owned session.
6. Run your original statusLine command with the same stdin.
7. Send the output of your command to stdout without changes.

If you had no statusLine command, the wrapper writes nothing to stdout. The installer keeps your `refreshInterval` and `padding` values.

The status file supplies these values: model, context %, cost, session name and rate limits.

Rules for the wrapper:

- Claude Code runs the wrapper for each session again and again, for example each second. So the wrapper starts few programs: `cat` one time to read stdin and `mv` one time to write the status file. It starts `mkdir` only for a new session.
- If the file `~/.bifrost/active` does not exist, the wrapper only runs your original command. It does steps 1 to 5 only while Bifrost runs.
- The wrapper makes its files with mode 0600 (`umask 077`).
- Chat windows in Bifrost show no statusline row. The Overview, the Selected Item panel and the global panels show the data (section 20).
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
| Working | None | `status` is `busy`, or a `UserPromptSubmit` or `PostToolUse` event. |
| Needs you | Yellow | A `Stop` event. Claude finished its turn. |
| Needs you | Red | `status` is `waiting` with a `waitingFor` value (also without a hook), a permission prompt, an `AskUserQuestion` call, or an old yellow box (rule 4). |
| Error | Red | A `StopFailure` event. |
| Idle | None | `status` is `idle`, and no event set a box. An example is a new session before the first prompt. |
| Parked | None | The session has no process. The row is grey. The cause is `claude stop`, a restart of the computer, or a process that ends. |

Box rules:

1. A new box flashes.
2. The flash stops when you select the row or focus the chat window. The box stays.
3. The box clears when the session starts to work again.
4. A yellow box changes to red after 10 minutes. The timer starts with the yellow box.
5. The "Escalation time" setting changes the time. The value 0 stops the escalation.
6. Bifrost does not move a row because of a box. Only the sort column of the tab sets the row order.
7. External sessions also get boxes, because the hooks are global.
8. Parked sessions never get a box.
9. A red box also clears when `status` is no longer `waiting`. Another client can answer a prompt. Examples are the agent view, a terminal and a phone.
10. A `status` sample clears a box only after a sample confirmed that box. `idle` confirms a yellow box and an error box. `waiting` confirms a red prompt box. The reason: Claude Code can report `busy` while the Stop hooks run, and an interactive session can report `idle` or `busy` at a prompt. Hook events clear a box at all times.

## 8. User interface

### 8.1 Window model

Bifrost has one app window. All panels float inside it.

Panel functions:

- Drag the title bar to move the panel.
- Drag an edge or a corner to resize the panel.
- The panel snaps to the window edges and to other panels at 8 pixels or less.
- Drop a panel on the title bar of a different panel to stack the two as tabs.
- Drag a tab out of a stack to make a separate panel.
- Minimise a panel to the side bar.
- Lock a panel to prevent moves and resizes.
- Set the opacity of a panel from 30% to 100%.

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
| Event log | All hook events, with their times. |
| Usage HUD | The 5-hour and 7-day rate limits. |
| Service status | The status of Claude, GitHub and Sentry. |

### 8.3 Overview

Visual layout:

The Overview uses the layout of the EVE Overview, with Bifrost colours, icons and fonts. The reference image is `docs/reference/overview-reference.png`.

- The title bar shows "Overview" and the name of the tab set. A menu button and a minimise button are on the right.
- A row of tabs is below the title bar. Each tab has its own text colour.
- A line shows the active tab. A "+" button adds a tab.
- The column headers are small and grey. The sort column shows ▲ or ▼.
- The rows are dense and use a narrow font. Text that is too long is cut off. It does not wrap.
- The first column shows a small icon. The yellow box and the red box go around this icon.
- A row can have a background highlight colour.
- The panel background is translucent.

Columns:

| Column | Source |
|---|---|
| Kind icon | `kind`. External rows show the icon of their terminal app. |
| Name | `name`, or `session_name` from the status file. |
| Priority | Bifrost. Values 1 to 5, or none. Each value has a colour. |
| State | The state machine (section 7). |
| Project | `cwd`. The column shows the last two parts of the path. |
| Branch | Git (section 6.4). |
| Model | `model.display_name` from the status file. |
| Context % | `context_window.used_percentage` from the status file. |
| Cost | `cost.total_cost_usd` from the status file. |
| Last activity | The time of the latest event from any source. |

Default tabs:

| Tab | Rows |
|---|---|
| All | All sessions except parked sessions. |
| Needs you | Rows with a yellow or red box. |
| Working | Rows with the state Working. |
| Idle | Rows with the state Idle. |
| Parked | Parked sessions. |

Tab rules:

- You can add, remove, rename and move tabs.
- Each tab has its own filter, columns and sort column.
- Click a column header to sort by that column. Click it again to reverse the sort.

Mouse:

| Input | Result |
|---|---|
| Left-click | Selects the session. |
| Double-click | Opens the chat window. |
| Right-click | Opens the right-click menu. |
| Hold a key and left-click | Does the action of that key on the row (section 9.4). |

### 8.4 Selected Item

The panel shows these items, from top to bottom:

1. The name, the state and the priority.
2. A row of icon buttons: Open, Send message, Run slash command, Interrupt, Show Info, Open in terminal and Stop session.
3. The project, the branch and the model.
4. A context bar and the cost.
5. The first 3 lines of the last Claude reply. The `Stop` hook supplies this text.
6. The send box.

Send box rules:

- Enter sends the text. Shift+Enter adds a new line.
- Text that starts with `/` runs as a slash command.
- If the chat window is open, Bifrost writes into the PTY of that window.
- If the chat window is not open, Bifrost types through a hidden attach.
- Bifrost sends text as a bracketed paste (`ESC[200~` text `ESC[201~`), then CR.
- A hidden attach is ready when its output is quiet for 1.5 seconds.
- Bifrost never sends CR to an empty prompt.
- One attach PTY serves each session.
- A hidden attach uses the size of the last chat window of that session. All clients of one session share one size.
- If the session has a red box, Bifrost blocks the send. Typed text can answer a prompt by accident.
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
- The chat window shows no statusline row (section 6.3).
- Visible chat windows use the WebGL renderer.
- A chat window in a back tab, or a minimised chat window, releases its WebGL context.

Size rule (the user approved this on 2026-11-04; M3 builds it):

- A session has one terminal size for all its clients. The last resize from any client sets it (M0 question 3).
- Only the chat window that has focus sends a resize to the session.
- A chat window with a different size from the session zooms the terminal to fit. The layout stays correct.
- A resize in a terminal app, for example Warp, also sets the size. Bifrost then zooms its chat window to that size.
- M3 starts with a test: can Bifrost learn the size that a different client set?

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

The Event log shows all hook events with the time, the session and the event name. You can filter it by session. It keeps the last 5,000 events in memory. It does not keep events on disk.

### 8.8 Usage HUD

The Usage HUD shows two bars: the 5-hour limit and the 7-day limit. Each bar shows the use and the reset time. The data comes from the newest status file.

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
- The worktree option needs a test in a trusted repository (M4).

### 8.10 Theme

- The theme is dark. The panels are translucent, with a background blur.
- Bifrost uses its own colours, icons and fonts. It does not copy EVE assets.
- One file holds all colour tokens.
- Yellow, red and grey have fixed meanings: yellow box, red box and parked session.
- The terminal font is a setting.

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
| Row flash | On | A new yellow box or red box. |
| macOS notification | On | A new box when Bifrost is not in focus. |
| Sound | On | A new red box. |

Click a notification to select the session and open its chat window.

## 11. First-run setup and integration

### 11.1 Setup dialog

At the first start, Bifrost shows the setup dialog. The dialog shows each change before Bifrost makes it:

1. The hook entries that Bifrost adds to `~/.claude/settings.json`.
2. The new statusLine command, and your current statusLine command that the wrapper runs.
3. The backup path.

You select "Install" or "Skip".

### 11.2 Install

Bifrost does these steps:

1. Read `~/.claude/settings.json`. If the file is not valid JSON, stop and show an error.
2. Copy the file to `~/.bifrost/backups/settings-<time>.json`.
3. Add the hook entries. Keep all your current hooks.
4. Save your statusLine setting to `~/.bifrost/statusline-original.json`.
5. Set the statusLine command to the wrapper. Keep `refreshInterval` and `padding`.
6. Write the new file to a temporary name.
7. Move the temporary file to `~/.claude/settings.json`.

### 11.3 Uninstall

Bifrost does these steps:

1. Make a new backup.
2. Remove each hook entry that runs `~/.bifrost/bin/bifrost-hook`.
3. Restore your statusLine setting from `~/.bifrost/statusline-original.json`.

### 11.4 Skip

If you select "Skip", Bifrost shows only the data from `claude agents --json`. This data is the name, the project and the `status`. Bifrost then shows no boxes, cost or context %. Settings > Integration can run the install later.

### 11.5 Checks at start

- Bifrost checks the integration at each start. If Bifrost cannot find an entry, Settings shows a warning and a Repair button.
- Bifrost reads `claude --version` at each start. Below the minimum version, Bifrost shows a warning. The minimum version is 2.1.281.

## 12. Settings

| Setting | Default |
|---|---|
| Labels | Plain |
| Terminal app | The first installed app from this list: Warp, Ghostty, iTerm2, Terminal. |
| Default app for "Open project" | VS Code if installed, or else Finder. |
| Escalation time | 10 minutes. The value 0 stops the escalation. |
| Row flash | On |
| macOS notification | On |
| Sound for a red box | On |
| Start at login | Off |
| Poll interval | 2 seconds |
| Snap distance | 8 pixels |
| Slash commands | `/compact`, `/clear`, `/context` |
| Terminal font | SF Mono, 13 pt |
| Display mode | Window |
| Keys | Section 9.4 |
| Integration | Install, Repair, Uninstall |

## 13. Performance targets

- 20 sessions in the registry.
- 8 visible chat windows at the same time, with smooth output.
- A maximum of 12 WebGL contexts.
- A maximum of 4 registry updates to the renderer each second.
- Less than 800 MB of memory with 8 open chat windows.
- One `claude agents --json` process at a time. A new poll starts only after the last poll ends.

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
| Base UI | The right-click menu with submenus, dialogs and tooltips | M3 |
| TanStack Table | Overview columns, sort, column order and resize for each tab | M3 |
| TanStack Hotkeys (beta) | Key map, hold-key-and-click, key editor in Settings | M3 to M5 |
| lucide-react | Icons | M3 |
| Zustand | Not used. A reducer keeps the window manager state (M2). | M2 |
| Zod | Not used. The hand-written checks stay small (M1). | M1 |
| lefthook and commitlint | Commit message checks. Added in M1. | M1 |
| Playwright for Electron | Smoke test | M5 |

### 14.1 Now

- The tools are pnpm, electron-vite, TypeScript 5.9, React, Biome, `@xterm/xterm`, `node-pty` and electron-builder.
- Biome replaces ESLint and Prettier.
- M1 keeps TypeScript 5.9. TypeScript 7.0.2 failed `pnpm typecheck`: `tsconfig.web.json` uses `baseUrl`, and TypeScript 7 removed it (TS5102 and TS5090). To try TypeScript 7 again, remove `baseUrl` and set the `paths` value to `./src/renderer/src/*`.
- `package.json` has `"engines": { "node": ">=24" }`.
- Scripts are ESM TypeScript files. Node runs them directly.
- Scripts that load `node-pty` run with `ELECTRON_RUN_AS_NODE=1 electron <file>.ts`.
- Bifrost has no CommonJS files.
- `pnpm dev` starts Bifrost from the repository.
- `pnpm dist` makes a universal DMG for Apple Silicon and Intel.
- The build uses an ad-hoc signature, because Apple Silicon does not run code without a signature.
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
| Script | Vitest and `sh` | The hook script and the wrapper, with sample JSON. |
| Smoke | Playwright for Electron | Bifrost starts with a fake `claude` command on the PATH and shows the sample sessions. |
| Manual | Checklist | The M0 questions, Take control and the DMG. |

## 16. Milestones

| Milestone | Content | Exit criteria |
|---|---|---|
| M0 - Test | The questions in section 17. | All answers are known. If an answer blocks the design, stop and ask the user. |
| M1 - Data | Hook script, wrapper, install, uninstall, registry, state machine. | The unit tests pass. A debug view shows real sessions with boxes. |
| M2 - Window manager | Panels, drag, resize, snap, stacks, position memory, layouts, display modes. | All panel functions in section 8.1 work. |
| M3 - Core panels | Overview (with the visual layout of section 8.3), Selected Item, right-click menu, chat windows. | You can select, open and use sessions. |
| M4 - Actions | Send box, slash commands, stop, delete, new session, Take control, parked sessions, Resume all. | All actions in section 9.1 work. |
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

1. The escalation timer starts with the yellow box. Your selection stops only the flash, not the timer.
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
2. Data that is the same for all sessions goes in separate panels: the Usage HUD and the Service status panel (sections 8.8 and 8.11).
3. Data for one session goes in the Overview and the Selected Item panel (sections 8.3 and 8.4).
