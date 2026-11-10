// The layout checks of the M5b final fix wave. Each check needs the running app, because the
// browser layout and the focus rules of Base UI decide the result:
// - M5a carry-over 1: Esc in the Rename dialog gives the focus back to the Overview rows.
// - The Usage HUD shows all its lines at its default size.
// - M5a carry-over 2: in a narrow Settings frame, a key row that records keeps its name visible,
//   and its Clear and Reset buttons stay in the frame.
// - Esc toggles Settings (spec 9.4). A dialog and the key recorder keep their own Esc.
// - The search of Settings (spec 12): Cmd+F, matches in two sections, a key search, no match,
//   and Esc in the search field.
//
// The test uses the same start as the smoke test (app.ts): a fake claude and a test home.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  _electron,
  type ElectronApplication,
  expect,
  type Locator,
  type Page,
  test,
} from '@playwright/test'
import { launchOptions, readText, realFiles, skipSetup, UNKNOWN_LOG } from './app.ts'

// The width of the narrow Settings frame of the M5a check.
const NARROW_W = 360

interface Point {
  x: number
  y: number
}

async function box(locator: Locator): Promise<{ x: number; y: number; w: number; h: number }> {
  const b = await locator.boundingBox()
  if (b === null) throw new Error('The element has no box.')
  return { h: b.height, w: b.width, x: b.x, y: b.y }
}

// A drag from one point to another point in steps, with a pen pointer of the CDP Input domain.
// In Chromium, the Playwright mouse and the real mouse of the Mac have the same pointer ID (1).
// If a person moves the real mouse over the test window during a mouse drag, the page gets a
// move of pointer 1 with no button down. Chromium then releases the pointer capture, and Bifrost
// ends the drag, because a move with no button down means a lost pointer up. The pen pointer has
// a different ID, so the real mouse cannot stop this drag. Bifrost uses the same pointer events
// for a pen and for a mouse.
async function penDrag(page: Page, from: Point, to: Point, steps: number): Promise<void> {
  const cdp = await page.context().newCDPSession(page)
  // buttons is 1 while the pen touches, and 0 before and after.
  const send = (
    type: 'mouseMoved' | 'mousePressed' | 'mouseReleased',
    at: Point,
    buttons: number,
  ) =>
    cdp.send('Input.dispatchMouseEvent', {
      button: type === 'mouseMoved' ? 'none' : 'left',
      buttons,
      clickCount: type === 'mouseMoved' ? 0 : 1,
      pointerType: 'pen',
      type,
      x: at.x,
      y: at.y,
    })
  try {
    await send('mouseMoved', from, 0)
    await send('mousePressed', from, 1)
    for (let i = 1; i <= steps; i++) {
      const part = i / steps
      const at = { x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part }
      await send('mouseMoved', at, 1)
    }
    await send('mouseReleased', to, 0)
  } finally {
    await cdp.detach()
  }
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

    await skipSetup(page)

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
    // The Esc of the dialog does not also open Settings.
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await expect(settingsFrame).toHaveCount(0)

    // The last line of the Usage HUD is inside the frame at the default size.
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
    const grab = { x: edge.x + edge.w / 2, y: edge.y + edge.h / 2 }
    await penDrag(page, grab, { x: grab.x - (start.w - NARROW_W), y: grab.y }, 8)
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
    // The Esc of the key recorder does not also close Settings.
    await expect(frame).toBeVisible()
    // Settings is the active panel of the top frame. So the next Esc closes it, and one more Esc
    // opens it again. The selection stays.
    await page.keyboard.press('Escape')
    await expect(frame).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(frame).toBeVisible()
    const alphaId = await alpha.getAttribute('data-session-id')
    await expect(page.locator('[data-selected-item]')).toHaveAttribute(
      'data-selected-item',
      alphaId ?? 'no id',
    )

    // The search of Settings. A click on a tab puts the focus in Settings, and Cmd+F moves it
    // to the search field.
    await frame.locator('[data-settings-tab="general"]').click()
    await page.keyboard.press('Meta+f')
    const search = frame.locator('[data-settings-search]')
    await expect(search).toBeFocused()
    await search.fill('open')
    await expect(frame.locator('[data-search-section="general"]')).toBeVisible()
    await expect(frame.locator('[data-search-section="keys"]')).toBeVisible()
    await search.fill('cmd shift t')
    await expect(frame.locator('[data-search-section]')).toHaveCount(1)
    await expect(frame.locator('[data-key-slot="take-control:mod"]')).toBeVisible()
    await expect(frame.getByRole('status')).toHaveText('1 setting matches.')
    await search.fill('xyz')
    await expect(frame.locator('[data-settings-no-match]')).toHaveText('No settings match "xyz".')
    // Esc clears the field first. Then Esc in the empty field closes Settings.
    await page.keyboard.press('Escape')
    await expect(search).toHaveValue('')
    await expect(frame).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(frame).toHaveCount(0)

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
