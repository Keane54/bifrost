# Deliberate differences

This table lists the places where the native Service status panel and the Performance monitor
work differently from the Electron app's TypeScript code on purpose. That code (`statuspage.ts` and
`monitor.ts` in `src/main/service-status/`, `ServiceStatusPanel.tsx` and `service-view.ts` in
`src/renderer/src/service/`, and `src/main/performance/`) is the reference for what they decide,
not for how they get there. The last column says whether you'd notice the difference in normal
use, and a row marked "for the hands-on test" is one to check by hand in the real app. The rows
`SV1`... are for Service status and the rows `PF1`... for Performance. Five rows are visible, SV1,
PF5, PF6, PF7 and PF8, and all five are for the hands-on test.

For Service status, a few parts look different and give the same result: the monitor is one task
with a timer on the app's clock where `createServiceMonitor` used a recursive `setTimeout`, the
three services are read at the same time with a task group where it used `Promise.all`, and the
answers become values of `ServiceStatus` and `Incident` where the TypeScript passed plain objects.
A service with no answer has no `error` text of its own: it has the level "No data", and the panel
shows the line "The status page didn't answer." for a checked service with that level.

For Performance, the limits, the reason texts, the "Checking Bifrost…" rule, the hour of history,
the gap rule, the offline rule and Clear all match. A few parts look different and give the same
result: the monitor is one task with a timer on the app's clock where the TypeScript chained
`setTimeout` calls, the health events arrive on one stream that the monitor reads for the life of
the app, and the slower reads (the response times, the GitHub points, the disk) run in their own
tasks. The first reading after a gap only restarts the CPU figures, so it adds no sample where the
TypeScript added one. The size of a chat terminal, the growth, the CPU and the delay are rounded to
whole numbers before the comparison, so a reason never shows a value equal to its limit. The
2-minute CPU average weights each sample by the time it covers, where the TypeScript took the plain
mean, so the 2-second ticks of an open panel don't outweigh the 15-second ticks before it. The
health log keeps its line forms, with the native name of the data in a save line
(`save failed: the settings`).

The panel has the layout of the approved mockup: the same headline, Clear button, Details row and
sections, the same "Last N min" key of the trend line, and the Details choice in the same
`performance` value of `ui-state.json`. It counts as showing while it's the active tab of a frame
that isn't minimised in a window on screen, which the native app reads from the frame and the
window's occlusion where the TypeScript read the visibility of the page. The update check reports
the end of each update cycle of Sparkle, so only the release app has an update streak, and a cycle
that finds no update or an install the user cancels or puts off is a good check. The session list
retries a failed save every second, so it reports only the first failure of each run of failures
to the health log.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| SV1 | The form of a narrow panel | The panel draws a hidden copy of each row at its natural width, measures the widest one, and picks the form from the width of the panel (`measureNeeds` and `serviceView`). | The panel gives the three whole-list forms to `ViewThatFits(in: .horizontal)`, which shows the first form that fits. An incident line asks for no width, so it can't force a smaller form. | SwiftUI measures a form without hidden copies, and a wider panel goes back to a fuller form by itself. | Yes, only in how a narrow panel picks its form: the widths where the form changes can differ by a few points. For the hands-on test. |
| PF1 | Crashes and the process groups | A `render-process-gone` event of the window or a `child-process-gone` event of the GPU process was a Problem for 60 minutes, with its time, and the Bifrost section grouped the Electron processes into Main process, Window, GPU and Other helpers. | No crash check. The Bifrost section has the app process and the chat terminals. | Bifrost is one process: a crash ends the app and the monitor with it, so there's nothing left to report. | No. |
| PF2 | Where the numbers come from | `app.getAppMetrics()` for the Electron processes, and `ps`, `sysctl`, `pmset`, `route`, `networksetup`, `netstat` and `du` with absolute paths for the rest. The memory of a process was its resident size. | System calls only: libproc and `proc_pid_rusage` for the processes (the memory is the physical footprint, as Activity Monitor shows it), `sysctl`, `host_statistics`, `ProcessInfo`, the IOKit power sources, `NWPathMonitor`, `getifaddrs` and a file walk for the clones. No program starts for a value. | A system call costs a tiny part of a program start, and each program start is slow on a Mac with an endpoint scanner (user decision, 2026-11-16). | No. |
| PF3 | The main process delay | `monitorEventLoopDelay()` of Node with a 50 ms resolution, less the resolution: the longest delay of the event loop in each 60 s window. | Two run loop observers on the main thread time each pass from `afterWaiting` (the first observer) to `beforeWaiting` (the last observer, after the display cycle and the Core Animation commit), on a clock that stops while the Mac sleeps, and keep the longest pass in each 60 s window. The reason text stays "Bifrost's main process was slow to respond". | The main run loop is what a slow Bifrost holds up, so its passes are the native measure of the same thing. | No. |
| PF4 | The GitHub points | The `rateLimit` of the last Reviews poll, and `gh api rate_limit` only with Reviews off or with a value past its reset time. | Always `gh api rate_limit` (it costs no points), at most every 60 s while the panel shows. | The two lanes of the port share no code, and one source is simpler than two. | No. |
| PF5 | The CPU values | The OK text and the CPU reason showed percent of all cores (only the check scaled the average back to one core), and the CPU of the OK text left out the chat terminals. | Percent of one core everywhere, as the Performance design and Activity Monitor define it, and the OK text gives the memory and the CPU of the app with its chat terminals. | One unit everywhere, so "50% CPU" means the same in the headline, in a reason and in Activity Monitor. | Yes: the CPU figures are higher by the number of cores, and the OK text's CPU includes the chat terminals. For the hands-on test. |
| PF6 | The rows of the section "Bifrost" | One row for each group of Electron processes: Main process, Window, GPU, Chat terminals (with the count) and Other helpers. | Two rows: App, and Chat terminals (with the count). | Bifrost is one process (PF1), so the chat terminals are the only other group. | Yes: the section has two rows where Electron had up to five. For the hands-on test. |
| PF7 | The Stop button of a session | Showed only while the Stop action was on: no other action running on the session, and its short ID known. | Shows for each owned session that runs. The Stop action decides at the click with the row of that moment, with its checks and, for a session that works, its confirmation, so a click during another action of the session does nothing. | The panel lives in the health module, which can't read the action runner's state; the click still goes through the same action and the same checks. | Yes: Stop can show for a moment when Electron hid it, and then does nothing. For the hands-on test. |
| PF8 | A size in the panel | From 1,024 MB a size had two decimals in GB ("1.25 GB"), in the panel only. | Every size in the panel has the form of the OK text: whole MB below 1,024 MB, then GB with one decimal ("1.3 GB"). | One form for a size in the headline and in the sections. | Yes: a size from 1 GB has one decimal, not two. For the hands-on test. |
