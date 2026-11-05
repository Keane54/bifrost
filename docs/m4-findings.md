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
