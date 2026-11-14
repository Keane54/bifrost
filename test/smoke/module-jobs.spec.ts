// The module jobs of a module (plan Task 7). The test seeds the jobs module with the claude-jobs
// permission and without claude-jobs-auto. Its panel asks for a job, and the job waits. A refresh
// through the page API runs the job with the fake claude, and sends the refresh event to the
// module. The test clicks the Refresh button of the title bar. The fake claude writes its
// arguments, its folder and its stdin to job.log in the test home.

import { cp, mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, type Page, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, skipSetup, UNKNOWN_LOG } from './app.ts'

const FIXTURE = join(import.meta.dirname, 'fixtures', 'modules', 'jobs')
// The longest wait for a condition. A slow machine gets the time it needs.
const SLOW = 20_000
// The argument list of Spike B with the model of the module, as the shell joins it.
const JOB_ARGS =
  '-p --no-session-persistence --disable-slash-commands --output-format json --tools  ' +
  '--strict-mcp-config --mcp-config {"mcpServers":{}} --setting-sources  --settings ' +
  '{"disableAllHooks":true,"autoMemoryEnabled":false,"disableSkillShellExecution":true} ' +
  '--permission-mode dontAsk --model haiku'
// The first line of the text of each job. The text of the module comes after it.
const JOB_HEADER = 'This is a Bifrost module job.'

// The part of the page API that the test uses.
interface PageModules {
  snapshot(): Promise<{ modules: { id: string; jobsToday: number; waitingJobs: number }[] }>
}

// The job counts of the row of the jobs module.
async function jobCounts(page: Page): Promise<{ today: number; waiting: number } | null> {
  return page.evaluate(async () => {
    const api = (window as unknown as { bifrost: { modules: PageModules } }).bifrost.modules
    const row = (await api.snapshot()).modules.find(m => m.id === 'jobs')
    return row ? { today: row.jobsToday, waiting: row.waitingJobs } : null
  })
}

async function seedModule(bifrostHome: string): Promise<void> {
  await cp(FIXTURE, join(bifrostHome, 'modules', 'jobs', 'current'), { recursive: true })
  const manifest = JSON.parse(await readFile(join(FIXTURE, 'bifrost-module.json'), 'utf8'))
  const jobs = {
    dailyCap: 5,
    enabled: true,
    granted: ['claude-jobs'],
    hash: '0'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest,
    model: 'haiku',
    pendingUpdate: null,
    source: { kind: 'folder', path: FIXTURE },
  }
  await writeFile(join(bifrostHome, 'modules', 'state.json'), JSON.stringify({ modules: { jobs } }))
}

test('a module job waits for a refresh, then runs claude with no tools', async () => {
  test.setTimeout(120_000)
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-module-jobs-'))
  let app: ElectronApplication | null = null
  try {
    await mkdir(join(testHome, '.bifrost'), { recursive: true })
    await seedModule(join(testHome, '.bifrost'))
    app = await _electron.launch(await launchOptions(testHome))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)
    await skipSetup(page)

    const sideBar = page.getByRole('navigation', { name: 'Side bar' })
    await sideBar.getByRole('button', { exact: true, name: 'Jobs board (Jobs)' }).click()
    const inFrame = page.frameLocator('iframe[data-module-panel="main"]')
    await expect(inFrame.locator('#job')).toHaveText('asked', { timeout: SLOW })

    // Without claude-jobs-auto, the job waits. The row gives the count, and claude does not run.
    await expect.poll(() => jobCounts(page), { timeout: SLOW }).toEqual({ today: 0, waiting: 1 })
    expect(await readText(join(testHome, 'job.log'))).toBe('')

    // The title bar of Bifrost shows Refresh with the count, outside the frame. A click runs the
    // waiting job and sends the refresh event to the module. Then the count goes away.
    const refresh = page.locator('[data-module-refresh="jobs"]')
    await expect(refresh).toHaveText('Refresh · 1 waiting', { timeout: SLOW })
    await expect(refresh).toHaveAttribute('title', 'Run the waiting module jobs')
    await refresh.click()
    await expect(inFrame.locator('#refreshed')).toHaveText('refreshed: 1', { timeout: SLOW })
    await expect(inFrame.locator('#job')).toHaveText('job: Hello from the fake job.', {
      timeout: SLOW,
    })
    await expect.poll(() => jobCounts(page), { timeout: SLOW }).toEqual({ today: 1, waiting: 0 })
    await expect(refresh).toHaveText('Refresh', { timeout: SLOW })
    await expect(page.locator('[data-module-tier="standard"]')).toHaveText('Standard')

    // claude got the argument list of Spike B and the text on stdin, with the token masked. It
    // ran in the empty fixed folder of the module, and Bifrost emptied the folder after the job.
    const log = await readText(join(testHome, 'job.log'))
    expect(log).toContain(`args: ${JOB_ARGS}\n`)
    expect(log).toContain('files: \n')
    expect(log).toContain(
      `stdin:\n${JOB_HEADER}\n\nSay hello.\n\n<input>\nThe input. ***\n</input>\nend\n`,
    )
    expect(log).not.toContain('ghp_')
    // A test home holds the job folders. The app uses the system temp folder.
    const folder = join(await realpath(testHome), 'bifrost-module-jobs', 'jobs')
    expect(log).toContain(`cwd: ${folder}\n`)
    expect(await readdir(folder)).toEqual([])

    // The fake claude knew each call of Bifrost.
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
  } finally {
    await app?.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
  }
})
