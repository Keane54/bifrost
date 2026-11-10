// The health log of the Performance panel (P5). The existing modules report their poll results,
// save results, crashes and Live details start errors here. The health checks read view().
// The log keeps only counts and times, in memory.

export type PollPart = 'sessions' | 'reviews' | 'account-usage' | 'service-status' | 'updates'
export type StorePart = 'settings' | 'ui-state' | 'registry' | 'window-state' | 'reviews-state'
// 'no-data' is a poll that got no data for a known cause that is not a failure, for example
// gh is logged out (P7).
export type PollResult = 'ok' | 'failed' | 'no-data'

export interface HealthEvents {
  poll(part: PollPart, result: PollResult): void
  save(part: StorePart, ok: boolean): void
  crash(kind: 'window' | 'gpu', reason: string): void
  liveStartFailed(message: string): void
  // The Live details server started, or Bifrost stopped it on purpose (Turn off, Remove or the
  // quit). The last start error then does not apply.
  liveStartCleared(): void
  // A poll part stopped while the app runs, for example the user turned it off. No more polls
  // come, so its failures in a row go to 0.
  stopped(part: PollPart): void
}

export interface HealthLogView {
  failsInARow: Record<PollPart, number>
  // The time of the last failed save of each store.
  saveFailedAt: Partial<Record<StorePart, number>>
  crashes: Array<{ kind: 'window' | 'gpu'; reason: string; at: number }>
  liveStartFailedAt: number | null
}

export interface HealthLog extends HealthEvents {
  view(now: number): HealthLogView
}

// A crash and a save failure stay in the view for this time.
export const HEALTH_WINDOW_MS = 60 * 60_000

// The default dep of each module. Each event does nothing.
export const NO_HEALTH: HealthEvents = {
  crash: () => {},
  liveStartCleared: () => {},
  liveStartFailed: () => {},
  poll: () => {},
  save: () => {},
  stopped: () => {},
}

// Run one write of a store and give its result to the health log. A failed write still rejects
// with its error. Each store calls this only for a real write, so a refused save and a store
// that does not save give no event.
export async function reportSave(
  health: Pick<HealthEvents, 'save'>,
  part: StorePart,
  write: () => Promise<void>,
): Promise<void> {
  try {
    await write()
  } catch (error) {
    health.save(part, false)
    throw error
  }
  health.save(part, true)
}

// The network poll parts. While the Mac is offline, a failure of these parts counts as no data
// (design section 6, P7). An update check is a network poll.
const NETWORK_PARTS: ReadonlySet<PollPart> = new Set([
  'reviews',
  'account-usage',
  'service-status',
  'updates',
])

// now gives the time of each event, in milliseconds since the epoch. online gives the network
// state at the time of each poll result. ipc.ts binds it to net.isOnline.
export function createHealthLog(now: () => number, online: () => boolean = () => true): HealthLog {
  const failsInARow: Record<PollPart, number> = {
    'account-usage': 0,
    reviews: 0,
    'service-status': 0,
    sessions: 0,
    updates: 0,
  }
  const saveFailedAt: Partial<Record<StorePart, number>> = {}
  let crashes: HealthLogView['crashes'] = []
  let liveStartFailedAt: number | null = null

  // True while an event of this time is less than 60 minutes old.
  const recent = (at: number, time: number): boolean => time - at < HEALTH_WINDOW_MS

  return {
    // Remove the old crashes here. Then the list stays small also when no view comes.
    crash(kind, reason) {
      const at = now()
      crashes = crashes.filter(c => recent(c.at, at))
      crashes.push({ at, kind, reason })
    },
    liveStartCleared() {
      liveStartFailedAt = null
    },
    liveStartFailed() {
      liveStartFailedAt = now()
    },
    // A good poll sets the count to 0. A poll with no data does not change it. While offline, a
    // failed network poll is a poll with no data. So the reconnect shows no old failures.
    poll(part, result) {
      if (result === 'ok') failsInARow[part] = 0
      else if (result === 'failed' && (online() || !NETWORK_PARTS.has(part))) {
        failsInARow[part] += 1
      }
    },
    // A good save does not clear an earlier failure (P6).
    save(part, ok) {
      if (!ok) saveFailedAt[part] = now()
    },
    stopped(part) {
      failsInARow[part] = 0
    },
    // The view has no crash and no save failure that is 60 minutes old or older. It is a copy, so
    // a change to it does not change the log.
    view(time) {
      const saves: HealthLogView['saveFailedAt'] = {}
      for (const [part, at] of Object.entries(saveFailedAt) as Array<[StorePart, number]>) {
        if (recent(at, time)) saves[part] = at
      }
      return {
        crashes: crashes.filter(c => recent(c.at, time)).map(c => ({ ...c })),
        failsInARow: { ...failsInARow },
        liveStartFailedAt,
        saveFailedAt: saves,
      }
    },
  }
}
