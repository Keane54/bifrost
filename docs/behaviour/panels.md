# Session panels: behaviour

Besides the Overview, Bifrost has a few smaller panels that show what your sessions are doing.
This page covers the rules behind them. The Event log keeps its rules in
`BifrostSessions/Model/Events/` (`EventLog` and `LogView`), its state in
`BifrostSessions/Services/Events/` (`EventLogModel` and `EventBatcher`) and its panel in
`BifrostSessions/UI/Events/`. The token mask that it uses is `TokenMask` in `BifrostFoundation`.
Show Info keeps its rules in `BifrostWindows/Model/Info/` (`ShowInfo`) and its panel in
`BifrostWindows/UI/Info/` (`ShowInfoPanel` and `ShowInfoPanels`). The PR lookup that it uses lives
in the sessions module: `PRInfo` in `BifrostSessions/Model/Info/` and `PRLookup` in
`BifrostSessions/Services/Info/`. The Watchlist keeps its order rules in
`BifrostSessions/Model/Watch/` (`WatchOrder`) and its panel in `BifrostWindows/UI/Watch/`
(`WatchlistPanel` and `WatchlistPanels`). `docs/ports/panels/DELIBERATE-DIFFERENCES.md` lists where
these panels deliberately differ from the Electron app.

## The Event log

The Event log is a running list of what your sessions did, newest first. Each time a session
starts a turn, runs a tool, asks for permission or stops, Live details reports a state event, and
the log adds an entry for it. Bifrost adds its own lines too, such as the one that tells you macOS
didn't show a notification. The log lives in memory only, so it starts empty each time Bifrost
starts.

- The log keeps the newest 5,000 entries. Each entry gets the next number of the log itself, not
  the number that the Live details mod gave its line.
- An event entry has the time of the event, the row ID of its session, the event's name (such as
  `PreToolUse`) and the tool, when the event has one.
- The events come from the registry, which hands them out one at a time on a stream that has one
  reader: `EventLogModel.read` reads it in a single task, and nothing else does. While nobody reads
  the stream it holds the newest 1,000 events, so the first read can bring in events from a little
  earlier.
- Bifrost's own lines come in two kinds. A notice shows once for each text, so a second refused
  notification doesn't add a second line, while a plain line shows every time. The text for a
  refused notification is "macOS didn't show a notification. Allow notifications for Bifrost in
  System Settings."

### Safe texts

A tool name comes from Claude Code, and a line can hold the text of an error, so the log treats
both as untrusted. Before a text goes into the log:

1. Line breaks and tabs become spaces, so the words stay apart and a row stays one line.
2. Hidden characters go: control characters, zero-width characters and the bidi controls, which
   could make the rest of a row read in a different order. This is the same rule that names use
   (`withoutHiddenCharacters`). The default-ignorable characters go too, such as a soft hyphen,
   a word joiner or a variation selector, since they show nothing at all. A mark you can see,
   such as a combining accent or a no-break space, stays.
3. The token mask hides each secret (see below).
4. A text longer than 500 characters is cut to 499 and ends with "…".

Removing the invisible characters before the mask means one hidden inside a token can't break
the token up and slip it past the mask, and cutting after the mask means a cut can never leave
the first half of a token on screen. A notice counts as "the same text" after these steps, so two
refusals that differ only in a secret still give one line.

## The token mask

`TokenMask.mask` replaces each secret in a text with `***` before the text reaches a log or the
screen. It hides the token that the caller knows about (every time it appears, as plain text) and
anything that has the shape of a known token:

| Secret | Its shape |
| --- | --- |
| GitHub token | `ghp_`, `gho_`, `ghs_` or `ghu_`, then 20 or more letters and digits |
| GitHub fine-grained token | `github_pat_`, then 20 or more letters, digits and underscores |
| Anthropic key or token | `sk-ant-`, then 20 or more letters, digits, underscores and hyphens |
| AWS access key ID | `AKIA`, then exactly 16 capital letters and digits |
| Slack token | `xoxa-`, `xoxb-`, `xoxp-` or `xoxr-`, then 10 or more letters, digits and hyphens |
| Bearer header | `Bearer` and a space, then 16 or more token characters and any `=` padding |

For a Bearer header only the value goes, so "Authorization: Bearer abc…" becomes
"Authorization: Bearer ***" and still makes sense. The word can be in any case. A token shorter
than its shape isn't hidden, and text around a token stays as it was. The mask reads the text as
code units rather than as characters, so a combining accent typed straight after a token doesn't
hide the token from it.

## The Event log panel

The panel shows the log as a table, with a bar on top that holds the Session filter and the
number of entries it shows, such as "1 event" or "5000 events".

- Each row is 18 units high and has three columns: the time with milliseconds (`14:03:07.045`),
  the session, and the event. The session column shows the name of the session's row, or the
  first 8 characters of its ID when the row has gone. A name goes through the same steps as a
  text of the log (see "Safe texts"), so a label never shows an invisible character or a token.
  The event column shows the event's name followed by its tool in brackets, as in "PreToolUse
  (AskUserQuestion)".
- A line from Bifrost has no session, so its text starts in the session column and runs across
  the event column too, in the strong text colour. A narrow panel cuts the text, so resting the
  pointer on it shows the whole text in a tooltip.
- The Session filter is a menu with "All sessions" and then each session that has an entry in the
  log, sorted by label in English order, where case and accents count for less than the letters
  themselves. Two sessions with the same name are two items, and the chosen one has a tick.
  Choosing a session shows only its entries and scrolls back to the newest. A chosen session stays
  in the menu after its last entry leaves the log, so the menu always says what the table shows.
  While the menu is open its list holds still, and a new session joins it once the menu closes,
  so an item never moves under the pointer.
- With nothing to show, the panel says "No events yet.". If Live details isn't on, it adds
  "Events come from Live details. Turn it on in Settings to see them here." Live details counts as
  on only when its plugin is installed and enabled, Bifrost is listening for it and the plugin's
  files match this Bifrost, which is the On state of Settings > Live details. While Bifrost is
  still checking, the hint shows too, and it follows each change of that state.
- The table changes at most once every 250 milliseconds. The first new entry shows at once, and
  everything that arrives in the next 250 milliseconds shows together at the end of that gap
  (`EventBatcher`), so a flood of thousands of events costs only a handful of table updates. A
  session row changes at every event, but the panel only looks at row names, so a change that
  keeps the name doesn't touch the table.
- The table never takes the keyboard focus and passes every key on, so clicking it leaves your
  focus where it was. It has no selection and no context menu.

## Show Info

Show Info gathers everything Bifrost knows about one session into a single panel, so you can see
its IDs, its folder, its branch and pull request, its model and its limits without opening the
session itself. Each session gets its own panel, stored as `show-info:<session ID>`, and its title
follows the session's name, as in "Show Info: fix-login" (plain "Show Info" once the row has
gone). The panel reads the session's row from the session list, the one place that holds the rows,
so every change to the row shows straight away.

The values come in seven sections, always in this order:

| Section | Values |
| --- | --- |
| Session | Name, Claude Code name (only when a local name hides it), Session ID, Current conversation (only when it differs from the session ID), Short ID, Kind, PID |
| Files | Project folder, Transcript |
| Git | Branch, PR, Worktree |
| Model | Model, Effort, Permission mode |
| Time | Started, Duration |
| Cost and context | Cost, Context window, Context use |
| Limits and version | 5-hour limit, 7-day limit, Claude Code version |

- A value Bifrost doesn't know, or one that's empty, shows "-". Each label sits level with the top
  of its value, and the IDs and paths (Session ID, Current conversation, Short ID, Project folder
  and Transcript) use the system's monospaced font, SF Mono, as in the Electron app.
- The session ID is the ID that `claude --resume` needs, the same one Copy session ID copies. For
  a session in another terminal that's the conversation it shows now. For a background job it's
  the job's resume ID, which Bifrost may not know yet, so a job that has been cleared with
  `/clear` also lists the conversation it shows now as "Current conversation".
- Kind is "Owned" for a session that Bifrost started and "External" for one in another terminal,
  followed by the terminal app in brackets when Bifrost knows it, as in "External (Warp)".
- Started shows the clock on the same day ("09:07"), and otherwise the day, date and clock ("Thu 5
  Nov 14:03"), always on a 24-hour clock with English names and in your time zone. Duration is
  "Parked" for a parked session and otherwise a length such as "2 h 53 min". The panel's clock
  moves every second, so the duration keeps up while the panel is open.
- Cost is the estimate from Claude Code with its "≈" mark, as in the Overview. Context window is
  a token count such as "200k tokens" or "1.5M tokens", with at most one decimal and a half
  rounded up, and context use is a whole percent.
- A limit shows its use and its reset, as in "62%, resets 14:03". Once the reset time has passed,
  Bifrost can't know the new use until the session sends another message, so the limit shows
  "-, reset at 09:07" instead, just like the Usage HUD. A plan with only a 7-day window hides the
  5-hour row, while a session with no limits yet shows both rows with "-".
- Worktree is the root of the session's Claude worktree, taken from its folder or, for a session
  that has stopped, from the worktree Bifrost saw while it ran. A plain folder shows "None".
- The PR line says "Loading..." while the PR lookup runs, then "#12 Fix (open)" for a pull
  request (the state in lower case), "None" for a branch with no PR, or the reason Bifrost
  couldn't check. A new folder or branch on the row asks again.
- Until the first session list arrives the panel says "Waiting for the session list...", and once
  the list has no row for the session it says "This session isn't in the list any more."
- A session with no live line and no model gets a hint under the sections: "Turn on Live details
  in Settings to see the model, effort, cost and limits."

The panel has three small controls, none of which take the keyboard focus:

- The copy button after the session ID copies that ID, with "Copy session ID" as its tooltip. A
  background job whose resume ID Bifrost doesn't know yet copies nothing.
- A pull request shows as an underlined link that fades a little under the pointer, and clicking
  it opens the PR in your browser. The
  panel can stay open longer than the lookup keeps its answer, so the click asks the lookup again
  (which reuses a fresh answer and otherwise runs `gh` again), and only an `https` address opens.
- When one of those clicks fails, its reason shows in an error line after the values (at the
  bottom of the panel when the values don't fill it), and it stays there until you close it with
  the line's close button.

The values are plain text that you can't select, because a text selection needs the keyboard
focus (see the differences file).

## The PR lookup

The PR line comes from the GitHub CLI. `PRLookup` runs `gh pr view --json number,title,url,state`
in the session's folder, with the environment of the Claude Code runs so it finds the `gh` on your
login `PATH`, and gives it 10 seconds to answer. `gh` works out the branch of that folder itself,
so no value from the row ever becomes one of its arguments.

Before it runs anything, the lookup checks the row:

- A folder that isn't an absolute path (or holds a NUL character), a row with no branch, and a
  branch that starts with "-" all give "None" with nothing run. Git never names a branch with a
  leading "-", so such a value can't be a real branch.
- It then reads the folder, and gives those reads 2 seconds from their start, since a read can hang
  on a network volume that has gone offline. A wait for a free thread doesn't count. A folder that
  isn't there, one that Bifrost isn't allowed to search (so `gh` couldn't start in it), and one that
  doesn't answer in time all give "The session folder isn't there any more."
- A folder at or below one of the review folders (`StartPlan.branchSkipRoots`, the same folders
  in which Bifrost never runs `git`) gives "This is a review session, so Bifrost doesn't run gh in
  its folder." A review session can write the git config of its folder, and `gh` would read it.
  The check also compares the real paths, so a link into a review folder counts too.

What `gh` gives back turns into the PR line like this:

| `gh` gives | The PR line |
| --- | --- |
| A good exit with the number (a whole number), the title, the state and an `https://` address | The PR |
| An error that says "no pull requests found" (in any case) | None |
| No answer within 10 seconds | GitHub CLI (gh) didn't answer within 10 seconds. |
| No start, because `gh` isn't on the `PATH` or can't run | GitHub CLI (gh) isn't installed. |
| No start, because the folder went away after the check | The session folder isn't there any more. |
| Any other error | The first line of the error, without hidden characters, cut to 200 characters |
| An error with no text, output over the runner's 1 MiB limit, a run that was stopped, or a good exit without a usable PR | GitHub CLI (gh) couldn't check for a PR. |

The title and the state come from GitHub, so they lose any hidden characters too, which stops a
bidi control in a PR title from changing how the rest of the panel reads.

The lookup keeps each answer for one folder and one branch: a PR or "None" for 5 minutes, and a
failure for 30 seconds, so a fix shows soon without `gh` running again at once. Two lookups of the
same folder and branch at the same moment share one run of `gh`, and old answers drop out of the
cache whenever a new one comes in. When the app stops the lookup, any `gh` that's still running
is stopped and the lookup runs no more.

`AppOpener.openInBrowser` opens only an `https` address: anything else is refused with "Bifrost
only opens https addresses." and nothing opens, and the open gives up after 10 seconds.

The tests never run the real `gh`. They use a fake runner, or the fake in `scripts/fake-gh/gh`,
which answers `pr view` from `fake-pr.json` in the test home (or with GitHub's "no pull requests
found" error when the file is missing), and refuses to run unless `HOME` is the test home.

## The Watchlist

The Watchlist is a short list of the sessions you've chosen to keep an eye on, each in a colour
you picked and in an order you set yourself. You add a session with Add to watchlist in its row
menu (Track, with the space labels), change its colour or take it off from the same menu, and drag
the rows into the order you want. The colour and the place belong to the session in the registry,
next to its local name and its priority, so the panel reads the rows from the session list like
every other panel and never keeps a copy of its own. It shares the Overview's model
(`OverviewModel`) for the selection, the Row flash setting, the terminal app icons and the Open
and row menu actions, so a row behaves here as it does in the Overview.

- Each watched session gets one row, 26 units high, in watch order. A row shows the session's row
  icon with its box, its name and its state, on a tint of its watch colour at 12 % with a 3-unit
  stripe of the full colour down its left edge. A parked session's name is in the parked colour,
  and the state has the same colours as in the Overview.
- The selected session has the selection colour over its tint, with the stripe still on top, so
  you can always see the watch colour.
- A click selects a row. A click while you hold a hold key runs that key's command on the row
  instead and leaves the selection where it was. A double-click selects the row and opens the
  session, and a right-click (or a Control-click) opens the row menu without changing the
  selection. Every action looks the row up by its ID when it runs, so it always acts on the row
  as it is now.
- The rows never take the keyboard focus, so clicking one leaves your focus where it was, and the
  Bifrost keys act on the selection as usual.
- With nothing watched, the panel says "Nothing on your watchlist yet. Right-click a session and
  choose Add to watchlist." The name of the menu item follows your label set, so with the space
  labels the text ends "choose Track."

### Reordering

To reorder the list, press a row and drag it up or down. A press only becomes a drag once the
pointer has moved 4 units, the same distance a frame drag needs before it can stack, so a small
wobble during a click is still a click.

- While you drag, the row you're moving fades to 40 % and a thin line in the strong text colour
  marks where it will land. Over the upper half of a row the line goes above that row, and over
  the lower half it goes above the next one, or below the last row at the end of the list. A
  pointer above the list counts as the top and one below it counts as the end.
- No line shows while the drop would leave the row where it is, and letting go there changes
  nothing.
- Letting go anywhere else moves the row in the registry (`RegistryService.watchMove`), and the
  list redraws in the new order. Letting go of a drag never counts as a click, so the selection
  stays as it was.
- The drag is a drag session of macOS, so a picture of the row follows the pointer. Esc during a
  drag cancels it through the system: the row and the line go back, nothing moves or gets
  selected, and that Esc doesn't also open or close Settings. Letting go outside the list ends
  the drag the same way. Before the pointer has moved far enough, the press is still a click.
- If the move fails, for example because the row you dropped it next to has just left the list,
  the reason ("This session isn't in the list any more.") shows in an error line at the bottom of
  the panel. It stays until you close it with the line's close button or the next move works.

The rules behind this are in `WatchOrder`: `place` finds the row and the half under the pointer,
`dropTarget` turns that into the session the dragged row goes before, and `shouldMove` says
whether letting go should move it, which it never does for a cancelled drag or a drop in the
row's own place.
