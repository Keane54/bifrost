<div align="center"><img width=150 src="build/icon.png" /></div>

<h1 align="center">Bifrost</h1>

<div align="center">

[![CI](https://github.com/Keane54/bifrost/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Keane54/bifrost/actions/workflows/ci.yml) [![Release](https://github.com/Keane54/bifrost/actions/workflows/release.yml/badge.svg)](https://github.com/Keane54/bifrost/actions/workflows/release.yml)

[![Electron](https://shieldcn.dev/badge/Electron.svg?size=xs&logo=electron&logoColor=ffffff&color=47848f)](https://www.electronjs.org/)
[![React](https://shieldcn.dev/badge/React.svg?size=xs&logo=react&logoColor=ffffff&color=087ea4)](https://react.dev/)
[![TypeScript](https://shieldcn.dev/badge/TypeScript.svg?size=xs&logo=typescript&logoColor=ffffff&color=3178c6)](https://www.typescriptlang.org/)
[![Tailwind V4](https://shieldcn.dev/badge/Tailwind_V4.svg?size=xs&logo=tailwindcss&logoColor=ffffff&color=00bcff)](https://tailwindcss.com/)
[![Vite](https://shieldcn.dev/badge/Vite.svg?size=xs&logo=vite&logoColor=ffffff&gradient=646cff%2Cbd34fe)](https://vite.dev/)
[![xterm.js](https://shieldcn.dev/badge/xterm.js.svg?size=xs&color=262626)](https://xtermjs.org/)

[![pnpm](https://shieldcn.dev/badge/pnpm.svg?size=xs&logo=pnpm&logoColor=ffffff&color=f69220)](https://pnpm.io/)
[![Biome](https://shieldcn.dev/badge/Biome.svg?size=xs&logo=biome&logoColor=ffffff&color=60a5fa)](https://biomejs.dev/)
[![Vitest](https://shieldcn.dev/badge/Vitest.svg?size=xs&logo=vitest&logoColor=ffffff&gradient=729b1b%2Cfcc72b)](https://vitest.dev/)
[![Playwright](https://shieldcn.dev/badge/Playwright.svg?size=xs&color=2ead33)](https://playwright.dev/)
[![Conventional Commits](https://shieldcn.dev/badge/Conventional_Commits.svg?size=xs&logo=conventionalcommits&logoColor=ffffff&gradient=fe5196%2C+f77062)](https://www.conventionalcommits.org/)
[![semantic-release](https://shieldcn.dev/badge/semantic--release.svg?size=xs&logo=semanticrelease&logoColor=ffffff&color=494949)](https://github.com/semantic-release/semantic-release)

</div>

Bifrost is a macOS desktop app for Claude Code. It shows all the Claude Code sessions on your Mac in one window, and it lets you control them.

Bifrost has a modular, flexible interface. Panels float inside one app window. You can move, resize, snap and stack the panels, plus save each layout with a name to load it again later.

Built with [Electron](https://www.electronjs.org/), [React](https://react.dev/) and [TypeScript](https://www.typescriptlang.org/), with:

- [electron-vite](https://electron-vite.org/) (build) and [electron-builder](https://www.electron.build/) (DMG)
- [xterm.js](https://xtermjs.org/) and [node-pty](https://github.com/microsoft/node-pty) (chat windows)
- [Tailwind CSS v4](https://tailwindcss.com/) (styles)
- [Base UI](https://base-ui.com/) (menus, dialogs and tooltips)
- [TanStack Table](https://tanstack.com/table/latest) and [TanStack Hotkeys](https://tanstack.com/hotkeys/latest) (Overview columns and keys)
- [Biome](https://biomejs.dev/) (lint and format)
- [Vitest](https://vitest.dev/) (unit tests) and [Playwright](https://playwright.dev/) (smoke tests)

## What Bifrost does

- Bifrost reads the session list from `claude agents --json` every 2 seconds.
- It starts a new session in the background with `claude --bg`.
- Each chat window shows the real terminal interface of Claude Code for one session. Bifrost runs `claude attach` for this.
- A session that a terminal app owns, for example Warp, shows its status only. With the Take control action, you can move the session to the background service of Claude Code.
- A yellow box or a red box flashes on a session that needs you. A macOS notification and a sound are optional.
- Live details is an optional mod for Claude Code. It sends live events and usage data to Bifrost. Then Bifrost shows the model, the cost and the context use of each session. Bifrost asks about Live details at the first start.
- When the 5-hour limit or the 7-day limit gets to 90%, Bifrost shows a macOS notification. Each limit gives one notification in each reset period. When extra usage is on, the notification warns you that Claude Code can spend real money after 100%. A click on the notification opens the Usage HUD.
- Bifrost skills are five built-in Claude Code skills. They give Claude tested steps for common jobs. Bifrost asks about them at the first start, after Live details. See the Skills section.
- Hand over moves the work of a session to a new session. Bifrost asks the session for a short note and saves it in `~/.bifrost/handovers`. Then Bifrost starts a new session that continues from the note. The new name is the old name with " (2)". When that name is taken, the number goes up to " (3)" or higher. The chat window shows the new session, and Bifrost parks the old session. Hand over moves the watchlist entry, its colour and the priority to the new session. The button gets the warning colour when the context use is 80% or more. Only Live details gives the context use, so the colour needs Live details. When you delete a session whose folder another session uses, Bifrost removes the session from the list at once and keeps the folder. Bifrost removes the session from Claude Code when you delete the last session in that folder. This applies only to a worktree, not to a plain folder.
- Bifrost updates itself. It checks GitHub for a new version and downloads it. When the update is ready, a button shows above Layouts in the side bar.
- Bifrost shows the release notes from GitHub. After an update, the "What's new" dialog shows the changes since your last version. The "Release notes" button in Settings > Updates shows the last 10 releases.

## Panels

The side bar on the left edge has one button for each panel. It also holds the panels that you minimise.

| Panel | Content |
| --- | --- |
| Overview | The list of sessions. Each tab has its own filters, columns and sort order. You can open more than one Overview. |
| Selected Item | The selected session, its action buttons (Hand over is one of them) and a send box. |
| Chat window | The Claude Code terminal of one session. |
| Show Info | All the details of one session. |
| Watchlist | The sessions that you track, in your order and colours. |
| Event log | The live events of the sessions, with their times. |
| Usage HUD | The use of the 5-hour limit and the 7-day limit. |
| Service status | The status of Claude, GitHub and Sentry. |
| Reviews | The GitHub pull requests that need you, in two tabs: To review and My PRs. In this version, the panel only shows the pull requests. |
| Settings | The tabs General, Slash commands, Keys, Reviews, Live details, Skills and Updates. |

## Skills

Bifrost skills are a small Claude Code plugin. The plugin has five skills.

| Skill | Group | Job |
| --- | --- | --- |
| `bifrost-review` | Called by name | Review a PR. |
| `bifrost-resolve-comments` | Called by name | Resolve the comments on a PR. |
| `bifrost-humanise` | Listed | Make a text sound like a person wrote it. |
| `bifrost-grill` | Listed | Ask hard questions about a plan. |
| `bifrost-hand-over` | Called by name | Hand over a session to a new session. |

Listed skills are in the skill list of Claude, so Claude can start them by itself. A skill that you call by name costs no context until you type its name.

- Install the skills from the setup dialog or from Settings > Skills. When you install the skills, Bifrost first shows each change.
- To start a skill, type its name in a chat, for example `/bifrost-review`.
- Bifrost updates the skill files at each start.
- After you install or turn on the skills, a session that runs now gets the change after `/reload-plugins` or a restart.
- The Hand over button works without the skills.

`bifrost-humanise` comes from `blader/humanizer`. `bifrost-grill` comes from `mattpocock/skills`. Both are MIT licensed.

## Requirements

- A Mac with Apple silicon and macOS 13 or later. The DMG has arm64 code only.
- The Claude Code CLI (`claude`). Bifrost finds it through the PATH of your login shell. For Live details, you need Claude Code 2.1.290 or later.
- The GitHub CLI (`gh`) for the Reviews panel. Log in with `gh auth login`.

## Install

1. Download [Bifrost for Apple silicon](https://github.com/Keane54/bifrost/releases/latest/download/Bifrost-arm64.dmg) from the latest release. The [Releases page](https://github.com/Keane54/bifrost/releases) has all versions and their release notes.
2. Open the DMG.
3. Drag Bifrost to the Applications folder. Keep Bifrost in this folder. Bifrost can update itself only from the Applications folder.
4. Open Bifrost from the Applications folder.
5. At the first start, Bifrost shows the "Set up Bifrost" dialog. Follow its steps, or select Skip.

After the first install, you do not need to download a DMG again. Bifrost checks for new versions. When a new version is ready, a button shows above Layouts in the side bar. Click the button to restart Bifrost with the new version. After the restart, the "What's new" dialog opens one time and shows the changes of the new version. Settings > Updates has the switch "Check for updates automatically", the "Check for updates" button, the "Show log" button and the "Release notes" button.

## Documentation

The [`docs`](docs) folder has the other documents:

- [Electron, Tauri or GPUI](docs/electron-or-tauri.md): why Bifrost stays on Electron.
- [Slack app](docs/slack/README.md): the Slack app for a later milestone.
