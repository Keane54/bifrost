// The smoke test of a review round (R2). It starts Bifrost with a fake claude, a fake gh and a
// test home. The test home holds a bare git repository as the remote of acme/api, so the clone
// comes from a file:// URL and never from GitHub. The test turns on Watch GitHub, trusts the
// clone in the trust terminal, starts a review and waits for the draft. Then it checks the one
// GitHub write of the fake gh, the flags of the review session, the unknown calls and the real
// files.
//
// The file gh-fixtures in the test home tells the fake gh to use the review-round fixtures. The
// file smoke-head holds the head commit of the PR. The fake gh and the fake claude put it in place
// of @HEAD@ in the fixtures.

import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { _electron, type ElectronApplication, expect, test } from '@playwright/test'
import { launchOptions, readText, realFiles, skipSetup, UNKNOWN_LOG } from './app.ts'

const run = promisify(execFile)

const PR_KEY = 'acme/api#7'
// The only GitHub write of a round: the create of a pending review.
const REVIEW_CREATE = 'api --method POST repos/acme/api/pulls/7/reviews --input -'

// Run git with no git config of the user or of the system.
async function git(args: string[], cwd: string, home: string): Promise<string> {
  const env = {
    GIT_AUTHOR_EMAIL: 'smoke@example.invalid',
    GIT_AUTHOR_NAME: 'Bifrost Smoke',
    GIT_COMMITTER_EMAIL: 'smoke@example.invalid',
    GIT_COMMITTER_NAME: 'Bifrost Smoke',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    HOME: home,
    PATH: '/usr/bin:/bin',
  }
  const { stdout } = await run('git', args, { cwd, env, timeout: 30_000 })
  return stdout.trim()
}

// Make the bare repository <testHome>/git-remotes/acme/api.git. It has one commit on main, and
// the PR head at refs/pull/7/head. The PR changes line 12 of src/limit.ts. Give the head commit.
async function makeRemote(testHome: string): Promise<string> {
  const work = join(testHome, 'git-work')
  await git(['init', '-q', '-b', 'main', work], testHome, testHome)
  await mkdir(join(work, 'src'))
  const lines = Array.from({ length: 20 }, (_, i) => `export const line${i + 1} = ${i + 1}`)
  await writeFile(join(work, 'src', 'limit.ts'), `${lines.join('\n')}\n`)
  await git(['add', '.'], work, testHome)
  await git(['commit', '-q', '-m', 'first'], work, testHome)
  await git(['switch', '-q', '-c', 'pr'], work, testHome)
  lines[11] = 'export const line12 = 1200'
  await writeFile(join(work, 'src', 'limit.ts'), `${lines.join('\n')}\n`)
  await git(['commit', '-q', '-am', 'raise the limit'], work, testHome)
  const head = await git(['rev-parse', 'HEAD'], work, testHome)
  const bare = join(testHome, 'git-remotes', 'acme', 'api.git')
  await git(['clone', '-q', '--bare', work, bare], testHome, testHome)
  await git(['update-ref', 'refs/pull/7/head', head], bare, testHome)
  await git(['update-ref', '-d', 'refs/heads/pr'], bare, testHome)
  return head
}

// Stop the sleep of the fake review session, if it still runs.
async function stopFakeSession(testHome: string): Promise<void> {
  const text = await readText(join(testHome, 'fake-agents.json'))
  if (text === '') return
  let entries: unknown
  try {
    entries = JSON.parse(text)
  } catch {
    return
  }
  if (!Array.isArray(entries)) return
  for (const entry of entries) {
    const pid = (entry as { pid?: unknown }).pid
    if (typeof pid !== 'number' || !Number.isSafeInteger(pid) || pid <= 1) continue
    try {
      process.kill(pid, 'SIGTERM')
    } catch {
      // The process stopped already.
    }
  }
}

test('a review round trusts the clone, runs the session and posts one pending review', async () => {
  test.setTimeout(180_000)
  // Step 1: record the real files. Make the test home, the remote and the fixture files.
  const before = await realFiles()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-review-round-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    const head = await makeRemote(testHome)
    await writeFile(join(testHome, 'smoke-head'), head)
    await writeFile(join(testHome, 'gh-fixtures'), 'review-round')

    // Step 2: start the app. Turn on Watch GitHub and accept the confirm.
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    await skipSetup(page)
    await page.getByRole('button', { exact: true, name: 'Settings' }).click()
    const settingsFrame = page.locator('[data-frame-id]', {
      has: page.locator('[data-settings-section]'),
    })
    await settingsFrame.locator('[data-settings-tab="reviews"]').click()
    await settingsFrame.getByRole('checkbox', { name: /Watch GitHub/ }).click()
    const confirm = page.locator('[data-confirm-dialog]')
    await expect(confirm).toBeVisible()
    await confirm.locator('[data-confirm-ok]').click()
    await expect(confirm).toBeHidden()
    await settingsFrame.getByRole('button', { exact: true, name: 'Close' }).first().click()
    await expect(settingsFrame).toHaveCount(0)

    // Step 3: the set-up clones acme/api, and the strip asks for trust before any click. Review
    // then puts the PR in the queue, and the row shows Trust needed.
    await page.getByRole('button', { exact: true, name: 'Reviews' }).click()
    const strip = page.locator('[data-trust-strip]')
    await expect(strip).toContainText('acme/api', { timeout: 30_000 })
    await expect(strip).toContainText('1 pull request waiting')
    const row = page.locator(`[data-review-row="${PR_KEY}"]`)
    await expect(row).toBeVisible()
    await row.getByRole('button', { exact: true, name: 'Review' }).click()
    await expect(row).toContainText('Trust needed')

    // Step 4: Trust opens the trust terminal. Enter answers the fake trust prompt, and the panel
    // closes when Bifrost sees the trust in the .claude.json of the test home.
    await strip.getByRole('button', { exact: true, name: 'Trust' }).click()
    const terminal = page.locator('[data-trust-terminal]')
    await expect(terminal).toBeVisible()
    await expect(terminal).toContainText('FAKE TRUST PROMPT', { timeout: 15_000 })
    await terminal.locator('textarea').focus()
    await page.keyboard.press('Enter')
    await expect(terminal).toHaveCount(0, { timeout: 15_000 })

    // Step 5: the round runs, then the row shows the draft and the recommendation.
    await expect(row).toContainText('Reviewing', { timeout: 30_000 })
    await expect(row).toContainText('Draft ready · Request changes', { timeout: 90_000 })

    // Step 6: the pending review is on the reviewed commit, has no event and has one comment.
    // It is the only write call, and it ran one time.
    const post = JSON.parse(await readText(join(testHome, 'review-post.json')))
    expect(post.commit_id).toBe(head)
    expect(Object.hasOwn(post, 'event')).toBe(false)
    expect(post.comments).toHaveLength(1)
    expect(post.comments[0]).toMatchObject({ line: 12, path: 'src/limit.ts', side: 'RIGHT' })
    expect(await readText(join(testHome, 'gh-writes.log'))).toBe(`${REVIEW_CREATE}\n`)

    // Step 7: one review session started, with the flags of a read-only test session.
    const starts = (await readText(join(testHome, 'review-args.log'))).trimEnd().split('\n')
    expect(starts).toHaveLength(1)
    const args = starts[0] ?? ''
    expect(args).toContain('--restricted')
    expect(args).toContain('--tools Read Glob Grep Write Skill')
    expect(args).toContain('--model haiku')
    expect(args).toMatch(/--name bifrost-test-\S+/)

    // Step 8: quit the app. The fakes got no unknown call, and the real files did not change.
    await app.close()
    app = null
    expect(await readText(join(testHome, UNKNOWN_LOG))).toBe('')
    expect(await realFiles()).toEqual(before)
  } catch (err) {
    await test.info().attach('app-output.txt', {
      body: appOutput.join(''),
      contentType: 'text/plain',
    })
    throw err
  } finally {
    if (app !== null) await app.close().catch(() => {})
    // Step 9: stop the sleep of the fake review session.
    await stopFakeSession(testHome)
    await rm(testHome, { force: true, recursive: true })
  }
})
