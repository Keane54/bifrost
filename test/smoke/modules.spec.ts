// The install of a module from a folder (plan Task 9). The test copies the greeter module into the
// test home, and answers the folder dialog in the main process, as release-notes.spec.ts answers
// shell.openExternal. Settings > Modules starts the install. Heimdall's panel shows the approval in
// its purple frame, and the module runs only after Allow. Its panel then calls storage and notify.
// A change of the state reaches the page through modules:changed: when the user turns the module
// off in Settings while its panel is open, the panel shows the notice (Review Focus 3).
//
// Discuss with Claude (plan Task 10). The planner module asks Heimdall to discuss. Heimdall's panel
// opens with an empty prompt box. The test copies the card through a fake clipboard, types a
// prompt and picks the test folder. Start runs the fake claude, which writes its arguments to
// session-args.log in the test home. The prompt is exactly the typed text.

import { cp, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, skipSetup, UNKNOWN_LOG } from './app.ts'

const FIXTURE = join(import.meta.dirname, 'fixtures', 'modules', 'greeter')
const PLANNER = join(import.meta.dirname, 'fixtures', 'modules', 'planner')
// The statusline override of each new session.
const STATUSLINE = '{"statusLine":{"type":"command","command":"true"}}'
const NOTICE = 'This module is off or no longer installed.'
// The longest wait for a condition. A slow machine gets the time it needs.
const SLOW = 20_000

test('a module installs from a folder, runs after Allow, and goes off at once', async () => {
  test.setTimeout(150_000)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-modules-'))
  const folder = join(testHome, 'greeter-source')
  let app: ElectronApplication | null = null
  try {
    await cp(FIXTURE, folder, { recursive: true })
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)

    // The folder dialog must not show. So replace it in the main process, and check that the
    // change took effect before any click.
    await app.evaluate(({ dialog }, dir) => {
      const stub = async () => ({ canceled: false, filePaths: [dir] })
      Object.assign(globalThis, { bifrostPickStub: stub })
      dialog.showOpenDialog = stub as unknown as typeof dialog.showOpenDialog
    }, folder)
    const stubbed = await app.evaluate(
      ({ dialog }) =>
        dialog.showOpenDialog === (globalThis as { bifrostPickStub?: unknown }).bifrostPickStub,
    )
    expect(stubbed).toBe(true)

    await skipSetup(page)
    const sideBar = page.getByRole('navigation', { name: 'Side bar' })
    const panelButton = sideBar.getByRole('button', {
      exact: true,
      name: 'Greeter board (Greeter)',
    })

    // Settings > Modules has no module yet.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settings = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settings.locator('[data-settings-tab="modules"]').click()
    await expect(settings.locator('[data-settings-section="modules"]')).toContainText(
      "You haven't installed any modules yet.",
    )

    // Install from a folder opens Heimdall's panel with the approval. The module does not run yet.
    await settings.getByRole('button', { exact: true, name: 'Install from a folder' }).click()
    const approval = page.locator('[data-heimdall-approval]')
    await expect(approval).toBeVisible({ timeout: SLOW })
    await expect(page.locator('[data-panel-id="heimdall"]')).toContainText('Greeter v1.0.0')
    await expect(approval).toContainText('Standard')
    await expect(approval).toContainText('Show notifications')
    await expect(approval).toContainText('To say hello when the panel opens.')
    await expect(approval).toContainText('What it can never do')
    await expect(page.locator('[data-heimdall-frame]')).toHaveCount(1)
    await expect(panelButton).toHaveCount(0)

    // Allow installs the module. Heimdall's panel closes, and Settings shows the row.
    await approval.getByRole('button', { exact: true, name: 'Allow' }).click()
    await expect(approval).toHaveCount(0)
    const row = settings.locator('[data-module-row="greeter"]')
    await expect(row).toContainText('Greeter')
    await expect(row).toContainText('v1.0.0')
    await expect(row.locator('[data-module-tier-badge="standard"]')).toHaveText('Standard')
    await expect(panelButton).toBeVisible()

    // The panel of the module runs in its frame, and calls storage and notify through Heimdall.
    await panelButton.click()
    const inFrame = page.frameLocator('iframe[data-module-panel="main"]')
    await expect(inFrame.locator('#stored')).toHaveText('stored: hello again', { timeout: SLOW })
    await expect(inFrame.locator('#notified')).toHaveText('notified')
    await expect
      .poll(() =>
        app?.evaluate(() =>
          (
            (globalThis as { bifrostNotifications?: { title: string; body: string }[] })
              .bifrostNotifications ?? []
          ).map(n => `${n.title} | ${n.body}`),
        ),
      )
      .toContain('Greeter: Hello | The panel is open.')

    // Turn the module off in Settings while its panel is open. The new state reaches the page
    // through modules:changed, and the panel shows the notice in place of the frame.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    await row.locator('[data-module-switch="greeter"]').click()
    await expect(page.locator('[data-module-notice]')).toHaveText(NOTICE, { timeout: SLOW })
    await expect(page.locator('iframe[data-module-panel]')).toHaveCount(0)
    await expect(panelButton).toHaveCount(0)

    // The saved state has the approved values: the requested permission, and the model and cap
    // that the module suggests.
    const state = JSON.parse(
      await readFile(join(testHome, '.bifrost', 'modules', 'state.json'), 'utf8'),
    )
    expect(state.modules.greeter).toMatchObject({
      dailyCap: 5,
      enabled: false,
      granted: ['notify'],
      model: 'haiku',
      source: { kind: 'folder', path: folder },
    })
  } finally {
    await app?.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})

// Put the planner module in the modules state of the test home, on, with the discuss permission.
async function seedPlanner(bifrostHome: string): Promise<void> {
  await cp(PLANNER, join(bifrostHome, 'modules', 'planner', 'current'), { recursive: true })
  const manifest = JSON.parse(await readFile(join(PLANNER, 'bifrost-module.json'), 'utf8'))
  const planner = {
    dailyCap: 5,
    enabled: true,
    granted: ['discuss'],
    hash: '0'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest,
    model: '',
    pendingUpdate: null,
    source: { kind: 'folder', path: PLANNER },
  }
  await writeFile(
    join(bifrostHome, 'modules', 'state.json'),
    JSON.stringify({ modules: { planner } }),
  )
}

test('a module asks to discuss, and the session gets only the prompt of the user', async () => {
  test.setTimeout(120_000)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-discuss-'))
  const project = join(testHome, 'project')
  const typed = 'Help me plan my week.'
  let app: ElectronApplication | null = null
  try {
    await mkdir(project, { recursive: true })
    await mkdir(join(testHome, '.bifrost'), { recursive: true })
    await seedPlanner(join(testHome, '.bifrost'))
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)

    // The folder dialog must not show, and Copy must not write the real clipboard. So replace
    // both in the main process, and check that the change took effect before any click.
    await app.evaluate(({ clipboard, dialog }, dir) => {
      const pick = async () => ({ canceled: false, filePaths: [dir] })
      const copies: string[] = []
      const write = async (text: string): Promise<void> => {
        copies.push(text)
      }
      Object.assign(globalThis, {
        bifrostCopies: copies,
        bifrostPickStub: pick,
        bifrostWriteStub: write,
      })
      dialog.showOpenDialog = pick as unknown as typeof dialog.showOpenDialog
      clipboard.writeText = write
    }, project)
    const stubbed = await app.evaluate(({ clipboard, dialog }) => {
      const stubs = globalThis as { bifrostPickStub?: unknown; bifrostWriteStub?: unknown }
      return (
        dialog.showOpenDialog === stubs.bifrostPickStub &&
        clipboard.writeText === stubs.bifrostWriteStub
      )
    })
    expect(stubbed).toBe(true)
    await skipSetup(page)

    // The panel of the module asks to discuss. The module gets null and nothing else.
    const sideBar = page.getByRole('navigation', { name: 'Side bar' })
    await sideBar.getByRole('button', { exact: true, name: 'Planner board (Planner)' }).click()
    const inFrame = page.frameLocator('iframe[data-module-panel="main"]')
    await expect(inFrame.locator('#asked')).toHaveText('asked: null', { timeout: SLOW })

    // Heimdall's panel opens in its purple frame, with the card and an empty prompt box.
    const view = page.locator('[data-heimdall-discuss]')
    await expect(view).toBeVisible({ timeout: SLOW })
    await expect(page.locator('[data-heimdall-frame]')).toHaveCount(1)
    await expect(page.locator('[data-panel-id="heimdall"]')).toContainText(
      'Discuss with Claude · Planner',
    )
    await expect(view).toContainText('Plan the week')
    await expect(view).toContainText('This week')
    await expect(view).toContainText('Your normal Claude setup')
    const prompt = view.locator('[data-discuss-prompt]')
    await expect(prompt).toHaveValue('')

    // Copy goes through the main process, and the copy has no zero-width space.
    const copy = view.locator('[data-discuss-copy="0"]')
    await copy.click()
    await expect(copy).toHaveText('Copied')
    const copies = await app.evaluate(
      () => (globalThis as { bifrostCopies?: string[] }).bifrostCopies ?? [],
    )
    expect(copies).toEqual(['Ship the release notes.'])

    // The user picks the folder and types the prompt. Start runs the fake claude.
    await view.getByRole('button', { exact: true, name: 'Choose...' }).click()
    await expect(view.locator('[data-discuss-folder]')).toHaveValue(project)
    await prompt.fill(typed)
    await view.getByRole('button', { exact: true, name: 'Start session' }).click()
    await expect(view).toHaveCount(0, { timeout: SLOW })
    await expect(page.locator('[data-heimdall-frame]')).toHaveCount(0)

    // claude got the normal setup, the label of the module and exactly the typed prompt, in the
    // real path of the folder. No card text got to it. The name holds the words of the user, not
    // the title of the module (ruling P13).
    const log = join(testHome, 'session-args.log')
    await expect.poll(() => readText(log), { timeout: SLOW }).not.toBe('')
    const name = `Planner: ${typed}`
    const args = ['--bg', '--settings', STATUSLINE, '--name', name, typed]
    const lines = args.map(arg => `arg: ${arg}\n`).join('')
    expect(await readText(log)).toBe(`cwd: ${await realpath(project)}\n${lines}`)

    // The session is an ordinary Bifrost session with the label of the module.
    await expect
      .poll(
        () =>
          page.evaluate(async () => {
            const api = (
              window as unknown as {
                bifrost: { registry: { rows(): Promise<{ name: string }[]> } }
              }
            ).bifrost.registry
            return (await api.rows()).map(row => row.name)
          }),
        { timeout: SLOW },
      )
      .toContain(name)

    // The fake claude knew each call of Bifrost.
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
  } finally {
    await app?.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
