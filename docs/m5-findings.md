# Bifrost M5 findings

## M5a checks

A check agent ran Task 9 on 2026-11-06 from 03:16 to 03:36 GMT. The code was branch `m5a` at `ecacfff`. The versions were Claude Code 2.1.318, Electron 44.7.2, Node 26.8.1 and macOS 26.6.2. The screen was not locked, and the dev app was the front app.

The check stopped in Step 3. The SHA-256 of `~/.claude/plugins/known_marketplaces.json` changed during Step 1. The safety rules say: stop the check and record what ran just before. See "SHA-256 values" and "Why the check stopped". Steps 1 and 2 and the real-home part of Step 3 ran. The test-home part of Step 3 and Steps 4 to 9 did not run.

A second run on 2026-11-06 from 04:01 to 04:34 GMT ran Steps 3 to 10 after the fix wave. See "Second run" at the end of this section.

### Method

- The agent started two test sessions in `.m0-sandbox` with `cl.sh --bg --model haiku --name bifrost-test-m5a "Reply with the word READY."` and the same for `bifrost-test-m5b` (03:17:35). The IDs are `41d718e9` (m5a) and `cddae5de` (m5b).
- The agent started the dev app in the worktree with its own userData in the scratch folder: `pnpm exec electron-vite dev -- --user-data-dir=<scratch>/m5a-check/userdata --remote-debugging-port=9333`. `BIFROST_TEST_HOME` was not set. This app uses the real home.
- The agent drove the page with `agent-browser` over port 9333 (`snapshot -i`, `click`, `select`, `fill`, `press`, `hover`, `screenshot`). It also used a small CDP script in the scratch folder for key events, mouse events, drags and `eval` reads of the DOM and of `window.bifrost`.
- A recorder in the page subscribed to `window.bifrost.registry.onUpdate`. It kept each change of the status or the box of a `bifrost-test-` row, with the page clock.
- A ps sampler read `ps` each 0.1 s and printed each new `claude agents --json` process with its parent PID.
- Before each action on a row, the agent read the name of the row, of the Selected Item panel or of the dialog, and checked the `bifrost-test-` prefix. Each Overview and Watchlist action of the check was on `bifrost-test-m5a` or `bifrost-test-m5b`.
- The agent quit the dev app with SIGTERM to its own Electron main PID (25936, then 66804). It found the PID from the command line with the scratch userData path and no `--type=`. It did not use `osascript`.
- Before Step 1 (03:16:21), the agent recorded the SHA-256 of `~/.claude/settings.json`, `~/.claude/plugins/installed_plugins.json` and `~/.claude/plugins/known_marketplaces.json`. It also kept a copy of each file in the scratch folder for a compare.

Changes to the method:

- The first send of Step 1 (03:22:04) failed with `posix_spawnp failed.` in the Selected Item panel. The app log has `Error occurred in handler for 'input:send': Error: posix_spawnp failed.` from `node-pty`. The cause is the worktree install: `node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper` had mode `644`. The main checkout has `755`. An install with `--ignore-scripts` does not run the node-pty script that sets the mode. The agent set the mode to `755` (03:22:54). This file is in `node_modules` and git ignores it. No source file changed. After this, each send worked.
- With a poll interval of 5 s, a short reply can start and end between two polls. So the agent sent `Write the numbers from 1 to 400, one number on each line.` to `bifrost-test-m5a` for the yellow box of the escalation check.
- After Step 1, the agent kept "macOS notification" and "Sound for a red box" off. The check has a limit of 3 notifications and 1 red-box sound, and Steps 2 to 8 can make new boxes. Step 9 was to turn them on again. Step 9 did not run.
- In Step 2, "Track" in the row menu is a submenu of colours. The agent used Green for m5a and Light blue for m5b.
- At the end of Step 2, the agent selected Plain with `window.bifrost.settings.set({ labels: 'plain' })` in the page, not with a click.
- The test home is `$TMPDIR/bifrost-m5a-home`, as the brief says, and not a folder in the scratch folder. A scratch path gives a socket path of 152 bytes. The limit is 100 bytes (D12). The test-home path gives 84 bytes.
- `HOME=<test home> cl.sh plugin list --json` gave `zsh:1: command not found: claude`. `cl.sh` runs a login shell, and that shell reads the dotfiles of the test home. The agent added `<test home>/.zshenv` with `export PATH=/Users/dev-user/.local/bin:$PATH`. Then `plugin list --json` and `plugin marketplace list --json` gave `[]` in the test home (03:31). The test-home dev app did not start.

### Results

| Step | Method | Result | Screenshot |
|---|---|---|---|
| 1. Settings | Open Settings with the side bar button, close it, open it with Cmd+, (CDP). Change each General row. Restart (SIGTERM at 03:26:08, same command). Sample `ps` for 31 s at poll 5 s. Yellow box on m5a at escalation 1 minute. Open the chat window of m5a at Menlo 15. Drag the chat frame 4 px from the left edge of the Overview frame. Put the settings back. | Pass. The side bar button and Cmd+, each open the `settings` panel. The tabs are General, Slash commands, Keys and Live details. Each changed value stays after the restart, in the page and in `settings.json` of the scratch userData. See "Step 1 details". Start at login is off and disabled in the dev app, with the hint `Only works in the installed app.` (For the user.) | `m5-findings/s1-settings-general.png`, `m5-findings/s1-settings-changed.png`, `m5-findings/s1-after-restart.png`, `m5-findings/s1-escalated-red.png`, `m5-findings/s1-chat-menlo-15.png`, `m5-findings/s1-chat-after-font-reset.png` |
| 2. Labels | Select Space. Right-click m5a in the Overview and in the Watchlist. Hover each Selected Item button and each side bar button. Open Stop (m5b busy) and Delete (m5b), click Cancel. Open Rename (m5a) and New session, press Esc. Select Plain again. | Pass. Menus, tooltips, dialog titles and dialog buttons show the space labels of spec 9.1. Panel titles stay plain. Cancel and Esc closed each dialog, and nothing ran. See "Step 2 details" and observations 1 and 2. | `m5-findings/s2-overview-menu-space.png`, `m5-findings/s2-watchlist-menu-space.png`, `m5-findings/s2-stop-confirm-space.png`, `m5-findings/s2-delete-confirm-space.png`, `m5-findings/s2-rename-space.png`, `m5-findings/s2-new-session-space.png`, `m5-findings/s2-panel-titles-space.png` |
| 3. Setup and Live details | Real home: read `live.status()` and the dialog at the first start. Press Esc. Click Skip. Test home: make `$H/.claude/settings.json` with the old hook. | Part only. Real home: pass. The status was `plugin: 'not-installed'`, `oldInstall: false`, `listening: false`, `versionOk: true`, `claudeVersion: '2.1.318'`. The setup dialog (`alertdialog`, "Set up Bifrost") showed two steps, because no old install exists. Esc did not close it. Skip closed it and set `setupDone: true`. No dialog showed after the restart. `~/.bifrost` did not change. Test home: not run. The check stopped before the test-home app started. | `m5-findings/s3-real-home-setup.png` |
| 4. Keys outside a chat window | - | Not run. The check stopped. | - |
| 5. Keys in a chat window | - | Not run. The check stopped. | - |
| 6. Hold-key-and-click | - | Not run. The check stopped. Both test rows are on the Watchlist from Step 2. | - |
| 7. Menu keys | - | Not run. The check stopped. | - |
| 8. Key editor | - | Not run. The check stopped. | - |
| 9. Alerts | - | Not run. The check stopped. No notification and no sound played in the check. | - |
| 10. Clean up | Close the chat window. SIGTERM to the dev app. Stop and remove the test sessions. Remove the test home and the scratch userData. Record the SHA-256 again. | Part only. The chat window closed, and the `claude attach 41d718e9` process ended. The dev app quit at 03:34:17, with no process left. The test home and the scratch userData are gone. `.m0-sandbox` has no new file. The permission check refused the stop and rm of the two test sessions. They are idle and still exist (For the user). | - |

### Step 1 details

| Row | Change | Evidence |
|---|---|---|
| Labels | Plain to Space | `labels: 'space'`. Step 2 checks the effect. |
| Terminal app | Automatic to Terminal | The list had Warp and Terminal. `terminalApp: 'terminal'`. |
| Default app for "Open project" | Automatic to Finder | The list had Finder, VS Code, Zed and Warp. `projectApp: 'finder'`. |
| Escalation time | 10 to 1 | The yellow box of m5a had `boxSince` 03:23:15.033. The box became red with `boxReason: 'escalated'` at 03:24:15.741, 60.7 s later. |
| Row flash | On to Off | While the row had `flashing: true`, the page had 0 elements with `animate-box-flash`. |
| macOS notification | On to Off | The app log has no notification line. |
| Sound for a red box | On to Off | No `afplay` process at the escalated red box. |
| Start at login | Not changed | The checkbox is disabled in the dev app. |
| Poll interval | 2 s to 5 s | The active polls (`claude agents --json`, parent PID 25936) started at 03:20:37.836, 43.088, 48.328, 53.487, 58.696 and 03:21:03.891. The gaps are 5.16 s to 5.25 s. The `--all` poll ran at 03:20:37.348 and 03:21:07.545. |
| Snap distance | 8 to 0 | The drag put the chat frame 4 px from the left edge of the Overview frame, and it stayed at 4 px. With 8, the same drag snapped it to 0 px. |
| Panel transparency | 15 to 30 | `--panel-alpha` on the document root changed from `0.85` to `0.7`. |
| Interface scale | 100 to 120 | `devicePixelRatio` changed from 2 to 2.4, and `innerWidth` from 1440 to 1200. |
| Terminal font | SF Mono 13 to Menlo 15 | The chat window of m5a had a cell width of 8.75 px. A 15 px Menlo cell is 9.03 px, which is 8.75 px on the device pixel grid at 2.4. A 13 px cell gives 7.5 px. After the reset to SF Mono 13, the open chat window refit: the line pitch in the screenshots went from 29.2 to 24.5 screenshot pixels (ratio 0.84, 13/15 = 0.87). |
| Display mode | Window to Borderless | `display.get()` gave `borderless`, and `window-state.json` had `"mode": "borderless"`. |

After the restart (main PID 66804), `settings.get()` and `settings.json` had all the changed values. `--panel-alpha` was `0.7`, `devicePixelRatio` was 2.4 and the mode was `borderless`. The chat window of m5a came back. At the end of Step 1, the agent put each row back to its default, except "macOS notification" and "Sound for a red box" (see "Changes to the method").

### Step 2 details

- Overview row menu (space): Warp to, Hail..., Activate module, Full stop, Set threat level, Track, Set callsign..., Scan (disabled), Copy transponder ID, Open cargo hold, Jump to terminal, Disengage, Power down..., Self-destruct....
- Watchlist row menu (space): the same, with Change colour and Stop tracking in place of Track.
- Selected Item tooltips (space): Warp to, Hail, Activate module, Full stop, Scan ("Coming in M5"), Jump to terminal, Power down, Stop tracking.
- Side bar tooltips (space): Launch and Reactivate all. The panel buttons (Overview, New Overview, Selected Item, Watchlist, Layouts, Settings) keep their names.
- Stop dialog (m5b busy): title `Power down`, buttons `Cancel` and `Power down`. Body: `bifrost-test-m5b is working right now. Stop it anyway? The current turn will end.`
- Delete dialog (m5b): title `Self-destruct bifrost-test-m5b`, buttons `Cancel` and `Self-destruct`. Body: `Delete bifrost-test-m5b? This removes the session from Claude Code and Bifrost.`
- Rename dialog (m5a): title and button `Set callsign`. The field had the focus. Esc closed it.
- New session dialog: title and button `Launch`. Esc closed it.
- Panel titles with space labels: `Overview (Default)`, `Selected Item`, `bifrost-test-m5a`, `Watchlist`.
- With Plain again, the Overview row menu showed Open, Send message..., Run slash command, Interrupt, Set priority, Change colour, Remove from watchlist, Rename..., Show Info, Copy session ID, Open project, Open in terminal, Close window, Stop session... and Delete session....

### Observations

These are small. The agent did not count them as bugs. The user can decide.

1. With space labels, the body text of the Stop and Delete dialogs keeps the plain verbs ("Stop it anyway?", "Delete bifrost-test-m5b?"). The title and the button use the space label. Spec 9.1 names dialogs. `src/renderer/src/actions/confirm.ts` writes these body texts on purpose.
2. With space labels, the empty Watchlist says `Nothing on your watchlist yet. Right-click a session and choose Add to watchlist.` The menu item is `Track`. The text is in the panel body, not in a menu or a dialog.
3. The checkboxes of Settings > General have the accessible names `On` and `Off`, not the row names. A snapshot of the accessibility tree shows four checkboxes named `On` or `Off`.

### SHA-256 values

| File | Before Step 1 (03:16:21) | At the stop (03:32:03) | After the clean-up (03:35:03) |
|---|---|---|---|
| `settings.json` | `f3eca126...b921a5` | `f3eca126...b921a5` | `f3eca126...b921a5` |
| `installed_plugins.json` | `bc14400d...185764` | `bc14400d...185764` | `bc14400d...185764` |
| `known_marketplaces.json` | `0f274b87...c1e798` | `b7b2de56...c7b126` | `b7b2de56...c7b126` |

`settings.json` and `installed_plugins.json` have the same bytes as the copies of 03:16:21. `known_marketplaces.json` has one difference: `claude-plugins-official.lastUpdated` changed from `2026-11-06T01:14:21.492Z` to `2026-11-06T03:22:08.190Z`. The mtime of the file is 03:22:08. The folder `~/.claude/plugins/marketplaces/claude-plugins-official` has the mtime 03:20:24.

### Why the check stopped

The agent saw the change at 03:32:03, at a check before the start of the test-home app. The safety rules say: if a value changes, stop the check and record what ran just before. So the agent stopped.

What ran before the change:

- 03:17:35: the two `cl.sh --bg` commands. They started the Claude Code daemon (`claude daemon run --origin transient`, PID 96311) and three `bg-spare` processes.
- From 03:18:30: the real-home dev app. It ran `claude agents --json` each 2 s (each 5 s from 03:20) and `claude agents --json --all` each 30 s. By that rhythm, an `--all` poll started at about 03:22:07.9.
- 03:19 to 03:22: Step 1 actions in the page. The send of 03:22:04 failed before any process started.
- The user's five Claude Code sessions and the controller session ran all the time.

No `claude plugin` command ran before 03:31, and the test home did not exist before 03:31. Bifrost does not write `lastUpdated`. The Live check saw the same field change (`docs/live-findings.md`, "Settings after Remove"). The agent cannot name the process that wrote the file. The most probable cause is a refresh of the official marketplace by Claude Code itself, about 2 hours after the last refresh (01:14:21).

### For the user

1. Decide on the SHA-256 rule. Claude Code changes `claude-plugins-official.lastUpdated` by itself, and the start of a test session can cause it. A new run of Steps 3 to 10 needs a rule that ignores only this field (for example, a compare with `jq 'del(."claude-plugins-official".lastUpdated)'`), or a new baseline just before Step 3.
2. Remove the two test sessions. The permission check refused the clean-up script. Read the name first, then run `cl.sh stop 41d718e9` and `cl.sh rm 41d718e9` (`bifrost-test-m5a`), and `cl.sh stop cddae5de` and `cl.sh rm cddae5de` (`bifrost-test-m5b`). Both were idle at 03:34.
3. Run the rest of the check: Step 3 in a test home (Install, Turn off, Turn on, Remove), Steps 4 to 9, and the carry-overs (the `closest` check of the focus zone, hold-key-and-click on a `bifrost-test-` row, a notification click with the window hidden, the Layout popover with keys off, Reset all keys asks first).
4. Check Start at login in the packaged app. The dev app disables the row.
5. Check the look of the Settings panel. At the default window size it is 640 x 540 px and covers most of the Overview.
6. Decide on observations 1 to 3.
7. The worktree `node_modules` had a `spawn-helper` of node-pty with no execute bit. The agent set mode `755`. A new install with `--ignore-scripts` removes the fix again, and the send box then shows `posix_spawnp failed.`

### Clean-up

- The chat window of `bifrost-test-m5a` closed. No `claude attach` process is left.
- The dev app quit with SIGTERM to PID 66804 at 03:34:17. No Electron, `electron-vite` or Vite process of the worktree is left. Port 9333 is free. No `afplay` process ran.
- The test home `$TMPDIR/bifrost-m5a-home` and the scratch userData are gone. `~/.bifrost` has the same entries as before the check.
- `.m0-sandbox` has no new file.
- `bifrost-test-m5a` (`41d718e9`) and `bifrost-test-m5b` (`cddae5de`) still exist. See "For the user" item 2.

### Second run

A check agent ran Steps 3 to 10 again on 2026-11-06 from 04:01 to 04:34 GMT. The code was branch `m5a` at `d6eb77f`, after the fix wave `cf5595a..d6eb77f`. The versions were Claude Code 2.1.318, Electron 44.7.2, Node 26.8.1 and macOS 26.6.2. The screen was not locked.

The check did not stop. The guard did not change. The check found no Bifrost bug. In the dev app, macOS did not let Bifrost show a notification. So the notification checks are for the user (see "Second run: for the user").

#### Second run: method

- Guard: the new rule of the controller. The agent took the baseline at 04:01:12, just before Step 3. It compared `~/.claude/settings.json` and `~/.claude/plugins/installed_plugins.json` byte for byte (SHA-256). It compared `~/.claude/plugins/known_marketplaces.json` after `jq -S 'walk(if type == "object" then del(.lastUpdated) else . end)'`. It ran the compare 10 times: six times in Step 3, after Steps 4, 8 and 9, and after the clean-up.
- node-pty: `prebuilds/darwin-arm64/spawn-helper` had mode `755` before the first start. The agent did not change it.
- Test home: `$TMPDIR/bifrost-m5a-home`, as in the first run (socket path limit). The test home had `.claude/settings.json` with the old hook of the brief, and `.zshenv` with the `PATH` of the first run. Only the `HOME=<test home> cl.sh plugin ...` checks use `.zshenv`.
- Test-home dev app: `BIFROST_TEST_HOME=<test home>`, `--user-data-dir=<test home>/user-data` and port 9334. Real-home dev app: `--user-data-dir=<scratch>/m5a-check/run2/userdata`, port 9333, and no `BIFROST_TEST_HOME`.
- Sessions: the agent used `bifrost-test-m5a` (`41d718e9`) and `bifrost-test-m5b` (`cddae5de`) again. It started `bifrost-test-m5d` (`c2b70e04`) for the Stop, Resume and Delete keys, and `bifrost-test-m5r` (`82bf334f`) for Step 9. Each start used `cl.sh --bg --model haiku` in `.m0-sandbox`.
- Page keys: CDP key events. Menu keys: a Swift tool posted real key events with `CGEvent.postToPid` to the main PID of the dev app only. These were Cmd+W, Cmd+Shift+W, Cmd+Ctrl+F, Cmd+R, Cmd+Shift+R, Cmd+= and Cmd+-.
- Before each key, a script read the Selected Item name and the selected rows. It refused the key unless each name started with `bifrost-test-`, or no row was selected. Each mouse action on a row read the name of the row first.
- A listener in the page kept each `keydown` with its time. A value on `window` showed that the page did not reload.
- Front app: `open -a Finder` put Finder in front. A second Swift tool put the dev app in front with `NSRunningApplication.activate`, by its PID only.
- "macOS notification" and "Sound for a red box" were off before Step 9 and after it. "Terminal app" was Terminal and "Default app for Open project" was Finder. So J and P did not open Warp or VS Code.
- The agent kept the text of the clipboard before the C keys and put it back after them. The clipboard was empty.
- The agent quit each dev app with SIGTERM to its own main PID: 14192 (test home), 9367 (real home, restart in Step 8) and 81647 (real home). It did not use `osascript`.

Changes to the method:

- Step 4 used `bifrost-test-m5d` for Stop, Resume and Delete. So `bifrost-test-m5a` and `bifrost-test-m5b` stayed for the later steps.
- Resume all acts on each parked row that can resume. The registry had three parked sessions of the user (`backlog-loop-dry-run`, `backlog-loop-dry-run2` and one session with a long name). None of them could resume, and the Resume all button was off. The agent pressed Cmd+Shift+R only after this check. So the check shows that the key gets to the page. It does not show that Resume all runs.
- The check has one red-box sound only. The agent used it with Finder in front. For the check with Bifrost in front, the sound was off.
- The second red box with Bifrost in front came from the escalation of a yellow box of `bifrost-test-m5a` at 1 minute.
- For Cmd+[ and Cmd+], the agent dragged the Settings frame onto the title bar of the Selected Item frame. This made a stack of two panels.

#### Second run: results

| Step | Method | Result | Screenshot |
|---|---|---|---|
| 3. Setup and Live details (04:02 to 04:06) | Test-home app: read the setup dialog, press Esc, click "Turn on Live details". Check the test-home files and `HOME=<test home> cl.sh plugin list --json`. In Settings > Live details: Turn off, Turn on, Remove (confirm). Real-home app with a new userData: read the dialog, press Esc, click Skip only. | Pass. See "Second run: Step 3". | `m5-findings/r2-s3-test-home-setup.png`, `m5-findings/r2-s3-turned-on.png`, `m5-findings/r2-s3-live-off.png`, `m5-findings/r2-s3-remove-confirm.png` |
| 4. Keys outside a chat window (04:07 to 04:20) | Cmd+0, then each single key and each Cmd key of spec 9.4 with a `bifrost-test-` row selected. Stack tabs, Layout popover, Overview settings (D27), Watchlist drag with Esc (D26). | Pass. Each key did its action. Show Info, Event log and Usage HUD do nothing, because M5b adds them. Take control does nothing on an owned session. See "Second run: Step 4". | `m5-findings/r2-s4-layout-popover.png`, `m5-findings/r2-s4-overview-settings-swatch.png`, `m5-findings/r2-s4-watchlist-drag.png` |
| 5. Keys in a chat window and in the send box (04:21 to 04:23) | Click into the chat window of m5a. Type `o1`, then Esc, Backspace, ArrowUp, Tab. Cmd+ArrowDown. Cmd+. on a busy m5a. Send box: `o`, Esc, Cmd+Enter. | Pass. The TUI got each key. No Bifrost action ran. See "Second run: Step 5". | `m5-findings/r2-s5-chat-focus-selects.png`, `m5-findings/r2-s5-chat-o1.png`, `m5-findings/r2-s5-chat-arrowup.png`, `m5-findings/r2-s5-chat-cmd-period-interrupted.png` |
| 6. Hold-key-and-click (04:23 to 04:25) | With m5b selected: hold O and click m5a, press O alone, hold 3 and click m5a, hold 4 with an early release. On the Watchlist: hold 3, and hold 5 with an early release. | Pass. The selection change after a hold Open follows M5a decision 1. See "Second run: Step 6". | `m5-findings/r2-s6-hold-click-watchlist.png` |
| 7. Menu keys (04:24 to 04:26) | Real Cmd+W, real Cmd+Ctrl+F two times. Close panel to Cmd+Shift+W in Settings > Keys, then real Cmd+W and Cmd+Shift+W. Real Cmd+= and Cmd+-. | Pass. See "Second run: Step 7". | `m5-findings/r2-s7-fullscreen.png` |
| 8. Key editor (04:26 to 04:28) | Open: try Cmd+L, Cmd+Q, Cmd+=, then Cmd+K. Hold Open: try Shift+O. Reset the Open row. Restart. Reset all keys: Cancel, then confirm. | Pass. See "Second run: Step 8". | `m5-findings/r2-s8-key-editor-menu-conflict.png`, `m5-findings/r2-s8-key-editor-hold.png`, `m5-findings/r2-s8-reset-all-confirm.png` |
| 9. Alerts (04:28 to 04:32) | Finder in front. Start m5r with `--permission-mode manual`. Row flash off. `Reply with OK.` to m5a. Bifrost in front, escalation 1 minute. | Part. The red box, the one sound, Row flash, the yellow box and the "no notification with Bifrost in front" rule work. macOS refused each notification (`UNErrorDomain error 1`). The notification click is not checked (For the user). See "Second run: Step 9". | `m5-findings/r2-s9-red-box-flash-on.png`, `m5-findings/r2-s9-red-box-flash-off.png` |
| 10. Clean up (04:33 to 04:34) | Close the chat windows. SIGTERM to the dev app. Stop and remove each `bifrost-test-` session with a name check. Remove the test home and the userData. Run the guard. | Pass. See "Second run: clean-up". | - |

#### Second run: Step 3

- Test home, status before the dialog: `plugin: 'not-installed'`, `oldInstall: true`, `versionOk: true`.
- The setup dialog listed three steps. The first step was the removal of the old hooks and the statusLine wrapper. Esc did not close the dialog.
- "Turn on Live details" (04:03:26) took about 3 s. The dialog then showed `On. 0 sessions are sending live details.`, the reload note and Done. Esc did not close it at this point either. Done closed it.
- `$H/.claude/settings.json`: the `Stop` hook of `~/.bifrost/bin/bifrost-hook` is gone. `statusLine` (`echo test`) stays. Claude Code added `extraKnownMarketplaces.bifrost-local` and `enabledPlugins."bifrost-live@bifrost-local": true`.
- `$H/.bifrost/backups/settings-20261106T040326Z.json` has the bytes of the old file.
- `$H/.bifrost/mod` has `hooks/hooks.json`, `hooks/register.ts`, `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json`.
- `HOME=$H cl.sh plugin list --json` showed `bifrost-live@bifrost-local` with `enabled: true`, scope `user` and `readFromFolder` the mod folder. `$H/.bifrost/live.sock` existed. The status was `plugin: 'enabled'`, `listening: true`, `modCurrent: true`, `oldInstall: false`.
- Turn off: the tab showed `Off.`. The socket was gone, and the plugin list showed `enabled: false`.
- Turn on: the tab showed `On.` after about 1 s. The socket was back, and the plugin list showed `enabled: true`.
- Remove: the dialog "Remove Live details" opened with Cancel and Remove. After Remove, the tab showed `Not installed.` The plugin list and the marketplace list were `[]`. `$H/.bifrost` had only `backups`: no `mod` and no socket. `settings.json` had empty `enabledPlugins` and `extraKnownMarketplaces`, and `statusLine` stayed.
- Real home: the status was `plugin: 'not-installed'`, `oldInstall: false`. The dialog listed two steps. Esc did not close it. Skip closed it and set `setupDone: true`. `~/.bifrost` did not change.

#### Second run: Step 4

| Keys | Result |
|---|---|
| Cmd+0 | The focus went from `BODY` to the Overview rows (`data-overview-rows`). |
| Cmd+1, Cmd+2, Cmd+3 | Selected row 1, 2 and 3 (m5a, m5b, m5d). |
| Up, Down, Cmd+Up, Cmd+Down | Selected the previous row and the next row (m5a and m5b). |
| Tab, Shift+Tab | The Overview tab went All, Needs you, All, Parked (wrap), All. The selection stayed. |
| Esc | Cleared the selection. |
| 1 to 5, 0 | The priority of m5a went 1, 2, 3, 4, 5, then none. |
| Cmd+Ctrl+1 to Cmd+Ctrl+5, Cmd+Ctrl+0 | The same. |
| O, Enter, Cmd+Enter | Each opened the chat window of m5a. The focus went into the chat window. |
| M, Cmd+Shift+M | The focus went to the send box. |
| /, Cmd+/ | The send box got `/` and the hint `This runs as a slash command.` |
| X, Cmd+. | With no chat window open, each press started `claude attach 41d718e9` from the dev app (the Interrupt). |
| I, Cmd+I | Nothing. M5b adds Show Info. |
| T, Cmd+Shift+T | Nothing. Take control is for external sessions only. The agent did not press it on another row. |
| C, Cmd+Shift+C | The clipboard got `41d718e9-4493-4013-ae90-04bda6619484`. |
| R | The Rename dialog opened with the focus in "Session name". Esc closed it. |
| Cmd+N | The New session dialog opened. Esc closed it. |
| J, Cmd+Shift+J | Terminal opened and ran `claude attach 41d718e9`, one window for each press. |
| P, Cmd+Shift+O | The dev app ran `/usr/bin/open -a /System/Library/CoreServices/Finder.app /Users/dev-user/Developer/bifrost/.m0-sandbox`. |
| Backspace (m5d, idle) | m5d stopped at once, with no dialog, and became parked. |
| Cmd+R (real key) | m5d resumed. The page did not reload. |
| Cmd+Shift+Backspace | m5d stopped. |
| Cmd+Shift+R (real key) | The page got the key. The page did not reload. Nothing resumed, because no row could resume. |
| Shift+Backspace (m5d) | The dialog "Delete bifrost-test-m5d" opened. Cancel closed it. |
| Cmd+Option+Shift+Backspace (m5d) | The same dialog. "Delete session" removed m5d from Bifrost and from `claude agents --json --all`. |
| Cmd+[, Cmd+] | In the stack of Selected Item and Settings, each press changed the active tab. It wraps. |
| Cmd+Option+S | The Layout popover opened with the focus in "Layout name". Enter saved the layout `m5a-check`. |
| Cmd+Option+1 | After a close of the chat window, layout 1 (`m5a-check`) loaded and the chat window came back. |
| Cmd+L, Cmd+U | No panel. M5b adds the Event log and the Usage HUD. |
| Cmd+, | Settings opened. |

- D-10 (Layout popover): with the focus in "Layout name", Cmd+2 and Cmd+Option+1 did nothing. With the focus on the Load button, 3, ArrowDown and Cmd+2 did nothing. The selection and the priorities did not change.
- D27 (Overview settings): Tab moved the focus from the Tab select to the Cyan swatch, then Columns, Filters and the Name checkbox. Shift+Tab moved it back. The Overview tab stayed All. ArrowRight on the swatch changed Cyan to Light blue, and ArrowLeft changed it back. ArrowDown did not change the swatch (`nextColour` uses only ArrowLeft and ArrowRight). No arrow key selected a row.
- D26 (Watchlist drag): the drag of m5a down over m5b faded the row and showed the line. Esc, with the mouse button still down, ended the drag. The release made no move and selected no row. The same drag without Esc moved m5a below m5b (the agent moved it back). Esc also cleared the selection, because the key map gets Esc too (D26).

#### Second run: Step 5

- Fix wave: with m5b selected, a click into the chat window of m5a selected m5a. The Selected Item panel showed m5a.
- `o1` went to the TUI prompt. No Open and no priority change ran.
- Esc: the TUI showed `Esc again to clear`. Backspace: the prompt showed `o`. ArrowUp: the TUI showed `History 100/100`. Tab: no Bifrost action, and the Overview tab stayed All. The selection stayed on m5a. Two more Esc presses cleared the prompt.
- Cmd+ArrowDown in the chat window selected m5b. The focus stayed in the chat window.
- Fix wave: m5a worked on a task of 600 lines. With m5b selected, the agent clicked into the chat window of m5a and pressed Cmd+.. The TUI showed `Interrupted · What should Claude do instead?` at line 253, and m5a became idle. With a chat window open, Bifrost writes the Esc into the chat PTY and starts no new attach.
- Send box: `o` went into the box, and no chat window opened. Esc moved the focus out of the box. Cmd+Enter in the box opened the chat window of m5a.

#### Second run: Step 6

- With m5b selected, the agent held O and clicked m5a. The chat window of m5a opened. The keyup opened nothing. The selection went to m5a, because the focus went into the new chat window. M5a decision 1 (spec section 24) says this. The brief expected the selection to stay on m5b.
- O alone, with m5b selected, opened the chat window of m5b.
- Hold 3 and click m5a in the Overview: the priority of m5a became 3. The selection stayed on m5b, and m5b kept no priority.
- Fix wave: hold 4, push the mouse button on m5a, release 4, release the mouse button. The priority of m5a became 4. m5b did not change.
- Watchlist: hold 3 and click m5a: priority 3. Hold 5 with the early release: priority 5. The selection stayed on m5b.

#### Second run: Step 7

- Real Cmd+W closed the top panel (Watchlist). The page got no `keydown`, so the menu took the key.
- Real Cmd+Ctrl+F: the display mode became `fullscreen` and `innerWidth` went from 1440 to 1512. A second Cmd+Ctrl+F gave `window` and 1440 again.
- Fix wave: on Close the focused panel, the recorder refused Ctrl+Shift+W and W with `A menu shortcut needs Cmd.` It took Cmd+Shift+W.
- After the change, real Cmd+W did not close a panel, and the page got the key. Real Cmd+Shift+W closed the top panel (Settings). So the menu uses the new key.
- Real Cmd+= changed the Interface scale from 100 to 110 and 120. Real Cmd+- changed it to 110 and 100. `devicePixelRatio` followed (2, 2.2, 2.4, 2.2, 2).

#### Second run: Step 8

- Fix wave: 50 ms after the click on Change, the focus was on the prompt `Press the new shortcut. Esc cancels.` (`data-key-recorder`).
- Open: Cmd+L gave `Event log already uses this key.` Cmd+Q (CDP) gave `macOS keeps this shortcut for itself.` Cmd+= gave `A Bifrost menu already uses this shortcut.` Cmd+K was accepted. Then Cmd+Enter did nothing, and Cmd+K opened the chat window of m5a.
- Hold Open: Shift+O gave `A hold key must be a single letter or number, without Cmd, Ctrl, Option or Shift.` The recorder stayed on.
- Reset on the Open row put back Cmd+Enter. `settings.json` then had `{"close-panel:mod":"Mod+Shift+W"}`.
- Restart: SIGTERM at 04:26:52, the same command, new main PID 81647. The key stayed in the page and in `settings.json`. Real Cmd+W did nothing, and real Cmd+Shift+W closed the top panel.
- Reset all keys asked first: the dialog "Reset all keys" with `This puts every key back to its Bifrost default.` Cancel kept the key. The second time, "Reset all keys" in the dialog gave `keys: {}` in the page and in `settings.json`. Real Cmd+W then closed the top panel again.

#### Second run: Step 9

- 04:29:27: Finder in front. 04:29:28: `bifrost-test-m5r` started with `--permission-mode manual` and the prompt `Run the shell command: touch perm-check-m5r.txt`.
- 04:29:32.569: m5r got a red box (`boxReason: 'prompt'`, status `waiting`).
- 04:29:33.131: one `afplay /System/Library/Sounds/Ping.aiff` process, parent 81647. No other `afplay` ran in the check.
- The app log has `Bifrost cannot show a notification. The operation couldn’t be completed. (UNErrorDomain error 1.)` and no `Bifrost showed a notification` line. Error 1 means that macOS does not allow notifications for this app (the dev `Electron.app`, bundle ID `com.github.Electron`). Bifrost asked for the notification at the correct time. This is not a Bifrost source bug.
- Row flash on: 4 elements had `animate-box-flash`. Row flash off: 0 elements. The red box stayed.
- 04:30:46.9: the send box sent `Reply with OK.` to m5a with Finder in front. m5a was busy at 04:30:47.8 and got a yellow box at 04:30:52.177. The log got a second `UNErrorDomain error 1` line at that time.
- 04:31:00: Bifrost in front. The yellow box of m5a became red (`escalated`) at 04:31:53.051, 60.9 s later. The log got no new notification line, and no `afplay` ran (sound off).
- Nobody answered the prompt of m5r. `perm-check-m5r.txt` does not exist.
- Not checked: the notification text, a click on a notification while the window is hidden, and a click after the window was closed (M5a decision 4). Not checked: the sound with Bifrost in front.

#### Second run: fix-wave items and carry-overs

| Item | Result | Evidence |
|---|---|---|
| Focus in a chat window selects its session, and Cmd+. acts on it | Pass | Step 5 |
| A hold key released before the mouse button acts on the clicked row | Pass | Step 6 |
| Panel transparency and Interface scale are selects | Pass | Comboboxes: `0% (solid)` to `50%` in steps of 5, `80%` to `150%` in steps of 10. `m5-findings/r2-settings-general-selects.png` |
| Each General checkbox has its row name | Pass | Checkboxes "Row flash", "macOS notification", "Sound for a red box" and "Start at login" (disabled) |
| The key recorder gets the focus at the click | Pass | Step 8 |
| A notification click after the window closed opens the session | Not checked (For the user) | Step 9 |
| Space labels in the Stop and Delete dialog bodies and the empty Watchlist hint | Pass | `bifrost-test-m5b is working right now. Power it down anyway? The current turn will end.`, `Self-destruct bifrost-test-m5b? This removes the session from Claude Code and Bifrost.`, `Nothing on your watchlist yet. Right-click a session and choose Track.` `m5-findings/r2-labels-space-stop-body.png`, `m5-findings/r2-labels-space-delete-body.png`, `m5-findings/r2-labels-space-watchlist-hint.png` |
| A menu slot refuses a key without Cmd | Pass | Step 7 |
| Real-DOM `closest` check of the focus zone (Task 5) | Pass | The xterm `textarea` found `[data-chat-terminal]` with the ID of m5a. The send box `textarea` found `[data-send-box]`. The rows `div` had `data-overview-rows`. The recorder prompt had `data-key-recorder`. "Layout name" found `[role="dialog"]` (modal). |
| Hold-key-and-click on a `bifrost-test-` row (Task 6) | Pass | Step 6 |
| Notification click while the window is hidden (Task 8) | Not checked (For the user) | Step 9 |
| The Layout popover turns keys off (D-10) | Pass | Step 4 |
| Reset all keys asks first (Task 7) | Pass | Step 8 |

The three observations of the first run are fixed: the dialog bodies and the Watchlist hint use the space words, and the checkboxes have the row names.

#### Second run: observations

These are small. The agent did not count them as bugs. The user can decide.

1. After Esc in the Rename dialog of the R key, the focus goes to the "Kind" column header button, not back to the Overview rows. The focus zone is then `control`. Cmd+0 moves the focus back to the rows.
2. In a narrow Settings frame (360 px, in a stack), a row that records shows only the prompt. The row name is hidden, and the Clear and Reset buttons go past the right edge (`m5-findings/r2-s8-key-editor-menu-conflict.png`).
3. When macOS refuses a notification, Bifrost writes the error to the log only. The user does not see that notifications do not work.

#### Second run: SHA-256 values

| File | Compare | 04:01:12 (baseline) | 9 checks from 04:02:48 to 04:32:18 | 04:34:03 (after the clean-up) |
|---|---|---|---|---|
| `settings.json` | bytes | `f3eca126...b921a5` | same | `f3eca126...b921a5` |
| `installed_plugins.json` | bytes | `bc14400d...185764` | same | `bc14400d...185764` |
| `known_marketplaces.json` | `jq` without `lastUpdated` | `58a06684...59866a` | same | `58a06684...59866a` |

The raw SHA-256 of `known_marketplaces.json` was `b7b2de56...c7b126` at 04:01:12 and at 04:34:03. So the raw file did not change in the second run either.

#### Second run: clean-up

- The chat windows closed. No `claude attach` process is left.
- The test-home app quit at 04:05:42 and the real-home app at 04:33:01. No Electron, `electron-vite` or Vite process of the worktree is left. Ports 9333, 9334 and 5173 are free.
- Sessions: the agent stopped and removed `bifrost-test-m5r`, `bifrost-test-m5a` and `bifrost-test-m5b` with `cl.sh stop` (each had a `pid`) and `cl.sh rm`, after a name check each time. The Delete key removed `bifrost-test-m5d` in Step 4. `cl.sh agents --json --all` has no `bifrost-test-` entry. This completes item 2 of the first "For the user" list.
- The test home and the scratch userData are gone. `~/.bifrost` has the same entries as before. The J key wrote `attach-41d718e9.command` in `~/.bifrost/run`, and Bifrost removed it again.
- `.m0-sandbox` has no new file.
- Terminal was not open before the check. The J keys opened it at 04:13:08. The agent stopped the two `claude attach 41d718e9` clients in it with SIGTERM, then quit Terminal with SIGTERM to its PID 36799.
- The P keys opened a Finder window of `.m0-sandbox`. It is still open (For the user).
- The clipboard is empty, as before the check.

#### Second run: for the user

1. Notifications in the dev app: macOS gave `UNErrorDomain error 1` for each notification of the dev `Electron.app`. Allow notifications for "Electron" in System Settings > Notifications, or use the packaged app. Then check the notification of a red box and of a yellow box with another app in front, a click on a notification while the window is hidden, and a click after the window was closed (M5a decision 4).
2. Check the sound of a red box with Bifrost in front. The check had one sound only, and it used it with Finder in front.
3. Check Resume all and Cmd+Shift+R with a row that can resume. In this check no row could resume, and three parked sessions of the user were in the registry.
4. Close the Finder window of `.m0-sandbox` that the P keys opened.
5. Decide on the second-run observations 1 to 3.
6. These items of the first list stay: Start at login in the packaged app (item 4) and the look of the Settings panel (item 5).
