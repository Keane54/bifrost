import type { Priority, SessionRow, UsageSnapshot, WatchColour } from '../../shared/types'
import type { AgentList } from '../claude/agents'
import type { LiveEvent } from '../live/live-event'
import { type HealthEvents, NO_HEALTH } from '../performance/health-log'
import type { HookEvent } from './hook-event'
import type { RegistryStore, SessionRegistry } from './registry'
import { type ProcessTable, type TerminalApp, terminalAppOf } from './terminal-app'

// The service reads all data and does all writes through these functions.
export interface ServiceDeps {
  listActive(): Promise<AgentList>
  listAll(): Promise<AgentList>
  readBranch(cwd: string): Promise<string | null>
  readProcessTable(): Promise<ProcessTable | null>
  saveStore(store: RegistryStore): Promise<void>
  now(): number
  // The health log gets each active poll and each save (P5). The default does nothing.
  health?: Pick<HealthEvents, 'poll' | 'save'>
}

// The times of the loops and the minimum time between two updates, in milliseconds.
export const SERVICE_TIMING = {
  activeMs: 2000,
  allMs: 30_000,
  branchMs: 10_000,
  minUpdateGapMs: 250,
  tickMs: 1000,
}

interface RowWaiter {
  match: (row: SessionRow) => boolean
  resolve: (row: SessionRow) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}

type UpdateCallback = (rows: SessionRow[], error: string | null) => void
type UsageCallback = (usage: UsageSnapshot | null) => void
type EventsCallback = (events: HookEvent[]) => void

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Run the loops that give data to the registry. Send the rows after each change.
// The lines of the Live details mod come through pushLive.
export class RegistryService {
  private readonly timers = new Set<ReturnType<typeof setTimeout>>()
  private readonly health: Pick<HealthEvents, 'poll' | 'save'>
  private readonly callbacks: UpdateCallback[] = []
  private readonly usageCallbacks: UsageCallback[] = []
  private readonly eventCallbacks: EventsCallback[] = []
  // The newest rate limits of the last onUsage call, as JSON. The JSON has updatedAt, so a newer
  // line with the same limits is a change. The start value is that of no rate limits.
  private lastUsage = 'null'
  // True for minUpdateGapMs after each onUsage call. The rate limits have their own gap, with the
  // same time as the gap of the rows.
  private usageInGap = false
  // True when a usage check came during the gap of the rate limits.
  private usageCheckedInGap = false
  private waiters: RowWaiter[] = []
  // True while a process table read runs.
  private readingTable = false
  // The two list polls wait in this queue.
  // So only one "claude agents --json" process runs at a time.
  private queue: Promise<void> = Promise.resolve()
  // True while a save runs. Only one save runs at a time.
  private saving = false
  // True when the store changed after the start of the last save, or when that save failed.
  private storeToSave = false
  // True after a failed save, until a save is good again.
  private saveFailed = false
  // False until the first active poll ends. No update goes out before that time.
  private ready = false
  private started = false
  private stopped = false
  // The error of the last active poll. A good poll sets it to null.
  private error: string | null = null
  // True after a failed active poll, until the next update sends the error.
  private errorToSend = false
  // The rows and the error of the last update, as JSON.
  private lastSent = ''
  // True for minUpdateGapMs after each update.
  private inGap = false
  // True when a change came during the gap.
  private changedInGap = false

  // The wait between two active polls. setActiveInterval changes it.
  private activeMs: number

  constructor(
    private readonly registry: SessionRegistry,
    private readonly deps: ServiceDeps,
    private readonly timing: typeof SERVICE_TIMING = SERVICE_TIMING,
  ) {
    this.activeMs = timing.activeMs
    this.health = deps.health ?? NO_HEALTH
  }

  // Start all loops. A second call does nothing.
  // The --all loop, the branch loop and the tick loop start after the end of the first
  // active poll. So the registry has the active list before the first --all list,
  // and the first tick uses real rows.
  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    const t = this.timing
    this.loop(
      () => this.activeMs,
      () => this.queued(() => this.pollActive()),
      () => {
        this.loop(t.allMs, () => this.queued(() => this.pollAll()))
        this.loop(t.branchMs, () => this.readBranches())
        this.loop(t.tickMs, async () => this.tick())
      },
    )
  }

  // Set the wait between two active polls. The active loop reads it before each wait.
  // The poll that runs now ends normally. A wait that started already keeps its time.
  setActiveInterval(ms: number): void {
    this.activeMs = ms
  }

  // Stop all loops. A result that comes after this call has no effect.
  stop(): void {
    this.stopped = true
    for (const timer of this.timers) clearTimeout(timer)
    this.timers.clear()
    const waiters = this.waiters
    this.waiters = []
    for (const w of waiters) {
      clearTimeout(w.timer)
      w.reject(new Error('stopped'))
    }
  }

  // Resolve with the first row that matches. Check the rows now and after each change.
  // Reject with "timeout" after timeoutMs, and with "stopped" when the service stops.
  waitForRow(match: (row: SessionRow) => boolean, timeoutMs: number): Promise<SessionRow> {
    if (this.stopped) return Promise.reject(new Error('stopped'))
    const found = this.registry.rows().find(match)
    if (found) return Promise.resolve(found)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter(w => w.timer !== timer)
        reject(new Error('timeout'))
      }, timeoutMs)
      this.waiters.push({ match, reject, resolve, timer })
    })
  }

  // Apply one line of the mod. A state event goes to the state machine. A usage line goes to
  // the usage of the session. The update limit of changed() applies to the rows. The newest
  // rate limits go out when the line changes them, with the same update limit.
  pushLive(ev: LiveEvent): void {
    if (this.stopped) return
    if (ev.type === 'state') {
      this.registry.applyEvents([ev.event], this.deps.now())
      // Each state event goes to the listeners after the registry applies it, also one of a
      // session that is not a row yet and one that the order rule skips. A usage line goes to
      // none. A listener that throws stops no other step (final review Minor 4).
      // The listeners get the row ID, so the Event log keeps one session for a row across
      // /clear (spec 8.7).
      const event = { ...ev.event, sessionId: this.registry.rowIdOf(ev.event.sessionId) }
      for (const cb of this.eventCallbacks) {
        try {
          cb([event])
        } catch (error) {
          console.error('A Bifrost live event listener failed.', error)
        }
      }
    } else this.registry.applyUsage(ev.sessionId, ev.usage, ev.at)
    this.changed()
    this.checkUsage()
  }

  // Return the newest rate limits of all sessions, or null.
  usage(): UsageSnapshot | null {
    return this.registry.usage()
  }

  // The service calls cb when the newest rate limits change.
  onUsage(cb: UsageCallback): void {
    this.usageCallbacks.push(cb)
  }

  // The service calls cb with each live state event (D29).
  onEvents(cb: EventsCallback): void {
    this.eventCallbacks.push(cb)
  }

  // Return the number of rows that are live and not parked.
  liveCount(): number {
    return this.registry.liveCount()
  }

  // End the live flag of each row. The usage stays. The update limit of changed() applies.
  clearLive(): void {
    if (this.stopped) return
    this.registry.clearLive()
    this.changed()
  }

  forget(sessionId: string): void {
    this.registry.forget(sessionId)
    this.changed()
    this.checkUsage()
  }

  markStarted(sessionId: string): void {
    this.registry.markStarted(sessionId)
    this.changed()
  }

  markPrSession(sessionId: string): void {
    this.registry.markPrSession(sessionId)
    this.changed()
  }

  expectPrSession(name: string): void {
    this.registry.expectPrSession(name)
    this.changed()
  }

  releasePrSession(name: string): void {
    this.registry.releasePrSession(name)
    this.changed()
  }

  markStopped(sessionId: string): void {
    this.registry.markStopped(sessionId)
    this.changed()
  }

  terminalOf(sessionId: string): TerminalApp | undefined {
    return this.registry.terminalOf(sessionId)
  }

  onUpdate(cb: UpdateCallback): void {
    this.callbacks.push(cb)
  }

  // Set the local name of a session. Return false for an unknown session.
  setAlias(sessionId: string, name: string | null): boolean {
    const known = this.registry.setAlias(sessionId, name)
    if (known) {
      this.changed()
      // The Usage HUD shows the row name, so it changes at once.
      this.checkUsage()
    }
    return known
  }

  // Set the priority of a session. Return false for an unknown session.
  setPriority(sessionId: string, priority: Priority | null): boolean {
    const known = this.registry.setPriority(sessionId, priority)
    if (known) this.changed()
    return known
  }

  // The four watch changes use the same change path as setPriority.
  // Each returns false if the change is not possible. Then nothing changes.
  watchAdd(sessionId: string, colour: WatchColour): boolean {
    const ok = this.registry.watchAdd(sessionId, colour)
    if (ok) this.changed()
    return ok
  }

  watchRemove(sessionId: string): boolean {
    const ok = this.registry.watchRemove(sessionId)
    if (ok) this.changed()
    return ok
  }

  watchColour(sessionId: string, colour: WatchColour): boolean {
    const ok = this.registry.watchColour(sessionId, colour)
    if (ok) this.changed()
    return ok
  }

  watchMove(sessionId: string, beforeSessionId: string | null): boolean {
    const ok = this.registry.watchMove(sessionId, beforeSessionId)
    if (ok) this.changed()
    return ok
  }

  // Store the worktree that claude rm names for a session. Return false when the registry
  // refuses it.
  rememberWorktree(sessionId: string, path: string): boolean {
    const ok = this.registry.rememberWorktree(sessionId, path)
    if (ok) this.changed()
    return ok
  }

  rows(): SessionRow[] {
    return this.registry.rows()
  }

  // Run the job now. Start the next run ms after the end of each run.
  // When ms is a function, the loop reads it before each wait. So a new value applies to the
  // next wait. A run never starts before the last run ends.
  // A failed run does not stop the loop.
  private loop(
    ms: number | (() => number),
    job: () => Promise<void>,
    afterFirst?: () => void,
  ): void {
    let first = afterFirst
    const run = async (): Promise<void> => {
      try {
        await job()
      } catch {
        // The next run tries again.
      }
      if (this.stopped) return
      first?.()
      first = undefined
      this.later(typeof ms === 'number' ? ms : ms(), run)
    }
    void run()
  }

  private later(ms: number, fn: () => void): void {
    const timer = setTimeout(() => {
      this.timers.delete(timer)
      fn()
    }, ms)
    this.timers.add(timer)
  }

  // Put a list poll in the queue. The poll starts when the poll before it ends.
  private queued(job: () => Promise<void>): Promise<void> {
    const run = this.queue.then(() => (this.stopped ? undefined : job()))
    this.queue = run.catch(() => {})
    return run
  }

  private async pollActive(): Promise<void> {
    // The sample time is the time when the poll starts, after the wait in the queue.
    const sampledAt = this.deps.now()
    const list = await this.deps
      .listActive()
      .catch((error: unknown): AgentList => ({ entries: [], error: messageOf(error) }))
    if (this.stopped) return
    // Only the active poll counts for the health of the session list (P7).
    this.health.poll('sessions', list.error === undefined ? 'ok' : 'failed')
    if (list.error !== undefined) {
      // Keep the old rows. Send the error, also when the last poll had the same error.
      this.error = list.error
      this.errorToSend = true
    } else {
      this.registry.applyAgents(list.entries, sampledAt)
      this.error = null
      if (this.registry.pidsWithoutTerminal().length > 0 && !this.readingTable) {
        void this.readTerminals()
      }
    }
    // The first update holds the rows or the error of the first active poll.
    this.ready = true
    this.changed()
  }

  // Read the process table one time. Give the terminal apps of the new external PIDs to the registry.
  // A failed read changes nothing. The next active poll tries again.
  private async readTerminals(): Promise<void> {
    this.readingTable = true
    try {
      const table = await this.deps.readProcessTable()
      if (this.stopped || table === null) return
      const apps = new Map<number, TerminalApp | null>()
      for (const pid of this.registry.pidsWithoutTerminal()) {
        apps.set(pid, terminalAppOf(table, pid))
      }
      this.registry.applyTerminals(apps)
      this.changed()
    } catch {
      // The next active poll tries again.
    } finally {
      this.readingTable = false
    }
  }

  // A failed poll and a rejected poll change nothing. So a failed read never counts for the
  // forget of a gone session (Task 17 bug 3).
  private async pollAll(): Promise<void> {
    const list = await this.deps.listAll()
    // After a failed poll, the registry keeps the last --all list.
    if (this.stopped || list.error !== undefined) return
    this.registry.applyAllAgents(list.entries, list.partial !== true)
    this.changed()
  }

  // Read the branch one time for each cwd. Only one git process runs at a time.
  private async readBranches(): Promise<void> {
    for (const cwd of this.registry.cwds()) {
      const branch = await this.deps.readBranch(cwd)
      if (this.stopped) return
      this.registry.applyBranch(cwd, branch)
    }
    this.changed()
  }

  // The tick also sends the rate limits after the other changes: a new row name from a poll, or
  // a usage line that a counted --all list removed.
  private tick(): void {
    this.registry.tick(this.deps.now())
    this.changed()
    this.checkUsage()
  }

  // Call each onUsage listener when the newest rate limits differ from the last value that the
  // service sent. The rows can stay the same, so this check does not use send().
  // The update limit is that of the rows: at most one call each minUpdateGapMs. A check during
  // the gap runs again at the end of the gap, so the last value goes out.
  private checkUsage(): void {
    if (this.stopped) return
    if (this.usageInGap) {
      this.usageCheckedInGap = true
      return
    }
    const usage = this.registry.usage()
    const json = JSON.stringify(usage)
    if (json === this.lastUsage) return
    this.lastUsage = json
    this.usageInGap = true
    this.later(this.timing.minUpdateGapMs, () => {
      this.usageInGap = false
      if (!this.usageCheckedInGap) return
      this.usageCheckedInGap = false
      this.checkUsage()
    })
    for (const cb of this.usageCallbacks) cb(usage)
  }

  // Call this after each change to the data.
  private changed(): void {
    if (this.stopped) return
    if (this.registry.storeChanged()) this.storeToSave = true
    this.save()
    this.checkWaiters()
    if (!this.ready) return
    if (this.inGap) {
      // The last update went out less than minUpdateGapMs ago.
      // The end of the gap sends this change.
      this.changedInGap = true
      return
    }
    this.send()
  }

  // Resolve each waiter whose row exists. This runs before the update gap.
  private checkWaiters(): void {
    if (this.waiters.length === 0) return
    const rows = this.registry.rows()
    this.waiters = this.waiters.filter(w => {
      const row = rows.find(w.match)
      if (!row) return true
      clearTimeout(w.timer)
      w.resolve(row)
      return false
    })
  }

  // Send the rows and the error if they changed after the last update.
  // An error from a failed active poll always goes out.
  private send(): void {
    const rows = this.registry.rows()
    const json = JSON.stringify([rows, this.error])
    if (json === this.lastSent && !this.errorToSend) return
    this.lastSent = json
    this.errorToSend = false
    this.inGap = true
    this.later(this.timing.minUpdateGapMs, () => {
      this.inGap = false
      if (!this.changedInGap) return
      this.changedInGap = false
      this.send()
    })
    for (const cb of this.callbacks) cb(rows, this.error)
  }

  // Save the newest store. Only one save runs at a time.
  // A change during a save starts the next save when that save ends.
  // A failed save does not stop the service. The next loop tries the save again.
  // The log shows only the first failure of a series. The health log gets each save.
  private save(): void {
    if (this.stopped || this.saving || !this.storeToSave) return
    this.saving = true
    this.storeToSave = false
    const store = this.registry.store()
    // The chain changes a throw in saveStore into a rejection.
    Promise.resolve()
      .then(() => this.deps.saveStore(store))
      .then(
        () => {
          this.saving = false
          this.saveFailed = false
          this.health.save('registry', true)
          this.save()
        },
        (error: unknown) => {
          this.saving = false
          this.storeToSave = true
          this.health.save('registry', false)
          if (!this.saveFailed) console.error('Bifrost cannot save the registry store.', error)
          this.saveFailed = true
        },
      )
  }
}
