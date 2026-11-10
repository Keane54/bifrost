---
name: bifrost-hand-over
description: Write a compact hand-over note so that a new session can continue this work. Shows the note in the chat and saves it to ~/.bifrost/handovers, or to a path you give.
disable-model-invocation: true
argument-hint: "[path]"
---

# Hand over

Write a hand-over note for this session, show it in the chat, and save it to a new file. A new
session continues the work from the note.

1. Read `${CLAUDE_SKILL_DIR}/hand-over-rules.md`. It says what the note holds and how to write it.
   Follow it exactly.
2. Before you write the note, you can confirm the state of the work with read-only commands, for
   example `git status --short`, `git branch --show-current` and `git log --oneline -5`. Do not
   change the work.
3. Write the note, and show the full note in the chat.
4. Find the path of the file:
   - If the user gave a path (`$ARGUMENTS`), use it. If that path is a folder (an existing folder,
     or a path that ends with `/`), put the file in it with the default file name.
   - Else use the default path: `~/.bifrost/handovers/<session name>-<time>.md`.
   - The session name is the name that the user gave this session with `/rename`, if you know it.
     Else it is the name of the current folder. In the name, change each run of characters other
     than ASCII letters, digits, `.`, `_` and `-` to one `-`, and remove a `-` at the start or the
     end. If the name is then empty, use `session`.
   - The time is the local time from `date +%Y%m%d-%H%M%S`.
5. Save the note:
   - If the folder does not exist, make it: `mkdir -p -m 700 ~/.bifrost/handovers` for the default
     folder, else `mkdir -p <folder>`.
   - Never write over a file. Check first that nothing exists at the path. If something does, add
     `-2` before the extension, then `-3`, and so on, until the path is free.
   - Write the note exactly as you showed it, to the absolute path. Use your file write tool, not a
     shell command, so that the shell does not change a `$`, a backtick or a quote in the note.
6. Tell the user the path of the file. Then stop. Do not start the next steps in this session.
