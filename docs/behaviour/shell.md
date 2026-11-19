# The app shell: behaviour

The app shell is everything around the panels: the checks that decide whether the app may start
at all, the order in which its services come up, the main window and its menus, and a test port
for automated tests. The Electron app was a reference for behaviour only (user rule, 2026-11-16),
and the places where the native app differs from it on purpose are listed in
`docs/ports/shell/DELIBERATE-DIFFERENCES.md`.

The code is spread over a few places. `App/Bifrost` holds the app delegate. `BifrostApp` holds the
start checks (`StartRule`, `StartGuard` and `UpdatePolicy`), the services (`AppServices` and
`StartPlan`) and the test port. The app's identity is in
`BifrostFoundation/Model/AppIdentity.swift`, the shared paths of the home are in
`BifrostFoundation/Model/SharedClaudeState.swift`, the session list model is in
`BifrostSessions/Services/SessionListModel.swift`, and `BifrostWindows` has the window, the menu,
the side bar and the panels.

## Which app may start

Two builds of Bifrost can live on one Mac, the release app and a development app, and they must
never share data. These checks run before anything else so that a wrong build stops early.

- The bundle ID decides the identity, and the development app's bundle ID ends in `.native-dev`.
  An app with no usable bundle ID doesn't start. A Debug build with a release identity doesn't
  start either, so it can never use the data folders of the release app.
- The development app may always run. The release app runs only when the build sets the cutover
  condition, and no build sets it before cutover.
- The updater starts only for the release app, and only when it has a feed URL and a public key.
  The development app never updates itself.
- The release app ignores `BIFROST_TEST_HOME`. In the development app, a test home that the app
  refuses (for example the real home or one of its parents) stops the app with a message.

## The start order

The app makes the services before its launch ends. They create the notifier, the Event log and
the account usage poller at once (a test home gets the recorder of the notifications and no
poller), so the notifier is in place before a click on a notification can arrive.

`AppServices` creates the session list model straight away in the status "starting", so the
window has something to show at once. Before the window appears, it runs the one-time import of
the Electron app's data (described in `docs/behaviour/import.md`) and then opens the UI stores, so
no store ever opens a file that the import is about to replace. `start()` waits for that same
import, then does the rest in this order:

1. Open `settings.json` and `registry.json`. The window applies the settings straight away. Then
   `usage-alerts.json` opens and the usage notification starts to follow the usage values, and
   the account usage poller starts when Account usage from Anthropic is on.
2. Find claude and the base environment of each claude run.
3. If there's no claude, the list shows "claude not found" and nothing more starts.
4. Create the PTY manager of the chats with the claude runner.
5. Create the registry with the escalation time and the poll interval from the settings, and
   point the session list at it. The list keeps no copy of the rows and reads them straight from
   the registry, so the window, the chats and the session input always see the same rows in the
   same turn. A later change to either setting reaches the registry. The Event log starts to
   read the registry's state events, and the PR lookup of Show Info gets the environment of the
   claude runs.
6. Create the Live details control, with its server on the shared socket of the shared home, and
   the skills control, and start both in the same turn of the main actor, Live details first.
   Each start runs in the background in the lock of the plugin changes, in the order of the
   calls: the clean-up of the old hook data and the Live details start rule
   (`docs/behaviour/live.md`), then the skills start rule (`docs/behaviour/skills.md`). The
   registry doesn't wait for them. With no claude there's no control at all.
7. Start the registry.

The window's Settings sections for Live details and the skills, the warning dot on the side bar's
Settings button and the Setup dialog all read one live model (`LiveModel`), which the shell makes
with the window, before the side bar first draws. Once the services have found claude, the model
gets the two controls and a check of the Claude Code version against Bifrost's own minimum. With no
claude it gets no controls, only the app's bundled skills folder, so Settings > Skills can still
list the skills. When the settings store opens, the shell hands the same model to the Settings
panel, gives Settings > General the version notice, and sets up the Setup dialog. With a test home
the dialog only opens by itself when the environment has `BIFROST_TEST_SETUP=1`. The model reads
again on its back-off while a warning shows, the window becoming the key window counts as a focus
for that back-off, and the quit stops the model.

The session list counts as loaded from the first update of the registry, even one that carries an
error, and never before it, so until then a chat says it's waiting for the session list. No later
update replaces "claude not found".

`StartPlan` only works out values: how to find claude, whether a test home forces the Live
details listen, the home of the plugin commands, the socket of the debug test port, whether the
app records its notifications and polls the account usage, the folders the branch reader skips,
the store files, the shared home and the Electron folder to import from. It reads no file and
creates no folder.

## The window and the menu

The main window holds everything the user sees, and the menu bar gives the macOS items plus the
View items that change how the window is shown.

- The window shows the moving background behind the side bar (on the left edge) and the canvas.
  The window tells the services whether it's visible, meaning not closed, minimised, hidden or
  fully covered, so that a hidden window polls less often.
- Closing the window detaches each chat and saves the layout. Quitting waits at most 2 s for the
  last writes, the notified periods of the usage notification and the last save of the Reviews
  store included, so a write that never finishes can't hold up the quit.
- The app menu has About, Check for Updates…, Hide, Hide Others, Show All and Quit, and the Edit
  menu has the standard text items. The View menu has Window, Borderless and Fullscreen, then
  Zoom In, Zoom Out and Actual Size, and the Window menu has Close Panel, Minimize and Zoom.
- Fullscreen is a toggle with its own key (Ctrl+Cmd+F by default), and macOS adds no full-screen
  item of its own. There's no Reload and no developer tools item.
- The menu is rebuilt only after a key changes. The View items get their check mark from the
  display mode each time the menu checks them.
- While the key recorder of Settings > Keys records, the menu keeps showing its keys, but the
  window gives every key to the recorder before the menu sees it. So Cmd+W, Ctrl+Cmd+F or Cmd+Q is
  recorded rather than run, and the menu needs no rebuild for the recording.
- The Window menu has no item that closes the window: the Close Panel key (Cmd+W by default)
  closes the active panel instead.
- A Bifrost menu item that can't do anything is greyed out, and its key doesn't run it. That
  covers the display mode items and Fullscreen while the window is closed, Close Panel while no
  panel shows (no frame, or only minimised frames), the Zoom items until the settings have loaded,
  and Check for Updates while the updater can't start a check.

## The Overview

The Overview is Bifrost's table of sessions. With no saved layout, the window opens with the
default layout, which has the Overview at the top left and the Selected Item to its right, and
otherwise the saved layout decides which panels show. The shell builds one model that every
Overview and every Overview Settings panel shares, so they all read the rows from the one session
list and share the selection, while each Overview keeps its own tabs. A row of an external session
whose terminal app Bifrost knows shows that app's icon, which Bifrost looks up once for each app.
Everything else the Overview does is in `docs/behaviour/overview.md`.

## The test port

Automated tests drive the app through a test port, which only Debug builds have.

- The port is a Unix socket in the test home, with mode 0600 inside a folder of mode 0700, and it
  lets a test read the app's state and type into a session. Only a Debug build contains this
  code, and only a development app with a test home starts it.
- A request is one JSON line, and the parse is strict: an extra field or a bad value isn't a
  request. The port logs no request and no answer, because a request can hold text for a session.
- Besides the frames, the chats and the window, the state gives the report of this start's import
  and, for each Overview, its active tab, its sort and its rows in the order they show. An
  `overview` request sorts an Overview's active tab the way a click on a column header does, and
  it answers with an error when that Overview isn't open or its active tab hides the column. With
  these, the smoke test checks the import and the Overview from the outside.
- The state also gives the saved settings, as settings.json has them, and the key of each item in
  the app's menu. A `setting` request changes the settings with a patch, which is an object of
  settings.json fields with their new values, in one edit of the settings store (`SettingsPatch`).
  The check is strict, so the first bad field refuses the whole patch and nothing changes. A key
  patch only changes the slots it names, and a new conflict is refused with "Two actions can't
  share the same key." That's how the smoke test checks that a change reaches settings.json and
  that a new menu key reaches the menu.
- For the panels of phase 4e, the state gives the Event log (the number of entries and the texts
  of the newest five), the Usage HUD (each bar and the source line, which never hold the token),
  the rows the Watchlist shows (null while it's in no frame) and the PR line of each Show Info
  panel. With these and the `open` request, the smoke test checks that a Live details line
  reaches the Event log, that a watched row shows in the Watchlist, and that Show Info gets the
  PR of the fake `gh`.
- The state also gives the status of Live details (`live`) and of the skills (`skills`), as the
  Settings sections have it, or null before their first read. A `live` or `skills` request runs
  one of the four actions (`install`, `enable`, `disable` or `uninstall`) the way the section's
  button does, except that Remove doesn't ask first, and it answers when the action has ended,
  with the failure's text as the error. The smoke test uses these to install Live details, send it
  a line, turn it off and install the skills, all in the test home. The state's `sessions` lists
  each row with its state, its process ID and whether the active list has it, and a `resume`
  request runs the Resume command on one row and answers with the refusal's text. The smoke test
  uses those two to check that Resume refuses a row in the moments after a start.
- An `action` request runs a session action through the action runner, just as a click on its button
  would, and a `send` request types a text into a session the way the send box does. An action names
  its ID and, unless it's New session or Resume all, the session. The port answers the dialogs the
  action opens: a confirmation gets a yes only when the request says `"confirm":true`, and a no
  otherwise; Rename saves the name the request gives; New session starts in the folder the request
  gives, with its name or the suggested one. The port refuses an action that needs a choice from a
  menu (Set priority, Open project, Change colour), one that reaches outside the test home (Copy
  session ID, Open in terminal, Take control) and one that only moves the focus (Send message, Run
  slash command). The answer comes once the action has finished (for New session, once the start
  has ended, although its dialog closes earlier), or with the reason when the action is off, a
  dialog didn't save or the action didn't end within 25 seconds. The state then shows the
  selected row, the notice and error lines, whether a dialog is open and which rows have an action
  still running. With these the smoke test sends a message, renames, starts, stops and deletes
  sessions through the fake `claude`.
- For Reviews, the state's `reviews` gives each row of the two tabs (its PR, its tab, whether it
  flashes or is paused, the text on its right, and the step of a round while one runs), whether
  the automatic rounds have your consent, and the panel's problem line. A `reviews` request clicks
  Review or Pause on a row the way its button does, and gets an error when the row doesn't offer
  that button right now. With these and the fake `gh`, the smoke test turns Reviews on, sees a new
  request flash, pauses it and runs a review round against a local repository in the test home.

## Not ported

Some Electron pieces have no counterpart in a native app and weren't carried over: the main
process, the preload bridge, the renderer entry and the Playwright `app.evaluate` hook. A few more
Electron behaviours around the shell have no phase 4 task, either because the native app doesn't
need them or because a later phase brings them:

- The race between the first answer of the session list and an update that arrives over IPC is
  dropped, because the native app is one process and the race can't happen.
- The CSS class helper, the JavaScript error helper and the JavaScript type check are dropped, as
  they only served the web code.
- The Electron network rules and the page guard are dropped, since a native app loads no web page
  and has nothing for them to guard.
- The UUID check isn't needed, because a session ID is parsed once into the `SessionID` type.
- The job runner comes in phase 7.
- The spawn lines, the rotating log, the hand-over source, the GitHub URL rules and the
  invisible-character rules come in phase 5.
