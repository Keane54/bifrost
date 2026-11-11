import { randomUUID } from 'node:crypto'
import { cleanAlias } from '../../shared/alias'
import type {
  Priority,
  RateLimits,
  RateWindow,
  SessionKind,
  SessionRow,
  UsageSnapshot,
  WatchColour,
} from '../../shared/types'
import { worktreeRoot } from '../../shared/worktree'
import type { AgentEntry } from '../claude/agents'
import type { LiveUsage } from '../live/live-event'
import { modelName } from '../live/model-name'
import type { HookEvent } from './hook-event'
import {
  INITIAL_STATE,
  type MachineState,
  onHookEvent,
  onParked,
  onStatus,
  onTick,
  withoutYellow,
} from './state-machine'
import type { TerminalApp } from './terminal-app'

// The data that the registry saves between runs of Bifrost. Each key is a row ID (spec 6.1).
export interface RegistryStore {
  // The local name of each session. Bifrost shows it and never sends it to Claude Code.
  aliases: Record<string, string>
  // The current ID of each row whose current ID is not its row ID. A /clear gives the process a
  // new session ID. A restart finds the row of that ID with this map.
  current: Record<string, string>
  // The short ID of each background row. A restart finds the row of a job with it, also after a
  // /clear changed the session ID of the job.
  jobs: Record<string, string>
  // The sessions that ran in the last run. Resume all uses them.
  lastActive: string[]
  names: Record<string, string>
  // The row IDs of the review sessions for PRs. They get no yellow box.
  prSessions?: string[]
  started: string[]
  priorities: Record<string, Priority>
  // The watched sessions. The array order is the order of the watchlist.
  watch: { sessionId: string; colour: WatchColour }[]
  // The worktree root of each session, from a sample while the session ran.
  worktrees: { sessionId: string; path: string }[]
}

// The store fields that an older store can lack.
type OptionalStoreKey =
  | 'aliases'
  | 'current'
  | 'jobs'
  | 'priorities'
  | 'lastActive'
  | 'watch'
  | 'worktrees'

// A state event for an unknown session waits this long for the session to show.
export const PENDING_EVENT_MS = 60_000

// A session is live for this long after its last line of the mod, in milliseconds.
// The mod sends a usage line each 30 s, so a live idle session stays live.
export const LIVE_FRESH_MS = 90_000

// A session that is not active stays in lastActive this long, in milliseconds.
export const LAST_ACTIVE_GRACE_MS = 60_000

// The registry forgets a session after this many counted --all lists without it (Task 17 bug 3).
// A list that does not count does not change the count. forgetGone gives the rules that set the
// count back to 0.
export const GONE_LISTS = 2

// The data that the registry keeps for one session.
// sessionId is the row ID: the first session ID that Bifrost saw for the session (spec 6.1). It
// never changes. The current ID is in the currents map of the registry.
interface Session {
  sessionId: string
  shortId?: string
  // The original session ID of the job: the ID of an active entry that starts with the short ID,
  // or the ID of the --all entry of the stopped job. A stopped job shows its original session ID
  // in --all (test of 2026-11-06). A resume by this ID wakes the same job.
  jobId?: string
  kind: SessionKind
  pid?: number
  cwd: string
  status: string
  waitingFor?: string
  startedAt: number
  // The time of the last applied state event. The value is 0 if no event came.
  lastEventAt: number
  // The seq of the last applied state event, if it had one.
  lastEventSeq?: number
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
// The order is: the entry name, the stored name, the short id, and the first 8 characters of
// the session id.
// The store always holds the last real entry name. So the stored name gives the first two steps.
function rowName(sessionId: string, stored?: string, shortId?: string) {
  for (const name of [stored, shortId]) {
    if (name) return name
  }
  return sessionId.slice(0, 8)
}

// Return true when the event is older than the last applied event of the session (D4).
// Each line of the mod is its own request, so two lines can arrive in the other order.
// For two events with the same time, the seq gives the order when both events have one.
function isOlder(ev: HookEvent, s: Session): boolean {
  if (ev.at !== s.lastEventAt) return ev.at < s.lastEventAt
  return ev.seq !== undefined && s.lastEventSeq !== undefined && ev.seq <= s.lastEventSeq
}

// The same place in the main checkout for a folder in a worktree. Other folders stay the same.
function checkoutPlace(cwd: string): string {
  const root = worktreeRoot(cwd)
  return root === null ? cwd : root.repo + cwd.slice(root.worktree.length)
}

// True when two folders can be the folder of one job. A stopped job reports its start folder,
// and a running job can be in a worktree of that folder (M4 controller check). An empty folder
// is not known, so it does not block.
function sameFolder(a: string, b: string): boolean {
  return a === '' || b === '' || checkoutPlace(a) === checkoutPlace(b)
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

// Two rate window readings with resetsAt values within this time are the same window.
const WINDOW_SAME_MS = 10 * 60 * 1000

// True when the use value a is higher than b. A value that is not a finite number never wins
// over a finite one.
function beats(a: number, b: number): boolean {
  if (!Number.isFinite(a)) return false
  return !Number.isFinite(b) || a > b
}

// The last usage line of a session. updatedAt is the time of the line.
// A line without rate limits keeps the rate limits of the session. limitsAt is the time of the
// line that had them.
interface Usage extends LiveUsage {
  updatedAt: number
  limitsAt?: number
}

// The row of an entry of a list. isNew is true for a row that the entry starts.
interface Match {
  entry: AgentEntry
  rowId: string
  isNew: boolean
}

// Merge the session list, the state events and the usage lines of the mod, and the git branches
// into rows. Each session has its own state machine.
export class SessionRegistry {
  // The time from a yellow box to the escalation to red. 0 stops the escalation.
  private escalationMs: number
  private readonly names: Map<string, string>
  private readonly started: Set<string>
  // The row IDs of the PR sessions. A PR session gets no yellow box and no escalation.
  private readonly prSessions: Set<string>
  private readonly aliases: Map<string, string>
  private readonly priorities: Map<string, Priority>
  // The watch colour of each watched session. The Map order is the watchlist order.
  private readonly watched: Map<string, WatchColour>
  // The worktree root of each session that ran in a worktree. A stopped session reports its
  // start folder as its cwd (M4 controller check). So the registry keeps the root.
  private readonly worktrees: Map<string, string>
  // The current ID of each row whose current ID is not its row ID. byCurrent is the reverse map.
  private readonly currents: Map<string, string>
  private readonly byCurrent = new Map<string, string>()
  // The short ID of each background row.
  private readonly jobs: Map<string, string>
  // The sessions with a process in the last samples. The store keeps them.
  private readonly lastActive: Set<string>
  // The sessions of lastActive at the start. Resume all can resume them. Not saved.
  private readonly resumable: Set<string>
  // The sample time when a session of lastActive was first not active.
  private readonly inactiveSince = new Map<string, number>()
  // The count of the counted --all lists without the session, since the count went back to 0
  // (forgetGone). A list that does not count leaves the count as it is.
  private readonly missing = new Map<string, number>()
  // The terminal app for each PID. null means that the PID has no app.
  private readonly terminals = new Map<number, TerminalApp | null>()
  private changed = false
  private readonly sessions = new Map<string, Session>()
  // The row IDs of the last active list.
  private active = new Set<string>()
  // The session IDs of the entries of the last active list.
  private lastSample = new Set<string>()
  // The background session ids of the last counted --all list, and of each later --all list
  // that did not count. A list that does not count adds its IDs and removes none.
  private all = new Set<string>()
  // The session ids of the background entries of the last active list.
  private activeBackground = new Set<string>()
  // State events for sessions that did not show yet.
  private pending: HookEvent[] = []
  // The time of the newest line of the mod for each session. The map also keeps sessions that
  // did not show yet.
  private readonly liveAt = new Map<string, number>()
  // The newest usage line for each session. The map also keeps sessions that did not show yet.
  private readonly usageLines = new Map<string, Usage>()
  // The newest time that applyAgents, applyEvents, applyUsage or tick got.
  private clock = 0
  private readonly branches = new Map<string, string>()

  // A store without aliases, current, jobs, priorities, lastActive, watch or worktrees (from an
  // older version) is valid.
  constructor(opts: {
    store: Omit<RegistryStore, OptionalStoreKey> & Partial<Pick<RegistryStore, OptionalStoreKey>>
    escalationMs: number
  }) {
    this.escalationMs = opts.escalationMs
    this.jobs = new Map(Object.entries(opts.store.jobs ?? {}))
    this.currents = new Map()
    for (const [rowId, id] of Object.entries(opts.store.current ?? {})) {
      // A current ID equal to the row ID is the default. When two rows have one current ID, the
      // first one gets its live lines until the next active list.
      if (id === rowId) continue
      this.currents.set(rowId, id)
      if (!this.byCurrent.has(id)) this.byCurrent.set(id, rowId)
    }
    this.names = new Map(Object.entries(opts.store.names))
    this.started = new Set(opts.store.started)
    this.prSessions = new Set(opts.store.prSessions ?? [])
    this.aliases = new Map(Object.entries(opts.store.aliases ?? {}))
    this.priorities = new Map(Object.entries(opts.store.priorities ?? {}) as [string, Priority][])
    this.watched = new Map((opts.store.watch ?? []).map(w => [w.sessionId, w.colour]))
    this.worktrees = new Map((opts.store.worktrees ?? []).map(w => [w.sessionId, w.path]))
    const last = opts.store.lastActive ?? []
    this.lastActive = new Set(last)
    this.resumable = new Set(last)
  }

  // Apply the output of "claude agents --json". sampledAt is the time when the poll started.
  // match gives the row of each entry. The session ID of the entry is the current ID of its row.
  applyAgents(entries: AgentEntry[], sampledAt: number): void {
    this.advance(sampledAt)
    const matches = this.match(entries, true)
    const ids = new Set(matches.map(m => m.rowId))
    for (const { entry, isNew, rowId } of matches) {
      const known = this.sessions.get(rowId)
      const s = known ?? this.add(rowId)
      // An entry with no pid has no process yet. A waking job can show its original ID then, so
      // only an entry with a pid, or a new row, sets the current ID (review M2).
      if (isNew || entry.pid !== undefined) this.setCurrent(rowId, entry.sessionId, ids)
      this.keepName(rowId, entry)
      this.keepJob(rowId, entry)
      // The status before this sample. A new session has none. A parked session has ''.
      const prevStatus = known?.status
      // A new status is activity. The first sample of a session is not a change.
      if (known && known.status !== entry.status) s.statusChangedAt = sampledAt
      // Without the mod, only the session list can clear the parked state.
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
      // The ID of a job that starts with its short ID is its original ID (review M4).
      if (entry.kind === 'background' && entry.id && entry.sessionId.startsWith(entry.id)) {
        s.jobId = entry.sessionId
      }
      this.setMachine(
        s,
        onStatus(s.machine, {
          live: this.liveOf(rowId),
          prevStatus,
          sampledAt,
          status: entry.status,
          waitingFor: entry.waitingFor,
        }),
      )
      this.keepWorktree(s)
    }
    for (const id of this.active) {
      if (!ids.has(id)) this.leave(id, sampledAt)
    }
    this.active = ids
    this.lastSample = new Set(entries.map(entry => entry.sessionId))
    this.activeBackground = new Set(
      matches.filter(m => m.entry.kind === 'background').map(m => m.rowId),
    )
    // A session in the active list exists. Its count of --all lists without it goes back to 0.
    for (const id of ids) this.missing.delete(id)
    this.parkStarted(sampledAt)
    this.trackLastActive(matches, sampledAt)
  }

  // Find the row of each entry of a list (spec 6.1). The rules come in this order:
  // 1. A background entry goes to the one row with its short ID (jobRow), when the folder agrees.
  //    Only one entry of the list can have that short ID. A /clear keeps the short ID of a job.
  // 2. An entry goes to a known row whose current ID is the session ID of the entry. A row with a
  //    short ID belongs to its job. Only an entry with that same short ID goes there. So a
  //    terminal that resumes the conversation of a stopped job gets its own row (review I1).
  // 3. Only with link (the active list): links finds a /clear of a session with no short ID.
  // 4. A new row. Its row ID is the session ID of the entry. When a row or a stored value has
  //    that ID already, the row ID is a new UUID.
  private match(entries: AgentEntry[], link: boolean): Match[] {
    const found = new Map<AgentEntry, Match>()
    // The entry that took each row in this list.
    const taken = new Map<string, AgentEntry>()
    const take = (entry: AgentEntry, rowId: string, isNew: boolean): void => {
      found.set(entry, { entry, isNew, rowId })
      taken.set(rowId, entry)
    }
    const shortIds = new Map<string, number>()
    for (const { id } of entries) if (id) shortIds.set(id, (shortIds.get(id) ?? 0) + 1)
    for (const entry of entries) {
      if (entry.kind !== 'background' || !entry.id || shortIds.get(entry.id) !== 1) continue
      const rowId = this.jobRow(entry.id)
      if (rowId === undefined || taken.has(rowId)) continue
      if (!sameFolder(this.sessions.get(rowId)?.cwd ?? '', entry.cwd)) continue
      take(entry, rowId, false)
    }
    for (const entry of entries) {
      if (found.has(entry)) continue
      for (const rowId of this.rowsOfCurrent(entry.sessionId)) {
        // Two entries with no short ID and one session ID share a row, as before.
        const by = taken.get(rowId)
        if (by !== undefined && (by.sessionId !== entry.sessionId || by.id || entry.id)) continue
        const job = this.jobs.get(rowId)
        if (job !== undefined && job !== entry.id) continue
        take(entry, rowId, false)
        break
      }
    }
    if (link) {
      for (const [entry, rowId] of this.links(entries, found, taken)) take(entry, rowId, false)
    }
    // The new rows of this list, by session ID. Two entries with one session ID share a row.
    const added = new Map<string, string>()
    for (const entry of entries) {
      if (found.has(entry)) continue
      const id = entry.sessionId
      const free = !taken.has(id) && !this.isKnown(id)
      const rowId = added.get(id) ?? (free ? id : randomUUID())
      added.set(id, rowId)
      take(entry, rowId, true)
    }
    return entries.map(entry => found.get(entry) as Match)
  }

  // Rule 3 of match: a /clear of a session with no short ID (an interactive session) gives the
  // same process a new session ID (spec 6.1). Link the entry to a row when all of these are true:
  // - The entry has no short ID, a positive pid and a folder. Its session ID is not the current
  //   ID of a known row.
  // - The row has no short ID, the same pid and the same folder.
  // - The current ID of the row was in the last active list and is not in this list.
  // - One entry matches one row, and one row matches one entry. Any other case links nothing.
  private links(
    entries: AgentEntry[],
    found: Map<AgentEntry, Match>,
    taken: Map<string, AgentEntry>,
  ): [AgentEntry, string][] {
    const sample = new Set(entries.map(entry => entry.sessionId))
    const pairs: [AgentEntry, string][] = []
    for (const entry of entries) {
      const { pid } = entry
      if (found.has(entry) || entry.id || pid === undefined || !(pid > 0) || entry.cwd === '') {
        continue
      }
      if (this.rowsOfCurrent(entry.sessionId).length > 0) continue
      for (const s of this.sessions.values()) {
        const current = this.currentOf(s.sessionId)
        if (taken.has(s.sessionId) || s.shortId !== undefined) continue
        if (!this.lastSample.has(current) || sample.has(current)) continue
        if (s.pid === pid && s.cwd === entry.cwd) pairs.push([entry, s.sessionId])
      }
    }
    const once = <T>(values: T[], value: T): boolean => values.filter(v => v === value).length === 1
    const pairEntries = pairs.map(pair => pair[0])
    const pairRows = pairs.map(pair => pair[1])
    return pairs.filter(([entry, rowId]) => once(pairEntries, entry) && once(pairRows, rowId))
  }

  // The one row of the job with this short ID: the row with that short ID in jobs. When no row
  // has it, the one known row whose row ID starts with the short ID, has no short ID and has its
  // row ID as its current ID. The short ID is the first 8 characters of the original session ID
  // of the job (section 4), so that row is the job before a /clear, for example a row of an older
  // store (review M6). undefined when no row or more than one row matches.
  private jobRow(shortId: string): string | undefined {
    const owners = [...this.jobs].filter(([, id]) => id === shortId).map(([rowId]) => rowId)
    if (owners.length > 0) return owners.length === 1 ? owners[0] : undefined
    const prefix = `${shortId}-`
    const rows = new Set(
      [
        ...this.sessions.keys(),
        ...this.names.keys(),
        ...this.aliases.keys(),
        ...this.priorities.keys(),
        ...this.watched.keys(),
        ...this.worktrees.keys(),
        ...this.started,
        ...this.lastActive,
      ].filter(rowId => rowId.startsWith(prefix)),
    )
    const free = [...rows].filter(rowId => !this.jobs.has(rowId) && !this.currents.has(rowId))
    return free.length === 1 ? free[0] : undefined
  }

  // True when the registry has a row or a stored value with this row ID.
  private isKnown(rowId: string): boolean {
    return (
      this.sessions.has(rowId) ||
      this.names.has(rowId) ||
      this.aliases.has(rowId) ||
      this.priorities.has(rowId) ||
      this.watched.has(rowId) ||
      this.worktrees.has(rowId) ||
      this.started.has(rowId) ||
      this.lastActive.has(rowId) ||
      this.jobs.has(rowId) ||
      this.currents.has(rowId)
    )
  }

  // The current ID of a row.
  private currentOf(rowId: string): string {
    return this.currents.get(rowId) ?? rowId
  }

  // The row ID of the row whose current ID is sessionId. The row can be a stored row only.
  // undefined when sessionId is the row ID of a row with another current ID. Then sessionId is the
  // old conversation of that row, for example the ID before a /clear.
  private rowOf(sessionId: string): string | undefined {
    const rowId = this.byCurrent.get(sessionId)
    if (rowId !== undefined) return rowId
    return this.currents.has(sessionId) ? undefined : sessionId
  }

  // The row ID that the Event log and the Usage HUD use for a session ID of the mod. The old
  // conversation of a row also gives that row. An unknown ID stays as it is.
  rowIdOf(sessionId: string): string {
    return this.byCurrent.get(sessionId) ?? sessionId
  }

  // The known rows whose current ID is id. Two processes can run one conversation, so more than
  // one row can have it. The row that gets the live lines of id comes first.
  private rowsOfCurrent(id: string): string[] {
    const rows = new Set<string>()
    const owner = this.rowOf(id)
    if (owner !== undefined && this.isKnown(owner)) rows.add(owner)
    for (const [rowId, current] of this.currents) if (current === id) rows.add(rowId)
    if (!this.currents.has(id) && this.isKnown(id)) rows.add(id)
    return [...rows]
  }

  // True when the row gets the live lines of its current ID.
  private ownsCurrent(rowId: string): boolean {
    return this.rowOf(this.currentOf(rowId)) === rowId
  }

  // True when the row gets the live lines of its current ID and the mod sent one recently.
  private liveOf(rowId: string): boolean {
    return this.ownsCurrent(rowId) && this.isLive(this.currentOf(rowId))
  }

  // Make id the current ID of a row. listed holds the rows of this active list.
  // The live lines of id go to one row only. A row that has them keeps them while the list has
  // it. Another row takes them only when the list does not have that row. So two processes of one
  // conversation do not move the lines at each poll (review M5).
  // The process or the job of the old ID now runs the new ID. So the time of the newest line of
  // the mod carries over, and the state events that wait for the new ID apply to the row.
  private setCurrent(rowId: string, id: string, listed: ReadonlySet<string>): void {
    const old = this.currentOf(rowId)
    if (old !== id) {
      if (id === rowId) this.currents.delete(rowId)
      else this.currents.set(rowId, id)
      if (this.byCurrent.get(old) === rowId) this.byCurrent.delete(old)
      this.changed = true
      const at = this.liveAt.get(old)
      if (at !== undefined) this.touch(id, at)
    }
    const owner = this.rowOf(id)
    if (owner === rowId) return
    if (owner !== undefined && this.isKnown(owner) && listed.has(owner)) return
    if (id === rowId) this.byCurrent.delete(id)
    else this.byCurrent.set(id, rowId)
    const s = this.sessions.get(rowId)
    if (s) this.applyPending(s, id)
  }

  // Keep the --all ID of a stopped job. An ID that starts with the short ID is the original ID.
  // Another ID only fills an empty value, so it never replaces the original ID.
  private keepJobId(s: Session, entry: AgentEntry): void {
    if (s.jobId === undefined || (entry.id && entry.sessionId.startsWith(entry.id))) {
      s.jobId = entry.sessionId
    }
  }

  // Keep the short ID of a background row.
  private keepJob(rowId: string, entry: AgentEntry): void {
    if (entry.kind !== 'background' || !entry.id || this.jobs.get(rowId) === entry.id) return
    this.jobs.set(rowId, entry.id)
    this.changed = true
  }

  // A background entry with a pid is active. The other sessions of lastActive start a grace time.
  private trackLastActive(matches: Match[], sampledAt: number): void {
    const running = new Set<string>()
    for (const { entry, rowId } of matches) {
      if (entry.kind !== 'background' || entry.pid === undefined) continue
      running.add(rowId)
      if (!this.lastActive.has(rowId)) {
        this.lastActive.add(rowId)
        this.changed = true
      }
      this.resumable.delete(rowId)
      this.inactiveSince.delete(rowId)
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
  // (Task 18 fix round 1, M1 and M2). A list with no background entry also does not count while
  // the registry knows a parked owned session (final review M1). The background service can
  // start slowly, for example after a restart of the computer. A list that does not count only
  // adds rows and names. Its background IDs join the IDs of all, so leave() parks those sessions.
  // match gives the row of each background entry. A stopped job shows its original session ID
  // here, and its short ID gives its row (spec 6.1). This list does not change a current ID.
  applyAllAgents(entries: AgentEntry[], complete: boolean): void {
    // An interactive session that ended must not come back as a parked row.
    // So the registry uses only the background entries.
    const owned = entries.filter(entry => entry.kind === 'background')
    // A running entry that needs a new row ID waits for the active list, which gives its row. An
    // ID from this list would be another new ID, so its values would go to no row.
    const matches = this.match(owned, false).filter(
      m => !(m.isNew && m.rowId !== m.entry.sessionId && m.entry.pid !== undefined),
    )
    const ownedIds = matches.map(m => m.rowId)
    const listed = new Set(ownedIds)
    for (const entry of entries) {
      if (entry.kind !== 'background') listed.add(this.rowIdOf(entry.sessionId))
    }
    const counts =
      complete &&
      entries.length > 0 &&
      [...this.activeBackground].every(id => listed.has(id)) &&
      (owned.length > 0 || !this.knowsParkedOwned())
    this.all = counts ? new Set(ownedIds) : new Set([...this.all, ...ownedIds])
    for (const { entry, isNew, rowId } of matches) {
      this.keepName(rowId, entry)
      this.keepJob(rowId, entry)
      // An entry with a pid has a process. The active list gives its data.
      if (entry.pid !== undefined || this.active.has(rowId)) continue
      const s = this.sessions.get(rowId) ?? this.add(rowId)
      if (isNew) this.setCurrent(rowId, entry.sessionId, this.active)
      copyEntry(s, entry)
      this.keepJobId(s, entry)
      this.park(s)
    }
    if (counts) this.forgetGone(listed)
  }

  // Apply state events. An event goes to the row whose current ID is its session ID. An event for
  // an unknown session waits until the session shows. An event of the old conversation of a row
  // also waits, and the registry drops it after PENDING_EVENT_MS.
  // Each event makes its session live. applyEvent skips an event that is older than the last
  // applied event of the session (D4).
  applyEvents(events: HookEvent[], now: number): void {
    this.advance(now)
    for (const ev of events) {
      this.touch(ev.sessionId, ev.at)
      const rowId = this.rowOf(ev.sessionId)
      const s = rowId === undefined ? undefined : this.sessions.get(rowId)
      if (s) this.applyEvent(s, ev)
      else this.pending.push(ev)
    }
    this.dropOldEvents(now)
  }

  // Keep the newest usage line of a session. The session can be unknown. Then its row gets the
  // usage when it shows. A usage line is not activity (D8), so it does not change lastEventAt.
  // A line without rate limits keeps the last rate limits of the session and their time. Only a
  // line with rate limits replaces them.
  applyUsage(sessionId: string, usage: LiveUsage, at: number): void {
    this.advance(at)
    this.touch(sessionId, at)
    const old = this.usageLines.get(sessionId)
    if (old !== undefined && at < old.updatedAt) return
    const line: Usage = { ...usage, updatedAt: at }
    if (line.rateLimits !== undefined) line.limitsAt = at
    else if (old?.rateLimits !== undefined) {
      line.rateLimits = old.rateLimits
      line.limitsAt = old.limitsAt
    }
    this.usageLines.set(sessionId, line)
  }

  // Return the newest value of each window (fiveHour, sevenDay), chosen on its own from the usage
  // lines of all sessions. A session that is not a row also counts. Each Claude Code process keeps
  // the rate limits of its own last reply, so an idle session sends old values with a new time.
  // So the time of the line says nothing about the data. The choice is:
  // 1. The newest window wins: the reading with the latest resetsAt.
  // 2. Two readings with resetsAt values within WINDOW_SAME_MS are the same window.
  // 3. In the same window, the highest usedPercent wins, because use only grows in a window.
  //    A value that is not a finite number never wins over a finite one.
  // name, sessionId and updatedAt come from the line that gave the 7-day value, else the 5-hour
  // value. The name is the row name, or the first 8 characters of the session ID when the session
  // is not a row. The session ID is the row ID of a row. updatedAt is the time of that line.
  // Return null when no session has a window.
  usage(): UsageSnapshot | null {
    const fiveHour = this.pickWindow('fiveHour')
    const sevenDay = this.pickWindow('sevenDay')
    const source = sevenDay ?? fiveHour
    if (source === null) return null
    const limits: RateLimits = {}
    if (fiveHour !== null) limits.fiveHour = fiveHour.window
    if (sevenDay !== null) limits.sevenDay = sevenDay.window
    const s = this.sessions.get(this.rowIdOf(source.sessionId))
    return {
      limits,
      name: s ? this.shownName(s) : source.sessionId.slice(0, 8),
      sessionId: s ? s.sessionId : source.sessionId,
      updatedAt: source.at,
    }
  }

  // Choose the reading of one window, by the rules of usage().
  private pickWindow(
    key: 'fiveHour' | 'sevenDay',
  ): { window: RateWindow; sessionId: string; at: number } | null {
    const readings: { window: RateWindow; sessionId: string; at: number }[] = []
    for (const [sessionId, line] of this.usageLines) {
      const window = line.rateLimits?.[key]
      if (window === undefined || line.limitsAt === undefined) continue
      if (!Number.isFinite(window.resetsAt)) continue
      readings.push({ at: line.limitsAt, sessionId, window })
    }
    if (readings.length === 0) return null
    const latestReset = Math.max(...readings.map(r => r.window.resetsAt))
    let best: (typeof readings)[number] | null = null
    for (const r of readings) {
      if (r.window.resetsAt < latestReset - WINDOW_SAME_MS) continue
      if (
        best === null ||
        beats(r.window.usedPercent, best.window.usedPercent) ||
        (r.window.usedPercent === best.window.usedPercent && r.at > best.at)
      ) {
        best = r
      }
    }
    return best
  }

  // Return the number of rows that are live and not parked.
  liveCount(): number {
    let count = 0
    for (const s of this.sessions.values()) {
      if (s.machine.state !== 'parked' && this.liveOf(s.sessionId)) count += 1
    }
    return count
  }

  // Forget the time of the newest line of the mod for each session. Then no row is live, and the
  // poll yellow box (O3) applies again. The usage of each session stays.
  // Live details calls this after the server stops (Turn off and Remove).
  clearLive(): void {
    this.liveAt.clear()
  }

  // Set the branch of all rows with this cwd. null removes the branch.
  applyBranch(cwd: string, branch: string | null): void {
    if (branch === null) this.branches.delete(cwd)
    else this.branches.set(cwd, branch)
  }

  // Remove a session and all values that the registry keeps for it. sessionId is a row ID.
  // The lines of the mod of its row ID and its current ID go too, when no other row has that ID
  // as its current ID.
  forget(sessionId: string): void {
    const current = this.currentOf(sessionId)
    for (const id of new Set([sessionId, current])) {
      if (this.rowsOfCurrent(id).some(rowId => rowId !== sessionId)) continue
      this.pending = this.pending.filter(ev => ev.sessionId !== id)
      this.usageLines.delete(id)
      this.liveAt.delete(id)
    }
    if (this.byCurrent.get(current) === sessionId) this.byCurrent.delete(current)
    this.sessions.delete(sessionId)
    this.active.delete(sessionId)
    this.all.delete(sessionId)
    this.resumable.delete(sessionId)
    this.inactiveSince.delete(sessionId)
    this.missing.delete(sessionId)
    this.activeBackground.delete(sessionId)
    const removed = [
      this.started.delete(sessionId),
      this.prSessions.delete(sessionId),
      this.names.delete(sessionId),
      this.aliases.delete(sessionId),
      this.priorities.delete(sessionId),
      this.watched.delete(sessionId),
      this.worktrees.delete(sessionId),
      this.lastActive.delete(sessionId),
      this.currents.delete(sessionId),
      this.jobs.delete(sessionId),
    ]
    if (removed.some(Boolean)) this.changed = true
  }

  // Record a session as a review session for a PR. It gets no yellow box and no Resume all.
  markPrSession(sessionId: string): void {
    if (this.prSessions.has(sessionId)) return
    this.prSessions.add(sessionId)
    const s = this.sessions.get(sessionId)
    if (s) this.setMachine(s, s.machine)
    this.resumable.delete(sessionId)
    this.changed = true
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

  // Set the escalation time. The next tick uses it, also for a box that is already yellow.
  // 0 stops the escalation.
  setEscalationMs(ms: number): void {
    this.escalationMs = ms
  }

  tick(now: number): void {
    this.advance(now)
    for (const s of this.sessions.values()) {
      this.setMachine(s, onTick(s.machine, now, this.escalationMs))
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

  // Set the local name of a session. null removes it.
  // An empty name, and a name equal to the Claude Code name, also remove it.
  // Return false for a session that the registry does not know, and for a bad name.
  setAlias(sessionId: string, name: string | null): boolean {
    const s = this.sessions.get(sessionId)
    if (!s) return false
    let clean = ''
    if (name !== null) {
      const result = cleanAlias(name)
      if (!result.ok) return false
      clean = result.name
    }
    if (clean === '' || clean === this.nameOf(s)) {
      if (this.aliases.delete(sessionId)) this.changed = true
    } else if (this.aliases.get(sessionId) !== clean) {
      this.aliases.set(sessionId, clean)
      this.changed = true
    }
    return true
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
    const store: RegistryStore = {
      aliases: Object.fromEntries(this.aliases),
      current: Object.fromEntries(this.currents),
      jobs: Object.fromEntries(this.jobs),
      lastActive: [...this.lastActive],
      names: Object.fromEntries(this.names),
      priorities: Object.fromEntries(this.priorities),
      started: [...this.started],
      watch: [...this.watched].map(([sessionId, colour]) => ({ colour, sessionId })),
      worktrees: [...this.worktrees].map(([sessionId, path]) => ({ path, sessionId })),
    }
    // The key exists only when a PR session exists.
    if (this.prSessions.size > 0) store.prSessions = [...this.prSessions]
    return store
  }

  // Return true one time after a change to the store. Then return false until the next change.
  storeChanged(): boolean {
    const changed = this.changed
    this.changed = false
    return changed
  }

  // Add a session with the initial state. Apply the state events that wait for its current ID.
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
    this.applyPending(s, this.currentOf(sessionId))
    return s
  }

  // Apply the state events that wait for a session ID to a row.
  private applyPending(s: Session, id: string): void {
    const waiting = this.pending.filter(ev => ev.sessionId === id)
    if (waiting.length === 0) return
    this.pending = this.pending.filter(ev => ev.sessionId !== id)
    for (const ev of waiting) this.applyEvent(s, ev)
  }

  // Apply one state event. Skip an event that is older than the last applied event (D4).
  // A /clear keeps the process and gives it a new session ID, so its SessionEnd does not park the
  // row (review M3). The next active list links the new ID.
  private applyEvent(s: Session, ev: HookEvent): void {
    if (isOlder(ev, s)) return
    if (ev.name === 'SessionEnd' && ev.reason === 'clear') return
    this.setMachine(s, onHookEvent(s.machine, ev))
    s.lastEventAt = ev.at
    s.lastEventSeq = ev.seq
    if (ev.name === 'SessionEnd') s.parkedAt = Math.max(s.parkedAt, ev.at)
  }

  // Store the new machine state of a row. A PR session gets no yellow box (design 12.3).
  private setMachine(s: Session, machine: MachineState): void {
    s.machine = this.prSessions.has(s.sessionId) ? withoutYellow(machine) : machine
  }

  // Move the clock forward. The clock never goes back.
  private advance(at: number): void {
    this.clock = Math.max(this.clock, at)
  }

  // Keep the time of the newest line of the mod for a session.
  private touch(sessionId: string, at: number): void {
    this.liveAt.set(sessionId, Math.max(this.liveAt.get(sessionId) ?? at, at))
  }

  // A session ID is live when the mod sent a line for it in the last LIVE_FRESH_MS. A row is live
  // when its current ID is live.
  private isLive(sessionId: string): boolean {
    const at = this.liveAt.get(sessionId)
    return at !== undefined && this.clock - at <= LIVE_FRESH_MS
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

  private keepName(rowId: string, entry: AgentEntry): void {
    const name = realName(entry)
    if (name === undefined || this.names.get(rowId) === name) return
    this.names.set(rowId, name)
    this.changed = true
    // A local name equal to the new Claude Code name has no use. It would come back later.
    if (this.aliases.get(rowId) === name) this.aliases.delete(rowId)
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
  // local name, priority, watch colour, worktree, short ID or current ID. Each session with a usage
  // line or a line time of the mod is also in the list, so these two maps do not grow without
  // limit. A line of a current ID or of an old conversation counts for its row.
  // The count of a session goes back to 0 when the last active list has it, when this list has
  // its background entry, or when this list has an entry of any kind for a started session.
  // A failed Take control leaves a started session with an interactive entry (D6).
  // applyAgents also sets the count of each session in the active list to 0. A list that does not
  // count does not call this function. So it does not add to a count, and it does not reset one.
  private forgetGone(listed: Set<string>): void {
    const ids = new Set([
      ...this.started,
      ...this.names.keys(),
      ...this.aliases.keys(),
      ...this.priorities.keys(),
      ...this.watched.keys(),
      ...this.worktrees.keys(),
      ...this.jobs.keys(),
      ...this.currents.keys(),
    ])
    for (const id of [...this.usageLines.keys(), ...this.liveAt.keys()]) ids.add(this.rowIdOf(id))
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

  // True when the registry knows an owned session without a process: a parked owned row, or a
  // session of the last run that did not run again yet (resumable). lastActive has only
  // background sessions, so each resumable session is owned.
  private knowsParkedOwned(): boolean {
    if (this.resumable.size > 0) return true
    for (const s of this.sessions.values()) {
      if (s.kind === 'owned' && s.machine.state === 'parked') return true
    }
    return false
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

  // The session ID that resumes an owned row (spec 9.1). A stopped job wakes only by its original
  // session ID: the ID that starts with its short ID (test of 2026-11-06). A resume by another ID
  // starts a second job. So the ID is the --all ID of the stopped job, the row ID or the current
  // ID, the first one that starts with the short ID. When none does, it is the --all ID of the
  // stopped job. undefined when Bifrost does not know it yet. A row with no known short ID has
  // no job, so it uses its current ID: the conversation that it ran last (review M1).
  private resumeIdOf(s: Session): string | undefined {
    const short = s.shortId ?? this.jobs.get(s.sessionId)
    if (!short) return this.currentOf(s.sessionId)
    const ids = [s.jobId, s.sessionId, this.currentOf(s.sessionId)]
    return ids.find(id => id?.startsWith(short)) ?? s.jobId
  }

  // The name that Bifrost shows: the local name when one exists, else the Claude Code name.
  private shownName(s: Session): string {
    return this.aliases.get(s.sessionId) ?? this.nameOf(s)
  }

  private nameOf(s: Session): string {
    return rowName(s.sessionId, this.names.get(s.sessionId), s.shortId)
  }

  // The session ID of a row is its row ID. The usage and the live flag come from its current ID,
  // when the row gets the live lines of that ID.
  private toRow(s: Session): SessionRow {
    const m = s.machine
    const current = this.currentOf(s.sessionId)
    const usage = this.ownsCurrent(s.sessionId) ? this.usageLines.get(current) : undefined
    const row: SessionRow = {
      box: m.box,
      boxSince: m.boxSince,
      claudeName: this.nameOf(s),
      cwd: s.cwd,
      flashing: m.box !== 'none',
      kind: s.kind,
      // A usage line is not activity (D8).
      lastActivity: Math.max(s.startedAt, s.lastEventAt, s.statusChangedAt),
      name: this.shownName(s),
      sessionId: s.sessionId,
      startedAt: s.startedAt,
      state: m.state,
      status: s.status,
    }
    // The input code needs the cause of a red box. Only a prompt box blocks a send.
    if (m.box === 'red' && m.redReason !== undefined) row.boxReason = m.redReason
    if (current !== s.sessionId) row.currentId = current
    if (s.shortId !== undefined) row.shortId = s.shortId
    if (s.kind === 'owned') {
      const resumeId = this.resumeIdOf(s)
      if (resumeId !== undefined) row.resumeId = resumeId
    }
    if (s.pid !== undefined) row.pid = s.pid
    if (s.waitingFor !== undefined) row.waitingFor = s.waitingFor
    if (m.lastMessage !== undefined) row.lastMessage = m.lastMessage
    if (usage?.model !== undefined) row.model = modelName(usage.model)
    if (usage?.contextPercent !== undefined) row.contextPercent = usage.contextPercent
    if (usage?.costUsd !== undefined) row.costUsd = usage.costUsd
    if (usage?.contextWindow !== undefined) row.contextWindowSize = usage.contextWindow
    // The registry replaces a usage line and never changes it. So the row can share its limits.
    if (usage?.rateLimits !== undefined) row.rateLimits = usage.rateLimits
    if (usage?.version !== undefined) row.claudeVersion = usage.version
    if (usage?.effort !== undefined) row.effort = usage.effort
    if (usage?.permissionMode !== undefined) row.permissionMode = usage.permissionMode
    if (usage?.transcriptPath !== undefined) row.transcriptPath = usage.transcriptPath
    if (this.liveOf(s.sessionId)) row.live = true
    const branch = this.branches.get(this.branchDir(s))
    if (branch !== undefined) row.branch = branch
    const worktree = this.worktrees.get(s.sessionId)
    if (worktree !== undefined) row.worktree = worktree
    const priority = this.priorities.get(s.sessionId)
    if (priority !== undefined) row.priority = priority
    const colour = this.watched.get(s.sessionId)
    if (colour !== undefined)
      row.watch = { colour, order: [...this.watched.keys()].indexOf(s.sessionId) }
    if (this.prSessions.has(s.sessionId)) row.prSession = true
    if (m.state === 'parked' && this.resumable.has(s.sessionId) && !row.prSession) {
      row.resumable = true
    }
    if (s.kind === 'external' && s.pid !== undefined) {
      const app = this.terminals.get(s.pid)
      if (app) row.terminalApp = app.name
    }
    return row
  }
}
