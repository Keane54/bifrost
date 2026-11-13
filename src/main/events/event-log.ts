// The Event log (spec 8.7). The main process keeps the newest live state events in memory.
// Nothing goes to disk.
import { EVENT_LOG_MAX } from '../../shared/event-log'
import type { LogEntry } from '../../shared/types'
import type { HookEvent } from '../registry/hook-event'

export { EVENT_LOG_MAX }
// The main process sends new entries to the page at most once in this time.
export const APPEND_GAP_MS = 250

// The text of the line that shows when macOS refuses a notification. A person reads it.
export const NOTIFICATION_REFUSED =
  "macOS didn't show a notification. Allow notifications for Bifrost in System Settings."

export class EventLog {
  private entries: LogEntry[] = []
  // The next number. The log has its own numbers. They are not the numbers of the mod.
  private next = 1
  // The texts of the notice lines that the log made already. A notice shows one time.
  private readonly notices = new Set<string>()

  constructor(private readonly max: number = EVENT_LOG_MAX) {}

  // Add one entry for each event. Return the new entries.
  append(events: HookEvent[]): LogEntry[] {
    const added = events.map((event): LogEntry => {
      const entry: LogEntry = {
        at: event.at,
        name: event.name,
        seq: this.next++,
        sessionId: event.sessionId,
      }
      if (event.toolName !== undefined) entry.detail = event.toolName
      return entry
    })
    this.keep(added)
    return added
  }

  // Add a plain line for the user, for example a refused notification. The same text goes in
  // one time only. Return the new entry, or null when the text was in the log before.
  notice(text: string, at: number): LogEntry | null {
    if (this.notices.has(text)) return null
    this.notices.add(text)
    return this.line(text, at)
  }

  // Add a plain line for the user each time, for example a line of a Daily update run. Return
  // the new entry.
  line(text: string, at: number): LogEntry {
    const entry: LogEntry = { at, kind: 'notice', name: text, seq: this.next++, sessionId: '' }
    this.keep([entry])
    return entry
  }

  // A copy of the entries, in seq order.
  list(): LogEntry[] {
    return [...this.entries]
  }

  private keep(added: LogEntry[]): void {
    this.entries.push(...added)
    if (this.entries.length > this.max) this.entries.splice(0, this.entries.length - this.max)
  }
}

// Send the first entries at once. Send entries that come within gapMs after a send as one call
// at the end of the gap. stop drops the waiting entries.
export function createBatcher(
  send: (entries: LogEntry[]) => void,
  gapMs: number = APPEND_GAP_MS,
): { push(entries: LogEntry[]): void; stop(): void } {
  let waiting: LogEntry[] = []
  let timer: ReturnType<typeof setTimeout> | null = null
  let stopped = false

  const out = (entries: LogEntry[]): void => {
    send(entries)
    timer = setTimeout(() => {
      timer = null
      if (stopped || waiting.length === 0) return
      const batch = waiting
      waiting = []
      out(batch)
    }, gapMs)
  }

  return {
    push(entries) {
      if (stopped || entries.length === 0) return
      if (timer === null) out(entries)
      else waiting.push(...entries)
    },
    stop() {
      stopped = true
      waiting = []
      if (timer !== null) clearTimeout(timer)
      timer = null
    },
  }
}
