# Live details: behaviour

The Live details mod runs inside Claude Code and tells Bifrost what each session is doing as it
happens: a prompt starting, a tool finishing, a turn ending, the latest usage. For every event it
sends one JSON line to a Unix socket as `POST /v1/event`, and the Live details server passes each
good line to the registry, either as a state event or as a usage line.

The mod and the Bifrost skills reach Claude Code as plugins, and Bifrost installs, turns on, turns
off and removes them with the `claude plugin` commands. This page covers the server, the version
check that Live details needs, those plugin commands, the Live details control that drives them,
and the lock that keeps the changes to one at a time.

The server listens on the shared socket `~/.bifrost/live.sock`, which Bifrost Dev owns, and only
while the plugin is on. With a test home, every shared path moves inside the test home, so the
socket is `<test home>/.bifrost/live.sock`.

The code is in `BifrostLive/Model` (`LiveLine.swift`, `HTTPRequestParser.swift`,
`PluginText.swift`, `LiveNotice.swift`), `BifrostLive/Services` (`LiveServer.swift`,
`LiveControl.swift`, `LiveLog.swift`, `ClaudeVersion.swift`, `PluginCLI.swift`, `SerialLock.swift`,
`LiveRetry.swift`) and `BifrostFoundation/Services` (`UnixSocketListener.swift`,
`SocketProbe.swift`). The Settings section, the model behind it and the Setup dialog are in
`BifrostSettings/UI` (`LiveSection.swift`, `LiveModel.swift`, `SetupDialog.swift`). Where the
native app deliberately differs from the Electron app, `docs/ports/live/DELIBERATE-DIFFERENCES.md`
explains how and why.

Further down, "Settings > Live details" covers what you see and press in Settings, "The warning
dot" covers the small square on the Settings button when something needs attention, and "The
Setup dialog" covers the steps at the first start. The last sections cover the clean-up that
comes with Live details: taking the old hook install out of Claude Code's settings file, and
removing the files the old hooks left in `~/.bifrost`.

## The lines of the mod

Each line is a fact from the mod, and the server turns it into the event that the registry
understands. A line that breaks the contract is dropped as a whole, while a bad field of a usage
line only loses that field.

- A line is a JSON object with `v` = 1, `kind`, `sid` (a UUID), `at` (milliseconds) and `seq`. A
  line with another `v`, a `sid` that isn't a UUID, or an `at` that isn't a number is dropped. A
  `seq` that isn't a whole number of 0 or more is left out, and the line stays.
- A byte of the body that isn't UTF-8 becomes U+FFFD, and the line stays.
- `kind` maps to an event as below. An unknown kind, an unknown `reason` of `turn.complete`, or a
  missing required text drops the line.

| `kind` | Other fields | Event |
| --- | --- | --- |
| `session.start` | none | SessionStart |
| `session.end` | `reason` (required) | SessionEnd |
| `turn.start` | none | UserPromptSubmit |
| `prompt` | `person` (required, `true` or `false`) | a prompt line (see "Who sent a prompt" below) |
| `ask` | none | PreToolUse of AskUserQuestion |
| `tool.done` | `tool` (required) | PostToolUse |
| `permission` | `tool` (required) | PermissionRequest |
| `turn.complete` | `reason` `answer` or `refusal`, and `answer` | Stop |
| `turn.complete` | `reason` `aborted`, and `answer` | TurnAborted |
| `turn.complete` | `reason` `error` | StopFailure |
| `stop.failure` | none that Bifrost reads | StopFailure |
| `usage` | see below | a usage line |

The rest of the line rules:

- A `usage` line holds the model, the context (`tokens`, `window`, `percent`), `costUsd`, the rate
  limits (`five_hour` and `seven_day`, each with `percentUsed` and `resetsAt`), the version, the
  effort, the permission mode and the transcript path. A bad field is left out, and the line
  stays. An empty text counts as no text, `costUsd` and `tokens` must be 0 or more, `window` must
  be above 0, and `percent` must be between 0 and 100.
- A rate limit window with a reset time that doesn't parse, or a percent outside 0 to 100, is
  left out. A later good window of the same kind replaces an earlier one, and with no good window
  there are no rate limits at all.
- A reset time is ISO 8601, as `Date.ISO8601FormatStyle` reads it (V2), and it rounds to the
  nearest millisecond.
- Every text (the tool, the reason, the answer, the model, the version, the effort and the
  permission mode) goes through one clean, `cleanText`, which drops the characters that could
  change how the app shows it: the C0 and C1 controls, DEL, the line and paragraph separators
  (U+2028, U+2029), the bidi controls and marks (U+200E, U+200F, U+061C, U+202A to U+202E,
  U+2066 to U+2069), and the default-ignorable characters that show nothing (the soft hyphen,
  the combining grapheme joiner U+034F, the Khmer vowels U+17B4 and U+17B5, U+180E, U+200B,
  U+2060 to U+206F, U+FEFF, U+FFF9 to U+FFFB, the shorthand and musical format controls
  U+1BCA0 to U+1BCA3 and U+1D173 to U+1D17A, the tag characters and the Hangul fillers). The
  answer keeps its tabs and line breaks. The joiners
  (U+200C, U+200D) and the variation selectors (U+FE00 to U+FE0F), which emoji and some scripts
  need, stay. The names and the `waitingFor` texts of the session list go through the same
  clean.
- The answer is then cut at 4,000 Characters, and the short texts at 200 Characters, so a cut
  never splits an emoji. A short text that the clean leaves empty counts as no text.
- The transcript path must start with the byte `/`, have at most 1,024 UTF-16 units (the mod's
  limit), and hold none of the characters above, because a bidi control can make one path look
  like another. A path is never cut or cleaned, because that names a different file. For the same
  reason, a `cwd` in the session list that holds one of them counts as no folder.
- Nothing uses the transcript path yet. Whatever uses it later has to resolve its links first and
  accept only a regular `.jsonl` file of this user below `<shared home>/.claude/projects/`, and
  it must never hand the path to a shell, because the path comes from another program.
- The time of a line is its own `at`, but never later than the time of receipt: a line with a time
  in the future gets the time of receipt (L4), so it can't hide the real events that come after
  it. When `at` is more than 10 s before the time of receipt, the time of receipt is used too. A
  time with a fraction gives the whole millisecond towards zero.
- A lone surrogate in a JSON text becomes U+FFFD, and the line stays (L1). This step can go once
  the mod of phase 4d cuts its texts on Character boundaries.

## Who sent a prompt

Claude Code doesn't only start a turn when you type. A background task that finishes, a message
from another session or agent, a schedule or a channel can each hand a session a prompt, and
Bifrost has to tell those apart from yours, so that it only notifies you about the turns you're
waiting on ("A finished turn" in `docs/behaviour/alerts.md`).

The mod makes that call inside Claude Code and sends a `prompt` line for every prompt the session
receives, with one flag, `person`. No text of the prompt leaves Claude Code. Instead of looking at
the words, the mod reads the prompt's origin, which Claude Code stamps where the prompt was queued
and which no plugin can change:

| Origin | Counts as yours? |
| --- | --- |
| `composer` (Enter at the prompt, also through `claude attach`), `bridge` (a Remote Control client), `sdk` (the host of an SDK session), `slack-ping` (you pinging the session from Slack), `auto-continuation` (Claude Code following up on something you chose in its interface) | Yes |
| `plugin` | Only when the plugin sent it as your own words (`asUser`) |
| `unclassified` | Yes, unless Claude Code hides it from you (`isMeta`), as it does an idle notice or a delivery receipt |
| `task-notification`, `scheduled-trigger`, `peer`, `peer-send-message`, `projects-relay`, `channel`, `coordinator`, `observer`, `observer-activity`, and any origin the mod doesn't know | No |

A prompt with no origin, which an older Claude Code could give, gets no line at all. Bifrost keeps
the newest prompt that counts as yours for each session ID, numbered from one counter for the
whole run, so a `/clear` that moves the row to a new session ID can't hide a prompt or repeat
one. The number only counts while the row is live, so with Live details off every yellow box
notifies as before.

The flag is only as good as the origin, and that has limits:

- A prompt that reaches the session over a channel Claude Code can't vouch for, such as a socket
  of the same user, arrives as `unclassified` and counts as yours. A message from a teammate in an
  agent team arrives unstamped too, so it counts as yours unless Claude Code hides it.
- An origin that a later Claude Code adds counts as not yours until the mod learns it. A new way
  for you to send a prompt would stay quiet until then.
- A message from a channel that an MCP server relays (`channel`) never counts, even when you wrote
  it, because anyone in the channel can write there.
- A program that drives a session through the SDK counts as you, so its turns still notify.
- The mod sends the line as the prompt is submitted, before the plugins after it have their say,
  so a prompt that another plugin then drops still counts.
- A running session picks up a new copy of the mod only after `/reload-plugins` or a restart (see
  "The Live details control" below). Until then it sends no prompt lines and keeps the old rule.

## The HTTP rules

The parser only takes the one request that the mod sends, `POST /v1/event HTTP/1.1` with a
`Content-Length` and a JSON body, and refuses every other form. Keeping it that narrow keeps the
parser small and its memory bounded.

- One request for each connection, and every answer has `Connection: close`.
- The head (the request line, the header lines and the empty line) has at most 16,384 bytes, and
  the body limit is 65,536 bytes.
- Every line ends with CR LF, and a bare LF or CR is bad at once.
- The request line is `METHOD target HTTP/1.1`, with one space between the parts. A header line
  is a name, `:` and a value. The name is printable ASCII with no space, and it compares without
  case.
- `Content-Length` is ASCII digits, with only spaces or tabs around them. Two `Content-Length`
  lines are bad, and with no `Content-Length` the body is empty.
- A `Transfer-Encoding` line is bad, because the mod sends no chunks.
- The checks at the end of the head run in this order: the framing (bad), the `Host` line (400),
  the method and the target (404), then the size (413). These answers come before the body. A
  good request gets 204 with no body.
- A bad request closes the connection without an answer, and so does a client that ends its side
  before the request is complete. A request that isn't complete after 5 s closes without an
  answer too.
- With 64 connections open, a new connection is closed at once.

## Starting and stopping

The server can start and stop at any moment, including while a start is still preparing its
socket. These rules make sure that two starts never fight over the path, and that Bifrost never
removes a socket that belongs to another program.

- A start while the server listens answers at once. A start while another start runs waits for
  it, so two starts give one prepare and one listen.
- A stop cancels the start that runs, and that start then says "not listening". A start that a
  stop cancelled before it ran does nothing: no folder, no probe and no listen.
- The server holds the listener from the start of its listen, so a stop during the listen closes
  the listener at once. That listen ends when the listener's cancel is complete, and the listener
  then removes a stale socket at the path (the file of that listen). A socket of another program
  stays.
- A start after a stop waits until the cancelled start has ended, so its probe never finds the
  socket of the old listen.
- The error of a failed start stays until the result of the next start. A stop clears the error.
- A stop only removes the socket file at once when the server listened, so it never removes
  another program's socket after a race for the path. A second stop does nothing.
- The prepare makes the folder, and each missing parent, with mode 0700. It then opens the folder
  without following a link and checks the open folder itself: it has to be a folder of this user,
  and its access list must have no entry that allows anyone in, because such an entry would let
  another user past the mode 0700. When Bifrost can't read the access list, it doesn't listen
  either. Then it sets the mode 0700 on that open folder.
- Next the prepare takes a lock on `live.lock` beside the socket, without waiting. The lock file has
  to be a regular file of this user with one link, so the lock never belongs to another file. Only
  the holder of that lock probes the path, removes a stale socket and listens, so two copies of the
  app (the Dev and the Release app, say) never race for the socket. When another process holds the
  lock, the start fails with `Another program listens on <path>.`. The lock stays held until the
  socket file is gone again at the stop, and the lock file itself stays in the folder.
- The probe then checks the path, and a stale socket file (one that no program listens on) is
  removed. Just before the listener starts, Bifrost checks again that nothing is at the path,
  because the bind of the listener would follow a link put there.
- Once the listener is ready, Bifrost sets the mode 0600 on the socket file without following a
  link, and checks with `lstat` that the path holds a socket of this user with mode 0600. If it
  doesn't, the listen fails and Bifrost closes it. Bifrost also notes the device and the inode of
  that socket file.
- A stop only removes the socket file when the file at the path still has that device and inode,
  so a file that another program put there stays.
- Network gives no descriptor for a connection, so the server can't check who the peer is. The
  folder checks, the folder's mode 0700 and the socket's mode 0600 keep other users out instead. A
  process of the same user can always connect, and a peer check couldn't tell the mod from such a
  process anyway, so there's no peer check and no raw listener (row N11).
- Each connection runs off the main actor, and so does the parse of its request. Only the event
  goes to the main actor, before the answer. The first line of a batch starts a wait of 50 ms, and
  every line that comes in that time reaches the registry with it, in the order of arrival, so a
  flood of lines rebuilds the session list at most once every 50 ms. Each answer comes after its
  batch reached the registry.
- With 64 connections open, the server closes each new connection at once. It counts those and
  writes one log line with the count a minute after the first of them, or at the stop, so a flood
  never floods the log.
- A failure of the listener closes the server, removes the socket file and logs one line,
  `Live details: server error. <text>`. It ends a start that's running, as a stop does, and that
  start gives the error. A new start straight after the failure listens again.

A start that can't listen gives one of these reasons, which the Live details status and the log
show:

| Why | The reason |
| --- | --- |
| The path is over 103 bytes | `The socket path is too long: <path>` |
| The folder is a link, or another user owns it | `Bifrost doesn't listen in <folder>, because it's a link or another user owns it.` |
| The access list of the folder can let someone in, or Bifrost can't read it | `Bifrost doesn't listen in <folder>, because its access list can let other users in.` |
| A file that isn't a socket has the path | `<path> exists and is not a socket. Bifrost did not change it.` |
| Another program listens on the path, holds `live.lock`, or put a socket there just before the listen | `Another program listens on <path>.` |
| `live.lock` isn't a regular file of this user with one link | `<lock path> is not a regular file of this user with one link. Bifrost did not change it.` |
| After the listen, the path holds no socket of this user with mode 0600 | `The socket <path> is not a socket of this user with mode 0600. Bifrost closed it.` |
| The socket didn't answer the probe within 500 ms | `The socket <path> did not answer in 500 ms.` |
| A system call failed | `<action> <path>: <reason>.`, for example `Cannot create the folder <path>: Permission denied.` |

The keep-alive, the `Date` header, `Expect: 100-continue`, chunked bodies, HTTP/1.0, empty lines
before the request line and the other HTTP forms that only Node accepts weren't ported, because
the mod sends one simple request.

## The version check

Live details needs Claude Code 2.1.290 or later (`ClaudeVersionCheck.liveMinimum`), so before it
installs the mod Bifrost asks Claude Code for its version. A feature passes its own minimum to the
check, and Bifrost as a whole needs 2.1.281 or later (`ClaudeVersionCheck.appMinimum`), which is
the version that Settings warns about.

- The check runs `claude --version` with a 5 s limit and takes the first version number in the
  output, which is three groups of ASCII digits joined by dots, such as `2.1.290` in
  `2.1.290 (Claude Code)`.
- It compares the versions part by part as whole numbers, so `2.10.0` is newer than `2.9.9`, and
  a zero at the start of a part changes nothing. The minimums are typed values in the code, so
  there's no minimum that the check can't read.
- A run that doesn't end with code 0, or output with no version number, gives no version, and no
  version is never OK. A part too large for a 64-bit whole number gives no version either.

## The plugin commands

Each plugin lives in a local marketplace that Bifrost adds to Claude Code, and the plugin's ID
names that marketplace:

| Plugin | Plugin ID | Marketplace |
| --- | --- | --- |
| Live details | `bifrost-live@bifrost-local` | `bifrost-local` |
| The skills | `bifrost@bifrost-skills` | `bifrost-skills` |

Two commands read the state, and six change it. Each write command ends with
`--scope user --json`:

| Step | Command |
| --- | --- |
| Read the plugins | `claude plugin list --json` |
| Read the marketplaces | `claude plugin marketplace list --json` |
| Add the marketplace | `claude plugin marketplace add <folder> --scope user --json` |
| Install | `claude plugin install <plugin ID> --scope user --json` |
| Turn on | `claude plugin enable <plugin ID> --scope user --json` |
| Turn off | `claude plugin disable <plugin ID> --scope user --json` |
| Uninstall | `claude plugin uninstall <plugin ID> --scope user --json` |
| Remove the marketplace | `claude plugin marketplace remove <marketplace> --scope user --json` |

Only fixed values go to Claude Code as arguments: the IDs above and the marketplace folder. A value
that starts with `-` never goes to Claude Code, because it would read as an option, and the command
fails with `Bifrost won't pass <value> to Claude Code, because it starts with a dash.` The folder
must be a file URL with no base URL, an absolute path and no line break, or the command fails with
`The plugin folder path must be absolute and have no line break`, and Bifrost passes it with no
`/` at the end.

### Reading the lists

Claude Code can print a note, such as an update notice, before the JSON list, so the list starts at
the first line that begins with `[` and runs to the end of the output. Any item that isn't an
object is skipped.

- The plugin is the first item whose `id` is the plugin ID, and no such item means it isn't
  installed. It's on only when `enabled` is `true`. Its folder is `readFromFolder` when that's
  text, and only the text items of `errors` count.
- The marketplace is the first item whose `name` is the marketplace. Its `source` is the text of
  that field (empty otherwise), and its `path` is the text of that field, if any.
- A run that doesn't end with code 0, or output with no JSON list, fails with
  `Bifrost couldn't read the <plugin|marketplace> list from Claude Code: <reason>`. The reason is
  the trimmed stderr, or `it exited with code <n>` when stderr is empty, or `it gave no list` for
  output with no list.

### Reading the result of a write

A write command prints one JSON result line, and only the last line that isn't empty counts,
because Claude Code can print other lines first.

- `"outcome": "ok"` passes.
- `"failureCode": "already_in_goal_state"` passes too, because enable and disable exit with code 1
  for a plugin that's already on or off.
- Any other line with a `message` that isn't empty fails with that message.
- Otherwise, an exit with code 0 fails with `Claude Code gave no result.`, and any other end
  fails with the trimmed stderr, or with `claude exited with code <n>` when stderr is empty.

### Time limits

Every command has a 30 s limit. A command that the limit stopped fails with
`Claude Code didn't finish in 30 seconds.`, and Bifrost doesn't use its output, because it isn't
complete.

- A read gets SIGKILL at the limit. A cancel, for example when Bifrost stops a start, stops a read
  at once, and the read fails with `Bifrost stopped the Claude Code command.`
- A write gets SIGTERM at the limit, because a SIGKILL could leave its change half done. If it
  still runs 5 s later, the process runner sends SIGKILL.
- Nothing else ends a write, so a cancel or a quit of the app leaves it running. The caller waits
  until claude has ended, even after a cancel, and then gets the write's own result. The lock stays
  held until then, so an old command never changes the settings after the lock is free again.
- If a write's result still hasn't come 10 s after the SIGTERM, Bifrost stops the run and the
  command fails with the same text. A hung command therefore frees the lock after 40 s at most.
  The 40 s limit runs on a `SuspendingClock`, so the time while the Mac sleeps doesn't count.
- Both ends of a write's limit, at 30 s and at 40 s, write an error line to the log, and so does a
  write that ends by itself 30 s or more after its start, even with code 0.
- A quit of the app is the one case with no limit at all: a write that still runs when the app
  quits gets no SIGTERM at 30 s and no SIGKILL at 35 s, because the timers end with the app, and
  Claude Code finishes the command on its own. If the app starts again quickly, its first change
  can run while that old command still runs. Claude Code ends a plugin command within seconds, so
  in practice the old command is done long before anyone clicks.

### The test home

In a test home, each plugin command runs with `HOME` and `CLAUDE_CONFIG_DIR` pointing into the test
home, so it only changes files under it (`PluginCLI.environment(_:testHome:)`). Every other claude
call keeps the app's own env, so the session list stays the real one.

## One change at a time

The Live details and skills actions, and their starts, share one lock (`SerialLock`). Two changes
at the same time could both edit the user's Claude Code settings or pick the same backup name, so
only one change runs at a time.

- A change that comes while another change runs fails at once with
  `Another change is still running. Try again in a moment.`, and its work doesn't run.
- A change that fails frees the lock and keeps its own error.
- A start takes the lock in its turn: after the earlier starts and after the change that holds the
  lock. A change or a status read that comes while a start waits or runs waits until no start is
  left, even when a start fails or the caller is cancelled. Then the change takes the lock with the
  usual rule, so of two changes that waited, the first runs and the second is refused.
- A status read never takes the lock. It runs alongside a change, and a change runs alongside it,
  but it does wait for the starts, so it shows the state after them.
- A start can also run in a task of its own (`SerialLock.first`). It counts as a start from the
  moment of that call, so a status read or a change straight after it waits for it, even in the
  same turn of the main actor.
- The work that holds the lock can read the status, and that read runs at once, also while a start
  waits for the lock. A change or a start from inside that work would wait for itself, so it fails
  at once with the busy text, and a Debug build stops at an assertion. Each hold of the lock gets a
  token of its own, so a task that the work made and that outlives the work isn't inside it any
  more: it takes the lock as a new change.

## The Live details control

`LiveControl` is what the Live details section of Settings talks to. It runs the start rule when
the app starts, the four actions (Install, Turn on, Turn off and Remove) and the status read, and
it owns the server on the shared socket. It shares the one lock with the skills control, so only
one plugin change runs at a time, and every sync or removal of the mod folder happens inside it.

### The start rule

When the app starts, the control runs one start in the lock:

1. It removes the old hook data from `~/.bifrost` (see "The old hook data" below).
2. With `BIFROST_LIVE_LISTEN=1`, which only a development app with a test home honours (for a
   test by hand; the smoke test installs Live details through the test port instead), it listens
   at once and does nothing else.
3. Otherwise it reads the plugin list. With the plugin on, it syncs the mod folder from the app,
   then listens. A failed copy still listens, because the old mod files still send lines.
4. When the plugin list can't be read, the plugin state is unknown, so it listens only when the
   mod's manifest (`~/.bifrost/mod/.claude-plugin/plugin.json`) exists.

A failed read or copy writes a line to the log, and the app goes on. The result of the listen
only goes to the server's own log line for now. A stop at the quit cancels the start: a start
that a stop came before does nothing at all, not even the clean-up, and a start that a stop
cancelled never listens. With no claude, the app makes no Live details control.

### The actions

Every action checks for the quit between two of its steps, and stops with
`Bifrost stopped the Claude Code command.` when it came. A cancel of the caller, for example a
closed section, ends an action the same way, but only before its first plugin write: once a
`claude plugin` write has run, the plugin state has changed, so the action runs to its end and
only the quit stops it. Each refusal comes before the step that would change something.

- **Install** refuses a Claude Code older than 2.1.290, and a marketplace called `bifrost-local`
  at another path, which belongs to another program. Then it removes an old hook install, syncs
  the mod folder, adds the marketplace (unless it's already Bifrost's), installs the plugin,
  turns it on if the install left it off, and listens.
- **Turn on** refuses an old Claude Code and a plugin that isn't installed, then removes an old
  hook install, syncs the mod folder, turns the plugin on and listens.
- **Turn off** stops the server first, because the server is the switch that acts at once, then
  turns the plugin off.
- **Remove** stops the server first, uninstalls the plugin, removes the marketplace only when it's
  Bifrost's (never one with another path), removes the mod folder, and removes the old hook
  install last.
- Turn off and Remove end the live flag of every row straight after the stop, so no line can
  arrive after the change and the status shows 0 live sessions at once.
- Settings that Bifrost can't read stop Install and Turn on before any change. Remove still does
  its plugin steps and fails at the end, so the user sees why the old hooks can stay.

Sessions that run already pick up a change after `/reload-plugins` or a restart
(`LiveTexts.reloadNote`).

| When | The message |
| --- | --- |
| No claude | `claude was not found.` |
| Claude Code is too old | `Live details needs Claude Code 2.1.290 or later. This Mac has <version>.`, or `... claude was not found.` with no version |
| Turn on with no plugin | `Live details is not installed.` |
| Another program's marketplace | `A marketplace with the name bifrost-local already exists at <path or source>. Bifrost did not change it.` |
| Settings that can't be read, before any change | `Bifrost can't read ~/.claude/settings.json, so it didn't change anything. <reason>` |
| Settings that can't be read, at the end of Remove | `Bifrost can't read ~/.claude/settings.json, so it didn't remove the old hooks. <reason>` |
| The removal of the old install, or a copy or removal of the mod folder, failed | the text of that failure |
| Another change runs | `Another change is still running. Try again in a moment.` |

### The status

The status read waits for the start but takes no lock. It reads the plugin list, the mod folder,
the settings and the version at the same time, then the server and the live count:

- `plugin`: `not-installed`, `enabled`, `disabled`, or `unknown` when the list can't be read.
- `modCurrent`: the mod folder has the app's bytes, and the plugin reads that folder (or the list
  names no folder).
- `oldInstall`: the settings still have the old hook install.
- `listening`, `liveSessions` (rows that are live and not parked), `claudeVersion` and
  `versionOk`.
- `error`: the texts of a failed plugin list, a settings file that can't be read and a server that
  doesn't listen, joined with a space. A linked `~/.bifrost` shows its folder check text here.

## Settings > Live details

The Live details section of Settings is where you see whether the plugin is working and where you
install, turn on, turn off or remove it. It reads everything through the control, and the texts
match the Electron app word for word.

At the top is one state line, worked out from the status (`LiveNotice`):

| State | The line |
| --- | --- |
| No status read yet | `Checking Live details...` |
| Not installed | `Not installed.`, with the dim line "Without Live details, Bifrost still lists your sessions and shows their boxes from the session list, a little later, but with no model, context % or cost. You can turn it on later in Settings > Live details." |
| Off | `Off.` |
| On, listening, with the app's files | `On. 1 session is sending live details.` or `On. <n> sessions are sending live details.` |
| The list can't be read | the status error, else `Bifrost couldn't check Live details.` |
| On, but no listener | the status error, else `Live details is on, but Bifrost isn't receiving it. Try Turn off, then Turn on.` |
| On, with other files | `Live details uses files that don't match this Bifrost. Remove it, then install it again.` |

Under the line come the buttons for that state (`LiveRules.actions`): Install when it isn't
installed, Turn on and Remove when it's off, Turn off and Remove when it's on, all three when it's
on with a problem, and Try again when the state can't be read. Try again just reads the status
again. The buttons are greyed out while an action or a read of the section runs.

- **Install** doesn't install straight away. It first shows "Install makes these changes:" and a
  numbered list of the steps: the removal of Bifrost's old hooks (only when the settings still
  have them), the copy of the plugin files to `~/.bifrost/mod`, and the marketplace and plugin
  install. A second Install under the list runs it, and Cancel goes back to the buttons.
- **Remove** asks first, with Bifrost's confirm dialog over the canvas: "Remove Live details",
  "Bifrost turns off Live details, removes the plugin and the folder ~/.bifrost/mod, and removes
  any old Bifrost hooks (with a backup first).", and a Remove button. Cancel changes nothing.
  Without a confirm dialog, which only happens in a test, Remove is greyed out.
- A good Install or Turn on adds the reload note ("Sessions that run now get the change after
  /reload-plugins or a restart."), which stays until the next action.
- A failed action reads the status again, because it may have changed something before it
  failed, and then shows its text in an error line with a close button. The error, and the list of
  Install steps, go away when you close them or when the section goes away.

Two more notes can show under the buttons: "Bifrost found its old hooks in
~/.claude/settings.json. Install or Turn on removes them first and saves a backup." while the
old hook install is there, and "Live details needs Claude Code 2.1.290 or later." when the
installed Claude Code is too old for Live details. Below the top part, the section shows
"Claude Code <version>" (or "Checking Claude Code..." until the check ends) and the general
version notice when there is one: "Claude Code <version> is older than 2.1.281, which Bifrost
needs. Please update Claude Code.", or "Bifrost can't find Claude Code. Check that the claude
command works in a terminal." when the check found no version.

The section reads its status, with the buttons greyed out, once each time you open Settings: the
first time it shows, whether through its tab or as a search result. A search that keeps showing it
doesn't run `claude plugin list` again, and the next open of Settings reads again
(`LiveModel.readOnce`). The app also reads the status, the version and the skills status once as
soon as the controls exist, quietly; a quiet read drops its answer if an action or a section read
started in the meantime, because that one brings a newer status. If you open Settings before the
controls exist, the section's read waits for them and takes the place of that first read.

With no claude there's no control at all, and the section says `claude was not found.` with Try
again, which can't change anything until the app starts again with claude. The version notice
then says that Bifrost can't find Claude Code.

The search finds the section by its title, the word "plugin", the state line, the button labels
and the Claude Code line.

## The warning dot

When something about Live details or Claude Code needs your attention, the gear at the bottom of
the side bar gets a small white square at its top right, and so does the Live details tab in
Settings. The gear's tooltip then says "Settings - something needs your attention", and a screen
reader hears the same text as the button's hint. The dot shows when any of these is true
(`LiveRules.hasWarning`):

- the state line shows a problem (the three problem rows above);
- the old hook install is still in the settings;
- the general version notice shows;
- the plugin is installed, on or off, and Claude Code is too old for Live details. A plugin that
  isn't installed doesn't count, because after Skip, Live details off is your choice.

The first read at the start can fail for a moment, so while the dot shows Bifrost reads the
status again on a back-off (`LiveRetry`), and every read runs `claude plugin list`:

- A new warning starts the steps: reads at 1, 2, 5 and 10 minutes after it, then nothing more.
  No timer runs while there's no warning.
- A read of any kind that ended less than 30 seconds before a step counts as that step.
- When the window becomes the key window, Bifrost reads again if the last read ended 5 minutes or
  more ago.
- Each of these reads also checks the Claude Code version again when the last check wasn't good.
- Nothing reads again while an action of the section runs, and only one of these reads runs at a
  time.

After the last step the dot stays until a focus read, a read of Settings or an action clears it.

## The Setup dialog

The first time Bifrost starts, it asks whether you'd like Live details and the Bifrost skills, and
it shows exactly what each one would change before anything happens. This is the Setup dialog,
titled "Set up Bifrost". It's a box in the same dialog layer as the confirmations (`DialogHost`,
see "The dialogs" in `actions.md`), 440 units wide, and its texts match the Electron app word for
word. The rules are in `BifrostSettings/UI/SetupDialog.swift` and the box is in
`BifrostWindows/UI/Actions/SetupDialogView.swift`.

### When it opens

Once the start has read both the Live details status and the skills status, the dialog opens if
you haven't made a choice yet (`setupDone` is false in the settings) and the Live details plugin
is either not installed or in a state Bifrost can't read (`LiveRules.shouldShowSetup`). An
installed plugin, on or off, already counts as your choice, so Bifrost saves `setupDone` and shows
nothing.

If another dialog is open at that moment, the Setup dialog waits and opens as soon as that one
closes. It opens by itself at most once in each run of the app, and not at all once you've opened
it from Settings. With a test home it never opens by itself unless the environment has
`BIFROST_TEST_SETUP=1` (`SetupDialog.opensAtStart`), so it can't cover the window of a test that
doesn't ask for it.

### What it shows

| View | What it shows | Buttons |
| --- | --- | --- |
| Ask | "Live details lets Bifrost see each session as it happens: ... Bifrost makes these changes only if you turn it on:", the numbered Install steps of Live details, the version notes when they apply, the status problem with Try again when there is one, and the dim "Without Live details, ..." line | Skip, Turn on Live details |
| Skills | "Bifrost skills give Claude tested steps for common jobs: ... Bifrost makes these changes only if you install them:", the two Install steps of the skills, and the dim "You can install the skills later in Settings > Skills. The Hand over button works without them." | Skip, Install skills |
| Done | What you installed in this open of the dialog: "Live details: On. ..." and "Skills: On." (or the problem text of either), then the reload note | Done |
| Installed | Only when you open it again from Settings with the plugin installed: the text about Live details, its state line, such as "Live details: Off.", and the dim "You can change this in Settings > Live details." | Done |

### How it moves on

- Turn on Live details installs the plugin exactly as Install in Settings does, with the same busy
  state and the same reload note in the section, and then saves `setupDone`.
- Skip at the first start saves `setupDone`, so the dialog doesn't come back at the next start.
  If that save fails, the dialog still moves on, and it shows again at the next start. When
  you've opened the dialog again from Settings, Skip moves on and saves nothing.
- After the Live details step, the skills step comes next only while the skills plugin isn't
  installed (`SkillsNotice.nextSetupPhase`). After that, the done view shows if you installed
  anything in this open of the dialog, and otherwise the dialog closes.
- A step that fails shows its reason in the dialog, just above the buttons, and keeps its buttons,
  so you can try again or skip. The Settings section doesn't get that error. The reason stays
  until the next step, Skip, Turn on Live details or Install skills, and Try again keeps it, as in
  the Electron app.
- The buttons of a step are greyed out while a plugin change of that part runs, wherever it
  started. The skills buttons are also greyed out while Live details changes, because only one
  plugin change runs at a time (`LiveModel.isBusy`), and Turn on Live details also waits until
  the first status read has ended.
- Esc and a click on the dimmed canvas do nothing. Only Skip and Done close the dialog.

The last row of Settings > General, Introduction, has a "Show introduction" button. Each press
opens the dialog again, and the open changes no setting by itself. With the plugin installed it
starts at the installed view, so it never offers an install that has already happened.

## Live state is a hint, not an authority

The Live socket takes lines from any process of the same user, so a line can be forged. Bifrost
treats what the lines say as a hint for the display, never as the only reason for an action that
changes something:

- **Resume** and **Resume all** need the session list to agree that a parked row has stopped: no
  pid, and no entry in the last active list. A forged (or early) `session.end` parks a row at
  once, but while the active list still has its entry, Resume refuses it, so Bifrost never starts
  a second copy of a running session. That covers the 2.5 seconds or so after a start, when the
  entry has no pid and no status yet. After a stop the entry also stays in the list for a moment
  with no pid, and Resume refuses it until the entry goes, which is the safe side. The --all list
  runs on its own timer, so it can show a new session with no pid before any active list has it:
  such a row counts as listed until an active list read after it also lacks it. "After" goes by
  the order of the reads, which take turns because only one `claude agents` runs at a time, not
  by the clock, so a clock that steps back can't open a gap. Every parked session is in that
  state for the first seconds after Bifrost starts, until the second active poll (1 to 10
  seconds, by the Poll interval, or 15 seconds or more while the window is hidden). Resume and
  Resume all don't wait for that poll: they read the active list there and then, with "Checking
  sessions..." in the notice line, and decide on what it shows. If the list can't be read, they
  refuse the row with the reason (see "The check of the session list" in
  `docs/behaviour/actions.md`).
- **Delete** treats a row that only a line parked, while the active list still has its entry, as
  a running row: it stops an owned session and checks its tracked changes first, refuses an
  external session that runs in its terminal, and refuses a running row with no short ID. A row
  that only an --all read lists gets the same fresh read of the active list first, so Delete goes
  straight to `claude rm` when the session has stopped, stops it first when it's starting, and
  refuses it with the reason when the list can't be read.
- **The worktree delete** counts every row in the worktree as a sharer, parked or not, so a
  forged line can't make Bifrost remove a worktree that another session uses. `claude rm` keeps
  a worktree with unpushed commits or changes on its own.
- **Take control** needs the session list to agree that the session doesn't work: a session that
  the list shows as busy is refused as working, and one that it shows waiting on a prompt is
  refused as having an open prompt. So a forged `turn.complete`, which gives a yellow box, can
  never make Bifrost send SIGTERM to a Claude Code that works. In the moments after a start, when
  the entry has no pid yet, a line makes no Take control either: there's no process to signal,
  and a parked row isn't one that runs.
- **A send** of the session input is blocked while the session list shows the session waiting
  on a prompt, also when a line cleared the red box.
- **Approve** isn't in the native app yet. When it comes, it has to follow the same rule.

What a forged line can still change is what the rows show:

- A forged `session.end` parks a row. A sample of the session list with a pid that started after
  the park clears it, so for a row with a pid that's the next poll (2 s, or 15 s while the window
  is hidden). An entry with no pid never clears it, so such a row stays parked until a real
  session start.
- A forged `turn.complete` gives a yellow box. The box goes with the next real line of the mod,
  or once the session list has confirmed it and then shows the session busy again, so it can stay
  across polls.
- The time of a forged line (never later than its receipt) becomes the row's last event time, so
  a real event with an earlier time that arrives after it is skipped, and the row shows the
  forged time as its last activity.
- Rate limits only count from a session that the session list knows, and each window only when it
  resets between now and 8 days from now, so another program can't fake the plan's windows. A
  line whose windows all fail keeps the last good ones.
- The lines of session IDs that no row has are bounded: at most 1,000 events wait for a session
  to show, and at most 256 such session IDs keep any line data. The oldest goes first.

## The edit of the Claude Code settings file

Before the mod, Bifrost followed sessions through hooks. That old hook install put a hook entry
for ten events into `~/.claude/settings.json` and swapped the user's status line for a wrapper
script. The mod does that job now, so the only edit Bifrost still makes to Claude Code's settings
is to take the old install back out. Install and Turn on of Live details do it first, and Remove
does it last.

The settings file belongs to the user, so the edit is careful in two ways: it changes nothing but
Bifrost's own entries, and it never leaves the file half written or writes over a change that
Claude Code made in the meantime. `ClaudeSettingsDocument` (in `BifrostSessions/Model/Integration`)
holds the file, `SettingsPlan` next to it decides what goes, and `ClaudeSettingsFile` (in
`BifrostSessions/Services/Integration`) reads and writes it.

What the edit removes:

- Every hook whose `command` is `~/.bifrost/bin/bifrost-hook`, under any event and any matcher.
  An entry that also holds the user's hooks keeps them, in their order. An entry with no hooks
  left goes, an event with no entries left goes, and `hooks` itself goes once the removal has
  emptied it. An event that had no Bifrost hook stays exactly as it was, even an empty list.
- The wrapper, which is a `statusLine` whose `command` is `~/.bifrost/bin/bifrost-statusline`.
  The user's original status line, which the old install saved in
  `~/.bifrost/statusline-original.json`, takes its place. When that file holds `null`, the user
  had no status line, so the key goes.
- A value of an unexpected type, such as a `hooks` that's a string or an entry that's a number,
  stays as it is. A command is compared by its value, so `~\/.bifrost\/bin\/bifrost-hook` with
  escaped slashes still counts as Bifrost's hook.

How the file is read and written:

- A missing file counts as an empty object, so there's nothing to remove and nothing is written.
  A file with no Bifrost entry isn't touched either, and gets no backup.
- The file has to be UTF-8 JSON with an object at the top, or Bifrost refuses and changes nothing.
  A byte order mark at the start is skipped, and the new text has none. Bifrost also refuses
  anything that isn't a regular file (a folder, or a FIFO, which it never waits on), a file over
  4 MB, and more than 64 levels of nesting. A real settings file has a few kilobytes and about
  seven levels.
- Every key keeps its place, every number keeps its exact text (`1.0` stays `1.0`), and every
  string keeps its escapes. A key that appears twice keeps its first place and its last value,
  which is how Claude Code reads it too. The new text has two spaces of indent for each level and
  ends with a newline.
- The write goes through the real path of the file that the read opened, which Bifrost takes from
  the open file itself, so when `settings.json` is a symbolic link, the link stays and its target
  gets the new text. If the system can't give that path, Bifrost refuses rather than write beside
  the link, and when the path is too long for the system the message says
  `Cannot check <path>: File name too long.` The new text first goes to a temporary file with a
  unique name in the same folder, with the old file's permissions and a full sync, and only then
  replaces the file in one rename.
- Before that rename, a backup of the exact old bytes goes to
  `~/.bifrost/backups/settings-<UTC time>.json`, for example `settings-20261104T153000Z.json`,
  with mode 0600. When the name is taken, even by a link, the backup gets `-1`, `-2` and so on,
  and an existing backup is never written over. A new `backups` folder, or a new `~/.bifrost`,
  gets mode 0700.
- Just before the rename, Bifrost reads the file again. If it changed since the first read,
  because Claude Code wrote it for example, the edit stops, removes its temporary file and leaves
  the file as the other program wrote it. The backup stays. Claude Code doesn't lock the file, so
  a very short window between that check and the rename remains.
- Bifrost only reads the saved original when the status line is the wrapper, so a removal of
  hooks alone never depends on it. It reads it the same way as the settings file, so a byte order
  mark at the start is skipped there too. When the status line is the wrapper but the saved
  original is missing or unusable, Bifrost refuses rather than delete the user's status line, and
  names the newest backup so the user can restore it by hand. A folder or a FIFO at the path of
  the saved original stops that edit too, with the "not a regular file" message. The saved
  original itself is never removed.

`ClaudeSettingsFile.oldInstall` only reads. It says whether the file still has a Bifrost entry,
or gives the refusal when the file can't be read.

The refusals:

| When | The message |
| --- | --- |
| The file isn't UTF-8 or isn't JSON | `The file <path> is not valid JSON (or not valid UTF-8). Bifrost did not change it.` |
| The top value isn't an object | `Unexpected type in <path>. Expect a JSON object. Bifrost did not change it.` |
| More than 64 levels | `The file <path> has more than 64 levels of nested values. Bifrost did not change it.` |
| Over 4 MB | `The file <path> is larger than 4 MB. Bifrost did not change it.` |
| Not a regular file | `<path> is not a regular file. Bifrost did not change it.` |
| The file changed during the edit | `The file <path> changed while Bifrost worked. Bifrost did not change it. Try again.` |
| The wrapper with no usable saved original | `Bifrost cannot find your original statusLine setting. Restore it from the newest backup: <backup>.`, where `<backup>` is the path of the newest backup, or `no backup found` |
| A system call failed | `<action> <path>: <reason>.`, for example `Cannot save <path>: Permission denied.` |

`ClaudeSettingsDocumentTests` and `SettingsPlanTests` cover the rules, and
`ClaudeSettingsFileTests` covers the file, including the hostile cases: a link at the path, a
FIFO, a folder, a huge file, a change during the edit, and folders that refuse a write.

## The old hook data

The old hooks and the old app also left files in `~/.bifrost`: the `active` file and the `events`
and `sessions` folders. Nothing else removes them, so the app does it once at start.
`OldHookData` (in `BifrostSessions/Services/Integration`) does the work.

- `active`, `events` and `sessions` always go, and a missing one is fine.
- `bin` holds the scripts that the old hook entries run, so it only goes when no such entry is
  left. When the settings still have one, or Bifrost can't read them to be sure, `bin` stays
  (`ClaudeSettingsFile.keepOldScripts`), because without it anyone who still has the wrapper
  would lose their status line.
- `mod`, `live.sock`, `live.lock`, `statusline-original.json` and `backups` are never touched.
- When `~/.bifrost` is itself a link, the clean-up removes nothing, because a linked dot folder
  stays refused (user decision, 2026-11-17).
- The Live details control runs this clean-up at the start of the app, in the lock, before its
  start rule. A failure never stops the start.
- A link goes as a link, and the folder it points to keeps its files.
- When one item can't be removed, the log says so and the others still go. The next start tries
  again.

`OldHookDataTests` covers these rules.
