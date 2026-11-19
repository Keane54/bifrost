# Health: behaviour

Bifrost watches the things that Claude Code and Bifrost itself depend on. This page covers two of
them. Service status is a small panel that tells you whether Claude, GitHub and Sentry are having
a bad day, so you can tell an outage on their side from a problem on yours. Performance watches
Bifrost itself, and tells you whether it uses too much memory or CPU or has stopped being healthy.
The rules live in `BifrostHealth/Model/`, the services that read the status pages and sample the
Mac in `BifrostHealth/Services/`, and the panels in `BifrostHealth/UI/`.
`docs/ports/health/DELIBERATE-DIFFERENCES.md` lists where they deliberately differ from the
Electron app.

## Service status

The panel has one row for each service, in the order Claude, GitHub and Sentry. A row shows a small
coloured square and the level in words ("Operational", "Minor issue", "Major outage", "Critical
outage" or "Maintenance"), the time the trouble began when the level isn't "Operational", the
name of the service, and an "Open status page" button that opens the page of the service in your
browser. An open incident gets a line of its own under the row, such as "API errors - major
(investigating), for 1 h 02 min". At the bottom, the panel says when the last check happened
("Checked at 09:03.", or "Not checked yet." before the first check).

The times follow the style that every panel uses (see `usage.md`, "Time texts"): the clock on the
day of the problem, and the weekday and the clock when it began on an earlier day ("since Wed
22:15"). A service that gave no answer shows "No data" in italics with no square, and a line under
it says "The status page didn't answer." The squares are green for operational, teal for a minor
issue, blue for a major outage, orange for a critical one and light blue for maintenance. Nothing
in the panel is yellow, red or grey.

### How the level is worked out

Each service has a public status page that runs on Atlassian Statuspage, so all three answer the
same JSON API under `/api/v2/`. Bifrost reads `status.json`, which gives the page's overall
indicator, and `incidents/unresolved.json`, which lists the open incidents. Claude and GitHub also
get `components.json`, because each of them runs parts that Claude Code never uses: for Claude the
components whose names start with "Claude Console", "Claude Cowork" or "Claude for Government", and
for GitHub those that start with "Copilot", "Codespaces", "Pages" or "Packages". An outage in one of
those parts shouldn't make the panel look worse than Claude Code's own experience, so Bifrost drops
those components and those incidents, and takes the level from the components that are left. An
incident that names only ignored components is dropped, and an incident that names no component
stays.

The level is the worse of what the page says and what the open incidents say. An incident weighs
as much as its impact (minor, major or critical), except an incident that Claude's team is
monitoring after a fix, which weighs at most a minor issue. The time shown beside the level is the
start of the oldest incident at that level. When the status answer is missing, isn't JSON or has an
indicator that Bifrost doesn't know, the service is "No data". A bad answer for the components or
the incidents only leaves that part out.

### The checks

One check reads all three pages and serves every panel, so opening the panel twice costs nothing
extra. The first check runs when the app starts, and the next one starts 60 seconds after the
previous one ends. A check never starts while another is still running. Each page of a check has
its own limits: the request waits at most 5 seconds, the answer may be at most 1,000,000 bytes, a
redirect counts as no answer, and so does any HTTP status outside 200 to 299. The request carries
no cookie, no token and nothing about you, and the session keeps nothing (no cache, no cookies, no
stored logins).

A check tells the health log how it went: "failed" when no page answered at all, otherwise "ok". A
stop of the app tells it that the check stopped. A test home (the development app started with
`BIFROST_TEST_HOME`) runs no check at all, and its panel says "Bifrost doesn't check status pages in
a test home."

### The forms of the panel

The panel picks one form for all rows, the fullest one that fits its width, and tries again each
time you resize it, so a wider panel goes back to a fuller form:

1. The full form, with the text "Open status page" on each button.
2. The button shows only its icon. The text is its tooltip and its label for VoiceOver.
3. The row also drops the level text. The square stays, with the level as its tooltip and its
   label.

An incident line wraps instead of widening the panel, so a long incident name never pushes the
panel into a smaller form.

### Where the code is

`StatusPage` turns the answers into a `ServiceStatus` and has no network access, which makes it easy
to test with the sample answers in `Tests/BifrostHealthTests/Fixtures`. `StatusText` holds every
text of the panel. `SessionStatusFetcher` reads one URL with the limits above, and
`ServiceStatusMonitor` runs the checks on the app's clock, so tests drive it with a manual clock and
a fake fetcher. `AppServices` owns the monitor and starts and stops it with the other services.
`ServiceStatusPanels` makes the body of the panel, and the panel is the "Service status" button of
the side bar, right after the Usage HUD.

## Performance

When your Mac slows down, the first question is usually whether Bifrost is to blame. The
Performance monitor answers it inside Bifrost: it keeps an eye on Bifrost's own memory and CPU, on
the chat terminals and on the background work that should be quietly succeeding, and sums it all
up as one level, OK, Warning or Problem, with a short sentence for each reason. It also gathers the
numbers that help you find the real cause when it isn't Bifrost: the Claude sessions, the Mac's
memory pressure and load, the network and the disk. Those extra numbers never change the level.

The monitor samples every 15 seconds, also while the panel is closed, so the dot on the side bar
button stays right. While the panel shows, it samples every 2 seconds instead. It never claims OK
without data: until it has a sample, or when its newest sample is more than 60 seconds old (after
the Mac slept, say), the headline says "Checking Bifrost…" rather than OK. A reason still shows in
that state, because a reason is data too. When things are fine, the OK headline reads "Bifrost is
using 712 MB RAM and 2% CPU.", with the real totals of the app and its chat terminals.

### The checks

A chat terminal is the small `claude attach` process that Bifrost starts behind each chat window
(and briefly behind a send to a session with no chat window open). Each chat window has its own,
so the memory limits leave them out: a few open chats would otherwise look like a leak. One chat
terminal that grows on its own gets its own check instead. CPU is a percentage of one core, as in
Activity Monitor, so a busy Bifrost can go above 100%.

| Check | Warning | Problem |
| --- | --- | --- |
| Bifrost's own memory, without the chat terminals | above 1 GB | above 1.5 GB |
| The memory of one chat terminal | above 500 MB | - |
| Memory growth over the last 60 minutes (a least-squares slope) | above 300 MB an hour | above 800 MB an hour |
| Bifrost's own CPU, the average of the last 2 minutes, with each sample weighted by the time it covers | above 50% | above 100% |
| The frame rate of the Performance panel, in two bursts in a row | below 30 fps | - |
| The longest pass of the main run loop in the last full 60 seconds | above 200 ms | above 1 s |
| A background poll that keeps failing (the session list, GitHub for Reviews, account usage, Service status, the update check) | 3 failures in a row | 10 failures in a row |
| The Live details socket couldn't start | each time | - |
| A terminal process with no chat window | for more than 60 s | - |
| A failed save of one of Bifrost's files in the last 60 minutes | each one | - |

Problems come first in the list, then warnings. A check with nothing to go on stays quiet, and
silence alone never adds up to OK.

The growth check only speaks once the samples cover a whole 60 minutes, so one jump in memory can't
trigger it, and the CPU check waits for its 2 minutes in the same way. The very first tick after a
start adds no sample, because a CPU figure needs two readings. When more than 60 seconds pass
between two readings, usually because the Mac slept, the monitor drops its history and starts
again, so the trend needs a new full hour and the CPU average a new 2 minutes.

While the Mac is offline (as `NWPathMonitor` sees it), a failed poll of a part that needs the
network counts as no data. Its streak doesn't grow, and a streak from before shows no reason until
the Mac is back online. The session list only reads local files, so its failures always count.

A reason always shows a value above its limit. The size of a chat terminal (in MB), the growth,
the CPU and the delay are rounded to whole numbers before they're compared with their limits, so a
terminal of 500.3 MB, which would read "500 MB", gives no reason. Bifrost's own memory is shown in
GB with the one decimal that the check uses, and it gets a second decimal, rounded up, when one
decimal would show the limit itself, as in "1.01 GB".

Some reasons are measurements that clear by themselves when the condition ends: the memory, the
growth, the CPU, the frame rate, the main-thread delay and the orphan terminals. The others come
from past events (the poll streaks, the failed saves and a failed start of Live details), and Clear
removes them and sets each streak back to zero. A failed save also drops off by itself
after an hour, and a good start of Live details, or turning it off, removes its reason. Clear
never removes a measurement: if it's still true, it shows again straight away, because Clear builds
a new snapshot at once instead of waiting for the next tick.

### Where the numbers come from

Every value comes from a system call; the monitor never starts a command-line tool for a number
the system can give it directly.

| Value | Source | When |
| --- | --- | --- |
| Bifrost's memory and CPU | `proc_pid_rusage` of the app: the physical footprint, as Activity Monitor shows it, and the CPU time | each tick |
| The chat terminals and the Claude sessions | One read of the process table through libproc, with the pids of the PTY manager for the chat terminals and the pids of the session rows plus all their child processes for the sessions | each tick |
| The CPU of a process | The change of its CPU time between two readings, over the time between them | each tick |
| The main-thread delay | Two run loop observers on the main thread, the first to run after a wait and the last to run before the next one, so each pass includes the layout, the drawing and the Core Animation commit. The clock stops while the Mac sleeps, and the monitor keeps the longest pass in each 60-second window | all the time while the monitor runs |
| The frame rate | The display link of the panel, counted for 2 seconds in every 10, only while the panel shows and its window has the focus | one value every 10 s |
| Memory pressure and swap | `sysctl` | each tick while the panel shows |
| The Mac's CPU load | `host_statistics`, the change of the CPU ticks between two readings | each tick while the panel shows |
| Thermal state | `ProcessInfo` | each tick while the panel shows |
| Battery | The power sources of IOKit | at most every 60 s while the panel shows |
| Online and the kind of link | `NWPathMonitor`, which tells Bifrost about each change. A `utun` or `ipsec` interface counts as a VPN | each change |
| Download and upload rates | The byte counters of the interface from `getifaddrs` | each tick while the panel shows |
| Response times | One HEAD request each to `https://api.anthropic.com` and `https://api.github.com`, with no token, no cookie and a 5-second limit. Any HTTP status counts as an answer, a timeout is "no answer" and a DNS or connection error is "can't reach" | at most every 60 s while the panel shows |
| GitHub points | `gh api rate_limit`, which costs no points, through the same `gh` set-up as the Daily update | at most every 60 s while the panel shows |
| Free disk | The available capacity of the volume that holds your home folder | at most every 60 s while the panel shows |
| The Reviews clones | A walk of the clones folder that adds up the size of each file | at most every 10 minutes while the panel shows |

A test home has no network reads at all: no response times, no GitHub points, and no network
section in the panel.

A Claude session's numbers cover its own process and everything it started, such as MCP servers
and tools. Bifrost's own processes never count towards a session, and when one session runs inside
another, each process counts once, for the inner session.

### The health log

The past events also go to `health.log` in Bifrost's logs folder (`~/Library/Logs/Bifrost` for
the release app), so you can look back after a Clear. Each line starts with the time in ISO form,
in UTC with milliseconds, and reads like one of these:

- `poll failed: sessions (3 in a row)`
- `save failed: the settings`
- `live details did not start: <the error>`
- `cleared by the user`

Clear doesn't touch the file. When it reaches 1 MB, it becomes `health.old.log` and a new file
starts, and a write error never gets in Bifrost's way. A test home writes its log inside the test
home.

### The panel

The Performance panel opens from the last of the panel buttons on the side bar, the heart with a
pulse line. While Bifrost's health is Warning or Problem, that button carries a small dot in the
colour of the level, amber or red, and its tooltip says "Performance - Warning" or "Performance -
Problem", so you notice trouble without keeping the panel open.

The headline gives the answer at a glance. When all is well it shows a green square and "OK",
followed by the OK sentence with the real totals. On a Warning or a Problem it shows the word in
amber or red, then one item for each reason, problems first, each with a small square in the colour
of its own level and 6 points between the items. Before the monitor has any data, the headline just
says "Checking Bifrost…" in the dim colour, with no square and no word. While at least one reason
comes from a past event (a poll streak, a failed save or a failed start of Live details), a Clear
button sits under the reasons.

Below the headline is a Details row with an arrow. It starts closed, and Bifrost remembers your
choice in the `performance` value of `ui-state.json`, as `{"detailsOpen": true}`, the same form the
Electron app wrote. It has a line under it only while it's open, so a closed row ends flush with the
edge of the panel. Opening it shows five sections, in this order:

| Section | What it shows |
| --- | --- |
| Bifrost | The memory and CPU of the app with its chat terminals in the title, the trend line of the last 10 minutes (memory in amber, CPU in blue), a row for the app and one for the chat terminals with their count, then the frame rate and the main process delay |
| Claude sessions | The total in the title, the three sessions that use the most memory, each with its memory, its CPU and a Stop button, then one "N more" row for the rest |
| Your Mac | The memory pressure as a bar and a word (Normal, Medium or High), the swap used of its total, the CPU load of the whole Mac, the thermal state, and the battery level with "charging", "plugged in" or "on battery" |
| Network | Online or Offline, with the kind of link (Wi-Fi, Ethernet or VPN), in the title, the download and upload rates, and the response times of Anthropic and GitHub ("No answer" after 5 seconds, "Can't reach" for a DNS or connection error) |
| Limits and disk | The GitHub GraphQL points left with their reset time, or "Not available" and the reason, the free disk in GB as Finder counts them, and the size of the Reviews clones when there are any |

The trend line runs from the oldest sample of the last 10 minutes at the left edge to the newest at
the right, so a short trend still fills the width. Its key reads "Last 3 min" (the minutes rounded
up) until the samples cover ten minutes, and "Last 10 minutes" from then on. A value the monitor
hasn't measured shows as "-". The Mac, the network and the disk are only read while the panel
shows, so the first open fills them in over a few seconds. A test home has no Network section.

Stop shows only for a session that Bifrost owns and that's running: an external session, such as
one in Warp, never gets one, and a parked session has nothing to stop. Stop is the same Stop action
as everywhere else, with its checks: an idle session stops at once, a session where Claude is
working asks you to confirm first, and a click on a session that's busy with another action does
nothing.

The panel counts as showing while it's the active tab of a frame that isn't minimised, in a window
that's on screen. Then the monitor samples every 2 seconds, and while the window also has the focus
the frame counter runs its bursts. Closing the panel, picking another tab of its frame, minimising
the frame or hiding the window puts the monitor back on its 15-second tick and stops the counter. A
quit ends the monitor, its run loop observers and the frame counter.

### Where the events come from

Each background part of Bifrost tells the health log how it went, and the monitor reads that one
stream:

- The session list: each poll of `claude agents --json`, ok or failed.
- Account usage: the result of each poll. Turning Account usage off (or quitting) ends its streak.
- Service status: each check of the status pages.
- Updates: the end of each update cycle of Sparkle, so only the release app reports it. A cycle
  that finds no update, or an install you cancel or put off, counts as a good check. Turning off
  "Check for updates automatically" ends its streak.
- Live details: each start of its listener. Turn off and Remove clear an old failure.
- The files: a failed save of your settings, the panel layout, the window position, the usage
  alerts and the Daily update state. The session list retries a failed save every second, so it
  reports the first failure of each run of failures.

### Where the code is

The rules have no I/O: `SampleHistory` keeps the samples and works out the trend and the CPU
average, `HealthChecks` turns them and the past events into reasons, `PastEvents` and
`PollStreaks` hold the events and the streaks, and `HealthText` holds every text. They live in
`BifrostHealth/Model/Performance/`. The readers live next to the monitor in
`BifrostHealth/Services/Performance/`: `ProcessTable`, `AppUsage`, `MacState`, `NetworkState`,
`DiskState`, `GitHubLimit`, `MainThreadWatch` and `HealthLog`. `PerformanceMonitor` runs the ticks
on the app's clock and reads the health events for the life of the app, so tests drive it with a
manual clock and fake readers. The panel lives in `BifrostHealth/UI/Performance/`:
`PerformancePanel` draws it, `TrendLine` the trend, `PerformancePanels` holds its model and tells
the monitor when the panel shows, and `FrameRateCounter` runs the display link bursts. The shell
makes the monitor and its readers in `BifrostApp/UI/PerformanceParts.swift`, where a test home gets
no network reader and no GitHub points, and gives the Stop button the Stop action of the window.
