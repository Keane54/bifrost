# The chat window: behaviour

A chat window shows one session that Bifrost owns as a live terminal. Behind it, Bifrost opens a
pseudo-terminal (PTY) that runs `claude attach <short id>` in the session's folder, so whatever
you type in the window goes straight into Claude Code. Claude Code always draws on the terminal's
alternate screen, which means the window keeps no scroll history of its own.

The code lives in the `BifrostChat` module. `UI/ChatTerminal.swift` owns the attach of one window,
`Services/SizeSync.swift` decides its size, the `Model` folder holds the agent view, size and link
rules, and `UI/LinkOpener.swift` opens links. The Take control loader has its rules in
`Model/TakeControlLoader.swift` and its look in `UI/LoaderLayer.swift`. The rules for which
session a window may attach to are in `BifrostSessions/Model/AttachRules.swift`. Where the native
app deliberately behaves differently from the Electron app,
`docs/ports/chat/DELIBERATE-DIFFERENCES.md` explains how and why.

## Which sessions a window can open

Bifrost only attaches to a session it can safely type into, so a window checks its row in the
session list before it opens anything, and shows the reason in place of the terminal while it
can't attach.

- Only an owned row that isn't parked can attach, and the only command Bifrost ever runs is
  `claude attach <short id>`.
- A short ID is eight lower-case hex digits. If the `id` that `claude agents --json` gives isn't
  one (for example, text that starts with `-`), Bifrost treats the row as having no short ID, and
  the window waits for the session ID.
- Just before the PTY opens, a final check refuses a short ID that two rows share, and an attach
  for a different session from the one the window shows.
- The folder always comes from the row, never from whoever asked for the open. A row with no
  folder attaches in the root folder (`/`).
- A window that waits attaches by itself as soon as its row can attach, except while Take control
  of its session runs (see "The Take control loader").
- A failed open isn't retried, which stops a loop of errors. You close the window and open it
  again.
- Closing a window sends SIGHUP to the attach child only, so the session keeps running.

While a window can't attach, it shows one of these reasons:

| When | The window shows |
| --- | --- |
| The first session list hasn't arrived yet | `Waiting for the session list.` |
| The row has gone from the list | `This session isn't in the list any more.` |
| The row is external | `This session runs in another terminal, so Bifrost can only show its status.` |
| The row is parked | `This session is parked. Resume it first.` |
| The row has no short ID yet | `Waiting for the session ID.` |

## The attach

The attach is the connection between one window and its session. At any moment it's in exactly
one state, and each state carries only the details that make sense for it: only an open attach
has output to read, for example, and only an ended window has a closing line to show. Because of
that, a window can never be ended and attached at the same time, or keep reading an attach it has
already closed.

| State | What's happening |
| --- | --- |
| Waiting | The window waits for the first session list, for a row that can attach, or for its panel to get a size. |
| Reading the size | A window that isn't focused reads the session's size once before its first open. |
| Opening | The PTY is opening. |
| Reattaching | The window opens again after the agent view showed, and its input stays blocked until the open ends. |
| Attached | The attach runs. The state also notes whether the screen has shown text yet, and how the agent view watch stands. |
| Ended | The window shows a closing line, and remembers whether the agent view guard gave up. |
| Closed | The window has closed, and nothing acts after this. |

The rules of an attach:

- One attach serves each session. Before it opens, a window waits until any sends that the
  session input is running have finished, and while the open runs, new sends wait for it. The
  rows can change during that wait, so the window checks them again before it opens. A reattach
  closes the old attach after the wait, just before the new one spawns.
- If the window closes while the open is running, it doesn't attach: when the spawn finishes, the
  new child gets SIGHUP straight away. A window that closes before its open starts opens nothing.
- Every way a window can end writes one line and closes the attach: `[process ended: code N]`
  after the child exits, `[input failed: the attach ended]` after a write fails, and
  `[open failed: <reason>]` after an open fails. A window that has ended only attaches again
  after a Resume.
- When the app quits, it closes every attach without an exit code, and each window then ends at
  its next write.
- Each chunk of output goes to the session input and the size watcher first, then to the
  terminal. During a reattach, a chunk from the old attach still reaches the session input and
  the size watcher, but not the terminal.
- The window tells the Take control loader when its screen first shows text from an attach, or
  when the window has ended and shows why (`isShowingText`, which is observable).
- The chats also keep an observable set of the sessions that a chat window is showing right now
  (`AttachedChats`), which the Overview reads to give those rows the Bifrost icon. A session is in
  the set while its window is attached or reattaching after the agent view, and it leaves when the
  window ends or closes. The hidden attach of the session input isn't a chat window, so it never
  adds a session.

An open that fails shows one of these reasons after `[open failed:`. A spawn error gives the
native error text that `docs/behaviour/pty.md` describes.

| Why the open failed | The reason |
| --- | --- |
| The final check found no single owned, unparked row with the short ID | `Bifrost can only open a session it started that isn't parked.` |
| The short ID belongs to another session | `This window is for another session. Open the chat again.` |
| The size is outside 1 to 1000 columns or rows | `The window is too small or too large for a terminal.` |
| The app has no PTY manager because it found no claude | `Bifrost can't find Claude Code. Install it, then open Bifrost again.` |

## The size

Several windows and other clients can show one session, but a session has only one size, so only
the window you're using decides it. Every resize makes Claude Code redraw the whole screen, which
is why Bifrost sends as few as it can.

- Only the focused window sends a resize. Other windows take the session's size, or zoom the
  terminal to fit their panel, never below 10 %.
- A window that isn't focused reads the session size once before its first open, so it opens at
  the size the session already has. A visible window waits until its panel has a size, so its
  attach opens at the right size.
- A terminal with no known size starts at 120 x 32.
- After a burst of changes, only the last size goes to the PTY, 150 ms after the last change.
  Each new change just pushes that send back.
- When a window gains focus, it takes the size back from any other client, but it sends its fit
  only when the session's size differs. If the PTY already has the fit, a resize to the same size
  wouldn't make Claude Code redraw. So the window sends a size one row smaller first (one column
  off for a one-row terminal), then the fit 60 ms later, which gives the session two separate
  SIGWINCH signals.
- For 500 ms after a send, a different session size counts as an old read, because the session
  hasn't caught up yet.
- After a focus gain, the window gives the keyboard focus to its terminal once the press on the
  frame has ended, unless a menu or a dialog has the focus.
- A zoomed window puts a clear cover over its terminal, because a zoomed terminal would report
  the wrong cells for the mouse. The first click on such a window only focuses it.
- A failed resize doesn't end the attach, and the next resize can still work.

## The agent view

Pressing the left arrow key on an empty prompt opens Claude Code's agent view, which lists the
sessions of all projects. Anything typed while it shows would go to that list rather than to the
session's prompt, so Bifrost watches the screen for it, stops the window's input, and attaches
again to bring the session back.

- Bifrost reads the screen 250 ms after the last output, and at least once a second during
  continuous output such as a spinner. It reads the screen and acts on what it finds in the same
  step.
- The screen shows the agent view when one of its last three non-empty lines is the footer
  `enter to return · space to reply`, and the screen also holds the counts line
  (`N awaiting input · N working · N completed`).
- The footer must fill its line, although white space and box-drawing characters can frame it. A
  footer inside the prompt box (with a border line below it), a footer quoted higher up the
  screen, and a footer with other text before it on its line don't count.
- A narrow terminal can wrap the footer, so Bifrost joins wrapped rows before it looks. A line
  that holds only white space (`Character.isWhitespace`) counts as empty. The footer and the
  counts line match on Unicode scalars.
- While the agent view shows, the window's input stops. The session input refuses a send to that
  window with `The chat window shows the agent view. Close the window and open it again.`, and a
  send that arrives once the reattach has started waits for it instead.
- If the row can attach, Bifrost resets the terminal and attaches again. If it can't, the input
  stays blocked with the row's reason as a note, and the next update of a row that can attach
  checks the screen again. If the agent view has closed by then, the input starts again.
- After 3 attaches within 60 s, Bifrost gives up: it stops checking, the input stays blocked, and
  the window shows `The agent view opened 3 times in 60 seconds. Close this window and open it
  again.`
- A Resume starts a new guard but keeps the session's attach history, which outlives the window.

## Links

Claude Code prints its links as terminal hyperlinks (OSC 8). A Cmd+click opens a link outside the
app with no dialog, and the rules below make sure that a click can never run a program. A plain
click goes to Claude Code, because Claude Code uses the mouse.

- Cmd+click opens an OSC 8 link, and also a plain URL in the text.
- An http or https link opens in the default browser.
- A file link of this Mac (no host, `localhost`, or this Mac's host name) opens in its default
  app. Bifrost works from the real path, with symbolic links, `.`, `..` and a trailing slash
  resolved.
- Any other link does nothing.

Some files run or install something when macOS opens them. Bifrost never opens those, and Finder
shows them instead. The type of the real path (`contentType`, `UTType`) decides, together with
its subtypes:

- a program: an app, a Unix or a Windows program, a Java archive (`jar`), an iOS app (`ipa`) and
  Python bytecode (`pyc`);
- a script that a shell, Terminal or Script Editor runs: a shell script (`sh`, `bash`, `zsh`,
  `csh`, `ksh`, `tcsh`, `command`, `tool`), Python, Perl (also `pm`), Ruby and AppleScript
  (`applescript`, `scpt`);
- a package, such as an app or another bundle;
- an alias file;
- a file that its app installs: an installer package, a profile (`mobileconfig`,
  `configprofile`, `provisionprofile`), a certificate (`cer`, `crt`, `der`, `pem`, `p12`, `pfx`,
  which Keychain Access adds to a keychain), a Safari extension (`safariextz`) and a shortcut
  (`shortcut`, `wflow`);
- a file that starts whatever it points to: a stored URL (`webloc`, `inetloc`, `fileloc`,
  `url`), a Terminal settings file and a Java Web Start file (`jnlp`).

Source code still opens, even when macOS marks its type as a program or a shell script:
JavaScript (`js`, `mjs`), TypeScript (`tsx`), PHP, makefiles, object code (`o`), a Java class and
a dynamic library (`dylib`).

A file that these rules would open still shows in Finder when the app that opens it would run it,
or when Bifrost can't check that app. Launch Services gives the file's own app and the default
app of its type, and Finder shows the file when:

- the two apps aren't the same app, or only one of them exists. A per-file Open With binding (the
  extended attribute `com.apple.LaunchServices.OpenWith`) can name any app on the disk for one
  file;
- the app has no bundle ID;
- the app is a terminal (an app that declares `public.unix-executable`, such as Terminal) or a
  launcher: Java Launcher, Python Launcher, Wish, Installer, Automator Installer, System
  Settings, Profile Helper or Keychain Access;
- Launch Services gives no answer within 5 seconds, or lists no terminal at all. Terminal is
  always there, so an empty list means Launch Services didn't answer. Only one lookup runs at a
  time, and the 5 seconds include the wait for an earlier link's lookup, so while one lookup
  hangs, a file link you click after it shows in Finder.

The rest of the link rules:

- The result depends on the apps of the Mac: a `.js` file that opens in a terminal shows in
  Finder, and the same file opens when its default app is an editor.
- A file opens in the app that the rules checked. A file with no app at all opens without one,
  and macOS asks you to choose an app.
- If you click another link before the previous link's action is ready, the older link does
  nothing. The opens are asynchronous, so the window never waits for Launch Services.
- A file with an execute bit, a package and an alias file show in Finder. So does a plain file
  with the extension of a package type (for example `workflow`), because macOS hands it to that
  type's app. A plain folder opens in Finder, even when its name has a script extension.
- A path that holds a NUL, a missing file and a link over 4,096 Characters do nothing.

## The scroll bar and the screen

The terminal follows a few rules of its own, which mostly matter after an attach has ended and the
window falls back to the normal screen.

- The vertical scroll bar shows only while the normal screen has lines above it. The alternate
  screen, which `claude attach` always uses, has none.
- The scrollback holds 500 lines.
- To find the first text of an attach and the agent view, the window reads the rows of the live
  screen, never a scrolled-back position. It keeps the white space inside each row, and trims the
  end of a line only after joining wrapped rows.
- A reset of the terminal clears its lines and updates the scroll bar.
- The terminal font comes from the settings.
- The terminal draws with Metal. Core Graphics is a hidden fallback that you turn on with
  `defaults write <bundle ID> TerminalRenderer cg`.
- A hidden terminal (a minimised frame or a back tab) stops its Metal renderer and keeps its PTY
  and its screen. It starts drawing again when it shows.

The xterm.js WebGL workarounds, the DOM focus code and the terminal's CSS rules weren't ported,
because the native terminal doesn't need them.

## The Take control loader

Take control moves a session that's running in another terminal into Bifrost, and that takes a
few seconds: the other terminal's process has to end, the session has to resume in the background,
and the chat window has to attach to it. Meanwhile the chat window shows the Take control loader
over its terminal. The loader is a layer over the whole chat body with the line "Taking control
of fix-a..." (or "Taking control..." when the row has no name), and a soft band in the colours of
the window background in the bottom two fifths. The line leaves out any hidden character of the
name, and a long line wraps.

The action runner tells the chats when Take control starts, fails or works, and the loader follows
these rules:

- It shows from the start of Take control. If Take control fails, the loader goes and the window
  closes.
- The window doesn't attach while Take control runs. The row can show the new background process
  as a running owned session a few seconds before Take control has checked that the process
  stays, and an attach from that moment might not be the moved session. So the window attaches
  when Take control ends, by itself, and you never have to close it and open it again.
- Once Take control has worked, the loader stays until the terminal shows Claude: the first text
  of the new attach, or the line that says why the window ended, so that line is never hidden. If
  the terminal showed Claude while Take control was still running, which only an attach that had
  started before it can do, the loader goes as soon as Take control finishes.
- A loader that's only waiting for that first text gives up after 20 seconds, and the window then
  shows the terminal, with its note if it can't attach. While Take control is still running, there's
  no time limit.
- If Take control works while no chat window of the session is open, there's nothing to wait for,
  so the loader goes at once. Closing the window of a loader that's waiting ends it too, and so
  does closing the main window. A loader of a Take control that's still running stays until that
  Take control fails or works.
- A second Take control while a loader waits starts the loader again, with no time limit until it
  works.
- The loader belongs to the row ID of the session, which never changes, so a `/clear` that gives the
  session a new current ID doesn't move it off the window.

While the loader shows, the terminal and its note are transparent, so the window shows the panel
background and the line. The terminal keeps its size and its focus underneath, so the attach
doesn't change, and a click goes through the loader. The window learns that the terminal shows
Claude by observing the terminal's `isShowingText`, which changes only at the steps of the attach,
so a chunk of output costs the loader nothing.

The look has these values (`LoaderLook.standard`):

| Part | Value |
| --- | --- |
| The line | 13 units, the text colour, centred, its top at 40 % of the height, 16 units from the sides, wrapping |
| The band | The bottom two fifths of the window, at 25 % opacity |
| The colours | The stops of the background's base gradient (`Motion.baseColours`), from the left to the right at 100 degrees: green (`icon-4`), blue (`icon-5`), violet (`icon-6`), red (`icon-1`) and violet again. The loader reads the same list as the background, so it changes whenever the background's colours do |
| The fade | From transparent at the top edge to full strength at the bottom: 3 % at 15 %, 10 % at 30 %, 20 % at 45 %, 38 % at 60 %, 60 % at 75 %, 85 % at 90 % |
| The motion | The gradient is twice the band's width and shifts from one end to the other in 12 seconds, then back, on the ease-in-out curve |

With Reduce motion on in the Accessibility settings, the band doesn't move. A screen reader
hears the line when the loader shows.
