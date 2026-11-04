import type { SessionRow } from '../../shared/types'
import type { AgentList } from '../claude/agents'
import type { HookEvent } from './hook-event'
import type { RegistryStore, SessionRegistry } from './registry'
import type { StatusData } from './status-file'

// The service reads all data and does all writes through these functions.
export interface ServiceDeps {
  listActive(): Promise<AgentList>
  listAll(): Promise<AgentList>
  drainEvents(): Promise<{ events: HookEvent[]; errors: number }>
  readStatus(): Promise<Map<string, StatusData>>
  readBranch(cwd: string): Promise<string | null>
  saveStore(store: RegistryStore): Promise<void>
  now(): number
}

// The times of the loops and the minimum time between two updates, in milliseconds.
export const SERVICE_TIMING = {
  activeMs: 2000,
  allMs: 30_000,
  branchMs: 10_000,
  eventsMs: 500,
  minUpdateGapMs: 250,
  statusMs: 2000,
  tickMs: 1000,
}

type UpdateCallback = (rows: SessionRow[], error: string | null) => void

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Run the loops that give data to the registry. Send the rows after each change.
export class RegistryService {
  private readonly timers = new Set<ReturnType<typeof setTimeout>>()
  private readonly callbacks: UpdateCallback[] = []
  // The two list polls wait in this queue.
  // So only one "claude agents --json" process runs at a time.
  private queue: Promise<void> = Promise.resolve()
  // The saves wait in this queue. So the last save writes the newest store.
  private saves: Promise<void> = Promise.resolve()
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
  // The --all loop and the branch loop start after the end of the first active poll.
  // So the registry has the active list before the first --all list.
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
      },
    )
    this.loop(t.eventsMs, () => this.drainEvents())
    this.loop(t.statusMs, () => this.readStatus())
    this.loop(t.tickMs, async () => this.tick())
  }

  // Stop all loops. A result that comes after this call has no effect.
  stop(): void {
    this.stopped = true
    for (const timer of this.timers) clearTimeout(timer)
    this.timers.clear()
  }

  onUpdate(cb: UpdateCallback): void {
    this.callbacks.push(cb)
  }

  acknowledge(sessionId: string): void {
    this.registry.acknowledge(sessionId)
    this.changed()
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
    }
    this.changed()
  }

  private async pollAll(): Promise<void> {
    const list = await this.deps.listAll()
    // After a failed poll, the registry keeps the last --all list.
    if (this.stopped || list.error !== undefined) return
    this.registry.applyAllAgents(list.entries)
    this.changed()
  }

  // drainEvents deletes the bad event files. The service does not use the count of them.
  private async drainEvents(): Promise<void> {
    const { events } = await this.deps.drainEvents()
    if (this.stopped || events.length === 0) return
    this.registry.applyEvents(events, this.deps.now())
    this.changed()
  }

  private async readStatus(): Promise<void> {
    const data = await this.deps.readStatus()
    if (this.stopped) return
    this.registry.applyStatusFiles(data)
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
    if (this.registry.storeChanged()) this.save(this.registry.store())
    if (this.inGap) {
      // The last update went out less than minUpdateGapMs ago.
      // The end of the gap sends this change.
      this.changedInGap = true
      return
    }
    this.send()
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

  // A failed save does not stop the service. The next change to the store saves all of it.
  private save(store: RegistryStore): void {
    this.saves = this.saves.then(() => this.deps.saveStore(store)).catch(() => {})
  }
}
