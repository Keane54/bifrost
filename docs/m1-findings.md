# M1 findings: the data flow with real sessions

Date: 2026-11-05, 05:01 to 06:46 (GMT). Claude Code 2.1.318. Branch `m1` at `5631121`.

The controller ran this task while the user was asleep. The user gave permission to install Bifrost into their real `~/.claude/settings.json` and to uninstall it at the end. The run used the Bifrost buttons for the install and the uninstall. Nobody edited the settings file by hand.

## Summary

| Step | Result | Design impact |
|---|---|---|
| 1. Skip mode | Pass. 10 rows, no box, no model, no context, no cost. `~/.bifrost/active` exists while Bifrost runs. | None. |
| 2. Single instance | Pass. The second instance quits with code 0. The first window and the marker stay. | None. |
| 3. Install | Pass. Status: installed, scripts current. A backup with the original bytes. 10 Bifrost hook rows and the wrapper statusLine. | The preview shows a backup path that the install does not use (finding F6). |
| 4. Hot reload | Pass. Running sessions use the new hooks and the new statusLine at once. Uninstall also applies at once. | None. The user does not need to restart sessions. |
| 5. Yellow box | Pass. Yellow and flashing for 11 s of samples, then red after 10 minutes (rule 4). | None. |
| 6. Red box, background | Pass after a change of prompt. `waiting` / `permission prompt`. Red and flashing for more than 6 minutes. | `date` does not prompt in `manual` mode (finding F2). |
| 7. Red box, interactive | Pass. An interactive session reports `waiting` / `permission prompt`. Red and flashing for 60 s. | The fact differs from M0 and from the reason text of spec 7 rule 10 (finding F3). |
| 8. AskUserQuestion | Pass. `waiting` / `input needed`. Red and flashing for 39 minutes. | New `waitingFor` value (finding F3). |
| 9. Flash stop | Pass. The click stops the flash. The box stays. | None. |
| 10. Status files | Pass. The wrapper runs each 1 s for an unattached background session and for the user's sessions. The `quiet` file exists. Model, context and cost show. | No update while a prompt dialog shows (finding F7). Age column shows 0 to 2 s (review item M2). |
| 11. Wrapper cost | Pass. The wrapper adds 15 ms (median) to the original command. Quiet session: 48 ms. | The original command alone takes 655 ms (finding F8). |
| 12. Hook cost | Pass. A 324,506-byte PostToolUse event shows no delay. The hook cost does not grow with the input. | The 50 ms limit fails at the maximum under load (finding F9). |
| 13. Hook with Bifrost closed | Pass. No event file, no status file write, no hook error. | None. |
| 14. Uninstall | Pass. SHA-256, bytes and `jq -S` are all equal to the backup. | None. |
| 15. Clean up | Done. All `bifrost-test-` entries are removed. The worktree of `bifrost-test-h` is removed. | Background sessions make a git worktree before an edit (finding F4). |

## Items for the user

1. The settings file is the same as before the run (step 14). You can install again from the app. The fix for review item I2 works, so daily use is now possible after the other merge fixes.
2. The Mac went into "Maintenance Sleep" 7 times during the run, for 5 to 16 minutes each time (finding F1). Sessions and Bifrost stop during this sleep. The 10-minute escalation counts the sleep time. Decide if the escalation must count only awake time.
3. Approve the spec text changes in findings F3 and F9, and decide on finding F6.
4. A background session in a git repository must call `EnterWorktree` before it can edit a file (finding F4). Decide how Bifrost shows these worktrees. `claude rm` deletes the worktree and its branch.
5. The supervisor ended `bifrost-test-y` about 60 minutes after its last turn, with no `SessionEnd` event (finding F5). This differs from the M0 fact in spec 4 ("did not stop ... in 75 minutes"). Check this fact again.
6. Spec 2 makes each background session an owned session. So Bifrost writes a `quiet` file for your own background sessions too. While Bifrost runs, `claude attach` of such a session in Warp shows no statusline. This run did not test it, because none of your background sessions was active. Decide if this is correct.
7. Your statusline command (`sh ~/.claude/statusline-command.sh`) takes 655 ms for each run, with `refreshInterval` 1 (finding F8). This cost is in the `claude-statusline` project, not in Bifrost.
8. These files stay: `.m0-sandbox/m1-real-settings-backup.json` (git ignores it) and `~/.bifrost/` with two backups, the scripts, `statusline-original.json` and 14 session directories. Bifrost is not installed, so the scripts do not run.
9. The permission system refused nothing. The auto mode classifier gave no verdict one time. The same call worked at the second try.

## Spec rules that a result breaks

- Spec 6.2: "The script must finish in less than 50 ms." The median meets the rule (38 to 49 ms). The maximum is 96 to 106 ms at load average 10 to 15. An empty `sh` alone has a maximum of 85 ms. Smallest change: "The median time of the script is less than 50 ms. The script adds less than 20 ms to the start of an empty `sh`."
- Spec 11.1, item 3: "The dialog shows ... the backup path." The preview showed `settings-20261105T050720Z.json`. The install wrote `settings-20261105T052433Z.json`, because the name uses the time of the install. Smallest change: "3. The backup directory. The file name has the time of the install."
- Spec 7, rule 10 (reason text only): "an interactive session can report `idle` or `busy` at a prompt". M1 saw `waiting` for an interactive session at two permission prompts. The rule itself is still necessary for the yellow box (Stop hooks). Smallest change: delete "and an interactive session can report `idle` or `busy` at a prompt" from the reason.

## Findings that are not in a step

- **F1. Maintenance Sleep.** `pmset -g log` shows 7 periods of "Maintenance Sleep": 05:01:58 to 05:06:35, 05:07:21 to 05:23:43, 05:25:01 to 05:40:24, 05:41:10 to 05:56:43, 05:57:29 to 06:02:12, 06:02:57 to 06:18:13 and 06:18:58 to 06:34:02. Each "DarkWake" between them lasted about 45 s. The sleep explains the reply of `bifrost-test-y` (prompt at 05:25:03, reply at 05:40:27) and the slow commands. The `caffeinate -i` assertions of Claude Code did not stop this sleep. The run started `caffeinate -s -i -t 10800` (no display wake). It has effect from the wake at 06:34:02, and the Mac did not sleep after that time. All measurements in steps 10 to 14 come from after 06:34. After each wake, Bifrost and the sessions continued correctly.
- **F2. `manual` mode and read-only commands.** In `--permission-mode manual`, `date` ran with no prompt in a background and in an interactive session. `touch perm-check-<name>.txt` gave a prompt. M0 Q8 also used `touch`.
- **F3. Values of `status` and `waitingFor`.** Background permission prompt: `waiting` / `permission prompt`. Interactive permission prompt: `waiting` / `permission prompt` (`bifrost-test-ri2` and `bifrost-test-hi`). `AskUserQuestion` in a background session: `waiting` / `input needed`. Suggested addition to spec 4: "An interactive session at a permission prompt also reports `waiting`. An `AskUserQuestion` call gives `waitingFor` `input needed`."
- **F4. Worktree for edits in background sessions.** In `bifrost-test-h`, the Edit tool returned "This background session hasn't isolated its changes yet. Call EnterWorktree first". The session then called `EnterWorktree`. Claude Code made `.claude/worktrees/bubbly-nibbling-cascade` on the branch `worktree-bubbly-nibbling-cascade`, locked with "claude session ... (pid 72826)". The Branch column then showed `worktree-bubbly-nibbling-cascade`. `claude rm d75c0cb1` removed the worktree and the branch. The run removed only the two empty directories `.claude/worktrees` and `.claude`.
- **F5. A background session parked by itself.** `bifrost-test-y` finished its turn at 05:40:29. Its last status file write was at 06:41:02. Bifrost showed it as parked at 06:41:05. No `SessionEnd` event came, and the run sent no stop to it. Its transcript ends with `stop_hook_summary`, `turn_duration` and `cost-state`.
- **F6. The preview backup path.** See "Spec rules that a result breaks".
- **F7. No statusline while a dialog shows.** The status file did not change while a session showed a prompt or a question. `bifrost-test-q`: last write 06:02:30, question from 06:02:31. `bifrost-test-r2`: last write 06:35:15, prompt from 06:35:16. `bifrost-test-hi`: last write 06:38:25, prompt from 06:38:26. So the row keeps the cost and the context from before the prompt.
- **F8. Cost of the original statusline command.** See step 11.
- **F9. The 50 ms limit.** See step 12 and "Spec rules that a result breaks".
- **F10. Cmd+Q through CDP.** `agent-browser press Meta+q` did not quit Bifrost. CDP key events go to the page, not to the macOS menu. `osascript -e 'tell application id "com.github.Electron" to quit'` quit Bifrost in 1 to 2 s. Only Bifrost used that bundle ID (`lsappinfo`).

## Step 1. Skip mode

Method: `pnpm exec electron-vite dev --remoteDebuggingPort 9333`. `agent-browser connect 9333`, then a snapshot and a screenshot.

Result:

- The window was ready at 05:01:56. Screenshot: `m1-findings/01-skip-mode.png`.
- 10 rows: 5 external sessions of the user (4 `idle`, 1 `busy`) and 5 owned parked sessions (`backlog-loop-prs` two times, `backlog-loop-dry-run`, `backlog-loop-dry-run2`, `bifrost-test-idle`).
- No row had a box. The Model, Context, Cost and Last message columns were empty.
- The status line said "Not installed. Missing: hooks: SessionStart, ... StopFailure; status line wrapper; scripts."
- `~/.bifrost/active` existed: 0 bytes, mode 0600, made at 05:01. Before the start, `~/.bifrost` did not exist.

## Step 2. Single instance (F4)

Method: a second `pnpm exec electron-vite dev --remoteDebuggingPort 9334` at 05:07.

Result:

- The second dev process printed "DevTools listening on ws://127.0.0.1:9334" and then ended with code 0 at 05:07:07.
- Port 9333 still had one page. The first window stayed.
- `~/.bifrost/active` stayed, with the same time (05:01).

## Step 3. Install

Method:

1. `cp -p ~/.claude/settings.json .m0-sandbox/m1-real-settings-backup.json`.
2. `shasum -a 256`: `f3eca126085625ddd32f22c3b86ec417c71462f5862f3e4b9c6f9ecdc3b921a5` for both files. Size 3004 bytes, mode 0600.
3. Click "Preview install". Screenshot: `m1-findings/03-preview-install.png`.
4. Check the hash again (no change). Click "Install" at 05:24:33. Screenshot: `m1-findings/03-installed.png`.

The change list of the preview:

- "Add the hook for" SessionStart, SessionEnd, UserPromptSubmit, PreToolUse with the matcher AskUserQuestion, PermissionRequest with the matcher *, PostToolUse with the matcher *, Notification with the matcher permission_prompt, Notification with the matcher idle_prompt, Stop, StopFailure.
- "Change the statusLine command to the Bifrost wrapper."
- "Backup path: ~/.bifrost/backups/settings-20261105T050720Z.json".
- "Original command: sh ~/.claude/statusline-command.sh".

Result after the install:

- The panel said "Installed.". `integration.status()` gave `{"installed":true,"missingHooks":[],"scriptsCurrent":true,"scriptsPresent":true,"statusLineInstalled":true}`.
- New backup: `~/.bifrost/backups/settings-20261105T052433Z.json`, 3004 bytes, mode 0600, SHA-256 `f3eca126...b921a5` (the same bytes as the original).
- `settings.json`: 4918 bytes, mode 0600, SHA-256 `276c996b82339cc408c86c16465d491be888ce51ffacfa5dacec4fb4d9746c6f`.
- 10 hook rows run `~/.bifrost/bin/bifrost-hook`. The user's own `UserPromptSubmit` row stays as the first row of that event.
- `statusLine`: `{"command":"~/.bifrost/bin/bifrost-statusline","type":"command","refreshInterval":1}`. `refreshInterval` stays.
- `~/.bifrost/statusline-original.json`: `{"type":"command","command":"sh ~/.claude/statusline-command.sh","refreshInterval":1}`.
- Scripts: `bifrost-hook` 784 bytes, `bifrost-statusline` 2514 bytes, both mode 0755.
- Modes: `events` and `sessions` 0700. Event and status files 0600.

## Step 4. Hot reload (I7 item 6)

Method: a file watcher (`fs.watch` on `~/.bifrost`, read only) recorded each new file with a time stamp. It parsed each event file before Bifrost deleted it.

Result:

- 05:24:33.3: Bifrost wrote the scripts and the settings.
- 05:24:34.8 to 05:24:34.9: status directories for all 5 running interactive sessions (the user's 4 sessions and the controller). These sessions started 13 h to 1 d before.
- 05:24:35.07: the first event file, `PostToolUse` (Bash) of the controller session. A `Stop` event of that session followed at 05:24:39.
- So running sessions use the new hooks and the new statusLine at once, with no restart.
- After the uninstall at 06:43:04, the same occurred in the other direction. The last status file write was at 06:43:05. The tool calls of the controller after 06:43:04 made no event file.
- During the run, the watcher saw 249 event files. Bifrost read and deleted all of them. The event directory was empty at each check.

## Step 5. Yellow box (I4)

Method: `cl.sh --bg --model haiku --name bifrost-test-y "Reply with OK."` (ID `a96b0ead`). The debug view rows were read each 2 s with `agent-browser eval`.

Result:

- Events: `SessionStart` 05:25:02.8, `UserPromptSubmit` 05:25:03.1, `Stop` 05:40:29.2. The transcript has the reply "OK" at 05:40:27.0. The Mac slept during most of this time (finding F1). The two Stop hooks then took about 2 s.
- Rows from 05:40:35 to 05:40:46 (6 samples, 11 s): box `yellow flashing`, state `needs-you`, status `idle`, model Haiku 5.5, context 5%, cost $0.01, last message "OK". The box stayed. Screenshot: `m1-findings/05-yellow-box.png`.
- At 05:56:58 the box was red and flashing. The yellow box became red after 10 minutes (rule 4).
- Stop hooks in the user's `settings.json`: none. Stop hooks from plugins: one, `on-stop.sh` of `warp@claude-code-warp`. The `stop_hook_summary` of `bifrost-test-hc` lists `hookCount` 2: `~/.bifrost/bin/bifrost-hook` and `${CLAUDE_PLUGIN_ROOT}/scripts/on-stop.sh`.
- Also, `bifrost-test-r` (first run) showed `yellow flashing` with status `busy` at 06:02:36, after its `Stop` at 06:02:33.9. At 06:02:40 the row showed `yellow flashing` with status `idle`. A `busy` sample after the Stop did not remove the box. This is the I4 case.

## Step 6. Red box, background (I3)

Method, first run: `cl.sh --bg --model haiku --permission-mode manual --name bifrost-test-r "Run the shell command date."` (ID `5ebb0dc3`).

Result, first run: no prompt. `date` ran (`PostToolUse` Bash 06:02:29.1, `Stop` 06:02:33.9). The box was yellow (step 5). See finding F2.

Method, second run: `cl.sh --bg --model haiku --permission-mode manual --name bifrost-test-r2 "Run the shell command: touch perm-check-r2.txt"` (ID `3a0191bf`). Nobody answered the prompt.

Result, second run:

- Events: `SessionStart` 06:35:12.5, `UserPromptSubmit` 06:35:13.0, `PermissionRequest` (Bash) 06:35:16.5.
- `cl.sh agents --json`: `busy` at 06:35:13, then `status` `waiting`, `waitingFor` `permission prompt` from 06:35:16 to the quit of Bifrost at 06:41:55.
- Box: `red flashing` at 06:35:17 (status still `busy`). `red flashing`, `waiting`, `permission prompt` from 06:35:20 to 06:41:55. The box stayed for more than 6 minutes.
- Screenshot `m1-findings/06-08-red-boxes.png` (06:37:51) shows the red boxes of `q`, `r`, `h` and `y`. The `r2` row is below the visible area. The row trace above gives its values.

## Step 7. Red box, interactive (I3)

Method: a node-pty script (based on `scripts/m0/lib.ts`, `cleanEnv()`, cwd `.m0-sandbox`) started `claude --model haiku --name bifrost-test-<x> --permission-mode manual`. It typed the prompt with bracketed paste, waited 400 ms, and sent CR. It read `claude agents --json` each 1.5 s. It never answered a prompt. It ended the session with SIGTERM to its PID.

First run, `bifrost-test-ri`, "Run the shell command date.": no prompt. `busy` 0.6 s after the input, `idle` at 6 s. `date` ran (`PostToolUse` Bash 06:02:52.9, `Stop` 06:02:55.1). Then the Mac slept. After the wake, one `claude agents` call printed no JSON, and the script stopped. The PTY closed, and the session ended (`SessionEnd` 06:18:16).

Second run, `bifrost-test-ri2`, "Run the shell command: touch perm-check-ri2.txt":

- `kind` `interactive` at each sample.
- `busy` at 0.5 s after the input. At 3.9 s (06:35:37): `status` `waiting`, `waitingFor` `permission prompt`. The screen showed "Do you want to proceed?". No change for 60 s.
- Events: `PermissionRequest` (Bash) 06:35:38.0, `Notification` (permission_prompt) 06:35:44.0, `SessionEnd` 06:36:39.9.
- Box: `red flashing`, state `needs-you`, status `waiting` from 06:35:38 to 06:36:39. After the SIGTERM (exit code 143), the row was `parked` with no box at 06:36:40. Then the row left the list.

Extra case, `bifrost-test-hi` (step 12, `acceptEdits`): a `sed -i` command gave a prompt. `waiting` / `permission prompt` from 06:38:26 to 06:39:25. Box `red flashing` from 06:38:27 to 06:39:26.

## Step 8. AskUserQuestion (I3)

Method: `cl.sh --bg --model haiku --name bifrost-test-q "Use the AskUserQuestion tool to ask me to pick red or blue. Do nothing else."` (ID `a6b78b78`).

Result:

- Events: `SessionStart` 06:02:27.5, `UserPromptSubmit` 06:02:28.2, `PreToolUse` (AskUserQuestion) 06:02:31.0, `PermissionRequest` (AskUserQuestion) 06:02:31.4, `Notification` (permission_prompt) 06:02:37.2.
- `cl.sh agents --json`: `status` `waiting`, `waitingFor` `input needed` from the first sample (06:02:42) to the quit of Bifrost (06:41:55).
- Box: `red flashing` from 06:02:31 to 06:41:55 (39 minutes, also through the sleep).

## Step 9. Flash stop

Method: at 05:56:58 the `bifrost-test-y` row had a red, flashing box (escalated). `agent-browser click` on the row.

Result: the rows at 05:57:00, 05:57:02 and 05:57:04 show `box red` with no `flashing`. The box stays. Screenshot: `m1-findings/09-flash-stopped.png`.

## Step 10. Status files and the quiet marker

Method: `stat` of each `status.json` each 1 s for 30 s (06:35:36 to 06:36:07), with the Mac awake.

Result:

- `bifrost-test-y` (owned, background, not attached): 30 different mtimes in 30 samples. The wrapper runs about each 1 s for a session with no attached client. This answers the open statusline item of M0 question 2.
- `sessions/a96b0ead-.../quiet` exists: 0 bytes, mode 0600, made at 05:25. Bifrost also made `quiet` for `r`, `q`, `h`, `r2` and `hc`.
- The user's interactive sessions `0de03bfa`, `6fbb3984` and `ada7416a` (read only): 30 different mtimes each. They also update each 1 s (`refreshInterval` 1).
- The debug view shows model, context and cost. Examples: `bifrost-test-y` Haiku 5.5, 5%, $0.01. `claude-statusline-89` Opus 5.5, 20%, $5.42.
- The Age column shows 0 to 2 s for each session with a status file (review item M2).
- A session that shows a prompt or a question does not update its status file (finding F7).

## Step 11. Wrapper cost (I6, I7 item 5)

Method:

- Sample input: the real `status.json` of `claude-statusline-89` (1762 bytes).
- 20 rounds. Each round runs each case one time, through `/bin/sh -c` with the command text of the setting. So the cases share the load.
- `BIFROST_HOME` points to a scratch directory with its own `active` file. So the runs do not change the real `~/.bifrost`. The script text is the installed file.
- Load average 10 to 15.

| Case | Median | Min | Max |
|---|---|---|---|
| Wrapper, Bifrost runs (copy, then the original command) | 670 ms | 413 ms | 1321 ms |
| Original command alone (`sh ~/.claude/statusline-command.sh`) | 655 ms | 399 ms | 1016 ms |
| Wrapper, quiet session | 48 ms | 24 ms | 173 ms |
| Wrapper, Bifrost closed (no `active`) | 668 ms | 400 ms | 1388 ms |
| Empty `sh` (base cost) | 30 ms | 15 ms | 85 ms |

Result: the wrapper adds about 15 ms (median) to the original command. The wrapper printed the output of the original command in each round. The original command alone takes more than half of the 1 s interval (finding F8).

## Step 12. Hook cost (I1, I7 item 4)

Direct timing, with the same method as step 11:

| Case | Median | Min | Max |
|---|---|---|---|
| Hook, 1 KB input | 49 ms | 23 ms | 106 ms |
| Hook, 300 KB input | 38 ms | 19 ms | 96 ms |
| Hook, 300 KB input, Bifrost closed | 30 ms | 15 ms | 119 ms |

The cost does not grow with the input. The maximum is above 50 ms (finding F9).

Real session, first try: `bifrost-test-h` (background, auto mode) with the brief prompt. The test did not give a large payload:

- The Read of the 293 KB file failed: "File content (293KB) exceeds maximum allowed size (256KB)".
- The Edit failed until the session entered a worktree (finding F4). The worktree did not have `big.txt`, so no Edit occurred.
- Events: `PostToolUse` Read 06:02:37.4 (3 lines), EnterWorktree 06:02:46.2, Bash 06:02:50.2, Bash 06:02:54.8, `Stop` 06:02:59.2.

Real session, second try: `bifrost-test-hi` (interactive, `acceptEdits`) with 1200 lines. The Read failed: "File content (34807 tokens) exceeds maximum allowed tokens (25000)". The Edit failed, because all 4000 lines had the same text. The session then asked for `sed -i` (step 7, extra case).

Real session, third try: `big.txt` with numbered lines (4000 lines, 318,893 bytes). `bifrost-test-hi2` (interactive, `acceptEdits`): "Use the Read tool to read lines 1 to 600 of the file big.txt. Then use the Edit tool to change its first line to 'EDITED'. Then run the shell command 'wc -l big.txt'. Then run 'date'. Then run 'pwd'. Use one tool call for each step."

| Tool | Tool result in the transcript | Event file complete (watcher) | Event size | Next model step |
|---|---|---|---|---|
| Read (600 lines) | 06:40:18.861 | 06:40:18.869 | 48,796 B | 06:40:21.094 |
| Edit | 06:40:21.788 | 06:40:21.752 | 324,506 B | 06:40:23.212 |
| Bash `wc -l` | 06:40:23.577 | 06:40:23.583 | 825 B | 06:40:25.026 |
| Bash `date` | 06:40:25.254 | 06:40:25.262 | 836 B | 06:40:26.691 |
| Bash `pwd` | 06:40:27.314 | 06:40:27.315 | 852 B | 06:40:29.543 (reply) |

Result:

- The Edit event holds the full original file. It is the largest payload type. The Read tool limits its output to 25000 tokens.
- Each event file was complete within 8 ms of the tool result in the transcript. The Edit file was complete 36 ms before the transcript record.
- The time to the next model step is 1.4 to 2.2 s after each tool. It is the same after the 324 KB event and after the 825 B events. I saw no visible delay.
- The full turn took 14 s for 5 tool calls. `Stop` came at 06:40:29.6.

## Step 13. Hook with Bifrost closed (re-review Minor 2, I7 item 6)

Method:

1. `agent-browser press Meta+q` at 06:41:33. Bifrost did not quit (finding F10).
2. `osascript -e 'tell application id "com.github.Electron" to quit'` at 06:41:55. Bifrost quit in 2 s.
3. New background session `bifrost-test-hc` (ID `9c779ca6`): "Use the Read tool to read lines 1 to 5 of the file big.txt. Then reply with the first line only." The integration was still installed.

Result:

- `~/.bifrost/active` was gone after the quit. The event directory was empty.
- The session ran from 06:42:11 to 06:42:16. The Read ran at 06:42:14. The reply was "EDITED".
- The watcher saw no event file and no status file write after 06:41:55. The last status file writes of all sessions were at 06:41:55.
- `stop_hook_summary` in the transcript: `hookCount` 2, `hookErrors` `[]`. The plain text of `cl.sh logs 9c779ca6` has no "error". The footer showed "running Stop hooks… 0/2" and then "done".

## Step 14. Uninstall

Method: start Bifrost again (ready at 06:42:49, new `active` file). Check the hash of the installed file (`276c996b...`, no change). Click "Uninstall" at 06:43:03. Compare. Quit Bifrost with AppleScript.

Result:

- The panel said "Not installed. Missing: hooks: ...; status line wrapper." Screenshot: `m1-findings/14-uninstalled.png`.
- New backup: `settings-20261105T064304Z.json`, 4918 bytes (the installed file).
- `shasum -a 256`: `f3eca126085625ddd32f22c3b86ec417c71462f5862f3e4b9c6f9ecdc3b921a5` for `~/.claude/settings.json` and for the backup. Equal.
- `cmp`: the bytes are equal.
- `diff <(jq -S . settings.json) <(jq -S . backup)`: equal.
- Mode 0600 and size 3004 bytes stay. Only the mtime changed (06:43).
- The restore did not need the backup copy.
- Bifrost quit in 1 s at 06:43:27. `~/.bifrost/active` was gone.

## Step 15. Clean up

Method: for each entry of `cl.sh agents --json --all` with a name that starts with `bifrost-test-`, the loop read the list again, checked the name and the count, then ran `cl.sh stop` (only with a `pid`) and `cl.sh rm`.

Result:

- Stopped and removed: `bifrost-test-r`, `bifrost-test-q`, `bifrost-test-h`, `bifrost-test-r2`, `bifrost-test-hc`.
- Removed (already parked): `bifrost-test-y`, `bifrost-test-idle`.
- `claude rm d75c0cb1` also removed the worktree `.claude/worktrees/bubbly-nibbling-cascade` and its branch.
- The interactive sessions `ri`, `ri2`, `hi` and `hi2` ended in the run (SIGTERM, exit code 143, or the end of the PTY).
- After the clean-up, `--all` lists no `bifrost-test-` entry.
- Removed: `.m0-sandbox/big.txt` and the empty directories `.claude/worktrees` and `.claude`. The prompts in steps 6 and 7 got no answer, so no `perm-check-*.txt` files exist.
- `~/.bifrost/` stays as it is.
