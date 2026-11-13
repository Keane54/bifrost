// The smoke test of the Performance panel. It starts Bifrost with a fake claude and a test home.
// It opens Performance from the side bar, waits for the headline, and opens and closes the
// Details row. It also checks that the app uses only the test home, and that the fakes got no
// unknown call.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, skipSetup, UNKNOWN_LOG } from './app.ts'

test('the Performance panel shows a headline and opens and closes the details', async () => {
  // Step 1: make the test home and start the app.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-performance-'))
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
    // A clean run has no past event to clear, so the panel shows no Clear button.
    await expect(panel.locator('[data-perf-clear]')).toHaveCount(0)

    // Step 3: the Details row starts closed. A click opens the Bifrost section with its rows.
    const details = panel.locator('[data-perf-details]')
    await expect(details).toHaveAttribute('aria-expanded', 'false')
    await expect(panel.locator('[data-perf-sections]')).toHaveCount(0)
    await details.click()
    await expect(details).toHaveAttribute('aria-expanded', 'true')
    const sections = panel.locator('[data-perf-sections]')
    await expect(sections).toBeVisible()
    await expect(sections.getByRole('heading', { exact: true, name: /^Bifrost/ })).toBeVisible()
    // Only the Bifrost section has the Main process row. The check looks only in that section.
    // The locator in "has" is relative to each section.
    const bifrostSection = sections
      .locator('section')
      .filter({ has: page.getByRole('heading', { name: /^Bifrost/ }) })
    await expect(bifrostSection.getByText('Main process', { exact: true })).toBeVisible({
      timeout: 15_000,
    })

    // Step 4: a second click hides the sections.
    await details.click()
    await expect(details).toHaveAttribute('aria-expanded', 'false')
    await expect(panel.locator('[data-perf-sections]')).toHaveCount(0)

    // Step 5: quit the app. The fakes got no unknown call.
    await app.close()
    app = null
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
