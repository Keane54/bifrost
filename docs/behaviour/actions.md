# Session actions: behaviour

The session actions are the things you can do to a Claude Code session from Bifrost: start a new
one, stop it, delete it, resume it, or take control of one that's running in another terminal.
Each of them ends up running a `claude` command or signalling a process, so they share a set of
rules: what a new session's values may be, which ID a command needs, how to read what `claude`
prints, how to look at a process or a folder safely, and what to tell you when something can't
be done.

Those shared rules live in `BifrostSessions`. The New session values are in
`Model/NewSession.swift` and the form that collects them in `Model/NewSessionForm.swift`, the IDs
of a row in `Model/SessionIDs.swift`, the reading of claude's output in `Model/ClaudeOutput.swift`,
and the refusals in `Model/Actions/ActionRefusal.swift`. The action model, which decides whether
each action is on for a row, is in `Model/Actions/ActionModel.swift`, with its reasons in
`ActionReasons.swift` and the row menu in `RowMenuModel.swift`. What an action does once you choose
it is in `RunPlan.swift` in the same folder, alongside the confirmation dialogs in
`ConfirmText.swift`, the Rename dialog's rules in `RenameRules.swift` and the notices during a
Delete in `NoticeLines.swift`. The session commands themselves (New session, Stop, Resume, Resume
all, Delete and Take control) are the `SessionActions` class in
`Services/Actions/SessionActions.swift`, and the
arguments they give `claude` are in `Model/Actions/SessionCommandArgs.swift`. The process probe and
the signals are in `Services/Actions/ProcessProbe.swift`, and the same folder holds the helpers
that the commands and the menus lean on: the worktree check (`WorktreeChecker.swift`), the
transcript check (`TranscriptReader.swift`), the installed apps (`ProjectApps.swift`), Open in
terminal (`TerminalLauncher.swift`), and Open project, Copy session ID and Open the worktree
(`AppActions.swift`). Hand over lives in the same two folders: its prompts and names in
`Model/Actions/HandOverText.swift`, the reading of its reply in `HandOverReply.swift`, and the run
itself and the note file in `Services/Actions/HandOver.swift` and `NoteFile.swift`.

The parts that you see live in `BifrostWindows/UI/Actions/`, because they use the window's layout,
selection and chats: the action runner (`ActionRunner.swift`) with its notice and error lines
(`TimedLine.swift`), the dialogs (`DialogHost.swift`, `ConfirmDialog.swift`, `RenameDialog.swift`
and `NewSessionDialog.swift`), the row menu (`RowMenu.swift`) and the macOS side of opening apps
and copying text (`WorkspaceApps.swift`). The Selected Item panel and its send box are next door
in `BifrostWindows/UI/SelectedItem/`, and the texts of the panel's status icon are in
`BifrostSessions/Model/Actions/StatusTexts.swift`. The shell (`BifrostApp/UI/Shell.swift`) puts
all of this together in the running app, as "The action runner" describes. Where the native app
deliberately differs from the Electron app, `docs/ports/actions/DELIBERATE-DIFFERENCES.md` explains
how and why.

## Which actions are on

Every button, menu item and key of a session action asks the action model first, and the model
answers with the action's state: on, or off with a reason that the tooltip shows on a second line
under the action's name. The session commands check their own rules again when they run, so the
model only decides what you can click.

The model sorts a row into one of three classes. A parked row is parked whatever its kind, and
any other row is owned (a session Bifrost started) or external (one running in another terminal).
Some actions only make sense for some classes:

| Actions | For |
| --- | --- |
| Open, Send message, Run slash command, Compact, Hand over, Interrupt, Stop session | Owned rows |
| Resume | Parked rows |
| Take control | External rows |
| Open in terminal | Owned and external rows |
| Delete session | Owned and parked rows |
| Everything else | Every row |

The rules run in a fixed order, and the first one that matches gives the reason:

1. With no row (the session has gone from the list), every action is off: "This session isn't in
   the list any more."
2. Add to watchlist is off for a watched row, and Change colour and Remove from watchlist are off
   for a row that isn't watched.
3. Stop on a parked row is off, because there's nothing to stop.
4. An action that isn't for the row's class is off. The reason says the action only works for an
   external or a parked session when that's its only class, and otherwise says the row runs in
   another terminal or is parked.
5. Hand over is off for a review session of a pull request, and so is Resume, since its next
   round is a new session.
6. Close window is off while the chat window is closed.
7. Open project needs a project folder (an absolute path) and at least one installed app.
8. Stop, Delete, Resume, Take control and Hand over are off while another action runs on the
   same session.
9. A red box of a prompt turns off Send message, Run slash command, Compact and Hand over, since
   typed text could answer the prompt by accident. An escalated box or an error box doesn't.
10. Send message, Run slash command, Compact, Hand over, Interrupt and Stop need the short ID of
    the session, and so does Open in terminal for an owned row.
11. Compact and Hand over wait while the session is working on a reply.
12. Take control is off while the session works, while it has any red box, without a process ID,
    and without a project folder.
13. Resume needs a project folder.
14. Open in terminal needs an installed terminal app (Warp, Ghostty, iTerm2 or Terminal) for an
    owned row, and for an external row, the terminal app it runs in.

So Hand over is on for an owned session that's idle, has its short ID and has no red box, and
isn't a review session. What it does is in "Hand over" below.

Delete stays on when another session shares the row's worktree. That changes what Delete does,
not whether you can choose it.

New session and Resume all don't need a row. New session is always on. Resume all is off while it
already runs, and when none of the parked sessions were active when Bifrost last closed.

The Selected Item panel shows Open, Send message, Run slash command, Compact, Hand over,
Interrupt, Show Info, Open in terminal and Stop session as buttons, and hides Open while the chat
window is open (see "The Selected Item panel"). The Hand over button turns to its warning colour
once the session's context is at 80 percent or more, rounded to the nearest whole percent.

Each action has a plain label and a space label, and the labels setting picks the set, so Open
can read "Warp to" and Delete session "Self-destruct". Send message, Rename, Stop session and
Delete session ask for more before they act, so their labels end in "...". A tooltip shows the
name without them.

## The row menu

Right-clicking a row in the Overview opens its menu, with its entries in three groups:

- Open (only while the chat window is closed), Send message, Run slash command, Compact, Hand
  over and Interrupt;
- then Set priority, the watchlist entries, Rename, Show Info, Copy session ID, Open project and
  Open in terminal;
- then Take control (external rows only), Resume (parked rows only), Close window (only while the
  chat window is open), Stop session and Delete session.

A separator sits between the groups. A few entries depend on the row or the chat window, as
marked above and in the watchlist entries below. Every other entry shows for every row and is off
with its reason where it doesn't apply.

A row that isn't watched gets Add to watchlist, and a watched row gets Change colour and Remove
from watchlist instead. Five entries open a submenu:

- Set priority lists 1 to 5 and None, with a check mark on the row's priority, or on None.
- Add to watchlist and Change colour list the eight colours (Dark red, Red, Amber, Yellow, Green,
  Light blue, Dark blue, White), and Change colour marks the row's colour.
- Open project lists the installed apps.
- Run slash command lists your favourite slash commands, then up to five recent ones that aren't
  favourites, then Other..., which opens the send box for a command. A separator comes before the
  first recent command and before Other...

The menu is a Bifrost menu (`docs/behaviour/menu.md`) that opens at the point of the right-click.
An entry that's off keeps its place, greyed out, and its tooltip gives the title and the reason on
a second line, such as "Stop session" and "This session is parked, so there's nothing to stop.". A
submenu that's off doesn't open. Set priority and Change colour mark their current choice with a
check, and each choice has a small square in its colour: the priority colour for 1 to 5 (None
keeps the space of the square, so the labels line up) and the watch colour for each colour. Add
to watchlist shows the colour squares too, with no check.

While the menu is open, its entries follow the row, as in the Electron app: when the session
stops, starts working or turns grey, the entries that change turn on or off straight away, with
their new reasons. Choosing an entry still runs the action on the row as it is at that moment, so
a choice that lands just before a change does nothing, as it would from a button. If the row
leaves the list while its menu is open, for example because the session was deleted, the menu
closes. A press outside the menu only closes it, as with the Electron context menus, so it doesn't
also select another row or press a button.

## What an action does

Once you choose an action, the run plan says what the action runner should do with it. The plan
is a plain value, so the runner only has to carry it out. An action that's off for the row plans
nothing, which is why clicking it has no effect, and the same goes for a menu choice that doesn't
fit the action.

| Action | What happens |
| --- | --- |
| Open | The chat window opens, or comes to the front |
| Close window | The chat window closes |
| Send message | The Selected Item panel opens with its send box focused and empty |
| Run slash command | The command you picked from the submenu is sent; Other..., or no command, focuses the send box with `/` in it |
| Compact | `/compact` is sent straight away, with no argument and no confirmation |
| Rename | The Rename dialog opens |
| Show Info | The session's Show Info panel opens |
| Stop session | The session stops, after a confirmation only while it's working |
| Delete session | The session is deleted after a confirmation, and its chat window closes |
| Take control | The session is taken over after a confirmation, and its chat restarts |
| Resume | The session resumes, and its chat restarts so an open window attaches again |
| Set priority, Change colour, Open project | The action runs with the priority, colour or app you picked |
| Add to watchlist | The session joins the watchlist in the colour you picked, or in light blue from a button or a key |
| Interrupt, Copy session ID, Open in terminal, Remove from watchlist, Hand over | The action runs with no confirmation |
| New session, Resume all | Nothing here, because they don't need a row |

Take control opens the chat window with its loader before the takeover starts. Afterwards the chat
restarts, because a terminal that has ended only attaches again after a restart. Open project only
runs with an app from the installed list, and Show Info needs a row whose ID is a session ID.

Send message and Run slash command select the row, open the Selected Item panel and then hand the
focus straight to its send box. Opening the panel is immediate, so the box already shows the row
when the focus arrives, and asking twice in a row focuses the box twice.

Clicking a notification opens that session's chat, but a new window can get the click before it
has its rows. The open then waits for the row, and once the session list has loaded without it,
the open is dropped.

A Delete can fail after the session has already left the list, which happens when a deferred
`claude rm` fails. When the row has gone, the chat window closes just as it would after a Delete
that worked, and the error stays.

## The action runner

The action runner is what carries out a plan. A button, a menu entry or a key gives it the action
and the row's ID, never the row itself, so it always reads the row as it is right now and plans
from that.

The shell makes one runner for the window at the first change of the session list after the services
have found `claude`, usually the first poll, because the runner needs the session commands, the
session input and the registry that only exist from then on. It then hands the runner to the keys,
the side bar's New session and Resume all buttons, the Overviews (a double-click runs Open, and a
right-click opens the row menu) and the Selected Item panel. Until that moment none of these can
act: the keys and the buttons do nothing and the Selected Item panel stays empty, which is also what
you see if Bifrost can't find `claude` at all. The runner reads the settings each time it needs
them, from the settings store, which is observable, so a change such as the space labels reaches the
buttons, the tooltips and the menus straight away.

Once it has a plan, it opens the chat, the panel or the dialog, or runs the call:

- While a call runs, the session counts as running, and so does a session that the session
  commands hold, such as one Resume all is working on, one whose Stop is waiting for its row to
  park, or one whose `claude rm` is still going. Stop, Delete, Resume, Take control and Hand over
  are then off with "Another action is still running on this session."
- A Delete first runs the check for unmerged work, with "Checking for unmerged work..." in the
  notice line, and then asks with the texts that fit the result of that check. A Delete in a folder
  that another session uses runs no check and asks with the shared-folder text. If that other
  session goes while the dialog is open, the folder would be removed after all, so once you say
  yes the runner runs the check and asks again with whatever unmerged work it finds. Once you
  confirm, "Deleting the session..." stays in the notice line until the Delete ends. After a
  Delete, the chat window closes and the row is no longer selected.
- Take control selects the row and opens its chat window with the loader before the takeover
  starts. If it fails, the loader goes and the window closes. If it works, the chat restarts, and
  the loader waits for the chat's first output. The chat doesn't attach while the takeover runs,
  so its first attach is to the session that the takeover moved.
- Resume restarts the chat, so an open window attaches again.
- Hand over shows "Writing the hand-over note..." in the notice line while it waits for the note,
  and the session counts as running the whole time. After a good hand-over, the old session's
  chat window, if it's open, shows the new session instead, the new row is selected, and the old
  session is stopped so that it parks. The notice line then says "Handed over to <name>.". A
  hand-over that fails shows its reason in the error line. The park waits for a fresh check that
  the old session is still quiet, and when the check fails, the old session keeps running and the
  error line says why. If the old session won't stop, the error line says "The new session
  started, but Bifrost couldn't park the old one." with the reason after it. "Hand over" below has
  the steps.
- A send types the text into the session through the session input. A `/rename` then clears the
  local name, and any other slash command goes first in your recent slash commands (see "Rename").
- Resume all says "Resumed 1 session." or "Resumed 3 sessions." in the notice line, and lists the
  sessions it couldn't resume in the error line, each as its name and its reason, separated by
  semicolons. When it resumed nothing and some sessions failed, only the error line shows, so a
  skipped session never hides behind "Resumed 0 sessions.". A second click while it runs does
  nothing.
- While Resume, Resume all or Delete checks the session list before it decides (see "The check of
  the session list" below), the notice line says "Checking sessions...", over any other notice.
- New session hands the start back to its dialog as soon as `claude --bg` begins, so the dialog
  can close, and carries on with the rest of the start in a task of its own. Until the new row is
  in the session list, the Overviews show the start as a Starting… row. A start that works then
  selects the new row and opens its chat, and one that fails says why in the error line ("New
  session" below has the details).

Once a command has started, nothing in the window stops it, so a start you've asked for always
gets to finish. Only quitting Bifrost stops a command that's running, as "The session commands"
below describes.

### Notices and errors

The runner keeps a notice line and an error line for the Selected Item panel to show. A notice
shows for 5 seconds, and a new one replaces it and gets the full time again. An error stays until
you close it or the next error replaces it, because an error can be long and you need time to read
it. While a Delete runs, the notice line follows the rules in "Notices during a Delete".

The Electron app had no unit tests for its runner, so the runner's tests (`ActionRunnerTests`) are
new. They cover an action that's off doing nothing, the order of the Delete check and its
confirmation, the busy notice, the 5-second notice and a notice that waits for a Delete, the
loader of Take control, the sends and what they change, a failed Delete closing the chat of a
row that went, the "Checking sessions..." notice, a Resume all whose only results are failures,
and a hand-over's running mark and what happens after a good one. When the runner has the
window's chats, it hands them each step of the Take control loader, and the chat window shows the
loader ("The Take control loader" in `docs/behaviour/chat.md`).

## The Selected Item panel

The Selected Item panel is where you look at the session you've selected and act on it. It reads
the selected row from the session list by its ID every time something changes, so it always
shows the row as it is right now. When nothing is selected, or the selected session has left the
list, the panel says "No session selected." and shows the notice line and the error line of the
actions at its bottom, the error with a close button. In a frame that's too low for its content,
the panel scrolls.

With a row selected, the panel has four parts, from the top:

- The name line starts with the row icon from the Overview at 22 units, then the name in
  semibold, with the alias tip (the local name and the Claude Code name) as its tooltip, the state
  label in its tone, and the priority in its colour. A row with no priority shows nothing there,
  not even a dash. A status icon comes last, but only when there's something to say: its tooltip
  holds the error of the actions, the notice and the send box's line, one per line. It's the error
  icon when the actions have an error or a send failed, and the info icon otherwise, and clicking
  the error icon closes both the error and the failed send.
- The buttons come next: one icon button for each of the panel's actions (listed in "Which actions
  are on"), then the watch button. That's Add to watchlist for a row that isn't watched, which
  opens the colours of the row menu below it, or Remove from watchlist for one that is. A button
  runs its action on the row as it is at the click, and a button that's off keeps its place,
  faded, with the reason in its tooltip, which VoiceOver reads as its hint. The buttons never take
  the keyboard focus, so they aren't in the Tab loop, and from the keyboard the action keys do the
  same work.
- The facts are Project, Branch, Model and Cost, with "-" for anything the row doesn't have. The
  Model row also has the context bar, which fills to the context percent in the band colour of
  the percent it shows (green below 40, orange from 40 and red from 70), stays empty without a
  percent, and is followed by a text such as "40% context". The panel shows no preview of the last
  reply.
- The send box comes last, and the next section describes it.

Each button has its lucide icon:

| Action | Icon |
| --- | --- |
| Open | `app-window` |
| Send message | `message-square` |
| Run slash command | `slash` |
| Compact | `shrink` |
| Hand over | `arrow-right-left` |
| Interrupt | `hand` |
| Show Info | `info` |
| Open in terminal | `square-terminal` |
| Stop session | `power` |
| Add to watchlist, Remove from watchlist | `eye`, `eye-off` |

The panel is a SwiftUI view (`SelectedItemView.swift`) in a SwiftUI scroll view, with the AppKit
send box inside it as a representable. The body keeps one send box for its whole life
(`SelectedItemPanel.swift`), so the box keeps its focus while the view changes around it.
`SelectedItemModel` gives everything the panel shows as plain values, so the tests can read the
panel without clicking it.

### The send box

The send box is where you type a message for the selected session. It's a text box three lines
high, an AppKit text view (`SendBoxView.swift`) whose placeholder is the label of Send message,
and its drafts, sends and line live in `SendBoxModel.swift`.

- Each session has its own draft, which stays when you select another session and when the panel
  closes. A send that works clears the draft. A send that fails keeps it, and the failure becomes
  the send box's line until you change that draft or send again.
- Enter sends the draft, and so do Option+Enter and Ctrl+Enter. Cmd+Enter would send too, but
  with the default keys it's Open, and the window's keys take it before the box sees it.
  Shift+Enter adds a line, and Enter during an input method composition (when you type Japanese,
  for example) only finishes the composition. Tab and Shift+Tab move the focus, as in any text
  area. A draft of only white space sends nothing.
- A send counts as running from the key, so a second Enter starts no second send. You can select
  another session and type in its draft while the send runs, and the end of the send clears only
  the draft it sent.
- While Send message is off for the row, the box is off too: it's faded and can't take the focus.
  While a send of its session runs, it's read-only.
- Its line is the first of these that applies: the reason Send message is off, "Sending...", the
  failure of the last send, or "This runs as a slash command." for a draft that starts with `/`.
  The line shows in the status icon of the panel.
- When the selected session changes, the box gives up the focus straight away. It also checks the
  selection before every key and every change of its text, so a key can never land in the draft
  of another session, for example just after Take control selects a different row.
- Send message and Run slash command focus the box at once (see "What an action does"). The box
  first catches up with the selection, and it only takes the focus when it shows that session.
  Run slash command puts `/` into an empty draft, the caret goes to the end, and a low panel
  scrolls to the box. A box that's off takes neither the focus nor the text. A menu that started
  the action has already closed by then, so nothing takes the focus back.

A send goes through the action runner, so `/rename` clears the local name and a slash command joins
your recent ones, just as for any other send.

## The dialogs

The confirmations, the Rename dialog, the New session dialog and the Setup dialog ("The Setup
dialog" in `live.md`) are Bifrost boxes inside the window, never a sheet, an alert or a separate
window. They show in one layer over the canvas (`DialogHost`), which dims the canvas with the
background colour at 40 % and puts the box in its middle: 420 units wide, or 440 for New session
and the Setup dialog, and never closer than 16 units to the edges of a narrow canvas. The box has
the title colour, a border of the panel edge colour and the UI font at 13, with the title in the
strong text colour.

- Only one dialog shows at a time. A confirmation that's asked for while another dialog is open
  doesn't show, so its action doesn't run, and the notice line says "Another dialog is open.
  Finish that one first.". Rename and New session give the same notice.
- While a dialog is open, the keyboard focus is inside it, and the window treats every key as
  happening in a dialog, so none of Bifrost's own keys act. The focus stays in the dialog while a
  save or the checks of a start run, even though its fields are off then, and after a Rename save
  that fails, the name field has the focus again. A held key repeats in a field as usual, so a held
  Backspace deletes more than one character. When the dialog closes, the focus goes back to where
  it was.
- With Full Keyboard Access on, Tab reaches the buttons and the check boxes of a dialog, and Space
  presses the one with the focus. No button is the default one, so Return never confirms a
  Delete or any other question.
- Esc cancels a dialog. Clicking the dimmed canvas closes Rename and New session, but does nothing
  for a confirmation. While a save runs, Rename stays open, and New session stays open while it
  makes its last checks before a start.
- The Setup dialog ignores both Esc and a click on the dimmed canvas: only its own Skip and Done
  close it.

## Confirmations

Stop, Delete and Take control can ask before they act. The dialog has a title, a body and a
confirm button, all in the words of your label set, and it names the session by its name, adding
`(Claude Code name: <name>)` when the session has a local name so there's no doubt which one you
mean. Names, branches and terminal app names show without the hidden characters that a name can't
hold, so a bidi control can't make the rest of the text read backwards.

- Stop asks only while the session is working: "fix-a is working right now. Stop it anyway? The
  current turn will end." The space labels say "Power it down" instead of "Stop it".
- Take control always asks: "This closes the session in Warp and moves it into Bifrost." When
  Bifrost doesn't know the terminal app, it says "its terminal", and a session with a local name
  gets both names after "the session".
- Delete always asks. Its title is the verb and the session's name, such as "Delete fix-a" or
  "Self-destruct fix-a", and its body depends on what Bifrost knows about the session's worktree.

| What the Delete knows | Body | Asks twice |
| --- | --- | --- |
| Nothing unmerged, or the folder isn't a worktree | `Delete <name>? This removes the session from Claude Code and Bifrost.` | No |
| Unmerged commits or changed files | `This session has <work> on <branch>.`, or `in its worktree.` without a branch, then the changed-files sentence when there are changed files, then `Are you sure you want to delete this?` | Yes, with Open worktree |
| The check failed | `Bifrost could not check this session for unmerged work. Are you sure you want to delete this?` | Yes, with Open worktree when the session has a worktree |
| Another session uses the folder | `Another session still uses this folder, so Bifrost keeps it. Delete <name>? It goes from the list now, and Bifrost removes it from Claude Code when you delete the last session in this folder.` | No, and no check runs |

The work reads like "2 commits that are not merged and 3 changed files", in the singular for one,
and a count of zero leaves its part out. Changed files add "Claude Code keeps a worktree with
changes that are not committed, so commit or discard them first.", because `claude rm` won't
remove such a worktree. The body never says the conversation goes, since `claude rm` keeps the
transcript. With the space labels the verb is "Self-destruct" throughout, so the question becomes
"Are you sure you want to self-destruct this?". Open worktree shows the worktree in Finder and
leaves the dialog open, so you can look at the work before you decide. After a failed check, it
opens the worktree of the session's folder, or for a stopped session, the worktree Bifrost stored
while it ran.

The dialog has Open worktree on the left, when there's a folder to open, then Cancel and the
confirm button on the right. Cancel and Esc give no.

A dialog that asks twice changes its confirm button to "Delete anyway" (or "Self-destruct
anyway") on the first click, and only a second click confirms. That second click counts only 500
ms or more after the label changed, so a held key or a quick double click can't get through both
steps. The second half of a double click never counts as the second click, and neither does the
repeat of a held key.

## Rename

The Rename dialog has a "Name in Bifrost" field, an "Also rename it in Claude Code" check box and a
"Use the Claude Code name" button, which only shows when the session has a local name. The check
box only shows for a running session that Bifrost started, and even then it's off, with its
reason, while a prompt's red box is up ("Answer the prompt in the chat window first.") or before
the session has a short ID ("Waiting for the session ID.").

A save does one of two things:

- With the check box off, the trimmed name becomes the local name, which only Bifrost knows, and
  an empty name clears it. A local name can't hold control or hidden characters and can be at
  most 64 characters, counting what you see as a character.
- With the check box on, Bifrost types `/rename <name>` into the session and clears the local
  name, since the Claude Code name is now the one you chose. The name gets the same clean-up as
  any other text, with each run of white space turned into one space, and it can't be empty or
  longer than 64 characters.

If the check box is ticked but the session can't take `/rename` right now, for example because a
prompt came up, the dialog says "Bifrost can't rename it in Claude Code right now. Save keeps the
name in Bifrost only." and a save treats the box as unticked.

The dialog's title and its save button say "Rename" ("Set callsign" with the space labels), and it
reads the row afresh at every step, so the check box and the note follow the session while the
dialog is open. With the check box ticked, the `/rename` goes first, and the local name only
changes once that send has worked, so a failed send leaves everything as it was. A save that fails
shows its reason under the field and leaves the dialog open, and while a save runs, the buttons are
off and the dialog stays.

Sending `/rename` yourself, from the send box or Run slash command, has the same effect as the
check box, so the local name goes. That command also stays out of your recent slash commands,
because clicking it in the submenu would give its name to another session. A send counts as a
rename when it starts with `/rename`, after any white space, and white space or nothing comes next,
so `/renamex` is just another command.

## Notices during a Delete

A Delete can take a few minutes, and while one runs, its notice ("Deleting the session...") stays
in the notice line. Other notices don't replace it: the latest one waits, then shows for the usual
time once the last running Delete has finished. A notice that would stay until it's hidden, such
as "Checking for unmerged work...", doesn't show at all while a Delete runs, and doesn't come back
afterwards. A Delete that starts while that check notice is up replaces it. The one exception is
"Checking sessions...", which shows over the Delete's notice while a command checks the session
list, and then "Deleting the session..." is back.

## New session

The New session dialog asks for a project folder, a name, a model, a permission mode, an optional
first prompt and whether to start in a git worktree. Bifrost checks the values as you type, so the
dialog can show a reason early, and checks them again just before it runs `claude --bg`. The first
value that fails gives the reason, in the order folder, name, prompt.

- The folder loses any white space and any `/` at its end, though `/` on its own stays. It must
  then be an absolute path with no NUL character in it.
- The name and the prompt get the same clean-up as text sent to a session: CR LF and a lone CR
  become LF, and the control characters other than tab and LF go. Then the ends are trimmed.
- The name can't be empty, can be at most 64 characters, and must be one line, with no tab, line
  break or Unicode line or paragraph separator. It also can't hold the hidden characters that a
  local name can't: zero-width characters, the byte order mark and the bidi controls, which could
  make text after the name read backwards.
- The prompt can be empty, in which case the session starts without one, and can be at most
  20,000 characters. Both limits count what you see as a character, so an emoji or an accented
  letter counts as one.
- Neither the name nor the prompt can start with `-`, because `claude` would read it as a flag.
  The check looks at the first Unicode scalar, since `claude` reads the first byte, so a combining
  mark after the dash doesn't hide it.
- The prompt can't be just the name of a `claude` command, such as `update` or `help`, because
  `claude` would run that command rather than treat it as a prompt. The list holds every command
  and alias in the help text of Claude Code 2.1.318, plus `help`, the hidden commands, and
  `config` and `migrate-installer` from older versions. Only the whole trimmed prompt counts, so
  "update the docs" is fine.
- The model is Default, Opus, Sonnet or Haiku. Default passes no `--model` flag, so `claude` uses
  its own default. A model picker in Settings calls that same choice "Claude Code default".
- The permission mode is none (no flag), acceptEdits, auto, manual, dontAsk or plan.
  bypassPermissions is never offered.
- A worktree's name comes from the session name: it's lowercased, each run of characters outside
  a-z and 0-9 becomes one `-`, dashes at either end go, and it's cut to 40 characters, because
  Claude Code adds `worktree-` to it for the branch. A name with nothing left becomes `session`.

The dialog opens with the folder you used last, along with the model and permission mode of your
last new session, and suggests a name: the last part of the folder's path, cut to 40 characters,
then a dash and four random lower-case hex digits, such as `bifrost-a1b2`. The folder part drops
any hidden character that a name can't hold, so such a character in a folder name never makes the
suggestion fail the name check. A path with no last part, or one made only of hidden characters,
gives `session-a1b2`. Choosing another folder suggests a new name, unless you've typed in the name
field, in which case your name stays. It also turns the worktree option off, because the new
folder has to be checked first.

The dialog shows the folder field with a Recent menu of the folders it offers (your recent folders,
then the project folder of each session) and Choose..., which opens the macOS folder panel at the
folder you've typed (without any spaces around it) and can make a new folder. Below come the name,
the model and the permission mode side by side, the first prompt ("Optional"), and the worktree
check box. A plain Return in a field, or Enter on the numeric keypad, starts the session, as long as
the input method has no text waiting, and Shift+Return adds a line to the prompt. Return with
Option, Control or Command never starts a session. The folder check runs 300 ms after the last
change of the folder.

When you start the session, the fields and buttons go off and the dialog says "Starting the
session..." while Bifrost makes its last checks: that no other start is running, that it can find
`claude`, and that the folder exists (and is in a git repository, for a worktree). If one of them
fails, the dialog shows the reason and puts the focus back in the folder field. Once they pass,
`claude --bg` starts and the dialog closes straight away, rather than waiting for Claude Code,
which takes several seconds to get a new session going.

From then on the start shows in every Overview tab, after the tab's own rows, as a Starting… row
with the session's name and project. It's a placeholder rather than a session: it has no icon, no
row menu and can't be selected, and the tab's filters don't hide it. As soon as the session list
has the real row (Bifrost reads the list the moment `claude --bg` ends), that row takes its place.
The start is done once Claude Code gives the session a process ID, a few seconds later: Bifrost
then remembers the folder, the model and the permission mode for next time, selects the new
session and opens its chat. If the start fails after the dialog has closed, the Starting… row
goes, and the error line says "<name> didn't start." followed by the reason. Only one start runs at
a time, so a New session dialog that you open while one is starting refuses its own start with "A
new session is already starting. Please wait."

The worktree option is only available once the folder check says the folder exists and is in a
git repository. Until then it's off with one of these reasons, and a folder that doesn't start
with `/` once it's trimmed isn't checked at all.

| Folder | Reason |
| --- | --- |
| Doesn't start with `/` | `Choose a project folder.` |
| The check is still running | `Checking the folder...` |
| The check failed | `Bifrost couldn't check this folder.` |
| Missing, or not a folder | `This folder doesn't exist.` |
| Not in a git repository | `This folder isn't in a git repository, so it can't use a worktree.` |

## The IDs of a session

A row in the session list keeps the first session ID Bifrost saw for it, and that row ID never
changes. A `/clear` starts a new conversation in the same session, so the row also has a current
ID, the conversation it shows now, which is the row ID until something changes it.

When an action resumes a session, it needs the ID that continues it:

- For a background session that Bifrost started (an owned row), that's the resume ID, the
  session ID of the original job. Resuming by any other ID would start a second job, so until
  Bifrost knows the resume ID, the action is refused.
- For an interactive session in another terminal (an external row), it's the current ID.
- The ID goes straight into a `claude` argument, so it must be a session ID (a UUID). Any other
  text gives no ID.

## The session commands

New session, Stop, Resume, Resume all, Delete and Take control are the commands that start, stop
or remove a session, and each one runs a `claude` command and then, for a start, waits for the
session to show up in the list. A caller only ever hands over a row ID or the checked values of
the New session dialog, plus, for Delete and Take control, whether you confirmed, and for Delete,
the counts its dialog showed. The command looks the row up itself, checks it again, and builds
the `claude` arguments, so it never trusts a process ID or a path from the caller. Delete and Take
control have sections of their own below.

Every command runs as a job, which holds a lock from its checks to its end:

- Only one action runs on a session at a time. The check of the lock and the lock itself happen in
  one step, so two clicks can't both get through, and a second action gets `Another action is
  still running on this session.`
- Only one New session start runs at a time, so a double click starts one session.
- Only one Resume all runs at a time, and it holds the lock of every session it resumes until it
  has finished. A session that already has an action running is skipped, and shows up in the
  result as a failure.
- A job that fails or is refused gives its locks back straight away. The one exception is a
  Delete whose `claude rm` still runs: the session stays locked until that command ends.

Each `claude` command gets 60 seconds, apart from the `claude rm` of a Delete, which has its own
limit (see Delete). A start, `claude --bg` with or without `--resume`, gets
SIGTERM rather than SIGKILL when it hits that limit or its job is cancelled, so `claude` can end the
start cleanly instead of leaving a half-started session. If it's still running 5 seconds later, it
gets SIGKILL, so the job always ends and frees its locks. `claude stop` gets SIGKILL straight
away. Exit code 0 isn't proof that a session started, so a start also waits up to 30
seconds for its row to appear in the session list. The commands read the rows
of the registry, the one place the rows live, so the row that ends the wait is already in the list
Bifrost shows, and a start can give its result at once.

Claude Code lists a new session the moment `claude --bg` ends, so New session doesn't wait for the
next poll to find it: it reads the active list straight away, and the new row shows in the list
then. The session has no process ID at that point, and Claude Code takes about five more seconds
to give it one, so the start then waits for an ordinary poll to bring the process ID. If that read
fails, the rows stay as they were and the start carries on with the polls.

When Bifrost quits, it stops the commands along with the registry. Every job that's running is
cancelled and any later command is refused, though a `claude rm` that's running is left to finish
(see Delete). A job also ends when its caller cancels it, or when the registry stops while the job
waits for a row. In each case the job stops at its next step, whether that's between two `claude`
runs, after the folder check or during a wait, and does nothing more: it marks nothing, runs no
further `claude` command, frees its locks and ends with `Bifrost stopped this action before it
finished.` That holds for Resume all as a whole, too, so it doesn't go on to the rest of its
sessions. A row that turns up after the job has ended changes nothing either.

The one exception is the wait at the end of Stop (below). By then `claude stop` has already
worked, so when the registry stops during that wait, Stop ends as done rather than cancelled. At
the quit, Bifrost stops the commands and the registry in the same step, and the registry's stop
reaches the wait first, so the wait ends at once, Stop ends as done and the session's lock is
freed. Only a cancel on its own, with the registry still running, ends Stop as cancelled.

| Command | What it does |
| --- | --- |
| New session | Checks the folder (it must be a folder, and in a git repository for a worktree), runs `claude --bg` in it, reads the short ID from the output, reads the active list at once, waits for an owned row with that short ID that isn't parked and has a process ID, then marks the session as started by Bifrost |
| Stop | Only for an owned session that runs. Runs `claude stop <short id>` and takes the session out of Resume all. Then it keeps the session until a poll of the list without the session parks the row, or the row leaves the list, for 20 seconds at most |
| Resume | Only for a parked session that isn't a review session, and only once the session list agrees that it has stopped: a row that only a Live line parked is refused while the active list still has its entry, also an entry with no process ID and no status in the moments after a start (Live state is a hint, not an authority; see `docs/behaviour/live.md`). A row that only an --all read lists gets the check of the session list first (below). Checks that its project folder exists (a plain read, with no git), checks again that the session is still parked, since it can start again during that read, then runs `claude --bg --resume <id>` there, waits until the row ID runs again as an owned row with a process ID, and marks the session as started |
| Resume all | Resumes the parked sessions that were running when Bifrost last closed, one after the other in the order of the list, each with its row as it is at that moment. A session that only an --all read lists gets the check of the session list first, and if the check can't read the list, it's a failure with the reason. Then it waits for all of them together, marks each one as it shows up, and gives the number resumed and each failure with its session name |

Until that poll the row still looks as if it runs, so a Delete straight after a Stop would run a
second `claude stop` and fail. That's why Stop waits: while it does, Delete and the others are off
with the running text, and once the row is grey Delete goes straight to `claude rm`. The wait
looks at the whole list, so a poll that leaves no row at all ends it too. The stop itself has
worked by then, so if the row doesn't park within the 20 seconds, or the registry stops (which
includes the quit of Bifrost), Stop still ends as done. Only a cancel of the job while the registry
still runs ends it as cancelled.

Stop uses the short ID, which a `/clear` doesn't change. A resume uses the continue ID of the row
(see the IDs above) but waits for the row ID, since the resumed job keeps its short ID and so comes
back to the same row. Bifrost never resumes a session that's running, because that would start a
copy, and the "Workspace not trusted" error of a start or a resume gives the trust message for the
folder.

The arguments are fixed:

- A new session gets `--bg`, then `--settings` with a statusline command that prints nothing, as
  one argument (`{"statusLine":{"type":"command","command":"true"}}`), so the chat window doesn't
  show your statusline. Then `--worktree <name>` when you asked for a worktree, `--model` unless
  the model is Default, `--permission-mode` when you picked one, `--name <name>`, and the prompt
  last, because `--worktree` takes an optional value.
- A resume of an owned session is just `--bg --resume <resume id>`. A background session keeps
  its saved options, and a new flag on a stopped one would start a copy with a new session ID.
- A parked external session, which only happens after a failed Take control, gets the Take control
  arguments: `--bg`, the same `--settings` argument and `--resume <current id>`. It ran in the
  foreground, so it has no saved options and the resume keeps its session ID.

Each command ends with a notice in the unified log, in the `sessions` category, so Console shows
it without extra settings: that it ended, or why it didn't. A failure names its reason in one fixed
word, the name of the refusal such as `notParked`, and adds the friendly text, which stays private
because it can hold a path. Resume all adds a line for each session it couldn't resume.

The New session dialog's folder check goes through the same object, and a relative path counts as
missing without being read.

### The check of the session list

The --all list runs on its own 30-second timer, so it can show a session that has only just
started, with no process ID yet, before any active list has it. Bifrost can't tell such a row from
a session that has stopped, so the row counts as listed until an active list read after it also
lacks it. The same goes for every parked background session just after Bifrost starts: the first
--all read comes right after the first active poll, so each parked session waits for the second
poll, which comes 1 to 10 seconds later depending on the Poll interval setting, or 15 seconds or
more while the window is hidden. So the check is common in the first seconds after a start.

Resume, Resume all and a confirmed Delete don't wait for the next poll. When a row they need is in
that state, they ask the registry for a fresh active list there and then, before they take their
locks, and decide on what it shows. That read takes its turn in the lock that lets only one
`claude agents` run at a time, so it always comes after the --all read. While it runs, the notice
line says "Checking sessions...". If the list can't be read, the row stays as it was, and the
command refuses it with the reason, for example "Bifrost couldn't check that this session has
stopped, because Claude Code ran into a problem. Try again in a moment." Resume all gives a
session that the fresh list shows as starting as not parked. No other command runs the check, and
the start of Bifrost doesn't run one either. (New session's read after `claude --bg`, above, takes
the same turn in the lock, but it isn't this check: it decides nothing and shows no notice.) When
Bifrost quits during a check, the check ends without reading the list.

## Delete

Deleting a session removes it from Claude Code with `claude rm`, then takes its row out of the
list. It only runs once you've confirmed, and it never deletes a session that's running in another
terminal. An external session that has ended can be deleted, though, and because Bifrost has no
short ID for it, it simply leaves the list; the same goes for any parked session without a short
ID. A running session that has no short ID yet is refused, since Bifrost couldn't stop it and the
next sample would only bring it back. A row that only a Live line parked, while the active list
still has its entry, counts as running here: Delete stops an owned session first, and refuses an
external one or one with no short ID (Live state is a hint, not an authority; see
`docs/behaviour/live.md`). A row that only an --all read lists gets the check of the session list
first (see "The session commands"): when the fresh active list lacks it, the session has stopped
and Delete goes straight to `claude rm`; when the list has it, the session is starting and Delete
stops it first.

For a session with a short ID, Delete works through these steps:

1. If another row uses the same worktree, `claude rm` could remove a clean worktree from under
   that session, so it doesn't run now. The session stops first if it's running, then leaves the
   list as a deferred delete (see below). No check runs, and the dialog's counts aren't used.
2. Otherwise, the worktree that the dialog checked has to be the row's worktree now, or the Delete
   stops with "The worktree changed after the check." before it runs anything.
3. For a running session in a worktree, Bifrost counts the changes that git tracks, and refuses
   straight away if there are any: `claude rm` would refuse that worktree anyway, and stopping the
   session first would end its turn for nothing. Untracked files don't count, and a count that
   fails doesn't block, because `claude rm` then decides.
4. A running session gets `claude stop <short id>`, and Bifrost waits up to 15 seconds for its
   process to end, because `claude rm` won't remove a worktree while the process runs. A process
   that's still there stops the Delete with "The session didn't stop in time." A row without a
   process ID skips the wait.
5. Bifrost looks for a sharer again, because another session can start in the worktree during
   the stop. If one shows up, the folder stays and the session leaves the list as a deferred
   delete, as in step 1.
6. `claude rm <short id>` runs. Once it works, Bifrost runs the deferred deletes of the worktree,
   then takes the row out of the list.

`claude rm` gets 10 minutes, where the other commands get 60 seconds, because discarding a large
worktree takes a while. When it hits that limit, or prints more than 1 MiB of output, it gets
SIGTERM and never SIGKILL, since a SIGKILL could leave the worktree half deleted. SIGTERM is the
only signal Bifrost ever sends it, though it can send it twice: once for the output and again at the
time limit. From the first SIGTERM on, Bifrost stops reading the output and closes its end of the
pipes, so a `claude rm` that still writes while it winds down can get SIGPIPE from macOS. After the
time limit, Bifrost waits 30 seconds more before the Delete fails with "Claude Code took too long to
delete this session". The session stays locked until the command really ends, so another action on
it, such as a second Delete or a resume, has to wait. That lock only lives in memory, so after
Bifrost quits and starts again, nothing stops a new action while the old `claude rm` still runs. If
you cancel a Delete, or Bifrost quits, while `claude rm` runs, the Delete ends at once and the
command is left to finish on its own. When it ends after its Delete, Bifrost writes a notice to the
log, and the next poll shows what happened. Only the output of a `claude rm` that ended by itself is
read for a kept line, because output cut short by a signal isn't complete.

### When claude rm keeps the worktree

`claude rm` keeps a worktree that has commits on no remote, and prints a value that would discard
them. Bifrost runs `claude rm <short id> --discard-unpushed <value>` only when all of these hold,
so it never throws away work that the dialog didn't show you:

- The Delete dialog showed a check of the worktree.
- The kept line names this session's short ID and the worktree that Bifrost knows for it, ignoring
  one `/` at the end.
- A fresh check after the stop finds no more commits and no more changed files than the dialog
  showed.
- The worktree's HEAD commit is still the one that the dialog's check read, so the commits are
  the ones the dialog showed, and it's the commit at the start of the discard value. A commit
  that was amended, reset and made again, or merged and followed by a new one while the dialog
  was open leaves the counts the same, but not the HEAD.

Without a check in the dialog, the Delete stops with "Claude Code kept this session"; when any
other condition fails, it stops with "The worktree changed after the check." The discard is tried
once, and a second refusal means the worktree changed in between.

`claude rm` also keeps a worktree with changes that aren't committed, and Claude Code has no
command that deletes one, so Bifrost never tries a discard there, even when the output holds a
value; you get the message about changes that aren't committed. When Bifrost didn't know the
session's worktree, and the kept line names this session and a worktree root, Bifrost remembers
that worktree, so the next Delete can check it and offer Open worktree.

### Deferred deletes

When you delete the last session in a shared worktree, and its own `claude rm` works, Bifrost runs
`claude rm` for each deferred session of that worktree in the order they were deferred. Each run
gets the check of this last dialog, so the discard rules above apply, and a run that works drops
its entry. A `claude rm` can take minutes, so before each run Bifrost skips an entry that has gone
in the meantime, and one whose worktree another row now uses, which waits for that row's Delete.
Each run holds the lock of its entry, so an entry whose `claude rm` still runs from an earlier
Delete is skipped and stays deferred. If a run fails, its entry and every later one come back to
the list as parked sessions, the last session still leaves the list because its own `claude rm`
worked, and the Delete shows why the run failed. A Delete that's cancelled changes no entry.

### The dialog's check

Before the Delete dialog shows, it asks for the worktree check of the session. That checks the
row's worktree, or for a stopped session the worktree Bifrost stored while it ran, and otherwise
the row's folder. For a worktree, the check also reads its HEAD commit; a folder that isn't a
worktree gets a check with no worktree and runs no git. An unknown row, an external row and a row
with no folder get no check, and neither does a check that fails. Only a check that found a
worktree and read its HEAD gives the values that the Delete gets back (`SeenCounts`), so they are
always ones that git gave.

## Take control

Take control ends the terminal process of a session that's running in another terminal, and
resumes the same conversation in Bifrost. It only runs once you've confirmed, and before it sends
anything it checks, in this order:

- The row is an external session that's running, and it's idle or has a yellow box. A working
  session would lose its turn, and any red box would lose the open prompt. The session list must
  agree, because a line of the Live details mod can give a yellow box: a session that the list
  shows as busy is refused as working, and one that it shows waiting on a prompt is refused as
  having an open prompt.
- The current ID is a session ID, and the row has a process ID above 1. PID 0 and -1 would signal
  a whole group of processes, and PID 1 is launchd.
- The project folder exists.
- The transcript of the current ID has a user message, because Claude Code can't resume a session
  without one.
- Bifrost can find `claude`, since without it the session couldn't come back.
- The process is a `claude` process, read by the process probe, and it isn't Bifrost itself.
- After all those reads, the row still has the same process ID and the same current ID, no other
  row has that process ID, and the rules above still hold. A `/clear` during the reads would
  otherwise resume the old conversation.

Then the process gets one SIGTERM, and only the `claude` process that the probe found can get it.
Sometimes that process ends on its own just before the signal. The system then reports that there's
no such process, or the read just before the signal finds no process while nothing else has the
PID. Either way the process needs no signal, and Take control carries on.

Bifrost waits up to 5 seconds for the process to end. If it's still there, Bifrost starts no copy
of the session. Otherwise it marks the session as started, so that a resume that fails leaves a
parked row. Then it runs `claude --bg` with the statusline setting and
`--resume <current id>` in the project folder, and waits for the row ID to run again as an owned
row. A resume can fail just after it starts, so 3 seconds later Bifrost checks that the row still
runs and its process is alive. If it doesn't, you get "Claude Code could not resume this
session.", with the `claude logs` hint when Bifrost knows the short ID.

## Hand over

Hand over moves a session's work to a fresh session, which is handy when its context is filling
up. Bifrost asks the session to write a hand-over note, saves the note, and starts a new
background session in the same folder that carries on from it. The old session parks, so you can
resume it later.

The button and the bifrost-hand-over skill share one rules file,
`skills/bifrost-hand-over/hand-over-rules.md` in the app's skills folder, so the note asks for the
same things whichever way you start it. The button doesn't need the skills plugin, because it
sends the rules as a plain prompt.

A hand-over runs these steps, and if one fails, the old session stays as it is and nothing new
starts:

1. Bifrost reads the rules file. A missing or empty file stops the hand-over before anything
   changes.
2. It finds the session's transcript: `<id>.jsonl` as a regular file in the first project folder,
   by name, under `<home>/.claude/projects`, where the ID is the conversation the row shows now.
   It notes the file's size as the baseline, so only what's written after the request can count,
   and a note from an earlier hand-over in the same transcript never does.
3. It types the request into the session through the session input, as Send message does. The
   request starts with `Bifrost hand-over request <id>`, where the ID is eight random hex digits,
   asks Claude to write the note without using a tool or changing anything, carries the rules
   word for word, and asks for the note between two lines of their own,
   `[[BIFROST-HAND-OVER-NOTE-START]]` and `[[BIFROST-HAND-OVER-NOTE-END]]`.
4. It waits for the note (see below).
5. It removes every NUL character from the note and then runs the token mask over it, so a token
   that Claude copied by mistake becomes `***`. Removing the NULs first means one can't hide a
   token from the mask.
6. It saves the note to a new file in `~/.bifrost/handovers` before it starts anything, so a start
   that fails still leaves the note on disk, and the error says where.
7. It starts the new session with the New session command, in the old session's folder and with
   no worktree. The session gets the next free name, the model and the permission mode of the
   reply, and a first prompt that points to the note file and then gives the note in full.
8. The new session takes the old one's priority and its place and colour in the watchlist, and
   the old one keeps neither.

The action runner then switches the old session's chat to the new session, selects the new row
and parks the old session, as "The action runner" above describes and "The park of the old
session" below explains.

The model comes from the reply in the transcript and goes to the new session as one of the New
session choices, by its family: an Opus model gives Opus, and the same goes for Sonnet and Haiku.
A model of another family, or a reply with no model, takes the model of the row's usage line
instead, and failing that, the new session uses Claude Code's default. The permission mode is the
one the request ran in. When that's a mode a new session can't start with, such as the default
mode or `bypassPermissions`, the new session gets no mode flag and starts in Claude Code's default
mode, so Bifrost never starts a session in `bypassPermissions` by itself. Only a request with no
mode at all takes the mode of the row's usage line, and then only a mode that a new session can
start with.

### Waiting for the note

Each time the session's row changes in the session list, and each time the transcript file
changes on disk, Bifrost reads the transcript from the baseline to its last full line. The file
events matter because a short turn can start and finish between two samples of the session list,
so the row may never show as working. The wait ends once the reply holds the note and the row is
idle. Five minutes is a safety limit.

The transcript format belongs to Claude Code and can change between versions, so the reader is
strict, and anything it doesn't recognise is a failure:

- The request is the first user entry with the request line on a line of its own. Bifrost reads
  only what comes after it, so a longer ID doesn't match and an older note doesn't count.
- The reply is the text of the assistant entries up to the end of the turn. A subagent's entries
  and the metadata entries are skipped, and so are the user entries that only carry tool results.
- The note is the trimmed text between the two marker lines. Each marker must appear once, with
  the start before the end, and the note can't be empty.
- A new message from you after the request fails the hand-over straight away, even after the end
  of the turn, and so does an Interrupt. A note from a background task doesn't count as a message.

### The park of the old session

Starting the new session can take a few seconds, and until the chat switches, the old session's
chat is still live. So just before the park, Bifrost checks the old session again. It asks Claude
Code for a fresh session list, and the row must still be a session that Bifrost started, not
parked, idle and without a prompt box. It also reads the old transcript once more from where the
wait stopped, and nothing new can have come in since the note: no message from you, no queued
command and no reply from Claude. A line that the reader doesn't recognise counts as something
new. When every check passes, the old session stops and parks. Otherwise it's left as it is, and
the error line says why:

| When | Message |
| --- | --- |
| The fresh session list doesn't come | `The new session started, but Bifrost couldn't check the old one, so it left it running.` |
| The row has left the list | `The new session started, but the old one isn't in the list any more, so Bifrost didn't park it.` |
| The row is parked already | `The new session started, but the old one has already stopped, so Bifrost didn't park it.` |
| The row isn't a session that Bifrost started | `The new session started, but the old one now runs in another terminal, so Bifrost left it running.` |
| The row has a prompt box | `The new session started, but the old one is waiting on a prompt, so Bifrost left it running.` |
| The row isn't idle | `The new session started, but the old one is busy again, so Bifrost left it running.` |
| The transcript has something new | `The new session started, but the old one has a new message, so Bifrost left it running.` |
| The transcript can't be read | `The new session started, but Bifrost couldn't read the old one's transcript, so it left it running.` |

### The names

The new session's name is the old name with the next free number: `x` gives `x (2)`, and `x (2)`
gives `x (3)` rather than `x (2) (2)`. A name that any row already uses, as its local name or its
Claude Code name, is skipped, so `x (2)` gives `x (4)` while `x (3)` exists. The name keeps to the
64-character limit of a new session by cutting the old name before its number, and any space left
at the end of the cut goes.

The note file is `<name>-<YYYYMMDD-HHmmss>.md`, with the date and time in your time zone. In the
name part, each run of characters other than ASCII letters, digits, `.`, `_` and `-` becomes one
`-`, a dash at either end goes, and the part is cut to 64 characters. A name with nothing left
becomes `session`.

Bifrost makes the handovers folder, and any missing folder above it, readable only by you
(mode 0700), and each note file the same way (mode 0600). It never writes over anything: when
the name is taken, by a file, a folder or a link, it tries `-2` before the extension, then `-3`,
and so on up to `-100`, and the write never follows a link.

### When it fails

| When | Message |
| --- | --- |
| The rules file is missing or empty | `Bifrost can't read its hand-over rules, so nothing changed.` |
| There's no transcript | `Bifrost can't find the transcript of this session, so nothing changed.` |
| The session input doesn't send the request | The send's own message, such as `Answer the prompt in the chat window first.` |
| No note within 5 minutes | `The session didn't finish the hand-over note within 5 minutes, so Bifrost didn't start a new session.` |
| The session parks or leaves the list, or its transcript can't be read any more | `The session stopped before it finished the hand-over note.` |
| The reply can't give a note | `Bifrost couldn't read the hand-over note, so it didn't start a new session. (<reason>)` |
| The note can't be saved | `Bifrost couldn't save the hand-over note, so it didn't start a new session. <reason>` |
| The new session doesn't start | `The note is saved at <path>, but the new session didn't start. <reason>` |

The reason in parentheses is one of these: "a line of the transcript has an unknown form", "a turn
ended before the hand-over request", "the reply has a part that Bifrost doesn't know", "the
session was interrupted", "a new message came in during the hand-over", "the reply has more than
one note", "the reply doesn't have both note markers", "the note markers are in the wrong order",
"the note is empty", "The reply is too long to read." (more than 4 MB after the baseline) or "The
transcript got shorter while Bifrost read it." A note file that can't be saved gives "The note
file name isn't valid.", "Too many hand-over notes have this name." or the system's reason, and a
new session that doesn't start gives the reason of New session, or "The note is too long to start
a new session with it." when the first prompt would pass the 20,000-character limit.

## Worktrees

Claude Code makes a session's worktree at `<repo>/.claude/worktrees/<name>`. A row's worktree
comes from its working folder, or, for a session that has stopped and now reports its start
folder, from the worktree Bifrost stored while it ran.

Two rows can share one worktree. Delete needs to know this, because `claude rm` can remove a
clean worktree that another session is still using. The sharer of a row is the first other row,
in the order of the list, with the same worktree, whatever its state. A row in a plain folder has
no sharer, and a row never shares with itself, even a copy of it that's running again.

## Local names and priority

- A session can have a local name that only Bifrost knows. When it has one, the tooltip of the
  name in the Selected Item panel shows `Claude Code name: <name>`. Otherwise it shows the name
  itself, so you can read a name that the panel cuts short.
- A priority is a number from 1 to 5, and 1 is the highest.

## The output of claude

Bifrost reads a few things out of what `claude` prints. Each pattern compares Unicode scalars, so
a combining mark next to a character doesn't change a match.

- `claude --bg` prints `backgrounded · <short id>`, with a middle dot (U+00B7). The short ID is
  the first one of 8 lower-case hex digits that isn't followed by a letter, a digit or `_`.
  Without one, the start counts as failed.
- "Workspace not trusted" anywhere in the output means Claude Code doesn't trust the folder yet.
- When `claude rm` keeps a worktree because it has commits that exist on no remote, its output
  has exactly one line starting with `kept `, in the form
  `kept <short id> — its worktree is still at “<path>”` (an em dash, U+2014, and curly quotes,
  U+201C and U+201D), and a `--discard-unpushed <value>` option. Bifrost only reads it when
  there's exactly one distinct value and it's 40 hex digits, `@` and 32 hex digits, because the
  value goes straight into a `claude` argument.
- When `claude rm` keeps a worktree because it has changes that aren't committed, the kept line
  comes first, it's the only line starting with `kept `, a later line says "The worktree has
  uncommitted changes", and there's no discard value.
- The text of a failed command is its stderr, else its stdout, with the control characters
  removed (as for text sent to a session) along with the hidden characters that a name can't hold
  (zero-width characters, the byte order mark and the bidi controls), then trimmed and cut to 300
  characters. Tabs and line breaks stay. So an escape sequence in Claude Code's output can't reach
  a notice, and a bidi control can't make the rest of the notice read backwards. A stderr line
  that's only the "Starting background service" banner doesn't count, because the first start of
  the background service always writes it.

## The process probe

Some actions need to look at a process or a folder before they act, and the process probe does
that without changing anything.

- Before an action signals a process, the probe checks that it's a `claude` process. It reads
  the process's command as `ps -o comm=` would show it, which is the first argument it was
  started with, through the process APIs of macOS rather than by running `ps`. The last part of
  that path, after trimming, must be `claude`. The probe never reads a PID of 1 or less, or
  Bifrost's own PID.
- A process that passes the check comes back with its start time (`ClaudeProcess`), and that's
  the only thing a SIGTERM can go to. Just before the signal, Bifrost reads the process again,
  and if it has gone, started at another time or is no longer `claude`, it gets no signal. The
  system can give the PID of an ended process to a new one, but never with the same start time.
- Each read takes the start time both before and after it reads the command. If the two differ,
  the PID went to a new process in between and the read counts as failed, so the command and the
  start time always belong to the same process. The start time is the last thing read before the
  signal, which leaves only the few microseconds between that read and the signal.
- The folder check says whether a path is a folder, something else, or missing, and for a folder
  whether it's in a git repository. A relative path, or one with a NUL character in it, counts as
  missing without being read.
- The check reads the path with `stat`, which follows links, and for a folder also reads the real
  paths for the review-folder check below. Both reads run on a thread of their own, and if they
  don't finish within 2 seconds of their start, as can happen on an offline network volume, the
  path counts as missing. The time before the start, while a busy Mac finds a free thread, doesn't
  count, so a folder that exists never shows as missing for that reason. A stuck read only holds
  its own thread.
- For a folder, `git -C <folder> rev-parse --show-toplevel` runs with your login environment and a
  2 second limit, and a success means it's in a repository. No git runs in a folder at or below
  one of the review folders, compared both as written and by real path, so a trailing `/` or a
  link into one counts too. A pull-request session can write the git config there, and git reads
  that config.
- The only signal the actions send is SIGTERM. If the system says the process no longer exists,
  it ended just before the signal, and the action carries on. Any other refusal from the system
  stops the action with "Bifrost couldn't stop the terminal session. Try again."
- Whether a process is alive is checked with signal 0, which sends nothing. Only "no such process"
  counts as gone; a process that belongs to another user still exists. A PID of 1 or less counts
  as alive without asking the system, which is the safe answer, since PID 1 is launchd, PID 0
  would mean Bifrost's own process group and PID -1 every process you own.
- The waits for a process to end don't poll. A process that's already gone ends the wait at once;
  otherwise the system tells Bifrost the moment the process exits (a Dispatch process source),
  and the wait gives up at its limit.

## The worktree check

Before a Delete, Bifrost checks the session's worktree for work that would be lost: files that
have changed, and commits that the main checkout doesn't have yet. The Delete dialog shows what
the check finds, and the Delete checks again before it discards anything. Every git command of the
check only reads.

- A folder outside `<repo>/.claude/worktrees/<name>` has no worktree, so the check reports no
  worktree and no work without running git. A folder inside a worktree, such as its `src`, checks
  the whole worktree.
- The changed files are the lines of `git --no-optional-locks -C <worktree> status --porcelain`,
  so untracked files count too. `--no-optional-locks` keeps git status from writing the
  worktree's `index.lock`, which could get in the way of a git command that the session runs.
- The branch comes from `git rev-parse --abbrev-ref HEAD` in the worktree. A detached HEAD has no
  branch.
- The unmerged commits are counted from the commit that the main checkout has now
  (`git -C <repo> rev-parse HEAD`) to the worktree's HEAD, with `git rev-list --count
  <base>..HEAD`. The base has to be a commit ID (40 or 64 lower-case hex digits) and the count a
  whole number in ASCII digits, so a sign such as `-1` or a stray word fails the check.
- Each git command gets 5 seconds and your login environment. If any of them fails, the whole
  check runs once more after 500 ms, because a git command of the session or an install in the
  worktree can make a single check fail. A second failure means the check failed, and the Delete
  dialog then says that Bifrost couldn't check the session for unmerged work.
- No git runs for a worktree, or its repository, at or below a review folder, compared both as
  written and by real path. The check counts as failed there, since a pull-request session can
  write the git config that git would read. The real paths are read on a thread of their own, and
  a read that takes more than 2 seconds, as on an offline network volume, also counts as a review
  folder, so the check fails rather than runs git in a folder it couldn't check.
- The check of the Delete dialog also reads the worktree's HEAD commit, and once the session has
  stopped, the Delete checks again with the HEAD. A discard needs the same HEAD in both checks,
  and the discard value of `claude rm` starts with it. That commit has to be a commit ID (40 or 64
  lower-case hex digits). This check reads the HEAD commit first and then counts up to that
  commit (`<base>..<commit>`) rather than up to `HEAD`, so the counts always belong to the HEAD
  it reports, even if a commit lands while the check runs. Its second try reads the HEAD again.
- For a session that's still running, the Delete first counts only the changes that git tracks:
  the lines of the same git status that don't start with `??`. This count follows the same rules:
  it needs a folder in a worktree, it gets the same second try, and it fails in the same way when
  the worktree or its repository is in a review folder.

## The transcript check

Claude Code can't resume a session that has no user message yet, so Take control looks at the
start of the session's transcript first. Claude Code writes each transcript to
`<home>/.claude/projects/<project>/<session id>.jsonl`, and the check only reads it.

- The session ID has to be a UUID. Any other ID gets a no, and no path is ever made from it.
- The check looks for the session's file in every project folder and reads its first 256 KB. A
  file with `"type":"user"` in that part means yes.
- No projects folder, or no transcript in any project, means no. A file in the projects folder
  isn't a project, so the check skips it.
- Any other read error means yes, so the check never blocks a session that does have messages.
  That covers a projects folder that Bifrost can't read, and a transcript name that turns out to be
  a folder.
- A named pipe at the transcript's path doesn't hold the check up: the read doesn't wait for a
  writer.

## The apps of a session

Open project and Open in terminal offer the apps that you have installed. Bifrost finds them by
checking whether their paths exist, without asking Launch Services anything or opening an app.

| App | Where Bifrost looks |
| --- | --- |
| Finder | `/System/Library/CoreServices/Finder.app` |
| VS Code | `Visual Studio Code.app` |
| Zed | `Zed.app` |
| Warp | `Warp.app` |
| Ghostty | `Ghostty.app` |
| iTerm2 | `iTerm.app` |
| Terminal | `/System/Applications/Utilities/Terminal.app` |

A name with no path is looked for in `/Applications` first, then in `~/Applications`. The
terminal order is Warp, Ghostty, iTerm2 and Terminal.

- Open project lists Finder, then VS Code and Zed when they're installed, then one terminal app:
  the one chosen in Settings when it's installed, otherwise the first installed one in the
  terminal order.
- The Settings select of the terminal app lists every installed terminal app, in the terminal
  order.
- The existence check follows links.
- The session actions look for the apps once when the settings have loaded and again after each
  change of the terminal app in Settings, always off the main thread
  (`BifrostApp/Services/InstalledAppList.swift`). Until the first search ends, the list is empty,
  so Open project and Open in terminal are off for that moment.

## Open project, Copy session ID and Open the worktree

These actions get a session ID and find the row, the folder and the app themselves.

- Open project opens the session's folder in the app you picked. The folder has to be an absolute
  path, and the app has to be in the installed list. When the app is Finder, the package rule
  below applies.
- Only a folder opens, in Open project and in Open the worktree. Bifrost first looks at what's at
  the path, following symbolic links, and opens the real folder it finds. A file, such as a
  `.command` file that Finder or Terminal would run, is refused with "<path> isn't a folder, so
  Bifrost didn't open it.", a missing folder with "The folder <path> doesn't exist.", a folder that
  Bifrost can't read with "Bifrost can't read the folder <path>. Check that you can open it in
  Finder.", and a look that takes more than 10 seconds with "Bifrost couldn't check this folder in
  time. Try again.". Open in terminal opens its own command file, so this rule isn't for it.
- Copy session ID copies the ID that `claude --resume` needs to continue the session: the resume
  ID for a background session that Bifrost started, and the current ID for a session in another
  terminal. Until Bifrost knows the resume ID of a background session, it copies nothing.
- Open the worktree, a button of the Delete dialog, opens the session's worktree in Finder, so you
  can look at the work first. The worktree comes from the session's folder, or from the worktree
  Bifrost stored while the session ran. The button is only for Bifrost's own sessions, so a
  session in another terminal is refused.
- Finder starts a folder that macOS treats as a package, such as a folder named `x.app`, as an
  app. So when Finder would open such a folder, Bifrost only shows it selected in a Finder window,
  and a plain folder opens as usual.
- An open that fails gives the reason that macOS gives, without the hidden characters that a name
  can't hold, and every open or activate gives up after 10 seconds.

The app itself does the opening with `NSWorkspace` (`WorkspaceOpener`), with a few rules that keep
it safe:

- Only an application bundle with a program in it opens a folder or comes to the front. A folder
  that merely looks like an app, such as an empty folder named `x.app`, never runs, and the open
  is refused with "Bifrost can only open an app that macOS knows as an app.". That check is part of
  the 10 seconds too.
- Bringing an app to the front starts it if it isn't running, which the clipboard way of Open in
  terminal needs.
- The look at a path follows symbolic links first, so a link to `x.app` counts as `x.app` and a
  link to a file counts as a file. A look that can't read the path or doesn't finish within the 10
  seconds refuses the open, so nothing opens that Bifrost didn't check.

## Open in terminal

Open in terminal lets you carry on with a session in a terminal app. A parked session is refused.

For a session in another terminal, Bifrost brings that terminal app to the front, and if it
doesn't know which app that is, the action is refused. For a session that Bifrost started,
Bifrost attaches it in the first terminal app of the installed list, in the terminal order, and
the session needs its short ID. How the attach starts depends on the app:

| Terminal app | How the attach starts |
| --- | --- |
| Warp, Terminal | Bifrost writes a command file and opens it in the app |
| Ghostty, iTerm2 | Bifrost copies `claude attach <short id>`, brings the app to the front, and shows `Copied "claude attach <short id>". Paste it into <app> to open the session.` |

- The command file is `attach-<short id>.command` in the `run` folder of the development build's
  own folder, never in `~/.bifrost`. It holds `#!/bin/sh` and then
  `exec '<claude path>' attach <short id>`.
- The `run` folder has to be a real folder that you own, not a link, and Bifrost makes it with
  mode 0700 when it's missing or sets that mode when it's looser. The script goes to a new file
  with mode 0700 and a temporary name in that folder, and a rename then puts it at its name. So
  whatever was at the name before, a link, a second name of another file or a named pipe, is
  replaced and never written to.
- The claude path goes in single quotes, and each quote in it becomes `'\''`. The escape works on
  Unicode scalars, because the shell reads bytes, so a quote with a combining mark after it is
  still escaped.
- The short ID is a `ShortID`, which the list of `claude agents` parses as exactly 8 lower-case
  hex digits, so no other text can reach the script or the clipboard.
- With no `claude` path, or one that isn't an absolute path, Bifrost doesn't write the command
  file, and you get the message that it can't find Claude Code. A path that starts with `-` would
  be an option of `exec`.
- Bifrost removes the command file 30 seconds later, also when the write or the open failed, and
  the removal checks the `run` folder in the same way. Opening the same session again writes the
  file again and starts the 30 seconds over. A failed write goes into the log with its error.
- A quit inside those 30 seconds, or a write that never finished, can leave a command file or a
  temporary file of a write behind. So when the session actions start, Bifrost removes every
  `attach-<short id>.command` and every `.attach-<short id>.command.<UUID>.tmp` from the `run`
  folder, with the same checks of the folder, and leaves any other file alone. An Open in terminal
  right after the start waits for that clean-up, so it can never remove the new file.

## Refusals

When an action can't run, or `claude` fails, you get a short, friendly message. Each refusal is
a case of `ActionRefusal`, and its text never holds a code or a raw command line. The first table
covers the New session values, the process checks and the output of `claude`.

| When | Message |
| --- | --- |
| The folder isn't an absolute path | `Choose a project folder.` |
| The name is empty | `Type a name.` |
| The name is over 64 characters | `The name is too long. The maximum is 64 characters.` |
| The name has a tab or a line break | `The name has one line.` |
| The name has a hidden character | `A name can't hold control or hidden characters.` |
| The name starts with `-` | `The name cannot start with "-".` |
| The prompt is over 20,000 characters | `The text is too long. The maximum is 20,000 characters.` |
| The prompt starts with `-` | `The first prompt cannot start with "-".` |
| The prompt is only a command name | `That prompt is also a Claude command name. Add a few more words.` |
| The folder isn't there | `This folder doesn't exist.` |
| A worktree in a folder outside git | `This folder isn't in a git repository, so it can't use a worktree.` |
| A session ID that isn't valid | `That session ID isn't valid.` |
| A process ID of 1 or less | `The process ID of this session isn't valid.` |
| The process isn't `claude`, or changed after the check | `Process <pid> isn't a Claude process, so Bifrost left it alone.` |
| The system refused the SIGTERM | `Bifrost couldn't stop the terminal session. Try again.` |
| An owned row with no resume ID yet | `Bifrost doesn't know which ID resumes this session yet. Try again in 30 seconds.` |
| Claude Code doesn't trust the folder | `Claude Code doesn't trust this folder yet. Run claude in <folder> once, accept the trust prompt, then try again.` |
| `claude` exited with an error and wrote a text | `Claude Code reported a problem: <text>` |
| `claude` exited with an error and wrote nothing | `Claude Code stopped before it finished (code <n>). Try again in a moment.` |
| The command hit its time limit, was stopped or didn't start | `A Claude Code command failed. Try again in a moment.` |
| Bifrost can't find `claude` | `Bifrost can't find Claude Code. Check that the claude command works in a terminal.` |

The last row covers every way a command can end other than by exiting: the runner's own text for
it can hold the command's raw arguments, so you get a plain message instead. A command other than
`claude`, such as `open`, gives its own text, else `<command> failed with code <n>`, else a short
description of how it ended, such as `open did not finish in time.`

The session commands and the other actions give these. Where the same rule also turns an action
off in the action model, the message is that rule's reason.

| When | Message |
| --- | --- |
| The session has gone from the list | `This session isn't in the list any more.` |
| Another action runs on the session | `Another action is still running on this session. Try again in a moment.` |
| A New session start already runs | `A new session is already starting. Please wait.` |
| Resume all already runs | `Resume all is already running.` |
| The job was cancelled, or Bifrost quit while it ran | `Bifrost stopped this action before it finished.` |
| The session runs in another terminal | `This session runs in another terminal, so Bifrost can only show its status.` |
| The session is parked | `This session is parked. Resume it first.` |
| An action for external sessions on another row | `This only works for a session that runs in another terminal.` |
| An action for running Bifrost sessions on another row | `This only works for a Bifrost session that is running.` |
| Resume of a session that isn't parked | `This session isn't parked, so there's nothing to resume.` |
| Resume of a review session | `A review session can't be resumed. Click Review in the Reviews panel to start a new one.` |
| The session is working on a reply | `This session is working right now. Try again when it has finished.` |
| The session is waiting on a prompt | `This session is waiting on a prompt. Answer it in the chat window first.` |
| Take control of a session that isn't idle | `Take control only works while the session is idle or has just finished.` |
| No short ID yet | `Waiting for the session ID.` |
| No process ID | `Bifrost doesn't know the process ID of this session.` |
| The process of the row changed during the checks | `The process of this session changed, so Bifrost left it alone.` |
| Take control of a session with no user message | `This session has no messages yet, so there's nothing to take over. Send a message in its terminal first.` |
| Delete or Take control without your confirmation | `Delete needs your confirmation first.` / `Take control needs your confirmation first.` |
| Delete of a session in another terminal | `Bifrost can't delete a session that runs in another terminal.` |
| `claude rm` kept a worktree with commits on no remote | `Claude Code kept this session, because its worktree has commits that exist on no remote. Open the worktree to check them, then delete again.` |
| The worktree has changes that aren't committed | `This worktree has changes that aren't committed, so Claude Code won't delete it. Open the worktree, commit or discard them, then delete again.` |
| `claude rm` took too long | `Claude Code took too long to delete this session. Check the worktree, then delete again.` |
| The worktree changed after the check of the dialog | `The worktree changed after the check. Check it again, then delete.` |
| The session didn't stop in time for Delete | `The session didn't stop in time. Try Delete again in a moment.` |
| `claude --bg` gave no short ID | `Claude Code didn't give the new session an ID. Try again in a moment.` |
| A new session didn't show within 30 seconds | `The session <id> did not start in 30 seconds. Run claude logs <id> to see the cause.` |
| A resumed session didn't show again within 30 seconds | `The session did not start again in 30 seconds.` |
| The terminal process of Take control didn't end within 5 seconds | `The session process did not end in 5 seconds. Bifrost did not start a copy of the session.` |
| The session that Take control resumed didn't stay | `Claude Code could not resume this session.`, then `Run claude logs <id> to see the cause.` when Bifrost knows the short ID |
| No project folder | `Bifrost doesn't know the project folder of this session.` |
| The project folder isn't there | `The folder <path> doesn't exist.` |
| Open worktree for a session with no worktree | `This session doesn't have a worktree.` |
| Open project with an app that isn't installed | `Bifrost doesn't know that app.` |
| No supported terminal app is installed | `No supported terminal app is installed.` |
| Bifrost doesn't know the terminal app of an external session | `Bifrost doesn't know which terminal app this session runs in.` |
| An open of a folder or an app failed | The text of the failure |
| Open in terminal for a session with no short ID | `That session ID isn't valid.` |
| Open in terminal couldn't write its command file | `Bifrost couldn't write the file that opens this session in your terminal. Try again.` |

A folder in a message (the missing folder and the folder Claude Code doesn't trust) shows without
the hidden characters that a name can't hold, so a bidi control in a path can't make the rest of
the message read backwards.

Send message, Run slash command, Compact and Rename go through the session input, and when it
refuses, you get its own message, such as `Answer the prompt in the chat window first.` A local
name that Rename can't keep gives `A name can't hold control or hidden characters.` or
`The name is too long. The maximum is 64 characters.`
