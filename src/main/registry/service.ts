import type { Priority, SessionRow, WatchColour } from '../../shared/types'
import type { AgentList } from '../claude/agents'
import type { LiveEvent } from '../live/live-event'
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

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Run the loops that give data to the registry. Send the rows after each change.
// The lines of the Live details mod come through pushLive.
export class RegistryService {
  private readonly timers = new Set<ReturnType<typeof setTimeout>>()
  private readonly callbacks: UpdateCallback[] = []
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

  constructor(
    private readonly registry: SessionRegistry,
    private readonly deps: ServiceDeps,
    private readonly timing: typeof SERVICE_TIMING = SERVICE_TIMING,
  ) {}

  // Start all loops. A second call does nothing.
  // The --all loop, the branch loop and the tick loop start after the end of the first
  // active poll. So the registry has the active list before the first --all list,
  // and the first tick uses real rows.
  start(): void {
    if (this.started || this.stopped) return
    this.started = true
    const t = this.timing
    this.loop(
      t.activeMs,
      () => this.queued(() => this.pollActive()),
      () => {
        this.loop(t.allMs, () => this.queued(() => this.pollAll()))
        this.loop(t.branchMs, () => this.readBranches())
        this.loop(t.tickMs, async () => this.tick())
      },
    )
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
  // the usage of the session. The update limit of changed() applies.
  pushLive(ev: LiveEvent): void {
    if (this.stopped) return
    if (ev.type === 'state') this.registry.applyEvents([ev.event], this.deps.now())
    else this.registry.applyUsage(ev.sessionId, ev.usage, ev.at)
    this.changed()
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
  }

  markStarted(sessionId: string): void {
    this.registry.markStarted(sessionId)
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

  acknowledge(sessionId: string): void {
    this.registry.acknowledge(sessionId)
    this.changed()
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
  // So a run never starts before the last run ends.
  // A failed run does not stop the loop.
  private loop(ms: number, job: () => Promise<void>, afterFirst?: () => void): void {
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
      this.later(ms, run)
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

  private tick(): void {
    this.registry.tick(this.deps.now())
    this.changed()
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
  // The log shows only the first failure of a series.
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
          this.save()
        },
        (error: unknown) => {
          this.saving = false
          this.storeToSave = true
          if (!this.saveFailed) console.error('Bifrost cannot save the registry store.', error)
          this.saveFailed = true
        },
      )
  }
}
