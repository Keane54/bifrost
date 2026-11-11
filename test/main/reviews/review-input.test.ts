import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { FetchedPr, RepoStore } from '../../../src/main/reviews/repo-store'
import {
  INPUT_VERSION,
  MAX_DIFF_BYTES,
  MAX_PR_BODY,
  reviewKind,
  writeRoundFiles,
} from '../../../src/main/reviews/review-input'
import type {
  ReviewContext,
  ViewerReview,
  ViewerThread,
} from '../../../src/main/reviews/review-query'
import { REASON_TOO_LARGE } from '../../../src/main/reviews/round-text'

let base: string
let skillsDir: string

beforeAll(async () => {
  base = await mkdtemp(join(tmpdir(), 'bifrost-review-input-'))
  skillsDir = join(base, 'skills-src')
  await mkdir(join(skillsDir, 'skills/bifrost-review'), { recursive: true })
  await mkdir(join(skillsDir, 'skills/bifrost-humanise'), { recursive: true })
  await writeFile(join(skillsDir, 'skills/bifrost-review/bifrost-mode.md'), 'MODE TEXT\n')
  await writeFile(join(skillsDir, 'skills/bifrost-humanise/rules.md'), 'HUMANISE TEXT\n')
})

afterAll(async () => {
  await rm(base, { force: true, recursive: true })
})

const SMALL_DIFF = [
  'diff --git a/src/a.ts b/src/a.ts',
  '--- a/src/a.ts',
  '+++ b/src/a.ts',
  '@@ -1 +1,2 @@',
  ' one',
  '+two',
  '',
].join('\n')
const SINCE_DIFF = SMALL_DIFF.replaceAll('src/a.ts', 'src/b.ts')

interface FakeOpts {
  full?: string
  since?: string
}

// A fake store. writeDiff writes fixed text with the mode 0644 that git diff --output gives.
function fakeRepos(opts: FakeOpts = {}): { repos: RepoStore; modes: string[] } {
  const modes: string[] = []
  const repos = {
    async resetIo(_clone: string, number: number): Promise<string> {
      const io = join(base, `io-${Math.random().toString(36).slice(2)}-${number}`)
      await mkdir(io, { mode: 0o700, recursive: true })
      return io
    },
    async writeDiff(
      _clone: string,
      _from: string,
      _to: string,
      file: string,
      mode: 'merge-base' | 'direct',
    ): Promise<void> {
      modes.push(mode)
      await writeFile(
        file,
        mode === 'merge-base' ? (opts.full ?? SMALL_DIFF) : (opts.since ?? SINCE_DIFF),
        {
          mode: 0o644,
        },
      )
    },
  } as unknown as RepoStore
  return { modes, repos }
}

const fetched: FetchedPr = { base: 'b'.repeat(40), head: 'h'.repeat(40), mergeBase: 'm'.repeat(40) }

const review = (extra: Partial<ViewerReview> = {}): ViewerReview => ({
  body: 'Looks fine.',
  commit: 'c'.repeat(40),
  replyOnly: false,
  state: 'COMMENTED',
  submittedAt: Date.UTC(2026, 10, 1),
  url: 'https://github.com/o/r/pull/7#pullrequestreview-1',
  ...extra,
})

const thread: ViewerThread = {
  comments: [{ author: 'me', body: 'Check this.' }],
  isOutdated: false,
  isResolved: false,
  line: 4,
  path: 'src/a.ts',
  url: 'https://github.com/o/r/pull/7#discussion_r1',
}

const context = (extra: Partial<ReviewContext> = {}): ReviewContext => ({
  author: 'someone',
  baseRef: 'main',
  baseSha: 'b'.repeat(40),
  body: 'Body text',
  headRef: 'feature',
  headSha: 'h'.repeat(40),
  number: 7,
  owner: 'o',
  pending: null,
  repo: 'r',
  reviews: [],
  state: 'OPEN',
  threads: [],
  title: 'A title',
  truncated: false,
  url: 'https://github.com/o/r/pull/7',
  ...extra,
})

const args = (ctx: ReviewContext) => ({
  clone: join(base, 'clone'),
  context: ctx,
  fetched,
  number: 7,
  viewer: 'me',
})

describe('reviewKind', () => {
  const head = 'h'.repeat(40)
  it('no last review gives first', () => {
    expect(reviewKind(null, head, true, true)).toEqual({ kind: 'first', note: null, since: null })
  })
  it('a last review with a null commit gives first with rewritten', () => {
    expect(reviewKind(review({ commit: null }), head, true, true)).toEqual({
      kind: 'first',
      note: 'rewritten',
      since: null,
    })
  })
  it('a last commit equal to the head gives first with unchanged', () => {
    expect(reviewKind(review({ commit: head }), head, true, true)).toEqual({
      kind: 'first',
      note: 'unchanged',
      since: null,
    })
  })
  it('a commit that the clone does not have gives first with rewritten', () => {
    expect(reviewKind(review(), head, false, false).note).toBe('rewritten')
  })
  it('a commit that is not an ancestor gives first with rewritten', () => {
    expect(reviewKind(review(), head, true, false)).toEqual({
      kind: 'first',
      note: 'rewritten',
      since: null,
    })
  })
  it('an ancestor commit gives re-review with since', () => {
    expect(reviewKind(review(), head, true, true)).toEqual({
      kind: 're-review',
      note: null,
      since: 'c'.repeat(40),
    })
  })
})

describe('writeRoundFiles', () => {
  it('writes input.json, the diffs and the two rule files with mode 0600', async () => {
    const { repos } = fakeRepos()
    const ctx = context({ reviews: [review({ commit: 'c'.repeat(40) })], threads: [thread] })
    const known = {
      ...repos,
      hasCommit: async () => true,
      isAncestor: async () => true,
    } as unknown as RepoStore
    const out = await writeRoundFiles({ repos: known, skillsDir }, args(ctx))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(out.input.version).toBe(INPUT_VERSION)
    expect(out.input.review.kind).toBe('re-review')
    expect(out.input.review.lastReview?.submittedAt).toBe('2026-11-01T00:00:00.000Z')
    expect(out.input.changedFiles).toEqual(['src/a.ts'])
    expect(out.files.map(f => f.path)).toEqual(['src/a.ts'])
    const f = out.input.files
    for (const p of [f.fullDiff, f.sinceDiff ?? '', f.result, f.mode, f.rules, out.inputFile]) {
      expect(isAbsolute(p)).toBe(true)
    }
    for (const p of [f.fullDiff, f.sinceDiff ?? '', f.mode, f.rules, out.inputFile]) {
      expect((await stat(p)).mode & 0o777).toBe(0o600)
    }
    expect(await readFile(f.mode, 'utf8')).toBe('MODE TEXT\n')
    expect(await readFile(f.rules, 'utf8')).toBe('HUMANISE TEXT\n')
    expect(await readFile(f.fullDiff, 'utf8')).toBe(SMALL_DIFF)
    expect(JSON.parse(await readFile(out.inputFile, 'utf8'))).toEqual(out.input)
  })

  it('a first review has no since diff and empty earlier lists', async () => {
    const { repos } = fakeRepos()
    const ctx = context({ reviews: [], threads: [thread] })
    const out = await writeRoundFiles({ repos, skillsDir }, args(ctx))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(out.input.files.sinceDiff).toBeNull()
    expect(out.input.earlier).toEqual({ summaries: [], threads: [] })
  })

  it('a full diff over MAX_DIFF_BYTES fails with REASON_TOO_LARGE', async () => {
    const { repos } = fakeRepos({ full: 'x'.repeat(MAX_DIFF_BYTES + 1) })
    const out = await writeRoundFiles({ repos, skillsDir }, args(context()))
    expect(out).toEqual({ message: REASON_TOO_LARGE, ok: false })
  })

  it('cuts a PR body over MAX_PR_BODY', async () => {
    const { repos } = fakeRepos()
    const out = await writeRoundFiles(
      { repos, skillsDir },
      args(context({ body: 'y'.repeat(MAX_PR_BODY + 500) })),
    )
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(out.input.pr.body.length).toBe(MAX_PR_BODY)
  })

  it('a re-review input holds the earlier threads and summaries', async () => {
    const { repos, modes } = fakeRepos()
    const known = {
      ...repos,
      hasCommit: async () => true,
      isAncestor: async () => true,
    } as unknown as RepoStore
    const ctx = context({
      reviews: [
        review({ body: 'First pass.', state: 'CHANGES_REQUESTED' }),
        review({ body: '', state: 'COMMENTED', url: 'u2' }),
      ],
      threads: [thread],
    })
    const out = await writeRoundFiles({ repos: known, skillsDir }, args(ctx))
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(modes).toEqual(['merge-base', 'direct'])
    expect(out.input.earlier.threads).toEqual([thread])
    expect(out.input.earlier.summaries).toEqual([
      { body: 'First pass.', state: 'CHANGES_REQUESTED', url: review().url },
    ])
  })
})
