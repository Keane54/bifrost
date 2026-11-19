# Processes, the claude program and the environment: behaviour

Bifrost runs a few programs of its own, mostly `claude` itself, and reads facts about others, such
as which terminal app a session runs in. This page covers how it runs a program, which
environment a child gets, how it finds claude when it starts, and how it reads the details of a
process without starting a program.

The code is in `BifrostFoundation` (`Services/ProcessRunner.swift`, `Services/ProcessLines.swift`,
`Model/HomeLocator.swift` and `Model/AppIdentity.swift`) and in `BifrostSessions`
(`Services/ProcessInspector.swift`, `Services/ClaudeCLI.swift`, `Model/ChildEnvironment.swift` and
`Model/LoginEnvironmentText.swift`). Where the native app deliberately differs from the Electron
app, `docs/ports/process/DELIBERATE-DIFFERENCES.md` explains how and why.

## The process runner

`ProcessRunner.run(_:)` runs one program and gives back one `ExecResult`. It never throws, so every
way a run can end, from a timeout to a program that never started, comes back as a value that the
caller can check.

- The result holds how the run ended (`ExecEnd`), stdout and stderr. `succeeded` is true only for
  `exited(0)`.
- A run ends in one of six ways: `exited(code)`, `timedOut`, `overflow`, `cancelled`,
  `notStarted` or `signal(n)`. A program that exits with code 0 after the timeout counts as
  `exited(0)`, because it finished its work.
- The run and its spawn use the blocking executor, not a thread from Swift's pool, and a cancel or
  a timeout never waits for a spawn.
- No signal goes to a program after its termination handler has run. Foundation reaps the program
  just before it calls that handler, so the gap is very short.
- The default timeout is 10 s. At the timeout, the runner sends the command's kill signal (SIGKILL
  by default, so a program that ignores SIGTERM still stops), and the result comes when the
  program ends.
- A command can ask for SIGTERM instead, when a SIGKILL could leave its work half done. The
  program then gets a grace, 5 seconds unless the command gives another, on the runner's clock.
  If it hasn't ended by then, it gets SIGKILL, so a program that ignores SIGTERM can't hold a run
  for ever. One that ends within the grace gets no SIGKILL. The grace also starts when a cancel
  or the output limit sends SIGTERM. A cancelled run returns at once, unless its command waits for
  the end of the program (as the first-line read does), and then it returns after that end. A
  command can turn the grace off, and then it has to set its own limit for the wait; the first-line
  read never turns it off.
- The output limit is 1,048,576 bytes each for stdout and stderr. Output of exactly the limit is
  fine, and one byte more stops the program with `overflow`. The runner keeps the first
  1,048,576 bytes of each stream.
- A cancel of the calling task sends the command's kill signal and the result comes straight
  away. A task that's cancelled before the start starts no program.
- A command can ask to wait for its end (`waitsForEnd`). Then the result of a cancel comes only
  once the program has ended, after the grace and a SIGKILL if it needs them, so the caller knows
  that nothing of the run still runs. Such a command needs SIGKILL or a grace, or the wait could
  last for ever.
- With no input, stdin is empty and closed. A program that ends before it reads its input still
  gives its result, and the app doesn't crash (Bifrost handles EPIPE).
- A name with no slash is looked up on the `PATH` of the command's environment, or on
  `/usr/bin:/bin` when there's no `PATH`. That's `ProgramLookup`, the app's one lookup. Empty and
  relative folders are skipped, and only a regular file that the user can run counts, never a
  folder.
- Output is read as UTF-8, and a byte that isn't valid UTF-8 becomes U+FFFD.

When a run doesn't succeed and the program wrote nothing to stderr, the runner fills stderr with a
native Swift text:

| How the run ended | stderr |
| --- | --- |
| A signal ended the program | `<program> stopped with signal <n>.` |
| The time limit stopped the program | `<program> did not finish within <n> s.` |
| The output went over the limit | `The output is over the limit of <n> bytes.` |
| A cancel stopped the program | `Bifrost stopped the program.` |
| The program didn't start | `Cannot start <program>: <reason>.`, or `Cannot start <program> in <folder>: <reason>.` when the folder is the problem |

## Stopping at the first line that fits

Some programs only need to run until they print one particular line. The Daily update probes the
MCP servers this way: the first event of `claude -p` lists the servers, and nothing after it
matters. `ProcessLines.firstLine(_:where:)` runs the program, hands each line of stdout to a test,
and stops the program at the first line the test accepts, which it then returns. It runs on the
same process core as the process runner, so the start, the limits, the kill signal and the grace
work exactly as above; only the split into lines is its own.

- A line ends at each LF, and a CR just before the LF isn't part of it. When the program ends by
  itself, the text after the last LF is the last line. Empty lines never reach the test.
- stdin is empty and closed, as for any command with no input.
- The program also stops at the command's time limit, at its output limit and when the caller is
  cancelled. Each stop sends the command's kill signal, and a SIGTERM turns into SIGKILL after the
  command's grace (5 seconds unless it gives another).
- The call always waits for the program to end, also after a stop or a cancel. The signal goes to
  the program only, so a child that the program started can outlive it.
- After a stop the call doesn't wait for stdout to close. If the program ends by itself with no
  accepted line while a child of it still holds stdout open, the call ends at the time limit.
- With no accepted line, or a program that didn't start, the result is nil.

## The child environment

A child must never see the terminal or the Claude Code session that started Bifrost, because
Claude Code changes how it behaves when it sees those variables. Started from Finder, Bifrost
doesn't have them anyway, so removing them keeps a development run the same as a real one.

- The environment drops `CLAUDECODE`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERM_SESSION_ID`
  and every key that starts with `CLAUDE_CODE_` or `WARP_`. All other keys stay.
- A PTY child also gets `TERM=xterm-256color` and `COLORTERM=truecolor`. A claude run without a
  terminal gets neither.

## Finding claude when the app starts

When you start Bifrost from Finder or the Dock, it inherits launchd's short `PATH`, which can miss
the folder that claude lives in. So at the start, Bifrost asks your login shell where claude is,
and which environment to run it in.

- The app runs one interactive login shell: the shell it's given, else `SHELL`, else `/bin/zsh`.
  An interactive shell also reads `.zshrc`, which can add claude's folder to the `PATH`.
- The shell only gets `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG` and `TMPDIR`, so the path of
  claude comes from the same environment that the claude runs get.
- The script prints `command -v claude` between two claude markers, then `/usr/bin/env -0`
  between two env markers. The shell can print a banner or other text outside the markers.
- The shell has 5 s. On a timeout, a failure, or output that doesn't parse (a missing marker, an
  entry with no `=` or with an empty key, or no `PATH`), the app uses its own environment and logs
  one line with the reason and the time the shell took.
- The path of claude is the last line between its markers, and only an absolute path counts, so
  an alias doesn't.
- If the shell gives no path, the first claude on the app's own `PATH` wins, then the first
  runnable one of `~/.local/bin/claude`, `/opt/homebrew/bin/claude` and
  `/usr/local/bin/claude`.
- With a test home, the app uses the first claude on its own `PATH`, with its own environment,
  and never runs a real login shell.
- Without claude, the app reads no session list and logs `Bifrost cannot find claude, so it does
  not read the session list.` Each Overview then shows `Bifrost can't find Claude Code. Install
  it, then open Bifrost again.` in its error line.

## Running claude

- Each claude run gets the child environment made from the login environment, and never gets
  input, because claude adds piped stdin to its prompt.
- `listAgents` runs `claude agents --json`, with `--all` only when asked, and a 10 s limit. A run
  that doesn't succeed gives its trimmed stderr as the error, or, when stderr is empty, a text for
  how it ended (for example `claude stopped with code <n>.`).

## The process inspector

To find which terminal app a session runs in, and to read a session's terminal, Bifrost reads
process details through the process APIs of macOS. It never starts a program for this, because
every program start is slow on a Mac with an endpoint scanner (user decision, 2026-11-16).

- To find the terminal app of a process, the inspector walks up its parents one process at a
  time. `proc_pidinfo` gives the parent PID, and the command is `argv[0]` (from `sysctl` with
  `KERN_PROCARGS2`), as `ps -o comm=` shows it.
- For another user's process, or when that read fails, the command is the executable's path
  (`proc_pidpath`), and failing that the kernel's short name, as for a zombie.
- The same read gives the command of a single process, with its start time from the same
  `proc_pidinfo` call (`identity(of:)`). The session actions check both before they signal
  anything.
- The first process whose command lies inside an app bundle (`.app/`) gives the terminal app. The
  walk stops at PID 1 or below, at a missing process, at a loop, and after 64 steps. It only reads
  the chain of parents, never the whole process table.
- To find the `claude attach` clients of background sessions (`attachClients(own:)`), one
  `sysctl` call with `KERN_PROC_UID` lists every process of the user with its controlling terminal
  and start time. `claude attach` needs a terminal, so only the processes that have one get their
  arguments read, which is usually a few dozen out of several hundred. A command line counts when
  `argv[0]` ends in `claude`, `argv[1]` is `attach` and exactly one argument that isn't an option
  follows, with no more than eight arguments in all. Each client then gets the same walk up its
  parents, and a client whose walk reaches Bifrost's own process is one of Bifrost's own attaches,
  so it's left out. A client with no app on its walk keeps no app.
- The terminal device of a PID comes from `proc_pidinfo`, and the size of a terminal from
  `ioctl(TIOCGWINSZ)` on the device, opened read-only and never as the app's controlling
  terminal. A size that isn't valid gives none. `docs/behaviour/pty.md` has the rules of the size
  read.

## The test home and the app's identity

Tests must never touch your real files, so the development app can run against a safe folder that
stands in for your home.

- `BIFROST_TEST_HOME` moves the development app to that folder. The release app ignores it.
- The value must be an absolute path, and the check refuses `/`, your real home and any parent of
  it, also through a symbolic link and with different letter case.
- The app writes its shared state into the test home, so the check also refuses a folder inside
  the real data of Claude Code and Bifrost: `~/.claude`, `~/.claude.json`, `~/.bifrost`,
  `~/.bifrost-native-dev` and the two Bifrost folders in `~/Library/Application Support`. These
  are the folders that the test sandbox refuses.
- A refused value stops the app, so it never falls back to the real home by mistake. The app
  shows an alert, `<name> can't start`, with `Bifrost can't use the test home <value>. Use an
  absolute folder that isn't /, your home folder, a parent of it, or a data folder of Claude Code
  or Bifrost.`
- An empty value is refused too, and shows as `(empty)`.
- The bundle ID of the development app ends with `.native-dev`, and the release and development
  apps never share data folders.

The helper keys that run the app binary as Node, the latin1 option and the flags of Node's
`execFile` weren't ported, because the Swift runner has no use for them.
