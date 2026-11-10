// Source checks of the usage notification wiring (ipc.ts, preload, API, renderer). ipc.ts imports
// Electron, so a unit test cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(__dirname, '../../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')
const ipc = read('src/main/ipc.ts')

// One space for each run of white space, and no space after "(" or "[" or before ")" or "]". So a
// line break of the formatter does not matter.
const flat = (text: string): string =>
  text
    .replace(/\s+/g, ' ')
    .replace(/([([{]) /g, '$1')
    .replace(/ ([)\]}])/g, '$1')

// The text of a top-level function, from its declaration to its closing "}" line.
function functionBody(name: string): string {
  const start = ipc.search(new RegExp(`\\n(export )?(async )?function ${name}\\b`))
  expect(start, `function ${name}`).toBeGreaterThan(-1)
  const end = ipc.indexOf('\n}\n', start)
  expect(end, `end of function ${name}`).toBeGreaterThan(start)
  return flat(ipc.slice(start, end + 2))
}

describe('the usage notification wiring', () => {
  it('shows the notification with the usage limit label and the refused handler', () => {
    const body = functionBody('notifyUsageLimit')
    expect(body).toContain("showNotification({...text, label: 'usage limit', sessionId: null}")
    expect(body).toContain('logRefusedNotification')
    // Unlike a box, the notification also shows while the window has focus.
    expect(body).not.toContain('isFocused')
    // A click shows the window and opens the Usage HUD, or waits for the next page.
    expect(body).toContain('showWindowFn?.()')
    expect(body).toContain("if (pendingUsageOpen.click(USAGE_OPEN) !== null) send('usage:open')")
  })

  it('makes the monitor with the setting, the state file and the test home', () => {
    const body = functionBody('startUsageAlerts')
    expect(body).toContain('createUsageAlertMonitor({')
    expect(body).toContain('enabled: () => getSettings().notifications')
    expect(body).toContain('notify: notifyUsageLimit')
    expect(body).toContain("openUsageAlertStore(usageAlertsFile(app.getPath('userData')))")
    // The monitor waits for the settings store too.
    expect(body).toMatch(/Promise\.all\(\[openUsageAlertStore\([^\]]*settingsReady,?\]\)/)
    expect(body).toContain('readExtraUsageFlag(claudeJsonFile(home?.home ?? homedir()))')
    expect(flat(ipc)).toContain('usageAlerts = startUsageAlerts(home, settings)')
  })

  it('gives each account value and each session value to the monitor', () => {
    const text = flat(ipc)
    expect(text).toMatch(
      /emit: value => \{send\('usage:account-update', value\) usageAlerts\?\.account\(value\)\}/,
    )
    expect(text).toMatch(
      /service\.onUsage\(usage => \{send\('usage:update', usage\) usageAlerts\?\.session\(usage\)\}\)/,
    )
  })

  it('gives a click that waits to the next page', () => {
    expect(ipc).toContain('const pendingUsageOpen = new PendingOpen()')
    expect(functionBody('attachWindow')).toContain(
      "if (pendingUsageOpen.load() !== null) send('usage:open')",
    )
    expect(functionBody('unloadPendingOpens')).toContain('pendingUsageOpen.unload()')
  })

  it('has usage.onOpen in the API and the preload, and the page opens the Usage HUD', () => {
    expect(read('src/shared/api.ts')).toMatch(/onOpen\(cb: \(\) => void\): \(\) => void/)
    expect(read('src/preload/index.ts')).toContain("onOpen: cb => subscribe('usage:open', cb)")
    expect(flat(read('src/renderer/src/actions/actions-context.tsx'))).toMatch(
      /window\.bifrost\.usage\.onOpen\(\(\) => \{?dispatch\(\{panelId: 'usage-hud', type: 'open'\}\)/,
    )
  })
})
