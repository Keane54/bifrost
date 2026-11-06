// The alerts of spec 10. The monitor finds each new box in the rows of the registry. It then
// shows a notification and plays a sound. It runs in the main process (D13).
import type { Settings } from '../../shared/settings'
import type { SessionRow, SessionState } from '../../shared/types'

// Show at most this many notifications for one update. More boxes give one summary.
export const MAX_NOTIFICATIONS = 3
// The least time between two sounds.
export const SOUND_GAP_MS = 2000
export const AFPLAY = '/usr/bin/afplay'
export const SOUND_FILE = '/System/Library/Sounds/Ping.aiff'

export interface BoxMark {
  box: 'yellow' | 'red'
  since: number | null
}

export interface NewBox {
  sessionId: string
  name: string
  box: 'yellow' | 'red'
  state: SessionState
}

// Find the boxes that are new since prev. A box is new when the row has no mark in prev, or the
// mark has another box or another boxSince. A null prev is the first update after the start. It
// only records the marks. A session that is not in rows leaves the marks.
export function findNewBoxes(
  prev: Map<string, BoxMark> | null,
  rows: SessionRow[],
): { marks: Map<string, BoxMark>; added: NewBox[] } {
  const marks = new Map<string, BoxMark>()
  const added: NewBox[] = []
  for (const row of rows) {
    if (row.box === 'none') continue
    marks.set(row.sessionId, { box: row.box, since: row.boxSince })
    if (prev === null) continue
    const old = prev.get(row.sessionId)
    if (old === undefined || old.box !== row.box || old.since !== row.boxSince) {
      added.push({ box: row.box, name: row.name, sessionId: row.sessionId, state: row.state })
    }
  }
  return { added, marks }
}

// The text of the notification for one box.
export function alertText(box: NewBox): { title: string; body: string } {
  if (box.box === 'yellow') return { body: 'Claude finished its turn.', title: box.name }
  if (box.state === 'error') {
    return { body: 'The session stopped with an error.', title: box.name }
  }
  return { body: 'Claude needs you.', title: box.name }
}

export interface AlertDeps {
  settings(): Pick<Settings, 'notifications' | 'redBoxSound'>
  focused(): boolean
  notify(n: { title: string; body: string; sessionId: string | null }): void
  playSound(): void
  now(): number
}

export function createAlertMonitor(deps: AlertDeps): { update(rows: SessionRow[]): void } {
  let marks: Map<string, BoxMark> | null = null
  let lastSound: number | null = null
  return {
    update(rows) {
      const found = findNewBoxes(marks, rows)
      marks = found.marks
      const { added } = found
      if (added.length === 0) return
      const settings = deps.settings()
      if (settings.notifications && !deps.focused()) {
        if (added.length <= MAX_NOTIFICATIONS) {
          for (const box of added) deps.notify({ ...alertText(box), sessionId: box.sessionId })
        } else {
          deps.notify({
            body: `${added.length} sessions need you.`,
            sessionId: null,
            title: 'Bifrost',
          })
        }
      }
      if (settings.redBoxSound && added.some(box => box.box === 'red')) {
        const now = deps.now()
        if (lastSound === null || now - lastSound >= SOUND_GAP_MS) {
          lastSound = now
          deps.playSound()
        }
      }
    },
  }
}
