import type { DailySnapshot } from './daily-state'
import type { McpInventory } from './daily-update'
import type { DirInfo, NewSessionSpec } from './new-session'
import type { PerformanceSnapshot } from './performance'
import type { ReleaseNotesResult, WhatsNewStart } from './release-notes'
import type { ReviewsSnapshot } from './reviews'
import type { Settings, SettingsPatch } from './settings'
import type { SkillsStatus } from './skills'
import type {
  AccountUsage,
  ClaudeVersion,
  DisplayMode,
  HandOverResult,
  LiveStatus,
  LogEntry,
  PrInfo,
  Priority,
  ProjectApp,
  ProjectAppId,
  ResumeAllResult,
  SeenCounts,
  ServiceId,
  ServiceStatus,
  SessionRow,
  TermSize,
  UsageSnapshot,
  WatchColour,
  WorktreeCheck,
} from './types'
import type { UpdatesSnapshot } from './updates'

// The type of window.bifrost. The preload script implements it.
// When a call fails in the main process, it rejects with an Error.
// The message of that Error is the message of the failure.
export interface BifrostApi {
  claudeVersion(): Promise<ClaudeVersion>
  registry: {
    rows(): Promise<SessionRow[]>
    // Set the local name of the session. null or an empty name removes it.
    // This rejects for a bad name and for an unknown session.
    setAlias(sessionId: string, name: string | null): Promise<void>
    // Set the priority of the session. null removes it.
    // This rejects for a bad priority and for an unknown session.
    setPriority(sessionId: string, priority: Priority | null): Promise<void>
    // The watchlist. Each call rejects for bad input and for an unknown session.
    watch: {
      // Add the session at the end. A watched session only gets the new colour.
      add(sessionId: string, colour: WatchColour): Promise<void>
      remove(sessionId: string): Promise<void>
      colour(sessionId: string, colour: WatchColour): Promise<void>
      // Move the session before beforeSessionId. null moves it to the end.
      move(sessionId: string, beforeSessionId: string | null): Promise<void>
    }
    // The main process sends a maximum of 4 updates each second.
    // The error is the error of the last poll of the session list, or null.
    // The returned function removes only this listener.
    onUpdate(cb: (rows: SessionRow[], error: string | null) => void): () => void
  }
  // Service status (spec 8.11): the public status pages of Claude, GitHub and Sentry.
  service: {
    status(): Promise<ServiceStatus[]>
    // The main process sends the list after each round of checks. The returned function
    // removes only this listener.
    onUpdate(cb: (list: ServiceStatus[]) => void): () => void
    // Open the status page of the service in the browser.
    openPage(id: ServiceId): Promise<void>
  }
  // The newest rate limits of the plan, from the newest live usage line with rate limits.
  // null means that no usage line has rate limits, for example with Live details off.
  usage: {
    get(): Promise<UsageSnapshot | null>
    // The main process sends the value after a change, a maximum of 4 times each second. The
    // last value always goes out. The returned function removes only this listener.
    onUpdate(cb: (usage: UsageSnapshot | null) => void): () => void
    // The account usage from Anthropic (spec 8.8). null means that the setting is off, or that no
    // good answer is available. The value never holds a token.
    getAccount(): Promise<AccountUsage | null>
    // The main process sends the value after each change. The returned function removes only
    // this listener.
    onAccountUpdate(cb: (usage: AccountUsage | null) => void): () => void
    // The Usage HUD opened. The main process polls, when the setting is on, but at most one time
    // in 60 seconds.
    hudOpened(): Promise<void>
    // A click on a usage notification.
    onOpen(cb: () => void): () => void
  }
  // The Event log (spec 8.7): the newest live state events, kept in memory in the main process.
  events: {
    // All entries, in seq order.
    list(): Promise<LogEntry[]>
    // The main process sends new entries a maximum of 4 times each second. The returned function
    // removes only this listener.
    onAppend(cb: (entries: LogEntry[]) => void): () => void
  }
  actions: {
    // The installed apps that can open a project. The list has no paths.
    apps(): Promise<ProjectApp[]>
    // The installed terminal apps, in the order of the default rule. The list has no paths.
    terminalApps(): Promise<ProjectApp[]>
    // Open the project directory of the session in the app. The main process finds both.
    // This rejects for an unknown session, an unknown app and a failed open.
    openProject(sessionId: string, appId: ProjectAppId): Promise<void>
    // Copy the full session ID to the clipboard.
    copySessionId(sessionId: string): Promise<void>
    // Open the session in the terminal app. An owned session attaches there.
    // An external session brings its own terminal app to the front.
    // The notice is text for the user, or null. This rejects with a refusal code.
    openInTerminal(sessionId: string): Promise<{ notice: string | null }>
    // The icon (a data URL) of the terminal app of an external session, or null.
    terminalIcon(sessionId: string): Promise<string | null>
  }
  info: {
    // The PR of the branch of the session, from gh. The main process finds the folder and the
    // branch from the row, and keeps a result 5 minutes. This rejects for an unknown session.
    pr(sessionId: string): Promise<PrInfo>
    // Open the PR page in the browser. This does nothing when no PR is known.
    openPr(sessionId: string): Promise<void>
  }
  input: {
    // Type the text into the session: a message, or a slash command when it starts with "/".
    // The main process writes into the open chat window, or else through a hidden attach.
    // This rejects with the reason, for example for a red box or an empty text.
    send(sessionId: string, text: string): Promise<void>
    // Send one Esc to the session. A second Interrupt within 1.5 s has no effect.
    interrupt(sessionId: string): Promise<void>
  }
  // The session commands. The main process finds the row and makes the claude arguments.
  // Each call rejects with the reason, for example for a refused row or a failed claude command.
  // One action at a time runs for each session.
  sessions: {
    // Run "claude --bg" in the directory. This resolves when the entry of the session shows.
    create(spec: NewSessionSpec): Promise<{ sessionId: string }>
    // Run "claude stop". Only for an owned session that runs.
    stop(sessionId: string): Promise<void>
    // Delete the session. Pass true only after the user accepted the confirmation.
    // The main process refuses a delete without it. seen is the unmerged-work check that the
    // dialog showed, or null when the check failed or did not run. The main process discards
    // a worktree that claude rm keeps only after a check that the dialog showed.
    remove(sessionId: string, confirmed: true, seen: SeenCounts | null): Promise<void>
    // Run "claude --bg --resume". Only for a parked session.
    resume(sessionId: string): Promise<void>
    resumeAll(): Promise<ResumeAllResult>
    // End the process of an external session and resume it in the background (spec 9.2).
    // Pass true only after the user accepted the confirmation. The main process refuses
    // a call without it.
    takeControl(sessionId: string, confirmed: true): Promise<{ sessionId: string }>
    // Ask the session for a hand-over note, save it and start a new session that continues from
    // it (spec 8). Only for an owned session that runs and waits for input. This resolves when
    // the new session shows. The old session stays as it is.
    handOver(sessionId: string): Promise<HandOverResult>
    // Count the commits that are not merged and the changed files in the worktree of the
    // session. This resolves with null when a git command fails.
    deleteCheck(sessionId: string): Promise<WorktreeCheck | null>
    // Open the worktree folder of the session. The main process finds the path from the row.
    openWorktree(sessionId: string): Promise<void>
    // What the main process finds at an absolute path.
    dirInfo(dir: string): Promise<DirInfo>
    // Show the directory picker. This resolves with null after a cancel.
    pickDirectory(defaultPath: string | null): Promise<string | null>
  }
  alerts: {
    // A click on a notification of a box. The main process sends the session ID.
    onOpen(cb: (sessionId: string) => void): () => void
  }
  // The Reviews panel (Reviews design). The main process polls GitHub with gh while Watch GitHub
  // is on. A key is a PR key, owner/repo#123. Each call except snapshot rejects while Watch
  // GitHub is off.
  reviews: {
    // The newest snapshot. While Watch GitHub is off, its availability is 'off'.
    snapshot(): Promise<ReviewsSnapshot>
    // The main process sends each new snapshot.
    onUpdate(cb: (s: ReviewsSnapshot) => void): () => void
    // Poll now. The main process ignores a call during a poll or within 5 seconds of the last
    // poll. The new snapshot comes through onUpdate.
    refresh(): Promise<void>
    // Stop the flash of a To review row for the Pause time setting. This rejects for a key that
    // is not a To review row.
    pause(key: string): Promise<void>
    // End the pause of a To review row now. This rejects as pause does.
    endPause(key: string): Promise<void>
    // Open the PR page on GitHub. The main process finds the URL. This rejects for a key with no
    // PR in the last poll.
    openPr(key: string): Promise<void>
    // Open the comment of a question of the Answer panel on GitHub. The main process finds the
    // link. This rejects for an unknown PR or question, and for a link that is not on github.com.
    openComment(key: string, itemId: string): Promise<void>
    // A click on a notification of a new review request.
    onOpen(cb: () => void): () => void
    // Start a review of a To review PR. This rejects for a key that is not a To review row.
    review(key: string): Promise<void>
    // Take a PR out of the queue, or stop its round. This works on a row of either tab.
    cancel(key: string): Promise<void>
    // Stop the session of a PR. This works on a row of either tab. It rejects for a key that is
    // not a row of the snapshot.
    stopSession(key: string): Promise<void>
    // Queue a request round for a My PRs row: all older and held items, or the later Copilot
    // items. This rejects for a key that is not a My PRs row.
    handle(key: string, what: 'all' | 'copilot'): Promise<void>
    // Send the rest of the outbox of a My PRs row. With no outbox, handle all items.
    retry(key: string): Promise<void>
    // Save the answers to the open questions of a My PRs row. A null text means that the user
    // handles the item. This rejects for 0 or more than 50 answers, a bad item ID, or a text of
    // more than 2000 characters.
    answer(key: string, answers: { id: string; text: string | null }[]): Promise<void>
    // Open the trust terminal for a repository in the trust list of the snapshot. This rejects
    // for any other value, and when the terminal cannot start.
    trust(repo: string): Promise<void>
    // Terminal text for the trust terminal, 64 KiB or less.
    trustWrite(data: string): Promise<void>
    // The size of the trust terminal, from 2 to 500 for each value.
    trustResize(cols: number, rows: number): Promise<void>
    // Close the trust terminal.
    trustClose(): Promise<void>
    // The output of the trust terminal. The returned function removes only this listener.
    onTrustData(cb: (chunk: string) => void): () => void
    // The trust terminal ended. trusted is true when Claude Code now trusts the repository.
    onTrustEnd(cb: (end: { repo: string; trusted: boolean }) => void): () => void
    // Delete the clones, worktrees and input folders of Bifrost. This also works while Watch
    // GitHub is off.
    removeClones(): Promise<void>
  }
  // The Daily update panel (Daily update design). The main process runs the drafts, keeps the
  // state of the day and shows the reminders. A call with an area ID rejects for an area that is
  // not on. A call with a bad value rejects and changes nothing.
  dailyUpdate: {
    snapshot(): Promise<DailySnapshot>
    // The main process sends each new snapshot. The returned function removes only this listener.
    onUpdate(cb: (s: DailySnapshot) => void): () => void
    // A click on a reminder. The area is the first area that is on and not sent, or null.
    onOpen(cb: (areaId: string | null) => void): () => void
    // Run the drafts. This resolves when the run ends, with false when no run started. 'open'
    // starts no run while a run runs, or within 5 minutes after the end of the last run.
    // 'button' starts a run unless a run runs.
    refresh(trigger: 'open' | 'button'): Promise<boolean>
    // Run the drafts as refresh does, and replace the draft of the area, also a changed one.
    redo(areaId: string): Promise<boolean>
    // Keep the text that the user changed. The text is Markdown, 20,000 characters or less.
    editDraft(areaId: string, text: string): Promise<void>
    // Use the newer draft of the area, or keep the changed draft.
    usePending(areaId: string): Promise<void>
    keepMine(areaId: string): Promise<void>
    // Mark the area as sent today, or undo the mark. The reminders stop when each area that is on
    // is sent.
    markSent(areaId: string): Promise<void>
    undoSent(areaId: string): Promise<void>
    // Skip today for all areas, or undo the skip.
    setSkipped(skipped: boolean): Promise<void>
    // Put the draft on the clipboard as plain text, as it is. This does not stop the reminders.
    copy(areaId: string): Promise<void>
    // Open the link of an item in the browser. The area ID '' is the list of the items that fit
    // no area. This rejects for an item with no https link.
    openItem(areaId: string, itemId: string): Promise<void>
    // The MCP servers of Claude Code and their tools. This can take up to 30 seconds. It rejects
    // with a friendly text.
    inventory(): Promise<McpInventory>
  }
  // The Performance panel (Performance design). The main process samples Bifrost, the Claude
  // sessions and the Mac every 15 s, and every 2 s while the panel shows.
  performance: {
    // The newest snapshot.
    snapshot(): Promise<PerformanceSnapshot>
    // The main process sends the snapshot after each sample, also while the panel is closed.
    // The returned function removes only this listener.
    onUpdate(cb: (s: PerformanceSnapshot) => void): () => void
    // Tell the main process if the panel shows, if the window has focus, and which chat panels
    // are open. Send it on each change. This rejects for a value that is not a chat panel ID.
    view(v: { showing: boolean; focused: boolean; chatPanels: string[] }): Promise<void>
    // The frame rate of the panel, once a second while it shows and the window has focus. This
    // rejects for a value that is not a finite number from 0 to 1000.
    fps(value: number): Promise<void>
    // Clear the past events from the headline: crashes, failed saves, a failed start of Live
    // details and failures in a row of the polls. The live measurements stay. The main process
    // then sends a new snapshot. The health.log file does not change.
    clear(): Promise<void>
  }
  // The window of the page.
  window: {
    // Tell the main process if the page is visible: false for a minimised or hidden window. The
    // main process then polls the sessions every 15 s, not every 2 s. An unfocused window that
    // is visible counts as visible. Send it when the page loads and on each change. This
    // rejects for a value that is not a boolean.
    setVisible(visible: boolean): Promise<void>
  }
  // The release notes of the GitHub releases. The main process reads GitHub only when a view opens,
  // and keeps a good answer 10 minutes. The page gets the parsed text, never the raw body.
  releaseNotes: {
    // The last 10 releases, newest first, or ok false when GitHub gave no good answer. This never
    // rejects for a bad answer.
    list(): Promise<ReleaseNotesResult>
    // Ask one time after the page loads. The answer is the What's new view to open, or null. Only
    // a release build can give a view, and only to the first call of the process.
    whatsNew(): Promise<WhatsNewStart | null>
    // Open a GitHub page in the browser: the page of the release with this version, or the
    // Releases page for null. This rejects for a version that the last list did not give.
    open(version: string | null): Promise<void>
  }
  // The updater (updater design). It runs only in a release build. In pnpm dev, in a test home and
  // in a local build, the snapshot has available false, and the other calls do nothing.
  updates: {
    // The newest snapshot.
    snapshot(): Promise<UpdatesSnapshot>
    // The main process sends each new snapshot. The returned function removes only this listener.
    onUpdate(cb: (s: UpdatesSnapshot) => void): () => void
    // Check one time, also when the switch is off. This resolves at once. The new state comes
    // through onUpdate.
    check(): Promise<void>
    // Install the ready update and restart Bifrost. This does nothing when no update is ready.
    restart(): Promise<void>
    // Open the update log in its default app (Console). This rejects with a message when it
    // cannot open the log.
    showLog(): Promise<void>
  }
  // Live details (D11). Each action resolves with the new status. It rejects with the message
  // of its failure. A switch calls install when plugin is not-installed, else enable or disable.
  live: {
    status(): Promise<LiveStatus>
    // Remove an old hook install, copy the mod folder, add the marketplace, install the plugin,
    // turn it on and listen. This rejects for Claude Code below 2.1.290. It also rejects before
    // any change when Bifrost cannot read the settings file.
    install(): Promise<LiveStatus>
    // Remove an old hook install, copy the mod folder, turn the plugin on and listen.
    // This rejects for Claude Code below 2.1.290 and when the plugin is not installed. It also
    // rejects before any change when Bifrost cannot read the settings file.
    enable(): Promise<LiveStatus>
    // Stop the server at once. Then turn the plugin off. A failure rejects, but the server
    // stays stopped.
    disable(): Promise<LiveStatus>
    // Stop the server. Remove the plugin, the marketplace of Bifrost, the mod folder and an old
    // hook install. When Bifrost cannot read the settings file, it does the other steps and then
    // rejects.
    uninstall(): Promise<LiveStatus>
  }
  // The Bifrost skills plugin (spec 5). Each action resolves with the new status. It rejects
  // with the message of its failure. A switch calls install when the plugin is not-installed,
  // else enable or disable.
  skills: {
    status(): Promise<SkillsStatus>
    // Copy the skills folder, add the marketplace, install the plugin and turn it on. This
    // rejects before any change when a marketplace bifrost-skills is at another path.
    install(): Promise<SkillsStatus>
    // Copy the skills folder again and turn the plugin on. This rejects when it is not installed.
    enable(): Promise<SkillsStatus>
    disable(): Promise<SkillsStatus>
    // Remove the plugin, the marketplace of Bifrost and the skills folder.
    uninstall(): Promise<SkillsStatus>
  }
  // The settings of spec 12. The main process keeps them in settings.json in userData (D1).
  settings: {
    get(): Promise<Settings>
    // Change the named settings. This resolves with all the settings after the change.
    // It rejects for an unknown key or a bad value, and then changes nothing.
    set(patch: SettingsPatch): Promise<Settings>
    // The main process sends the settings after each change.
    onChange(cb: (settings: Settings) => void): () => void
    // Tell the main process that the key recorder of Settings > Keys starts (true) or ends (false).
    // While it records, the menu gives its keys to the page. The main process ends it when the
    // page reloads or the window closes. It rejects for a value that is not a boolean.
    recording(on: boolean): Promise<void>
  }
  system: {
    // packaged is false in development. testHome is true with BIFROST_TEST_HOME (D12).
    info(): Promise<{ packaged: boolean; testHome: boolean; version: string }>
  }
  ui: {
    // The saved UI state, or null when the file is missing or damaged.
    load(): Promise<unknown>
    // Rejects when the value is not a plain object or is larger than 1 MB.
    save(data: unknown): Promise<void>
  }
  display: {
    get(): Promise<DisplayMode>
    // Rejects when the value is not a display mode.
    set(mode: DisplayMode): Promise<void>
    // The main process sends the new mode after each change of the real mode.
    onChange(cb: (mode: DisplayMode) => void): () => void
  }
  wm: {
    // The main process sends this event when the user chooses Close Panel (Cmd+W).
    onClosePanel(cb: () => void): () => void
  }
  pty: {
    // The main process opens a PTY only for a chat view and "attach <short id>".
    // The session must be owned and not parked, and it must be the session of the view.
    open(viewId: string, args: string[], opts: { cols: number; rows: number }): Promise<number>
    write(viewId: string, data: string): Promise<boolean>
    resize(viewId: string, cols: number, rows: number): Promise<void>
    close(viewId: string, signal?: string): Promise<void>
    // Each on* function returns a function that removes only that listener.
    onData(cb: (viewId: string, chunk: string) => void): () => void
    onExit(cb: (viewId: string, exitCode: number, signal?: number) => void): () => void
    // The main process sends the session size after a change that it reads from the TTY.
    onSize(cb: (viewId: string, size: TermSize) => void): () => void
    // The size of the session TTY, or null when the row is not owned or has no PID.
    sessionSize(sessionId: string): Promise<TermSize | null>
    // Tell the main process that the chat window shows the agent view (true) or not (false).
    // While a chat window shows the agent view, input.send to that session rejects.
    setBlocked(viewId: string, blocked: boolean): Promise<void>
    // Open a link of a chat window outside Bifrost: a web link in the default browser, a file
    // link in its default app. The main process refuses other links (main/pty/open-link.ts).
    openLink(uri: string): Promise<void>
  }
}
