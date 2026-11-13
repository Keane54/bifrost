// The smoke test of the skills. The setup dialog shows the skills step after the Live step. Then
// Settings > Skills shows "Not installed." and the six skills. The fake claude lists no Bifrost
// plugin, so nothing is installed. The test also checks that the app uses only the test home, and
// that the fake claude got no unknown call.

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, UNKNOWN_LOG } from './app.ts'

const SKILLS = [
  ['bifrost-daily-update', 'called-by-name'],
  ['bifrost-grill', 'listed'],
  ['bifrost-hand-over', 'called-by-name'],
  ['bifrost-humanise', 'listed'],
  ['bifrost-resolve-comments', 'called-by-name'],
  ['bifrost-review', 'called-by-name'],
]

test('the setup dialog offers the skills and Settings > Skills lists them', async () => {
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-skills-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)

    // Step 1: the Live step comes first. Skip shows the skills step.
    const setup = page.locator('[data-setup-dialog]')
    await expect(setup).toContainText('Set up Bifrost', { timeout: 15_000 })
    await expect(setup).toHaveAttribute('data-setup-dialog', 'ask')
    await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
    await expect(setup).toHaveAttribute('data-setup-dialog', 'skills')
    await expect(setup).toContainText('Bifrost skills give Claude tested steps')
    await expect(setup.locator('[data-setup-action="skip-skills"]')).toBeFocused()
    await expect(setup.locator('[data-setup-action="install-skills"]')).toBeVisible()

    // Step 2: Skip closes the dialog.
    await setup.locator('[data-setup-action="skip-skills"]').click()
    await expect(setup).toBeHidden()

    // Step 3: Settings > Skills.
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settingsFrame.locator('[data-settings-tab="skills"]').click()
    await expect(settingsFrame.locator('[data-skills-state]')).toHaveText('Not installed.')
    await expect(settingsFrame.locator('[data-skills-action="install"]')).toBeVisible()
    const rows = settingsFrame.locator('li[data-skill-name]')
    await expect(rows).toHaveCount(SKILLS.length)
    for (const [index, [name, group]] of SKILLS.entries()) {
      const row = rows.nth(index)
      await expect(row).toHaveAttribute('data-skill-name', name)
      await expect(row.locator('[data-skill-group]')).toHaveAttribute('data-skill-group', group)
      await expect(row).toContainText(`/${name}`)
    }

    // Quit the app. Nothing ran that should not run.
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
