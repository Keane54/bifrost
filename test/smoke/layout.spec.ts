// The layout checks of the M5b final fix wave. Each check needs the running app, because the
// browser layout and the focus rules of Base UI decide the result:
// - M5a carry-over 1: Esc in the Rename dialog gives the focus back to the Overview rows.
// - Bug B2: the Usage HUD shows all its lines at its default size.
// - M5a carry-over 2: in a narrow Settings frame, a key row that records keeps its name visible,
//   and its Clear and Reset buttons stay in the frame.
//
// The test uses the same start as the smoke test (app.ts): a fake claude and a test home.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, type Locator, test } from '@playwright/test'
import { launchOptions, readText, realFiles, UNKNOWN_LOG } from './app.ts'

// The width of the narrow Settings frame of the M5a check.
const NARROW_W = 360

async function box(locator: Locator): Promise<{ x: number; y: number; w: number; h: number }> {
  const b = await locator.boundingBox()
  if (b === null) throw new Error('The element has no box.')
  return { h: b.height, w: b.width, x: b.x, y: b.y }
}

test('the Rename dialog, the Usage HUD and a narrow Settings frame keep their layout', async () => {
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-layout-'))
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

    // M5a carry-over 1. A click on a row focuses the rows. R opens the Rename dialog of the
    // selected owned session. Esc closes it, and the rows get the focus again.
    const overview = page.locator('[data-overview-id]').first()
    const rowsArea = overview.locator('[data-overview-rows]')
    const alpha = overview.locator('tr[data-session-id]', { hasText: 'smoke-alpha' })
    await expect(alpha).toBeVisible({ timeout: 15_000 })
    await alpha.click()
    await expect(rowsArea).toBeFocused()
    await page.keyboard.press('r')
    const rename = page.locator('[data-rename-dialog]')
    await expect(rename).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(rename).toBeHidden()
    // A soft check: a failure here does not stop the other checks.
    await expect.soft(rowsArea).toBeFocused()

    // Bug B2. The last line of the Usage HUD is inside the frame at the default size.
    await page.getByRole('button', { exact: true, name: 'Usage HUD' }).click()
    const hud = page.locator('[data-usage-hud]')
    await expect(hud).toBeVisible()
    const hidden = await hud.evaluate(el => el.scrollHeight - el.clientHeight)
    expect.soft(hidden, 'the HUD content fits').toBeLessThanOrEqual(0)

    // M5a carry-over 2. Drag the right edge of the Settings frame to make it narrow.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const frame = page.locator('[data-frame-id]', { has: page.locator('[data-settings-section]') })
    await expect(frame).toBeVisible()
    const start = await box(frame)
    const edge = await box(frame.locator('[data-edge="e"]'))
    const grabX = edge.x + edge.w / 2
    const grabY = edge.y + edge.h / 2
    await page.mouse.move(grabX, grabY)
    await page.mouse.down()
    await page.mouse.move(grabX - (start.w - NARROW_W), grabY, { steps: 8 })
    await page.mouse.up()
    const narrow = await box(frame)
    expect(Math.abs(narrow.w - NARROW_W)).toBeLessThanOrEqual(12)

    await frame.locator('[data-settings-tab="keys"]').click()
    const slot = frame.locator('[data-key-slot]').first()
    await slot.getByRole('button', { exact: true, name: 'Change' }).click()
    await expect(slot.locator('[data-key-recorder]')).toBeFocused()
    const right = narrow.x + narrow.w
    // The first span of the row is the name.
    const name = await box(slot.locator('span').first())
    expect.soft(name.w, 'the name is visible').toBeGreaterThanOrEqual(40)
    expect.soft(name.x + name.w, 'the name is inside the frame').toBeLessThanOrEqual(right)
    for (const label of ['Change', 'Clear', 'Reset']) {
      const button = await box(slot.getByRole('button', { exact: true, name: label }))
      expect.soft(button.x + button.w, `${label} is inside the frame`).toBeLessThanOrEqual(right)
    }
    await page.keyboard.press('Escape')
    await expect(slot.locator('[data-key-recorder]')).toHaveCount(0)

    await app.close()
    app = null

    // The test changed no real file, and the fake claude got only the calls that it knows.
    expect(await realFiles()).toEqual(before)
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
  } catch (err) {
    await test.info().attach('app-output.txt', {
      body: appOutput.join(''),
      contentType: 'text/plain',
    })
    if (app !== null) {
      const page = await app.firstWindow().catch(() => null)
      const shot = await page?.screenshot().catch(() => null)
      if (shot) await test.info().attach('screen.png', { body: shot, contentType: 'image/png' })
    }
    throw err
  } finally {
    if (app !== null) await app.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
