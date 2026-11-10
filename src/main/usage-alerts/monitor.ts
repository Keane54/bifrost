// The usage notification (spec 8.8). The monitor checks the rules each time new values arrive: an
// account usage emit or a change of the session usage. It has no timer of its own.
import type { AccountUsage, UsageSnapshot } from '../../shared/types'
import { usageSource } from '../../shared/usage'
import { afterAlerts, alertText, dueAlerts } from './rules'
import type { UsageAlertStore } from './state-store'

export interface UsageAlertDeps {
  // The state store. The monitor checks nothing until this promise resolves. The caller also
  // waits for the settings store, so the setting below has its real value.
  store: Promise<UsageAlertStore>
  now(): number
  // True when the setting notifications is on.
  enabled(): boolean
  // The extra usage flag of ~/.claude.json. The monitor calls it only when a notification is
  // about to show and the account values do not give the flag.
  readExtraUsage(): Promise<boolean>
  // Show one notification.
  notify(text: { title: string; body: string }): void
  // For tests. Without it, the zone of the computer applies.
  timeZone?: string
}

export interface UsageAlertMonitor {
  // New account values from the poller, or null.
  account(value: AccountUsage | null): void
  // New session values from the usage lines, or null.
  session(value: UsageSnapshot | null): void
}

export function createUsageAlertMonitor(deps: UsageAlertDeps): UsageAlertMonitor {
  let account: AccountUsage | null = null
  let session: UsageSnapshot | null = null
  let store: UsageAlertStore | null = null

  // The flag of fresh account values, else the flag of the file. A failed read counts as off.
  function extraUsage(known: boolean | undefined): Promise<boolean> {
    if (known !== undefined) return Promise.resolve(known)
    return deps.readExtraUsage().catch(() => false)
  }

  function check(): void {
    if (!store) return
    const now = deps.now()
    // The same choice as the Usage HUD: fresh account values, else the session values.
    const source = usageSource(session, now, account)
    // With the setting off, the period stays open. So a notification can show after the user
    // turns the setting on, at the next new value in the same period.
    if (!source || !deps.enabled()) return
    const due = dueAlerts(source.limits, store.get(), now)
    if (due.length === 0) return
    // Keep the periods before the read of the flag. So a new value during the read does not
    // notify again.
    void store.set(afterAlerts(store.get(), due))
    const known = source.kind === 'account' ? source.account.extraUsage : undefined
    extraUsage(known)
      .then(on => {
        for (const alert of due) deps.notify(alertText(alert, on, now, deps.timeZone))
      })
      .catch(error => console.error('Bifrost cannot show the usage notification.', error))
  }

  deps.store.then(
    opened => {
      store = opened
      check()
    },
    error => console.error('Bifrost cannot open the state of the usage notification.', error),
  )

  return {
    account(value) {
      account = value
      check()
    },
    session(value) {
      session = value
      check()
    },
  }
}
