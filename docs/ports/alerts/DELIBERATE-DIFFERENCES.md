# Deliberate differences

This table lists the places where the native box alerts work differently from the Electron app's
TypeScript code on purpose. That code (`alert-monitor.ts`, `notifier.ts` and `pending-open.ts` in
`src/main/alerts/`, with their wiring in `src/main/ipc.ts`) is the reference for what the alerts
decide, not for how they get there. The last column says whether you'd notice the difference in
normal use, and a row marked "for the hands-on test" is one to check by hand in the real app.

Apart from A7 and A8, none of the rows changes what a user sees or hears. The notification is the
system one in both apps, and A1 keeps the same sound. A1 is marked for the hands-on test so that
someone listens to the sound in the real app, and so is A8.

A few parts look different and decide the same things. The core of the monitor returns its
notifications and its sound as effects, and the alert service runs them, where
`createAlertMonitor` called its dependencies directly. A box mark is the row's `SessionAlert`, and
the compare looks only at its colour and time, as `findNewBoxes` looked only at `box` and
`boxSince`. The notifier is a protocol with the system notifier, the recorder of a test home and
the fakes of the tests, where `notifier.ts` switched on a module flag.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| A1 | The alert sound | `/usr/bin/afplay` plays `/System/Library/Sounds/Ping.aiff` in a child process with a 5-second limit. | `NSSound(named: "Ping")` plays the same system sound in the app (`AlertSound`). | A short system sound needs no child process, and macOS finds the sound file by its name. | No, it's the same sound. The user listens to it by hand, for the hands-on test. |
| A2 | The sound in a test home | A test home plays the sound like any other start. | A test home plays no sound (`appAlertSound`). | A test run must never play audio aloud. A smoke test checks the notifications, which a test home records. | No, only in a test run. |
| A3 | The gap between two sounds | The gap of 2 seconds compares two wall times (`Date.now`). | The gap compares two times of the injected monotonic clock. | A change of the Mac's clock can't block the sound or let two sounds play close together, and a test drives the gap with a manual clock. | No. |
| A4 | A click while no window shows | The session waits for the next page load of the window, and a reload of the page also makes it wait. | The session waits for the next show of the window (`PendingOpen`). | The native window has no page to load or reload, so the wait ends when the window shows, and a close of the window starts it again. | No. |
| A5 | The record of a test home | The list is `globalThis.bifrostNotifications`, which a smoke test reads in the main process. | The list is `RecordingNotifier.recorded`, which the unit tests read. No smoke test reads it yet. | The native app has no global object for a smoke test. The debug test port can show the list when a smoke test needs it. | No. |
| A6 | The Dock icon of a development start | A `pnpm dev` start runs inside the Electron binary, so `devDockIcon` (`src/main/window/dock-icon.ts`) swaps the Electron icon in the Dock for the Bifrost icon with a "dev" badge. | No rule, and no test. | Bifrost Dev is a bundle of its own with its own icon, so the Dock already shows the right one. | No. |
| A7 | One alert for each requirement | A box is new when its colour or its time changes, so each page of a multi-question prompt gives a notification and a sound. | A box is new only when it starts a requirement, which ends when the session works again (`AlertRules.newBoxes`). A yellow box that turns red gives its one sound at the red box. | User decision (2026-11-23): a session that stops to need you dings once for that requirement. | Yes. A prompt with several pages gives one alert. |
| A8 | A finished turn that you didn't start | Each new yellow box gives a notification. | A new yellow box gives a notification only when the Live details mod reported a prompt from a person since the session's last yellow box (`AlertRules.newBoxes`, `SessionRow.personPrompt`). A turn that a background task, another session or agent, or a system message started stays quiet. Without prompt lines (Live details off, or an older mod), each new yellow box notifies as before. Red boxes are unchanged. | User decision (2026-11-24): a session that runs background agents woke up for each report and notified again and again, with nothing new to answer. | Yes. A background wake-up no longer notifies. For the hands-on test. |
