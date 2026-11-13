import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import {
  type BranchCommit,
  COMMIT_TIMEOUT_MS,
  type CommitTarget,
  commentOnPr,
  commitOnBranch,
  defuseMentions,
  fixedBy,
  MAX_QUOTE,
  quoteRequest,
  replyToThread,
  requestReviewer,
  resolveThread,
} from '../../../src/main/reviews/request-writes'
import {
  REASON_FILES_REFUSED,
  REASON_NOT_RESOLVED,
  REASON_PUSH_TARGET,
  REASON_WRITE_FAILED,
  REASON_WRITE_TIMEOUT,
  REASON_WRITE_UNREADABLE,
  reasonPostsStopped,
} from '../../../src/main/reviews/round-text'
import { REASON_GH_LOGGED_OUT } from '../../../src/shared/reviews'

const TIME = '2026-11-12T10:00:00Z'
// The zero-width space that defuses a mention.
const Z = '\u200b'

// A fake gh that records each call and gives the next answer. It never calls GitHub.
function fakeGh(answers: ExecResult[]): { gh: Gh; calls: string[][] } {
  const calls: string[][] = []
  const gh: Gh = {
    async run(args, opts) {
      if (opts?.input !== undefined) throw new Error('a write must not use stdin')
      calls.push(args)
      const answer = answers.shift()
      if (answer === undefined) throw new Error(`no answer for call ${calls.length}`)
      return answer
    },
  }
  return { calls, gh }
}

const ok = (data: unknown): ExecResult => ({
  code: 0,
  stderr: '',
  stdout: JSON.stringify({ data }),
})
const replied = (state = 'SUBMITTED'): ExecResult =>
  ok({ addPullRequestReviewThreadReply: { comment: { createdAt: TIME, id: 'PRRC_9', state } } })
const resolved = (): ExecResult =>
  ok({ resolveReviewThread: { thread: { id: 'PRRT_1', isResolved: true } } })
const commented = (): ExecResult =>
  ok({ addComment: { commentEdge: { node: { createdAt: TIME, id: 'IC_9' } } } })
const requested = (): ExecResult => ok({ requestReviews: { pullRequest: { id: 'PR_1' } } })

interface Sent {
  name: string
  fields: string[]
  vars: Record<string, string>
  flags: string[]
  query: string
}

// The operation name, the fields with an input, the variables and the flags of one call.
function sent(args: string[]): Sent {
  const vars: Record<string, string> = {}
  const flags: string[] = []
  let query = ''
  for (let i = 2; i < args.length; i += 2) {
    const flag = args[i] ?? ''
    const [name = '', ...rest] = (args[i + 1] ?? '').split('=')
    flags.push(flag)
    if (name === 'query') query = rest.join('=')
    else vars[name] = rest.join('=')
  }
  return {
    fields: [...query.matchAll(/\b(\w+)\s*\(\s*input\s*:/g)].map(m => m[1] ?? ''),
    flags,
    name: /^mutation (\w+)/.exec(query)?.[1] ?? '',
    query,
    vars,
  }
}

describe('the GitHub writes of a request round', () => {
  it('each write sends one mutation with its variables', async () => {
    const { calls, gh } = fakeGh([replied(), resolved(), commented(), requested()])
    expect(await replyToThread(gh, { body: 'Done.', threadId: 'PRRT_1' })).toEqual({
      ok: true,
      value: { createdAt: Date.parse(TIME), id: 'PRRC_9', pending: false },
    })
    expect(await resolveThread(gh, 'PRRT_1')).toEqual({ ok: true, value: { resolved: true } })
    expect(await commentOnPr(gh, { body: 'Thanks.', prId: 'PR_1' })).toEqual({
      ok: true,
      value: { createdAt: Date.parse(TIME), id: 'IC_9' },
    })
    expect(await requestReviewer(gh, { prId: 'PR_1', userId: 'U_1' })).toEqual({
      ok: true,
      value: null,
    })

    for (const args of calls) expect(args.slice(0, 2)).toEqual(['api', 'graphql'])
    const all = calls.map(sent)
    expect(all.map(s => s.name)).toEqual([
      'ReplyToThread',
      'ResolveThread',
      'CommentOnPr',
      'RequestReviewer',
    ])
    expect(all.map(s => s.fields)).toEqual([
      ['addPullRequestReviewThreadReply'],
      ['resolveReviewThread'],
      ['addComment'],
      ['requestReviews'],
    ])
    expect(all.map(s => s.vars)).toEqual([
      { body: 'Done.', thread: 'PRRT_1' },
      { thread: 'PRRT_1' },
      { body: 'Thanks.', subject: 'PR_1' },
      { pr: 'PR_1', user: 'U_1' },
    ])
    // No value goes in the query text.
    for (const s of all) {
      for (const value of Object.values(s.vars)) expect(s.query).not.toContain(value)
    }
  })

  it('a text that starts with @ goes as -f and is not read as a file', async () => {
    const { calls, gh } = fakeGh([replied(), commented()])
    await replyToThread(gh, { body: '@/etc/passwd', threadId: 'PRRT_1' })
    await commentOnPr(gh, { body: '@~/.netrc', prId: 'PR_1' })
    expect(calls[0]).toContain('body=@/etc/passwd')
    expect(calls[1]).toContain('body=@~/.netrc')
    for (const args of calls) {
      expect(args).not.toContain('-F')
      expect(sent(args).flags.every(flag => flag === '-f')).toBe(true)
    }
  })

  it('requestReviewer sends union true and one user', async () => {
    const { calls, gh } = fakeGh([requested()])
    await requestReviewer(gh, { prId: 'PR_1', userId: 'U_1' })
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/requestReviews\(input: \{[^}]*\bunion: true\b[^}]*\}\)/)
    expect(query).toContain('userIds: [$user]')
    expect(query).toContain('$user: ID!')
    expect(Object.keys(vars).sort()).toEqual(['pr', 'user'])
  })

  it('an answer with errors is a failure', async () => {
    const message = 'Could not resolve to a node with the global id of PRRT_1.'
    const { gh } = fakeGh([
      // gh prints the answer and exits with code 1.
      {
        code: 1,
        stderr: `gh: ${message}`,
        stdout: JSON.stringify({ data: null, errors: [{ message: `${message}\nmore` }] }),
      },
      // An answer with data and errors also fails.
      {
        code: 0,
        stderr: '',
        stdout: JSON.stringify({ data: { addComment: null }, errors: [{ message: 'Nope' }] }),
      },
      { code: 0, stderr: '', stdout: JSON.stringify({ errors: [{}] }) },
    ])
    // The row gets a fixed text. The raw text is the detail for the Event log.
    expect(await replyToThread(gh, { body: 'Done.', threadId: 'PRRT_1' })).toEqual({
      detail: message,
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: false,
    })
    expect(await commentOnPr(gh, { body: 'Done.', prId: 'PR_1' })).toEqual({
      detail: 'Nope',
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: false,
    })
    expect(await resolveThread(gh, 'PRRT_1')).toEqual({
      message: REASON_WRITE_UNREADABLE,
      ok: false,
      unknown: false,
    })
  })

  it('a timeout is an unknown result', async () => {
    const { gh } = fakeGh([
      { code: 1, stderr: '', stdout: '', timedOut: true },
      // Exit code 0 with an answer that Bifrost cannot read.
      { code: 0, stderr: '', stdout: 'not json' },
      ok({ addComment: { commentEdge: { node: {} } } }),
      ok({ requestReviews: null }),
      { code: 1, stderr: 'gh: Server Error (HTTP 502)', stdout: '' },
      { code: 1, overflow: true, stderr: 'maxBuffer', stdout: '' },
    ])
    expect(await replyToThread(gh, { body: 'Done.', threadId: 'PRRT_1' })).toEqual({
      message: REASON_WRITE_TIMEOUT,
      ok: false,
      unknown: true,
    })
    const unread = { message: REASON_WRITE_UNREADABLE, ok: false, unknown: true }
    expect(await resolveThread(gh, 'PRRT_1')).toEqual(unread)
    expect(await commentOnPr(gh, { body: 'Done.', prId: 'PR_1' })).toEqual(unread)
    expect(await requestReviewer(gh, { prId: 'PR_1', userId: 'U_1' })).toEqual(unread)
    expect(await resolveThread(gh, 'PRRT_1')).toEqual({
      detail: 'gh: Server Error (HTTP 502)',
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: true,
    })
    expect(await resolveThread(gh, 'PRRT_1')).toEqual(unread)
  })

  it('a refusal of GitHub, a missing gh and a logged-out gh are known results', async () => {
    const { gh } = fakeGh([
      { code: 1, stderr: 'gh: You have exceeded a secondary rate limit (HTTP 403)', stdout: '' },
      { code: 4, stderr: 'To get started with GitHub CLI, please run:  gh auth login', stdout: '' },
      { code: 1, stderr: 'spawn gh ENOENT', stdout: '' },
    ])
    expect(await resolveThread(gh, 'PRRT_1')).toEqual({
      detail: 'gh: You have exceeded a secondary rate limit (HTTP 403)',
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: false,
    })
    expect(await resolveThread(gh, 'PRRT_1')).toEqual({
      message: REASON_GH_LOGGED_OUT,
      ok: false,
      unknown: false,
    })
    expect(await resolveThread(gh, 'PRRT_1')).toMatchObject({ ok: false, unknown: false })
  })

  it('a reply that goes into a pending review gives pending true', async () => {
    const { gh } = fakeGh([replied('PENDING')])
    expect(await replyToThread(gh, { body: 'Done.', threadId: 'PRRT_1' })).toEqual({
      ok: true,
      value: { createdAt: Date.parse(TIME), id: 'PRRC_9', pending: true },
    })
  })
})

// The PR of a signed fix commit, and a commit for its head branch.
const TARGET: CommitTarget = {
  baseRef: 'main',
  crossRepository: false,
  defaultBranch: 'main',
  headRef: 'feature',
  owner: 'acme',
  repo: 'api',
}
const HEAD_OID = 'a'.repeat(40)
const NEW_OID = 'b'.repeat(40)
const CONTENTS = Buffer.from('export const limit = 10\n').toString('base64')
const BRANCH_COMMIT: BranchCommit = {
  additions: [{ contents: CONTENTS, path: 'src/limit.ts' }],
  body: 'The limit was 5.',
  branch: 'feature',
  deletions: [{ path: 'src/old.ts' }],
  expectedHeadOid: HEAD_OID,
  headline: 'fix: raise the limit',
  repository: 'acme/api',
}

interface StdinCall {
  args: string[]
  input: string | undefined
  timeoutMs: number | undefined
}

// A fake gh for the commit write. It records the arguments and stdin of each call.
function stdinGh(answers: ExecResult[]): { gh: Gh; calls: StdinCall[] } {
  const calls: StdinCall[] = []
  const gh: Gh = {
    async run(args, opts) {
      calls.push({ args, input: opts?.input, timeoutMs: opts?.timeoutMs })
      const answer = answers.shift()
      if (answer === undefined) throw new Error(`no answer for call ${calls.length}`)
      return answer
    },
  }
  return { calls, gh }
}

const committed = (oid = NEW_OID): ExecResult => ok({ createCommitOnBranch: { commit: { oid } } })

describe('commitOnBranch', () => {
  it('sends the commit as one createCommitOnBranch call with the body on stdin', async () => {
    const { calls, gh } = stdinGh([committed()])
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual({
      ok: true,
      value: { oid: NEW_OID },
    })
    expect(calls).toHaveLength(1)
    const call = calls[0] as StdinCall
    // The arguments hold no value: no file contents, path, branch or message.
    expect(call.args).toEqual(['api', 'graphql', '--input', '-'])
    expect(call.timeoutMs).toBe(COMMIT_TIMEOUT_MS)
    const body = JSON.parse(call.input ?? '')
    expect(Object.keys(body).sort()).toEqual(['query', 'variables'])
    expect(body.query).toMatch(/^mutation CommitOnBranch\(\$input: CreateCommitOnBranchInput!\) \{/)
    expect([...String(body.query).matchAll(/\b(\w+)\s*\(\s*input\s*:/g)].map(m => m[1])).toEqual([
      'createCommitOnBranch',
    ])
    expect(body.variables).toEqual({
      input: {
        branch: { branchName: 'feature', repositoryNameWithOwner: 'acme/api' },
        expectedHeadOid: HEAD_OID,
        fileChanges: {
          additions: [{ contents: CONTENTS, path: 'src/limit.ts' }],
          deletions: [{ path: 'src/old.ts' }],
        },
        message: { body: 'The limit was 5.', headline: 'fix: raise the limit' },
      },
    })
    expect(COMMIT_TIMEOUT_MS).toBeGreaterThan(30_000)
  })

  it('sends no body for a message with one line', async () => {
    const { calls, gh } = stdinGh([committed()])
    await commitOnBranch(gh, TARGET, { ...BRANCH_COMMIT, body: '' })
    expect(JSON.parse(calls[0]?.input ?? '').variables.input.message).toEqual({
      headline: 'fix: raise the limit',
    })
  })

  it('refuses another repository or branch, the default or base branch and a fork', async () => {
    const refused = { message: REASON_PUSH_TARGET, ok: false, unknown: false }
    const cases: [Partial<CommitTarget>, Partial<BranchCommit>][] = [
      // Another repository than the repository of the PR.
      [{}, { repository: 'globex/api' }],
      [{}, { repository: 'acme/web' }],
      [{}, { repository: 'acme/api/x' }],
      [{ owner: '../acme' }, { repository: '../acme/api' }],
      // Another branch than the head branch of the PR.
      [{}, { branch: 'other' }],
      [{}, { branch: 'Feature' }],
      [{}, { branch: 'refs/heads/feature' }],
      // The default branch or the base branch, in any case.
      [{ headRef: 'main' }, { branch: 'main' }],
      [{ defaultBranch: 'trunk', headRef: 'Trunk' }, { branch: 'Trunk' }],
      [{ baseRef: 'develop', headRef: 'develop' }, { branch: 'develop' }],
      [{ defaultBranch: '' }, {}],
      [{ baseRef: '' }, {}],
      // A name that git or GitHub can read as something else.
      [{ headRef: '-feature' }, { branch: '-feature' }],
      [{ headRef: '' }, { branch: '' }],
      // A PR from a fork. A missing value counts as a fork.
      [{ crossRepository: true }, {}],
      [{ crossRepository: undefined }, {}],
      // A head that is not a commit ID, and a message that is not one headline.
      [{}, { expectedHeadOid: 'feature' }],
      [{}, { headline: '' }],
      [{}, { headline: 'fix: one\ntwo' }],
    ]
    const { calls, gh } = stdinGh([])
    for (const [pr, commit] of cases) {
      const r = await commitOnBranch(gh, { ...TARGET, ...pr }, { ...BRANCH_COMMIT, ...commit })
      expect(r, JSON.stringify([pr, commit])).toEqual(refused)
    }
    expect(calls).toEqual([])
    // The same PR in another case of the owner or the repository is the same repository.
    const same = stdinGh([committed()])
    expect(
      await commitOnBranch(same.gh, TARGET, { ...BRANCH_COMMIT, repository: 'Acme/API' }),
    ).toMatchObject({ ok: true })
  })

  it('a GraphQL error is a known failure, and its text holds no file contents', async () => {
    const echo = `Variable $input got a bad value (Could not coerce "${CONTENTS}" to Base64String)`
    const { gh } = stdinGh([
      {
        code: 1,
        stderr: 'gh: Expected branch to point to "aaaa" but it did not.',
        stdout: JSON.stringify({
          data: { createCommitOnBranch: null },
          errors: [
            { message: 'Expected branch to point to "aaaa" but it did not. Pull and try again.' },
          ],
        }),
      },
      { code: 1, stderr: '', stdout: JSON.stringify({ errors: [{ message: echo }] }) },
      // Only the start of a file shows in a cut text.
      {
        code: 1,
        stderr: '',
        stdout: JSON.stringify({ errors: [{ message: `Bad value ${CONTENTS.slice(0, 12)}` }] }),
      },
      // The error line of gh, with no answer, can quote a file too.
      { code: 1, stderr: `gh: bad value ${CONTENTS.slice(0, 12)} (HTTP 422)`, stdout: '' },
    ])
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual({
      detail: 'Expected branch to point to "aaaa" but it did not. Pull and try again.',
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: false,
    })
    // A text that quotes a file gives no detail, so the file never reaches a log.
    const refused = { message: REASON_FILES_REFUSED, ok: false, unknown: false }
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual(refused)
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual(refused)
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual(refused)
    expect(REASON_FILES_REFUSED).toBe('it refused the files of the fix.')
  })

  it('a timeout, a server error or an answer with no commit is an unknown result', async () => {
    const { gh } = stdinGh([
      { code: 1, stderr: '', stdout: '', timedOut: true },
      { code: 1, stderr: 'gh: Server Error (HTTP 502)', stdout: '' },
      committed('not-a-sha'),
      ok({ createCommitOnBranch: null }),
    ])
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual({
      message: REASON_WRITE_TIMEOUT,
      ok: false,
      unknown: true,
    })
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual({
      detail: 'gh: Server Error (HTTP 502)',
      message: REASON_WRITE_FAILED,
      ok: false,
      unknown: true,
    })
    const unread = { message: REASON_WRITE_UNREADABLE, ok: false, unknown: true }
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual(unread)
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual(unread)
  })

  it('a refusal of GitHub (HTTP 4xx) and a logged-out gh are known results', async () => {
    const { gh } = stdinGh([
      { code: 1, stderr: 'gh: Resource not accessible by integration (HTTP 403)', stdout: '' },
      { code: 4, stderr: 'To get started with GitHub CLI, please run:  gh auth login', stdout: '' },
    ])
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toMatchObject({
      ok: false,
      unknown: false,
    })
    expect(await commitOnBranch(gh, TARGET, BRANCH_COMMIT)).toEqual({
      message: REASON_GH_LOGGED_OUT,
      ok: false,
      unknown: false,
    })
  })
})

describe('the texts of the writes', () => {
  it('the reasons of a stopped run read well after the GitHub text', () => {
    expect(reasonPostsStopped(1, 3, REASON_WRITE_TIMEOUT)).toBe(
      'GitHub stopped after 1 of 3 updates: it took too long to answer. ' +
        'Choose Try again to send the rest.',
    )
    for (const reason of [REASON_WRITE_TIMEOUT, REASON_WRITE_UNREADABLE, REASON_NOT_RESOLVED]) {
      expect(reason).not.toMatch(/GitHub/)
    }
  })

  it('fixedBy names the short commit', () => {
    expect(fixedBy('0123456789abcdef0123456789abcdef01234567')).toBe('Fixed by 0123456')
  })

  it('defuseMentions puts a zero-width space after each @ that can start a mention', () => {
    expect(defuseMentions('Thanks @ravi, and @acme/core-team too.')).toBe(
      `Thanks @${Z}ravi, and @${Z}acme/core-team too.`,
    )
    expect(defuseMentions('@ravi: done (cc @mia-k)\n@lee_acme')).toBe(
      `@${Z}ravi: done (cc @${Z}mia-k)\n@${Z}lee_acme`,
    )
    // No backtick, code span, escape or entity next to the @ can make the mention work again.
    expect(defuseMentions('a`@ravi`b \\@mia @&#114;avi &amp@lee')).toBe(
      `a\`@${Z}ravi\`b \\@${Z}mia @${Z}&#114;avi &amp@${Z}lee`,
    )
    // A second pass changes nothing.
    const once = defuseMentions('@ravi &#64;mia')
    expect(defuseMentions(once)).toBe(once)
    expect(defuseMentions('no mention, not @ ravi, @')).toBe('no mention, not @ ravi, @')
  })

  it('defuseMentions keeps an email-like text as it is', () => {
    expect(defuseMentions('Mail dev@example.com or a.b@x.io, or ping x9@acme/core.')).toBe(
      'Mail dev@example.com or a.b@x.io, or ping x9@acme/core.',
    )
  })

  it('defuseMentions turns an entity that makes an @ into a defused @', () => {
    expect(defuseMentions('&#64;ravi &#x40;mia &commat;lee &#064;sam &#X40jo')).toBe(
      `@${Z}ravi @${Z}mia @${Z}lee @${Z}sam @${Z}jo`,
    )
  })

  it('defuseMentions keeps only a link that GitHub makes as a link', () => {
    const npm = 'https://www.npmjs.com/package/@types/node'
    expect(defuseMentions(`See ${npm}\nand www.example.com/@ravi.`)).toBe(
      `See ${npm}\nand www.example.com/@ravi.`,
    )
    expect(defuseMentions(`[the types](${npm})`)).toBe(`[the types](${npm})`)
    // An _ in the last two parts of the host, a space that is not ASCII before www, and a host
    // that does not end at / ? # or : make no link on GitHub.
    expect(defuseMentions('https://x.io_/@ravi')).toBe(`https://x.io_/@${Z}ravi`)
    expect(defuseMentions('www.example.com_/@acme/core-team')).toBe(
      `www.example.com_/@${Z}acme/core-team`,
    )
    expect(defuseMentions(' www.x.io/@ravi')).toBe(` www.x.io/@${Z}ravi`)
    expect(defuseMentions('x(www.x.io/@ravi) https://x.io.@ravi')).toBe(
      `x(www.x.io/@${Z}ravi) https://x.io.@${Z}ravi`,
    )
    // A Markdown link ends at its bracket, and a host with no dot is not a link here.
    expect(defuseMentions('[a](https://x.io/y)@ravi http://localhost/@mia')).toBe(
      `[a](https://x.io/y)@${Z}ravi http://localhost/@${Z}mia`,
    )
  })

  it('defuseMentions keeps no link as it is in a text that can hold HTML', () => {
    // GitHub reads an HTML block as HTML, so a code span or a link there does not stop a mention.
    expect(defuseMentions('> <div>\n> `@acme/team` https://x.io/@ravi\n> </div>')).toBe(
      `> <div>\n> \`@${Z}acme/team\` https://x.io/@${Z}ravi\n> </div>`,
    )
  })

  it('quoteRequest quotes 3 lines at most and cuts at MAX_QUOTE', () => {
    expect(quoteRequest('Rename this.\r\nAnd @ravi agrees.\n\nLine 4\nLine 5')).toBe(
      `> Rename this.\n> And @${Z}ravi agrees.`,
    )
    expect(quoteRequest('One\n\nTwo\nThree')).toBe('> One\n>\n> Two')
    expect(quoteRequest(`${'x'.repeat(MAX_QUOTE + 50)}\nnext`)).toBe(`> ${'x'.repeat(MAX_QUOTE)}`)
    expect(quoteRequest(`${'a'.repeat(MAX_QUOTE - 3)}\n${'b'.repeat(10)}`)).toBe(
      `> ${'a'.repeat(MAX_QUOTE - 3)}\n> bb`,
    )
    expect(quoteRequest('  \n ')).toBe('')
  })
})
