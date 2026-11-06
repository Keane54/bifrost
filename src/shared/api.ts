import type { DirInfo, NewSessionSpec } from './new-session'
import type {
  ClaudeVersion,
  DisplayMode,
  InstallPreview,
  IntegrationStatus,
  LiveStatus,
  Priority,
  ProjectApp,
  ProjectAppId,
  ResumeAllResult,
  SeenCounts,
  SessionRow,
  TermSize,
  WatchColour,
  WorktreeCheck,
} from './types'

// The type of window.bifrost. The preload script implements it.
// When a call fails in the main process, it rejects with an Error.
// The message of that Error is the message of the failure.
export interface BifrostApi {
  claudePath(): Promise<string | null>
  claudeVersion(): Promise<ClaudeVersion>
  registry: {
    rows(): Promise<SessionRow[]>
    // Stop the flash of the box of the session.
    acknowledge(sessionId: string): Promise<void>
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
  actions: {
    // The installed apps that can open a project. The list has no paths.
    apps(): Promise<ProjectApp[]>
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
  integration: {
    status(): Promise<IntegrationStatus>
    preview(): Promise<InstallPreview>
    // install and uninstall reject when the settings file is not valid.
    install(): Promise<IntegrationStatus>
    uninstall(): Promise<IntegrationStatus>
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
    // This rejects when the plugin is not installed. It also rejects before any change when
    // Bifrost cannot read the settings file.
    enable(): Promise<LiveStatus>
    // Stop the server at once. Then turn the plugin off. A failure rejects, but the server
    // stays stopped.
    disable(): Promise<LiveStatus>
    // Stop the server. Remove the plugin, the marketplace of Bifrost, the mod folder and an old
    // hook install. When Bifrost cannot read the settings file, it does the other steps and then
    // rejects.
    uninstall(): Promise<LiveStatus>
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
    open(
      viewId: string,
      args: string[],
      opts: { cwd: string; cols: number; rows: number },
    ): Promise<number>
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
  }
}
