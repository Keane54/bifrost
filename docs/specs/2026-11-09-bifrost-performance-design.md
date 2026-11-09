# Bifrost Performance: design

Status: Built, 2026-11-09. The user approved the mockup (version 4) and asked to start on 2026-11-09.

The Performance panel answers one question at a glance: does Bifrost use too many resources, or is something wrong with Bifrost's health? A headline gives the answer. Details below the headline show Bifrost's processes, the Claude sessions, the Mac, the network, and the limits and disk.

## 1. Intent

On 2026-11-09 the user's Mac slowed down, and he thought that Bifrost had a memory leak. The cause was not clear without Activity Monitor and shell commands. Bifrost was not running. Six Claude sessions used 270 to 850 MB each, and swap was at 4.6 of 6 GB. The Performance panel gives that answer inside Bifrost, in a few seconds.

## 2. Goals

- Give one health state for Bifrost: OK, Warning or Problem, with one line for each reason.
- Find two kinds of trouble. One: Bifrost uses too many resources. Two: Bifrost's health is abnormal, for example a leak, a crash or a poll that keeps failing.
- Show whether the cause is Bifrost, the Claude sessions, or something else on the Mac.
- Cost almost nothing to run.

## 3. Non-goals

- No replacement for Activity Monitor. The panel shows no list of other apps.
- No history beyond 60 minutes. No charts other than the 10-minute trend line.
- No macOS notification for a state change (the user's call, unless he asks later).
- No automatic action. Bifrost never stops a session or a process by itself.
- No settings for the limits in the first version.

## 4. Anti-goals

- The monitor itself makes Bifrost heavy or slow.
- The headline says OK when it cannot know. The OK text states only measured facts (user decision, 2026-11-09).
- A Stop button that can stop a session that Bifrost does not own.

## 5. The panel

The approved mockup is version 4: `.superpowers/brainstorm/74668-1794218564/content/performance-panel-v4.html` in the main checkout. It is the reference for the layout.

### 5.1 The headline

| State | Colour | Text |
|---|---|---|
| OK | green | "Bifrost is using 712 MB RAM and 2% CPU." (the user's text, with the real values.) Nothing more. |
| Warning | amber | "Warning", then one item for each warning reason. |
| Problem | red | "Problem", then one item for each reason. Problem reasons come first, then warning reasons. |

- Each reason is its own list item, with a 6 px gap between items (user decision, 2026-11-09).
- Each item starts with a small square in its own colour. The square is amber for a warning and red for a problem.
- A reason is one short sentence with the facts. Example: "Bifrost's memory grew by 600 MB in the last hour."
- The headline never shows OK without data. When no sample exists and no check gives a reason, the headline shows "Checking Bifrost…". This text has the dim colour, with no state word and no square. The headline also shows this text when the newest sample is older than 60 s, for example while `ps` fails.
- The first tick after the start adds no sample. The first read of the Electron metrics gives 0% CPU for each process. Also, the window process does not exist yet.

### 5.2 The details

- One "Details" row with an arrow sits under the headline in every state (user decision, 2026-11-09). A click opens or closes all the sections below it.
- Closed is the default. Bifrost remembers the last choice (my call).
- The Details row has a bottom border only while it is open. A closed row ends flush with the panel edge, with no double line (user decision, 2026-11-09).

The sections, in this order:

| Section | Content |
|---|---|
| Bifrost | The total RAM and CPU in the section title. A trend line of RAM and CPU for the last 10 minutes. The memory line is amber. The CPU line is blue. The line goes from the oldest sample of the 10 minutes at the left edge to the newest sample at the right edge. Before Bifrost has run for 10 minutes, the key under the line gives "Last N min" (the minutes up to the next whole minute). After that, it gives "Last 10 minutes". One row for each process group: Main process, Window, GPU, Chat terminals (with the count), and Other helpers if any. Each row shows RAM and CPU. Two more rows: Frame rate and Main process delay. |
| Claude sessions | The total RAM and CPU of all `claude` processes in the section title. The three heaviest sessions by RAM, each with RAM, CPU and a Stop button. Then one "N more" row with their total. |
| Your Mac | Memory pressure (a bar and a word: Normal, Medium, High), swap used of total, CPU load, thermal state, battery level and charging state. |
| Network | Online or offline and the interface type (Wi-Fi, Ethernet, VPN) in the title. Download and upload rates. The response times to Anthropic and to GitHub. |
| Limits and disk | GitHub GraphQL points left of the limit, and the reset time. Free disk space. The size of the Reviews clones, when Reviews has clones. |

### 5.3 The side bar

- A Performance button in the side bar opens the panel. Its icon is a heart pulse, because Service status already uses the activity line.
- While the state is Warning or Problem, the button shows a dot in the state colour.

### 5.4 The Stop button

- Stop shows only for a session that Bifrost owns and that runs. It uses the existing Stop action, with its checks.
- An external session (for example one in Warp) shows no Stop button. Bifrost never stops it.

## 6. The checks

Bifrost runs the checks every 15 seconds, also while the panel is closed, so the side bar dot is correct. The limits are my calls and are constants in the first version.

| Check | Warning | Problem |
|---|---|---|
| Bifrost RAM (all Bifrost processes, chat terminals included) | above 1 GB | above 1.5 GB |
| Memory growth (a leak), on Bifrost RAM without the chat terminals | the trend over the last 60 minutes rises faster than 300 MB per hour | the trend rises faster than 800 MB per hour |
| Bifrost CPU without the chat terminals, the average over 2 minutes | above 50% of one core | above 100% of one core |
| Frame rate while the panel shows and the window has focus | below 30 fps for 10 s: the last two burst values of this showing are both below 30 fps | not used |
| Main process delay (event loop) | above 200 ms (the longest delay in 60 s) | above 1 s |
| Window or GPU crash in the last 60 minutes | not used | each one, with its time |
| A background poll that keeps failing (the session list, GitHub for Reviews, account usage, Service status) | 3 failures in a row | 10 failures in a row |
| The Live details socket cannot start | each time | not used |
| Terminal processes with no chat window | 1 or more for more than 60 s | not used |
| A failed save of a Bifrost file (settings, layouts, registry, Reviews state) in the last 60 minutes | each one | not used |

Rules:

- A check with no data gives no reason. It never gives OK by itself.
- A reason clears when its condition ends. A crash reason clears 60 minutes after the crash.
- The Mac section, the network and the Claude sessions do not change Bifrost's state. They help you find the cause.
- While the Mac is offline (`net.isOnline()` is false), a failed poll of a network part counts as no data. The network parts are GitHub, account usage and Service status. So the failures in a row do not grow while offline. The reconnect then shows no failure from the offline time. The session list always counts. The health model also gives no reason for a network poll while offline.

Definitions (my calls after the builder check, 2026-11-09):

- **Bifrost RAM** is the sum of all Electron processes of Bifrost (`app.getAppMetrics()`) and the chat terminals. A chat terminal is the `claude attach` viewer process that the PTY manager starts for a chat window. It is not the session process, so no process counts twice.
- **CPU** is a percentage of one core, as in Activity Monitor. A total can be above 100%.
- **The trend** is the least-squares slope of the samples of the last 60 minutes. The check needs samples for the full 60 minutes, so one step in RAM cannot give a reason. After Bifrost starts, the check gives no reason for 60 minutes. The monitor keeps the newest sample before the 60 minutes. That sample shows that the samples cover the full 60 minutes. The history is in memory only.
- **The main process delay** is the longest delay of the Node event loop in each 60 s window. The histogram of `monitorEventLoopDelay()` uses a 50 ms resolution. Each value of the histogram is the timer interval plus the delay. So Bifrost subtracts the 50 ms, and the value is never below 0. The longest delay shows a repeated freeze that a percentile can hide.
- **A low frame rate** needs two burst values below 30 fps in a row. The bursts start 10 s apart, so the two values cover 10 s or more. A change of showing or of the focus starts a new count.
- **A crash** is a `render-process-gone` event of the main window, or a `child-process-gone` event of the GPU process. Its reason is not `clean-exit`. A reload that you start (the View menu, Cmd+R) is not a crash. A reload of the development server is not a crash.
- **A Claude session** is a registry row with a PID. Its RAM and CPU are the sum of its process and all its child processes. MCP servers and tools are examples of child processes. One `ps` call reads all processes. Processes outside the registry do not count.

## 7. Data sources

| Data | Source | Interval |
|---|---|---|
| Bifrost processes | Electron `app.getAppMetrics()` (type, CPU, memory) | 15 s; 2 s while the panel shows |
| Chat terminals | The PIDs of the PTY manager, in one `ps -axo pid=,ppid=,rss=,time=,comm=` table of all processes. The CPU is the change of the CPU time (`time=`) between two reads (P3). | each `ps` read |
| Claude sessions | The PIDs of the registry rows, in the same `ps` table. Bifrost calculates the sessions on each `ps` read. | each `ps` read: 15 s; at most every 6 s while the panel shows |
| Frame rate | The renderer counts frames in bursts: 2 s of `requestAnimationFrame` in each 10 s, only while the panel shows and the window has the focus. Each burst gives one value: the frames divided by the real time of the burst. No frame callback runs between the bursts. The bursts stop at once when the panel closes or the window loses the focus. The Frame rate row shows the value of the last burst. | one value each 10 s |
| Main process delay | Node `perf_hooks.monitorEventLoopDelay()` with a 50 ms resolution | continuous; the check uses each 60 s window |
| Crashes | `render-process-gone` of the main window, and `child-process-gone` of the GPU process | event |
| End of a page | `did-navigate`, `render-process-gone` and `closed` of the main window. The monitor then works as for a closed panel (15 s, no network command, no probe) until the next page reports. | event |
| Poll failures | Results from the registry service, the Reviews watcher, the account usage poller and the Service status monitor. While offline, a failed poll of a network part counts as no data. | event |
| Live details start errors | The result of each start of the Live details server. A good start, Turn off and Remove clear the reason. | event |
| Failed saves | A counter in each store | event |
| Memory pressure, swap | `sysctl kern.memorystatus_vm_pressure_level` and `sysctl vm.swapusage` | 15 s |
| CPU load | `os.cpus()` time deltas | 15 s; 2 s while the panel shows |
| Thermal state | Electron `powerMonitor.getCurrentThermalState()`, read on each tick | 15 s; 2 s while the panel shows |
| Battery | `pmset -g batt` | 60 s |
| Online | Electron `net.isOnline()` | 15 s |
| Interface and rates | the default route interface from `/sbin/route -n get default`; its type from `/usr/sbin/networksetup -listallhardwareports` (Wi-Fi or Ethernet); a `utun` or `ipsec` interface is a VPN; byte counters from `netstat -ib` | the interface and its type when the panel opens, then at most every 60 s; the byte counters at most every 6 s; only while the panel shows |
| Response times | One HTTPS `HEAD` request to `https://api.anthropic.com` and to `https://api.github.com` with Electron `net.fetch` (it uses the system proxy), with no login and no token. Any HTTP status counts as an answer. The time is until the response headers. After 5 s the row shows "No answer". A DNS or connection error shows "Can't reach". | 60 s while the panel shows |
| GitHub points | The `rateLimit` of the last Reviews poll (the query adds `limit` and `resetAt`). With Reviews off, or when the Reviews value is missing or past its reset time, `gh api rate_limit` (it costs no points), only while the panel shows. Without `gh`, or with `gh` logged out, the row shows "Not available" and the reason. | each poll, or 60 s while the panel shows |
| Free disk | Node `fs.statfs` of the home folder | 60 s |
| Reviews clones | The size of `~/.bifrost/reviews/repos` from `/usr/bin/du -sk` | 10 min, only when the folder exists |

While the panel shows, the `ps` and `netstat` commands run at most every 6 s, not every 2 s. Memory pressure and swap run at most every 15 s. The `route` and `networksetup` commands run when the panel opens, then at most every 60 s. These limits keep the cost of the monitor low (section 8 gives the measured value). The Electron metrics and the snapshot keep the 2 s tick.

The monitor keeps 60 minutes of samples in memory. It writes nothing to disk, except the Details open state with the other UI state.

## 8. Constraints

- The goal: the monitor stays below 1% CPU of one core on average and below 10 MB of memory.
- The measured CPU (2026-11-09). A test copy of Bifrost ran in the smoke harness, with a test home and a fake `claude`. It made no network request. The Mac was busy (load average 8 to 27). Before each measurement, the app ran for 30 s. `/bin/ps -o pid=,time=,comm=` gave the CPU time of each Bifrost process at the start and at the end of 2 minutes. The window had the focus, and the animated background was off. The values are percent of one core. The frame rate counter used bursts, as section 7 describes.

| State | Main process | Window | GPU | Other | Total |
|---|---|---|---|---|---|
| Panel closed | 0.71% | 0.22% | 0.03% | 0.00% | 0.96% |
| Panel open, Details closed | 0.55% | 0.71% | 0.45% | 0.00% | 1.71% |
| Panel open, Details open | 1.12% | 1.01% | 0.98% | 0.00% | 3.11% |

- The values above do not include the short commands of the monitor. One run of `ps` uses about 38 ms of CPU. One run of `networksetup` uses about 23 ms, and one run of `pmset` about 8 ms. One run of `netstat` uses about 6 ms, and one run of `sysctl` or `route` about 3 ms. At the intervals of section 7, the commands add about 0.3% of one core with the panel closed. They add about 0.8% while the panel shows.
- With the panel closed, the monitor is near the goal. All of Bifrost used 0.96% of one core (0.77% in an earlier run), and the commands add about 0.3%.
- While the panel shows and has the focus, the goal is not met. All of Bifrost used 1.71% of one core, and the commands add about 0.8%.
- An earlier counter counted the frames at all times while the panel showed. Its frame loop made the page draw a frame for each display refresh (118 fps in this test). With that counter, the panel open gave 5.45% of one core (window 2.86%, GPU 1.96%). The bursts cut this to 1.71%.
- With the animated background on, the GPU process used about 19% to 22% of one core in each state. The background is not part of the monitor.
- No new library. Use Electron, Node and macOS commands with absolute paths (`/bin/ps`, `/usr/sbin/sysctl`, `/usr/bin/pmset`, `/usr/sbin/netstat`, `/sbin/route`, `/usr/sbin/networksetup`, `/usr/bin/du`). All are read only.
- Build order: Reviews R1 merges into `main` first. This work starts from that `main`, because the GitHub points and a poll counter come from the Reviews watcher.
- The response-time requests send no token, no cookie and no user data.
- All text in the app is plain, friendly English. Specs, plans, comments and commit bodies use ASD-STE100.
- Tests use fakes for every command and API. A test never reads the real system state as a result.
- All rules of the project `CLAUDE.md` apply.

## 9. Left to the builder

- The exact process grouping of `getAppMetrics()` types into the rows.
- The format of the trend line, inside the Bifrost theme.
- How the renderer gets the samples (a pushed snapshot, as Reviews and Service status do).
- The frame rate counts only while the Performance panel shows and the window has the focus.
- The texts of the reasons, inside the rules of section 5.1.

## 10. Related

- [Bifrost design spec](2026-11-04-bifrost-design.md)
- [Reviews design](2026-11-09-bifrost-reviews-design.md): the GitHub points come from its poll.
