// The input files of one request round. The session reads only this folder: the input file, the
// rules and the full diff of the PR. Each file has mode 0600.

import { chmod, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { prKey } from '../../shared/reviews'
import { isCopilot, isTrustedHuman, type WorkItem } from './model'
import type { PrComment } from './pr-data'
import type { FetchedPr, RepoStore } from './repo-store'
import type { RequestContext } from './request-query'
import {
  copyRuleFiles,
  cutText,
  MAX_DIFF_BYTES,
  MAX_PR_BODY,
  REASON_INPUT_FAILED,
} from './review-input'
import type { Question } from './state'

export const REQUEST_INPUT_VERSION = 1
// The longest comment body and diff hunk in the input, in characters.
export const MAX_ITEM_TEXT = 10_000
export const MAX_HUNK = 3_000
export const REQUEST_MODE = 'skills/bifrost-resolve-comments/bifrost-mode.md'

export interface RequestInputItem {
  id: string
  kind: 'thread' | 'comment' | 'review-body'
  path: string | null
  line: number | null
  outdated: boolean
  diffHunk: string | null
  // The thread, or the one comment or review body. The viewer's own comments have you: true.
  // trusted is the trust rule of the work rule, so the skill needs no trust rule of its own.
  comments: {
    author: string
    association: string
    trusted: boolean
    you: boolean
    body: string
    at: string
  }[]
  question: string | null
  answer: string | null
}

export interface RequestInput {
  version: 1
  pr: {
    key: string
    url: string
    title: string
    body: string
    baseRef: string
    headRef: string
    baseSha: string
    headSha: string
    mergeBase: string
  }
  viewer: string
  items: RequestInputItem[]
  files: { result: string; mode: string; rules: string; fullDiff: string | null }
}

type Done = { ok: true; input: RequestInput; inputFile: string }
type Failed = { ok: false; message: string }

interface WriteArgs {
  clone: string
  number: number
  context: RequestContext
  viewer: string
  fetched: FetchedPr
  items: readonly WorkItem[]
  questions: Readonly<Record<string, Question>>
}

export async function writeRequestFiles(
  deps: { repos: RepoStore; skillsDir: string },
  args: WriteArgs,
): Promise<Done | Failed> {
  // A failed step gives a fixed reason. The reason has no path and no error text.
  try {
    return await build(deps, args)
  } catch {
    return { message: REASON_INPUT_FAILED, ok: false }
  }
}

type InputComment = RequestInputItem['comments'][number]

function inputComment(
  author: PrComment['author'],
  body: string,
  time: number,
  viewer: string,
): InputComment {
  // GitHub ignores case in a login.
  const you = author.login.toLowerCase() === viewer.toLowerCase()
  return {
    association: author.association,
    at: new Date(time).toISOString(),
    author: author.login,
    body: cutText(body, MAX_ITEM_TEXT),
    // A comment of the viewer is never trusted, also when its login has another case.
    trusted: !you && (isTrustedHuman(author, viewer) || isCopilot(author)),
    you,
  }
}

// The item of the input, or null when the context does not have it.
function inputItem(
  item: WorkItem,
  context: RequestContext,
  viewer: string,
  question: Question | undefined,
): RequestInputItem | null {
  const asked = {
    answer: question?.answer ?? null,
    question: question?.question ?? null,
  }
  const flat = { diffHunk: null, line: null, outdated: false, path: null }
  if (item.kind === 'thread') {
    const thread = context.threads.find(t => t.id === item.id)
    if (thread === undefined) return null
    return {
      ...asked,
      comments: thread.comments.map(c => inputComment(c.author, c.body, c.createdAt, viewer)),
      diffHunk: thread.diffHunk === '' ? null : cutText(thread.diffHunk, MAX_HUNK),
      id: item.id,
      kind: item.kind,
      line: thread.line,
      outdated: thread.isOutdated,
      path: thread.path,
    }
  }
  if (item.kind === 'comment') {
    const comment = context.comments.find(c => c.id === item.id)
    if (comment === undefined) return null
    const one = inputComment(comment.author, comment.body, comment.createdAt, viewer)
    return { ...asked, ...flat, comments: [one], id: item.id, kind: item.kind }
  }
  const review = context.reviews.find(r => r.id === item.id)
  if (review === undefined) return null
  const one = inputComment(review.author, review.body, review.submittedAt ?? 0, viewer)
  return { ...asked, ...flat, comments: [one], id: item.id, kind: item.kind }
}

async function build(
  deps: { repos: RepoStore; skillsDir: string },
  args: WriteArgs,
): Promise<Done | Failed> {
  const { repos, skillsDir } = deps
  const { clone, number, context, viewer, fetched } = args

  const io = await repos.resetIo(clone, number)
  // A full diff over the limit goes. The session can still read the files and the hunks.
  let fullDiff: string | null = join(io, 'full.diff')
  await repos.writeDiff(clone, fetched.base, fetched.head, fullDiff, 'merge-base')
  await chmod(fullDiff, 0o600)
  if ((await stat(fullDiff)).size > MAX_DIFF_BYTES) {
    await rm(fullDiff, { force: true })
    fullDiff = null
  }

  const { mode, rules } = await copyRuleFiles(skillsDir, io, REQUEST_MODE)

  const items: RequestInputItem[] = []
  for (const item of args.items) {
    const question = Object.hasOwn(args.questions, item.id) ? args.questions[item.id] : undefined
    const read = inputItem(item, context, viewer, question)
    if (read !== null) items.push(read)
  }
  const input: RequestInput = {
    files: { fullDiff, mode, result: join(io, 'result.json'), rules },
    items,
    pr: {
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
    version: REQUEST_INPUT_VERSION,
    viewer,
  }
  const inputFile = join(io, 'input.json')
  await writeFile(inputFile, `${JSON.stringify(input, null, 2)}\n`, { mode: 0o600 })
  await chmod(inputFile, 0o600)
  return { input, inputFile, ok: true }
}
