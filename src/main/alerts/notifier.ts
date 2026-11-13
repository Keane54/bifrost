// Show a macOS notification. Electron needs a reference to the Notification until the user
// acts on it. Else the click handler can go away.
import { Notification } from 'electron'

// Keep at most this many open notifications.
const MAX_KEPT = 20

const kept = new Set<Notification>()

// The first refused notification of the run logs. Later ones do not log.
let failedLogged = false

// A notification that a test home did not show.
export interface RecordedNotification {
  body: string
  label: string | null
  sessionId: string | null
  sound: boolean
  title: string
}

// In a test home, Bifrost shows no macOS notification (user decision, 2026-11-13). It adds each
// notification to this list. A smoke test reads the list in the main process as
// globalThis.bifrostNotifications.
let recording = false
const recorded: RecordedNotification[] = []

// Start or stop the record of the notifications. registerIpc starts it in a test home.
export function recordNotifications(on: boolean): void {
  recording = on
  if (on) Object.assign(globalThis, { bifrostNotifications: recorded })
}

// The notifications that the record has.
export function recordedNotifications(): readonly RecordedNotification[] {
  return recorded
}

// label names the notification in the log line, for example "review requests". Without it, the
// log line names the session, or "a summary" for a summary of boxes.
// sound true lets macOS play its notification sound. Without it, the notification is silent.
export function showNotification(
  n: { title: string; body: string; sessionId: string | null; label?: string; sound?: boolean },
  onClick: (sessionId: string | null) => void,
  // Called when macOS refuses the notification.
  onFailed?: () => void,
): void {
  const name = n.label ?? n.sessionId ?? 'a summary'
  if (recording) {
    const { body, sessionId, title } = n
    recorded.push({ body, label: n.label ?? null, sessionId, sound: n.sound === true, title })
    console.log(`Bifrost recorded a notification for ${name}.`)
    return
  }
  if (!Notification.isSupported()) return
  const note = new Notification({ body: n.body, silent: n.sound !== true, title: n.title })
  kept.add(note)
  // Drop the oldest when the set is full.
  while (kept.size > MAX_KEPT) {
    const oldest = kept.values().next().value
    if (oldest === undefined) break
    kept.delete(oldest)
  }
  note.on('click', () => {
    kept.delete(note)
    onClick(n.sessionId)
  })
  note.on('close', () => {
    kept.delete(note)
  })
  note.on('failed', (_event, error) => {
    kept.delete(note)
    if (!failedLogged) {
      failedLogged = true
      console.error('Bifrost cannot show a notification.', error)
    }
    onFailed?.()
  })
  note.on('show', () => {
    console.log(`Bifrost showed a notification for ${name}.`)
  })
  note.show()
}
