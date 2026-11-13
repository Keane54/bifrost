// The smoke tests of a review round (R2), of the Approve button and of the Review panel (user
// decision, 2026-11-13). Each test starts Bifrost with a fake claude, a fake gh and a test home.
// The test home holds a bare git repository as the remote of acme/api, so the clone comes from a
// file:// URL and never from GitHub. The test turns on Watch GitHub, trusts the clone in the trust
// terminal, starts a review and waits for the draft. The first test then checks the one GitHub
// write of the fake gh and the flags of the review session. Then it opens the draft in the Review
// panel, changes the summary and sends the review. It checks the two more writes, the unknown
// calls and that the app uses only the test home. The second test gets an
// Approve result, clicks Approve, and checks that the one more write submits the draft as an
// approval. The third test gets an Approve result with nothing to post, and checks that the click
// approves the reviewed commit with no text.
//
// The file gh-fixtures in the test home tells the fake gh which fixtures to use: review-round,
// approve-round or approve-head-round. The file smoke-head holds the head commit of the PR. The
// fake gh and the fake claude put it in place of @HEAD@ in the fixtures.

import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import {
  _electron,
  type ElectronApplication,
  expect,
  type Locator,
  type Page,
  test,
} from '@playwright/test'
import {
  expectTestHomeOnly,
  launchOptions,
  readText,
  removeTestHome,
  skipSetup,
  UNKNOWN_LOG,
} from './app.ts'

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

// Steps 2 to 4 of each test: start the app, turn on Watch GitHub, trust the clone and start the
// review. started gets the app at once, so the caller can close it after a failure. Give the
// page and the row of the PR.
async function startReview(
  testHome: string,
  appOutput: string[],
  started: (app: ElectronApplication) => void,
): Promise<{ app: ElectronApplication; page: Page; row: Locator }> {
  // Step 2: start the app. Turn on Watch GitHub and accept the confirm.
  const app = await _electron.launch(await launchOptions(testHome))
  started(app)
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
  await settingsFrame.getByRole('button', { exact: true, name: 'Close' }).first().click()
  await expect(settingsFrame).toHaveCount(0)

  // Step 3: the set-up clones acme/api, and the strip asks for trust before any click. Review
  // then allows one start. The fake claude refuses it for trust, so the PR goes back to the
  // queue and the row shows Trust needed.
  await page.getByRole('button', { exact: true, name: 'Reviews' }).click()
  const strip = page.locator('[data-trust-strip]')
  await expect(strip).toContainText('acme/api', { timeout: 30_000 })
  await expect(strip).toContainText('1 pull request waiting', { timeout: 30_000 })
  const row = page.locator(`[data-review-row="${PR_KEY}"]`)
  await expect(row).toBeVisible({ timeout: 30_000 })
  await row.getByRole('button', { exact: true, name: 'Review' }).click()
  // The row can show Trust needed before the refused start ran: after the click, the entry is
  // in the queue a short time before Bifrost gives the clone its one start. If the test trusted
  // the clone in that time, the start would not be refused, or the refusal would come after the
  // trust. So the test waits for the one refused start in the log of the fake claude first.
  await expect
    .poll(async () => (await readText(join(testHome, 'review-args.log'))).trimEnd().split('\n'), {
      message: 'the fake claude got the refused review start',
      timeout: 30_000,
    })
    .toHaveLength(1)
  await expect(row).toContainText('Trust needed', { timeout: 30_000 })

  // Step 4: Trust opens the trust terminal. Enter answers the fake trust prompt, and the panel
  // closes when Bifrost sees the trust in the .claude.json of the test home.
  await strip.getByRole('button', { exact: true, name: 'Trust' }).click()
  const terminal = page.locator('[data-trust-terminal]')
  await expect(terminal).toBeVisible()
  await expect(terminal).toContainText('FAKE TRUST PROMPT', { timeout: 15_000 })
  await terminal.locator('textarea').focus()
  await page.keyboard.press('Enter')
  await expect(terminal).toHaveCount(0, { timeout: 15_000 })
  return { app, page, row }
}

test('a review round posts one pending review, and the Review panel sends it', async () => {
  test.setTimeout(180_000)
  // Step 1: make the test home, the remote and the fixture files.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-review-round-'))
  const appOutput: string[] = []
  let app = null as ElectronApplication | null
  try {
    const head = await makeRemote(testHome)
    await writeFile(join(testHome, 'smoke-head'), head)
    await writeFile(join(testHome, 'gh-fixtures'), 'review-round')
    const started = await startReview(testHome, appOutput, launched => {
      app = launched
    })
    const { row } = started

    // Step 5: the round runs, then the row shows the draft and the recommendation.
    await expect(row).toContainText('Reviewing', { timeout: 30_000 })
    await expect(row).toContainText('Changes required', { timeout: 90_000 })
    await expect(row).toContainText('Claude drafted a summary and 1 comment.', { timeout: 30_000 })

    // Step 6: the pending review is on the reviewed commit, has no event and has one comment.
    // It is the only write call, and it ran one time.
    const post = JSON.parse(await readText(join(testHome, 'review-post.json')))
    expect(post.commit_id).toBe(head)
    expect(Object.hasOwn(post, 'event')).toBe(false)
    expect(post.comments).toHaveLength(1)
    expect(post.comments[0]).toMatchObject({ line: 12, path: 'src/limit.ts', side: 'RIGHT' })
    expect(await readText(join(testHome, 'gh-writes.log'))).toBe(`${REVIEW_CREATE}\n`)

    // Step 7: two review session starts: the refused start of step 3 and the start after the
    // trust. Each has the flags of a read-only test session, and the prompt is the last
    // argument with the input file.
    const starts = (await readText(join(testHome, 'review-args.log'))).trimEnd().split('\n')
    expect(starts).toHaveLength(2)
    for (const args of starts) {
      expect(args).toContain('--restricted')
      expect(args).toContain('--tools Read Glob Grep Write Skill')
      expect(args).toContain('"disableAllHooks":true')
      expect(args).toContain('--model haiku')
      expect(args).toMatch(/--name bifrost-test-\S+/)
      expect(args).toMatch(/ \/bifrost-review bifrost-input=\/\S+\/input\.json$/)
    }

    // Step 8: Request changes opens the Review panel. The panel reads the draft from the fake gh
    // and shows the summary and the comment of Claude. The user changes the summary and sends the
    // review. Bifrost writes the new summary, then submits the draft with REQUEST_CHANGES.
    const page = started.page
    await row.getByRole('button', { exact: true, name: 'Request changes' }).click()
    const panel = page.locator(`[data-review-draft="${PR_KEY}"]`)
    await expect(panel).toBeVisible({ timeout: 30_000 })
    await expect(panel.locator('[data-draft-comment="PRRC_fake1"]')).toContainText(
      'src/limit.ts line 12',
    )
    const summary = panel.locator('[data-draft-summary]')
    await expect(summary).toHaveValue(
      'The limit goes from 12 to 1200. Please explain the new value, or keep it lower.',
    )
    await summary.fill('Please explain the new limit.')
    await panel.locator('[data-draft-send]').click()
    await expect(panel).toHaveCount(0, { timeout: 30_000 })
    const writes = (await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')
    expect(writes).toHaveLength(3)
    expect(writes[0]).toBe(REVIEW_CREATE)
    expect(writes[1]).toMatch(/^api graphql -f query=mutation EditBody\(/)
    expect(writes[1]).toMatch(/ -f body=Please explain the new limit\. -f review=PRR_fake$/)
    expect(writes[2]).toMatch(/^api graphql -f query=mutation SendChanges\(/)
    expect(writes[2]).toContain(
      'submitPullRequestReview(input: { pullRequestReviewId: $review, event: REQUEST_CHANGES })',
    )
    expect(writes[2]).toMatch(/ -f review=PRR_fake$/)

    // Step 9: the next poll has no review request for the user, so the row goes. A poll comes
    // at most one time in 5 seconds, so the test clicks Refresh until the fake gh got a poll
    // after the send.
    const tabs = page.locator('[role="tablist"]', { has: page.locator('[data-reviews-tab]') })
    await expect
      .poll(
        async () => {
          if ((await readText(join(testHome, 'gh-polls-sent'))) !== '') return true
          await tabs.getByRole('button', { exact: true, name: 'Refresh' }).click()
          return false
        },
        { intervals: [2_000], timeout: 30_000 },
      )
      .toBe(true)
    await expect(row).toHaveCount(0)
    expect((await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')).toHaveLength(3)

    // Step 10: quit the app. The fakes got no unknown call.
    await started.app.close()
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
    // Step 11: stop the sleep of the fake review session.
    await stopFakeSession(testHome)
    await removeTestHome(testHome)
  }
})

test('an Approve click submits the draft review of an Approve round as an approval', async () => {
  test.setTimeout(180_000)
  // Step 1: make the test home, the remote and the fixture files. The fake
  // claude gives an Approve result with a summary, so Bifrost saves a draft review.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-approve-round-'))
  const appOutput: string[] = []
  let app = null as ElectronApplication | null
  try {
    const head = await makeRemote(testHome)
    await writeFile(join(testHome, 'smoke-head'), head)
    await writeFile(join(testHome, 'gh-fixtures'), 'approve-round')
    const started = await startReview(testHome, appOutput, launched => {
      app = launched
    })
    const { row } = started

    // Step 5: the round runs, then the row shows the draft, the recommendation and the button.
    await expect(row).toContainText('Reviewing', { timeout: 30_000 })
    await expect(row).toContainText('Approval recommended', { timeout: 90_000 })
    const approve = row.getByRole('button', { exact: true, name: 'Approve' })
    await expect(approve).toBeEnabled({ timeout: 30_000 })
    const post = JSON.parse(await readText(join(testHome, 'review-post.json')))
    expect(post.commit_id).toBe(head)
    expect(post.body).toBe('The change is small, and the test covers it.')
    expect(Object.hasOwn(post, 'event')).toBe(false)
    expect(await readText(join(testHome, 'gh-writes.log'))).toBe(`${REVIEW_CREATE}\n`)

    // Step 6: one click submits the draft review as an approval. The row shows that the user
    // approved, and the button goes.
    await approve.click()
    await expect(row).toContainText('You approved', { timeout: 30_000 })
    await expect(approve).toHaveCount(0, { timeout: 30_000 })
    const writes = (await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')
    expect(writes).toHaveLength(2)
    expect(writes[0]).toBe(REVIEW_CREATE)
    expect(writes[1]).toMatch(/^api graphql -f query=mutation ApproveDraft\(/)
    expect(writes[1]).toContain(
      'submitPullRequestReview(input: { pullRequestReviewId: $review, event: APPROVE })',
    )
    expect(writes[1]).toMatch(/ -f review=PRR_fake$/)

    // Step 7: the next poll shows the approval of the user on the head. The row still shows it,
    // with no button, and Bifrost writes nothing more. A poll comes at most one time in 5
    // seconds, so the test clicks Refresh until the fake gh got a poll after the write.
    const tabs = started.page.locator('[role="tablist"]', {
      has: started.page.locator('[data-reviews-tab]'),
    })
    await expect
      .poll(
        async () => {
          if ((await readText(join(testHome, 'gh-polls-approved'))) !== '') return true
          await tabs.getByRole('button', { exact: true, name: 'Refresh' }).click()
          return false
        },
        { intervals: [2_000], timeout: 30_000 },
      )
      .toBe(true)
    await expect(row).toContainText('You approved')
    await expect(approve).toHaveCount(0, { timeout: 30_000 })
    expect((await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')).toHaveLength(2)

    // Step 8: quit the app. The fakes got no unknown call.
    await started.app.close()
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
    // Step 9: stop the sleep of the fake review session.
    await stopFakeSession(testHome)
    await removeTestHome(testHome)
  }
})

test('an Approve click with no draft approves the reviewed commit with no text', async () => {
  test.setTimeout(180_000)
  // Step 1: make the test home, the remote and the fixture files. The fake
  // claude gives an Approve result with nothing to post, so Bifrost saves no draft review.
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-approve-head-'))
  const appOutput: string[] = []
  let app = null as ElectronApplication | null
  try {
    const head = await makeRemote(testHome)
    await writeFile(join(testHome, 'smoke-head'), head)
    await writeFile(join(testHome, 'gh-fixtures'), 'approve-head-round')
    const started = await startReview(testHome, appOutput, launched => {
      app = launched
    })
    const { row } = started

    // Step 5: the round runs. Nothing is posted, and the row shows the button.
    await expect(row).toContainText('Reviewing', { timeout: 30_000 })
    await expect(row).toContainText('Approval recommended', { timeout: 90_000 })
    await expect(row).toContainText('Claude found nothing to change.', { timeout: 30_000 })
    const approve = row.getByRole('button', { exact: true, name: 'Approve' })
    await expect(approve).toBeEnabled({ timeout: 30_000 })
    expect(await readText(join(testHome, 'gh-writes.log'))).toBe('')

    // Step 6: one click approves the reviewed commit, with the PR ID of the fresh read and no
    // text. It is the only write.
    await approve.click()
    await expect(row).toContainText('You approved', { timeout: 30_000 })
    await expect(approve).toHaveCount(0, { timeout: 30_000 })
    const writes = (await readText(join(testHome, 'gh-writes.log'))).trimEnd().split('\n')
    expect(writes).toHaveLength(1)
    expect(writes[0]).toMatch(/^api graphql -f query=mutation ApproveHead\(/)
    expect(writes[0]).toContain(
      'addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: APPROVE })',
    )
    expect(writes[0]).toMatch(new RegExp(` -f commit=${head} -f pr=PR_fake7$`))
    expect(writes[0]).not.toContain('body')

    // Step 7: quit the app. The fakes got no unknown call.
    await started.app.close()
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
    // Step 8: stop the sleep of the fake review session.
    await stopFakeSession(testHome)
    await removeTestHome(testHome)
  }
})
