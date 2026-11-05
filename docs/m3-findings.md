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
