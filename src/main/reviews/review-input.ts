// The input files of one review round. The session reads only this folder, so the folder holds
// the diffs, the rules, and the input file. Each file has mode 0600.

import { chmod, copyFile, readFile, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { prKey } from '../../shared/reviews'
import { type DiffFile, parseDiff } from './diff-lines'
import type { FetchedPr, RepoStore } from './repo-store'
import {
  lastSubmittedReview,
  type ReviewContext,
  type ViewerReview,
  type ViewerThread,
} from './review-query'
import { REASON_TOO_LARGE } from './round-text'

export const INPUT_VERSION = 1
export const MAX_DIFF_BYTES = 3 * 1024 * 1024
export const MAX_PR_BODY = 20_000

export interface ReviewInput {
  version: 1
  pr: {
    key: string
    url: string
    title: string
    body: string
    author: string
    baseRef: string
    headRef: string
    baseSha: string
    headSha: string
    mergeBase: string
  }
  viewer: string
  review: {
    kind: 'first' | 're-review'
    since: string | null
    note: 'unchanged' | 'rewritten' | null
    lastReview: { commit: string | null; state: string; submittedAt: string; url: string } | null
  }
  changedFiles: string[]
  earlier: { threads: ViewerThread[]; summaries: { state: string; body: string; url: string }[] }
  files: { fullDiff: string; sinceDiff: string | null; result: string; mode: string; rules: string }
}

type Kind = ReviewInput['review']['kind']
type Note = ReviewInput['review']['note']

export function reviewKind(
  last: ViewerReview | null,
  head: string,
  known: boolean,
  ancestor: boolean,
): { kind: Kind; since: string | null; note: Note } {
  if (last === null) return { kind: 'first', note: null, since: null }
  if (last.commit === null) return { kind: 'first', note: 'rewritten', since: null }
  if (last.commit === head) return { kind: 'first', note: 'unchanged', since: null }
  if (!known || !ancestor) return { kind: 'first', note: 'rewritten', since: null }
  return { kind: 're-review', note: null, since: last.commit }
}

type Done = { ok: true; input: ReviewInput; inputFile: string; files: DiffFile[] }
type Failed = { ok: false; message: string }

export async function writeRoundFiles(
  deps: { repos: RepoStore; skillsDir: string },
  args: {
    clone: string
    number: number
    context: ReviewContext
    viewer: string
    fetched: FetchedPr
  },
): Promise<Done | Failed> {
  const { repos, skillsDir } = deps
  const { clone, number, context, viewer, fetched } = args
  const last = lastSubmittedReview(context.reviews)
  const lastCommit = last?.commit ?? null
  const needsCheck = lastCommit !== null && lastCommit !== fetched.head
  const known = needsCheck ? await repos.hasCommit(clone, lastCommit) : false
  const ancestor =
    known && needsCheck ? await repos.isAncestor(clone, lastCommit, fetched.head) : false
  const kind = reviewKind(last, fetched.head, known, ancestor)

  const io = await repos.resetIo(clone, number)
  const fullDiff = join(io, 'full.diff')
  await repos.writeDiff(clone, fetched.base, fetched.head, fullDiff, 'merge-base')
  await chmod(fullDiff, 0o600)
  if ((await stat(fullDiff)).size > MAX_DIFF_BYTES) return { message: REASON_TOO_LARGE, ok: false }

  let sinceDiff: string | null = null
  if (kind.kind === 're-review' && kind.since !== null) {
    sinceDiff = join(io, 'since.diff')
    await repos.writeDiff(clone, kind.since, fetched.head, sinceDiff, 'direct')
    await chmod(sinceDiff, 0o600)
  }

  const mode = join(io, 'mode.md')
  const rules = join(io, 'humanise-rules.md')
  await copyFile(join(skillsDir, 'skills/bifrost-review/bifrost-mode.md'), mode)
  await copyFile(join(skillsDir, 'skills/bifrost-humanise/rules.md'), rules)
  await chmod(mode, 0o600)
  await chmod(rules, 0o600)

  const files = parseDiff(await readFile(fullDiff, 'utf8'))
  const rereview = kind.kind === 're-review'
  const input: ReviewInput = {
    changedFiles: files.map(f => f.path),
    earlier: {
      summaries: rereview
        ? context.reviews
            .filter(r => r.state !== 'PENDING' && !r.replyOnly && r.body.trim() !== '')
            .map(r => ({ body: r.body, state: r.state, url: r.url }))
        : [],
      threads: rereview ? context.threads : [],
    },
    files: { fullDiff, mode, result: join(io, 'result.json'), rules, sinceDiff },
    pr: {
      author: context.author,
      baseRef: context.baseRef,
      baseSha: fetched.base,
      body: context.body.slice(0, MAX_PR_BODY),
      headRef: context.headRef,
      headSha: fetched.head,
      key: prKey(context.owner, context.repo, context.number),
      mergeBase: fetched.mergeBase,
      title: context.title,
      url: context.url,
    },
    review: {
      kind: kind.kind,
      lastReview: last
        ? {
            commit: last.commit,
            state: last.state,
            submittedAt: new Date(last.submittedAt ?? 0).toISOString(),
            url: last.url,
          }
        : null,
      note: kind.note,
      since: kind.since,
    },
    version: INPUT_VERSION,
    viewer,
  }
  const inputFile = join(io, 'input.json')
  await writeFile(inputFile, `${JSON.stringify(input, null, 2)}\n`, { mode: 0o600 })
  await chmod(inputFile, 0o600)
  return { files, input, inputFile, ok: true }
}
