# Pseudo-terminals and the session size: behaviour

Every chat window, and every hidden attach that the session input opens to type into a session,
talks to Claude Code through a pseudo-terminal (PTY). A PTY is a pair of connected ends: the
program on one end, here `claude attach`, sees an ordinary terminal, and Bifrost holds the other
end, where it reads the output and writes the keys. This page covers how Bifrost starts and runs
those PTYs, and how it reads the size that another client has given a session.

The code is in `BifrostSessions/Services` (`PTYManager.swift`, `TrustRuns.swift`,
`PTYProcess.swift`, `SessionSizeReader.swift`, `SessionSizeWatcher.swift` and
`ProcessInspector.swift`) and
`BifrostSessions/Model/TerminalSize.swift`. Where the native app deliberately differs from the
Electron app, `docs/ports/pty/DELIBERATE-DIFFERENCES.md` explains how and why.

## Opening a PTY

`PTYManager` keeps one PTY for each view, where a view is either a chat window or the hidden
attach of a session. It only ever runs one command, and it's built so that no caller can change
that command or skip the checks before it.

- The child is always `claude attach <short id>`, run with the claude program that the app found,
  the child environment (see `docs/behaviour/process.md`), and `TERM` and `COLORTERM`.
- The manager builds the arguments itself from a `ShortID`, which is always eight lower-case hex
  digits. So no caller can hand claude anything else, and an ID that starts with `-` can never
  turn into an option.
- An open only takes a `CheckedAttach` (the view, the short ID and the folder), and only
  `AttachRules.check` can make one, so no caller can skip the check.
- The open gives back a `PTYAttach`, and the caller of the open owns it: it reads the output and
  the exit, writes, resizes and closes.
- An open of a view closes that view's old PTY first, before the spawn. Any output or exit from
  the old PTY goes only to its closed attach, which means nowhere.
- A cancel of the open's task (a window that closes), a `closeAll`, or a newer open of the same
  view during the spawn cancels the open. When the spawn finishes, the manager closes the new
  child straight away with SIGHUP to its pid, and the open gives no attach, so the old child can't
  affect a newer window of the session. An open whose task is cancelled before the spawn starts no
  child.
- Output and an exit that arrive during the spawn wait until the open has finished, so the
  caller always has the attach before the first output and the exit.
- A spawn error throws, and the view has no PTY. A missing folder gives
  `Cannot start <program> in <folder>: <reason>.`, and a program that can't start gives
  `Cannot start <program>: <reason>.`

## The trust run

Reviews needs one other kind of PTY: a terminal in which you trust a review clone (see "Clones and
trust" in `docs/behaviour/reviews.md`). It runs `claude` with no arguments in the clone, so the
real workspace trust prompt of Claude Code shows up and you answer it yourself. It goes through the
same spawner, environment and order rules as an attach, with its own checks:

- `PTYManager.openTrust` only takes a `CheckedTrustRun`, and only `TrustRuns.check` can make one.
  The check gives a run only for a real folder strictly below the real path of the folder of the
  review clones: the folder itself, a sibling, a path with `..`, a link that leads out of it, a
  file and a missing folder all give nothing. The forbidden rule `trust-run` lets only Reviews
  and the tests call the check, so nothing else can start `claude` in a folder of its choice.
- The manager keeps at most one trust run, and a new one closes the old one first. It gives back a
  `PTYRun`, which works like an attach (output, writes, resize, close and exit) but has no
  session and no view, so the list of attaches, the attach of a view and the session input never
  see it. `closeAll` closes it too, with SIGHUP.

`PTYAttach` and `PTYRun` share one engine underneath (`PTYChannel`: the life of the child, the
drain of its output with the flow control, the writes, the size and the close), so both behave the
same way in every case below.

## How the child starts

Starting a program can be slow, and the child needs a real terminal of its own so that it hears
about a resize. So the spawn runs away from the interface, and the child is set up as the leader
of its own terminal session.

- The spawn (`forkpty`, then `posix_spawn` with `POSIX_SPAWN_SETEXEC`) runs on the blocking
  executor, off the main actor and off the cooperative pool, because on a Mac with an endpoint
  scanner every program start waits for a scan.
- The child is the leader of a new session, and the PTY is its controlling terminal, so a resize
  sends it SIGWINCH. It starts in its folder with only descriptors 0, 1 and 2, every signal at its
  default action, and an empty signal mask.
- All signals are blocked during the fork, and the code between the fork and the exec only uses C
  values.

## Output, input and closing

Once the child runs, the attach carries its output to the reader, its input to the child, and its
end back to the caller. These rules keep that flow ordered and keep the app responsive during a
burst of output.

- Output arrives in drains on the main actor. Each PTY has one drain in flight at a time, each
  drain takes at most 262,144 bytes, and each drain is one element of the attach's output.
- A drain happens only when the reader asks for the next element, at most once in each turn of
  the main actor, and the child holds on to its bytes until then. That keeps the bytes in order
  and leaves the main actor free during a burst.
- The output has one reader. A second reader waiting at the same time is a programming error and
  stops the app.
- Flow control: when more than 1 MiB (four drains) waits, the app stops reading the PTY, and it
  starts again once a drain leaves less than 256 KiB. While reading has stopped, the kernel buffer
  fills and the child waits on its write, just as it would in any terminal, so a slow or stalled
  reader can't make the app's memory grow without limit. Bytes that the kernel still holds when
  the child ends are read before the PTY closes.
- The child reports its output and its exit through one ordered stream of events, which the
  attach reads on the main actor.
- Writes go onto a write queue in the order of the calls, so a large paste never holds up the
  caller. When the PTY is full, the write waits for the child to read, looking again every
  100 ms so that a close can end the wait.
- A close only detaches. It sends SIGHUP (or SIGTERM when asked) to the attach child by its pid,
  never to a process group and never to the session.
- Once the child has been reaped, no signal goes to its pid, because the system can hand that
  pid to a new process.
- After a close, the attach keeps draining the child's output and dropping it until the child
  exits.
- The exit code is the code of an exit, or 0 when a signal ended the child. The exit comes after
  the last output, and after a close the attach gives no exit code.
- A valid size has 1 to 1000 columns and 1 to 1000 rows. The attach ignores a resize below 1 x 1,
  and the chat window and the session input never pass on a size over 1000.
- A chunk of a chat attach that holds the full-redraw sequence (`ESC [ 2 J`) tells the size
  watcher to look. A sequence that two chunks split is missed, and the next redraw or open picks
  it up.

## The size of a session

Another client, such as a terminal app attached to the same session, can set the session's size.
Bifrost reads that size so that windows which aren't focused can follow it, and it never writes
to a TTY.

- `SessionSizeReader` finds the terminal device of the session's process, then that device's
  size. It finds the device again on every read, so a new process with a reused PID gets the size
  of its own device. With no TTY, or a failed read, there's no size.
- The device comes from `proc_pidinfo` and `devname_r`, and only a pseudo-terminal
  (`/dev/ttys<n>`) counts. The size comes from `ioctl(TIOCGWINSZ)` on that device, opened
  read-only, without blocking, and never as the app's controlling terminal. No program starts.
- `SessionSizeWatcher` starts one read 150 ms after the last poke of a view. Only one read runs
  at a time for each view, and a poke during a read gives one more read after it.
- The watcher emits a size only when it has changed. A failed read keeps the last size, so a
  window keeps the old size after the session ends.
- `forget` stops the timer and drops the last size, so a new window of the view gets the size
  again.
- A size that isn't valid is dropped before it reaches the chat terminal.

## Not ported

The node-pty helper program isn't needed, because the system calls give the child a controlling
terminal without it. The `ps` and `stty` programs aren't needed either, because the process APIs
read the same data. The reader's 30 s device cache is gone too: it only saved a `ps` run, and
finding the device is now a cheap `proc_pidinfo` call.
