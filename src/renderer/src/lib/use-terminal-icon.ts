// The icon of the terminal app of an external row (D7). The main process reads it one time.
import { useEffect, useState } from 'react'
import type { SessionRow } from '../../../shared/types'

// One call for each app name. The key is the name of the terminal app.
const icons = new Map<string, Promise<string | null>>()
// The icons that arrived. A new mount shows them at once.
const loaded = new Map<string, string | null>()

function iconOf(app: string, sessionId: string): Promise<string | null> {
  let icon = icons.get(app)
  if (!icon) {
    icon = window.bifrost.actions.terminalIcon(sessionId).then(
      url => {
        loaded.set(app, url)
        return url
      },
      err => {
        // A failed call does not stay. A later row of the app can ask again.
        icons.delete(app)
        console.warn('Bifrost cannot get the icon of the terminal app.', app, err)
        return null
      },
    )
    icons.set(app, icon)
  }
  return icon
}

// The data URL of the icon, or null while it loads, for another row and for an app without one.
export function useTerminalIcon(row: SessionRow): string | null {
  const app = row.kind === 'external' && row.state !== 'parked' ? row.terminalApp : undefined
  const sessionId = row.sessionId
  const [icon, setIcon] = useState<{ app: string; url: string | null } | null>(null)

  // The call uses the first row of the app. A later row of the same app gets the same promise.
  useEffect(() => {
    if (app === undefined) return
    let active = true
    iconOf(app, sessionId).then(url => {
      if (active) setIcon({ app, url })
    })
    return () => {
      active = false
    }
  }, [app, sessionId])

  if (app === undefined) return null
  if (icon?.app === app) return icon.url
  return loaded.get(app) ?? null
}
