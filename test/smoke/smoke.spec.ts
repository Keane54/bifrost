// The smoke test of spec 15 (D23). It starts Bifrost with a fake claude and a test home. It checks
// the setup dialog, the sample sessions, the Parked tab and one chat window. It also checks that
// the real Claude files and ~/.bifrost did not change, and that the fake claude got no unknown
// call.
//
// app.ts tells how to start the build in out/ or the packaged app.

import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, type Locator, test } from '@playwright/test'
import {
  launchOptions,
  makeSessionFolders,
  readText,
  realFiles,
  SESSION_ROOT,
  UNKNOWN_LOG,
} from './app.ts'

test('Bifrost starts with a fake claude and shows the sample sessions', async () => {
  // Step 1: record the real files, and make the test home.
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-smoke-'))
  const appOutput: string[] = []
  // Set before the first mkdir. So a failed mkdir still removes a root folder that this run made.
  const madeSessionRoot = !existsSync(SESSION_ROOT)
  let app: ElectronApplication | null = null
  let tracing = false
  try {
    await makeSessionFolders()

    // Step 2: start the app.
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    await app.context().tracing.start({ screenshots: true, snapshots: true })
    tracing = true
    const page = await app.firstWindow()

    // Step 3: the fake claude lists no Bifrost plugin, so the setup dialog shows.
    const setup = page.locator('[data-setup-dialog]')
    await expect(setup).toContainText('Set up Bifrost', { timeout: 15_000 })
    await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
    await expect(setup).toBeHidden()

    // Step 4: the All tab shows the two active sessions, but not the parked session.
    const overview = page.locator('[data-overview-id]').first()
    const row = (name: string): Locator =>
      overview.locator('tr[data-session-id]', { hasText: name })
    await expect(row('smoke-alpha')).toBeVisible({ timeout: 15_000 })
    await expect(row('smoke-beta')).toBeVisible()
    await expect(row('smoke-gamma')).toHaveCount(0)

    // Step 5: the Parked tab shows the parked session. It comes from the first --all poll.
    await overview.getByRole('tab', { exact: true, name: 'Parked' }).click()
    await expect(row('smoke-gamma')).toBeVisible({ timeout: 15_000 })
    await overview.getByRole('tab', { exact: true, name: 'All' }).click()
    await expect(row('smoke-alpha')).toBeVisible()
    await expect(row('smoke-gamma')).toHaveCount(0)

    // Step 6: a double-click opens a chat window. Its attach runs the fake claude through
    // node-pty and spawn-helper. WebGL draws the terminal text, so the DOM has no text to read
    // (R7). The fake claude writes the attach line to a file in the test home.
    await row('smoke-alpha').dblclick()
    await expect
      .poll(() => readText(join(testHome, 'attach.log')), { timeout: 10_000 })
      .toContain('FAKE ATTACH 5a0e0001')

    // Step 7: quit the app.
    tracing = false
    await app.context().tracing.stop()
    await app.close()
    app = null

    // Step 8: the Skip choice is in the test home. The real Claude files and ~/.bifrost did not
    // change. Live details is not installed, so no live server made a socket. The fake claude
    // got only the calls that it knows.
    const settings = JSON.parse(
      await readFile(join(testHome, 'user-data', 'settings.json'), 'utf8'),
    )
    expect(settings.setupDone).toBe(true)
    expect(await realFiles()).toEqual(before)
    expect(existsSync(join(testHome, '.bifrost', 'live.sock'))).toBe(false)
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
  } catch (err) {
    // Keep the trace and the output of the app in test-results/ for the person who reads the
    // failure.
    if (app !== null && tracing) {
      await app
        .context()
        .tracing.stop({ path: test.info().outputPath('trace.zip') })
        .catch(() => {})
    }
    await test.info().attach('app-output.txt', {
      body: appOutput.join(''),
      contentType: 'text/plain',
    })
    throw err
  } finally {
    if (app !== null) await app.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
    if (madeSessionRoot) await rm(SESSION_ROOT, { force: true, recursive: true })
  }
})
