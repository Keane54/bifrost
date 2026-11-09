# Bifrost Performance: design

Status: draft after the builder check, 2026-11-09. The user approved the mockup (version 4) and asked to start on 2026-11-09.

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

### 5.2 The details

- One "Details" row with an arrow sits under the headline in every state (user decision, 2026-11-09). A click opens or closes all the sections below it.
- Closed is the default. Bifrost remembers the last choice (my call).
- The Details row has a bottom border only while it is open. A closed row ends flush with the panel edge, with no double line (user decision, 2026-11-09).

The sections, in this order:

| Section | Content |
|---|---|
| Bifrost | The total RAM and CPU in the section title. A trend line of RAM and CPU for the last 10 minutes. One row for each process group: Main process, Window, GPU, Chat terminals (with the count), and Other helpers if any. Each row shows RAM and CPU. Two more rows: Frame rate and Main process delay. |
| Claude sessions | The total RAM and CPU of all `claude` processes in the section title. The three heaviest sessions by RAM, each with RAM, CPU and a Stop button. Then one "N more" row with their total. |
| Your Mac | Memory pressure (a bar and a word: Normal, Medium, High), swap used of total, CPU load, thermal state, battery level and charging state. |
| Network | Online or offline and the interface type (Wi-Fi, Ethernet, VPN) in the title. Download and upload rates. The response times to Anthropic and to GitHub. |
| Limits and disk | GitHub GraphQL points left of the limit, and the reset time. Free disk space. The size of the Reviews clones, when Reviews has clones. |

### 5.3 The side bar

- A Performance button in the side bar opens the panel.
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
| Frame rate while the panel shows and the window has focus | below 30 fps for 10 s | not used |
| Main process delay (event loop) | above 200 ms (99th percentile over 60 s) | above 1 s |
| Window or GPU crash in the last 60 minutes | not used | each one, with its time |
| A background poll that keeps failing (the session list, GitHub for Reviews, account usage, Service status) | 3 failures in a row | 10 failures in a row |
| The Live details socket cannot start | each time | not used |
| Terminal processes with no chat window | 1 or more for more than 60 s | not used |
| A failed save of a Bifrost file (settings, layouts, registry, Reviews state) in the last 60 minutes | each one | not used |

Rules:

- A check with no data gives no reason. It never gives OK by itself.
- A reason clears when its condition ends. A crash reason clears 60 minutes after the crash.
- The Mac section, the network and the Claude sessions do not change Bifrost's state. They help you find the cause.
- While the Mac is offline (`net.isOnline()` is false), failed network polls do not count. These are GitHub, account usage and Service status. The session list always counts.

Definitions (my calls after the builder check, 2026-11-09):

- **Bifrost RAM** is the sum of all Electron processes of Bifrost (`app.getAppMetrics()`) and the chat terminals. A chat terminal is the `claude attach` viewer process that the PTY manager starts for a chat window. It is not the session process, so no process counts twice.
- **CPU** is a percentage of one core, as in Activity Monitor. A total can be above 100%.
- **The trend** is the least-squares slope of the samples. The check needs at least 30 minutes of samples. After Bifrost starts, the check gives no reason for 30 minutes. The history is in memory only.
- **A crash** is a `render-process-gone` event of the main window, or a `child-process-gone` event of the GPU process. Its reason is not `clean-exit`. A reload that you start (the View menu, Cmd+R) is not a crash. A reload of the development server is not a crash.
- **A Claude session** is a registry row with a PID. Its RAM and CPU are the sum of its process and all its child processes, for example MCP servers and tools. One `ps` call reads all processes. Processes outside the registry do not count.

## 7. Data sources

| Data | Source | Interval |
|---|---|---|
| Bifrost processes | Electron `app.getAppMetrics()` (type, CPU, memory) | 15 s; 2 s while the panel shows |
| Chat terminals | The PIDs of the PTY manager, with `ps -o rss=,%cpu= -p <pids>` | same |
| Claude sessions | The PIDs of the registry rows, with one `ps` call | 15 s |
| Frame rate | The renderer counts frames while the panel shows | 1 s |
| Main process delay | Node `perf_hooks.monitorEventLoopDelay()` | continuous |
| Crashes and reloads | `render-process-gone` and page loads of the main window | event |
| Poll failures | Counters in the registry service, the Reviews watcher, the Live details link and the Service status monitor | event |
| Failed saves | A counter in each store | event |
| Memory pressure, swap | `sysctl kern.memorystatus_vm_pressure_level` and `sysctl vm.swapusage` | 15 s |
| CPU load | `os.cpus()` time deltas | 15 s |
| Thermal state | Electron `powerMonitor.getCurrentThermalState()` and its change event | event |
| Battery | `pmset -g batt` | 60 s |
| Online | Electron `net.isOnline()` | 15 s |
| Interface and rates | the default route interface from `/sbin/route -n get default`; its type from `/usr/sbin/networksetup -listallhardwareports` (Wi-Fi or Ethernet); a `utun` or `ipsec` interface is a VPN; byte counters from `netstat -ib` | 2 s while the panel shows, else not read |
| Response times | One HTTPS `HEAD` request to `https://api.anthropic.com` and to `https://api.github.com` with Electron `net.fetch` (it uses the system proxy), with no login and no token. Any HTTP status counts as an answer. The time is until the response headers. After 5 s the row shows "No answer". A DNS or connection error shows "Can't reach". | 60 s while the panel shows |
| GitHub points | The `rateLimit` of the last Reviews poll (the query adds `limit` and `resetAt`). With Reviews off, `gh api rate_limit` (it costs no points), only while the panel shows. Without `gh`, or with `gh` logged out, the row shows "Not available" and the reason. | each poll, or 60 s while the panel shows |
| Free disk | Node `fs.statfs` of the home folder | 60 s |
| Reviews clones | The size of `~/.bifrost/reviews/repos` | 10 min, only when the folder exists |

The monitor keeps 60 minutes of samples in memory. It writes nothing to disk, except the Details open state with the other UI state.

## 8. Constraints

- The monitor must stay below 1% CPU of one core on average and below 10 MB of memory.
- No new library. Use Electron, Node and macOS commands with absolute paths (`/bin/ps`, `/usr/sbin/sysctl`, `/usr/bin/pmset`, `/usr/sbin/netstat`, `/sbin/route`, `/usr/sbin/networksetup`). All are read only.
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
