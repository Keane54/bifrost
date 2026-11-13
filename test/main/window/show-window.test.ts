import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  hideFromDock,
  seenFocused,
  seenVisible,
  showMainWindow,
} from '../../../src/main/window/show-window'

// A fake window that records each call.
function fakeWindow(): { calls: string[]; win: Parameters<typeof showMainWindow>[0] } {
  const calls: string[] = []
  return {
    calls,
    win: {
      focus: () => calls.push('focus'),
      show: () => calls.push('show'),
      showInactive: () => calls.push('showInactive'),
    },
  }
}

// The code of a source file without the comment lines.
function code(file: string): string {
  return readFileSync(join(__dirname, '../../../src/main', file), 'utf8')
    .split('\n')
    .filter(line => !line.trim().startsWith('//'))
    .join('\n')
}

// One space for each run of white space, and no space after "(", "[" or "{" or before ")", "]"
// or "}". So a line break of the formatter does not matter.
const flat = (text: string): string =>
  text
    .replace(/\s+/g, ' ')
    .replace(/([([{]) /g, '$1')
    .replace(/ ([)\]}])/g, '$1')

describe('showMainWindow', () => {
  it('shows the window as before in a normal start', () => {
    const start = fakeWindow()
    showMainWindow(start.win, { focus: false, testHome: false })
    expect(start.calls).toEqual(['show'])
    const click = fakeWindow()
    showMainWindow(click.win, { focus: true, testHome: false })
    expect(click.calls).toEqual(['show', 'focus'])
  })

  it('never focuses the window in a test home', () => {
    for (const focus of [false, true]) {
      const { calls, win } = fakeWindow()
      showMainWindow(win, { focus, testHome: true })
      expect(calls).toEqual(['showInactive'])
      const shown = fakeWindow()
      showMainWindow(shown.win, { focus, headless: false, testHome: true })
      expect(shown.calls).toEqual(['showInactive'])
    }
  })

  it('shows no window in a headless test home', () => {
    for (const focus of [false, true]) {
      const { calls, win } = fakeWindow()
      showMainWindow(win, { focus, headless: true, testHome: true })
      expect(calls).toEqual([])
    }
  })

  it('a normal start ignores the headless flag', () => {
    const { calls, win } = fakeWindow()
    showMainWindow(win, { focus: true, headless: true, testHome: false })
    expect(calls).toEqual(['show', 'focus'])
  })
})

describe('hideFromDock', () => {
  // A fake app that records each activation policy.
  function fakeApp(): { policies: string[]; app: Parameters<typeof hideFromDock>[0] } {
    const policies: string[] = []
    return { app: { setActivationPolicy: policy => policies.push(policy) }, policies }
  }

  it('a headless test home on macOS has no Dock icon and is never active by itself', () => {
    const { app, policies } = fakeApp()
    hideFromDock(app, { headless: true, platform: 'darwin' })
    expect(policies).toEqual(['accessory'])
  })

  it('a start that is not headless keeps its Dock icon', () => {
    const { app, policies } = fakeApp()
    hideFromDock(app, { headless: false, platform: 'darwin' })
    expect(policies).toEqual([])
  })

  it('another platform has no Dock', () => {
    const { app, policies } = fakeApp()
    hideFromDock(app, { headless: true, platform: 'linux' })
    expect(policies).toEqual([])
  })
})

describe('the main process view of a headless window', () => {
  it('a headless test window counts as visible, so the poll keeps its normal interval', () => {
    expect(seenVisible(false, true)).toBe(true)
    expect(seenVisible(true, true)).toBe(true)
    // A window that is not headless keeps the visibility that the page sends.
    expect(seenVisible(false, false)).toBe(false)
    expect(seenVisible(true, false)).toBe(true)
  })

  it('a headless test window counts as focused, so no alert notification starts', () => {
    expect(seenFocused(false, true)).toBe(true)
    expect(seenFocused(true, true)).toBe(true)
    expect(seenFocused(false, false)).toBe(false)
    expect(seenFocused(true, false)).toBe(true)
  })
})

describe('the headless wiring in index.ts', () => {
  const index = code('index.ts')

  it('shows the window only through showMainWindow, with the test-home and headless flags', () => {
    expect(index).not.toMatch(/\.show\(\)|\.focus\(\)|\.showInactive\(\)/)
    expect(index.match(/showMainWindow\(/g)).toHaveLength(2)
    expect(index).toContain(
      'showMainWindow(mainWindow, { focus: false, headless, testHome: testHome !== null })',
    )
    expect(index).toContain(
      'showMainWindow(win, { focus: true, headless, testHome: testHome !== null })',
    )
  })

  it('reads the headless flag from the env and the test home', () => {
    expect(index).toContain('const headless = testHeadless(process.env, testHome)')
  })

  it('leaves the Dock before the app is ready', () => {
    const hide = index.indexOf('hideFromDock(app, { headless, platform: process.platform })')
    expect(hide).toBeGreaterThan(-1)
    expect(hide).toBeLessThan(index.indexOf('function startApp('))
  })

  it('gives the headless flag to registerIpc', () => {
    expect(index).toContain('registerIpc(testHome, headless)')
  })
})

describe('the headless wiring in ipc.ts', () => {
  const ipc = code('ipc.ts')
  const text = flat(ipc)

  it('keeps the flag that index.ts gives', () => {
    expect(text).toContain(
      'export function registerIpc(home: TestHome | null = null, hidden = false): void {',
    )
    expect(text).toMatch(/testHome = home headless = hidden /)
  })

  it('gives the poll a visible window in a headless test home', () => {
    expect(text).toContain(
      'function pollVisible(): boolean {return seenVisible(pageVisible, headless)}',
    )
    expect(text).toContain('liveService?.setPageVisible(pollVisible())')
    expect(text).toContain('service.setPageVisible(pollVisible())')
    expect(ipc.match(/\.setPageVisible\(/g)).toHaveLength(2)
  })

  it('reads the focus of the window for alerts and review requests through windowFocused', () => {
    const focused =
      'currentWindow !== null && !currentWindow.isDestroyed() && currentWindow.isFocused()'
    expect(text).toContain(
      `function windowFocused(): boolean {return seenFocused(${focused}, headless,)}`,
    )
    expect(text).toContain('if (!getSettings().notifications || windowFocused()) return')
    expect(text).toContain('const alerts = createAlertMonitor({focused: windowFocused,')
  })

  it('records the notifications in a test home', () => {
    expect(text).toMatch(/testHome = home headless = hidden recordNotifications\(home !== null\)/)
  })
})
