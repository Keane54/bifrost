// The notified periods of the usage notification, in userData/usage-alerts.json. The file keeps
// them across restarts. So a restart, for example after an update, does not notify again for the
// same period.
import { join } from 'node:path'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'
import { NO_PERIODS, type NotifiedPeriods } from './rules'

export interface UsageAlertStore {
  // The newest value.
  get(): NotifiedPeriods
  // Set the value at once and write the file. This promise never rejects. A failed write goes to
  // the log, and the new value stays in memory.
  set(next: NotifiedPeriods): Promise<void>
}

export function usageAlertsFile(userData: string): string {
  return join(userData, 'usage-alerts.json')
}

function timeOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

// Each value that is not a finite number gives null ("no period notified").
export function parseNotified(data: unknown): NotifiedPeriods {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return NO_PERIODS
  const record = data as Record<string, unknown>
  return { fiveHour: timeOrNull(record.fiveHour), sevenDay: timeOrNull(record.sevenDay) }
}

// Open the state file.
// A missing file or a file that is not valid JSON gives no notified period.
// A file that cannot be read gives no notified period, and the store does not save. So it cannot
// write over a file that it did not read.
export async function openUsageAlertStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<UsageAlertStore> {
  let current: NotifiedPeriods = { ...NO_PERIODS }
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parseNotified(read.data)
  } catch (error) {
    canSave = false
    log(`Bifrost cannot read ${file}. The usage notification uses an empty state.`, error)
  }
  // Each write waits for the write before it, so the last set wins on disk.
  let queue: Promise<void> = Promise.resolve()
  return {
    get: () => current,
    set(next) {
      current = { ...next }
      const value = current
      queue = queue.then(async () => {
        if (!canSave) return
        try {
          await writeJsonAtomic(file, value)
        } catch (error) {
          log(`Bifrost cannot save ${file}.`, error)
        }
      })
      return queue
    },
  }
}
