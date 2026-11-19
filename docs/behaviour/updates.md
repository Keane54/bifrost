# Updates: behaviour

Bifrost tells you what changed in each version in three places: the Release notes dialog, a
"What's new" dialog that opens by itself after an update, and the Updates section of Settings. The
update itself, from the download to the restart, belongs to Sparkle, the updater that ships inside
the release app. This page covers what Bifrost adds around it. The rules are in
`BifrostWindows/Model/ReleaseNotes/`, the source that reads GitHub in
`BifrostWindows/Services/ReleaseNotes/`, the dialog in `BifrostWindows/UI/ReleaseNotes/`, and the
Settings section in `BifrostSettings/UI/UpdatesSection.swift`.
`docs/ports/updates/DELIBERATE-DIFFERENCES.md` lists where it deliberately differs from the Electron
app.

## Release notes

The notes come from the releases that Bifrost publishes on GitHub. They are public, so the request
carries no token and no data about you. Bifrost reads them only when the dialog opens, and it keeps
the last good answer in memory for ten minutes, so opening the dialog again straight away doesn't
ask GitHub twice. Two dialogs that open at the same moment share one request.

The request has hard limits. It gives up after ten seconds, it reads at most 2 MB, it refuses every
redirect, and it uses a session with no cookies and no cache. An answer that is too large, slow,
redirected or not a list of releases counts as "could not load". The address of the Releases page
comes from the build setting `BIFROST_RELEASES_URL` (the Info.plist key `BifrostReleasesURL`), and
the address of the API follows from it. A test home reads `github-releases.json` in the home folder
instead, so a test run never reaches the network.

### What Bifrost keeps from an answer

Bifrost keeps the ten newest releases, newest version first. It drops drafts, pre-releases, a tag
that isn't a version, an entry it can't read, and any release whose page isn't below the Releases
page. Each body is split into a summary (the text before the first heading) and its sections. The
release workflow writes the section titles, and Bifrost shows only some of them, under friendlier
names:

| Section in the release | Shown as | Order |
| --- | --- | --- |
| BREAKING CHANGES | Changed | 1 |
| Features | New | 2 |
| Bug Fixes | Fixed | 3 |
| Performance Improvements | Faster | 4 |
| Reverts | Reverted | 5 |

Every other section, such as Documentation, Code Refactoring and Tests, stays hidden. Each item is a
line that starts with `*` or `-`. A bold word followed by a colon at the start of the line is the
item's scope, and the commit link at the end of the line is cut off along with everything after
it. Only **bold** and `code` have a format in the text. Everything else, including a link or an
HTML tag, shows as plain text.

### The dialog

The dialog is a Bifrost box in the window, like the other dialogs. It shows a version heading, the
date ("10 Nov 2026"), a "View on GitHub" button, the summary and the sections of each release. A
release with no summary and no shown section says "Small internal changes." The dialog never opens
an address of its own choosing: "View on GitHub" opens the page of a release from the answer, and
the other button opens the Releases page. Esc, a click outside the box and "Close" all close it.

| State | What it shows |
| --- | --- |
| Loading | "Loading the release notes…" |
| Could not load | "Couldn't load the release notes." and "Open the Releases page on GitHub" |
| Nothing to show | "There are no release notes to show yet." and the same button |
| Loaded | The releases |

From Settings, the dialog is titled "Release notes" and lists the last ten releases. After an
update, it is titled "What's new" and lists only the releases since the version you last saw.

## What's new

Only the release app opens What's new by itself, and Bifrost Dev never does. The decision happens
once at the start, when the settings have opened, and follows the rule below. The app writes the
current version to `release-notes.json` (in the support folder) before the dialog opens, so a
failed load never brings the dialog back for the same version. The dialog itself waits until the
Setup dialog is done and no other dialog is showing.

| Stored version | Setup done | Result |
| --- | --- | --- |
| None, or a text that isn't a version | No | A fresh install has no news: store the version, open nothing. |
| None, or a text that isn't a version | Yes | The first version with What's new: show only this version. |
| Older than the running version | Either | An update: show the releases after the stored version, up to this one. |
| The running version, or a newer one | Either | Nothing happens, and nothing is stored. |

## Settings > Updates

The section has five rows, and the search finds each one by its label:

| Row | What it does |
| --- | --- |
| Check for updates automatically | The existing setting. It turns Sparkle's scheduled checks and downloads on or off. |
| Version | The version of the running app. |
| Last checked | The time of the last check: the clock for today, else the weekday, date and clock. "Not yet" before the first check. |
| Check for updates | The "Check now" button. It starts a check, and Sparkle shows the result. |
| Release notes | The "Open" button opens the Release notes dialog. |

"Check now" is off unless the updater runs, so it is always off in Bifrost Dev, and the row says
"This build doesn't update itself." While an update cycle runs, from the moment Sparkle starts a
check to the moment the cycle ends, the button is off and the row says "Checking for updates…".
Sparkle can keep its own window open for that whole time, for example while it shows an update. If
Sparkle never reports a start, the line never shows, and the end of a cycle always puts the row back
to normal and updates "Last checked". Sparkle's own window shows an available update and its
download progress. Bifrost has no update line in Settings and no Update button in the side bar.
