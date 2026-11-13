// The smoke test of the Reviews panel (R1). It starts Bifrost with a fake claude, a fake gh and a
// test home. It turns on Watch GitHub in Settings, and it checks the To review rows, the flash
// of a new request after a refresh, and the My PRs rows. It also checks that the real Claude
// files and ~/.bifrost did not change, and that the fakes got no unknown call.
//
// The test does not click a row with the Cmd key, because that opens a browser. The main process
// uses the hidden window of a headless run as a window with the focus, so no notification starts.
// The test does not check notifications.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, readText, realFiles, skipSetup, UNKNOWN_LOG } from './app.ts'

test('the Reviews panel shows the PRs from the fake gh and flashes a new request', async () => {
  // Step 1: record the real files, make the test home and start the app.
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-reviews-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()

    await skipSetup(page)

    // Step 2: Settings > Reviews. Turn on Watch GitHub and accept the confirm.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settingsFrame.locator('[data-settings-tab="reviews"]').click()
    await settingsFrame.getByRole('checkbox', { name: /Watch GitHub/ }).click()
    const confirm = page.locator('[data-confirm-dialog]')
    await expect(confirm).toBeVisible()
    await confirm.locator('[data-confirm-ok]').click()
    await expect(confirm).toBeHidden()
    await settingsFrame.getByRole('button', { exact: true, name: 'Close' }).first().click()
    await expect(settingsFrame).toHaveCount(0)

    // Step 3: the Reviews panel shows the rows of reviews-1.json, with no flash.
    await page.getByRole('button', { exact: true, name: 'Reviews' }).click()
    const row = (key: string) => page.locator(`[data-review-row="${key}"]`)
    await expect(row('acme/web#101')).toBeVisible({ timeout: 30_000 })
    await expect(row('acme/api#7')).toBeVisible()
    await expect(row('acme/web#102')).toBeVisible()
    await expect(row('acme/web#103')).toHaveCount(0)
    await expect(page.locator('[data-review-flash]')).toHaveCount(0)
    await expect(page.locator('[data-reviews-count="to-review"]')).toHaveText('3')

    // Step 4: Refresh gives one new row with the flash overlay and a red tab count. The watcher
    // ignores a Refresh during a poll and for a short time after a poll starts. So the test
    // clicks again once when the first click had no effect.
    const refresh = page.getByRole('button', { exact: true, name: 'Refresh' })
    await refresh.click()
    try {
      await expect(row('acme/web#103')).toBeVisible({ timeout: 8_000 })
    } catch {
      await refresh.click()
      await expect(row('acme/web#103')).toBeVisible({ timeout: 15_000 })
    }
    await expect(row('acme/web#103').locator('[data-review-flash]')).toHaveCount(1)
    await expect(page.locator('[data-reviews-count="to-review"]')).toHaveText('4')
    await expect(page.locator('[data-reviews-count="to-review"]')).toHaveClass(/text-box-red/)

    // Step 5: My PRs shows the status words and one failed check mark.
    await page.locator('[data-reviews-tab="mine"]').click()
    await expect(row('acme/web#90')).toBeVisible()
    await expect(row('acme/web#90')).toContainText('Changes requested')
    await expect(row('acme/api#31')).toBeVisible()
    await expect(row('acme/api#31')).toContainText('Approved')
    await expect(page.locator('[data-review-row]', { hasText: '✕' })).toHaveCount(1)

    // Step 6: quit the app. The real files did not change, and the fakes got no unknown call.
    await app.close()
    app = null
    expect(await realFiles()).toEqual(before)
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
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
