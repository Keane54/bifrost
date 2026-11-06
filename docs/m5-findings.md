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

## M5b checks and the DMG

A check agent ran Task 9 of M5b on 2026-11-06 from 05:50 to 06:16 GMT. The code was branch `m5b` at `9c87552`. The versions were Claude Code 2.1.319, Electron 44.7.2, Node 26.8.1 and macOS 26.6.2. The screen was not locked.

The check did not stop. The guard did not change. The check found two Bifrost bugs (B1 and B2). B1 makes the smoke test fail on a slow start, and it fails each Rosetta run of the packaged app. See "M5b: bugs".

### M5b: method

- Guard: the rule of the second M5a run, and R13. The agent took the baseline at 05:50:29, before Step 1. It compared `~/.claude/settings.json` and `~/.claude/plugins/installed_plugins.json` byte for byte (SHA-256). It compared `~/.claude/plugins/known_marketplaces.json` after `jq -S 'walk(if type == "object" then del(.lastUpdated) else . end)'`. It also kept a list of each file in `~/.bifrost` with its size and SHA-256 (not `live.sock`). It ran the compare six times: after Step 4, before `pnpm dist`, before the stop of the dev app, before the start of the packaged app, after the start of the packaged app, and after the clean-up.
- Live details without an install (D32): the agent copied the four `MOD_FILES` of `resources/live-mod/` to `.m0-sandbox/m5b-check/bifrost-live/`. It started `bifrost-test-m5c` (`32f54b87`) and `bifrost-test-m5d` (`e089ed45`) at 05:51:33 with `cl.sh --bg --plugin-dir <copy> --model haiku --name <name> "Reply with the word READY."`.
- Dev app: `BIFROST_LIVE_LISTEN=1 pnpm exec electron-vite dev -- --user-data-dir=<scratch>/m5b-check/userdata --remote-debugging-port=9333`, in the real home. The main PID was 20513. `window.bifrost.live.status()` gave `listening: true`, `plugin: 'not-installed'`. The agent clicked Skip in the setup dialog. After the start of the two sessions, the status gave `liveSessions: 2`. So the live parts of Steps 1 to 3 ran with the socket.
- The agent drove the page with a CDP script over port 9333: clicks, key events, `eval` reads of the DOM and of `window.bifrost`, and screenshots. Real keys (Cmd+I, F5, Cmd+R) went to the main PID only, with a Swift tool that uses `CGEvent.postToPid`. A second Swift tool put an app in front by its PID. The agent did not use `osascript`.
- Before each action on a row, a script read the name of the row and of the Selected Item panel, and checked the `bifrost-test-` prefix. Each row action of the check was on `bifrost-test-m5c`, `bifrost-test-m5d` or `bifrost-test-m5e`.
- In the dev app, the agent set "Sound for a red box" to off. "macOS notification" stayed on, for the notice row of Step 2.
- The agent quit each app with SIGTERM to its own main PID: 20513 (dev app, 06:11:54) and 51207 (packaged app, 06:15:08).

Changes to the method:

- The packaged app got `--remote-debugging-port=9335` in addition to `--user-data-dir`, so that the agent could click Skip, open the chat window and select rows. The agent started it with a clean env (`env -i` with `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`, `TMPDIR` and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`), as a start from a new terminal.
- Step 6 failed at the first run. The agent ran the smoke test 7 more times to find the cause. Step 7 ran the Rosetta smoke test 4 times, one time after the stop of the dev app.
- The agent has no Screen Recording permission. So it cannot capture the DMG window, the Dock or the browser window, and it cannot read window titles. For the status page, it counted the string `https://status.claude.com` in the newest Brave session file. It read nothing else from that file.
- The packaged app ran without the live socket. So it also showed the "no socket" case of the Event log and of the Usage HUD.

### M5b: results

| Step | Method | Result | Screenshot |
|---|---|---|---|
| 1. Show Info (05:52 to 05:54) | m5c selected: I, then Cmd+I (CDP), then real Cmd+I, then the row menu item "Show Info". m5d selected: hold I and click m5c. Then I on m5d for a second panel. Then Backspace (Stop) on the idle m5d. Compare with `cl.sh agents --json`, `registry.rows()`, `gh` and the transcript file. | Pass. Each of the five ways opened `show-info:32f54b87-...` with the title `Show Info: bifrost-test-m5c`. A second I with the panel open made no second panel. Hold I and click kept the selection on m5d. Two panels were open at the same time. After the stop, the m5d panel showed `PID -` and `Duration Parked`. Each value agrees with its source. See "M5b: Step 1". | `m5-findings/m5b-s1-show-info-i.png`, `m5-findings/m5b-s1-two-panels.png`, `m5-findings/m5b-s1-parked.png` |
| 2. Event log (05:54 to 05:55) | Cmd+L. Finder in front. Send box: `Reply with OK.` to m5c. Filter by m5c. Real F5. | Pass, with the socket. The log showed `UserPromptSubmit` (05:54:09.318) and `Stop` (05:54:13.625) of m5c, newest first, above the older events. macOS refused the notification of the yellow box, and the log got the notice row (carry-over 3). The m5c filter showed 5 events, all of m5c. After F5 the page was new (a value on `window` was gone), and the 10 events stayed. The filter went back to "All sessions". The "no socket" case ran in Step 7: `No events yet.` and the Live details hint. | `m5-findings/m5b-s2-event-log.png`, `m5-findings/m5b-s2-event-log-filter.png` |
| 3. Usage HUD (05:55) | Cmd+U. Compare with `usage.get()` and the `rateLimits` of the rows. | Pass, with bug B2. See "M5b: Step 3". | `m5-findings/m5b-s3-usage-hud.png` |
| 4. Service status (05:55 to 05:58) | Side bar button. `curl` of `status.json`, `incidents/unresolved.json` and `components.json` of each page. Wait 70 s. Click "Open status page" of Claude. | Pass. See "M5b: Step 4". | `m5-findings/m5b-s4-service-status.png` |
| 5. Theme (05:59 to 06:01) | Open all nine panel kinds: Overview, Selected Item, Watchlist (m5c, Light blue), chat window (m5c), Settings, Show Info, Event log, Usage HUD, Service status. Read the computed styles. Look for the box yellow, the box red and the parked grey on each element outside the terminal canvas. | Pass for the rules that a script can check. The user checks the look. See "M5b: Step 5". | `m5-findings/m5b-s5-theme-all-panels.png` |
| 6. Smoke test (06:01 to 06:04) | `pnpm smoke`, then `pnpm smoke` again, then `pnpm smoke:app` six times. | Fail. The first run failed after 12.4 s: `attach.log` stayed empty. The trace shows the chat window of `smoke-alpha` with `Waiting for the session list.` while the Overview shows the rows. The next 7 runs passed (2.0 s to 2.3 s). The cause is bug B1. | `m5-findings/m5b-s6-smoke-fail-waiting.jpeg` |
| 7. DMG (06:05 to 06:15) | `pnpm dist`. The Task 8 checks of Steps 3 to 5. Open the DMG in Finder. SIGTERM to the dev app. One start of the packaged app in the real home. | Part. The build, the bundle checks, the arm64 smoke test, the DMG and the packaged app pass. The Rosetta smoke test failed 4 times of 4, with the same cause as Step 6 (B1). See "M5b: Step 7". | `m5-findings/m5b-s7-packaged-app.png`, `m5-findings/m5b-s7-packaged-no-live.png`, `m5-findings/m5b-s7-smoke-x64-fail-waiting.jpeg` |
| 8. Clean up (06:15 to 06:16) | Close the chat windows. Stop and remove each `bifrost-test-` session with a name check. Remove the mod copy and the two user-data folders. Run the guard. | Pass. See "M5b: SHA-256 values" and "M5b: clean-up". | - |

### M5b: Step 1

| Value | Show Info (m5c) | Source |
|---|---|---|
| Name, Session ID, Short ID | `bifrost-test-m5c`, `32f54b87-6690-4ac7-9afb-73b647443139`, `32f54b87` | `cl.sh agents --json`: the same `name`, `sessionId` and `id` |
| Kind | Owned | `kind: background`. Bifrost shows a background session as Owned. |
| PID | 34610 | `pid: 34610` |
| Project folder | `/Users/dev-user/Developer/bifrost/.m0-sandbox` | `cwd` |
| Transcript | `~/.claude/projects/-Users-dev-user-Developer-bifrost--m0-sandbox/32f54b87-....jsonl` | `transcriptPath` of the row. The file exists (404,896 bytes). |
| Branch, PR, Worktree | `main`, `no git remotes found`, `None` | `git branch --show-current` gives `main`. `gh pr view --json number,title,url,state` in `.m0-sandbox` gives `no git remotes found` (exit 1). This is the `gh` reason. |
| Model, Effort, Permission mode | Haiku 5.5, medium, auto | `model`, `effort`, `permissionMode` of the row (D28) |
| Started, Duration | 05:51. The duration was `less than 1 min`, and later `1 min`. | `startedAt` 1793944295836 (05:51:35.836) |
| Cost | `<$0.01` | `costUsd` 0.0093 |
| Context window, Context use | 1M tokens, 5% | `contextWindowSize` 1000000, `contextPercent` 5 |
| 5-hour limit | `-` | The row has no `fiveHour` window. |
| 7-day limit | `33%, resets Sat 7 Nov 02:00` | `sevenDay`: `usedPercent` 33, `resetsAt` 1794016800000 (2026-11-07 02:00 GMT) |
| Claude Code version | 2.1.319 | `claudeVersion` of the row, and `cl.sh --version` |

- The row menu of m5c had: Open, Send message..., Run slash command, Interrupt, Set priority, Add to watchlist, Rename..., Show Info, Copy session ID, Open project, Open in terminal, Stop session..., Delete session....
- The m5d panel had the same kinds of values, with PID 34648 and Context use 6%. After the stop (05:53:33), the Event log got `SessionEnd` of m5d at 05:53:33.655.

### M5b: Step 3

- `usage.get()` at 05:55:06: `limits: { sevenDay: { usedPercent: 33, resetsAt: 1794016800000 } }`, from `bifrost-test-m5c`, `updatedAt` 05:55:05.853. The rows of m5c and m5d had the same `rateLimits`, with no `fiveHour`.
- The HUD: "5-hour limit", `-`, `No data for this limit yet.` "7-day limit", `33%`, a bar of width 33% in `--color-usage` (`#5fb3c9`), `Resets in 20 h 04 min (Sat 02:00)`. The last line was `From bifrost-test-m5c, 0 s ago.`
- No window was at 90% or more. So the amber `usage-high` bar did not show (For the user).
- Values for the user: the 7-day limit was at 33% and resets on 2026-11-07 at 02:00 GMT. This plan has no 5-hour window.
- Bug B2: at the default size the last line is cut. See "M5b: bugs".

### M5b: Step 4

- `curl` at 05:55:53: each of `status.claude.com`, `www.githubstatus.com` and `status.sentry.io` gave `{"indicator":"none","description":"All Systems Operational"}`, no unresolved incident and no component that was not operational.
- The panel showed `Operational` for Claude, GitHub and Sentry (`data-service-level="none"`, colour `rgb(134, 196, 143)`, the `svc-ok` token). `service.status()` agreed.
- The rounds ran at 05:55:00.988, about 05:56:01 and 05:57:01.627, about 60 s apart. In the 70 s wait the panel line went from `Checked at 05:56.` to `Checked at 05:57.` The line shows hours and minutes only.
- "Open status page of Claude": the agent clicked it at 05:57:57 and at 05:58:16. Each time Brave, the default app for `https`, came to the front within 3 s. The Brave session file changed at 05:58:17 and has the string `https://status.claude.com`. Two Brave tabs of the status page can be open (For the user).

### M5b: Step 5

- Each frame had `backdrop-filter: blur(12px)`. Each frame background was `rgba(24, 24, 24, 0.85)`, and the focused frame was `rgba(8, 8, 8, 0.95)`. The font was `"Geist Mono", ui-monospace, "SF Mono", Menlo, monospace`. The terminal font setting was SF Mono 13.
- The box yellow showed only on the box marks of m5c (Overview row, Watchlist row, Selected Item, chat title) and in the `Needs you` text of these. No element used the box red or the parked grey. The four new panels used none of the three.

### M5b: Step 7

- `pnpm dist` (06:05:11 to 06:07:46): exit 0. The log has no `x64ArchFiles`, `detected file`, `warn` or `error` line. `dist/Bifrost-1.0.0-universal.dmg` has 232,285,120 bytes and the SHA-256 `5ae0fea3...ab72fb`.
- The Task 8 checks of Step 3 passed: `lipo -archs` gives `x86_64 arm64`. `codesign` gives `Identifier=com.keyholding.bifrost`, `Signature=adhoc`, `TeamIdentifier=not set`, and the strict deep check passed. The two `pty.node` and the two `spawn-helper` files are Mach-O for their own chip, and each `spawn-helper` has mode 755. No `node-pty/build` path is in the bundle or in `app.asar` (852 entries). The four mod files are in `app.asar.unpacked/resources/live-mod` with the same bytes as `resources/live-mod`. No mod test is in the bundle. The Info.plist has `com.keyholding.bifrost`, `icon.icns` (the same bytes as `build/icon.icns`), `public.app-category.developer-tools` and 1.0.0.
- Task 8 Step 4: `BIFROST_SMOKE_APP=<app> pnpm smoke:app` passed (8.5 s). With `BIFROST_SMOKE_ARCH=x86_64`, it failed 4 times (56.2 s, 30.5 s, 32.3 s, and 29.4 s with the dev app off). Each trace shows `Waiting for the session list.` in the chat window (B1).
- Task 8 Step 5: the DMG mounts as `/Volumes/Bifrost 1.0.0-universal` with `Applications`, `Bifrost.app`, `.background.tiff` and `.VolumeIcon.icns`. The app in it has `Signature=adhoc`. `open` of the DMG made one new Finder window of 540 x 380 points. `hdiutil detach` closed it. The agent cannot capture the window (For the user).
- The packaged app started at 06:13:19 as PID 51207. `lsappinfo` gave `Bifrost`, the path in `dist/mac-universal` and `ApplicationType Foreground`, so the app has a Dock icon. Bifrost was the front app.
- The setup dialog showed (new user data). The agent clicked Skip only. `live.status()` gave `listening: false`, `plugin: 'not-installed'`.
- The registry had the real sessions: the five external sessions of the user, the three parked sessions that were there before the check, m5c and the parked m5d. The All tab showed m5c and the five external sessions.
- The O key on m5c opened its chat window. `claude attach 32f54b87` ran as PID 65152, with the parent 51207. The terminal drew the TUI of m5c.
- The Service status panel filled at once: three `Operational`, `Checked at 06:13.`
- 06:14:06: `open -a Finder` put Finder in front. 06:14:07: `bifrost-test-m5e` (`8b420fdf`) started with `--model haiku --permission-mode manual` and `Run the shell command: touch perm-check-m5e.txt`, with no `--plugin-dir`. 06:14:13.003: m5e got a red box (`boxReason: 'prompt'`).
- The terminal log has `Bifrost showed a notification for 8b420fdf-2de3-4966-b9a3-19d191d90506.` The agent cannot see the screen, so it does not know if macOS also showed a permission prompt. One `afplay /System/Library/Sounds/Ping.aiff` ran at 06:14:13 with the parent 51207 (the sound is on by default).
- The Event log showed `No events yet.` and the Live details hint. The Usage HUD showed `No data` for both limits and `No usage data yet. Live details sends it.`
- In the Parked tab, the agent selected m5d and sent a real Cmd+R to PID 51207 at 06:14:47. At 06:14:54 m5d was `idle` with the new PID 74697. So Resume works in the packaged app.
- SIGTERM to PID 51207 at 06:15:08. No Bifrost process stayed.

### M5b: bugs

B1 (medium): a page that loads after the last registry change cannot open a chat window until the next change.

- Evidence: smoke run 1 of Step 6 and 4 of 4 Rosetta runs of Step 7 failed. In each trace, the Overview shows the sample rows, and the chat window of `smoke-alpha` shows `Waiting for the session list.` for 10 s. In the dev app, after a real F5 at 06:04:10, the open chat window of m5c showed the same text for 2.3 s. Then a session changed, and the chat window attached.
- Cause (from the code): `RegistryProvider` in `src/renderer/src/data/registry.tsx` sets `loaded` only in `registry.onUpdate`. The first rows come from `registry.rows()`, which does not set `loaded`. The main process sends `registry:update` only when the rows change (`send()` in `src/main/registry/service.ts` returns when the JSON is the same as `lastSent`). `attachWindow` in `src/main/ipc.ts` sends no rows at `did-finish-load`. So when the page subscribes after the last change, `loaded` stays false. `attachTarget` in `src/renderer/src/chat/views.ts` then gives `Waiting for the session list.`
- Effect: a slow start (Rosetta, an Intel Mac, a busy Mac) or a reload can block all chat windows while no session changes. The smoke fixtures never change, so the test fails. This touches Review Focus 4 (chat windows on both chips).
- A possible fix: set `loaded` when `registry.rows()` gives the rows, or send the current rows when a page loads. The agent did not change the code.

B2 (low): the Usage HUD is too small at its default size.

- Evidence: at 360 x 170 px, the content area is 140 px high, and the content needs 146 px. The last line (`From bifrost-test-m5c, 0 s ago.` in the dev app, `No usage data yet. Live details sends it.` in the packaged app) is cut at the bottom edge. `m5-findings/m5b-s3-usage-hud.png` and `m5-findings/m5b-s7-packaged-no-live.png` show it. At 176 px the line shows fully (`m5-findings/m5b-s5-theme-all-panels.png`).

### M5b: observations

These are small. The agent did not count them as bugs. The user can decide.

1. At the default width of 640 px, the Event log cuts the notice row to `macOS didn't show a notification. Allow notifica...`. The row has no tooltip. The full text shows only in a wider frame.
2. The dev app sets no Dock icon (the code has no `app.dock.setIcon`). So the Dock shows the icon of the dev `Electron.app`, and only the packaged app can show the Bifrost icon.

### M5b: SHA-256 values

| File | Compare | 05:50:29 (baseline) | 5 checks from 05:58:36 to 06:15:03 | 06:15:52 (after the clean-up) |
|---|---|---|---|---|
| `settings.json` | bytes | `f3eca126...b921a5` | same | `f3eca126...b921a5` |
| `installed_plugins.json` | bytes | `bc14400d...185764` | same | `bc14400d...185764` |
| `known_marketplaces.json` | `jq` without `lastUpdated` | `58a06684...59866a` | same | `58a06684...59866a` |
| `~/.bifrost` | list with size and SHA-256 | `backups/` (2 files), `run/` (empty), `statusline-original.json` | same | same |

- The raw SHA-256 of `known_marketplaces.json` went from `b7b2de56...c7b126` to `99ff9acf...a40aef`. The only change is `claude-plugins-official.lastUpdated`, now `2026-11-06T06:00:35.033Z`. At that time the agent moved frames in the dev app. No `claude plugin` command ran in the check. This is the Claude Code refresh that the M5a check saw.
- `~/.bifrost/live.sock` existed while the dev app ran with `BIFROST_LIVE_LISTEN=1`, and the dev app removed it at the quit. The packaged app made no socket. No other file in `~/.bifrost` changed.

### M5b: clean-up

- The chat windows closed. No `claude attach` process is left.
- The dev app quit at 06:11:54 and the packaged app at 06:15:08. No Electron, `electron-vite`, Vite or Bifrost process of the check is left. Ports 9333, 9335 and 5173 are free. No `afplay` process runs.
- Sessions: the agent stopped and removed `bifrost-test-m5e`, `bifrost-test-m5c` and `bifrost-test-m5d` with `cl.sh stop` (each had a `pid`) and `cl.sh rm`, after a name check each time. `cl.sh agents --json --all` has no `bifrost-test-` entry.
- Nobody answered the prompt of m5e. `perm-check-m5e.txt` does not exist. `.m0-sandbox/m5b-check/` and the two user-data folders are gone. `.m0-sandbox` has the same entries as before the check.
- The DMG is not mounted. The DMG Finder window closed with the eject. The three Finder windows that were open before the check are still open. The check opened no Terminal window.
- `dist/` has the new DMG of Step 7. `test-results/` (ignored by git) has the trace of the last Rosetta failure.

### M5b: items for the user

1. Open `dist/Bifrost-1.0.0-universal.dmg`. Drag Bifrost to Applications. Start it from Applications. Check the look of the DMG window and the Bifrost icon in the Dock. The agent cannot capture them.
2. Allow notifications when macOS asks. Check that a click on a notification selects the session and opens its chat window. In the check, the packaged app wrote `Bifrost showed a notification` at once. The user's own Bifrost has the same bundle ID, so macOS can already allow it.
3. Turn on Start at login in Settings, if you want it. Check System Settings > General > Login Items.
4. Check Fullscreen (the M2 items) and the look of all panels. `m5-findings/m5b-s5-theme-all-panels.png` has all nine panel kinds.
5. Bifrost has an ad-hoc signature. A copy to another Mac needs the signing of spec 14.2.
6. Turn on Live details in Settings > Live details, if you want boxes at once and the model, cost and limits. Sessions that run now get it after `/reload-plugins` or a restart.
7. Check the colours of the Service status panel and of the Usage HUD (D30, ruling R4), and the app icon next to the row mark (D31). The amber high bar did not show, because the 7-day use was 33%. Check it when a window is at 90% or more.
8. Decide on B1 before the DMG goes to an Intel Mac. The Rosetta smoke test fails until B1 is fixed.
9. Decide on B2 and on the two observations.
10. Close the Brave tabs of `status.claude.com` that the two clicks of Step 4 opened.
