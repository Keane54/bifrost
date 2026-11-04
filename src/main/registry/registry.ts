import type { SessionKind, SessionRow } from '../../shared/types'
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

// The data that the registry saves between runs of Bifrost.
export interface RegistryStore {
  names: Record<string, string>
  started: string[]
}

// A hook event for an unknown session waits this long for the session to show.
export const PENDING_EVENT_MS = 60_000

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
  private changed = false
  private readonly sessions = new Map<string, Session>()
  // The session ids of the last active list and of the last --all list.
  private active = new Set<string>()
  private all = new Set<string>()
  // Hook events for sessions that did not show yet.
  private pending: HookEvent[] = []
  private status = new Map<string, StatusData>()
  private readonly branches = new Map<string, string>()

  constructor(opts: { store: RegistryStore; escalationMs: number }) {
    this.escalationMs = opts.escalationMs
    this.names = new Map(Object.entries(opts.store.names))
    this.started = new Set(opts.store.started)
  }

  // Apply the output of "claude agents --json". sampledAt is the time when the poll started.
  applyAgents(entries: AgentEntry[], sampledAt: number): void {
    const ids = new Set(entries.map(entry => entry.sessionId))
    for (const entry of entries) {
      this.keepName(entry)
      const s = this.sessions.get(entry.sessionId) ?? this.add(entry.sessionId)
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
    }
    for (const id of this.active) {
      if (!ids.has(id)) this.leave(id, sampledAt)
    }
    this.active = ids
    this.parkStarted(sampledAt)
  }

  // Apply the output of "claude agents --json --all".
  // Call it only after a poll that did not fail.
  applyAllAgents(entries: AgentEntry[]): void {
    // An interactive session that ended must not come back as a parked row.
    // So the registry uses only the background entries.
    const owned = entries.filter(entry => entry.kind === 'background')
    this.all = new Set(owned.map(entry => entry.sessionId))
    for (const entry of owned) {
      this.keepName(entry)
      // An entry with a pid has a process. The active list gives its data.
      if (entry.pid !== undefined || this.active.has(entry.sessionId)) continue
      const s = this.sessions.get(entry.sessionId) ?? this.add(entry.sessionId)
      copyEntry(s, entry)
      this.park(s)
    }
    // A parked session that left --all goes away, if Bifrost did not start it.
    for (const s of this.sessions.values()) {
      if (s.machine.state === 'parked' && !this.known(s.sessionId)) {
        this.sessions.delete(s.sessionId)
      }
    }
    // Remove the names of sessions that left all lists. This limits the size of the store.
    for (const id of this.names.keys()) {
      if (this.known(id)) continue
      this.names.delete(id)
      this.changed = true
    }
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
  }

  acknowledge(sessionId: string): void {
    const s = this.sessions.get(sessionId)
    if (s) s.machine = onAcknowledge(s.machine)
  }

  // Return new row objects, sorted by startedAt, then by sessionId.
  rows(): SessionRow[] {
    return this.sorted().map(s => this.toRow(s))
  }

  // Return each cwd of the rows one time.
  // An empty cwd is not a directory. The list does not contain an empty cwd.
  cwds(): string[] {
    const cwds = new Set(this.sorted().map(s => s.cwd))
    cwds.delete('')
    return [...cwds]
  }

  // Return a copy of the store.
  store(): RegistryStore {
    return { names: Object.fromEntries(this.names), started: [...this.started] }
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

  private keepName(entry: AgentEntry): void {
    const name = realName(entry)
    if (name === undefined || this.names.get(entry.sessionId) === name) return
    this.names.set(entry.sessionId, name)
    this.changed = true
  }

  // Apply the rules for a session that left the active list.
  // An owned session stays as a parked row if it is in --all or if Bifrost started it.
  // All other sessions go away.
  private leave(sessionId: string, sampledAt: number): void {
    const s = this.sessions.get(sessionId)
    if (!s) return
    const keep = this.all.has(sessionId) || this.started.has(sessionId)
    if (s.kind === 'owned' && keep) this.park(s, sampledAt)
    else this.sessions.delete(sessionId)
  }

  // A session that Bifrost started and that is not active is parked.
  private parkStarted(sampledAt: number): void {
    for (const id of this.started) {
      if (!this.active.has(id) && !this.sessions.has(id)) this.park(this.add(id), sampledAt)
    }
  }

  // Return true if the session is in the active list, in the --all list or in the started list.
  private known(sessionId: string): boolean {
    return this.active.has(sessionId) || this.all.has(sessionId) || this.started.has(sessionId)
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
      lastActivity: Math.max(s.startedAt, s.lastEventAt, status?.updatedAt ?? 0),
      name: rowName(s.sessionId, this.names.get(s.sessionId), status?.sessionName, s.shortId),
      sessionId: s.sessionId,
      startedAt: s.startedAt,
      state: m.state,
      status: s.status,
    }
    if (s.shortId !== undefined) row.shortId = s.shortId
    if (s.pid !== undefined) row.pid = s.pid
    if (s.waitingFor !== undefined) row.waitingFor = s.waitingFor
    if (m.lastMessage !== undefined) row.lastMessage = m.lastMessage
    if (status?.model !== undefined) row.model = status.model
    if (status?.contextPercent !== undefined) row.contextPercent = status.contextPercent
    if (status?.costUsd !== undefined) row.costUsd = status.costUsd
    const branch = this.branches.get(s.cwd)
    if (branch !== undefined) row.branch = branch
    return row
  }
}
