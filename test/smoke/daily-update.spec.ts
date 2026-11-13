// The smoke test of the Daily update panel (Daily update design, section 9). It starts Bifrost
// with a fake claude and a test home. The settings of the test home have two work areas that are
// on, one area that is off, and the invented ticket source "board". The open of the panel runs
// the drafts: the fake claude answers the two probes and the run. The test checks the side bar
// dot, the tabs, the draft of the second tab, and that Mark as sent on both areas clears the dot.
// Then it checks the flags of the run, the unknown calls, and that the app uses only the test
// home.
//
// The day state of the test home says that both reminders of today showed. So no scheduled run
// starts and no macOS notification shows during the test. The open of the panel starts the only
// run. The test does not click Copy, because Copy writes to the real clipboard of the Mac.

import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, UNKNOWN_LOG } from './app.ts'

const pad = (n: number): string => String(n).padStart(2, '0')

// The local date, YYYY-MM-DD. The app uses the same time zone.
function localDate(now: Date): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

// Each day is due, and the draft time is 00:00. So the marker shows at each time of the test.
const SETTINGS = {
  dailyUpdate: {
    areas: [
      {
        channel: '#platform',
        description: 'Work on the platform.',
        id: 'area-a',
        name: 'Platform',
        on: true,
        takesRest: true,
      },
      {
        channel: '#old-project',
        description: 'Work on the old project.',
        id: 'area-off',
        name: 'Old project',
        on: false,
        takesRest: false,
      },
      {
        channel: '#billing',
        description: 'Work on billing.',
        id: 'area-b',
        name: 'Billing',
        on: true,
        takesRest: false,
      },
    ],
    days: [0, 1, 2, 3, 4, 5, 6],
    deadline: '23:59',
    draftTime: '00:00',
    format: { examples: [], template: '**Daily update**' },
    mergedPrs: false,
    model: '',
    source: { server: 'board', tools: ['mcp__board__list_items'] },
    you: '',
  },
  setupDone: true,
  version: 1,
}

function dayState(today: string): unknown {
  return {
    areas: {},
    lastRun: null,
    lastSent: {},
    marks: { date: today, firstShown: true, secondShown: true, sent: {}, skipped: false },
    prevSent: {},
    unplaced: [],
    version: 1,
  }
}

test('the Daily update panel shows the drafts and Mark as sent clears the dot', async () => {
  test.setTimeout(120_000)
  // Step 1: write the settings and the day state of the test home.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-daily-update-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    await mkdir(join(testHome, 'user-data'), { recursive: true })
    await writeFile(join(testHome, 'user-data', 'settings.json'), JSON.stringify(SETTINGS))
    const dailyDir = join(testHome, '.bifrost', 'daily-update')
    await mkdir(dailyDir, { mode: 0o700, recursive: true })
    await writeFile(join(dailyDir, 'state.json'), JSON.stringify(dayState(localDate(new Date()))))

    // Step 2: start the app. The side bar button shows its dot.
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)
    const button = page.getByRole('button', { exact: true, name: 'Daily update' })
    const dot = button.locator('[data-side-warning]')
    await expect(dot).toBeVisible({ timeout: 15_000 })

    // Step 3: open the panel. It shows one tab for each area that is on, in the order of the
    // settings. The run ends, and the first tab shows its items and its draft.
    await button.click()
    const tabs = page.locator('[data-daily-tab]')
    await expect(tabs).toHaveCount(2)
    await expect(tabs.nth(0)).toHaveAttribute('data-daily-tab', 'area-a')
    await expect(tabs.nth(0)).toContainText('Platform')
    await expect(tabs.nth(1)).toHaveAttribute('data-daily-tab', 'area-b')
    await expect(tabs.nth(1)).toContainText('Billing')
    const first = page.locator('[data-daily-area="area-a"]')
    await expect(first).toContainText('The login page loads faster now.', { timeout: 30_000 })
    await expect(first).toContainText('PLAT-1')
    await expect(first).toContainText('In progress → Done')
    const status = page.locator('[data-daily-status]')
    await expect(status).toContainText('Not sent yet')
    await expect(status).toContainText('Due 23:59')
    await expect(status).toContainText('Refreshed')
    await expect(status).toContainText('1 ticket fits no area')
    await expect(page.locator('[data-daily-failure]')).toHaveCount(0)

    // Step 4: the second tab shows its draft. Bold shows as bold.
    await tabs.nth(1).click()
    const second = page.locator('[data-daily-area="area-b"]')
    await expect(second).toContainText('The invoice export is ready for review.')
    await expect(second).toContainText('BILL-7')
    await expect(second.locator('strong', { hasText: 'Done since my last update' })).toBeVisible()
    await expect(second.locator('[data-daily-draft]')).not.toContainText('**')

    // Step 5: Mark as sent on the second area. Its tab shows the time and Undo, and its tab marker
    // goes. The first area is not sent, so the side bar dot stays.
    await expect(tabs.nth(1).locator('[data-daily-tab-marker]')).toHaveCount(1)
    await second.getByRole('button', { exact: true, name: 'Mark as sent' }).click()
    await expect(second).toContainText('Sent at')
    await expect(second.getByRole('button', { exact: true, name: 'Undo' })).toBeVisible()
    await expect(tabs.nth(1).locator('[data-daily-tab-marker]')).toHaveCount(0)
    await expect(dot).toBeVisible()

    // Step 6: Mark as sent on the first area. Each area is sent, so the dot goes.
    await tabs.nth(0).click()
    await first.getByRole('button', { exact: true, name: 'Mark as sent' }).click()
    await expect(first).toContainText('Sent at')
    await expect(dot).toHaveCount(0)
    await expect(status).toContainText('Sent')
    await expect(status).not.toContainText('Not sent yet')

    // Step 7: quit the app. One run started. It may use only the read tool of the ticket source,
    // with Read and Skill, and every other tool and server is denied. The fake claude got no
    // unknown call.
    await app.close()
    app = null
    const runs = (await readText(join(testHome, 'daily-args.log'))).trimEnd().split('\n')
    expect(runs).toHaveLength(1)
    const args = runs[0] ?? ''
    expect(args).toMatch(/^-p --output-format json --tools Read,Skill --permission-mode dontAsk /)
    expect(args).toContain('--allowedTools mcp__board__list_items Skill ')
    expect(args).toContain('--disallowedTools mcp__board__update_item mcp__other ')
    expect(args).toContain('"disableAllHooks":true')
    expect(args).toMatch(/ \/bifrost-daily-update bifrost-input=\/\S+\/input\.json$/)
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
