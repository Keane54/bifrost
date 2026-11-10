# Electron, Tauri or GPUI

Bifrost runs on Electron, and we think it should stay there for now.

We looked hard at two alternatives. Tauri 2 swaps Chromium for the system web view and the Node.js backend for Rust. GPUI, the framework behind Zed, drops the web engine altogether and draws everything natively on the GPU. Both can work. Neither is worth the cost today, but if Bifrost ever does leave Electron, GPUI is the better place to go.

## The short version

- **Electron** gives us one engine we control, automated UI tests, one language, and native features that already work.
- **Tauri** would make the app about 20 times smaller, but memory stays about the same. We would lose our UI tests on macOS, swap Chromium for a WebKit engine that changes with every macOS update, and rewrite the whole backend in Rust.
- **GPUI** is the most promising long-term option for an app like ours, and Discord is moving to it. But it means rewriting everything, UI included, on a framework that has not reached 1.0.

## The options side by side

| | Electron 44 | Tauri 2 | GPUI |
|---|---|---|---|
| How it draws the UI | Chromium, shipped inside the app | The system web view: WKWebView on macOS, WebView2 on Windows, WebKitGTK on Linux | Native Rust UI drawn on the GPU (Metal on macOS). No web engine. |
| Who controls engine updates | We do, when we update Electron | The operating system. Every macOS update can change rendering. | We do, through the GPUI version |
| Backend language | TypeScript on Node.js | Rust | Rust |
| UI code | Our React UI as it is | Our React UI, behind a small adapter | Rewritten in Rust as GPUI views |
| What we would rewrite | Nothing | The main process (about 8,800 lines) and its tests | The main process **and** the UI (about 13,100 lines of React), plus about 22,000 lines of tests |
| App size | 302 MB app, 131.7 MB DMG | 15 MB app, 4.2 MB DMG (from our spike) | Small, similar to Tauri (not measured) |
| Memory | Baseline | About the same as Electron in our spike | The lowest of the three. Discord's early GPUI build used about 290 MB. |
| Terminal | xterm.js | xterm.js | Rebuilt on `alacritty_terminal`, as in Zed's terminal |
| UI tests on macOS | Playwright drives the app, with screenshots and Chrome DevTools Protocol (CDP) access | No WebDriver support on macOS, so our smoke tests cannot move | GPUI's own Rust test tools with simulated input. No screenshots or CDP. |
| Visual effects (blur, masks, the animated background) | CSS, already built | CSS, works in WebKit (checked in the spike) | Rebuilt as custom drawing code |
| Maturity | About ten years in production, with mature packaging, signing, updates and crash reporting | Stable 2.x, smaller ecosystem that grows fast | Before 1.0. The API changes, the docs are thin, and the crates.io release lags Zed's own code. |
| Who uses it | VS Code, Slack, and Discord until its rebuild ships | Many smaller apps | Zed, Discord's next client, and a growing set of terminal apps for coding agents |

## What the Tauri spike showed

We built a small Tauri 2 version of Bifrost (branch `tauri-spike`) with the real UI and one real Claude Code chat.

| Check | Result |
|---|---|
| The full UI in WebKit: Overview, panels, blur, the animated background, the loader gradient, the transparent terminal, fonts, Settings search | Works |
| A real Claude Code session in xterm.js through a Rust PTY: colours, box lines, the input box, the status line | Works |
| xterm.js on WebGL, and the fallback renderer after a WebGL context loss | Works |
| Keys: Esc, Cmd+F, single-key shortcuts, menu shortcuts | Work |
| Terminal throughput through Tauri's channel | 80 to 117 MiB/s, plenty |
| Building the DMG | Failed on our test Mac (`hdiutil`: "Resource busy"). The Electron DMG built fine. |
| Dim terminal text gets a black box behind it with WebGL and a transparent background | Chromium does the same, so this is an xterm.js quirk, not a WebKit problem |

So Tauri can run Bifrost. The question is whether the move is worth it.

## Where Tauri falls short on macOS

These are the Electron features Bifrost uses that Tauri has no API for, or only covers partly. Each one can be fixed, but together they are native code that Electron already gives us.

| Gap | What it means for us |
|---|---|
| No API for file and app icons | The "Open project" menu shows app icons. That needs about 60 lines of native code. |
| No events for entering and leaving full screen | Our display modes would have to watch window size changes instead. |
| macOS adds "Enter Full Screen" to a View menu | Removing it needs native code. |
| The single-instance lock is per app ID | A test copy of Bifrost cannot run next to the real one, and our checks rely on that. |
| The login item uses a LaunchAgent or AppleScript | Electron uses SMAppService. The login item would have to move, and macOS would ask for permission again. |
| No way to read the normal window bounds | Restoring the window needs extra code. |
| Notification clicks in a packaged app | Not proven yet. |
| No `safeStorage`, `powerMonitor` or Chromium networking | The Slack plan relies on all three (Keychain encryption, reconnecting after sleep, the system proxy). |
| No `WebContentsView` | Showing another web page inside a panel gets harder. |
| No Cmd+C, Cmd+V or Cmd+A without an Edit menu | A small thing, but every detail like this is built by hand. |
| A new app ID means a new data folder | Settings, layouts, local names and window state would have to move. Keychain and notification permissions are asked again. |

## Why GPUI is the more interesting alternative

GPUI is the UI framework that Zed is built on. It draws straight to the GPU, so there is no browser engine underneath at all. That removes the thing that worries us most about Tauri: the engine changing under us. It also suits Bifrost's shape. Zed is a panel-and-terminal app much like ours, and its terminal (`alacritty_terminal` drawn by GPUI) is proven. A number of terminal apps for coding agents now use the same setup.

Discord's choice is a strong signal. In November 2026, Discord's CTO confirmed that the desktop app is being rebuilt in Rust with GPUI, replacing Electron. They looked at Tauri and chose GPUI. An early test build used about 290 MB of memory.

But it is a much bigger job than Tauri:

- **Everything gets rewritten.** Tauri would keep our React UI. GPUI replaces it, so the window manager, the Overview, every panel, Settings and the keys all become Rust code.
- **The framework is still moving.** GPUI is before 1.0. Its API changes, its docs are thin, and Discord needed its own patches to make it work for them.
- **Our visual effects need new code.** The panel blur, the masks and the animated background are a few lines of CSS today. In GPUI they become custom drawing code.
- **Testing changes completely.** GPUI has good Rust test tools with simulated input, but nothing like our Playwright smoke tests and screenshot checks.
- **Accessibility is weaker.** As far as we know, screen reader support in GPUI is behind what a web view gives.

## Why we are staying on Electron

1. **We control the engine.** Bifrost leans on engine details: blur over moving content, WebGL in xterm.js, masks and gradients. Electron pins Chromium, and we test each engine change before it ships.
2. **Our UI tests keep working.** Every UI change gets Playwright smoke tests, screenshots and CDP measurements. Tauri cannot do this on macOS, and GPUI would need new tooling.
3. **One language.** The main process, the UI, the shared types and the Live details mod are all TypeScript. Both alternatives add Rust and a second set of types that can drift.
4. **The native features already work.** Everything in the gap table above is free with Electron, including the three things the Slack plan needs.
5. **The gain is small for us.** Tauri's real win is download size, and memory is about the same. GPUI's win is bigger, but so is the cost.

## When to look again

- One framework for all of the company's desktop apps becomes a firm requirement.
- Download size or memory use becomes a real problem for people using Bifrost.
- GPUI reaches a stable 1.0 on crates.io, and Discord's GPUI client ships and holds up in daily use. If we ever move, this is the path we would look at first.
- Tauri gets end-to-end test support on macOS, or a stable way to bundle its own engine (it has explored Servo, through Verso).
- Bifrost needs to run on Linux or Windows for other people. On Linux, WebKitGTK has known WebGL and GPU problems (see Tauri's docs on Linux graphics), which counts against Tauri there.

## Glossary

| Term | Meaning |
|---|---|
| WKWebView | The web view on macOS. It uses Safari's WebKit engine. |
| WebView2 | The web view on Windows. It uses the Chromium engine from Microsoft Edge. |
| WebKitGTK | The WebKit web view for Linux desktops. |
| GPUI | Zed's Rust UI framework. It draws the interface directly on the GPU. |
| CDP | Chrome DevTools Protocol, which test tools use to control and measure a Chromium page. |
| PTY | Pseudo-terminal, the link between a terminal program such as `claude attach` and the terminal view. |
| Spike | A short, limited build that tests the risks of a change before anyone commits to it. |

## Sources

- [Tauri: Linux graphics issues (official docs)](https://v2.tauri.app/develop/debug/linux-graphics/)
- [Tauri 2.x vs Electron 2026 (moklabs research)](https://moklabs-research.pages.dev/reports/technology/2026-03-20-tauri-vs-electron-desktop-framework-decision)
- [Tauri 2 deep dive 2026 (youngju.dev)](https://www.youngju.dev/blog/culture/2026-05-14-tauri-2-rust-webview-desktop-mobile-electron-alternative-deep-dive-2026.en)
- [Comparing Electron and Tauri (OpenReplay)](https://blog.openreplay.com/comparing-electron-tauri-desktop-applications/)
- [Electron vs Tauri 2026 (PkgPulse)](https://www.pkgpulse.com/guides/electron-vs-tauri-2026)
- [Retrospective: 6 months of Tauri 2 (DEV Community)](https://dev.to/johalputt/retrospective-6-months-of-using-tauri-20-for-desktop-apps-60-smaller-installers-20-more-13m4)
- [Debugging WebKitGTK performance (GeoLibre)](https://instagit.com/opengeos/GeoLibre/how-to-debug-webkitgtk-performance-linux/)
- [Discord CTO confirms the desktop and mobile apps are being rebuilt in Rust (Inven Global)](https://www.invenglobal.com/articles/28182/discord-cto-confirms-the-desktop-and-mobile-apps-are-being-rebuilt-in-rust)
- [Discord ditches Electron for Rust to cut RAM usage (Cybernews)](https://cybernews.com/tech/discord-app-overhaul/)
- [Discord's ground-up rebuild (HotHardware)](https://hothardware.com/news/discords-ground-up-rebuild-aims-to-slash-ram-from-gigabytes-to-megabytes)
- [GPUI README (Zed)](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)
- [gpui-component (Longbridge)](https://github.com/longbridge/gpui-component)
- [Native app for coding agents with Rust and GPUI](https://baeseokjae.github.io/posts/native-app-for-coding-agents-rust-gpui/)

Most of these sources are blogs and news reports, and their numbers vary. The Tauri numbers in this document come from our own spike on one Mac.
