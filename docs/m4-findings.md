# Bifrost M4 findings

## Task 1: worktree, slash form, terminal launch

Questions:

- Does `claude --bg --worktree <name>` work in a trusted repository (spec 8.9)?
- Does a slash command work as a bracketed paste, or only as typed text (spec 8.4)?
- Does each terminal app run a `.command` file with `claude attach <id>` (spec 9.1, Open in terminal)?
- Which permission modes does `claude --help` give?

The experiment agent ran `scripts/m4/probe.ts` on 2026-11-05 in two runs. Run 1 (Part A) started at 08:36:07 GMT and took 26 s. Run 2 (Parts B and C) started at 08:36:46 GMT and took 47 s. The environment variable `M4_PARTS` selects the parts. The versions were Claude Code 2.1.318 and macOS 26.6.2. The Mac had a high load (load average 9.3 to 10.8). The screen was locked.

Commands, in the main checkout:

```bash
M4_PARTS=A M0_CLAUDE=/Users/dev-user/Developer/bifrost/.m0-sandbox/cl.sh \
  M0_OUT="$TMPDIR/bifrost-m4" ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m4/probe.ts
M4_PARTS=B,C M0_CLAUDE=/Users/dev-user/Developer/bifrost/.m0-sandbox/cl.sh \
  M0_OUT="$TMPDIR/bifrost-m4" ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m4/probe.ts
```

Both runs ended with exit code 0. The raw results are in `$TMPDIR/bifrost-m4`:

- `probe.json`: the two runs together, and the full help lines of Step 3.
- `probe-A.json` (run 1) and `probe-BC.json` (run 2).
- `probe-slash.raw`, `probe-slash.screen.txt`: the attach PTY of Part B.
- `m0.log`, `started.jsonl`, `values.jsonl`: the `lib.ts` records.

Safety:

- Each `claude` call went through `.m0-sandbox/cl.sh`. All sessions used `--model haiku` and the directory `.m0-sandbox`.
- `assertTestTarget` checked the test session before each write and before each `open -a`.
- No trust prompt showed. The script accepted no prompt.
- The script sent SIGHUP to 3 processes only. The first was its own attach PTY of Part B. The other two were the `claude attach e5d4c91b` clients of Part C. For each Part C client, the script checked the exact command line, that the PID was not in the process table before the `open` call, and that the start time was after the `open` call. It checked these values again just before the signal.
- The script closed no window and no tab.

Changes to the plan method:

- Two runs, not one. Run 1 let the agent check the worktree clean-up before Part C opened terminal windows.
- The waits are longer because of the load: 180 s for an entry, 30 s for the attach process, and 15 s of name reads (each 1 s) after a `/rename`. The rulings use the limits of the plan (60 s and 10 s). All values were well inside these limits.
- Before B2, the script waits until the status is `idle`. B1 did not start a turn, so this wait ended in 0.4 s.

### Part A: the worktree flag

Before Part A, `/Users/dev-user/Developer/bifrost/.claude` did not exist. `git worktree list` gave the main checkout and `.worktrees/m2`. No branch matched `worktree-bifrost-test-*`.

| Step | Method | Result | Delay |
|---|---|---|---|
| 1. Start | `claude --bg --worktree bifrost-test-wt --model haiku --name bifrost-test-wt "Reply with the word READY."` | Exit code 0. Stdout `backgrounded · b2287433 · bifrost-test-wt` and the 4 hint lines. Stderr `Starting background service…`. No trust error. | The command took 4.3 s. |
| 2. Entry | `watchEntry` until the entry has a `pid`. | `cwd` `/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-wt`, `pid` 8105, `status` `busy`, `state` `working`, `name` `bifrost-test-wt`. The status was `idle` 4.1 s later. The transcript has the reply `READY`. | The entry showed without a `pid` after 1.2 s, and with the `pid` after 3.2 s. |
| 3. Git | `git -C <cwd> rev-parse --abbrev-ref HEAD` and `git worktree list --porcelain`. | `HEAD` is `worktree-bifrost-test-wt`. `--show-toplevel` gives the worktree path. The worktree list has a new worktree at that path, with the branch `refs/heads/worktree-bifrost-test-wt` and the commit `4f7ff02` (the `HEAD` of `main`). | - |
| 4. Stop and rm | `stopTest`, then `rmTest`. Then a wait of 3 s. | Stop: exit code 0, `stopped b2287433`, `worktree retained at /Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-wt`, `run 'claude rm b2287433' to remove worktree and job state`. Rm: exit code 0, `removed b2287433`, `worktree: “/Users/dev-user/Developer/bifrost/.claude/worktrees/bifrost-test-wt”`. After the wait, `git worktree list` gave only the main checkout and `.worktrees/m2`. No `worktree-bifrost-test-*` branch stayed. | Stop 0.9 s. Rm 2.7 s. |

After step 4, the script removed the two empty directories that Part A made: `.claude/worktrees` and `.claude`. No `git worktree remove` and no `git branch -D` was necessary. Claude Code keeps the transcript directory `~/.claude/projects/-Users-dev-user-Developer-bifrost--claude-worktrees-bifrost-test-wt`, as for each test session.

Facts for Task 4:

- The worktree goes in `<git root>/.claude/worktrees/<name>`, not in the start directory. The entry `cwd` is the root of the worktree. Git ignores `.m0-sandbox`, so the worktree does not have that directory.
- The worktree starts at the `HEAD` of the current branch of the git root.
- `claude stop` keeps the worktree and prints its path. Only `claude rm` deletes the worktree and the branch. This agrees with D5.

### Part B: the slash command form

Test session: `bifrost-test-slash`, id `e5d4c91b`, PID 23332. It was `idle` 5.2 s after the start command ended. The attach PTY had the size 120 x 32. Its output was quiet for 1.5 s, 2.9 s after the spawn.

| Step | Method | Result | Delay |
|---|---|---|---|
| B1 | Write `ESC[200~/rename bifrost-test-slash2ESC[201~`. Wait. Write CR. | The name changed to `bifrost-test-slash2`. The title of the prompt box showed the new name. The prompt was empty after the command. | The first name read after the CR gave the new name, 0.5 s after the CR. |
| B2 | Write `ESC[200~/contextESC[201~`. Wait. Write CR. | The command ran as a slash command. The screen showed the context table (for example `Free space: 920.8k (92.1%)` and `/context all to expand`). The transcript got one meta user message that starts with `## Context Usage`. The model gave no reply. | The output was quiet 1.9 s after the CR. |
| B3 | Typed text, 500 ms, CR. | Not run, because B1 changed the name. | - |

Limit: the gap from the end of the paste to the CR was 665 ms in B1 and 737 ms in B2, not 300 ms. `TestPty.write` checks the target before each write, and each check took 370 to 430 ms. M0 Q5 showed that the 300 ms gap works for usual text. Task 10 must check Run slash command and Rename in the app with the 300 ms gap.

After B2, the script closed its attach PTY with SIGHUP. The client ended with signal 1. The session stayed for Part C.

### Part C: the terminal launch

The file `$TMPDIR/bifrost-m4/bifrost-test-attach.command` had the mode 0700 and this text:

```sh
#!/bin/sh
exec /Users/dev-user/Developer/bifrost/.m0-sandbox/cl.sh attach e5d4c91b
```

The walk goes from the attach process to its parents (`scripts/m0/terminal-of.ts`).

| App | Method | Result | Delay |
|---|---|---|---|
| Warp | `open -a /Applications/Warp.app <file>` at 08:37:09 GMT. Exit code 0 in 64 ms. Warp was running. | Warp ran the file in a new tab or window. A new shell `-zsh -g --no_rcs` (PID 31966) started at 08:37:09. It ran `/bin/sh <file>` (seen at 2.3 s). The `exec` then gave `claude attach e5d4c91b` (PID 32944). Walk: `claude` 32944, `-zsh` 31966, Warp `stable` 931, Warp `stable` 866, PID 1. The walk gives Warp. The outermost `.app` also gives Warp. After SIGHUP, the attach process ended in 6 ms. The shell 31966 still runs, so the tab shows a shell prompt. | 2.8 s |
| Ghostty | `/Applications/Ghostty.app` does not exist. | Not installed. | - |
| iTerm2 | `/Applications/iTerm.app` does not exist. | Not installed. | - |
| Terminal | `open -a /System/Applications/Utilities/Terminal.app <file>` at 08:37:22 GMT. Exit code 0 in 95 ms. Terminal was not running. It started as PID 37646. | `claude attach e5d4c91b` (PID 38030) started. Walk: `claude` 38030, `-zsh` 37885, `login` 37856, Terminal 37646, PID 1. The walk gives Terminal. The outermost `.app` also gives Terminal. After SIGHUP, the attach process ended in 7 ms. The shell and `login` also ended. Terminal has no child process now. | 1.1 s, with the start of the app |

Neither app showed a dialog that stopped the launch. The screen was locked, so the agent could not see the windows. "No dialog" means only this: `open` gave no error, and the attach process started.

Facts for Task 5:

- Warp runs the file in a new shell of its own and keeps that shell after the attach ends. Terminal runs the file in a login shell and ends that shell after the attach ends.
- For both apps, the first parent with `.app/` and the outermost `.app` give the correct app. The Warp walk has two Warp `stable` processes.

### Permission modes

The full lines of `cl.sh --help` (Step 3):

```text
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  -w, --worktree [name]                 Create a new git worktree for this
                                        session (optionally specify a name)
```

The `--tmux` line also names the worktree: `Create a tmux session for the worktree (requires --worktree)`.

### Rulings

**Worktree ruling:** yes. Exit code 0. The entry had a `pid` after 3.2 s. Its `cwd` ends with `.claude/worktrees/bifrost-test-wt`. Its branch is `worktree-bifrost-test-wt`. After `claude rm`, no worktree and no branch stayed. Task 4 sets `WORKTREE_OK` to `true`.

**Slash form ruling:** paste. B1 changed the name to `bifrost-test-slash2`. B2 ran `/context` as a slash command. Task 2 sets `SLASH_FORM` to the paste form.

**Terminal launch ruling:** warp command-file, ghostty clipboard, iterm2 clipboard, terminal command-file. Ghostty and iTerm2 are not installed. Task 5 sets `LAUNCH`.

**Permission modes:** `acceptEdits`, `auto`, `manual`, `dontAsk`, `plan`. Task 4 sets `PERMISSION_MODES`.

### Spec text for the controller

- 8.9: replace "The worktree option needs a test in a trusted repository (M4)." with "M4 test (2026-11-05): `--worktree <name>` works in a trusted repository. See `docs/m4-findings.md`."
- 8.4: no change. The ruling is "paste".
- 9.1: no change. Warp is "command-file".

### Windows and tabs that the test left open

The user can close these:

- Warp: one new tab or window, opened at 08:37:09 GMT. It shows a zsh prompt (PID 31966).
- Terminal: Terminal.app started at 08:37:22 GMT (PID 37646) and opened one window. The shell of that window ended. The window can show "[Process completed]". Terminal.app still runs. If Terminal opens old windows again when it starts, more windows can show. The agent could not check this.

### Clean-up

- `cl.sh agents --json --all` after the runs: 9 entries, and no entry starts with `bifrost-test-`.
- `git worktree list`: the main checkout and `.worktrees/m2` only. `git branch --list`: `m2` and `main`. `/Users/dev-user/Developer/bifrost/.claude` does not exist.
- No `claude attach e5d4c91b` process runs.
- These files stay: the output in `$TMPDIR/bifrost-m4` (also the `.command` file), and the transcripts of the two test sessions in `~/.claude/projects`.
- Each start printed `Starting background service…` on stderr. So `cl.sh` started the shared background service each time, with the clean environment. `cl.sh` expects this.

## Task 10: action checks

The controller agent ran the app check on 2026-11-05 from 16:03 to 16:56 GMT. The code was branch `m4` at `a275a6e`. The versions were Claude Code 2.1.318, Electron 44.7.2 and macOS 26.6.2.

### Method

- The agent started the dev app with its own userData: `pnpm exec electron-vite dev -- --user-data-dir=<scratch>/m4-check/userdata --remote-debugging-port=9333`. `registry.json` and `ui-state.json` appeared in that folder. The mtimes of the real Bifrost userData files and of `~/.claude/settings.json` did not change during the run.
- The agent drove the page with `agent-browser` over port 9333. It used clicks, key presses, mouse moves, `eval` reads of the DOM and of `window.bifrost`, and screenshots. For the held Enter it sent CDP key events with `autoRepeat` from a small scratch script.
- Before each action, the agent read the row ID and the name in the Selected Item panel, the menu or the dialog title. It checked the `bifrost-test-` prefix.
- Each `claude` command went through `.m0-sandbox/cl.sh`. All sessions used Haiku and the folder `.m0-sandbox`.
- The agent quit the dev app with SIGTERM to its own Electron main PID, not with `osascript`. The app removed `~/.bifrost/active` at each quit. The agent wrote the marker again (0 bytes, mode 600) each time.
- The Bifrost integration is not installed in `~/.claude/settings.json`. So no hook runs. The red box came from the `waiting` status of `claude agents`. The reply preview and the model need the hooks, so they do not show.

Changes to the plan method:

- The agent renamed `bifrost-test-m4b` by error to a name of 64 `a` characters (session `d64bb329`). Its key press for select-all did not work, and the field kept 64 characters. The rename itself worked in 4.2 s. After that, the name had no `bifrost-test-` prefix, so the agent sent nothing more to that session. A new session `bifrost-test-m4c` (renamed to `bifrost-test-m4c2`) took the part of `m4b2` in Steps 5, 6, 11 and 12.
- Take control failed for `bifrost-test-m4ext` and `bifrost-test-m4ext2`, which had no message (bug 3). The agent started `bifrost-test-m4ext3` with a first prompt for the pass test and for Step 12.

### Results

| Check | Method | Result | Screenshot |
|---|---|---|---|
| Step 1: send box, hidden attach | Select m4a with no chat window. Send `Reply with the word ONE.`. Read `ps` each 1 s and `stty -f /dev/ttys005 size`. | Pass. The session replied `ONE.`. No `claude attach` ran 5 s after the send. The size stayed 50 x 200. The Working state shows in Steps 5 and 6. | - |
| Step 1: reply preview | Read `lastMessage` of the row. | For the user. The preview needs the Stop hook. The integration is not installed. | - |
| Step 2: send box, chat path | Open the m4a chat. Type two lines with Shift+Enter. | Pass. One message with two lines. One `claude attach c51397d9`, child of the dev main PID. | `m4-findings/t10-03-send-two-lines.png` |
| Step 3: Run slash command | Menu > Run slash command > `/context`. | Pass. The context view showed. `ui-state.json` has `/context` in `recentSlash`. The submenu shows it once, under the favourites, because the recent part skips favourites. `/cost` from the send box also went into the list. `/rename` did not. | `m4-findings/t10-04-slash-context.png` |
| Step 3: Other... | Menu > Run slash command > Other.... | Pass. The send box has the focus, the text `/`, the caret at the end, and the line `This runs as a slash command.`. | - |
| Step 3: Rename | Menu > Rename... on m4c. Enter `bifrost-test-m4c2`. | Pass. The new name showed 3.6 s after Enter (m4b: 4.2 s). The field starts with the name and takes 64 characters. An empty name shows `Type a name first.`. Esc closes the dialog. | `m4-findings/t10-11-dialog-rename.png` |
| Step 4: red box | Start m4r with `--permission-mode manual` and the `touch` prompt. | Pass. Red box and Needs you. The send box is at 40% with `Answer the prompt in the chat window first.`. Send message, Run slash command and Rename are off with that text in the tooltip. Interrupt is on. The agent did not answer the prompt. `/cost` gave the same red box on m4a, and Interrupt closed the panel. | `m4-findings/t10-05-red-box.png` |
| Step 5: Interrupt | Send a count to 300 to m4c2. Click Interrupt two times in 220 ms. | Pass. The chat shows `Interrupted` and no rewind menu. | `m4-findings/t10-06-interrupt.png` |
| Step 6: busy session | Send a count to 300, then `Reply with TWO.` at once, with no chat window. | Pass. The second text waited and went in after the turn. The hidden attach ended after the send. | - |
| Step 6: 15 s reason | Send a count to 2500, then `Reply with the word LATE.`. | Pass. After 15 s the line shows `The session did not get ready in 15 seconds. Bifrost sent nothing.` in `text-text`, with no `Error:` prefix. The text stays. No attach stays. | - |
| Step 7: Stop of a working session | Stop m4a during a count. Cancel. Stop again and confirm. | Pass. The dialog shows `bifrost-test-m4a is working right now. Stop it anyway? The current turn will end.`. Cancel changes nothing. The confirm parks the row in 2 s. The chat window stays open and shows the end. | `m4-findings/t10-07-dialog-stop.png`, `m4-findings/t10-08-stopped-chat.png` |
| Step 7: Resume | Menu > Resume on the parked m4a. | Pass. The row ran again in 6 s. The open chat window attached again (new attach PID). | - |
| Step 7: Stop of an idle session | Stop the idle m4a. | Pass. No dialog. The row parks. | - |
| Step 8: Delete | Menu > Delete session... on the parked m4a. Esc, then Delete again and confirm. | Pass. Title `Delete bifrost-test-m4a`, body `Delete bifrost-test-m4a? This removes the session and its conversation.`. Cancel has the first focus. Esc cancels. After the confirm the row went away in 1 s, and the chat window closed. `claude agents --all` and the dev `registry.json` have no `c51397d9`. | `m4-findings/t10-10-dialog-delete.png` |
| Step 9: dialog defaults | Side bar > New session. | Pass. Empty folder (no history yet), name `session-c82a`, Model and Permission mode Default, empty prompt, worktree off. Width 440 px. The first focus is in Folder. The datalist has 5 recent project folders. | `m4-findings/t10-12-dialog-new-session.png` |
| Step 9: Choose... | Set the folder to `.m0-sandbox`. Click Choose.... Read the sheet with System Events by the dev PID. Click its Cancel button. | Pass. The native sheet opened at `.m0-sandbox`. Cancel kept the field. The agent did not pick a folder. | - |
| Step 9: start m4new | `.m0-sandbox`, Haiku, `bifrost-test-m4new`, prompt `Reply with the word READY.`. Press Enter two times fast in the prompt. | Pass. One session started in 7 s. The dialog closed, the row is selected, and its chat window opened with `READY`. The next open has the same folder and Haiku, a new name suffix and the worktree box off. | - |
| Step 9: trust error | Folder `/private/tmp/bifrost-test-untrusted`. | Pass. After 4 s: `Claude Code doesn't trust this folder yet. Run claude in /private/tmp/bifrost-test-untrusted once, accept the trust prompt, then try again.`. No session started. The agent removed the folder. | `m4-findings/t10-13-dialog-new-session-trust.png` |
| Step 9: worktree start | Worktree on, Enter on the worktree box. | Pass. The row has the branch `worktree-bifrost-test-m4wt` and the cwd `.claude/worktrees/bifrost-test-m4wt`. | - |
| Step 9: worktree delete (ruling 4) | One empty commit `c72de0f` in the worktree. Delete, then the tests of Task 8 item 3, then confirm. | Fail. See bugs 1 and 2. The dialog text is correct: `This session has 1 commit that is not merged on worktree-bifrost-test-m4wt. Are you sure you want to delete this?`. But `claude rm` refused and kept the worktree folder and the branch. The agent removed both by hand after a name check. Then a third Delete removed the session. | `m4-findings/t10-14-dialog-delete-worktree.png`, `m4-findings/t10-15-delete-refused.png` |
| Step 10: Take control, session with a message | `.command` file in Terminal with a first prompt (m4ext3). Menu > Take control. | Pass. The dialog shows `This closes the session in Terminal and moves it into Bifrost.`. Cancel has the first focus. After the confirm, the row became owned with the same session ID in 6 s. The chat window opened. The Terminal tab shows `[Process completed]`. | `m4-findings/t10-21-dialog-take-control.png`, `m4-findings/t10-23-take-control-ok.png` |
| Step 10: Take control, session with no message | `.command` file with no prompt (m4ext, m4ext2). | Fail. See bug 3. | `m4-findings/t10-22-take-control-no-transcript.png` |
| Step 11: Open in terminal | Selected Item > Open in terminal on m4c2. Walk the parents of the new attach. | Pass. A Warp shell ran `claude attach e1bfaa66` (PID 2247, parents `-zsh` 1136 and Warp `stable` 866). The command was exactly `/Users/dev-user/.local/bin/claude attach e1bfaa66`. SIGHUP ended it. No notice showed (Warp uses the command file). | - |
| Step 12: Resume all | SIGTERM to the dev main PID. `cl.sh stop` for m4c2 and m4ext3. Start the app. Safety check, then Resume all. | Pass. The quit took less than 1 s and left no attach process. The resumable names were only `bifrost-test-m4c2` and `bifrost-test-m4ext3`. Both rows ran again in 12 s. No chat window opened. The notice `Resumed 2 sessions.` showed and went away in about 5 s. Then the button was off again. | - |
| Step 13: icons | Read the kind cells of the external Warp rows of the user. Only look. | Fail. See bug 5. The 12 px image loads from a data URL, with the title `Warp`, and no content security error. But the image is a generic square, not the Warp icon. | `m4-findings/t10-26-terminal-icons.png`, `m4-findings/t10-27-warp-icon-data-url.png` |
| Step 14: clean-up | Delete through the app (name check in the dialog title), `claude agents --all`, `git worktree list`, `ps`. | Pass, with one item for the user. All test sessions are gone except `d64bb329`. No worktree, branch, attach process, `.command` file or temp folder stays. | - |
| Task 8 item 1: start | Read the dev log and the page errors. | Pass. No renderer error. | - |
| Task 8 item 3: two-click Delete | Worktree Delete dialog of m4wt. | Pass. The first click changes the label to `Delete anyway`. A fast double click does not delete. A second click 200 ms after the first does not delete. Open worktree opened the folder in Finder, and the dialog stayed open. Cancel has the first focus. Esc cancels. A single click after more than 500 ms runs the delete. | `m4-findings/t10-14-dialog-delete-worktree.png` |
| Task 8 item 4: held Enter | Focus the confirm button. Send 1 key down and 25 repeated key downs of Enter in 0.8 s. | Pass. The label changed to `Delete anyway`. The session stayed. | - |
| Task 8 item 5: time to the dialog | Time from the Delete click to the dialog. | For the user. 1705 ms on the bifrost repository. The agent did not check the disabled state of Delete in that time. | - |
| Task 8 item 8: send box | Enter, Shift+Enter, a text of spaces, the slash hint, a failed send, drafts. | Pass. A text of spaces does not send. `Sending...` shows during a send. Each session keeps its own draft when the selection changes. Send message from the menu puts the caret in the box. | - |
| Task 8 item 10: Resume all | Side bar and tooltip. | Pass. The 1 px separator is above New session, and Resume all is below New session. The off button is at 40% with the tooltip `Resume all` and `None of the parked sessions were active when Bifrost last closed.`. The agent did not see a failure text. | - |
| Task 8 item 12: agent view and send | Give-up state in the m4a chat, then `input.send`. Close and open the window, then send again. | Pass. The send was refused with `The chat window shows the agent view. Close the window and open it again.`. After the new window opened, `Reply with the word AFTER.` went in. | `m4-findings/t10-09-agent-view-give-up.png` |
| Task 8 item 13: Resume after the agent view | Left arrow after the Resume of m4a. | Pass. The window blocked the input and attached again in 1.2 s. | - |
| Task 8 ledger: Resume after a give-up | Give-up, then Stop and Resume of m4a. | Pass. The input stays blocked. See bug 10 for the window state. | - |
| Task 8 ledger: the clipboard notice | Open in terminal. | For the user. Ghostty and iTerm2 are not installed, so no clipboard notice can show. | - |
| Task 8 item 14: restart | Compare `ui-state.json` before the quit and after the start. Look at the Overview tabs. | Pass. `recentSlash`, `recentDirs`, the model, the Overview configs (with the added tab) and the frame layout stayed the same. | - |
| Task 8 item 15: notice and error lines | Read the colours and the time. | Pass. The error line is light grey (`text-text`), not red. The notice went away in about 5 s. | - |
| Task 9 item 2: Enter in a select and on the box | Focus Model, Permission mode and the worktree box. Press Enter. | Pass with synthetic keys. Each Enter submitted. A real keyboard is for the user. | - |
| Task 9 item 3: Enter in fields | Enter in Folder and Name. Shift+Enter in the prompt. | Pass. Enter submits. Shift+Enter adds a line and does not submit. | - |
| Task 9 item 5: during a start | Press Esc and click the backdrop while `Starting the session...` shows. | Pass. All 9 controls are off. Esc and the backdrop click do nothing. | - |
| Task 9 item 6: failed start | Trust error. | Pass. The text shows under the fields, and the fields work again. See bug 7 for the focus. | - |
| Task 9 item 8: worktree box | Folders `relative/path`, `/private/tmp`, `.m0-sandbox`, and a fast change from a git folder to `/private/tmp`. | Fail. See bug 6. The rest works: no git gives `This folder isn't in a git repository, so it can't use a worktree.`, the git folder turns the box on after about 300 ms, and the fast change keeps it off. | - |
| Task 9 item 11: focus | Cancel and Esc on the dialog. | Pass. The focus goes back to the New session button. | - |
| Task 9 item 12: side bar button | Hover New session. | Pass. The button is above Resume all, the icon is 15 px, and the tooltip is `New session`. See bug 9 for the focus ring. | `m4-findings/t10-24-side-bar-focus-ring.png` |
| Watchlist: add with a colour | Menu > Add to watchlist > Cyan, Orange, White on three test rows. | Pass. The submenu has 8 coloured squares: orange, green, lime, cyan, blue, purple, pink and white. The colour shows in the Overview and in the panel. | `m4-findings/t10-17-watchlist-and-overview.png` |
| Watchlist: Change colour | Panel menu > Change colour on the cyan row. | Fail. See bug 4. Green then applied, and the order stayed. | `m4-findings/t10-16-change-colour-no-check.png` |
| Watchlist: Remove and the empty text | Selected Item > Remove from watchlist. Delete the watched rows. | Pass. The button changes between Add and Remove with the row, with the tooltip. The rows of deleted sessions go away. The empty text is `Nothing on your watchlist yet. Right-click a session and choose Add to watchlist.`. | - |
| Watchlist: drag order | Mouse drags in the panel. | Pass. 3 px gives no drag, and 6 px starts it. The row fades. The line shows at the top of the first row and at the bottom of the last row, also above and below the list. The drop moves the row. A drop in place shows no line and changes nothing. A click selects. A double-click opens the chat. No text gets selected. | - |
| Watchlist: release outside and Esc | Esc during a drag. Release the mouse at (1600, 950), outside the page. | Pass. The drag ended at the release with no faded row and no change. Esc does not cancel the drag (bug 11). The agent used CDP mouse events, not a real mouse. | - |
| Watchlist: row layers | Select the pink row and hover the purple row. Read the computed colours. | Pass. The watch colour is on the `tr` at 25%. The selection (cyan 15%) and the hover (white 5%) are on the cells. No seam shows between the cells. | `m4-findings/t10-18-watch-colours-2.png`, `m4-findings/t10-19-watch-colours-3.png` |
| Watchlist: parked watched row | Stop the watched m4c2. | Pass. Grey text on the purple colour, in the panel and in the Watched tab. Stop and Resume keep the colour and the order. | `m4-findings/t10-20-watched-tab-parked-row.png` |
| Watchlist: Watched tab and filter | Watched tab, tab menu > Filter > Only watched sessions, Overview Settings > Filters, Reset to default on All and on an added tab. | Pass. The Watched tab shows only watched rows. Both checkboxes set `watchedOnly`. Reset gives the default filter with `watchedOnly` false, also for the added tab. | - |
| Look: glow | Computed `box-shadow` and a crop of the focused Watchlist panel. | Pass. `0 -6px 12px -6px` cyan at 28% shows above the top edge only. Unfocused panels have no glow. | `m4-findings/t10-01-focus-glow.png`, `m4-findings/t10-02-glow-crop.png` |
| Look: focused panel darker | Computed background colours. | Fail. See bug 8. | `m4-findings/t10-01-focus-glow.png` |
| Look: 250 ms change | Computed `transition`. | Pass. Background, border colour and box shadow change in 0.25 s, ease-out. | - |
| M3: agent view | One left arrow on an empty prompt in the m4a chat. | Pass. The attach ended and a new attach showed the session after 1.2 s. The agent pressed no other key. | - |
| M3: WebGL contexts | Stack the m4new and m4c2 chats. Change the tab 20 times. Count the contexts with a `getContext` hook. | Pass. 20 contexts were made, and only 1 was live at the end. | - |
| M3: Lock checkbox | Selected Item panel menu. | Pass. The checkbox is square (`border-radius: 0px`). | `m4-findings/t10-25-lock-checkbox.png` |
| M3: column resize outside the window | Drag the Name column edge, move to (1600, -20), release. | Pass. The resize stopped at the release, at the 600 px limit. A later move did not change the width. The agent then set the width back to 184 px. | - |

### Bugs found

1. **Delete of a worktree session with commits that are on no remote stops the session, and then `claude rm` refuses.**
   1. Start a worktree session in the bifrost repository (New session, Use a worktree on).
   2. Make one commit in its worktree.
   3. Click Delete session..., then Delete anyway, then Delete anyway again after 500 ms.
   4. Result: Bifrost runs `claude stop`, then `claude rm`. `claude rm` refuses with the text "kept 98a27613", "its worktree is still at .../bifrost-test-m4wt", "169 unpushed commits on worktree-bifrost-test-m4wt ... They exist on no remote, so deleting the worktree would lose them." The repository has no remote, so the 168 commits of `main` also count. The worktree folder and the branch stay. The session stays, now parked.
   5. The error line shows the raw text with the prefix `Error:`, and the panel cuts the line. The text does not tell the user what to do.
2. **A stopped worktree session loses its worktree in Bifrost.**
   1. Do bug 1, or stop a worktree session.
   2. Result: the `claude agents` entry of the stopped session gives the start folder (`.m0-sandbox`) as `cwd`. Bifrost shows the project `.m0-sandbox` and the branch `main`.
   3. Click Delete session... again. The dialog shows only `Delete bifrost-test-m4wt? This removes the session and its conversation.`. It has no commit warning and no Open worktree button. Only the refusal of `claude rm` keeps the work safe.
3. **Take control of an external session with no message fails, and Bifrost shows no error.**
   1. Open a `.command` file in Terminal that runs `cl.sh --model haiku --name bifrost-test-m4ext`, with no prompt.
   2. Wait for the external row. Click Take control, then confirm.
   3. Result: Bifrost ends the Terminal process and starts `claude --bg --resume <id>`. The job shows `blocked` with no PID for about 15 s, then `failed`. The chat window shows `Session a222258e has exited (source session a222258e-4f09-4626-9429-adf6fcf70d34 not found).`. The row parks. No error line shows. `claude agents` shows no name for the job.
   4. The agent saw this two times (m4ext and m4ext2). With one message first (m4ext3), Take control worked.
4. **Change colour shows no check mark on the current colour.**
   1. Add a test row to the watchlist in cyan.
   2. Right-click the row, then open Change colour.
   3. Result: no item has a check mark. `RowMenu.tsx` uses `checked` only in the Set priority items.
5. **The terminal icon is a generic square.**
   1. Look at an external Warp row and an external Terminal row in the Overview.
   2. Result: both show the same light square. The data URL is a 16 x 16 generic icon (screenshot `t10-27`). The main process gets it with `app.getFileIcon(path, { size: 'small' })` (`src/main/ipc.ts`, line 340).
6. **The worktree tooltip stays `Checking the folder...` for a relative folder.**
   1. Open New session. Type `relative/path` in Folder.
   2. Result: the box is off, and its tooltip stays `Checking the folder...`. No check runs for a path that is not absolute, so the text never changes.
7. **After a failed start, the focus is on the page body.**
   1. Start a session in an untrusted folder.
   2. Result: after the trust text shows, `document.activeElement` is the body. The user must click a field to go on.
8. **The focused panel is not visibly darker.**
   1. Focus one panel and compare it with an unfocused panel on the empty page.
   2. Result: the panels use `rgb(16 16 16 / 0.85)` and the focused panel uses `rgb(16 16 16 / 0.95)` over the page colour `#0a0a0a`. This gives about 15.1 and 15.7 of 255. The focused panel is a little lighter, and the difference is too small to see. It looks darker only where it covers another panel.
9. **The side bar buttons show a round orange focus ring.**
   1. Close the New session dialog with Cancel. The focus goes back to the New session button.
   2. Result: the button shows the browser outline `rgb(229, 151, 0) auto 1px` with round corners. Spec 8.10 asks for square corners and a cyan accent.
10. **A chat window that gave up in the agent view does not attach again after Stop and Resume.**
    1. In a test chat window, press the left arrow on an empty prompt 4 times in 60 s. The window gives up and keeps the input blocked.
    2. Stop the session, then Resume it.
    3. Result: the attach client stays in the agent view. Its process title changes to `claude agents`. It does not end at the Stop, so the window does not end, and `restart()` does not run. The window keeps the give-up note. The input stays blocked, so this is safe. Close and open the window to recover.
11. **Esc does not cancel a drag in the Watchlist panel.** The drop happens at the release. This can be the intended design.
12. **A confirm dialog can block a click for a short time after it closes.** A right-click menu click 0.8 s after Cancel landed on the old `fixed inset-0` backdrop. One second later no backdrop stayed. The agent saw this one time.

### For the user

- Stop and remove the test session `d64bb329`. Its name is 64 `a` characters because of an agent error. Run `claude stop d64bb329` and `claude rm d64bb329` in `.m0-sandbox`, or delete the row in Bifrost.
- Close these windows that the test opened: three Terminal windows (m4ext, m4ext2 and m4ext3, each at `[Process completed]`), one Warp tab with a shell (PID 1136, from Open in terminal), and one Finder window of `bifrost-test-m4wt` (the folder is gone).
- Look at the dialogs, the 8 watch colours on the dark panel (lime and white are the risk), the glow, the focused panel and the focus ring in the screenshots.
- Check Enter in the Model and Permission mode selects and on the worktree box with a real keyboard. The agent used synthetic key events.
- Check the reply preview and the hook red box with the integration installed. This run did not change `~/.claude/settings.json`.
- Check the clipboard notice of Open in terminal. It needs Ghostty or iTerm2.
- Check the space labels (Track, Stop tracking). `LABELS` is the constant `plain`, so the app has no switch.
- Check that a saved M3 config shows no Watched tab and loads with no change. The agent did not run this.
- Check a folder pick in Choose... and Enter then a click in New session. The agent ran only Cancel and two fast Enter presses.
- Check that Delete stays off with the running reason during the worktree check (1.7 s).
- Check the Resume all failure text `<name>: <text>`.
- Decide the Add button of the Selected Item panel. It adds the row in orange with no colour choice. Spec 8.12 says that you select a colour in a submenu.
- Release a drag outside the window with a real mouse. The agent used CDP mouse events.
- The dev app made `quiet` folders in `~/.bifrost/sessions` for 9 test session IDs and an empty `~/.bifrost/run` folder. The agent left them.
