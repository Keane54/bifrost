// The smoke test of a request round (R3). It starts Bifrost with a fake claude, a fake gh and a
// test home. The test home holds a bare git repository as the remote of acme/api, so the clone,
// the fetch and the push use a file:// URL and never GitHub. The test turns on Watch GitHub and
// trusts the clone. A later poll shows a new review thread on the user's own PR acme/api#9. The
// fake request session changes src/limit.ts and writes its result file. Then the test checks
// the pushed fix on the remote, the two GitHub writes of the fake gh, the flags of the session,
// the unknown calls, and that the app uses only the test home.
//
// The second test turns on Sign commits through GitHub. Then Bifrost sends the fix with the signed
// commit write of the fake gh, which makes the commit in the bare remote as GitHub does. git
// pushes nothing.
//
// The file gh-fixtures in the test home tells the fake gh to use the request-round fixtures. The
// file smoke-head holds the head commit of the PR. The fake gh and the fake claude put it in place
// of @HEAD@ in the fixtures. The fake gh counts the polls in the file gh-polls.

import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { _electron, type ElectronApplication, expect, type Page, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, readText, skipSetup, UNKNOWN_LOG } from './app.ts'

const run = promisify(execFile)

const PR_KEY = 'acme/api#9'
const THREAD = 'PRRT_fake1'
const SESSION_NAME = 'bifrost-test-api-9-request'
// The start of the two GraphQL writes of the round, as the fake gh logs them.
const REPLY_WRITE = 'api graphql -f query=mutation ReplyToThread('
const RESOLVE_WRITE = 'api graphql -f query=mutation ResolveThread('
// The signed commit write, as the fake gh logs it. Its body goes on stdin, so the log has no
// file contents.
const COMMIT_WRITE = 'api graphql --input -'

const LIMIT = `export function limit(n: number): number {
  if (n < 0) return 0
  return n
}
`

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

// Make the bare repository <testHome>/git-remotes/acme/api.git. It has one commit on main and a
// second commit on feature that adds src/limit.ts. refs/pull/9/head is that second commit. Give
// the bare repository and the head commit. The HEAD of the bare repository names main, so main
// is the default branch. Bifrost never pushes to the default branch.
async function makeRemote(testHome: string): Promise<{ bare: string; head: string }> {
  const work = join(testHome, 'git-work')
  await git(['init', '-q', '-b', 'main', work], testHome, testHome)
  await writeFile(join(work, 'README.md'), '# api\n')
  await git(['add', '.'], work, testHome)
  await git(['commit', '-q', '-m', 'first'], work, testHome)
  await git(['switch', '-q', '-c', 'feature'], work, testHome)
  await mkdir(join(work, 'src'))
  await writeFile(join(work, 'src', 'limit.ts'), LIMIT)
  await git(['add', '.'], work, testHome)
  await git(['commit', '-q', '-m', 'add the limit'], work, testHome)
  const head = await git(['rev-parse', 'HEAD'], work, testHome)
  await git(['switch', '-q', 'main'], work, testHome)
  const bare = join(testHome, 'git-remotes', 'acme', 'api.git')
  await git(['clone', '-q', '--bare', work, bare], testHome, testHome)
  await git(['update-ref', 'refs/pull/9/head', head], bare, testHome)
  return { bare, head }
}

// The count of the polls that the fake gh answered.
async function pollCount(testHome: string): Promise<number> {
  const text = (await readText(join(testHome, 'gh-polls'))).trim()
  return text === '' ? 0 : Number(text)
}

// Click Refresh until the fake gh answers one more poll. The watcher ignores a Refresh during a
// poll and for a short time after a poll starts. So the test clicks again after a wait.
async function laterPoll(page: Page, testHome: string): Promise<void> {
  const start = await pollCount(testHome)
  const refresh = page.getByRole('button', { exact: true, name: 'Refresh' })
  await expect(async () => {
    await refresh.click()
    await expect.poll(() => pollCount(testHome), { timeout: 6_000 }).toBeGreaterThan(start)
  }).toPass({ timeout: 45_000 })
}

// Stop the sleep of the fake request session, if it still runs.
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

test('a request round fixes a review thread, pushes the fix and replies', async () => {
  await requestRound({ signed: false })
})

test('with Sign commits through GitHub on, GitHub makes the fix commit', async () => {
  await requestRound({ signed: true })
})

async function requestRound(o: { signed: boolean }): Promise<void> {
  test.setTimeout(180_000)
  // Step 1: make the test home, the remote and the fixture files.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-request-round-'))
  const appOutput: string[] = []
  let app: ElectronApplication | null = null
  try {
    const { bare, head } = await makeRemote(testHome)
    await writeFile(join(testHome, 'smoke-head'), head)
    await writeFile(join(testHome, 'gh-fixtures'), 'request-round')

    // Step 2: start the app. Turn on Watch GitHub and accept the confirm. Automatic comment
    // handling is on by default.
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    const page = await app.firstWindow()
    // The app uses only the test home.
    await expectTestHomeOnly(app, testHome)
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
    if (o.signed) {
      const signed = settingsFrame.getByRole('checkbox', { name: /Sign commits through GitHub/ })
      await expect(signed).not.toBeChecked()
      await signed.click()
      await expect(signed).toBeChecked()
    }
    await settingsFrame.getByRole('button', { exact: true, name: 'Close' }).first().click()
    await expect(settingsFrame).toHaveCount(0)

    // Step 3: the first poll shows the PR with no thread. The set-up clones acme/api, and the
    // strip asks for trust. Trust opens the trust terminal. Enter answers the fake trust prompt,
    // and the panel closes when Bifrost sees the trust in the .claude.json of the test home.
    await page.getByRole('button', { exact: true, name: 'Reviews' }).click()
    await page.locator('[data-reviews-tab="mine"]').click()
    const row = page.locator(`[data-review-row="${PR_KEY}"]`)
    await expect(row).toBeVisible({ timeout: 30_000 })
    await expect(row).toContainText('Waiting')
    const strip = page.locator('[data-trust-strip]')
    await expect(strip).toContainText('acme/api', { timeout: 30_000 })
    await expect(strip).toContainText('1 pull request waiting')
    await strip.getByRole('button', { exact: true, name: 'Trust' }).click()
    const terminal = page.locator('[data-trust-terminal]')
    await expect(terminal).toBeVisible()
    await expect(terminal).toContainText('FAKE TRUST PROMPT', { timeout: 15_000 })
    await terminal.locator('textarea').focus()
    await page.keyboard.press('Enter')
    await expect(terminal).toHaveCount(0, { timeout: 15_000 })
    await expect(strip).toHaveCount(0, { timeout: 15_000 })

    // Step 4: a later poll shows the new thread of alice. The round starts, the session works on
    // the one thread, and then Bifrost commits, pushes and posts.
    await laterPoll(page, testHome)
    await expect(row).toContainText('Fixing 1', { timeout: 30_000 })
    await expect(row).toContainText('Waiting', { timeout: 90_000 })

    // Step 5: the branch on the remote has a new commit. Its only parent is the old head, and it
    // changes src/limit.ts only. The message comes from the result file.
    const fix = await git(['rev-parse', 'refs/heads/feature'], bare, testHome)
    expect(fix).not.toBe(head)
    expect(await git(['rev-list', '--parents', '-n', '1', fix], bare, testHome)).toBe(
      `${fix} ${head}`,
    )
    const changed = ['diff-tree', '--no-commit-id', '--name-only', '-r', fix]
    expect(await git(changed, bare, testHome)).toBe('src/limit.ts')
    expect(await git(['log', '-1', '--format=%s', fix], bare, testHome)).toBe(
      'fix: check the upper limit',
    )
    expect(await git(['show', `${fix}:src/limit.ts`], bare, testHome)).toContain('MAX_LIMIT')
    // The fake GitHub made the signed commit. git made the pushed commit.
    const author = await git(['log', '-1', '--format=%an', fix], bare, testHome)
    expect(author === 'Fake GitHub').toBe(o.signed)
    if (o.signed) {
      const sent = JSON.parse(await readText(join(testHome, 'gh-commit.json')))
      expect(sent.variables.input).toMatchObject({
        branch: { branchName: 'feature', repositoryNameWithOwner: 'acme/api' },
        expectedHeadOid: head,
        fileChanges: { additions: [{ path: 'src/limit.ts' }], deletions: [] },
        message: { headline: 'fix: check the upper limit' },
      })
    }

    // Step 6: with signed commits, the commit write. Then one reply that names the commit on
    // GitHub, then one resolve of the thread. No other GitHub write.
    const all = (await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')
    if (o.signed) expect(all[0]).toBe(COMMIT_WRITE)
    const writes = o.signed ? all.slice(1) : all
    expect(all).toHaveLength(o.signed ? 3 : 2)
    expect(writes[0]?.startsWith(REPLY_WRITE)).toBe(true)
    expect(writes[0]?.endsWith(` -f body=Fixed by ${fix.slice(0, 7)} -f thread=${THREAD}`)).toBe(
      true,
    )
    expect(writes[1]?.startsWith(RESOLVE_WRITE)).toBe(true)
    expect(writes[1]?.endsWith(` -f thread=${THREAD}`)).toBe(true)

    // Step 7: one request session start, with the flags of a sandboxed test session.
    const starts = (await readText(join(testHome, 'request-args.log'))).trimEnd().split('\n')
    expect(starts).toHaveLength(1)
    const args = starts[0] ?? ''
    expect(args).toContain('--setting-sources')
    expect(args).toContain('--tools Bash Read Glob Grep Edit Write Skill')
    expect(args).toContain('--model haiku')
    expect(args).toContain(`--name ${SESSION_NAME} `)
    expect(args).toContain('"allowUnsandboxedCommands":false')
    expect(args).not.toContain('--restricted')
    expect(args).toMatch(/ \/bifrost-resolve-comments bifrost-input=\/\S+\/input\.json$/)

    // Step 8: two more polls show the thread as resolved, so no new round starts. A round would
    // start within a few seconds of a poll, so the test waits a short time before the check.
    await laterPoll(page, testHome)
    await laterPoll(page, testHome)
    await page.waitForTimeout(3_000)
    await expect(row).toContainText('Waiting')
    expect((await readText(join(testHome, 'request-args.log'))).trimEnd().split('\n')).toHaveLength(
      1,
    )

    // Step 9: quit the app. The fakes got no unknown call.
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
    // Step 10: stop the sleep of the fake request session.
    await stopFakeSession(testHome)
    await rm(testHome, { force: true, recursive: true })
  }
}
