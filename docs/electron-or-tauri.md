# Electron or Tauri

Bifrost stays on Electron for now. Tauri 2 can run Bifrost, but the move costs more than it gives.

Bifrost is a desktop app for macOS that shows Claude Code sessions. It has many terminals, a window manager inside the page, and visual effects that need the GPU. A Tauri 2 spike (branch `tauri-spike`) gave the evidence below.

## Comparison

| Factor | Electron 44 | Tauri 2 | Effect on Bifrost |
|---|---|---|---|
| Web engine | Chromium, shipped in the app | The system web view: WKWebView (macOS), WebView2 (Windows), WebKitGTK (Linux) | Electron gives one engine on each platform. Tauri gives a different engine on each platform. |
| Engine updates | The app team chooses when Chromium changes (with an Electron update) | The operating system changes the engine (each macOS update changes WKWebView) | With Tauri, a macOS update can change the rendering, and the app cannot roll back the engine. |
| Backend language | TypeScript on Node.js | Rust | Bifrost uses TypeScript for the main process, the UI, the shared types and the Live details mod. Tauri adds a second language and a type contract that can drift. |
| Node.js packages | Available (for example `node-pty`) | Not available. Rust crates replace them (for example `portable-pty`). | Each Node.js package of the main process needs a Rust replacement. |
| End-to-end UI tests on macOS | Playwright controls the app (`_electron`), with screenshots and Chrome DevTools Protocol (CDP) access | `tauri-driver` does not support macOS | The smoke tests, the screenshot checks and the CDP measurements of Bifrost do not move to Tauri. More checks become manual. |
| Debug tools | Chrome DevTools | Safari Web Inspector | Both work. The CDP-based tools of the Bifrost tests work only with Chromium. |
| App size | 302 MB app, 131.7 MB DMG | 15 MB app, 4.2 MB DMG | Tauri is about 20 times smaller. |
| Memory | About the same by resident memory in the spike | About the same by resident memory in the spike | No strong reason in either direction. Each open chat window also runs `claude attach` (about 125 MB) in both apps. |
| First Rust compile | Not applicable (about 16 s for an Electron build in one source) | About 80 s in one source | Slower change and test cycles. |
| Ecosystem | About ten years of production use: packaging, signing, auto-update and crash reports are mature | Smaller and newer, and it grows fast | More known solutions for edge cases with Electron. |
| IPC security | Context isolation and a preload bridge | A permission model (capabilities) for each command | Both are good. Tauri is stricter by default. |
| Mobile targets | No | Yes (iOS and Android) | Bifrost has no mobile need now. |

## Native gaps in Tauri 2 (macOS)

The spike mapped each Electron API that the Bifrost main process uses to a Tauri 2 plugin or crate. These items have no Tauri API, or need more work.

| Gap | Effect on Bifrost |
|---|---|
| No API for file and app icons (`app.getFileIcon`) | The "Open project" menu shows app icons. About 60 lines of native code are necessary. |
| No full-screen enter and leave events | The display modes must watch size changes, or use native code. |
| macOS adds "Enter Full Screen" to a View menu | Native code must set the `NSFullScreenMenuItemEverywhere` default. |
| The single-instance lock is per app identifier | A test copy of Bifrost (with a test home) cannot run beside the real app. The Bifrost checks need this. |
| The login item uses a LaunchAgent or AppleScript | Electron uses SMAppService. The login item must move, and macOS asks for permission again. |
| No getter for the normal window bounds | The window restore needs more code. |
| Notification click in a packaged app | Not proven. |
| No `safeStorage`, `powerMonitor` or Chromium `net.fetch` | The Slack plan (M6) uses all three: Keychain encryption, a reconnect after sleep, and the system proxy. Each needs a Rust replacement. |
| No `WebContentsView` or Chromium sessions | An embedded web page in a panel (for example a web client) is harder. |
| No Edit menu means no Cmd+C, Cmd+V or Cmd+A in the page | Each such native detail is built by hand. |
| A new app identifier gives a new data folder | The settings, layouts, local names and window state must move. Keychain and notification permissions are asked again. |

Each gap has a fix. Together they are native code that Electron already supplies.

## Spike results

| Check | Result |
|---|---|
| The full Bifrost UI in WKWebView: Overview, frames, blur, the animated background and its pause, the loader gradient and mask, the transparent terminal, fonts, the Settings search | Pass |
| A real Claude Code session in xterm.js through a Rust PTY: colours, box lines, the input box, the status line | Pass |
| xterm.js WebGL renderer and the DOM fallback after a context loss | Pass |
| Keys: Esc, Cmd+F, single-key shortcuts, menu shortcuts (Cmd+W, Cmd+A, Cmd+,, Cmd+Q) | Pass |
| PTY throughput through the Tauri channel | 80 to 117 MiB/s |
| Tauri DMG step (`tauri build`) | Failed on the test Mac (`hdiutil`: "Resource busy"). The Electron DMG built. |
| Dim terminal text (SGR 2) with WebGL and a transparent theme | An opaque black cell background. Chromium gives the same result, so this is xterm.js behaviour, not a WebKit fault. |

The spike shows that Tauri can run Bifrost. The question is about cost and risk, not about whether the port is possible.

## Why Bifrost stays on Electron

1. **One engine under the app's control.** Bifrost depends on engine details: `backdrop-filter` over content that moves, WebGL in xterm.js, masks and gradients. Electron pins Chromium, and the team tests each engine change before it ships. With Tauri, each macOS update can change these details.
2. **Automated UI checks.** The Bifrost workflow checks each UI change with Playwright smoke tests, screenshots and CDP measurements. This is not possible for a Tauri app on macOS.
3. **One language.** The main process, the UI and the shared contract are TypeScript. A port rewrites about 8,800 lines and about 976 tests in Rust. This includes the registry rules, which took several review rounds to get right.
4. **Native features that already work.** Electron supplies the items in the gap table. The Slack plan also depends on three of them.
5. **Small gain.** The main gain of Tauri for Bifrost is the download size. Memory is about the same, and Bifrost does not need mobile targets.

## When to look at Tauri again

Look at it again when one of these becomes true:

- One framework for all desktop apps of the company becomes a firm requirement.
- The download size or the memory use becomes a real problem for users.
- Tauri gets end-to-end test support on macOS.
- Tauri gets a stable option to bundle its own engine. Tauri has explored Servo, through Verso.
- Bifrost must run on Linux or Windows for other users. On Linux, WebKitGTK has known WebGL and GPU problems (see the Tauri docs on Linux graphics).

## Glossary

| Term | Meaning |
|---|---|
| WKWebView | The web view of macOS. It uses the WebKit engine of Safari. |
| WebView2 | The web view of Windows. It uses the Chromium engine of Microsoft Edge. |
| WebKitGTK | The WebKit web view for Linux desktops. |
| CDP | Chrome DevTools Protocol: an interface that test tools use to control and measure a Chromium page. |
| PTY | Pseudo-terminal: the interface that connects a terminal program, such as `claude attach`, to a terminal view. |
| IPC | Inter-process communication: the messages between the UI and the main process. |
| Spike | A short, limited build that tests the risks of a change before a full plan. |

## Related

- [Bifrost design spec](specs/2026-11-04-bifrost-design.md)
- [Plans](plans/)
- The spike code: branch `tauri-spike` (`src-tauri/` and the Tauri adapter of `window.bifrost`).

## Sources

- [Tauri: Linux graphics issues (official docs)](https://v2.tauri.app/develop/debug/linux-graphics/)
- [Tauri 2.x vs Electron 2026 (moklabs research)](https://moklabs-research.pages.dev/reports/technology/2026-03-20-tauri-vs-electron-desktop-framework-decision)
- [Tauri 2 deep dive 2026 (youngju.dev)](https://www.youngju.dev/blog/culture/2026-05-14-tauri-2-rust-webview-desktop-mobile-electron-alternative-deep-dive-2026.en)
- [Comparing Electron and Tauri (OpenReplay)](https://blog.openreplay.com/comparing-electron-tauri-desktop-applications/)
- [Electron vs Tauri 2026 (PkgPulse)](https://www.pkgpulse.com/guides/electron-vs-tauri-2026)
- [Retrospective: 6 months of Tauri 2 (DEV Community)](https://dev.to/johalputt/retrospective-6-months-of-using-tauri-20-for-desktop-apps-60-smaller-installers-20-more-13m4)
- [Debugging WebKitGTK performance (GeoLibre)](https://instagit.com/opengeos/GeoLibre/how-to-debug-webkitgtk-performance-linux/)

Most sources are blogs. Their numbers vary. The numbers in the spike results come from the Bifrost spike on one Mac.
