// The smoke test of spec 15 (D23). It starts Bifrost with a fake claude and a test home. It checks
// the setup dialog, the sample sessions, the animated background, the Parked tab and one chat
// window. It also checks that the real Claude files and ~/.bifrost did not change, and that the
// fake claude got no unknown call.
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

    // Step 4b: the animated background (spec 8.10) is behind the frames and moves. Each layer is a
    // canvas with a size. With reduced motion, it stays still. A frame has the blur only while it
    // overlaps a lower frame (user decision, 2026-11-10).
    const layer = page.locator('.background')
    const fields = page.locator('.background canvas.background-field')
    await expect(fields).toHaveCount(6)
    await expect(page.locator('.background canvas.background-base')).toHaveCount(1)
    await expect(fields.first()).toHaveCSS('animation-name', 'background-drift-1')
    const sizes = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLCanvasElement>('.background canvas')].map(c =>
        Math.min(c.width, c.height),
      ),
    )
    expect(sizes).toHaveLength(7)
    for (const size of sizes) expect(size).toBeGreaterThan(1)
    // The default layout depends on the size of the screen. On a small screen, its frames can
    // overlap, for example on the CI runner. So the test finds the overlaps from the rects and the
    // z-order of the frames that show. Frames that only touch at an edge do not overlap.
    const frameBlur = await page.evaluate(() => {
      const shown = [...document.querySelectorAll<HTMLElement>('[data-frame-id]')]
        .map(el => ({
          id: el.dataset.frameId ?? '',
          rect: el.getBoundingClientRect(),
          z: Number(getComputedStyle(el).zIndex) || 0,
        }))
        .filter(f => f.rect.width > 0 && f.rect.height > 0)
        .sort((a, b) => a.z - b.z)
      const overlap = (a: DOMRect, b: DOMRect): boolean =>
        Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
        Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5
      return shown.map((f, i) => ({
        blur: shown.slice(0, i).some(lower => overlap(f.rect, lower.rect)),
        id: f.id,
      }))
    })
    expect(frameBlur.length).toBeGreaterThan(0)
    expect(frameBlur[0].blur).toBe(false)
    for (const { blur, id } of frameBlur) {
      await expect(page.locator(`[data-frame-id="${id}"]`)).toHaveCSS(
        'backdrop-filter',
        blur ? 'blur(8px)' : 'none',
      )
    }
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await expect(layer).toHaveClass('background background-still')
    await expect(fields.first()).toHaveCSS('animation-name', 'none')
    await page.emulateMedia({ reducedMotion: 'no-preference' })
    await expect(fields.first()).toHaveCSS('animation-name', 'background-drift-1')

    // Step 4c: the fields pause where they are while the window does not have the focus, and
    // when the setting goes off. The real focus of the test window depends on the other apps of
    // the Mac. So the test sets the focus answer of the page, and then sends the event.
    const field = fields.first()
    const setFocus = (focus: boolean): Promise<void> =>
      page.evaluate(value => {
        Object.defineProperty(document, 'hasFocus', { configurable: true, value: () => value })
        window.dispatchEvent(new Event(value ? 'focus' : 'blur'))
      }, focus)
    const transform = (): Promise<string> => field.evaluate(el => getComputedStyle(el).transform)
    // The times of the background animations, read each 2 ms for the given time. The view holds
    // the animations (paused) and sets their time from one clock 30 times each second (user
    // decision, 2026-11-10). So the times are equal, and they change about 30 times each second,
    // not at each refresh of the display.
    const clock = (ms: number) =>
      page.evaluate(
        span =>
          new Promise<{ count: number; changes: number; oneClock: boolean; states: string[] }>(
            resolve => {
              const anims = document.querySelector('.background')?.getAnimations({ subtree: true })
              const all = anims ?? []
              const states = new Set<string>()
              let oneClock = true
              let last: number | null = null
              let changes = 0
              const start = performance.now()
              const read = (): void => {
                const times = new Set(all.map(a => Number(a.currentTime)))
                for (const a of all) states.add(a.playState)
                if (times.size !== 1) oneClock = false
                const time = Math.min(...times)
                if (last !== null && time !== last) changes += 1
                last = time
                if (performance.now() - start < span) setTimeout(read, 2)
                else resolve({ changes, count: all.length, oneClock, states: [...states] })
              }
              read()
            },
          ),
        ms,
      )
    const animationTime = (): Promise<number> =>
      page.evaluate(() =>
        Number(
          document.querySelector('.background')?.getAnimations({ subtree: true })[0]?.currentTime,
        ),
      )
    await setFocus(true)
    await expect(layer).toHaveClass('background')
    await expect(field).toHaveCSS('animation-play-state', 'running')
    const steps = await clock(1000)
    expect(steps.count).toBe(7)
    expect(steps.states).toEqual(['paused'])
    expect(steps.oneClock).toBe(true)
    expect(steps.changes).toBeGreaterThanOrEqual(10)
    expect(steps.changes).toBeLessThanOrEqual(40)
    await setFocus(false)
    await expect(layer).toHaveClass('background background-paused')
    await expect(field).toHaveCSS('animation-play-state', 'paused')
    await expect(field).toHaveCSS('animation-name', 'background-drift-1')
    // No jump to the still position, and no motion during the pause.
    const pausedAt = await transform()
    const pausedTime = await animationTime()
    expect(pausedAt).not.toBe('none')
    expect((await clock(500)).changes).toBe(0)
    expect(await transform()).toBe(pausedAt)
    await setFocus(true)
    await expect(field).toHaveCSS('animation-play-state', 'running')
    // The motion continues from the paused time, with no jump.
    await expect.poll(animationTime).toBeGreaterThan(pausedTime)
    expect((await animationTime()) - pausedTime).toBeLessThan(2000)
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    // The Settings frame opens over the Overview, so it has the light blur. The Overview frame is
    // the lowest frame, so it has no blur.
    await expect(settingsFrame).toHaveCSS('backdrop-filter', 'blur(8px)')
    await expect(page.locator('[data-frame-id]').first()).toHaveCSS('backdrop-filter', 'none')
    const animatedCheck = settingsFrame.getByRole('checkbox', { name: 'Animated background' })
    await animatedCheck.click()
    await expect(layer).toHaveClass('background background-paused')
    expect(await transform()).not.toBe('none')
    await animatedCheck.click()
    await expect(layer).toHaveClass('background')
    await settingsFrame.getByRole('button', { exact: true, name: 'Close' }).first().click()
    await expect(settingsFrame).toHaveCount(0)
    // The page gets its real focus answer back.
    await page.evaluate(() => {
      delete (document as { hasFocus?: unknown }).hasFocus
    })

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
