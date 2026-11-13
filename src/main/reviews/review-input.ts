// The input files of one review round. The session reads only this folder, so the folder holds
// the diffs, the rules, and the input file. Each file has mode 0600.

import { chmod, copyFile, readFile, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { prKey } from '../../shared/reviews'
import { type DiffFile, parseDiff } from './diff-lines'
import type { FetchedPr, RepoStore } from './repo-store'
import {
  isRealReview,
  lastSubmittedReview,
  type ReviewContext,
  type ViewerReview,
  type ViewerThread,
} from './review-query'
import { REASON_TOO_LARGE } from './round-text'

export const INPUT_VERSION = 1
export const MAX_DIFF_BYTES = 3 * 1024 * 1024
export const MAX_PR_BODY = 20_000
// Limits of the earlier threads and summaries, so that a long history stays small.
export const MAX_EARLIER_THREADS = 100
export const MAX_EARLIER_SUMMARIES = 20
export const MAX_EARLIER_TEXT = 4_000
export const CUT_MARKER = '\n[Bifrost cut this text.]'
export const REASON_INPUT_FAILED =
  "Bifrost couldn't write the files for the review session. Try again."

// Cut a text to max characters. Keep a surrogate pair whole. Add a marker when it is cut.
export function cutText(text: string, max: number): string {
  if (text.length <= max) return text
  let end = max
  const code = text.charCodeAt(end - 1)
  if (code >= 0xd800 && code <= 0xdbff) end -= 1
  return `${text.slice(0, end)}${CUT_MARKER}`
}

// Copy the mode file and the humanise rules into the input folder as mode.md and
// humanise-rules.md, with mode 0600. modeSource is the path of the mode file in skillsDir.
export async function copyRuleFiles(
  skillsDir: string,
  io: string,
  modeSource: string,
): Promise<{ mode: string; rules: string }> {
  const mode = join(io, 'mode.md')
  const rules = join(io, 'humanise-rules.md')
  await copyFile(join(skillsDir, modeSource), mode)
  await copyFile(join(skillsDir, 'skills/bifrost-humanise/rules.md'), rules)
  await chmod(mode, 0o600)
  await chmod(rules, 0o600)
  return { mode, rules }
}

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
    lastReview: {
      commit: string | null
      state: string
      submittedAt: string | null
      url: string
    } | null
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
  // A failed step gives a fixed reason. The reason has no path and no error text.
  try {
    return await build(deps, args)
  } catch {
    return { message: REASON_INPUT_FAILED, ok: false }
  }
}

async function build(
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
    if ((await stat(sinceDiff)).size > MAX_DIFF_BYTES) {
      return { message: REASON_TOO_LARGE, ok: false }
    }
  }

  const { mode, rules } = await copyRuleFiles(
    skillsDir,
    io,
    'skills/bifrost-review/bifrost-mode.md',
  )

  const files = parseDiff(await readFile(fullDiff, 'utf8'))
  // A rewritten history gets the full diff, but the session must still check the earlier
  // threads and summaries.
  const withEarlier = kind.kind === 're-review' || kind.note === 'rewritten'
  const input: ReviewInput = {
    changedFiles: files.map(f => f.path),
    earlier: {
      summaries: withEarlier
        ? context.reviews
            .filter(r => isRealReview(r) && r.body.trim() !== '')
            .slice(-MAX_EARLIER_SUMMARIES)
            .map(r => ({ body: cutText(r.body, MAX_EARLIER_TEXT), state: r.state, url: r.url }))
        : [],
      threads: withEarlier
        ? context.threads.slice(0, MAX_EARLIER_THREADS).map(t => ({
            ...t,
            comments: t.comments.map(c => ({ ...c, body: cutText(c.body, MAX_EARLIER_TEXT) })),
          }))
        : [],
    },
    files: { fullDiff, mode, result: join(io, 'result.json'), rules, sinceDiff },
    pr: {
      author: context.author,
      baseRef: context.baseRef,
      baseSha: fetched.base,
      body: cutText(context.body, MAX_PR_BODY),
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
            submittedAt:
              last.submittedAt === null ? null : new Date(last.submittedAt).toISOString(),
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
