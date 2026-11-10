// The smoke test of the Updates section. In a test run the updater does not start. So the side
// bar has no update button, and Settings > Updates shows the "not available" form. The test also
// checks that the fake claude got no unknown call, that the test home has no updater log, and
// that the real updater log did not change.

import { mkdtemp, rm, stat } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, readText, realFiles, UNKNOWN_LOG } from './app.ts'

const REAL_UPDATER_LOG = join(homedir(), 'Library', 'Logs', 'Bifrost', 'updater.log')

// The mtime of a file in ms, or "missing". The test never creates or removes this file.
async function mtimeOf(path: string): Promise<number | 'missing'> {
  try {
    return (await stat(path)).mtimeMs
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return 'missing'
    throw err
  }
}

test('a test run shows the Updates section in the not available form', async () => {
  const before = await realFiles()
  const logBefore = await mtimeOf(REAL_UPDATER_LOG)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-updates-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()

    const setup = page.locator('[data-setup-dialog]')
    await expect(setup).toContainText('Set up Bifrost', { timeout: 15_000 })
    await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
    await expect(setup).toBeHidden()

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
    expect(await realFiles()).toEqual(before)
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
    expect(await mtimeOf(join(testHome, 'logs', 'updater.log'))).toBe('missing')
    // The installed Bifrost of the user can write the real updater.log during the run, for
    // example at its hourly check. Then this guard fails with no fault in the test app. Run the
    // test again.
    expect(await mtimeOf(REAL_UPDATER_LOG)).toBe(logBefore)
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
