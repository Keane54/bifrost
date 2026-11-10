// The status icon of the Selected Item panel (spec 8.4). The texts under the send box moved to a
// tooltip in the name line. The test takes two screenshots: with no text, and with a text.
//
// The test uses the same start as the smoke test (app.ts): a fake claude and a test home.

import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, skipSetup } from './app.ts'

const SLASH = 'This runs as a slash command.'
const SHOTS = process.env.BIFROST_SHOT_DIR

test('the Selected Item panel shows a status icon only when a text exists', async () => {
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-status-'))
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    await skipSetup(page)

    const alpha = page
      .locator('[data-overview-id]')
      .first()
      .locator('tr[data-session-id]', { hasText: 'smoke-alpha' })
    await expect(alpha).toBeVisible({ timeout: 15_000 })
    await alpha.click()
    const panel = page.locator('[data-selected-item]').first()
    await expect(panel.locator('[data-send-box]')).toBeVisible()
    // No text: no icon, and no line under the send box.
    await expect(panel.locator('[data-status-icon]')).toHaveCount(0)
    if (SHOTS) {
      await mkdir(SHOTS, { recursive: true })
      await panel.screenshot({ path: join(SHOTS, 'no-text.png') })
    }

    // A slash gives the hint. The hint shows in the icon, not under the box.
    await panel.locator('textarea').fill('/')
    const icon = panel.locator('[data-status-icon="info"]')
    await expect(icon).toHaveCount(1)
    await expect(icon).toHaveAttribute('aria-label', 'This runs as a slash command.')
    await expect(panel.locator('[data-send-line]')).toHaveCount(0)
    await expect(panel.locator('[aria-live="polite"]')).toHaveText('This runs as a slash command.')

    // A key focus shows the tooltip. The real mouse shares the normal pointer, so the test does not
    // use a mouse here.
    await page.keyboard.press('Shift')
    await icon.focus()
    await expect(page.locator('.whitespace-pre-line', { hasText: SLASH })).toBeVisible({
      timeout: 5000,
    })
    if (SHOTS) await page.screenshot({ path: join(SHOTS, 'with-text.png') })
  } finally {
    if (app !== null) await app.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
