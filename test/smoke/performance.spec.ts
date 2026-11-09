// The smoke test of the Performance panel. It starts Bifrost with a fake claude and a test home.
// It opens Performance from the side bar, waits for the headline, and opens and closes the
// Details row. It also checks that the real Claude files and ~/.bifrost did not change, and
// that the fakes got no unknown call.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, readText, realFiles, UNKNOWN_LOG } from './app.ts'

test('the Performance panel shows a headline and opens and closes the details', async () => {
  // Step 1: record the real files, make the test home and start the app.
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-performance-'))
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

    // Step 2: open Performance. The headline shows OK, Warning or Problem within 20 s.
    await page.getByRole('button', { exact: true, name: 'Performance' }).click()
    const panel = page.locator('[data-performance]')
    await expect(panel).toBeVisible()
    await expect(panel.locator('[data-perf-headline]')).toHaveAttribute(
      'data-perf-headline',
      /^(ok|warning|problem)$/,
      { timeout: 20_000 },
    )
    await expect(panel.locator('[data-perf-headline]')).toContainText(/OK|Warning|Problem/)

    // Step 3: the Details row starts closed. A click opens the Bifrost section with its rows.
    const details = panel.locator('[data-perf-details]')
    await expect(details).toHaveAttribute('aria-expanded', 'false')
    await expect(panel.locator('[data-perf-sections]')).toHaveCount(0)
    await details.click()
    await expect(details).toHaveAttribute('aria-expanded', 'true')
    const sections = panel.locator('[data-perf-sections]')
    await expect(sections).toBeVisible()
    await expect(sections.getByRole('heading', { exact: true, name: /^Bifrost/ })).toBeVisible()
    await expect(sections.getByText('Main process', { exact: true })).toBeVisible({
      timeout: 15_000,
    })

    // Step 4: a second click hides the sections.
    await details.click()
    await expect(details).toHaveAttribute('aria-expanded', 'false')
    await expect(panel.locator('[data-perf-sections]')).toHaveCount(0)

    // Step 5: quit the app. The real files did not change, and the fakes got no unknown call.
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
