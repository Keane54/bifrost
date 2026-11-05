# Bifrost M3 findings

## Task 1: the session size

Question: can Bifrost learn the terminal size of a background session after a different client resized it?

The experiment agent ran `scripts/m3/size-probe.ts` two times on 2026-11-05, at 07:58 and at 07:59 GMT. Each run took 51 to 54 s. The versions were Claude Code 2.1.318 and macOS 26.6.2. The Mac had a high load (load average 6.6 to 11.4).

Command, in the main checkout:

```bash
M0_CLAUDE=/Users/dev-user/Developer/bifrost/.m0-sandbox/cl.sh M0_OUT="$TMPDIR/bifrost-m3" \
  ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m3/size-probe.ts
```

Both runs ended with exit code 0. The raw results are in `$TMPDIR/bifrost-m3/size-probe-run1.json` (run 1) and `$TMPDIR/bifrost-m3/size-probe.json` (run 2).

Test sessions: `bifrost-test-size`, `--model haiku`, directory `.m0-sandbox`, prompt "Reply with the word READY.". Run 1 had id `2d1d3f31` and PID 5169. Run 2 had id `4d764c50` and PID 50300. Each session was `idle`/`done` 4 to 5 s after the start command ended. Each session process had the TTY `ttys005`.

Clients: A attached at 120 x 32, B at 100 x 30 and C at 80 x 24. B resized to 90 x 25, 140 x 40, 110 x 35, 100 x 30 and 120 x 32. The size of A did not change.

### Probes

| Probe | Method | Result | Delay |
|---|---|---|---|
| P1 | `ps -o tty= -p <pid>` with the `pid` of the entry. It gave `ttys005`. Then `stty -f /dev/ttys005 size`. It gave `<rows> <cols>`. | The exact cols and rows of B after each of the 10 resizes (5 in each run). A second read after the redraw and the quiet time gave the same size each time. | The first read matched each time. It ended 62 to 78 ms after the resize. The first read starts 50 ms after the resize, so the true delay is shorter. |
| P2 | `ESC[2J` in the output of A after a resize of B. | Yes, after each resize. Each redraw had one `ESC[2J` and 1255 to 2062 bytes. P2 shows that a resize occurred. It does not give the size. | The first byte came 52 to 54 ms after the resize. `ESC[2J` came 57 to 61 ms after the resize. |
| P3 | The longest run of `─` (U+2500) and the last row with text on the screen of A (120 x 32). | Correct only for a size that is not larger than the screen of A. The rule was 90, 110, 100 and 120 for those widths. The last row was 25 and 30 for those heights. For 140 x 40, P3 gave 120 and 32. For 110 x 35, the last row was 32. P3 is a guess from the screen. | Read after the quiet time, 1.5 to 3 s after the resize. |
| P4 | The keys of the session entry in `claude agents --json`. | `cwd`, `id`, `kind`, `name`, `pid`, `sessionId`, `startedAt`, `state`, `status`. No key holds a size. | Not applicable. |
| P5 | `~/.bifrost/sessions/<sessionId>/status.json`. | No status file for the two test sessions. The newest status file of a different session has no size key either. Its top-level keys are `context_window`, `cost`, `cwd`, `effort`, `exceeds_200k_tokens`, `fast_mode`, `model`, `output_style`, `prompt_cache`, `prompt_id`, `rate_limits`, `scratchpad_dir`, `session_id`, `session_name`, `thinking`, `transcript_path`, `version` and `workspace`. | Not applicable. |

P1 after each step. The two runs gave the same values.

| Step | P1 (cols x rows) |
|---|---|
| 2. Start, no client | 200 x 50 |
| 3. A attached at 120 x 32 | 120 x 32 |
| 4. B attached at 100 x 30 | 100 x 30 |
| 5. B resized to 90 x 25, 140 x 40, 110 x 35, 100 x 30, 120 x 32 | The new size of B each time |
| 6. C attached at 80 x 24 | 80 x 24 |
| 6. 1 s after C closed with SIGHUP | 120 x 32 |

### Ruling

Yes. Method: P1. Bifrost reads the size of the session TTY with `ps -o tty= -p <pid>` and `stty -f /dev/<tty> size`.

- P1 gave the exact cols and rows of B within 78 ms after each of the 10 resizes. The limit was 1000 ms.
- P1 sends no input to the session.
- P1 does not change the size. The read after the quiet time gave the same size.
- P1 needs no new library.

### Question a: does a new attach set the session size?

Yes. Each new attach immediately set the session size to the size of the new client.

- Step 3: the attach of A changed the size from 200 x 50 to 120 x 32.
- Step 4: the attach of B changed the size to 100 x 30.
- Step 6: the attach of C changed the size to 80 x 24. Client A got a full redraw with `ESC[2J` (2609 to 2695 bytes). The rule on A was then 80 and the last row was 24.

When a client closes, the size can also change. After C closed, the size went back to 120 x 32 in less than 1.5 s. A got a redraw at 120 x 32. At that time A and B both had 120 x 32. So the test does not show which remaining client set the size.

### Facts for Tasks 10 and 11

- An attach is also a resize. A hidden attach, or an attach from a chat window without focus, sets the session size. The size rule of section 8.5 must include the attach size.
- When a client closes, the session gets the size of a different client.
- P1 needs the `pid` of the entry. A new entry has no `pid` for about 2.5 s (M0).
- The test used background sessions only.

### Differences from the plan

- The script ran in the main checkout, not in an m3 worktree. The controller gave this instruction.
- The clients did not send the xterm.js replies to the session. The script locked the input of each client immediately after the attach. Thus the script sent no input. The replies that the script did not send were: A `ESC[?1;2c` and 2 focus-out events `ESC[O`, B 7 `ESC[O`, C 2 `ESC[O`. All attaches worked.
- The script checked the session with `assertTestTarget` before each resize and before each TTY read. Each check took 332 to 495 ms. Thus the script could not read each 50 ms. The check before a resize also covers the first read after it. Then the script waits 50 ms and reads. Each later read has its own check. The first read matched each time, so no later read was necessary.
- `watchEntry` waited for a maximum of 120 s, not 60 s, because of the high load.
- The script also read P1 after the quiet time of each resize. This read shows that the size stays.
- Run 1 recorded `firstOutputMs` of the clients incorrectly (null). This error had no effect on the probes. Run 2 used the corrected script. All probe values are the same in the two runs.

### Cleanup

Each run closed A and B with SIGHUP (exit code 0, signal 1). Then it ran `claude stop` and `claude rm` through `cl.sh`, each after the safety check. Both commands ended with exit code 0. After the runs, `cl.sh agents --json --all` had 9 entries and no `bifrost-test-` entry.

## Task 12: app check

Date: 2026-11-05, 12:12 to 12:33. Build: the m3c worktree at f63c0ae and later, `electron-vite dev` with remote debugging port 9333. The agent-browser CLI drove the app. The window was 1440 x 857 CSS pixels.

Test sessions: `bifrost-test-m3a` (a544a379), `bifrost-test-m3b` (cd69eb95) and `bifrost-test-m3perm` (28a9a90a, `--permission-mode manual`, "Run the shell command: touch m3-check.txt"). All three used `cl.sh --bg --model haiku`. The check typed only into m3a and m3b. It did not answer the permission prompt of m3perm.

### Summary

| # | Check | Result | Screenshots |
|---|---|---|---|
| 1 | The look | Pass, 1 defect | `t12-00-full.png`, `t12-02-press-tint.png`, `t12-03-selected-row.png` |
| 2 | The Overview | Pass, 3 defects | `t12-13-sort-desc.png`, `t12-14-column-resize.png`, `t12-15-column-drag.png`, `t12-16-second-overview.png` |
| 3 | The row icon | Partial: red box pass, yellow box not tested | `t12-12-row-icons.png`, `t12-11-lime-vs-yellow.png`, `t12-10-no-yellow-box.png` |
| 4 | Menu, Selected Item, actions | Pass | `t12-04-context-menu.png`, `t12-05-disabled-tooltip.png`, `t12-06-priority-submenu.png`, `t12-07-open-project.png`, `t12-24-menu-close-window.png` |
| 5 | Chat windows | Pass after an environment repair | `t12-08-chat-open.png`, `t12-09-chat-typed.png`, `t12-18-chat-stack.png`, `t12-19-second-client.png`, `t12-22-agent-view.png`, `t12-23-after-agent-view.png`, `t12-25-focused-resize.png`, `t12-26-working.png` |
| 6 | Snap on release | Pass | `t12-17-stack-drop.png`, `t12-20-snap-corner-marks.png`, `t12-33-snap-shared-edge.png` |
| 7 | Overview Settings | Pass, 1 defect | `t12-28-overview-settings.png`, `t12-29-settings-columns.png`, `t12-30-settings-drag.png`, `t12-31-settings-filters.png`, `t12-32-settings-reset.png` |

The full screenshot for the user is `t12-00-full.png`.

### Defects

| ID | Check | Defect |
|---|---|---|
| D1 | 1 | The active Overview tab has text and an underline in the colour of the tab (for example `rgb(124, 196, 214)` for All). Spec 8.10 gives white text and a white underline. The active chat tab in a stack is white. |
| D2 | 2 | The default Project width (160 px) cuts the path "Developer/claude-statusline" (202 px). The cut text touches the next column. There is no gap and no ellipsis. |
| D3 | 2 | One drag on the Project resize handle moved the column after Last activity. The width also changed (160 to 169 px). The pointer moved in steps of 9 to 15 px. A later drag on a handle in steps of 2 to 20 px resized the column correctly (24 to 218 px). |
| D4 | 2, 7 | After D3, a resize of Name (184 to 207 px) changed the Project width to 24 px. "Reset to default" restored the columns, the sort and the filters, but not the widths. Name stayed at 207 px and Project at 24 px. |
| D5 | 3 | Last activity does not change after a turn. The poll showed Working for m3b, but Last activity stayed at the start time ("12 min"). Possibly Last activity uses only hook events (see E2). Spec 8.3 says "from any source". |
| D6 | 4 | The Selected Item panel opens at 420 x 144 px. This size cuts the Model row and all items below it. The panel does not scroll. |

### Environment findings (not defects of the app)

- E1: The first chat open failed with "[open failed: posix_spawnp failed.]". `node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper` in the worktree had mode 644. The install of 12:08 did not do step 3 of `scripts/postinstall.ts`. I did only that step (`chmod 755`). After that, all chat windows opened. Check the install of the worktree.
- E2: `~/.claude/settings.json` has no Bifrost hooks and no Bifrost statusLine wrapper. The claude-statusline install replaced them. Thus no `Stop` event came, and no yellow box showed. For the same reason, the chat window shows the statusline row of the user (spec 8.5 says no statusline row).
- E3: The AppleScript query for the path of the Finder window timed out (error -1712). A permission prompt possibly showed on the screen.

### 1. The look

Method: computed styles through `eval`, a held mouse button for the press tint, and screenshots.

- Font: all 50 visible text elements use "Geist Mono".
- Corners: 0 elements have a border radius.
- Panel: the background is `rgba(16, 16, 16, 0.85)` with `blur(12px)`. The panel opacity is 1, so the text is solid.
- Focused panel: the top border is 1 px `rgb(143, 220, 236)`, and the title bar has a gradient from the accent glow. Other panels have the accent at 35% and no glow.
- Press tint: a held row has the accent at 12%. Tabs and menu items have the same `active:bg-accent/12` class.
- Selected row: the accent at 15%. It differs from a neutral row.
- Result: pass. See D1 for the active tab.

### 2. The Overview

Method: clicks and pointer drags on the header, and DOM reads.

- The 5 tabs have 5 text colours. "+" adds a tab.
- The default columns are Kind, Name, State, Project and Last activity.
- A click on State gave "State▲" (Needs you, Working, Idle). A second click gave "State▼" (Idle, Working, Needs you).
- A drag on a header moved Last activity before State.
- The side bar button "New Overview" opened "Overview 2 (Default)". Its tab Working showed 1 row, and its sort was Name▲. Overview 1 stayed on All with its own sort.
- Result: pass, with D2, D3 and D4.

### 3. The row icon

Method: DOM reads of the icon cell, a select of the m3perm row, and a temporary DOM sample for the colours.

- Owned rows show a hexagon in project colour 4 (`#4ade80`). External rows show a terminal glyph: claude-statusline in colour 2 (`#60a5fa`), herald in colour 7 (`#38bdf8`). The two blues are near. Spec 8.3 asks for the icon of the terminal app for an external row. The row shows a general terminal glyph.
- Red box: m3perm had 4 corner brackets in `#e0473e` with the `box-flash` animation (1 s). A select stopped the animation. The box stayed.
- Yellow box: not tested. See E2.
- Lime: no live row used colour 8. A temporary sample (`t12-11-lime-vs-yellow.png`) shows lime `#a3d63a` with yellow brackets `#e2b93b`. The two are different, but near at 12 px. The user must judge.
- Result: partial.

### 4. Menu, Selected Item and actions

Method: a real right-click on test rows, hover, and clicks on menu items.

- The order is the order of spec 9.5. "Close window" shows only when the chat window is open. Take control and Resume do not show for a live owned row.
- Disabled items have opacity 0.4. The tooltip gives the reason, for example "Send message / Comes in M4". A disabled item also gets the hover highlight.
- Set priority 2 on m3b: the Selected Item panel and the chat title show "2" in the priority colour.
- Copy session ID on m3b: `pbpaste` gave `cd69eb95-18ab-4570-9732-66dbe70e6479`. This is the sessionId of m3b.
- Open project: the submenu showed Finder, VS Code, Zed and Warp. All four are installed. Finder became the front app. See E3 for the path.
- Selected Item: it shows the name, the state, the priority, 7 icon buttons, the project and the branch. See D6.
- Result: pass.

### 5. Chat windows

Method: double-click on test rows, typing through the xterm text area, `ps`, `stty -f /dev/<tty> size`, and the lib.ts script `TestPty.attach` for a second client.

- A double-click opened the m3a chat. One `claude attach a544a379` process started. The TUI showed. See E1.
- "Reply with OK." went to m3a and Claude replied "OK.".
- Renderer: the visible terminal has a WebGL2 canvas and no DOM rows. In a stack of 2 chats, only 1 WebGL canvas existed. The back tab released its context.
- Close: "Close window" ended the attach process. m3a stayed in the list as idle.
- Title: the kind icon, a square state dot, the name and the priority. The dot was grey for Idle and white for Working (m3b turn).
- Stack: a drop of the m3b title on the m3a title made one panel with 2 tabs. The active tab text is white. The other tab is grey. The count of attach processes stayed at 2.
- Size with focus: a resize of the focused m3b chat changed the session from 30 x 93 to 26 x 80.
- Size from another client: the second client set 30 x 100. The unfocused m3a chat zoomed (750 px terminal at scale 0.957 in 718 px) and sent no resize. At 90 x 26 the terminal was 675 x 390 px. After the second client closed, the session went back to 30 x 93.
- Agent view: one left arrow on the empty prompt of m3a. Within 2 s, attach process 80179 ended and 48839 started. The TUI showed again. I pressed no other key.
- Result: pass after E1.

### 6. Snap on release

Method: pointer drags of the Selected Item title bar in steps, with reads during the drag.

- Corner: during the drag the panel was at (1016, 4) and did not jump. Two marks showed: a right chevron at the right window edge and an up chevron at the top window edge. On release the panel went to (1020, 0).
- Shared edge: during the drag the panel was at x 769. A left chevron showed at x 760, on the right edge of the Overview. On release the panel went to x 765.
- The stack drag showed a mark at the top edge of the target panel. On release the panel moved 3 px to y 189.
- Result: pass.

### 7. Overview Settings

Method: the vertical dots button, then clicks and a drag in the panel.

- The menu has "Overview settings…", Lock and the tab set name field.
- The panel has a Tab selector and the tabs Columns and Filters. Kind is checked and disabled.
- Priority on: the column showed in the Overview.
- State off while State was the sort column: the sort went to Name▲.
- A drag of Project to the top of the list put Project first after Kind in the Overview.
- Filters: Working, Needs you, Error, Idle, Parked, Owned, External and "Only rows with a box". External off left 3 rows. There is no watched-session filter yet (Watchlist is M4).
- "Reset to default" restored the default columns, the sort Name▲ and the filters. See D4 for the widths.
- Result: pass, with D4.

### Checks for the user

- The look of the colours in `t12-00-full.png`, and the active tab colour (D1).
- Lime against the yellow box (`t12-11-lime-vs-yellow.png`).
- The two blues of external projects.
- The yellow box with the Bifrost hooks installed (E2).
- Open project with VS Code, Zed and Warp.

### Cleanup

- I closed the chat windows. `ps` showed 0 `claude attach` processes.
- `cl.sh stop` and `cl.sh rm` for a544a379, cd69eb95 and 28a9a90a ended with "stopped" and "removed". After that, `cl.sh agents --json --all` had no `bifrost-test-` entry.
- `m3-check.txt` does not exist in `.m0-sandbox`.
- The app quit through AppleScript. No Electron process of the worktree stayed. `~/.bifrost/active` did not exist after the quit.
- The m3b priority and the Overview layout of this dev instance changed during the check. The Overview columns are at the default, but Name is 207 px and Project is 218 px.
