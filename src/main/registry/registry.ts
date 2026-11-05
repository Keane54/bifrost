import type { Priority, SessionKind, SessionRow, WatchColour } from '../../shared/types'
import { worktreeRoot } from '../../shared/worktree'
import type { AgentEntry } from '../claude/agents'
import type { HookEvent } from './hook-event'
import {
  INITIAL_STATE,
  type MachineState,
  onAcknowledge,
  onHookEvent,
  onParked,
  onStatus,
  onTick,
} from './state-machine'
import type { StatusData } from './status-file'
import type { TerminalApp } from './terminal-app'

// The data that the registry saves between runs of Bifrost.
export interface RegistryStore {
  // The sessions that ran in the last run. Resume all uses them.
  lastActive: string[]
  names: Record<string, string>
  started: string[]
  priorities: Record<string, Priority>
  // The watched sessions. The array order is the order of the watchlist.
  watch: { sessionId: string; colour: WatchColour }[]
  // The worktree root of each session, from a sample while the session ran.
  worktrees: { sessionId: string; path: string }[]
}

// A hook event for an unknown session waits this long for the session to show.
export const PENDING_EVENT_MS = 60_000

// A session that is not active stays in lastActive this long, in milliseconds.
export const LAST_ACTIVE_GRACE_MS = 60_000

// The registry forgets an owned or started session after this many --all lists in a row
// without it (Task 17 bug 3).
export const GONE_LISTS = 2

// The data that the registry keeps for one session.
interface Session {
  sessionId: string
  shortId?: string
  kind: SessionKind
  pid?: number
  cwd: string
  status: string
  waitingFor?: string
  startedAt: number
  // The time of the last hook event. The value is 0 if no event came.
  lastEventAt: number
  // The sample time of the last status change that the registry saw. The value is 0 if none.
  statusChangedAt: number
  // The time of the last park. A SessionEnd event or a list sample gives this time.
  parkedAt: number
  machine: MachineState
}

// Return the name of an entry that the registry can keep, or undefined.
// A new background entry first shows its short id as the name. That value is not a name.
function realName(entry: AgentEntry): string | undefined {
  return entry.name !== '' && entry.name !== entry.id ? entry.name : undefined
}

// Return the name of a row.
// The order is: the entry name, the stored name, the status file name, the short id,
// and the first 8 characters of the session id.
// The store always holds the last real entry name. So the stored name gives the first two steps.
function rowName(sessionId: string, stored?: string, sessionName?: string, shortId?: string) {
  for (const name of [stored, sessionName, shortId]) {
    if (name) return name
  }
  return sessionId.slice(0, 8)
}

function compareSessions(a: Session, b: Session): number {
  if (a.startedAt !== b.startedAt) return a.startedAt - b.startedAt
  if (a.sessionId === b.sessionId) return 0
  return a.sessionId < b.sessionId ? -1 : 1
}

// Copy the values of an entry to a session.
function copyEntry(s: Session, entry: AgentEntry): void {
  s.shortId = entry.id
  s.kind = entry.kind === 'background' ? 'owned' : 'external'
  s.pid = entry.pid
  s.cwd = entry.cwd
  s.status = entry.status
  s.waitingFor = entry.waitingFor
  s.startedAt = entry.startedAt
}

// Merge the session list, the hook events, the status files and the git branches into rows.
// Each session has its own state machine.
export class SessionRegistry {
  private readonly escalationMs: number
  private readonly names: Map<string, string>
  private readonly started: Set<string>
  private readonly priorities: Map<string, Priority>
  // The watch colour of each watched session. The Map order is the watchlist order.
  private readonly watched: Map<string, WatchColour>
  // The worktree root of each session that ran in a worktree. A stopped session reports its
  // start folder as its cwd (M4 controller check). So the registry keeps the root.
  private readonly worktrees: Map<string, string>
  // The sessions with a process in the last samples. The store keeps them.
  private readonly lastActive: Set<string>
  // The sessions of lastActive at the start. Resume all can resume them. Not saved.
  private readonly resumable: Set<string>
  // The sample time when a session of lastActive was first not active.
  private readonly inactiveSince = new Map<string, number>()
  // The count of the --all lists in a row that did not have the session.
  private readonly missing = new Map<string, number>()
  // The terminal app for each PID. null means that the PID has no app.
  private readonly terminals = new Map<number, TerminalApp | null>()
  private changed = false
  private readonly sessions = new Map<string, Session>()
  // The session ids of the last active list and of the last --all list. The --all set has only
  // the background entries.
  private active = new Set<string>()
  private all = new Set<string>()
  // The session ids of the background entries of the last active list.
  private activeBackground = new Set<string>()
  // Hook events for sessions that did not show yet.
  private pending: HookEvent[] = []
  private status = new Map<string, StatusData>()
  private readonly branches = new Map<string, string>()

  // A store without priorities, lastActive, watch or worktrees (from an older version) is valid.
  constructor(opts: {
    store: Omit<RegistryStore, 'priorities' | 'lastActive' | 'watch' | 'worktrees'> &
      Partial<Pick<RegistryStore, 'priorities' | 'lastActive' | 'watch' | 'worktrees'>>
    escalationMs: number
  }) {
    this.escalationMs = opts.escalationMs
    this.names = new Map(Object.entries(opts.store.names))
    this.started = new Set(opts.store.started)
    this.priorities = new Map(Object.entries(opts.store.priorities ?? {}) as [string, Priority][])
    this.watched = new Map((opts.store.watch ?? []).map(w => [w.sessionId, w.colour]))
    this.worktrees = new Map((opts.store.worktrees ?? []).map(w => [w.sessionId, w.path]))
    const last = opts.store.lastActive ?? []
    this.lastActive = new Set(last)
    this.resumable = new Set(last)
  }

  // Apply the output of "claude agents --json". sampledAt is the time when the poll started.
  applyAgents(entries: AgentEntry[], sampledAt: number): void {
    const ids = new Set(entries.map(entry => entry.sessionId))
    for (const entry of entries) {
      this.keepName(entry)
      const known = this.sessions.get(entry.sessionId)
      const s = known ?? this.add(entry.sessionId)
      // A new status is activity. The first sample of a session is not a change.
      if (known && known.status !== entry.status) s.statusChangedAt = sampledAt
      // Without hooks, only the session list can clear the parked state.
      // An entry without a pid has no process.
      // This occurs for a short time after a start or a stop.
      // A sample that started before the park is too old. It cannot clear the parked state.
      const restarted = entry.pid !== undefined && sampledAt > s.parkedAt
      if (s.machine.state === 'parked' && restarted) {
        s.machine = onHookEvent(s.machine, {
          at: sampledAt,
          name: 'SessionStart',
          sessionId: s.sessionId,
        })
      }
      copyEntry(s, entry)
      s.machine = onStatus(s.machine, {
        sampledAt,
        status: entry.status,
        waitingFor: entry.waitingFor,
      })
      this.keepWorktree(s)
    }
    for (const id of this.active) {
      if (!ids.has(id)) this.leave(id, sampledAt)
    }
    this.active = ids
    this.activeBackground = new Set(
      entries.filter(entry => entry.kind === 'background').map(entry => entry.sessionId),
    )
    // A session in the active list exists. Its count of --all lists without it goes back to 0.
    for (const id of ids) this.missing.delete(id)
    this.parkStarted(sampledAt)
    this.trackLastActive(entries, sampledAt)
  }

  // A background entry with a pid is active. The other sessions of lastActive start a grace time.
  private trackLastActive(entries: AgentEntry[], sampledAt: number): void {
    const running = new Set<string>()
    for (const entry of entries) {
      if (entry.kind !== 'background' || entry.pid === undefined) continue
      running.add(entry.sessionId)
      if (!this.lastActive.has(entry.sessionId)) {
        this.lastActive.add(entry.sessionId)
        this.changed = true
      }
      this.resumable.delete(entry.sessionId)
      this.inactiveSince.delete(entry.sessionId)
    }
    for (const id of this.lastActive) {
      if (!running.has(id) && !this.inactiveSince.has(id)) this.inactiveSince.set(id, sampledAt)
    }
  }

  // Apply the output of "claude agents --json --all".
  // Call it only after a poll that did not fail. complete is false when the parser skipped an
  // entry. Then the list can miss a session that exists.
  // Only a list that counts can remove a row or a stored value, through forgetGone. A list counts
  // when it is complete, not empty, and has each background session of the last active list
  // (Task 18 fix round 1, M1 and M2). A list that does not count only adds rows and names. Its
  // background IDs join the IDs of the last --all list, so leave() parks those sessions.
  applyAllAgents(entries: AgentEntry[], complete: boolean): void {
    const listed = new Set(entries.map(entry => entry.sessionId))
    const counts =
      complete && entries.length > 0 && [...this.activeBackground].every(id => listed.has(id))
    // An interactive session that ended must not come back as a parked row.
    // So the registry uses only the background entries.
    const owned = entries.filter(entry => entry.kind === 'background')
    const ownedIds = owned.map(entry => entry.sessionId)
    this.all = counts ? new Set(ownedIds) : new Set([...this.all, ...ownedIds])
    for (const entry of owned) {
      this.keepName(entry)
      // An entry with a pid has a process. The active list gives its data.
      if (entry.pid !== undefined || this.active.has(entry.sessionId)) continue
      const s = this.sessions.get(entry.sessionId) ?? this.add(entry.sessionId)
      copyEntry(s, entry)
      this.park(s)
    }
    if (counts) this.forgetGone(listed)
  }

  // Apply hook events. An event for an unknown session waits until the session shows.
  applyEvents(events: HookEvent[], now: number): void {
    for (const ev of events) {
      const s = this.sessions.get(ev.sessionId)
      if (s) this.applyEvent(s, ev)
      else this.pending.push(ev)
    }
    this.dropOldEvents(now)
  }

  // Keep the latest status file data. The key is the session id.
  applyStatusFiles(data: Map<string, StatusData>): void {
    this.status = new Map(data)
  }

  // Set the branch of all rows with this cwd. null removes the branch.
  applyBranch(cwd: string, branch: string | null): void {
    if (branch === null) this.branches.delete(cwd)
    else this.branches.set(cwd, branch)
  }

  // Remove a session and all values that the registry keeps for it.
  forget(sessionId: string): void {
    this.sessions.delete(sessionId)
    this.pending = this.pending.filter(ev => ev.sessionId !== sessionId)
    this.active.delete(sessionId)
    this.all.delete(sessionId)
    this.resumable.delete(sessionId)
    this.inactiveSince.delete(sessionId)
    this.missing.delete(sessionId)
    this.activeBackground.delete(sessionId)
    const removed = [
      this.started.delete(sessionId),
      this.names.delete(sessionId),
      this.priorities.delete(sessionId),
      this.watched.delete(sessionId),
      this.worktrees.delete(sessionId),
      this.lastActive.delete(sessionId),
    ]
    if (removed.some(Boolean)) this.changed = true
  }

  // A stopped session is no candidate for Resume all.
  markStopped(sessionId: string): void {
    if (this.lastActive.delete(sessionId)) this.changed = true
    this.resumable.delete(sessionId)
    this.inactiveSince.delete(sessionId)
  }

  // Merge the terminal apps by PID. Remove the PIDs that no external row has.
  applyTerminals(apps: Map<number, TerminalApp | null>): void {
    for (const [pid, app] of apps) this.terminals.set(pid, app)
    const pids = new Set<number>()
    for (const s of this.sessions.values()) {
      if (s.kind === 'external' && s.pid !== undefined) pids.add(s.pid)
    }
    for (const pid of this.terminals.keys()) {
      if (!pids.has(pid)) this.terminals.delete(pid)
    }
  }

  // Return the PIDs of the running external rows that have no terminal entry.
  pidsWithoutTerminal(): number[] {
    const pids: number[] = []
    for (const s of this.sorted()) {
      if (s.kind !== 'external' || s.machine.state === 'parked') continue
      if (s.pid !== undefined && !this.terminals.has(s.pid)) pids.push(s.pid)
    }
    return pids
  }

  // Return the terminal app of an external session, or undefined.
  terminalOf(sessionId: string): TerminalApp | undefined {
    const s = this.sessions.get(sessionId)
    if (s?.kind !== 'external' || s.pid === undefined) return undefined
    return this.terminals.get(s.pid) ?? undefined
  }

  // Record a session that Bifrost started.
  markStarted(sessionId: string): void {
    if (this.started.has(sessionId)) return
    this.started.add(sessionId)
    this.changed = true
  }

  tick(now: number): void {
    for (const s of this.sessions.values()) {
      s.machine = onTick(s.machine, now, this.escalationMs)
    }
    this.dropOldEvents(now)
    for (const id of this.lastActive) {
      const since = this.inactiveSince.get(id)
      if (since === undefined || now - since < LAST_ACTIVE_GRACE_MS) continue
      this.lastActive.delete(id)
      this.inactiveSince.delete(id)
      this.changed = true
    }
  }

  acknowledge(sessionId: string): void {
    const s = this.sessions.get(sessionId)
    if (s) s.machine = onAcknowledge(s.machine)
  }

  // Set the priority of a session. null removes it.
  // Return false for a session that the registry does not know.
  setPriority(sessionId: string, priority: Priority | null): boolean {
    if (!this.sessions.has(sessionId)) return false
    if (priority === null) {
      if (this.priorities.delete(sessionId)) this.changed = true
    } else if (this.priorities.get(sessionId) !== priority) {
      this.priorities.set(sessionId, priority)
      this.changed = true
    }
    return true
  }

  // Add a session to the end of the watchlist. A watched session only gets the new colour.
  // Return false for a session that the registry does not know.
  watchAdd(sessionId: string, colour: WatchColour): boolean {
    if (!this.sessions.has(sessionId)) return false
    if (this.watched.get(sessionId) !== colour) {
      this.watched.set(sessionId, colour)
      this.changed = true
    }
    return true
  }

  // Remove a session from the watchlist. Return false for a session that the registry does not know.
  watchRemove(sessionId: string): boolean {
    if (!this.sessions.has(sessionId)) return false
    if (this.watched.delete(sessionId)) this.changed = true
    return true
  }

  // Change the colour of a watched session. A session that is not watched stays as it is.
  // Return false for a session that the registry does not know.
  watchColour(sessionId: string, colour: WatchColour): boolean {
    if (!this.sessions.has(sessionId)) return false
    if (this.watched.has(sessionId) && this.watched.get(sessionId) !== colour) {
      this.watched.set(sessionId, colour)
      this.changed = true
    }
    return true
  }

  // Move a watched session before another watched session. null moves it to the end.
  // Return false if sessionId or beforeSessionId is not watched. Then nothing changes.
  watchMove(sessionId: string, beforeSessionId: string | null): boolean {
    const colour = this.watched.get(sessionId)
    if (colour === undefined) return false
    if (beforeSessionId !== null && !this.watched.has(beforeSessionId)) return false
    if (beforeSessionId === sessionId) return true
    const order = [...this.watched.keys()].filter(id => id !== sessionId)
    const index = beforeSessionId === null ? order.length : order.indexOf(beforeSessionId)
    order.splice(index, 0, sessionId)
    const before = [...this.watched.keys()]
    if (order.every((id, i) => id === before[i])) return true
    const colours = new Map(this.watched)
    this.watched.clear()
    for (const id of order) this.watched.set(id, colours.get(id) as WatchColour)
    this.changed = true
    return true
  }

  // Store the worktree root that claude rm names for a session. Bifrost did not see the
  // session run in it. Return false for an unknown session or a path that is not a worktree
  // root. Then nothing changes.
  rememberWorktree(sessionId: string, path: string): boolean {
    if (!this.sessions.has(sessionId) || worktreeRoot(path)?.worktree !== path) return false
    if (this.worktrees.get(sessionId) !== path) {
      this.worktrees.set(sessionId, path)
      this.changed = true
    }
    return true
  }

  // Return new row objects, sorted by startedAt, then by sessionId.
  rows(): SessionRow[] {
    return this.sorted().map(s => this.toRow(s))
  }

  // Return the folder of the branch read of each row one time. This is the cwd, or the stored
  // worktree when the cwd is not in a worktree.
  // An empty cwd is not a directory. The list does not contain an empty cwd.
  cwds(): string[] {
    const cwds = new Set(this.sorted().map(s => this.branchDir(s)))
    cwds.delete('')
    return [...cwds]
  }

  // Return a copy of the store.
  store(): RegistryStore {
    return {
      lastActive: [...this.lastActive],
      names: Object.fromEntries(this.names),
      priorities: Object.fromEntries(this.priorities),
      started: [...this.started],
      watch: [...this.watched].map(([sessionId, colour]) => ({ colour, sessionId })),
      worktrees: [...this.worktrees].map(([sessionId, path]) => ({ path, sessionId })),
    }
  }

  // Return true one time after a change to the store. Then return false until the next change.
  storeChanged(): boolean {
    const changed = this.changed
    this.changed = false
    return changed
  }

  // Add a session with the initial state. Apply the hook events that wait for it.
  private add(sessionId: string): Session {
    const s: Session = {
      cwd: '',
      kind: 'owned',
      lastEventAt: 0,
      machine: INITIAL_STATE,
      parkedAt: Number.NEGATIVE_INFINITY,
      sessionId,
      startedAt: 0,
      status: '',
      statusChangedAt: 0,
    }
    this.sessions.set(sessionId, s)
    const waiting = this.pending.filter(ev => ev.sessionId === sessionId)
    this.pending = this.pending.filter(ev => ev.sessionId !== sessionId)
    for (const ev of waiting) this.applyEvent(s, ev)
    return s
  }

  private applyEvent(s: Session, ev: HookEvent): void {
    s.machine = onHookEvent(s.machine, ev)
    s.lastEventAt = Math.max(s.lastEventAt, ev.at)
    if (ev.name === 'SessionEnd') s.parkedAt = Math.max(s.parkedAt, ev.at)
  }

  private dropOldEvents(now: number): void {
    this.pending = this.pending.filter(ev => now - ev.at <= PENDING_EVENT_MS)
  }

  // Store the worktree root of a session that is not parked and has a cwd in a worktree.
  private keepWorktree(s: Session): void {
    if (s.machine.state === 'parked') return
    const root = worktreeRoot(s.cwd)
    if (root === null || this.worktrees.get(s.sessionId) === root.worktree) return
    this.worktrees.set(s.sessionId, root.worktree)
    this.changed = true
  }

  // The folder for the branch read of a session. A stopped worktree session reports its start
  // folder, so the stored worktree gives its branch.
  private branchDir(s: Session): string {
    if (worktreeRoot(s.cwd) !== null) return s.cwd
    return this.worktrees.get(s.sessionId) ?? s.cwd
  }

  private keepName(entry: AgentEntry): void {
    const name = realName(entry)
    if (name === undefined || this.names.get(entry.sessionId) === name) return
    this.names.set(entry.sessionId, name)
    this.changed = true
  }

  // Apply the rules for a session that left the active list.
  // A session that Bifrost started stays as a parked row, whatever its kind.
  // An owned session in --all also stays. All other sessions go away.
  private leave(sessionId: string, sampledAt: number): void {
    const s = this.sessions.get(sessionId)
    if (!s) return
    const keep = (s.kind === 'owned' && this.all.has(sessionId)) || this.started.has(sessionId)
    if (keep) this.park(s, sampledAt)
    else this.sessions.delete(sessionId)
  }

  // Count each session that a counted --all list does not have. Forget the session after
  // GONE_LISTS counted lists in a row without it. This is the only forget that an --all list
  // gives (Task 17 bug 3, Task 18 fix round 1). It also limits the size of the store.
  // The sessions are the owned rows, the started sessions, and each session with a stored name,
  // priority, watch colour or worktree.
  // The count of a session goes back to 0 when the last active list has it, when this list has
  // its background entry, or when this list has an entry of any kind for a started session.
  // A failed Take control leaves a started session with an interactive entry (D6).
  // applyAgents also sets the count of each session in the active list to 0. A list that does not
  // count does not call this function. So it does not add to a count, and it does not reset one.
  private forgetGone(listed: Set<string>): void {
    const ids = new Set([
      ...this.started,
      ...this.names.keys(),
      ...this.priorities.keys(),
      ...this.watched.keys(),
      ...this.worktrees.keys(),
    ])
    for (const s of this.sessions.values()) {
      if (s.kind === 'owned') ids.add(s.sessionId)
    }
    for (const id of this.missing.keys()) {
      if (!ids.has(id)) this.missing.delete(id)
    }
    for (const id of ids) {
      const here =
        this.active.has(id) || this.all.has(id) || (this.started.has(id) && listed.has(id))
      if (here) {
        this.missing.delete(id)
        continue
      }
      const missing = (this.missing.get(id) ?? 0) + 1
      if (missing >= GONE_LISTS) this.forget(id)
      else this.missing.set(id, missing)
    }
  }

  // A session that Bifrost started and that is not active is parked.
  private parkStarted(sampledAt: number): void {
    for (const id of this.started) {
      if (!this.active.has(id) && !this.sessions.has(id)) this.park(this.add(id), sampledAt)
    }
  }

  // Park a session. A parked session has no process.
  // Remove the values that came from the active list.
  // A park from the --all list keeps the old park time. Only one list poll runs at a time.
  // So the next active sample is newer than the --all list.
  private park(s: Session, at?: number): void {
    if (at !== undefined) s.parkedAt = Math.max(s.parkedAt, at)
    s.machine = onParked(s.machine)
    s.pid = undefined
    s.status = ''
    s.waitingFor = undefined
  }

  private sorted(): Session[] {
    return [...this.sessions.values()].sort(compareSessions)
  }

  private toRow(s: Session): SessionRow {
    const m = s.machine
    const status = this.status.get(s.sessionId)
    const row: SessionRow = {
      box: m.box,
      boxSince: m.boxSince,
      cwd: s.cwd,
      flashing: m.box !== 'none' && !m.acknowledged,
      kind: s.kind,
      lastActivity: Math.max(s.startedAt, s.lastEventAt, s.statusChangedAt, status?.updatedAt ?? 0),
      name: rowName(s.sessionId, this.names.get(s.sessionId), status?.sessionName, s.shortId),
      sessionId: s.sessionId,
      startedAt: s.startedAt,
      state: m.state,
      status: s.status,
    }
    // The input code needs the cause of a red box. Only a prompt box blocks a send.
    if (m.box === 'red' && m.redReason !== undefined) row.boxReason = m.redReason
    if (s.shortId !== undefined) row.shortId = s.shortId
    if (s.pid !== undefined) row.pid = s.pid
    if (s.waitingFor !== undefined) row.waitingFor = s.waitingFor
    if (m.lastMessage !== undefined) row.lastMessage = m.lastMessage
    if (status?.model !== undefined) row.model = status.model
    if (status?.contextPercent !== undefined) row.contextPercent = status.contextPercent
    if (status?.costUsd !== undefined) row.costUsd = status.costUsd
    const branch = this.branches.get(this.branchDir(s))
    if (branch !== undefined) row.branch = branch
    const worktree = this.worktrees.get(s.sessionId)
    if (worktree !== undefined) row.worktree = worktree
    const priority = this.priorities.get(s.sessionId)
    if (priority !== undefined) row.priority = priority
    const colour = this.watched.get(s.sessionId)
    if (colour !== undefined)
      row.watch = { colour, order: [...this.watched.keys()].indexOf(s.sessionId) }
    if (m.state === 'parked' && this.resumable.has(s.sessionId)) row.resumable = true
    if (s.kind === 'external' && s.pid !== undefined) {
      const app = this.terminals.get(s.pid)
      if (app) row.terminalApp = app.name
    }
    return row
  }
}
