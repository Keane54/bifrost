# The session registry: behaviour

The session registry is the part of Bifrost that keeps one row for each Claude Code session, and
it's the one place that the session list, the chat windows and the session input read their rows
from. This page describes how it builds those rows and the rules it follows. The Electron app was
a reference for behaviour only (user rule, 2026-11-16), and the places where the native app
differs from it on purpose are listed in `docs/ports/registry/DELIBERATE-DIFFERENCES.md`.

The code is in the `BifrostSessions` module. `Model` holds the registry and its rules, and
`Services` holds the service that runs it, the branch reader, the store file and the session list.

## What it does

The registry brings several sources together into one row for each session: the output of
`claude agents --json` (the sessions that are active now) and `claude agents --json --all` (every
session Claude Code knows about, including stopped ones), the state events and usage lines of the
Live details mod (a Claude Code mod that sends Bifrost each session's events and usage over a
local socket), and the git branch of each session's folder. From these it decides the state of
each row, its alert box and the name it shows.

## States and alert boxes

Each row has a state, which says what the session is doing, and an alert box, which is how the
row asks for the user's attention. A row is `working`, `needs-you`, `error`, `idle` or `parked`,
and its box is none, yellow or red. Most changes come from the state events of the Live details
mod, and the polls of the session list then confirm or clear them.

- A prompt gives `needs-you` with a red prompt box. A prompt is a permission request, an
  `AskUserQuestion` tool call or a `permission_prompt` notification. When the same prompt comes
  again, the row keeps its box and the time of that box.
- A stop gives `needs-you` with a yellow box, and keeps the session's last message.
- A stop failure gives `error` with a red error box, and a repeated error keeps the box it has.
- Only a red box carries a reason, which is prompt, escalated or error.
- A yellow box turns red once the escalation time has passed. That time is a setting, 10 minutes
  by default, and 0 turns escalation off. A PR review session never gets a yellow box.
- When the user stops a turn, the row goes to `idle` with no box and no alert, and the partial
  answer stays as its last message.
- Events apply in order: an event older than the last one applied is skipped, and two events with
  the same time follow the mod's sequence numbers.
- `SessionEnd` parks a row, except after a `/clear`, which keeps the same process. A parked row
  comes back when `SessionStart` arrives, or when the active list shows the session with a process
  ID in a poll that started after the park. The second way is how a row un-parks when the Live
  details mod isn't there to send `SessionStart`. For a row that's still running, `SessionStart`
  changes nothing, because the mod sends it again at every reload.

The polls of `claude agents --json` give each session a status, and each of these samples checks
the boxes that the events set:

- A status is busy, waiting, idle or unknown. Unknown covers a missing status and one that the app
  doesn't recognise, and it changes nothing.
- Only an entry of the kind `background` is a background job, which Bifrost shows as an owned
  row. Every other kind is an external row, a session running in another terminal.
- A sample clears a box only after an earlier sample has confirmed that box. An idle sample clears
  a red prompt box only when it starts more than 1 s after the box, so an older poll that finishes
  late can't clear a new box, and a sample that isn't newer than the box is ignored.
- A waiting status with a question gives a red prompt box, or confirms the one that's there.
- Without recent lines from the mod, the polls alone can end a turn: an idle sample that follows
  busy or waiting, on a row with no box, gives `needs-you` with a yellow box.
- A row is live for 90 s after the last line from the mod. A usage line doesn't count as
  activity.

## Rows and identity

A session can change its ID during its life, for example after a `/clear` or a resume, so the
registry keeps the identity of a row apart from the conversation it shows now. These rules decide
which row each session belongs to and what the row is called.

- The row ID is the first session ID that Bifrost saw for the session, and it never changes. The
  current ID is the conversation the row shows now, and that one can change.
- A session ID in the UUID form is kept in lower case wherever it comes in: the session list, a
  line from the mod, a panel ID, and each row ID and current ID in the store file. That way a row,
  its chat panel and its live lines always agree on one ID. If the store file has two keys in one
  map for the same row (they differ only in case), the key that's already lower case wins, then
  the first in sort order, and in a list the first entry wins.
- Each entry of a list finds its row in this order: the row with the short ID of a background job
  (where the folder must agree), then the row whose current ID matches, then, in the active list
  only, a `/clear` link (no short ID, the same process ID and folder, and the old ID gone from
  this list), and last a new row. A new row takes the session ID as its row ID, unless a row or a
  stored value other than the PR flag already has that ID, in which case it gets a new UUID.
- The live lines of one current ID go to one row. When several rows share that ID, the row that
  owns the lines comes first and the others follow in row ID order.
- A state event for a session that the registry doesn't know yet waits 60 s for it to show up.
  At most 1,000 such events wait, and at most 256 session IDs with no row keep any live data (a
  line time, a usage line or a waiting event), the oldest out first, so a flood of lines with new
  session IDs can't fill the memory.
- A row shows its local name (the name the user gives it in Bifrost) if it has one, else its
  Claude Code name, else its short ID, else the first 8 characters of its row ID. A model ID shows
  as a readable name, for example `Opus 5.5` or `Opus 4.7 (1M context)`.
- A local name has at most 64 characters, counted as Swift `Character`s, and no control,
  zero-width or bidirectional-text character. It's trimmed with `Character.isWhitespace`, under
  which U+FEFF and U+200B aren't white space, so a name that holds them is refused. An empty name,
  or one equal to the Claude Code name, removes the local name, and so does a later Claude Code
  name that matches it.
- A priority runs from 1 to 5. The watchlist keeps the order the user gives it, and a newly
  watched row gets one of eight colours (old stored colour names map to a current colour).
- The terminal app of an external row comes from its process ID. The registry walks up the
  parents of that process only, never the whole process table, until it reaches the first process
  inside an app bundle. A process ID that no longer has an external row is dropped, and one with
  no app isn't looked up again.
- A background (owned) session runs inside Claude Code's background service, so walking up from
  its process never reaches the terminal where you're looking at it. Instead, while the registry
  has any owned session, every good active poll also scans for `claude attach <id|name>` clients
  ([the process inspector](process.md#the-process-inspector) has the details). Claude Code reads
  the argument as the start of an ID when it's only hex digits and dashes, and as a session name
  otherwise, and the registry matches it the same way: against the short ID and each session ID
  of an owned row, or against its Claude Code name. An argument that matches no owned row, or more
  than one, is ignored, because Claude Code refuses those too.
- Each owned row that isn't parked gets the terminal app of its newest client that has one: the
  latest start time wins, then the higher process ID. The newest attach is the window you opened
  last. A client with no app, such as one inside tmux, doesn't hide an older client in a terminal
  app. Every scan replaces the previous one, so closing a terminal drops its app at the next poll,
  and the rows only change when an app changes. Clients that Bifrost started itself are
  left out, because the Overview takes those from the chats.

## Forgetting a session

Claude Code's lists can fail or come back incomplete, so the registry only forgets a session once
it's sure the session has gone.

- Only a counted `--all` list can remove a row. A list counts when it's complete, isn't empty,
  holds every background session of the last active list, and either has a background entry or
  comes at a time when the registry knows no parked owned session.
- A session that two counted lists in a row don't have is forgotten. A session that has left the
  active list stays in `lastActive` for 60 s.
- The gone count watches the owned rows, each row with a stored value other than `lastActive` and
  the PR flag, and each session that has a line from the mod.
- Deleting a session whose worktree another session uses is deferred. The delete goes ahead after
  two counted lists without the row, or once no row, running entry or background job uses the
  worktree, and a deferred session that runs again cancels it.

## Rate limits

The Usage HUD shows the newest rate limits, which the registry picks from the usage lines of all
sessions. It picks the five-hour and the seven-day window separately: the latest `resetsAt` wins,
readings within 10 minutes of it count as the same window, and inside that window the highest use
wins. An equal use goes to the newer reading, and a full tie goes to the lowest session ID.

A line from the Live socket can come from any process of the same user, so the registry only takes
rate limits from a session that the session list knows, and each window only when it resets
between now and 8 days from now. A line whose windows all fail keeps the last good ones.

## The service

The registry service runs the registry on the main actor. It polls Claude Code, applies what comes
back, saves the store and publishes the rows, using four loops.

- The active poll runs every 2 s by default (the Poll setting), or every 15 s or more while the
  window is hidden, and it runs at once when the window shows again. The wait starts when a poll
  ends, and a new interval applies from the next wait.
- The `--all` poll runs every 30 s, the branch loop every 10 s and the tick every 1 s. These three
  start when the first active poll ends, so they work on real rows.
- Only one `claude agents` process runs at a time. The sample time of an active poll is the moment
  it starts to run, after any wait for the other poll.
- The rows, the error, the rate limits and the live count update straight after each change, and
  a value that doesn't change notifies no one. A tick or a round of the branch loop that changes
  nothing rebuilds nothing, so a quiet registry does no work each second.
- The rows live only in the registry. The session list reads them from it rather than keeping a
  copy, so a row that `waitForRow` returns is already in the list. The list counts as loaded once
  the first active poll ends, with either its rows or its error.
- A failed active poll keeps the rows and shows a friendly reason in the session list until a
  poll succeeds. The details of the failure, such as the stderr of claude, go to the log once for
  each kind of failure, so a stderr that changes on every run can't crowd out later loop errors.
  A failed or partial `--all` list changes nothing and never counts towards forgetting a session.
- When Bifrost can't find claude, the registry doesn't start and the session list shows the status
  `claude not found`.
- A save runs only when the store differs from the last saved store, and only one runs at a time,
  so a change during a save saves again when that save ends. A failed save is logged once for a
  series of failures, and the tick tries again each second until a save works. Each loop error is
  logged once, up to 20 messages.
- Each state event from the mod goes to the `events` stream after the registry has applied it,
  with the row ID as its session ID. With no reader, the stream keeps the newest 1,000 events.
- `forgotten` holds the row IDs that Bifrost has forgotten for good: a Delete, or a session that
  two counted `--all` lists didn't have. A deferred delete never goes in, because that session can
  come back.
- `waitForRow` returns the first row that matches, or throws a timeout, stopped or cancelled
  error. `waitForRows` waits in the same way for the whole list to match, so it also sees a change
  that leaves no row at all, which a wait for one row can't match.
- After a stop, no loop runs, and neither a late result nor a command changes anything.

## The store file

The registry saves what it needs to remember between runs in `registry.json`.

- The store keeps the local names, priorities, the watchlist, worktrees, short IDs, deferred
  deletes, and the sets `started`, `lastActive`, `prSessions` and `prNames`. A save never loses a
  field that the app doesn't know.
- In memory, the registry keeps the stored values of a row together in one record. The file keeps
  one map or list for each value, in the format of the Electron app, so a file of an earlier
  version loads to the same values, and a save of those values gives the same bytes.

## Branches

The branch reader finds the git branch of each session's folder, mostly without running git.

- It reads `.git/HEAD` directly, reads it again only when its modification time changes, and asks
  git (with a time limit of 2 s) only when the file is something it can't read.
- It follows links, so a `.git` that links to a folder gives that repo's branch, and a linked HEAD
  gives the time of its target.
- It reads no HEAD file and runs no git below the review folders, because a PR session can write a
  git config there. That check also compares real paths, so a link into a review folder is
  caught too.
- A relative folder, or one that no longer exists, has no branch.
- git runs with the login environment of the claude runs, so it's the git on the login `PATH`.

Some Electron behaviour wasn't carried over because it belonged to the web stack rather than to
the app: the 250 ms gap between two updates (a limit of the IPC to the renderer), the order of
promise jobs, the insertion order of a JavaScript `Map`, the V8 error texts of a JSON parse, the
store's change flag (the service compares the store with the last saved one instead) and the
store's parallel maps and sets (the registry keeps one record for each row).

## Tests

The tests of the rules are in `Tests/BifrostSessionsTests/Model`, and the tests of the service,
the branch reader and the files are in `Tests/BifrostSessionsTests/Services`. The edge cases are
small tables of inputs and results (Swift Testing arguments).

- `RuleEdgeTests`: local names, short IDs, worktree paths, paths, poll intervals, model names,
  HEAD files, `.git` files and the terminal app of a process.
- `AgentsParserTests`: the parser of `claude agents --json`, with the status and kind rules.
- `StoreLoadEdgeTests`: the load and the save of the store file, one field at a time.
- `StoreRecordTests`: the record of each row, the order of the watchlist, and a real-shaped
  `registry.json` that loads to its values and saves to the same bytes.
- `StateMachineTests`: the state machine as tables of steps (a start state, an input and the
  result), the parked state, the time limits and the escalation.
- `RegistryEdgeTests`: rows that share a current ID, empty short IDs and commands with edge
  values.
- `RegistryMatchingTests`, `RegistryParkingTests`, `RegistryForgetTests`, `RegistryUsageTests`
  and `RegistryWatchlistTests`: matching entries to rows, parking, forgetting, the live lines and
  rate limits, and the watchlist.
- `BranchReaderEdgeTests` (in `Services`): the branch reader on small file trees.
- `ServiceTests` (in `Services`): the service on a manual clock with fake dependencies, covering
  the loops, the window, the saves, the stop, the waits for a row, the events and the rate limits.
