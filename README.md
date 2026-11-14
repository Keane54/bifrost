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
- Modules add your own panels to Bifrost. A module never gets a secret. See the Modules section.

## Panels

The side bar on the left edge has one button for each panel. It also holds the panels that you minimise.

| Panel | Content |
| --- | --- |
| Overview | The list of sessions. Each tab has its own filters, columns and sort order. You can open more than one Overview. |
| Selected Item | The selected session, its action buttons (Hand over is one of them) and a send box. |
| Chat window | The Claude Code terminal of one session. You can dictate into it. See the Dictation section. |
| Show Info | All the details of one session. |
| Watchlist | The sessions that you track, in your order and colours. |
| Event log | The live events of the sessions, with their times. |
| Usage HUD | The use of the 5-hour limit and the 7-day limit. |
| Service status | The status of Claude, GitHub and Sentry. |
| Reviews | The GitHub pull requests that need you, in two tabs: To review and My PRs. See the Reviews section. |
| Daily update | One tab for each work area. Each tab shows the tickets and PRs that moved since your last update, and the draft of your daily update. |
| Settings | The tabs General, Slash commands, Keys, Reviews, Daily update, Live details, Skills, Modules and Updates. |
| Module panels | The panels of the modules that you installed. See the Modules section. |

## Dictation

You can speak to Claude in a chat window. Bifrost types your words into the prompt of Claude
while you speak.

1. Click in a chat window.
2. Hold Space. After a short time, the top line of the window becomes green. A microphone icon
   and a level bar show in the header.
3. Speak. Your words show in the prompt. While you speak, Bifrost can change the last words.
4. Release Space. Bifrost types the final text.
5. Read the text. Press Enter to send it. Bifrost never presses Enter.

Rules:

- A tap of Space types a space. The microphone opens only when you hold the key.
- Speech recognition runs on your Mac. The audio and the text stay on your Mac. Bifrost saves no
  audio. Bifrost can download the speech model of your language from Apple one time. During the
  download, a hold shows the progress. When the model is ready, hold the key again. If you
  release the key before the download ends, the chat window does not tell you that the model is
  ready. Your next hold after the download dictates.
- macOS asks one time for access to the microphone. On macOS 13 to 15, macOS also asks for
  Speech Recognition. Answer each prompt. Then hold the key again. If you do not give access, the
  chat window shows a notice with an "Open System Settings" button. Use this button to give
  access.
- When macOS has no speech model for your language, Bifrost uses English.
- Dictation stops at these times. The text that Bifrost typed stays.
  - You press another key.
  - The window loses the focus.
  - The chat window closes.
  - The dictation is 2 minutes long.
- Dictation does not start when Claude shows a choice, for example a permission prompt. Then
  Space types a space.
- Dictation does not work with the vim mode of Claude Code.
- To change the key, go to Settings > Keys > Dictation key. The key can be Space, a letter, a
  number or a symbol, with no Cmd, Ctrl, Option or Shift. To turn dictation off, click Clear.

## Daily update

The Daily update reminds you to post a short update in Slack on each work day. Claude writes one draft for each work area. You read the draft, change it if necessary, and copy it to Slack.

Set up the Daily update in Settings > Daily update:

- **Ticket source**: an MCP server of your Claude Code, for example the server of your ticket board. Bifrost proposes the tools of the server that only read. You confirm the list.
- **You on the board**: your name, email or ID on the board. When this is empty, Claude uses the user of the MCP server.
- **Merged PRs**: Bifrost also uses your merged PRs as items. This needs `gh`.
- **Times and days**: the draft time (default 09:30), the deadline (default 10:00) and the work days (default Monday to Friday).
- **Format**: the template of the update, and up to three past updates as examples of your style.
- **Work areas**: each area has a name, a Slack channel and a short text that tells which work goes there. One area can take all other work.

How it works:

- At the draft time, Bifrost runs `claude -p` with the `bifrost-daily-update` skill. Then a notification with a sound tells you that the drafts are ready. When an area is not sent 10 minutes before the deadline, a second notification comes.
- When you open the Daily update panel, Bifrost makes new drafts. It does not do this when the last run ended less than 5 minutes ago. The Refresh button always makes new drafts.
- On the same day, a new draft does not replace a draft that you changed. The tab offers the new draft, and you choose. On the next day, the new draft replaces it.
- The reminders stop when you mark each area as sent, or when you click Skip today. Copy does not stop them.
- The run only reads the board. It gets the Read and Skill tools of Claude Code and the read tools that you confirmed. Bifrost denies all other tools of the server and all other MCP servers. A tool with a name that can change things, for example `update_item` or `deleteItem`, is always denied. Settings does not let you tick it.
- The Send button comes with the Slack app. Until then, copy the draft and paste it in Slack.

## Reviews

The Reviews panel shows the GitHub pull requests that need you. To start, turn on Watch GitHub in Settings > Reviews. Bifrost uses your `gh` login and checks GitHub every 2 minutes. You can change this interval.

- **To review**: the pull requests that ask for your review. A new request flashes. When you click Review, Claude reviews the pull request in a read-only session. Bifrost then saves a draft review on GitHub. Only you can see the draft. The row shows the result of Claude in a colour, with one button:
  - **Approval recommended** (green): click Approve to approve the pull request on GitHub, or to submit the draft review as an approval.
  - **Draft ready** (amber) or **Changes required** (red): click Comment or Request changes to open the Review panel. The panel shows the summary and each comment of the draft, also the comments that you added on GitHub. You can change each text and remove a comment. Bifrost changes nothing on GitHub until you click Send review. "Send as" sets the type of the review. Discard draft deletes the draft on GitHub. Approve instead deletes the draft, then approves the pull request.
  - **Approved by others** (grey): click Remove to hide the row in Bifrost. Nothing changes on GitHub. The row comes back when someone asks for your review again.
  - **CI failing** (red): Bifrost starts no review and does not approve the pull request. You can still send a draft as Comment or Request changes. **CI running** (grey, with a spinner): Claude can review, but Approve waits until CI has passed.
- **My PRs**: your own pull requests. Claude fixes or answers each new comment from an owner, a member or a collaborator of the repository. It also handles the first Copilot review of the pull request. The session of Claude has no access to GitHub. Bifrost then commits the fix, pushes it to your branch, replies to the comment and resolves its thread. When Claude needs a decision from you, the row shows Needs you. Click the row and answer in the Answer panel. Each reviewer name has the colour of the latest review: green for approved, amber for comments only, red for changes requested, grey for no review.

Rules:

- Bifrost makes its own copy of each repository and asks you to trust each copy one time. It never uses your checkouts.
- Bifrost approves a pull request only when you click Approve or Approve instead. It sends or
  deletes a draft review only when you click a button in the Review panel. It never merges a
  pull request. It never force-pushes. Bifrost itself never signs a commit.
- To get signed fix commits, turn on "Sign commits through GitHub" in Settings > Reviews. Bifrost
  then sends each fix to GitHub with your `gh` login, and does not push it with git. GitHub makes
  the commit and signs it, so the commit shows as Verified. You are its author. Bifrost does not
  send a fix that changes an executable file, a link or a submodule, or a fix that has more than 4
  MB of files. When Bifrost refuses a fix, turn the setting off and select Try again, or make the
  change yourself.
- Bifrost never pushes a change to a GitHub workflow, a GitHub action or a `.claude` folder.
- Comments from before the turn-on wait until you select Handle now in the menu of the row.
- To stop the automatic fixes, turn off "Handle comments on my PRs automatically" in Settings > Reviews.
- If Watch GitHub was on before the update that added the automatic fixes, Bifrost turns the automatic fixes off one time. The My PRs tab then shows how to turn them on.
- When Bifrost stops before it posts all the replies, the row shows Error. Select Try again to send the rest. Select Cancel to drop them. After Cancel, the comments wait for Handle now.

## Skills

Bifrost skills are a small Claude Code plugin. The plugin has six skills.

| Skill | Group | Job |
| --- | --- | --- |
| `bifrost-review` | Called by name | Review a PR. |
| `bifrost-resolve-comments` | Called by name | Resolve the comments on a PR. |
| `bifrost-humanise` | Listed | Make a text sound like a person wrote it. |
| `bifrost-grill` | Listed | Ask hard questions about a plan. |
| `bifrost-hand-over` | Called by name | Hand over a session to a new session. |
| `bifrost-daily-update` | Called by name | Write a draft of your daily update for each work area. |

Listed skills are in the skill list of Claude, so Claude can start them by itself. A skill that you call by name costs no context until you type its name.

- Install the skills from the setup dialog or from Settings > Skills. When you install the skills, Bifrost first shows each change.
- To start a skill, type its name in a chat, for example `/bifrost-review`.
- Bifrost updates the skill files at each start.
- After you install or turn on the skills, a session that runs now gets the change after `/reload-plugins` or a restart.
- The Hand over button works without the skills.

`bifrost-humanise` comes from `blader/humanizer`. `bifrost-grill` comes from `mattpocock/skills`. Both are MIT licensed.

## Modules

A module adds your own panels to Bifrost. A module is a folder of static web files with a manifest. You can keep a module in your own repository, also in a private repository. The [author guide](docs/modules.md) tells you how to write a module.

Each panel of a module runs in a sandboxed frame. The frames of a module run in a process of their own, apart from Bifrost and from the other modules. A frame has no Node, no network and no clipboard read. One known limit: if a browser bug takes over the process of a module, that process can send UDP to a fixed IP address. HTTP, TCP and DNS stay blocked. Bifrost tracks a browser-side block for UDP. The panel talks only to Heimdall, the secure core of Bifrost. Heimdall runs in the main process. It checks each call of a module against the permissions that you gave to the module.

A module never gets a secret. Heimdall keeps the tokens, the logins and the keys, and it never gives them to a module. Heimdall filters each value that it gives to a module. Each text that looks like a token or a private key becomes `***`.

A module cannot read the files on your Mac by itself. It can read a file only when you pick the file in a file dialog of its panel, or drop the file on its panel. The module can then give the content of the file to a module job, and the job sends it to Claude. Before each module job, the secret filter masks the known token and key formats in its input. So pick or drop only a file that you want the module to have.

Each module has a tier. Bifrost has two tiers:

- **Standard**: the panels of the module, its own storage, notifications, the session list, the plan usage, the service status, module jobs and Discuss with Claude. This version of Bifrost has only the Standard tier.
- **Permissive**: more access, for example Slack reads, GitHub reads and web reads, each to a target that you approve. A later version of Bifrost adds this tier. This version refuses a module that asks for a Permissive permission, with "This module needs a newer version of Bifrost."

To install a module:

1. Open Settings > Modules.
2. Click "Install from a folder" or "Install from a git repo". For a git repo, Bifrost accepts only an address of the form `https://github.com/<owner>/<repo>`. It uses your `gh` login, so a private repository works.
3. Read Heimdall's window. It shows the tier, each permission with the reason of the module, and what a module can never do.
4. Click "Allow". The module runs only after this step.

The side bar then shows a button for each panel of the module. In Settings > Modules, you can turn a module off, remove a permission, check for updates or remove the module. A new version that asks for a new permission does not run until you allow it.

A module job is a short Claude Code run that Heimdall starts for a module. The job has no tools, no MCP servers, no skills and no memory. You choose the model and the daily cap of the module jobs for each module. Without the permission "Run module jobs automatically", a job waits until you click Refresh in the title bar of a panel of the module.

With Discuss with Claude, a module can ask you to start a Claude session. Heimdall opens its own panel. The module can show text cards with Copy buttons there, but Claude does not see the cards. The prompt box always starts empty. You write the prompt and pick the folder. Only your text goes to Claude. The module cannot see or change the session.

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

The [`docs`](docs) folder and the root folder have the other documents:

- [Modules](docs/modules.md): the author guide. It tells you how to write a module for Bifrost.
- [Electron, Tauri or GPUI](docs/electron-or-tauri.md): why Bifrost stays on Electron.
- [Slack app](docs/slack/README.md): the Slack app for a later milestone.
- [Releasing](RELEASING.md): the secrets and the steps of a signed release.
