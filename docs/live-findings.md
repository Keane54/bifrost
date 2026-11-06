# Bifrost Live details findings

## Task 9: Live details checks with real test sessions

A check agent ran Task 9 on 2026-11-06 from 00:57 to 01:15 GMT. The code was branch `live` at `94f122b`. The versions were Claude Code 2.1.318, Electron 44.7.2, Node 26.8.1 and macOS 26.6.2.

### Method

- The agent started the dev app in the worktree with its own userData in the scratch folder: `pnpm exec electron-vite dev -- --user-data-dir=<scratch>/userdata --remote-debugging-port=9333`. Part A set `BIFROST_LIVE_LISTEN=1`. Part B did not set it.
- The agent drove the page with `agent-browser` over port 9333 (`snapshot -i`, `click`, `eval` and `screenshot`). It read the status with `window.bifrost.live.status()` and the rows with `window.bifrost.registry.rows()`.
- A small recorder in the page subscribed to `window.bifrost.registry.onUpdate`. It kept each change of a `bifrost-test-` row with the time of the update (`Date.now()` of the page). The step times below come from this record. The agent added the recorder again after each start of the app.
- The agent copied the four `MOD_FILES` to `.m0-sandbox/live-check/bifrost-live/`. In Part A, the sessions loaded the mod only with `--plugin-dir` on that copy. Claude Code wrote `tsconfig.json` and `.claude-plugin/types` into that copy, not into the repository.
- Each `claude` command of the agent went through `.m0-sandbox/cl.sh`, with `--model haiku`, in `.m0-sandbox`. Before each stop, rm and respawn, the agent read the list of `cl.sh agents --json --all` again and checked the `bifrost-test-` prefix.
- The interactive session `bifrost-test-li` ran in a `TestPty` of `scripts/m0/lib.ts`, with `M0_CLAUDE=.m0-sandbox/cl.sh`. A driver script in the scratch folder read one command at a time from a file. `TestPty.write` checks the name and the PID before each input.
- The agent quit the dev app with SIGTERM to its own Electron main PID. It found the PID from the command line with the scratch userData path. The `electron-vite` parent then stopped by itself. The agent did not use `osascript`.

Changes to the method:

- The driver imported `lib.ts` from the main checkout (`/Users/dev-user/Developer/bifrost/scripts/m0/lib.ts`). The file has the same bytes as the worktree copy. In the worktree copy, `SANDBOX` points to `.worktrees/live/.m0-sandbox`, and that folder does not exist.
- The first driver run stopped at 01:00:05. The `echo` of zsh changed the backslashes of a command line, and the parse error ended the driver. The first `bifrost-test-li` session (`356adabe`, no message) ended with the driver. The agent added a parse guard, wrote the commands with `printf`, and started `bifrost-test-li` again (`20d8dd37`). This second session did all of Step 4 and Step 6.
- For the Esc of Step 4a, the driver started the name check at the Enter. It sent Esc only after the check passed and the line `12` showed on the screen. The check passed 0.7 s after the Enter. The Esc went 3.3 s after the Enter.
- The brief gives no prompt for `bifrost-test-lo` and no names for the new sessions of Step 12. The agent used `bifrost-test-lo` with `Reply with OSCAR.`, `bifrost-test-ld` with `Reply with FOXTROT.` (after Turn off) and `bifrost-test-le` with `Reply with GOLF.` (after Turn on).
- The first clean-up loop ran under zsh, and zsh did not split the list of IDs. The name check refused the joined text, so no command ran. The agent then ran the same loop with bash.

### Results

| Step | Method | Result | Screenshot |
|---|---|---|---|
| 1. Socket | Start the app with `BIFROST_LIVE_LISTEN=1`. Read the socket and `live.status()`. | Pass. `~/.bifrost/live.sock` has mode `srw-------`, in `~/.bifrost` with mode `drwx------`. The status is `listening: true`, `plugin: 'not-installed'`, `oldInstall: false`, `versionOk: true`. As expected, the start removed `active`, `events/`, `sessions/` and `bin/` from `~/.bifrost`. | `live-findings/step1-integration.png` |
| 2. Yellow box | `cl.sh --bg --plugin-dir <copy> --model haiku --name bifrost-test-la "Reply with exactly the word ALPHA."` | Pass. The yellow box came 6.9 s after the start command. `boxSince` is 2,138 ms earlier than the first row update with `status: 'idle'`. The row has `live: true`, Last message `ALPHA`, model `Haiku 5.5`, context 5% and cost 0.0042 USD. The Selected Item panel shows `Haiku 5.5`, `5%`, `$0.00` and `ALPHA`. | `live-findings/step2-yellow-la.png`, `live-findings/step2-selected-la.png` |
| 3. Red box | `bifrost-test-lp` with `--plugin-dir <copy> --permission-mode manual` and `Run the shell command: touch perm-check-lp.txt`. No answer. | Pass. The red box (`boxReason: 'prompt'`) came 4.1 s after the start command. `boxSince` is 901 ms earlier than the first row update with `status: 'waiting'`. No `perm-check-lp.txt` file exists. | `live-findings/step3-red-lp.png` |
| 4a. Esc | `TestPty` session `bifrost-test-li` with `--plugin-dir <copy>`. `Count from 1 to 300, one number on each line.`, then Esc. | Pass. Claude Code shows `Interrupted`. The row is `idle`, with no box. Last message has the first numbers (`1` to `23`). | - |
| 4b. Question | `Use the AskUserQuestion tool to ask me to pick red or blue. Do nothing else.`, then Enter on `1. Red`. | Pass. The red box came 2.0 s after the prompt. It is 1,100 ms earlier than the poll `waiting` (`input needed`). The box went away 65 ms after the Enter. The yellow box came 1.9 s after the Enter, with Last message `You picked red.`. | `live-findings/step4b-red-ask-li.png` |
| 4c. Reload | `/reload-plugins` while the yellow box shows. | Pass. Claude Code shows `Reloaded: 13 plugins · 96 skills · 8 agents · 15 hooks · 5 plugin MCP servers · 1 plugin LSP server`. The row did not change in the next 60 s. The yellow box stayed. | - |
| 4d. Clear | `/clear`, then `Reply with BRAVO.` | Pass. The session ID changed from `20d8dd37` to `0e1cf81f`. The old row parked 65 ms after the `/clear`. The row of `0e1cf81f` got the yellow box 3.1 s after the prompt, with Last message `BRAVO.`. See observation 1. | `live-findings/step4d-clear-li.png` |
| 5. Heartbeat | SIGTERM to the app (01:04:46). Start it again (01:04:54). Read the row of `bifrost-test-la` each second. | Pass. The idle row showed `live: true`, `Haiku 5.5`, 5% and 0.0042 USD 18.0 s after the start command (12.5 s after the debug port answered). Before that, the row had no model and no cost. The rows of `bifrost-test-lp` and `bifrost-test-li` were live too. | `live-findings/step5-heartbeat.png` |
| 6. Bifrost closed | SIGTERM to the app (01:05:44). In `bifrost-test-li`, `Reply with CHARLIE.`. | Pass. `CHARLIE.` and the end of the turn showed within 1.8 s of the Enter. The screen shows no error line. The new PTY output has no `ENOENT`, `ECONNREFUSED`, `hook error` or `rror`. `rg -n "bifrost-live\|ENOENT\|ECONNREFUSED\|hook error"` on the transcript `0e1cf81f-...jsonl` gives no match. | - |
| 7. Poll-only yellow | Start the app. `cl.sh --bg --model haiku --name bifrost-test-lq "Reply with DELTA."` with no `--plugin-dir`. | Pass. The poll showed `busy`, then `idle`. The yellow box came with the `idle` sample, 10.5 s after the start command. The row has no `live`, no model and no cost. | `live-findings/step7-poll-yellow-lq.png` |
| 8. Hashes | `shasum -a 256` before Part A (00:57) and after Part A (01:06). | Pass. The three values did not change. See "SHA-256 values". | - |
| 9. Before | Start the app without `BIFROST_LIVE_LISTEN`. Read `live.status()`. Copy the three files. Start `bifrost-test-lo` (no `--plugin-dir`). Read the `bg-spare` processes. | Pass. The status is `oldInstall: false`, `listening: false`, `plugin: 'not-installed'`. The backups are in `.m0-sandbox/live-real-backup/`. `bifrost-test-lo` took the spare process 66802, which started at 01:06:34. | - |
| 10. Install | Click Install (01:08:13). | Pass. The panel showed the result 6.8 s after the click, with the reload note. `~/.bifrost/mod` has the four files with the same bytes as `resources/live-mod/` (folders 0700, files 0600). `plugin list` shows `bifrost-live@bifrost-local`, `enabled: true`, `scope: user`, `readFromFolder` `/Users/dev-user/.bifrost/mod`. `marketplace list` shows `bifrost-local`, `source: directory`, with that path. The status is `listening: true`, `plugin: 'enabled'`, `modCurrent: true`. | `live-findings/step10-install.png` |
| 11. Spike step 3 | Watch `bifrost-test-lo` for 40 s. `cl.sh respawn 0e10e1c4`. Start `bifrost-test-lc` with `Reply with ECHO.` (no `--plugin-dir`). | Pass. `bifrost-test-lo` sent no line before the respawn. After the respawn it took the spare process 1275, and it sent lines 3.7 s after the respawn command. The spare 1275 started at 01:07:40, before the install at 01:08:16. `bifrost-test-lc` was live 2.6 s after its start command, and it got the yellow box with `ECHO`. See observation 6. | - |
| 12. Turn off and Turn on | Click Turn off (01:10:46). Start `bifrost-test-ld`. Click Turn on (01:11:59). Start `bifrost-test-le`. | Pass. Turn off took 3.6 s. The socket is gone, `plugin list` shows `enabled: false`, and the status is `listening: false`. `bifrost-test-ld` sent no line in 45 s. It got the poll yellow box. Turn on took 3.6 s. The socket is back, `enabled: true`, `listening: true`. `bifrost-test-le` was live 2.9 s after its start command. Its spare process started at 01:11:00, while the plugin was off. | `live-findings/step12-turn-off.png`, `live-findings/step12-turn-on.png` |
| 13. Remove | Click Remove (01:12:36). Compare the files with the backup. | Pass. The status showed `not-installed` less than 4 s after the click. `plugin list` has no `bifrost-live`. `marketplace list` has no `bifrost-local`. `~/.bifrost/mod` and the socket are gone. The status is `plugin: 'not-installed'`, `listening: false`. `jq -S` of `settings.json` is the same as the backup, and the SHA-256 is the same. `installed_plugins.json` has the same SHA-256. `known_marketplaces.json` has one difference, see "Settings after Remove". | `live-findings/step13-remove.png` |
| 14. Clean up | Exit `bifrost-test-li` with `/exit`. For each `bifrost-test-` entry: read the list again, check the name, `cl.sh stop` (with a PID), then `cl.sh rm`. | Pass. See "Clean-up". | - |

### Settings after Remove

- `~/.claude/settings.json`: no difference. The SHA-256 is the same as before Part A.
- `~/.claude/plugins/installed_plugins.json`: no difference. The SHA-256 is the same.
- `~/.claude/plugins/known_marketplaces.json`: one difference. `claude-plugins-official.lastUpdated` changed from `2026-11-06T01:07:19.333Z` (the backup) to `2026-11-06T01:12:04.117Z`. Claude Code writes this value when it updates the official marketplace. The value also changed between Step 8 (01:06) and Step 9 (01:07:19). Bifrost does not write this value. The `bifrost-local` entry is gone.
- Claude Code kept the folder `~/.claude/plugins/cache/bifrost-local/bifrost-live/1.0.0` (the four files and a `.orphaned_at` file of 01:12:38). See "For the user".

### SHA-256 values

| File | Before Part A (00:57) | After Part A (01:06) | Backup, before Part B (01:07) | After Remove (01:13) |
|---|---|---|---|---|
| `settings.json` | `f3eca126...b921a5` | `f3eca126...b921a5` | `f3eca126...b921a5` | `f3eca126...b921a5` |
| `installed_plugins.json` | `bc14400d...185764` | `bc14400d...185764` | `bc14400d...185764` | `bc14400d...185764` |
| `known_marketplaces.json` | `36b5b565...908913` | `36b5b565...908913` | `c5cde47a...94b8c5` | `983c9bd1...0bb9ab` |

### Bugs found

The agent found no bug in Live details. Each check step passed.

Observations (not bugs; each one agrees with the spec or comes from Claude Code):

1. After `/clear`, the row of the new session ID had no `live` flag, no model, no context and no cost for 6.3 s, until the next prompt. No line came for the new ID before `turn.start`. So the mod does not send `session.start` for the new ID at `/clear`. The model came with the usage line after the turn. Without a new prompt, the 30 s heartbeat gives the usage.
2. The Selected Item panel shows a cost below 0.005 USD as `$0.00` (Step 2: 0.0042 USD).
3. A row stays live for 90 s after its last line (D9, spec times). After Remove, the panel showed `Listening: no` and `Live sessions: 6`.
4. The Integration panel reads the status only at the start and after an action. So `Live sessions: 0` stayed on the panel while one session was live. The panel shows `Claude Code version` two times. This is the debug panel, and M5a owns the real UI.
5. The first poll sample of a new background session has `status: ''`. For `bifrost-test-lo` the row state was `parked` for 2.2 s, and after the respawn for 0.6 s. For `bifrost-test-lq` and `bifrost-test-le` it was `idle`.
6. A background session reads the plugins when it takes a `bg-spare` process, not when the spare process starts. Proof: after the respawn, `bifrost-test-lo` loaded the mod in a spare that started before the install. `bifrost-test-le` loaded the mod in a spare that started while the plugin was off. So the spare processes do not delay Live details for new background sessions on 2.1.318. A session that runs at the install time still needs `/reload-plugins`, a respawn or a restart.
7. The rows of sessions that `cl.sh rm` removed stay in the app as parked rows. This is M4 bug 3 of Task 17.

### For the user

- No new session of yours started while the mod was installed (01:08:16 to 01:12:38). Your 5 open sessions started on 2026-11-03 and 2026-11-04. The agent ran no input and no `/reload-plugins` in them.
- Claude Code kept `~/.claude/plugins/cache/bifrost-local/bifrost-live/1.0.0` after the uninstall, with a `.orphaned_at` marker. Claude Code removes orphan caches later. If it stays, you can delete the folder `~/.claude/plugins/cache/bifrost-local`.
- The backups stay in `.m0-sandbox/live-real-backup/` (`settings.json`, `installed_plugins.json`, `known_marketplaces.json`, mode 600). Only `known_marketplaces.json` differs from the live file, by the one `lastUpdated` value.
- The Live build removed `~/.bifrost/active`, `events/`, `sessions/` and `bin/` at its first start (Task 7 ruling). It also changed the mode of `~/.bifrost` from 755 to 700. `backups/`, `run/` and `statusline-original.json` stay.
- Decide the cost format for a cost below one cent (observation 2). M5a owns this text.
- A process `bash .../T/bifrost-scripts-mT4ddt/wrapper.sh` (PID 99174) runs since 2026-11-05 03:23. It is not from this check. The agent did not touch it.
- These transcripts stay in `~/.claude/projects/-Users-dev-user-Developer-bifrost--m0-sandbox`: `7d1e9fad`, `74d0799d`, `20d8dd37`, `0e1cf81f`, `ba4f211d`, `0e10e1c4`, `63df3fdd`, `6d81ed71`, `ce3490dc`. The first `bifrost-test-li` (`356adabe`) has no transcript.

### Answers of the user (O1 to O4)

- O1 (user-scope install test): yes. Part B ran with backups, SHA-256 values and no `/reload-plugins` in your sessions.
- O2 (`/plugin` check): `cc-plugin-sec-default` is not listed. The guard does not apply. In Step 3, `classic.PermissionRequest` gave the red box 901 ms before the poll.
- O3 (poll-only yellow box): yes. Step 7 and the `bifrost-test-ld` row of Step 12 show it.
- O4 (statusline in chat windows): option a. Bifrost adds the `--settings` statusLine override only on a new start. This check did not start a session from Bifrost.

### Clean-up

- `cl.sh agents --json --all` has no `bifrost-test-` entry. The agent stopped and removed `bifrost-test-la`, `-lp`, `-lq`, `-lo`, `-lc`, `-ld` and `-le` after a name check. `bifrost-test-li` ended with `/exit` (exit code 0). The first `bifrost-test-li` ended with the first driver run.
- The agent removed `.m0-sandbox/live-check/` and the scratch userData. No `.m0-sandbox/perm-check-lp.txt` file exists, because the prompt got no answer.
- No dev app process, no `electron-vite` process and no driver process runs. `~/.bifrost` has no socket and no `mod` folder.
- `git worktree list` has only the main checkout, `.worktrees/live` and `.worktrees/m3`. `git status` of the main checkout is clean. `.m0-sandbox` is not a repository (git ignores it in the main checkout).
