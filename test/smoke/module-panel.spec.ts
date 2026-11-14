// Module panels in the window system (plan Task 6). The test seeds modules/state.json, the hello
// module and a saved layout in the test home. The side bar shows a button for the panel of each
// enabled module. A click opens the panel through the window manager. The module page then loads
// /_bifrost/api.js in its real sandboxed frame, and calls Heimdall through the bridge of
// ModuleFrame. A saved panel of a module that is off or gone shows the notice (Review Focus 3).

import { cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, skipSetup } from './app.ts'

const FIXTURE = join(import.meta.dirname, 'fixtures', 'modules', 'hello')
const NOTICE = 'This module is off or no longer installed.'
// The longest wait for a condition. A slow machine gets the time it needs.
const SLOW = 20_000

function manifest(id: string, title: string): Record<string, unknown> {
  return {
    description: 'A module that calls Heimdall from its panel.',
    id,
    minBifrost: '0.1.0',
    name: id === 'hello' ? 'Hello' : 'Hello off',
    panels: [{ entry: 'panels/main.html', icon: 'star', id: 'main', title }],
    permissions: [],
    suggests: { dailyCap: null, model: null },
    version: '1.0.0',
  }
}

// Seed the hello module (on) and a copy of it that is off.
async function seedModules(bifrostHome: string): Promise<void> {
  const modules: Record<string, unknown> = {}
  for (const [id, enabled, title] of [
    ['hello', true, 'Hello board'],
    ['hello-off', false, 'Off board'],
  ] as const) {
    await cp(FIXTURE, join(bifrostHome, 'modules', id, 'current'), { recursive: true })
    modules[id] = {
      dailyCap: 10,
      enabled,
      granted: [],
      hash: '0'.repeat(64),
      jobs: { count: 0, day: '' },
      manifest: manifest(id, title),
      model: 'sonnet',
      pendingUpdate: null,
      source: { kind: 'folder', path: FIXTURE },
    }
  }
  await writeFile(join(bifrostHome, 'modules', 'state.json'), JSON.stringify({ modules }))
}

// A saved layout with a panel of the module that is off and a panel of a module that is gone.
async function seedLayout(userData: string): Promise<void> {
  const frame = (panelId: string, x: number) => ({
    active: panelId,
    locked: false,
    minimised: false,
    panels: [panelId],
    rect: { h: 200, w: 320, x, y: 20 },
  })
  await mkdir(userData, { recursive: true })
  await writeFile(
    join(userData, 'ui-state.json'),
    JSON.stringify({
      current: {
        frames: [frame('module:hello-off:main', 20), frame('module:gone:main', 360)],
        memory: {},
      },
      layouts: [],
      overviews: {},
      version: 1,
    }),
  )
}

test('a module panel opens from the side bar and calls Heimdall', async () => {
  test.setTimeout(120_000)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-module-panel-'))
  let app: ElectronApplication | null = null
  try {
    await mkdir(join(testHome, '.bifrost'), { recursive: true })
    await seedModules(join(testHome, '.bifrost'))
    await seedLayout(join(testHome, 'user-data'))
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)
    await skipSetup(page)

    // The saved panels of a module that is off and of a module that is gone show the notice.
    // The title of the module that is off comes from its manifest, with the module name.
    const off = page.locator('[data-panel-id="module:hello-off:main"]')
    await expect(off).toHaveText('Off board · Hello off', { timeout: SLOW })
    const gone = page.locator('[data-panel-id="module:gone:main"]')
    await expect(gone).toHaveText('Module')
    await expect(page.locator('[data-module-notice]')).toHaveCount(2)
    await expect(page.locator('[data-module-notice]').first()).toHaveText(NOTICE)
    await expect(page.locator('iframe[data-module-panel]')).toHaveCount(0)

    // The side bar has a button for the panel of the module that is on, and none for the module
    // that is off. The label gives the module name.
    const sideBar = page.getByRole('navigation', { name: 'Side bar' })
    const button = sideBar.getByRole('button', { exact: true, name: 'Hello board (Hello)' })
    await expect(button).toBeVisible()
    await expect(sideBar.getByRole('button', { name: /Off board/ })).toHaveCount(0)

    // A click opens the panel in a frame, with the title of the manifest and the module name.
    await button.click()
    await expect(page.locator('[data-panel-id="module:hello:main"]')).toHaveText(
      'Hello board · Hello',
    )
    const frame = page.locator('iframe[data-module-panel="main"]')
    await expect(frame).toHaveCount(1)
    await expect(frame).toHaveAttribute('sandbox', 'allow-scripts')
    await expect(frame).toHaveAttribute('src', 'bifrost-module://hello/panels/main.html')

    // The module page loads the client library and gets the answers of Heimdall through the
    // bridge: its own storage works, and a call without the permission is refused.
    const inFrame = page.frameLocator('iframe[data-module-panel="main"]')
    await expect(inFrame.locator('#stored')).toHaveText('stored: hello from Heimdall', {
      timeout: SLOW,
    })
    await expect(inFrame.locator('#refused')).toHaveText('refused: not allowed for this module')

    // The module frame runs in its own process (ruling S-A5).
    const processes = await app.evaluate(({ BrowserWindow }) => {
      const top = BrowserWindow.getAllWindows()[0].webContents.mainFrame
      const module = top.framesInSubtree.find(f => f.url.startsWith('bifrost-module://hello/'))
      return { module: module?.osProcessId ?? 0, top: top.osProcessId }
    })
    expect(processes.module).toBeGreaterThan(0)
    expect(processes.module).not.toBe(processes.top)

    // A close of the panel removes the frame.
    const helloFrame = page.locator('[data-frame-id]', { has: frame })
    await helloFrame.getByRole('button', { exact: true, name: 'Close' }).click()
    await expect(frame).toHaveCount(0)
  } finally {
    await app?.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})

// The ids of the modules that the next test opens at the same time.
const MANY = ['m-one', 'm-two', 'm-three', 'm-four', 'm-five']

// Seed one copy of the hello module for each id, all on.
async function seedMany(bifrostHome: string): Promise<void> {
  const modules: Record<string, unknown> = {}
  for (const id of MANY) {
    await cp(FIXTURE, join(bifrostHome, 'modules', id, 'current'), { recursive: true })
    modules[id] = {
      dailyCap: 10,
      enabled: true,
      granted: [],
      hash: '0'.repeat(64),
      jobs: { count: 0, day: '' },
      manifest: { ...manifest(id, `Board ${id}`), name: `Hello ${id}` },
      model: 'sonnet',
      pendingUpdate: null,
      source: { kind: 'folder', path: FIXTURE },
    }
  }
  await writeFile(join(bifrostHome, 'modules', 'state.json'), JSON.stringify({ modules }))
}

// Chromium groups sandboxed frames by origin, and each module has its own host. So each open
// module must run in a process of its own (isolation research, item 1). The spike checked only
// two modules. The negative control ran by hand on 2026-11-14: with
// --disable-site-isolation-trials, the 5 module frames had 1 process. So this check fails when
// Chromium does not isolate each origin.
test('each open module runs in a process of its own', async () => {
  test.setTimeout(120_000)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-module-processes-'))
  let app: ElectronApplication | null = null
  try {
    await mkdir(join(testHome, '.bifrost'), { recursive: true })
    await seedMany(join(testHome, '.bifrost'))
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)
    await skipSetup(page)

    // Open the panel of each module from the side bar. Each page calls Heimdall.
    const sideBar = page.getByRole('navigation', { name: 'Side bar' })
    for (const id of MANY) {
      const name = `Board ${id} (Hello ${id})`
      await sideBar.getByRole('button', { exact: true, name }).click()
      const frame = page.frameLocator(`iframe[src="bifrost-module://${id}/panels/main.html"]`)
      await expect(frame.locator('#stored')).toHaveText('stored: hello from Heimdall', {
        timeout: SLOW,
      })
    }
    await expect(page.locator('iframe[data-module-panel]')).toHaveCount(MANY.length)

    // Each module frame has its own process. No module frame shares the process of the Bifrost
    // page.
    const processes = await app.evaluate(({ BrowserWindow }) => {
      const top = BrowserWindow.getAllWindows()[0].webContents.mainFrame
      const modules = top.framesInSubtree
        .filter(f => f.url.startsWith('bifrost-module://'))
        .map(f => ({ host: new URL(f.url).host, pid: f.osProcessId }))
      return { modules, top: top.osProcessId }
    })
    expect(processes.modules.map(m => m.host).sort()).toEqual([...MANY].sort())
    const pids = processes.modules.map(m => m.pid)
    for (const pid of pids) expect(pid).toBeGreaterThan(0)
    expect(new Set(pids).size).toBe(MANY.length)
    expect(pids).not.toContain(processes.top)
    test.info().annotations.push({ description: JSON.stringify(processes), type: 'processes' })
  } finally {
    await app?.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
