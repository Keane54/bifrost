// Show a macOS notification. Electron needs a reference to the Notification until the user
// acts on it. Else the click handler can go away.
import { Notification } from 'electron'

// Keep at most this many open notifications.
const MAX_KEPT = 20

const kept = new Set<Notification>()

// The first refused notification of the run logs. Later ones do not log.
let failedLogged = false

// label names the notification in the log line, for example "review requests". Without it, the
// log line names the session, or "a summary" for a summary of boxes.
// sound true lets macOS play its notification sound. Without it, the notification is silent.
export function showNotification(
  n: { title: string; body: string; sessionId: string | null; label?: string; sound?: boolean },
  onClick: (sessionId: string | null) => void,
  // Called when macOS refuses the notification.
  onFailed?: () => void,
): void {
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
    console.log(`Bifrost showed a notification for ${n.label ?? n.sessionId ?? 'a summary'}.`)
  })
  note.show()
}
