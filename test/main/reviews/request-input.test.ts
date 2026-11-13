import { existsSync } from 'node:fs'
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { isCopilot, isTrustedHuman, type WorkItem } from '../../../src/main/reviews/model'
import type { Author, PrComment } from '../../../src/main/reviews/pr-data'
import type { FetchedPr, RepoStore } from '../../../src/main/reviews/repo-store'
import {
  MAX_HUNK,
  MAX_ITEM_TEXT,
  REQUEST_INPUT_VERSION,
  REQUEST_MODE,
  type RequestInput,
  writeRequestFiles,
} from '../../../src/main/reviews/request-input'
import type { RequestContext, RequestThread } from '../../../src/main/reviews/request-query'
import {
  CUT_MARKER,
  MAX_DIFF_BYTES,
  REASON_INPUT_FAILED,
} from '../../../src/main/reviews/review-input'
import type { Question } from '../../../src/main/reviews/state'
import { COPILOT_LOGIN } from '../../../src/shared/reviews'

let base: string
let skillsDir: string

beforeAll(async () => {
  base = await mkdtemp(join(tmpdir(), 'bifrost-request-input-'))
  skillsDir = join(base, 'skills-src')
  await mkdir(join(skillsDir, 'skills/bifrost-resolve-comments'), { recursive: true })
  await mkdir(join(skillsDir, 'skills/bifrost-humanise'), { recursive: true })
  await writeFile(join(skillsDir, REQUEST_MODE), 'REQUEST MODE TEXT\n')
  await writeFile(join(skillsDir, 'skills/bifrost-humanise/rules.md'), 'HUMANISE TEXT\n')
})

afterAll(async () => {
  await rm(base, { force: true, recursive: true })
})

const DIFF = [
  'diff --git a/src/limit.ts b/src/limit.ts',
  '--- a/src/limit.ts',
  '+++ b/src/limit.ts',
  '@@ -1 +1,2 @@',
  ' one',
  '+two',
  '',
].join('\n')

// A fake store. writeDiff writes fixed text with the mode 0644 that git diff --output gives.
function fakeRepos(opts: { diff?: string; failReset?: boolean } = {}): {
  repos: RepoStore
  diffs: { from: string; to: string; mode: string }[]
} {
  const diffs: { from: string; to: string; mode: string }[] = []
  const repos = {
    async resetIo(_clone: string, number: number): Promise<string> {
      if (opts.failReset) throw new Error('/secret/path is busy')
      const io = join(base, `io-${Math.random().toString(36).slice(2)}-${number}`)
      await mkdir(io, { mode: 0o700, recursive: true })
      return io
    },
    async writeDiff(
      _clone: string,
      from: string,
      to: string,
      file: string,
      mode: 'merge-base' | 'direct',
    ): Promise<void> {
      diffs.push({ from, mode, to })
      await writeFile(file, opts.diff ?? DIFF)
      await chmod(file, 0o644)
    },
  } as unknown as RepoStore
  return { diffs, repos }
}

const fetched: FetchedPr = { base: 'b'.repeat(40), head: 'h'.repeat(40), mergeBase: 'm'.repeat(40) }
const HUNK = '@@ -1 +1,2 @@\n one\n+two'

const at = (iso: string): number => Date.parse(iso)

function comment(id: string, login: string, association: string, body: string, iso: string) {
  return {
    author: { association, bot: false, login },
    body,
    createdAt: at(iso),
    databaseId: 1,
    id,
  } satisfies PrComment
}

function thread(over: Partial<RequestThread> = {}): RequestThread {
  return {
    comments: [
      comment('PRRC_1', 'alice', 'MEMBER', 'Check the upper limit.', '2026-11-11T09:00:00.000Z'),
      comment('PRRC_2', 'Dana', 'OWNER', 'I will look.', '2026-11-11T10:00:00.000Z'),
    ],
    diffHunk: HUNK,
    id: 'PRRT_1',
    isOutdated: false,
    isResolved: false,
    line: 12,
    path: 'src/limit.ts',
    reviewId: 'PRR_1',
    viewerCanReply: true,
    ...over,
  }
}

function context(over: Partial<RequestContext> = {}): RequestContext {
  return {
    author: 'dana',
    baseRef: 'main',
    baseSha: 'b'.repeat(40),
    body: 'This adds a rate limit.',
    comments: [
      comment('IC_1', 'erin', 'MEMBER', 'Update the README too.', '2026-11-11T11:00:00.000Z'),
    ],
    decisions: [],
    defaultBranch: 'main',
    headRef: 'feature',
    headSha: 'h'.repeat(40),
    id: 'PR_1',
    isCrossRepository: false,
    number: 9,
    owner: 'acme',
    repo: 'api',
    requested: [],
    reviews: [
      {
        author: { association: 'MEMBER', bot: false, login: 'alice' },
        body: 'Please add a limit check.',
        commit: null,
        databaseId: 3,
        id: 'PRR_1',
        state: 'CHANGES_REQUESTED',
        submittedAt: at('2026-11-11T08:00:00.000Z'),
      },
    ],
    state: 'OPEN',
    threads: [thread(), thread({ id: 'PRRT_2', isOutdated: true, line: null, path: 'src/old.ts' })],
    title: 'Add the rate limit',
    truncated: false,
    updatedAt: 1,
    url: 'https://github.com/acme/api/pull/9',
    viewerPending: false,
    ...over,
  }
}

const ITEMS: WorkItem[] = [
  { id: 'PRRT_1', kind: 'thread' },
  { id: 'IC_1', kind: 'comment' },
  { id: 'PRR_1', kind: 'review-body' },
]

function args(
  over: {
    context?: RequestContext
    items?: readonly WorkItem[]
    questions?: Record<string, Question>
  } = {},
) {
  return {
    clone: join(base, 'clone'),
    context: over.context ?? context(),
    fetched,
    items: over.items ?? ITEMS,
    number: 9,
    questions: over.questions ?? {},
    viewer: 'dana',
  }
}

async function written(over: Parameters<typeof args>[0] = {}, diff?: string) {
  const { diffs, repos } = fakeRepos(diff === undefined ? {} : { diff })
  const r = await writeRequestFiles({ repos, skillsDir }, args(over))
  if (!r.ok) throw new Error(r.message)
  return { ...r, diffs }
}

const mode = async (file: string): Promise<number> => (await stat(file)).mode & 0o777

describe('writeRequestFiles', () => {
  it('writes input.json, mode.md, humanise-rules.md and full.diff with mode 0600', async () => {
    const r = await written()
    const { files } = r.input
    expect(r.inputFile.endsWith('/input.json')).toBe(true)
    expect(files.mode.endsWith('/mode.md')).toBe(true)
    expect(files.rules.endsWith('/humanise-rules.md')).toBe(true)
    expect(files.result.endsWith('/result.json')).toBe(true)
    expect(files.fullDiff?.endsWith('/full.diff')).toBe(true)
    for (const file of [r.inputFile, files.mode, files.rules, files.fullDiff ?? '']) {
      expect(await mode(file), file).toBe(0o600)
    }
    expect(await readFile(files.mode, 'utf8')).toBe('REQUEST MODE TEXT\n')
    expect(await readFile(files.rules, 'utf8')).toBe('HUMANISE TEXT\n')
    expect(await readFile(files.fullDiff ?? '', 'utf8')).toBe(DIFF)
    expect(existsSync(files.result)).toBe(false)
    expect(r.diffs).toEqual([{ from: fetched.base, mode: 'merge-base', to: fetched.head }])
    const saved: RequestInput = JSON.parse(await readFile(r.inputFile, 'utf8'))
    expect(saved).toEqual(r.input)
    expect(saved.version).toBe(REQUEST_INPUT_VERSION)
    expect(saved.viewer).toBe('dana')
    expect(saved.pr).toEqual({
      baseRef: 'main',
      baseSha: fetched.base,
      body: 'This adds a rate limit.',
      headRef: 'feature',
      headSha: fetched.head,
      key: 'acme/api#9',
      mergeBase: fetched.mergeBase,
      title: 'Add the rate limit',
      url: 'https://github.com/acme/api/pull/9',
    })
  })

  it('an item holds its thread, and the comments of the viewer have you true', async () => {
    const { input } = await written()
    expect(input.items.map(i => [i.id, i.kind])).toEqual([
      ['PRRT_1', 'thread'],
      ['IC_1', 'comment'],
      ['PRR_1', 'review-body'],
    ])
    expect(input.items[0]).toEqual({
      answer: null,
      comments: [
        {
          association: 'MEMBER',
          at: '2026-11-11T09:00:00.000Z',
          author: 'alice',
          body: 'Check the upper limit.',
          trusted: true,
          you: false,
        },
        {
          association: 'OWNER',
          at: '2026-11-11T10:00:00.000Z',
          author: 'Dana',
          body: 'I will look.',
          trusted: false,
          you: true,
        },
      ],
      diffHunk: HUNK,
      id: 'PRRT_1',
      kind: 'thread',
      line: 12,
      outdated: false,
      path: 'src/limit.ts',
      question: null,
    })
    expect(input.items[1]).toEqual({
      answer: null,
      comments: [
        {
          association: 'MEMBER',
          at: '2026-11-11T11:00:00.000Z',
          author: 'erin',
          body: 'Update the README too.',
          trusted: true,
          you: false,
        },
      ],
      diffHunk: null,
      id: 'IC_1',
      kind: 'comment',
      line: null,
      outdated: false,
      path: null,
      question: null,
    })
    expect(input.items[2]?.comments).toEqual([
      {
        association: 'MEMBER',
        at: '2026-11-11T08:00:00.000Z',
        author: 'alice',
        body: 'Please add a limit check.',
        trusted: true,
        you: false,
      },
    ])
    // An outdated thread keeps its flag. Only the items of the round go in.
    const old = await written({ items: [{ id: 'PRRT_2', kind: 'thread' }] })
    expect(old.input.items).toHaveLength(1)
    expect(old.input.items[0]).toMatchObject({ line: null, outdated: true, path: 'src/old.ts' })
  })

  // Ruling S9: the skill reads trusted and has no trust rule of its own.
  it('trusted is the trust rule of Bifrost, and never true for the viewer', async () => {
    const authors: Author[] = [
      { association: 'MEMBER', bot: false, login: 'alice' },
      { association: 'COLLABORATOR', bot: false, login: 'bo' },
      { association: 'NONE', bot: true, login: COPILOT_LOGIN },
      { association: 'MEMBER', bot: true, login: 'ci-helper' },
      { association: 'NONE', bot: false, login: COPILOT_LOGIN },
      { association: 'CONTRIBUTOR', bot: false, login: 'carl' },
      { association: 'OWNER', bot: false, login: 'dana' },
      { association: 'OWNER', bot: false, login: 'DANA' },
    ]
    const comments = authors.map((author, i) => ({
      author,
      body: `Comment ${i}.`,
      createdAt: at('2026-11-11T09:00:00.000Z') + i,
      databaseId: i,
      id: `PRRC_${i}`,
    }))
    const ctx = context({ threads: [thread({ comments })] })
    const { input } = await written({ context: ctx, items: [{ id: 'PRRT_1', kind: 'thread' }] })
    const flags = input.items[0]?.comments.map(c => [c.author, c.trusted, c.you])
    expect(flags).toEqual([
      ['alice', true, false],
      ['bo', true, false],
      [COPILOT_LOGIN, true, false],
      ['ci-helper', false, false],
      [COPILOT_LOGIN, false, false],
      ['carl', false, false],
      ['dana', false, true],
      ['DANA', false, true],
    ])
    // The same rule as the work rule of Bifrost, except for the viewer.
    for (const [i, author] of authors.entries()) {
      const rule = isTrustedHuman(author, 'dana') || isCopilot(author)
      expect(input.items[0]?.comments[i]?.trusted).toBe(rule && i < 6)
    }
  })

  it('cuts a long comment and a long hunk', async () => {
    const long = 'x'.repeat(MAX_ITEM_TEXT + 50)
    const hunk = `@@ -1 +1 @@\n${'+y\n'.repeat(MAX_HUNK)}`
    const ctx = context({
      threads: [
        thread({
          comments: [comment('PRRC_1', 'alice', 'MEMBER', long, '2026-11-11T09:00:00.000Z')],
          diffHunk: hunk,
        }),
      ],
    })
    const { input } = await written({ context: ctx, items: [{ id: 'PRRT_1', kind: 'thread' }] })
    const item = input.items[0]
    expect(item?.comments[0]?.body).toBe(`${'x'.repeat(MAX_ITEM_TEXT)}${CUT_MARKER}`)
    expect(item?.diffHunk).toBe(`${hunk.slice(0, MAX_HUNK)}${CUT_MARKER}`)
    // A thread with no hunk gives null.
    const none = context({ threads: [thread({ diffHunk: '' })] })
    const empty = await written({ context: none, items: [{ id: 'PRRT_1', kind: 'thread' }] })
    expect(empty.input.items[0]?.diffHunk).toBeNull()
  })

  it('an answered question goes into its item', async () => {
    const questions: Record<string, Question> = {
      IC_1: {
        answer: null,
        at: 1,
        question: 'Is the README in scope?',
        seenUntil: 1,
        where: 'Comment from erin',
      },
      PRRT_1: {
        answer: 'Use 100 as the upper limit.',
        at: 1,
        question: 'Which upper limit?',
        seenUntil: 1,
        where: 'src/limit.ts line 12',
      },
    }
    const { input } = await written({ questions })
    expect(input.items[0]).toMatchObject({
      answer: 'Use 100 as the upper limit.',
      question: 'Which upper limit?',
    })
    expect(input.items[1]).toMatchObject({ answer: null, question: 'Is the README in scope?' })
    expect(input.items[2]).toMatchObject({ answer: null, question: null })
  })

  it('a full diff over MAX_DIFF_BYTES gives no fullDiff and no failure', async () => {
    const r = await written({}, 'x'.repeat(MAX_DIFF_BYTES + 1))
    expect(r.input.files.fullDiff).toBeNull()
    const io = r.inputFile.slice(0, -'/input.json'.length)
    expect(existsSync(join(io, 'full.diff'))).toBe(false)
    expect(await mode(r.inputFile)).toBe(0o600)
    expect(r.input.items).toHaveLength(3)
  })

  it('a failed step gives REASON_INPUT_FAILED with no path', async () => {
    const { repos } = fakeRepos({ failReset: true })
    expect(await writeRequestFiles({ repos, skillsDir }, args())).toEqual({
      message: REASON_INPUT_FAILED,
      ok: false,
    })
    const missing = await writeRequestFiles(
      { repos: fakeRepos().repos, skillsDir: join(base, 'no-skills') },
      args(),
    )
    expect(missing).toEqual({ message: REASON_INPUT_FAILED, ok: false })
  })
})
