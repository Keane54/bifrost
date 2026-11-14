// The smoke test of dictation (dictation design). It starts Bifrost with the fake claude, the fake
// speech helper and a test home. The fake helper never opens the microphone and never records or
// plays audio. The fake attach writes the input of the chat window to a file in the test home.
// The test checks these points:
// - A hold of Space in a chat window types the text of the fake helper into the input of the fake
//   session, and the frame shows the green look while the key is held.
// - A tap of Space types a space.
// - Settings > Keys has the Dictation key under its own heading. The recorder takes a plain Space
//   for it.
//
// app.ts tells how to start the build in out/ or the packaged app.

import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import {
  expectTestHomeOnly,
  launchOptions,
  makeSessionFolders,
  readText,
  SESSION_ROOT,
  skipSetup,
  UNKNOWN_LOG,
} from './app.ts'

const SESSION_ID = '5a0e0001-0000-4000-8000-000000000001'
// The text of the fake helper (test/smoke/fake-dictation/bifrost-dictation).
const FAKE_TEXT = 'Hello from the fake helper.'
const DICTATION_SLOT = 'dictation:hold'

// The text that the chat window sent to the fake session, with no escape sequences. xterm.js can
// send a reply to a query of the terminal. Such a reply is not text of the user.
function typedText(input: string): string {
  // biome-ignore lint/suspicious/noControlCharactersInRegex: the escape sequences start with ESC.
  return input.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]/g, '')
}

test('a hold of Space dictates into a chat window, and a tap types a space', async () => {
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-smoke-'))
  const appOutput: string[] = []
  const madeSessionRoot = !existsSync(SESSION_ROOT)
  let app: ElectronApplication | null = null
  try {
    await makeSessionFolders()
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    await expectTestHomeOnly(app, testHome)
    await skipSetup(page)

    // Step 1: a double-click opens the chat window of smoke-alpha. The fake attach starts.
    const overview = page.locator('[data-overview-id]').first()
    const alpha = overview.locator('tr[data-session-id]', { hasText: 'smoke-alpha' })
    await expect(alpha).toBeVisible({ timeout: 15_000 })
    await alpha.dblclick()
    await expect
      .poll(() => readText(join(testHome, 'attach.log')), { timeout: 10_000 })
      .toContain('FAKE ATTACH 5a0e0001')
    const input = (): Promise<string> =>
      readText(join(testHome, 'attach-input-5a0e0001.log')).then(typedText)
    const chat = page.locator(`[data-chat-terminal="${SESSION_ID}"]`)
    const frame = page.locator('[data-frame-id]', { has: chat })
    const textarea = chat.locator('textarea')
    await textarea.focus()
    await expect(textarea).toBeFocused()

    // Step 2: hold Space. After 250 ms dictation starts, and the frame shows the green top line,
    // the glow and the mic with the level bar. The text of the fake helper goes to the session.
    await page.keyboard.down('Space')
    await expect(frame.locator('[data-dictation-meter]')).toBeVisible({ timeout: 10_000 })
    await expect(frame.locator('[data-dictation-edge]')).toHaveCount(1)
    await expect(frame.locator('[data-dictation-glow]')).toHaveCount(1)
    expect(await frame.getAttribute('style')).toContain('--color-watch-green')
    await expect.poll(input, { timeout: 10_000 }).toBe(FAKE_TEXT)

    // Step 3: the release stops dictation. The look goes, and no space follows the text.
    await page.keyboard.up('Space')
    await expect(frame.locator('[data-dictation-meter]')).toHaveCount(0, { timeout: 10_000 })
    await expect(frame.locator('[data-dictation-edge]')).toHaveCount(0)
    expect(await frame.getAttribute('style')).not.toContain('--color-watch-green')
    expect(await input()).toBe(FAKE_TEXT)

    // Step 4: a tap of Space types a space, and opens no dictation.
    await page.keyboard.press('Space')
    await expect.poll(input, { timeout: 10_000 }).toBe(`${FAKE_TEXT} `)
    await expect(frame.locator('[data-dictation-meter]')).toHaveCount(0)

    // Step 5: Settings > Keys has the Dictation key under its own heading. Clear turns it off.
    // Then the recorder takes a plain Space, which is the default again.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settings = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settings.locator('[data-settings-tab="keys"]').click()
    const group = settings.locator('[data-key-group="dictation"]')
    await expect(group.locator('h3')).toHaveText('Hold to dictate in a chat window')
    const row = group.locator(`[data-key-slot="${DICTATION_SLOT}"]`)
    await expect(row.locator('[data-key-name]')).toHaveText('Dictation key')
    const savedKeys = async (): Promise<Record<string, unknown>> => {
      const text = await readText(join(testHome, 'user-data', 'settings.json'))
      return text === '' ? {} : (JSON.parse(text).keys ?? {})
    }
    await row.getByRole('button', { exact: true, name: 'Clear' }).click()
    await expect(row).toContainText('No key')
    await expect.poll(savedKeys).toEqual({ [DICTATION_SLOT]: null })
    await row.getByRole('button', { exact: true, name: 'Change' }).click()
    await expect(row.locator('[data-key-recorder]')).toBeFocused()
    await page.keyboard.press('Space')
    await expect(row.locator('[data-key-recorder]')).toHaveCount(0)
    await expect(row).not.toContainText('No key')
    await expect(row.getByRole('button', { exact: true, name: 'Reset' })).toBeDisabled()
    await expect.poll(savedKeys).toEqual({})

    await app.close()
    app = null
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
    const saved = JSON.parse(await readFile(join(testHome, 'user-data', 'settings.json'), 'utf8'))
    expect(saved.keys?.[DICTATION_SLOT]).toBeUndefined()
  } catch (err) {
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
