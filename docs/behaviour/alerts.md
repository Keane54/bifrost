# Alerts: behaviour

When a session needs you, Bifrost tells you, even while you're working in another app. A session
row can carry an alert box: a yellow box once Claude has finished its turn, and a red box when it
needs you, which happens at a permission prompt, after an error, or when a yellow box has waited
long enough to escalate. Bifrost watches for boxes as they appear, shows a macOS notification for
each new one, and plays a short sound for a new red box. A yellow box is the one exception: it only
notifies you when you're actually waiting on it, which means after you've sent the session a
prompt. This page covers the rules behind those alerts. The rules live in
`BifrostSessions/Model/Alerts/AlertRules.swift`, the alert service that applies them in
`BifrostSessions/Services/Alerts/`, and the two parts that talk to macOS, the system notifier and
the alert sound, in `BifrostSessions/UI/Alerts/`.
`docs/ports/alerts/DELIBERATE-DIFFERENCES.md` lists where they deliberately differ from the
Electron app.

## New boxes

The shell gives the session rows to the alert service each time they change, starting from the
first active poll of the session list. The service remembers the box of every row, which means its
colour and the time it appeared, and compares each update with the one before.

- A box is new when it starts a requirement. A requirement starts when a session stops and needs
  you, which means a yellow or red box appears. It ends only when the session works again.
- Within one requirement a session gives one notification and one sound, however many prompts,
  pages, causes or box times come. A prompt with three pages gives one alert, not three.
- A box that clears and comes back with no work between is the same requirement. A yellow box
  that turns red is the same requirement, and so is a red box whose cause or time changes.
- Work means that the session list shows the session busy, the row is in the working state, or
  the row has a newer busy sample than the last update. Live events of the Live details mod give
  the working state too. There is no timer. Without the mod, a burst of work shorter than one
  read of the session list can be missed, and a quick new requirement then gives no second alert.
- The first update after Bifrost starts only records the boxes that are already there, so a
  start never sets off notifications for old boxes.
- A session that leaves the list ends its requirement, and new boxes are handled in the order of the
  rows.

## A finished turn

A session doesn't only work when you ask it to. When it runs background agents or tasks, each one
that reports back wakes the session for a turn of its own, and so does a message from another
session or agent. Each of those turns ends with a yellow box like any other, and a notification
for every one of them would tell you nothing new, so a yellow box only notifies you after you've
sent the session a prompt.

- A new yellow box gives a notification only when you've sent the session a prompt since its last
  yellow box, or since Bifrost started. A turn that a background task, another session or agent, a
  schedule or a system message started stays quiet, though its box still shows on the row.
- Each new yellow box uses up the prompts before it, even when no notification shows because the
  window has the focus or Notifications is off. Once you've seen the answer, a later wake-up won't
  tell you about it again.
- A prompt you type while a woken turn is still running counts, so the end of that turn notifies
  you.
- A red box with its own cause works as before. A permission prompt, a question or an error
  notifies you and plays the sound, whatever started the turn, and that's also true when it follows
  a quiet yellow box with no work between.
- A quiet yellow box that waits long enough to escalate still turns red on the row, but it plays no
  sound and sends no notification, because nothing is waiting for your reply. A yellow box that did
  notify you escalates as before, with its one sound.
- Bifrost learns who sent each prompt from the Live details mod (see "Who sent a prompt" in
  `docs/behaviour/live.md`), and only while the session's row is live. Without that, for example
  with Live details off or in a session that still runs an older copy of the mod, every new yellow
  box notifies, as it always did.

## The texts

| Box | Title | Body |
| --- | --- | --- |
| Yellow | The session name | Claude finished its turn. |
| Red, with the session in the error state | The session name | The session stopped with an error. |
| Any other red box (a prompt or an escalated box) | The session name | Claude needs you. |
| More than 3 new boxes in one update | Bifrost | 8 sessions need you. (with the real count) |

## Notifications

- A notification shows only while Notifications is on in Settings and the main window doesn't
  have the focus. If you're already looking at Bifrost, the box itself is enough. A closed window
  never has the focus, and a headless test window counts as focused, so it never gets one.
- One update shows at most 3 notifications. When more than 3 boxes appear at once you get a
  single summary instead, and clicking it opens no session.
- Box notifications are silent, because the alert sound below is their sound.
- The notifications come from the macOS notification centre, under Bifrost's own bundle ID. The
  first one asks you for permission, and macOS remembers your answer. They also show while
  Bifrost is the active app, as long as the main window isn't focused.
- Bifrost has one notifier, which the box alerts and the usage notification
  (`docs/behaviour/usage.md`) share. The app makes it as it starts, so a click on a notification
  reaches Bifrost even when it comes in early.
- If macOS refuses a notification, for example because notifications are off for Bifrost in
  System Settings, the Event log shows one line: "macOS didn't show a notification. Allow
  notifications for Bifrost in System Settings." The system log records the first refusal of each
  run.
- Bifrost remembers the click action of its 20 newest open notifications. Clicking an older one
  only brings the app to the front, as macOS does for any notification.
- A test home (a start with `BIFROST_TEST_HOME`) records each notification in memory and shows
  none, so a test run never puts a real notification on screen.

## The alert sound

- While Red box sound is on in Settings, a red box plays the macOS system sound Ping,
  whether or not the window has the focus. A yellow box never plays it. Each requirement plays it
  once, when its box is red: a yellow box that turns red plays it at the red box, and a red box
  that was already there at the start of Bifrost plays none.
- The sound plays at most once every 2 seconds, however many sessions need you. The gap is
  measured on a clock that doesn't jump when the Mac's time changes.
- A test home plays no sound, so a test run is always silent.
- If the sound can't play, Bifrost logs it and carries on.

## A click

- Clicking a box notification brings the main window to the front, restoring it if it was
  minimised and making Bifrost the active app, except in a test home, which never takes the
  focus. Bifrost then selects the session's row and opens it, just as a double-click on the row
  in the Overview does.
- If the window was closed, the click opens it first, and the session opens as soon as the
  window shows. It opens only once, so reopening the window later doesn't open it again.
- If a newer click comes while a session is still waiting for the window, the newer session
  replaces it.
- If the session has left the list by the time you click, or it's parked or external, the click
  still brings the window to the front but opens nothing, just as a double-click on such a row
  does.
