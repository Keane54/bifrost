# Typing into a session: behaviour

Everything that Bifrost types into a session goes through one path, the session input: sending a
message, running a slash command, renaming a session, and Interrupt, which presses Esc once. Input
only ever goes to an owned session that's running, through `claude attach <short id>`. It goes
through the chat window's own attach when the window is open, and otherwise through a short-lived
hidden attach that Bifrost opens just for the job.

The text rules and the refusal texts are in `BifrostSessions/Model/InputPlan.swift`, the jobs are
in `BifrostSessions/Services/SessionInput.swift`, and the terminal of a hidden attach is
`BifrostChat/UI/HiddenTerminalModel.swift`. Where the native app deliberately differs from the
Electron app, `docs/ports/input/DELIBERATE-DIFFERENCES.md` explains how and why.

## The text plan

Before anything goes to a session, Bifrost checks the text and turns it into a plan: the exact
bytes to write and the pauses between them. Making a plan has no side effects, so the send box can
use the same checks to show a reason early.

- A text over 20,000 Characters is refused before any clean-up.
- The clean-up turns CRLF and a lone CR into LF, and removes the control characters (C0 apart from
  tab and LF, DEL, and C1). So the text can't hold ESC, which means it can neither end a paste
  early nor press a key.
- The ends of the text are then trimmed. White space is `Character.isWhitespace`, and the trim
  removes whole Characters, so a combining mark on a trimmed space goes with it.
- An empty text is refused, and so is a slash command (a text whose first scalar is `/`) that
  holds a line break.
- A text goes as a bracketed paste (`ESC [ 200 ~`, the text with each LF turned into CR, then
  `ESC [ 201 ~`), followed by a CR 300 ms later. A typed form for slash commands also exists (the
  text, then a CR 500 ms later), but the paste is the form in use.
- No plan is ever just a CR, so Bifrost never presses Enter on an empty prompt.
- A rename sends `/rename <name>`, with each run of white space Characters turned into one space.
  The 64 Character limit applies after that clean-up, and a name over 20,000 Characters is refused
  as too long without one.
- A red box for a prompt blocks Send, Run slash command, Compact and Rename, because typed text
  could answer the prompt by accident. A send is also blocked while the session list shows the
  session waiting on a prompt (`waitingFor`), because a line of the Live details mod, even a
  forged one, can clear the box (Live state is a hint, not an authority; see
  `docs/behaviour/live.md`). An escalated box, an error box and a yellow box don't
  block, and nothing blocks Interrupt. Every red box has a cause, so there's no "unknown cause"
  case.
- In the send box, Enter sends and Shift+Enter adds a line break. Enter doesn't send while an
  input method is composing. The send box comes in phase 4, so these keys are its spec.

## The jobs

A send or an Interrupt is a job. Jobs keep the input of one session in order, check the session
again just before every write, and make sure that only one attach to the session is open at a
time.

- Each send and each Interrupt is a job, which is one task on the main actor. The jobs of one
  session run in the order of the calls.
- A job starts with a check of the row: it must be an owned session that isn't parked, with a
  short ID that no other row has. For a send, a red box for a prompt, or a session that the
  session list shows waiting on a prompt, also stops the job. Just
  before every write, the job checks the row, the attach, the short ID and the block again.
- When the session's chat window has an open attach, the job writes into it. Otherwise the job
  reads the session's size and opens a hidden attach (`claude attach <short id>`, in the root
  folder) at that size. A row with no process ID can't give a size, so it ends the job, and so
  does a size that can't be read or that falls outside 1 to 1000.
- A hidden attach closes 1 s after its last write, or straight away after an error. The close
  sends SIGHUP to the attach child only, so the session keeps running.
- A hidden attach answers Claude Code's terminal queries, such as a cursor position report,
  through a terminal model with no view. It doesn't answer the kitty keyboard query, so Claude
  Code keeps the legacy key forms and the Esc of an Interrupt is a plain Escape key.
- A failed open of a hidden attach ends the job, and the error goes to the log.

### Waiting until the session is ready

- A send waits until the attach's output has been quiet for 1.5 s once, whether it writes through
  the chat window or through a hidden attach. A busy session may never go quiet, so after 15 s the
  job writes nothing and ends.
- An Interrupt only needs a connected attach, because a working session shows a spinner and never
  goes quiet. It sends its Esc 300 ms after the attach's first output.
- If the attach ends while a job waits or writes, the job ends. So does a job whose row now has a
  different short ID from the attach it writes to.

### Chat windows and hidden attaches

- One attach serves each session. A chat window that's about to open its PTY tells the session
  input first, and that call waits until the session has no job. Until the open has finished,
  every job of the session waits, so a hidden attach never opens beside the chat's attach.
- When a chat window opens while a job reads the session size, the job starts again and uses the
  chat's attach.
- The chat window reads its attach's output itself (an attach has one reader) and tells the
  session input about each chunk and about the end. The session input reads a hidden attach's
  output itself.
- While a chat window shows the agent view, a job that would write through it ends.

### Interrupt and the other keys

- Interrupt first cancels every send of the session that hasn't written yet. A send that's in the
  middle of the size read ends when the read returns, and opens no attach. Once a send has
  written its first bytes, Interrupt can't cancel it, so a text never sits in the prompt without
  its CR.
- Interrupt sends one Esc. A second Interrupt while one waits or runs, or within 1.5 s of an Esc,
  does nothing, because two Esc presses open the rewind menu.
- After an Esc, the next write to the session waits 200 ms, so the session can't read the Esc and
  the next bytes as one key. For the same reason, the hidden terminal's replies go nowhere after
  the Esc until the attach closes.
- A left arrow key on an empty prompt opens the agent view, so a send to that chat window waits
  2 s after any left arrow key (`ESC [ D` or `ESC O D`) that the window writes. A new left arrow
  key during the wait starts it again, and the waits of one step last 15 s at most.
- `idle` returns once the session has no job. A new job can start while the caller waits, so it
  checks again after each job.

## Refusals

When Bifrost won't type something, the refusal is a case of `InputRefusal`, and each case has a
friendly sentence that the user can read.

| When | The text |
| --- | --- |
| The text is empty after the clean-up | `Type a message first.` |
| The text is over 20,000 Characters | `The text is too long. The maximum is 20,000 characters.` |
| A slash command holds a line break | `A slash command has one line.` |
| The name is empty after the clean-up | `Type a name first.` |
| The name is over 64 Characters | `The name is too long. The maximum is 64 characters.` |
| A red box for a prompt blocks a send | `Answer the prompt in the chat window first.` |
| The row isn't an owned, unparked session with its own short ID | `Bifrost can only type into a session that it started and that is running.` |
| The row has no process ID yet | `The session is still starting. Try again in a moment.` |
| The session size can't be read, or is outside 1 to 1000 | `Bifrost cannot read the session size. Open the chat window and send from there.` |
| The attach didn't get ready in 15 s, or the waits of one step went over 15 s | `The session did not get ready in 15 seconds. Bifrost sent nothing.` |
| A hidden attach failed to open, or ended before it was ready | `The connection to the session ended before it was ready. Bifrost sent nothing.` |
| The chat window shows the agent view | `The chat window shows the agent view. Close the window and open it again.` |
| The chat window's attach ended during the job | `The chat window closed during the send.` |
| A hidden attach ended during the writes | `The connection to the session ended during the send.` |
| The row's short ID no longer matches the attach | `The chat window shows an old connection to the session. Close the window and open it again.` |
| Interrupt cancelled the send before its first write | `Interrupt stopped the send before it went.` |

The Node timers, the quiet-watch classes and the promise race of a cancel weren't ported. Each job
sleeps on the injected clock, and a cancel of its task takes the place of the race.
