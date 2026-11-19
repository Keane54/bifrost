# Daily update: behaviour

The Daily update is a reminder plus a draft. On the days you pick, Bifrost reminds you in the
morning to post a short team update, and it asks Claude to draft that update from the tickets that
moved on your board and the PRs you merged. You read the draft, change it if you like, and post it
yourself to a Slack channel. Bifrost never changes the board, and it posts nothing without a click.

This page covers the settings and their section in Settings, the reminder schedule, the panel, the
state of the day and the run that asks Claude for the drafts. The rules live in
`BifrostDailyUpdate/Model/`, and the store and the run in `BifrostDailyUpdate/Services/`. The panel
is in `BifrostWindows/UI/DailyUpdate/` and the Settings section in `BifrostSettings`.
`docs/ports/daily-update/DELIBERATE-DIFFERENCES.md` lists where the native app differs from the
Electron app on purpose.

## The settings

The settings are the `dailyUpdate` block of `settings.json`, with the field names and the meaning
that the Electron app used, so the block you had keeps working. A block that isn't an object counts
as no block, and the app then uses the defaults. Inside a block, one bad field costs only that
field: it gets its default and the others stay. Fields that this version doesn't know are kept and
written back on the next save.

| Field | Meaning | Default |
| --- | --- | --- |
| `source` | The board: the name of one MCP server, and the read tools that the run may use (`mcp__<server>__<tool>`). One tool that doesn't belong to the server drops the whole list. | No server, no tools |
| `you` | Your name, email or ID on the board, up to 200 characters. | Empty |
| `mergedPrs` | Whether the draft also lists the PRs you merged. | On |
| `draftTime` | When the first reminder comes, as `HH:MM` on a 24-hour clock. | `09:30` |
| `deadline` | When the update is due, at least 10 minutes after the draft time. If it isn't, both times go back to their defaults. | `10:00` |
| `days` | The days that count, 0 for Sunday to 6 for Saturday, written in sorted order. | Monday to Friday |
| `model` | The model of the run. Empty means the default model of Claude Code. | Empty |
| `format` | The template of the draft (1 to 2,000 characters) and up to three examples of earlier updates (4,000 characters each). | A plain template with a title and three headings |
| `areas` | Up to ten work areas, each with an ID, a name, a channel, a description, and the flags `on` and `takesRest`. | None |

An area that is off is ignored. At most one area takes all the work that no other area claims: if
a file has two, the first keeps the flag. An area with no name, a repeated ID or a place after the
tenth is dropped. The defaults name no board, no company and no person.

## Settings > Daily update

The Daily update tab of Settings edits that block, one row per setting, in the order and with the
labels of the Electron app: Ticket source, Tools the run can use, You on the board, Use merged PRs,
Draft and first reminder, Deadline, Days, Model, Format, Examples of your updates and Work areas. A
last row, Daily update panel, opens the panel. The search of Settings finds each row by its label.
`DailyUpdateRows` holds the labels and the rules, and `DailyUpdateSection` the rows.

Every change is checked against the whole block before it saves, so a refused change shows its own
reason under its row and nothing is written: a time that isn't `HH:MM`, a deadline less than 10
minutes after the draft time, no day left, an empty format, a fourth example, an eleventh area, an
area with no name or a text over its limit. The times are text fields that take `HH:MM`, the days
are seven buttons from Monday to Sunday, and the model is a standard pop-up menu.

The ticket source is a pop-up menu of the MCP servers that Find servers read. Finding them starts
the same short probe that the run uses (see "The servers" below), so only the button starts it, and
the row says "Looking for your MCP servers…" while it runs. Every server is listed, a Slack server
included (user decision, 2026-11-18). A server that isn't connected shows its status, for example
"(needs sign-in)", and can't be chosen. When you choose a new server it saves with no tools, and the
tools list below ticks the ones whose names only read. Those ticks are a proposal: nothing is saved
until you click Use these tools, and you can change the ticks first. After that, each tick saves at
once. A tool whose name has a write word stays unticked with the note "Bifrost never lets the run
use this tool", and a tool with neither kind of word says "May change things". The list shows each
tool by its name after the server's prefix.

The format is a box of several lines for your template, where bold is `**text**`, and Add example
adds up to three more boxes for earlier updates. Each box saves when you leave it, and Esc puts the
saved text back. A text that is refused, such as a format over 2,000 characters, stays in its box
with the reason under the row, so you can correct it.

Work areas are boxes, one per area, with On, the name, the channel, Remove, "Which work goes here"
and "Takes all other work". Add work area adds an area that is on, with a free name such as "Work
area 2", which you then change, so every area in the file has a name. Remove asks first. Only one
area can take all other work: ticking it on a second area is refused with "Only one work area can
take all other work." Until the Slack app exists, the channel is a name you type.

When the Daily update doesn't run, a line at the top of the section says why: another copy of
Bifrost holds it ("Daily update is running in another copy of Bifrost."), or Bifrost couldn't find
Claude Code.

## The schedule

The reminders follow the wall clock of the Mac (the weekday, the hour and the minute), so a day
with a clock change needs no special case. On a due day that still has work left, Bifrost does this:

- Before the draft time, nothing happens.
- From the draft time, the first reminder runs a draft and then notifies you.
- Ten minutes before the deadline, the second reminder notifies you again. If the first reminder
  never came (the Mac was asleep, or Bifrost started late), the second runs the draft instead.
- After the deadline, a late start runs the draft one time and makes no sound.

The first and the second reminder never come together, and each one comes once. Nothing more
happens once every area that is on has been sent or skipped, or when you skip the day. The button
in the side bar shows its marker from the draft time until midnight, or until the work is done.
Marks from an earlier day count as fresh marks, so the day starts clean after midnight.

Rather than checking the clock on a timer, the schedule works out the next moment at which the
answer can change: the next draft time, second-reminder time, deadline or midnight. If that time
doesn't exist (the hour that a spring clock change skips), the first time after the gap is used.
The period that a draft covers starts at your last send. With no send, it starts at the beginning
of the last due day before today, looking back at most a week.

## Reminders

One service plans the reminders. It sleeps until the next date that the schedule gives, then acts.
It plans again after a wake from sleep, a change of the clock or the time zone, a new day, and a
change of the Daily update settings. There is no polling loop.

Each reminder is a notification with sound (the late start has none), and a click opens the panel at
the first tab that isn't sent:

- "Your daily update is ready to check." comes after a draft for the first reminder and for a late
  start. The late start makes no sound.
- "10 minutes left to post your daily update." comes for the second reminder, and the Dock icon
  bounces one time.
- "Bifrost couldn't write your daily update. You can still write it yourself." comes when a
  scheduled run fails. The failure also shows in the panel.

Bifrost marks a reminder as shown before the draft runs, so a wake or a second plan never gives it
twice. A second reminder that comes while the run of the first reminder goes is dropped, so the two
never show together. A reminder that comes while you run a draft by hand waits for that run. No
reminder shows or sounds once every area is sent or you skipped the day. A start or a wake after
the draft time on a due day with work left runs at once and shows one notification.

Opening the panel or Refresh with no area on runs nothing, and the panel says so.
Opening the panel runs a draft only when no run is going and the last run ended more than 5
minutes ago. Refresh and Redo always run. A refresh keeps each draft that you changed and offers
the new draft beside it. Redo replaces the draft of its own tab only.

Only one copy of Bifrost owns the Daily update. When another copy holds it, this copy sends no
reminder, runs no draft and writes no skill export, and the panel says so.

## The panel

The Daily update panel opens from its side bar button, which sits after Reviews and shows a
small dot ("Daily update - Not sent yet") while the side bar marker is on. A click on a reminder
opens it too, at the first tab that isn't sent. The panel reads the snapshot of the service, so a
run, a mark or a new draft shows at once.

At the top, a status line gives the state of the day ("Your drafts are ready.", "Bifrost is writing
your drafts.", "All your updates are sent for today." and so on) with Refresh and Skip today, which
becomes Undo after a skip. Under it come "Due 10:00" on a due day, the time of the last good run
("Refreshed 09:31", or the day and date for an earlier day) and, when the run found items that fit
no area, a count such as "2 tickets fit no area", which shows those items when you click it. If the
last run failed, its reason sits under the status line, and Mark as sent and Skip today keep
working, so you can write the update yourself.

Each area that is on has a tab, and a tab that isn't sent has a small marker on a due day you
haven't skipped. The tab you pick stays after you mark it, so the panel doesn't jump. In a tab:

- "Moved since your last update" lists each ticket and PR with its ID, title and change of state.
  A click opens its link in the browser, and only an https link opens.
- When a refresh brings a new draft while you have changed yours, "There's a new draft." offers
  Use new draft and Keep mine.
- The draft editor shows the draft with its bold parts in bold, and you change the text in place.
  Each change is saved as Markdown, and text you type after a bold part stays bold. A paste comes
  in as plain text.
- Redo draft writes a new draft for this tab only. If you changed the draft, it asks first with the
  confirm dialog.
- Copy puts the draft on the clipboard as standard Markdown and shows "Copied" for two seconds.
- Mark as sent becomes "Sent at 09:31" with Undo.
- "Send to #channel" stays off, with the tip "Sending comes with the Slack app. For now, copy the
  draft." Bifrost posts nothing.

With no area on, the panel shows "Set up your work areas to get a daily update." and Open settings,
which goes to Settings > Daily update. With no service, it says why, as the Settings section does.

## The state of the day

`state.json` in the Daily update folder holds what happened today and the drafts. The format is the
one the Electron app wrote, with times as milliseconds since 1970.

- A new day gives fresh marks and drops any waiting draft, so the run of the new day replaces a
  draft that you changed the day before. The time of the last send stays.
- A run replaces the items and the draft of each area. If you changed a draft, yours stays, and
  the new draft waits beside it: you can take the new one or keep yours.
- Redo replaces the draft of its own tab only, even one that you changed.
- Mark as sent records the time and keeps the send before it, so Undo can bring it back.
- Skip today stops the reminders for every area.
- A failed run keeps its reason, and the panel shows a plain text for it.

## The store

The state file is opened in place, so the Electron data carries over. The first time the native app
opens it, it keeps a copy next to it, `state.json.before-native`, and never replaces that copy. If
the copy fails, the app keeps the state in memory and doesn't save, so the old file stays safe.

Only one copy of Bifrost may own the Daily update. The app takes an exclusive lock on the `.lock`
file in the folder and holds it until it quits. A second copy, such as a second Dev app or the
release app after the cutover, finds the lock taken. It shows "Daily update is running in another
copy of Bifrost." in the panel, and it neither reminds you nor writes the state. The lock goes away
by itself when the first copy quits or crashes. The lock is the same one Reviews uses: it keeps the
folder private (mode 0700) and refuses a link in place of the folder or the lock file.

## Draft text

A draft is Markdown with `**bold**` parts. The panel shows those parts in bold, and Copy gives the
draft back as standard Markdown with the two stars. A bold part sits on one line and has at least
one character inside. Everything else, including a single `*`, is plain text. The draft comes
from Claude, so the panel never reads it as anything else.

## The run

A run is a short Claude Code session in print mode (`claude -p`) that reads your board, puts each
ticket and merged PR in the work area it belongs to, and writes one draft per area. It uses the
`bifrost-daily-update` skill from the skills plugin that ships with the app. The run can read, but
it has no tool that writes, so it can't change a ticket, a file or anything else. It never shows in
the Overview, because it isn't a session you work in; its start, its end and any failure go to the
Event log instead. `DailyRunner` runs it and `DailyUpdateService` starts one run at a time, and a
whole run stops after five minutes. A run only counts as over once its programs have ended, so a
new run never starts while Claude from the last one is still shutting down.

### Before Claude starts

Some runs fail before any Claude process starts. With no ticket source and merged PRs turned off,
there's nothing to read.

Each run gets a new private folder (mode 0700) under `runs/` in the Daily update folder, named
after the UTC start time, for example `runs/20261118-093000`. A second run in the same second gets
`-2` at the end. Bifrost keeps the ten newest run folders and removes older ones; it only ever
removes folders with a run name.

When merged PRs are on, Bifrost asks the GitHub CLI for the PRs you merged since the earliest start
of your areas:

```
gh search prs --author=@me --merged-at=">=<UTC time>" --limit 100 \
  --json number,title,url,repository,closedAt,body
```

For a merged PR, `closedAt` is the merge time. gh runs in the `runs/` folder, so it never reads one
of your repositories, with prompts and the update notice turned off, and it uses its own login:
Bifrost reads no token. The title and the description of each PR go into the run, so a PR that
names a ticket ends up in the same area as that ticket. A description over 2,000 characters is cut
and ends with "[Bifrost cut this text.]". If gh fails, the Event log says so and the drafts leave
the PRs out.

### The servers

Next, a probe reads the MCP servers of your Claude Code setup and their tools. It's a run of
`claude -p --output-format stream-json --no-session-persistence --verbose --tools "" --model haiku
--permission-mode dontAsk --settings '{"disableAllHooks":true}' "Reply with OK only."`, and its
first event lists every
server and every tool. Bifrost stops it right after that event, before it asks a model anything.
The small model, the short prompt and the permission mode keep a probe that misses the stop cheap
and harmless, and the probe has a limit of 30 seconds. It comes after the PRs, so the tool list is
as fresh as it can be.

A tool belongs to the server whose prefix it starts with, which is the rule Claude Code uses to
name the tools: `mcp__` plus the server name with each character other than a letter, a digit, `_`
or `-` turned into `_`, plus `__`. For a claude.ai connector (a name that starts with
`claude.ai `), each run of `_` then shrinks to one and a `_` at either end goes, so
`claude.ai Atlassian (Jira)` gives `mcp__claude_ai_Atlassian_Jira__`. The probe keeps every MCP
tool by its full name too, including one that fits no server, so the run never has to trust this
rule to deny a tool. If the ticket source isn't connected, or the probe doesn't list it, the run
fails with "Bifrost couldn't reach <server> (<status>). Check it in Claude Code with /mcp."

### The input file

`input.json` (mode 0600) in the run folder tells the skill what to do:

| Field | What |
| --- | --- |
| `version` | Always 1. |
| `now`, `timeZone` | The time of the run in UTC, and the time zone of the Mac. |
| `you` | "You on the board", which can be empty. |
| `areas` | Each area that is on: its ID, name, description, `takesRest` and `since`, the start of its period. |
| `format` | The template and the examples. |
| `prs` | The merged PRs: repository, number, title, link, merge time and description. |
| `source` | The server of the board (`null` for none) and the tools the run may call. |

Times are ISO 8601 text in UTC with milliseconds, for example `2026-11-18T09:30:00.000Z`. The
period of an area starts at its last send, or at the start of the last due day when it has none.

### The Claude run

Then Bifrost runs `claude -p` in the run folder, with no input on stdin and these flags:

| Flag | Value |
| --- | --- |
| `--output-format` | `json` |
| `--no-session-persistence` | Claude Code saves no session for the run, so `~/.claude/projects` gets no new project folder for each run folder |
| `--tools` | `Read,Skill`: no tool that writes, no shell, no network |
| `--permission-mode` | `dontAsk`, so any tool without an allow rule is refused at once |
| `--plugin-dir` | The skills folder of the app |
| `--add-dir` | The run folder |
| `--allowedTools` | The allowed board tools, `Skill`, and `Read(//<run folder>/**)` and `Read(//<skills folder>/**)` |
| `--disallowedTools` | Every other MCP tool of the probe by its full name, then the rule of each other server |
| `--settings` | `{"disableAllHooks":true}` |
| `--model` | The model of the settings, only when it isn't the Claude Code default |

The prompt comes last: `/bifrost-daily-update bifrost-input=<path of input.json>`. Both folders are
real paths with no links, so the read rules match what Claude reads.

The allowed board tools are the ones you picked that the source still has now, minus any tool whose
name has a word that changes things. The run denies every other MCP tool that the probe listed, one
by one by its full name: the rest of the source's tools, every tool of every other server, and any
tool that fits no server. On top of that it denies each other server as a whole, with a rule
such as `mcp__claude_ai_Claude_Docs`, in case a tool shows up after the probe.

### Which tools only read

Settings proposes the tools of a server that look read-only, and the run uses the same words to keep
the others out. A tool name is split into words after its prefix, at `_`, at `-` and at each
camelCase step, so `getIssueID` gives "get", "issue" and "id". A tool is proposed when one of its
words is `list`, `get`, `search`, `query`, `read`, `find`, `diff` or `aggregate`, and none of its
words is a verb that can change things, such as `add`, `create`, `update`, `delete`, `move`,
`mark`, `set`, `send`, `post`, `assign`, `close`, `cancel`, `start`, `reset`, `share`, `resolve`,
`save`, `rename` or `deploy`. `ToolProposal.writeWords` has the whole list. That's why
`work_items_mark_comment_read` isn't proposed. A word that read tools also use as a noun, such as
`comment` in `list_comment_reactors`, isn't on the list, because a tool that writes such a thing
names a verb as well (`add_comment`).

### The result

`claude -p` prints one JSON object, and its `result` field is Claude's final reply. Bifrost takes
the text between the last line that is only `BIFROST-DAILY-RESULT-BEGIN` and the next line that is
only `BIFROST-DAILY-RESULT-END`, and checks it strictly. The board and the PRs are text Bifrost
doesn't trust, so one broken rule throws the whole result away:

- The output is at most 1 MiB, the reply isn't an error, and the result has `version` 1.
- The result has only `version`, `areas` and `unplaced`. Each area of the input shows exactly once,
  with only `id`, `moved` (true or false), `items` and `draft` (1 to 8,000 characters).
- Each item has only `kind` (`ticket` or `pr`), `id` (up to 100 characters), `title` (up to 300),
  and optionally `from` and `to` (up to 60 each) and `url` (up to 2,000, and it must start with
  `https://`). A list holds at most 100 items, and never the same kind and ID twice.
- A failure result has only `version` and `failure`, and the failure is `no-user`,
  `source-unavailable` or `tool-denied`.

A run that takes too long fails with "The run took more than 5 minutes, so Bifrost stopped it."
Output that breaks a rule gives "Claude's answer didn't have the right shape, so Bifrost didn't use
it." A failed Claude gives "Claude Code couldn't run the daily update." with the first line of its
error. If you stop Bifrost during a run, that run isn't a result: it changes nothing and writes no
line.

### The Event log

A run writes these lines:

- "Daily update: Bifrost is writing the drafts." when it starts.
- "Daily update: the drafts are ready." when it ends well.
- "Daily update: " and the failure text when it fails.
- "Daily update: Claude tried 2 tool calls that the run isn't allowed to make." when the permissions
  refused some calls. Only the count goes in the log, never the tool names.
- "Daily update: Bifrost couldn't read your merged PRs, so the drafts leave them out." with the
  reason from gh.

### The skill export

You can also type `/bifrost-daily-update` in any session to see drafts in the chat. The skill then
reads `settings.json` in the Daily update folder, which Bifrost writes (mode 0600) when it starts
and whenever the Daily update settings change; a change to any other setting doesn't write it. The
file holds only what the skill needs: `version`, the areas that are on, the format, the merged PRs
switch, the source with the tools you picked minus any write tool (the same filter as the run), and
"You on the board". It holds no secret. With no Daily update block in the settings, it holds the
defaults.
