# Bifrost M5 findings

## M5a checks

A check agent ran Task 9 on 2026-11-06 from 03:16 to 03:36 GMT. The code was branch `m5a` at `ecacfff`. The versions were Claude Code 2.1.318, Electron 44.7.2, Node 26.8.1 and macOS 26.6.2. The screen was not locked, and the dev app was the front app.

The check stopped in Step 3. The SHA-256 of `~/.claude/plugins/known_marketplaces.json` changed during Step 1. The safety rules say: stop the check and record what ran just before. See "SHA-256 values" and "Why the check stopped". Steps 1 and 2 and the real-home part of Step 3 ran. The test-home part of Step 3 and Steps 4 to 9 did not run.

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
