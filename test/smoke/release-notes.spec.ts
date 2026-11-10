// The smoke test of the release notes view. In a test home, Bifrost reads the GitHub releases from
// the file github-releases.json of the test home, so the test never calls GitHub. The test opens
// Release notes from Settings > Updates two times: first with no file, which gives the error
// state, then with the fake answer of test/smoke/fixtures/github-releases.json. It stubs the open
// of a GitHub page in the main process, so no browser opens. It also checks that What's new did
// not open by itself and stored no state, that the fake claude got no unknown call, and that the
// real files did not change.

import { copyFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, readText, realFiles, skipSetup, UNKNOWN_LOG } from './app.ts'

const FIXTURE = join(import.meta.dirname, 'fixtures', 'github-releases.json')

test('Settings > Updates opens the release notes of the fake GitHub answer', async () => {
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-release-notes-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()

    // A GitHub page must not open in the browser of the user. So replace the open in the main
    // process, and check that the change took effect before any click.
    await app.evaluate(({ shell }) => {
      const opened: string[] = []
      const stub = async (url: string): Promise<void> => {
        opened.push(url)
      }
      Object.assign(globalThis, { bifrostOpened: opened, bifrostOpenStub: stub })
      shell.openExternal = stub
    })
    const stubbed = await app.evaluate(
      ({ shell }) =>
        shell.openExternal === (globalThis as { bifrostOpenStub?: unknown }).bifrostOpenStub,
    )
    expect(stubbed).toBe(true)

    await skipSetup(page)

    // What's new never opens by itself in a test run.
    await expect(page.getByRole('button', { exact: true, name: 'Settings' })).toBeVisible()
    const dialog = page.locator('[data-release-notes]')
    await expect(dialog).toHaveCount(0)

    // Settings > Updates > Release notes, with no answer: the error state.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settingsFrame.locator('[data-settings-tab="updates"]').click()
    const button = settingsFrame.locator('[data-updates-release-notes]')
    await expect(button).toHaveText('Release notes')
    await button.click()
    await expect(dialog).toHaveAttribute('data-release-notes', 'all')
    await expect(dialog).toHaveAttribute('data-release-notes-state', 'failed')
    await expect(dialog.getByRole('heading', { exact: true, name: 'Release notes' })).toBeVisible()
    await expect(dialog).toContainText("Couldn't load the release notes.")
    await dialog.getByRole('button', { name: 'Open the Releases page on GitHub' }).click()
    await dialog.getByRole('button', { exact: true, name: 'Close' }).click()
    await expect(dialog).toHaveCount(0)

    // The fake answer. A failed load keeps nothing, so the next open reads the file.
    await copyFile(FIXTURE, join(testHome, 'github-releases.json'))
    await button.click()
    await expect(dialog).toHaveAttribute('data-release-notes-state', 'ok')
    // The draft and the prerelease do not show. The newest version is first.
    const releases = dialog.locator('[data-release]')
    await expect(releases).toHaveCount(3)
    expect(
      await releases.evaluateAll(els => els.map(el => el.getAttribute('data-release'))),
    ).toEqual(['0.5.0', '0.4.0', '0.3.1'])

    // 0.5.0: the summary with bold, the tags as text, and the shown sections only.
    const v050 = dialog.locator('[data-release="0.5.0"]')
    await expect(v050).toContainText('Version 0.5.0')
    await expect(v050).toContainText('11 Nov 2026')
    const summary = v050.locator('[data-release-summary]')
    await expect(summary).toHaveText(
      "Bifrost now shows What's new after an update. <b>Tags</b> show as text.",
    )
    await expect(summary.locator('strong')).toHaveText("What's new")
    await expect(summary.locator('b')).toHaveCount(0)
    const sections = v050.locator('[data-release-section]')
    expect(
      await sections.evaluateAll(els => els.map(el => el.getAttribute('data-release-section'))),
    ).toEqual(['New', 'Faster'])
    await expect(v050).toContainText('settingsadd a Release notes button')
    await expect(v050.locator('code')).toHaveText('Release notes')
    await expect(v050.locator('[data-release-scope]').first()).toHaveText('settings')
    await expect(v050).not.toContainText('1234567')
    await expect(v050).not.toContainText('add the release notes check')

    // 0.4.0: the real body. Only New and Fixed show.
    const v040 = dialog.locator('[data-release="0.4.0"]')
    expect(
      await v040
        .locator('[data-release-section]')
        .evaluateAll(els => els.map(el => el.getAttribute('data-release-section'))),
    ).toEqual(['New', 'Fixed'])
    await expect(v040.locator('li')).toHaveCount(12)
    await expect(v040).not.toContainText('Code Refactoring')

    // 0.3.1 has only documentation.
    await expect(dialog.locator('[data-release="0.3.1"]')).toContainText('Small internal changes.')

    // View on GitHub opens the page of the release, through the main process.
    await v050.locator('[data-release-github="0.5.0"]').click()
    await expect
      .poll(() =>
        app?.evaluate(() => (globalThis as { bifrostOpened?: string[] }).bifrostOpened ?? []),
      )
      .toEqual([
        'https://github.com/Keane54/bifrost/releases',
        'https://github.com/Keane54/bifrost/releases/tag/v0.5.0',
      ])

    // Esc closes the view.
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)

    // Quit the app. Nothing ran that should not run.
    await app.close()
    app = null
    expect(await realFiles()).toEqual(before)
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
    expect(await readText(join(testHome, 'user-data', 'release-notes.json'))).toBe('')
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
