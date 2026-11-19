# Usage: behaviour

Claude plans limit how much you can use them over two rolling windows, one of five hours and one
of seven days. Bifrost shows how much of each window you've used in the Usage HUD, and the usage
notification warns you when a window gets close to its limit. This page covers the rules behind
both, which live in `BifrostSessions/Model/Usage/`, along with the services in
`BifrostSessions/Services/Usage/`: the poller that fetches the account values, and the monitor and
store behind the usage notification. It also covers the time texts that the panels and
notifications share. `docs/ports/usage/DELIBERATE-DIFFERENCES.md` lists where they deliberately
differ from the Electron app.

## Time texts

Every time Bifrost shows in a panel or a notification follows one style: a 24-hour clock, no
commas, and English day and month names, whatever language and region your Mac uses. Only the
time zone changes a text, and each one uses the Mac's zone. The texts are in `TimeText`.

| Text | Looks like | Where it's used |
| --- | --- | --- |
| `clock` | `09:07` | Part of `clockOrDay` and `when` |
| `dayClock` | `Thu 14:03` | Part of `clockOrDay` |
| `clockOrDay` | `14:05` on the same day, else `Fri 13:00` | The Usage HUD and the usage notification |
| `clockMs` | `09:07:03.045` | The Event log |
| `when` | `09:07` on the same day, else `Wed 4 Nov 14:03` | Show Info and the update rows of Settings |
| `duration` | `less than 1 min`, `59 min`, `1 h 02 min`, `1 d 1 h` | Reset times and session lengths |
| `age` | `59 s`, `1 min`, `1 h`, `1 d` | The Overview's Activity column and the source line of the Usage HUD |

- "The same day" means the same date as now in the time zone, so 23:30 UTC on 4 November already
  counts as 5 November in Tokyo.
- A duration counts whole minutes. Anything under a minute, including a negative length, is
  "less than 1 min". Under an hour it's the minutes, under a day it's the hours and two-digit
  minutes, and from a day on it's the days and hours.
- `clockMs` shows the exact millisecond, and a time before 1970 counts back from the second
  before it, so one millisecond before 1970 shows `23:59:59.999`.
- The day and month names come from macOS's British English (en_GB) data, so September shows as
  `Sep`.
- An age is in whole units, and a time after now shows `0 s`. The Overview also asks for the time
  until the age text next changes (at most an hour) so it can update the cell just then.

## Where the usage values come from

Bifrost has two sources for usage values. The account values come from the usage endpoint of your
Anthropic account, which Bifrost polls when account usage is on in Settings. The session values
come from the usage lines that Claude Code sessions send through Live details, and the newest of
those lines becomes the session snapshot. `UsageSource.pick` chooses between them, and the Usage
HUD and the usage notification both use it, so they can't disagree.

- The account values win while they're 15 minutes old or less, even when they lack a window that
  the session values have, and also when their time is after now.
- Older account values fall back to the session values. With neither, there's no source.
- A limit is high from 90 percent, judged on the rounded percent. The HUD then draws its bar in
  red, and Bifrost shows the usage notification. Above 70 percent, up to 89, the limit is raised,
  and the HUD draws its bar in amber. The usage notification doesn't change with the raised level.
- The account values also say whether extra usage (spending beyond the plan) is on. That flag is
  unknown until an answer from the account gives it.

## The account values

With account usage on in Settings, Bifrost asks your Anthropic account for its usage directly,
so the numbers are there even before any session has sent a usage line. `AccountPoller` runs the
polls, `AccessToken` reads your login and `AccountAnswer` reads what the endpoint sends back.

### When it polls

The poller polls as soon as it starts and then every five minutes. Opening the Usage HUD polls as
well, so the HUD shows fresh values, but never while a poll is running, never within a minute of
the last poll and never during the wait after a rate limit. A poll from the HUD restarts the
five-minute timer.

Each poll reads the token again, then sends one request:

- The token is the access token of your Claude Code login, which Bifrost reads from the macOS
  Keychain with `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` and a
  10-second limit. The login must have a `claudeAiOauth` object with a non-empty `accessToken` and
  a numeric `expiresAt`. A token that expires within the next minute counts as no token, because
  it could expire during the request.
- Bifrost uses only the access token: it never keeps the refresh token, and it never refreshes
  the login. Claude Code does that itself, and the next poll picks up the new token.
- The request is a GET to `https://api.anthropic.com/api/oauth/usage` with the token as a bearer
  token, the header `anthropic-beta: oauth-2025-04-20` and `User-Agent: Bifrost`, and it has a
  10-second limit. The whole poll ends after 25 seconds, even when the request hangs.

### What each answer does

Every poll ends with one of three results, ok, no data or failed, which the poller keeps for health
reporting. Most problems keep the last good values on screen, because they say nothing about your
usage, while an expired login or an unusable answer clears them.

| What happens | The values | Result |
| --- | --- | --- |
| A good answer | Replaced | ok |
| No token | Kept | no data |
| 401 or 403: the login has expired | Cleared | no data |
| 429: rate limited | Kept, and the next poll waits 15 minutes | no data |
| Another status that isn't 2xx, including a redirect | Kept | failed |
| No answer at all, or the body can't be read | Kept | failed |
| A body over 1,000,000 bytes, not JSON, or with no usable window | Cleared | failed |
| No end within 25 seconds | Kept | failed |

### Reading the answer

The endpoint isn't documented, so the parse is careful and ignores every key it doesn't know.

- The five-hour window comes from `five_hour` and the seven-day window from `seven_day`, each with
  a `utilization` percent and a `resets_at` time. When `seven_day` is missing or unusable, the
  first usable `weekly_all` entry of the `limits` list stands in, with its `percent`.
- A percent must be a number of 0 or more, and anything above 100 counts as 100. A reset time must
  be ISO 8601 with seconds and a zone, which is the form the Live usage lines use as well.
- An answer needs at least one usable window. Without one, it's an unusable answer.
- The extra usage flag comes from `extra_usage.is_enabled`, and only when that's a true or false
  value.

### Stopping, and keeping the token safe

Turning account usage off stops the polling and clears the values, and a poll that's still running
changes nothing once it ends. A rate-limit wait outlasts the stop, so turning the setting off and
on again can't hammer the endpoint.

The token only lives in memory for the length of one request, and it goes to the fixed URL above
and nowhere else. Each request has its own ephemeral session with no cookies, no cache and no
saved credentials, and that session refuses every redirect. Bifrost never logs the token, writes
it to a file or shows it: a log line names a fixed reason and at most an HTTP status.

## The Usage HUD

The HUD shows a bar for each window and, under them, a line that says where the values came from.
`UsageView.of` works out the bars and that line.

- There are normally two bars, "5-hour limit" then "7-day limit". Some plans have no 5-hour
  window, so a source with a 7-day window and no 5-hour window shows only the 7-day bar, and the
  5-hour bar comes back as soon as its window does. A source with neither window keeps both bars.
- A bar with no window says "No data for this limit yet.", except for a missing 5-hour window in
  the account values, which says "No 5-hour limit right now.".
- With no source at all, both bars say "No data" and the source line says "No usage data yet.".
- A bar's percent is the used percent rounded to a whole number and kept between 0 and 100, and
  the bar is raised from 71 and high from 90 (`UsageLevel`). Both bars follow the same levels. A
  value that isn't a finite number shows "-" rather than 0%.
- Under each bar is the time until the reset and the reset time, such as
  "Resets in 2 h 05 min (14:05)" or "Resets in less than 1 min (12:00)".
- Once the reset time has passed, including the exact moment of the reset, the old percent is
  wrong and the new one isn't known until the next message. The bar then shows "-" and the time
  of the reset, such as "Reset at 11:00." or "Reset at Wed 12:00.", as Show Info does.
- The source line names the account and the age of its values, as in "From your Anthropic
  account, updated 3 min ago.", or the session and the age of its usage line, as in
  "From bifrost-test-a, 2 min ago.".

### The panel

You open the HUD from its button in the side bar, with its key (Cmd+U by default), or by clicking
a usage notification, which brings the window forward first. It's an ordinary panel, 360 by 180
units when it first opens, and it has no controls, so it never takes the keyboard focus. The
panel lives in `BifrostSessions/UI/Usage/`: `UsageHUDPanels` makes its body and keeps its values,
and `UsageHUDPanel` lays them out.

- Each bar has its label and percent on one line, the bar itself under them, and the reset text
  under that. The bar is teal (`#5fb3c9`) up to 70 percent, amber (`#d4730a`) above 70 and red
  (`#dc2626`) from 90, on a track in the panel edge colour. The source line sits at the bottom in
  the dim text colour.
- New values show as soon as they arrive, whether that's a usage line from a session or an answer
  from the account. The clock the texts are worked out from moves on every 30 seconds while the
  panel is open, so an age like "updated 3 min ago" keeps up without a new value.
- Each time the HUD shows, it asks the poller for fresh account values: when it opens, when its
  minimised frame comes back from the side bar, when its tab becomes the active tab again, and
  when you reopen the window while the HUD is showing in a frame. The poller still polls at most
  once a minute, so flicking between tabs doesn't hammer the endpoint, and with account usage off
  there's no poll at all.
- VoiceOver reads each bar as one element, with its label, percent and reset text together.

## The usage notification

When either window reaches 90 percent, Bifrost shows a notification, so you can ease off before
Claude Code stops, or before extra usage starts costing real money. Each window gets one
notification per reset period, so a busy afternoon doesn't fill Notification Centre.
`UsageAlertRules` holds the rules, `UsageAlertMonitor` checks them whenever new values come in,
and `UsageAlertStore` remembers which periods have already had their notification.

### When it shows

The monitor has no timer of its own. It checks the rules each time the account values or the
session snapshot change, and it picks between them with `UsageSource.pick`, so it always looks at
the same values as the Usage HUD.

- A window notifies when its rounded percent is 90 or more and its reset time is still ahead. The
  rounding matches the red of the HUD, so 89.5 percent notifies and 89.4 doesn't. When
  both windows qualify at once you get two notifications, the 5-hour one first.
- A period is known by its reset time, and each window notifies once per period. The account
  values and the session values can disagree slightly about that time, so a reset time up to 15
  minutes after the one Bifrost remembers still counts as the same period. Bifrost also moves the
  remembered time forward whenever a later reset time in the same period comes in, so small steps
  can't add up to a new period. A reset time more than 15 minutes later is a new period, and it
  notifies again.
- The Notifications setting turns the notification off. While it's off, Bifrost still follows the
  reset time of a period it has already notified, but it doesn't mark new periods as notified, so
  after you turn the setting back on the next value in that period can notify.
- The notification shows even while the Bifrost window has the focus, unlike the notification for
  a red box.

### What it says

| Extra usage | Title | Body |
| --- | --- | --- |
| Off | `5-hour limit at 92%` | `Claude Code stops at 100% until the limit resets at 14:05.` |
| On | `Warning: extra usage is on` | `Your 5-hour limit is at 92%. After 100%, Claude Code spends your extra usage credits, which costs real money. It resets at 14:05.` |

The window is either the "5-hour limit" or the "7-day limit", and the percent is rounded and never
goes above 100. The reset time is a `clockOrDay` text, so a reset on another day reads like
`Fri 13:00`.

### Whether extra usage is on

The warning only makes sense when extra usage really is on, so Bifrost works out the flag in this
order:

1. Fresh account values (15 minutes old or less) that carry the flag decide it, whether it's on or
   off.
2. Otherwise, if the last account values that carried the flag said it's on, it stays on.
   Account values that have gone stale after a rate limit or a network error therefore keep the
   warning.
3. Otherwise Bifrost reads `~/.claude.json` in the resolved home, so a test home uses its own
   file. Only `oauthAccount.hasExtraUsageEnabled` set to `true` counts as on.

`ClaudeJSON` does that last read, and only just before a notification shows. The file holds
account data, so Bifrost never writes it or logs any part of it, and every problem counts as "off":
a missing file, something that isn't a regular file (such as a folder or a FIFO), a file over 20 MB
or a file that isn't JSON. The read decodes only the one key it needs, so an odd value elsewhere
in the file can't get in the way. The period is marked as notified before the read starts, which
means a value that arrives during the read can't notify a second time.

### Remembering the periods

`usage-alerts.json` in the support folder keeps the reset time of the last notified period for
each window, or `null`, so a restart (after an update, say) doesn't repeat a notification. It's
saved the way every store is. Writes go one at a time and the newest value wins, unknown
top-level fields survive a save, and a file that doesn't parse is copied aside before Bifrost
writes over it. A kept time has to be a whole number of milliseconds and no more than eight days
ahead. A 7-day window always resets within seven days, and a time far in the future would block
that window's notifications until then, so anything else counts as no notified period. If the
file can't be read at all, Bifrost starts with no notified periods and doesn't save, so it never
writes over a file it couldn't read.

### Not ported

The Electron app held a click on a usage notification until its next page load, and it exposed
`usage.onOpen` through its preload bridge. A native window has no page to reload and no bridge, so
neither piece has a counterpart.
