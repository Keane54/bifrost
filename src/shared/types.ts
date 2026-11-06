// Types that the main process and the renderer share.

export interface ClaudeVersion {
  // The version that claude reports, or null when it did not report one.
  version: string | null
  // True when the version is at least the minimum.
  ok: boolean
  minimum: string
}

// The state of the Live details plugin in Claude Code.
// unknown: Bifrost could not read the plugin list.
export type LivePluginState = 'not-installed' | 'disabled' | 'enabled' | 'unknown'

export interface LiveStatus {
  plugin: LivePluginState
  // True when the mod folder has the files of this app and the plugin reads that folder.
  modCurrent: boolean
  // True when the settings still have a Bifrost hook or the Bifrost wrapper.
  oldInstall: boolean
  // True when Bifrost listens on the socket for the lines of the mod.
  listening: boolean
  // The number of rows that are live and not parked.
  liveSessions: number
  claudeVersion: string | null
  // True when the version of Claude Code is at least the minimum of Live details.
  versionOk: boolean
  error?: string
}

// The size of a terminal in cells.
export interface TermSize {
  cols: number
  rows: number
}

// The state of one session row.
export type SessionState = 'working' | 'needs-you' | 'error' | 'idle' | 'parked'

// The box of a row. Yellow: Claude finished. Red: Claude needs the user.
export type Box = 'none' | 'yellow' | 'red'

// The cause of a red box. prompt: a permission prompt or a question. escalated: an old yellow box.
// error: a StopFailure event.
export type BoxReason = 'prompt' | 'escalated' | 'error'

// Owned: the supervisor runs the session in the background. External: a terminal app owns it.
export type SessionKind = 'owned' | 'external'

// The priority of a session. 1 is the highest.
export type Priority = 1 | 2 | 3 | 4 | 5

// The colour of a watched session.
export type WatchColour =
  | 'dark-red'
  | 'red'
  | 'amber'
  | 'yellow'
  | 'green'
  | 'light-blue'
  | 'dark-blue'
  | 'white'

// What a check finds in the worktree of a session before a Delete.
// worktree is null when the session has no worktree under .claude/worktrees.
export interface WorktreeCheck {
  worktree: string | null
  branch: string | null
  changedFiles: number
  unmergedCommits: number
}

// The counts of the unmerged-work check that the Delete dialog showed (Task 15), and the
// worktree of that check (final review M2).
export type SeenCounts = Pick<WorktreeCheck, 'unmergedCommits' | 'changedFiles'> & {
  worktree: string
}

// One row of the session list. The main process sends rows to the renderer.
export interface SessionRow {
  sessionId: string
  shortId?: string
  name: string
  kind: SessionKind
  pid?: number
  cwd: string
  status: string
  waitingFor?: string
  state: SessionState
  box: Box
  // Only for a red box.
  boxReason?: BoxReason
  boxSince: number | null
  // True when the box is not 'none' and nobody acknowledged it.
  flashing: boolean
  lastMessage?: string
  lastActivity: number
  startedAt: number
  // model, contextPercent and costUsd come from the last usage line of the Live details mod.
  model?: string
  contextPercent?: number
  costUsd?: number
  // True when the Live details mod sent a line for the session in the last 90 s.
  live?: true
  branch?: string
  // The worktree root that Bifrost saw while the session ran. A stopped session reports its
  // start folder as its cwd, so this keeps the worktree of the session.
  worktree?: string
  priority?: Priority
  // Present for a watched session. order is the 0-based place in the watchlist.
  watch?: { colour: WatchColour; order: number }
  // True for a parked row that Resume all resumes.
  resumable?: true
  // The name of the terminal app of an external row.
  terminalApp?: string
}

// The result of Resume all. resumed counts the sessions whose entry showed.
// Each failure has the row name and the reason.
export interface ResumeAllResult {
  resumed: number
  failed: { name: string; error: string }[]
}

// How the Bifrost window shows on the screen.
// borderless is the simple full screen of macOS. fullscreen is the native full screen.
export type DisplayMode = 'window' | 'borderless' | 'fullscreen'

// An app that can open the project directory of a session.
export type ProjectAppId = 'finder' | 'vscode' | 'zed' | 'warp' | 'ghostty' | 'iterm2' | 'terminal'

export interface ProjectApp {
  id: ProjectAppId
  label: string
}

// One usage window of the plan. resetsAt is in milliseconds.
export interface RateWindow {
  usedPercent: number
  resetsAt: number
}

// The usage windows of the plan. A plan can lack a window.
export interface RateLimits {
  fiveHour?: RateWindow
  sevenDay?: RateWindow
}
