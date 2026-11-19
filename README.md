<div align="center"><img width=150 src="docs/images/bifrost-icon.png" /></div>

<h1 align="center">Bifrost</h1>

<div align="center">

[![CI][ci-badge]][ci] [![Release][release-badge]][release]

[![Swift][swift-badge]][swift] [![SwiftUI][swiftui-badge]][swiftui]
[![AppKit][appkit-badge]][appkit] [![SwiftTerm][swiftterm-badge]][swiftterm]
[![Sparkle][sparkle-badge]][sparkle]

[![Conventional Commits][cc-badge]][cc] [![semantic-release][sr-badge]][sr]

</div>

[ci-badge]: https://github.com/Keane54/bifrost/actions/workflows/ci.yml/badge.svg?branch=main
[ci]: https://github.com/Keane54/bifrost/actions/workflows/ci.yml
[release-badge]: https://github.com/Keane54/bifrost/actions/workflows/release.yml/badge.svg
[release]: https://github.com/Keane54/bifrost/actions/workflows/release.yml
[swift-badge]: https://shieldcn.dev/badge/Swift.svg?size=xs&logo=swift&logoColor=ffffff&color=f05138
[swift]: https://www.swift.org/
[swiftui-badge]: https://shieldcn.dev/badge/SwiftUI.svg?size=xs&color=0a84ff
[swiftui]: https://developer.apple.com/xcode/swiftui/
[appkit-badge]: https://shieldcn.dev/badge/AppKit.svg?size=xs&color=262626
[appkit]: https://developer.apple.com/documentation/appkit
[swiftterm-badge]: https://shieldcn.dev/badge/SwiftTerm.svg?size=xs&color=262626
[swiftterm]: https://github.com/migueldeicaza/SwiftTerm
[sparkle-badge]: https://shieldcn.dev/badge/Sparkle.svg?size=xs&color=262626
[sparkle]: https://sparkle-project.org/
[cc-badge]: https://shieldcn.dev/badge/Conventional_Commits.svg?size=xs&logo=conventionalcommits&logoColor=ffffff&gradient=fe5196%2C+f77062
[cc]: https://www.conventionalcommits.org/
[sr-badge]: https://shieldcn.dev/badge/semantic--release.svg?size=xs&logo=semanticrelease&logoColor=ffffff&color=494949
[sr]: https://github.com/semantic-release/semantic-release
[dmg]: https://github.com/Keane54/bifrost/releases/latest/download/Bifrost-arm64.dmg

Bifrost is a native macOS app for Claude Code. It shows every Claude Code session on your Mac in
one window, and you can run them all from there.

Panels float inside the window. You can move, resize, snap and stack them, and save a layout by
name to load it again later.

It's written in Swift with SwiftUI and AppKit. The chat windows use
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), and updates come through
[Sparkle](https://sparkle-project.org/).

## What Bifrost does

- It reads the session list from `claude agents --json`, every 2 seconds by default.
- It starts new sessions in the background with `claude --bg`. The New session dialog closes as
  soon as the start begins, and a "Starting…" row shows until the session is ready.
- Each chat window is the real Claude Code terminal of one session, through `claude attach`.
- A session that runs in a terminal app, such as Warp, shows its status and the icon of that app.
  Take control moves it to Claude Code's background service.
- A yellow or red box flashes on a session that needs you, with an optional macOS notification
  and sound.
- Live details, an optional mod for Claude Code, sends live events and usage data to Bifrost, so
  it can show the model and the context use of each session.
- The Usage HUD shows the 5-hour and 7-day limits. When a limit reaches 90%, Bifrost sends one
  notification for that reset period.
- Hand over moves the work of a session to a fresh session, through a short note that the old
  session writes.
- Reviews watches your GitHub pull requests. Claude drafts the reviews and the replies, and you
  decide what goes out.
- The Daily update drafts your daily update for each work area.
- You can dictate into a chat window: hold Space and talk.
- Bifrost updates itself, and shows what's new after each update.

## Requirements

- A Mac with Apple silicon and macOS 26 or later.
- The Claude Code CLI (`claude`). Bifrost finds it through the PATH of your login shell.
- The GitHub CLI (`gh`) for Reviews. Log in with `gh auth login`.

## Install

1. Download [Bifrost for Apple silicon][dmg] from the latest release. The
   [Releases page](https://github.com/Keane54/bifrost/releases) has every version with its
   release notes.
2. Open the DMG and drag Bifrost to the Applications folder.
3. Open Bifrost. On the first start, the "Set up Bifrost" dialog walks you through the setup.

After that, Bifrost keeps itself up to date. Sparkle checks for new versions and shows you what
changed before it installs one, and after the restart the "What's new" dialog lists the changes.
Settings > Updates has the switch for automatic checks and a "Check now" button.

If you used the Electron version of Bifrost, it updates to this version by itself, and your
layouts and settings come across on the first start.

## Build and test

You'll need macOS 26 and Xcode 26.6 or later. The app build also needs Xcode's Metal Toolchain,
because the shaders of the background and the chat terminal are compiled when the app builds.
Xcode doesn't always install it, so on a new Mac run this once before your first build:

    xcodebuild -downloadComponent MetalToolchain

CI runs one script on every push, and you run the same script before every commit:

    scripts/check.sh

It runs 17 steps in order and stops at the first one that fails. Between them, the steps test the
checkers themselves, check the repo rules, look for forbidden code constructs and work out the list
of Debug-only names, resolve the package dependencies, run the package tests in the test sandbox,
build the package in release mode, and build the Debug and Release apps. Straight after the Debug
build, a release step tests the scripts that build and publish a release
(`scripts/test-release.sh`). Two bundled steps then check that the Debug app carries the Live
details mod and the skills plugin with exactly the bytes of the repo copies
(`scripts/check-bundled.sh`, which tests itself first). The Release build must contain none of the
Debug-only names. After the builds, a fork-child step checks that the code which runs in a forked
child process never calls into the Swift or Objective-C runtime. Finally the smoke test runs the
Debug app, and a last step makes sure the smoke script refuses to start the Release app. Each step
writes its output to `.build/check/<step>.log`, and passing `--clean` removes the `.build` folder
when the run ends. The full list of steps is at the end of `scripts/check.sh`.

Any other test command, even a single focused test, has to run through the test sandbox too:

    scripts/run-sandboxed.sh swift test --package-path Packages/Bifrost \
        --scratch-path .build/pkg --disable-sandbox --filter Shared

The sandbox keeps tests away from your real `~/.claude`, `~/.claude.json`, `~/.bifrost` and the app
data folders, it blocks the network and the Keychain tool `/usr/bin/security`, and it stops a test
from signalling any process it didn't start. Each `swift test` inside it needs `--disable-sandbox`,
because macOS won't let SwiftPM start its own `sandbox-exec` inside another sandbox. The full rules
are in `scripts/run-sandboxed.sh` and `scripts/test-sandbox.sb`. Outside the sandbox, for example
from a plain `swift test` or from Xcode, the shared helpers that start real processes or make
temporary folders (`TemporaryFolder` and `StandInProcess`, and so `FakeClaude` and `ChatFixture`)
stop the test at once, and so do the process runner suites.

Tests and scripts never attach to a real Claude session; they use the fake `claude` in
`scripts/fake-claude/` instead. Besides listing sessions and attaching to them, the fake handles the
commands of the session actions: `--bg` starts a session (a new one, or a resume) with a small
stand-in process, and `stop` and `rm` end it and take it off the list. It logs every call to
`claude-calls.log` in the test home, and it refuses to run with your real home. In the app, closing
a chat only detaches from its session: Bifrost sends SIGHUP (the "hang up" signal) to the attach
process it started, and the session itself keeps running.

## Running the app

Only ever run the Debug app. Open `Bifrost.xcodeproj` and use the shared `Bifrost` scheme, whose
Debug configuration builds `Bifrost Dev.app`. After a `check.sh` run you'll also find a copy in
`.build/xcode/Build/Products/Debug/`. The Debug app keeps its data in
`~/Library/Application Support/Bifrost Native Dev` and `~/.bifrost-native-dev`, separate from the
release app's folders.

Never start the Release build. It uses the Electron app's bundle ID, and unless it was built with
`BIFROST_CUTOVER` it shows an alert and quits. No build configuration sets that flag: only the
Release workflow adds it, on the `xcodebuild` command line, when it builds a release. How a release
works, and how the first one takes over from the Electron app, is in
[`docs/release.md`](docs/release.md). `check.sh` only builds the Release app, checks that it
contains no debug-only code, and then removes it from the LaunchServices database, so that macOS
can't open it in place of the Electron app.

The main panel is the Overview, Bifrost's table of your Claude Code sessions, and a window with no
saved layout opens with it, with the Selected Item panel to its right. Each Overview has a row of
tabs that filter and sort the sessions, and you can open more than one Overview from the side bar
(New Overview) and change any tab in its Overview Settings panel. What it does in detail is in
[`docs/behaviour/overview.md`](docs/behaviour/overview.md).

The session actions work from the Selected Item panel, the keys, the side bar and the row menu that
a right-click on a row opens. You can start a new session, send a message or a slash command,
interrupt, rename, set a priority, watch a session, open its project or a terminal, stop, resume,
take control of a session running in another terminal, and delete. Anything that needs a yes or a
few values asks in a Bifrost dialog inside the window, with the canvas dimmed behind it, never in a
system sheet. The row menu and the Panel menu are Bifrost menus too: borderless panels in Bifrost's
own colours and fonts, which work from the keyboard and with VoiceOver like the menus of macOS.
These actions run the real `claude` on your real sessions, so try them on `bifrost-test-` sessions
first. The rules are in [`docs/behaviour/actions.md`](docs/behaviour/actions.md) and, for the
menus, [`docs/behaviour/menu.md`](docs/behaviour/menu.md).

Settings opens from the gear at the bottom of the side bar, with Cmd+, or with Esc. It keeps the
nine tabs of the Electron app, and a search above them finds any setting or shortcut by its label
or by its key. General, Slash commands, Keys, Live details and Skills work now. The other sections
show "This section comes in a later build of Bifrost Dev." until their phase brings them: Reviews,
Daily update and Updates with phase 5, and Modules with phase 7. In
Keys you change a shortcut by recording it: click Change and press the new keys. While it records,
the recorder gets every key first, menu keys such as Cmd+W included, so nothing else acts on them,
and Esc stops it without a change. The details are in
[`docs/behaviour/settings.md`](docs/behaviour/settings.md) and, for the keys,
[`docs/behaviour/keys.md`](docs/behaviour/keys.md).

The side bar also opens the other panels of phase 4: the Watchlist, which lists the sessions you
watch in their colours and lets you drag them into order, the Event log, which shows the newest
events of your sessions as Live details reports them, and the Usage HUD, which shows how much of
your 5-hour and 7-day limits you've used. Show Info opens from a session's row menu and gives its
details, with the pull request of its branch, which Bifrost looks up with the GitHub CLI (`gh`).
The details are in [`docs/behaviour/panels.md`](docs/behaviour/panels.md) and
[`docs/behaviour/usage.md`](docs/behaviour/usage.md).

Bifrost tells you when a session needs you. A new box on a session row gives a macOS notification
while the window isn't focused, and a red box plays the Ping sound. When a limit reaches 90 %, a
usage notification shows once for that period, even while the window is focused. All of them go
through one notifier, and the first one asks macOS for permission. With Account usage from
Anthropic on in Settings, Bifrost also polls your account's usage every five minutes, with the
access token of your Claude Code login from the Keychain. A test home never does either: it
records each notification in memory and shows none, plays no sound, and has no poller, so a test
run never reads the Keychain or reaches the network. The rules are in
[`docs/behaviour/alerts.md`](docs/behaviour/alerts.md) and
[`docs/behaviour/usage.md`](docs/behaviour/usage.md).

The chat terminals draw with Metal. To switch the Debug app to Core Graphics drawing, run
`defaults write <Debug bundle ID> TerminalRenderer cg`, where the Debug bundle ID is the one set in
`Config/Debug.xcconfig`. The change takes effect the next time the app starts, and
`defaults delete` with the same ID and key switches it back.

### Live details and the skills

Live details is how Bifrost knows what each Claude Code session is doing right now: its model, its
context, its cost and whether it's waiting for you. A small Claude Code plugin, the mod, runs
inside every session and sends a line for each event to a Unix socket that Bifrost listens on,
`~/.bifrost/live.sock`. The Bifrost skills are a second plugin, a set of `/bifrost-...` skills
that sessions can call. This repo owns both plugins: the four mod files are in
`App/Bifrost/Resources/live-mod` and the skills in `App/Bifrost/Resources/bifrost-skills`, and
the app bundles both folders. Settings > Live details and Settings > Skills install them with
`claude plugin` (the mod goes to `~/.bifrost/mod`, the skills to `~/.bifrost/skills`), turn them
on and off and remove them, and the gear in the side bar shows a small dot when Live details needs
attention. At the first start a Setup dialog offers both. The rules are in
[`docs/behaviour/live.md`](docs/behaviour/live.md) and
[`docs/behaviour/skills.md`](docs/behaviour/skills.md), and the
[Live details and skills](docs/explainers/live-and-skills.html) page shows how the pieces fit.

### Reviews

Reviews watches GitHub for the pull requests that need you, the ones where someone asked for your
review and your own, and lists them in the Reviews panel. It polls through the GitHub CLI (`gh`)
with your own login, and only once you turn on Watch GitHub in Settings > Reviews. When you click
Review, Claude reviews the PR in a read-only background session and Bifrost leaves the result as a
pending review that only you can see, which you then approve, edit or send from the Review panel.
On your own PRs, once you turn on "Handle comments on my PRs automatically" and confirm it, Claude
fixes or answers each new review comment in a sandboxed session, and Bifrost commits, pushes and
posts the replies itself. Claude never touches GitHub or git: every write goes through a small set
of closed types in `BifrostReviews`, and `scripts/check_forbidden.py` stops any other code from
adding one. Bifrost works in its own clones under `~/.bifrost/reviews`, never in your checkouts. It
never merges or force-pushes, and it approves only when you click Approve. The rules are in
[`docs/behaviour/reviews.md`](docs/behaviour/reviews.md), and the
[Reviews](docs/explainers/reviews.html) page shows how the pieces fit.

### Shared paths

Bifrost Dev owns the state it shares with Claude Code (user decision, 2026-11-16): the Live
details socket, the mod, the skills, the settings backups and your saved status line
(`statusline-original.json`) in `~/.bifrost`, and Claude Code's settings file
`~/.claude/settings.json`. The app works out all these paths once, from its home
(`SharedClaudeState`), so under a test home, the temporary home folder that the tests and the
smoke test use, every shared path sits inside the test home and nothing can reach the real ones.
The writers are Live details and the skills: they copy the mod and the skills, listen on the
socket, and remove the old Electron hook install from Claude Code's settings file, keeping a backup
of the old file. Every `claude plugin` command that Bifrost Dev runs in a test home gets the test
home as its home, so it only changes the test home's Claude Code state.

### The data import

The first time a phase 4 build of Bifrost Dev starts, it copies the Electron app's data across, so
your local session names, priorities, watchlist, layouts, Overviews and settings carry over. It
reads `settings.json`, `registry.json`, `ui-state.json`, `window-state.json` and
`usage-alerts.json` from `~/Library/Application Support/Bifrost` and writes them, unchanged, into
`~/Library/Application Support/Bifrost Native Dev`. A Bifrost Dev file that the copy replaces stays
next to it as `<name>.before-import`, and the Electron folder is only ever read. The last step
writes a marker, `import.json`, with a short report of what came across and why any file didn't.
While the marker is there the import never runs again, so deleting it (with the app quit) is how
you'd run it once more. The full rules are in
[`docs/behaviour/import.md`](docs/behaviour/import.md).

### The Daily update

The Daily update reminds you each morning to post a short team update, and asks Claude to draft it
from the tickets that moved on your board and the PRs you merged. You set it up in Settings > Daily
update: Find servers reads the MCP servers of your Claude Code setup, you pick your board as the
ticket source and confirm the read tools that the run may use, and you add a work area for each
channel you post to. At the draft time Bifrost runs `claude -p` with only those read tools and
notifies you, and ten minutes before the deadline it reminds you again. The Daily update panel,
from its side bar button, shows one tab per work area with what moved and the draft, which you can
change in place and copy as Markdown. Bifrost never changes the board and posts nothing: you paste
the draft into Slack yourself and click Mark as sent. Only one copy of Bifrost runs the Daily
update at a time. The rules are in
[`docs/behaviour/daily-update.md`](docs/behaviour/daily-update.md).

### Performance

The Performance panel answers one question: is Bifrost using too much, or is something wrong with
it? The monitor samples Bifrost's memory and CPU every 15 seconds (every 2 while the panel shows),
counts the background polls that keep failing and the saves that don't make it to disk, and sums it
all up as OK, Warning or Problem, with a sentence for each reason and a coloured dot on the side
bar button while something's wrong. The Details row adds the Claude sessions (with a Stop button
for the ones Bifrost owns), your Mac, the network and the disk, which help you find the cause when
it isn't Bifrost. The past events also go to `health.log` in Bifrost's logs folder. A test home
measures no network and starts no `gh`. The rules are in
[`docs/behaviour/health.md`](docs/behaviour/health.md).

### The smoke test

`scripts/smoke.sh` runs the Debug app headless in a test home and drives it through the debug test
port, a local socket that only exists in a Debug build running in a test home. Before the start, it
puts a small hand-written Electron folder (`scripts/smoke-fixtures/electron-support`) in the test
home, read only, so it can check the import, the imported local name, the Overview's sort and that
the Electron folder never changes. It also changes the settings through the port, to check that a
change reaches settings.json, that a new menu key reaches the menu, and that a key conflict is
refused. Then it checks the panels of phase 4e: a Live details line gives an entry in the Event log,
the Watchlist shows the fixture row that the fixture registry watches, and Show Info of that row
shows the pull request of the fake `gh` in `scripts/fake-gh`, which prints `fake-pr.json` from the
test home. Last, it runs the session actions through the port against the fake `claude`: it sends a
message, renames a session, starts a new one, stops one and deletes it, and checks each `claude`
call and the rows that follow. The requests the port understands are listed in
`Packages/Bifrost/Sources/BifrostApp/Model/TestPortMessage.swift`.

The smoke test also owns Live details and the skills through the port. The fake `claude` keeps its
plugin state in `fake-plugins.json` in the test home and logs every call to `claude-calls.log`
there. The smoke test starts with no such file, so neither plugin is installed and the app doesn't
listen. It then installs Live details and checks the plugin commands, the four mod files with the
bundle's bytes, the socket and the answer to a Live details line, turns Live details off and
checks that the socket is gone, and finally installs the skills and compares the installed folder
with the bundle's.

Reviews gets its own run through the port, with no network and no real repository. The smoke test
makes a local bare repository in the test home, and a Debug build running in a test home clones
from there in place of GitHub. The fake `gh` answers the poll, the read of the PR and the one write
of a round from the files in `scripts/smoke-fixtures/reviews`, and it logs every write in
`gh-writes.jsonl`. With the automatic rounds off, the smoke test turns Watch GitHub on, checks that
a new review request flashes and that Pause stops it, then clicks Review. The fake `claude` runs a
`bifrost-test-` review session that writes a result file, and the round must leave exactly one
pending review on the fake GitHub and nothing else.

## Repo layout

| Path | What |
| --- | --- |
| `App/Bifrost/` | The app target, which handles start-up, the menu and updates, and holds the shell that joins all the parts together. `Resources/` has the Live details mod and the skills plugin that the app bundles |
| `Packages/Bifrost/` | One Swift package with a module for each area of the app: `BifrostFoundation`, `BifrostLayout`, `BifrostLook`, `BifrostKeyboard`, `BifrostSessions`, `BifrostLive`, `BifrostSettings`, `BifrostDictation`, `BifrostChat`, `BifrostWindows` and `BifrostApp`, plus `BifrostTestSupport` with the fakes and helpers that the tests share. Every module except the test support splits its code into `Model`, `Services` and `UI` folders as it needs them |
| `Config/` | The build settings and the Debug app's Info.plist |
| `scripts/` | The check script, the test sandbox, the smoke test with its fixtures, the fake `claude` and the fake `gh` |
| `tools/bench/` | The performance bench |

## Docs

- The explainer pages walk through the biggest pieces with diagrams, and open in a browser:
  [Canvas and panels](docs/explainers/canvas-and-panels.html),
  [Sessions and attach](docs/explainers/sessions-and-attach.html),
  [Keyboard input](docs/explainers/keyboard-input.html),
  [Live details and skills](docs/explainers/live-and-skills.html) and
  [Reviews](docs/explainers/reviews.html).
- [`docs/behaviour/`](docs/behaviour/) describes what each feature does, as the tests prove it.
- `docs/ports/*/DELIBERATE-DIFFERENCES.md` lists the places where the native app differs from
  Electron on purpose, and why.
- [`docs/release.md`](docs/release.md) explains how a release runs and how the Electron app
  updates to this one.
- [`docs/WRITING.md`](docs/WRITING.md) explains how to write docs for this repo.
