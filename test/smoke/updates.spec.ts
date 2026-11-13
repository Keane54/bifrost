// The smoke test of the Updates section. In a test run the updater does not start. So the side
// bar has no update button, and Settings > Updates shows the "not available" form. The test also
// checks that the app uses only the test home, that the fake claude got no unknown call, and that
// the test home has no updater log.

import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, skipSetup, UNKNOWN_LOG } from './app.ts'

// The mtime of a file in ms, or "missing".
async function mtimeOf(path: string): Promise<number | 'missing'> {
  try {
    return (await stat(path)).mtimeMs
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return 'missing'
    throw err
  }
}

test('a test run shows the Updates section in the not available form', async () => {
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-updates-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)

    await skipSetup(page)

    // The side bar has no update button.
    await expect(page.getByRole('button', { exact: true, name: 'Settings' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Update Bifrost' })).toHaveCount(0)

    // Settings > Updates.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settingsFrame.locator('[data-settings-tab="updates"]').click()
    await expect(settingsFrame.locator('[data-updates-state]')).toHaveText(
      "This build doesn't update itself.",
    )
    await expect(
      settingsFrame.getByRole('checkbox', { name: 'Check for updates automatically' }),
    ).toBeChecked()
    await expect(settingsFrame.locator('[data-updates-action]')).toHaveCount(0)

    // Quit the app. Nothing ran that should not run.
    await app.close()
    app = null
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
    expect(await mtimeOf(join(testHome, 'logs', 'updater.log'))).toBe('missing')
  } catch (err) {
    await test.info().attach('app-output.txt', {
      body: appOutput.join(''),
      contentType: 'text/plain',
    })
    throw err
  } finally {
    if (app !== null) await app.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
