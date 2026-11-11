// The result file of a review round. The review session writes it after it read text from the
// PR, so Bifrost trusts none of it. The check is strict: one failed rule refuses the whole file,
// and Bifrost then posts nothing. A reason names a known field or a limit only. It never holds
// text from the file, because Bifrost shows and logs the reason.

import { constants } from 'node:fs'
import { lstat, open } from 'node:fs/promises'
import { RECOMMENDATION_TEXT, RECOMMENDATIONS, type Recommendation } from '../../shared/reviews'
import { type DiffFile, lineInDiff } from './diff-lines'

export const RESULT_VERSION = 1
export const MAX_RESULT_BYTES = 1024 * 1024
export const MAX_COMMENTS = 50
export const MAX_COMMENT_BODY = 10_000
export const MAX_SUMMARY = 20_000
export const MAX_WHY = 300

export type Side = 'LEFT' | 'RIGHT'

export interface ResultComment {
  path: string
  line: number
  side: Side
  startLine?: number
  startSide?: Side
  body: string
}

export interface ReviewResult {
  version: 1
  pr: string
  headSha: string
  recommendation: Recommendation
  why: string
  summary: string
  comments: ResultComment[]
}

type ReadResult = { ok: true; text: string } | { ok: false; reason: ReadReason }
type ReadReason = 'missing' | 'not a regular file' | 'too large'

// Read the file with a size limit. A link, a folder or another special file is not a regular
// file. The function never rejects, and it gives no error text.
export async function readResultFile(file: string): Promise<ReadResult> {
  try {
    const info = await lstat(file)
    if (!info.isFile()) return { ok: false, reason: 'not a regular file' }
    if (info.size > MAX_RESULT_BYTES) return { ok: false, reason: 'too large' }
  } catch {
    return { ok: false, reason: 'missing' }
  }
  // The path can change after the lstat. O_NOFOLLOW refuses a link, O_NONBLOCK does not wait on
  // a pipe, and the checks on the open file see the real file.
  let handle: Awaited<ReturnType<typeof open>>
  try {
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    return { ok: false, reason: code === 'ENOENT' ? 'missing' : 'not a regular file' }
  }
  try {
    const info = await handle.stat()
    if (!info.isFile()) return { ok: false, reason: 'not a regular file' }
    // Read one byte more than the limit, so that a file that grew shows as too large.
    const buffer = Buffer.alloc(MAX_RESULT_BYTES + 1)
    let length = 0
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length)
      if (bytesRead === 0) break
      length += bytesRead
    }
    if (length > MAX_RESULT_BYTES) return { ok: false, reason: 'too large' }
    return { ok: true, text: buffer.toString('utf8', 0, length) }
  } catch {
    return { ok: false, reason: 'missing' }
  } finally {
    await handle.close().catch(() => undefined)
  }
}

const RESULT_KEYS = ['version', 'pr', 'headSha', 'recommendation', 'why', 'summary', 'comments']
const COMMENT_KEYS = ['path', 'line', 'side', 'startLine', 'startSide', 'body']
const COMMENT_NEEDS = ['path', 'line', 'side', 'body']
const SIDES: readonly string[] = ['LEFT', 'RIGHT']
const UNKNOWN_FIELD = 'an unknown field'

type Parsed = { ok: true; result: ReviewResult } | { ok: false; reason: string }
type Checked<T> = { ok: true; value: T } | { ok: false; reason: string }

const fail = (reason: string): { ok: false; reason: string } => ({ ok: false, reason })
const count = (n: number): string => n.toLocaleString('en-GB')
const blank = (text: string): boolean => text.trim() === ''

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// The first problem with the keys of an object: an unknown key, then a missing key.
function keyProblem(
  value: Record<string, unknown>,
  allowed: readonly string[],
  needed: readonly string[],
  missing: (key: string) => string,
): string | null {
  if (Object.keys(value).some(key => !allowed.includes(key))) return UNKNOWN_FIELD
  const absent = needed.find(key => !Object.hasOwn(value, key))
  return absent === undefined ? null : missing(absent)
}

const isLineNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 1

function checkComment(
  value: unknown,
  n: number,
  files: readonly DiffFile[],
): Checked<ResultComment> {
  if (!isObject(value)) return fail(`comment ${n} is not a JSON object`)
  const keys = keyProblem(value, COMMENT_KEYS, COMMENT_NEEDS, k => `comment ${n} has no ${k} field`)
  if (keys !== null) return fail(keys)
  const { path, line, side, body } = value
  const file = files.find(f => f.path === path)
  if (typeof path !== 'string' || file === undefined) {
    return fail(`comment ${n} is on a file that is not in the diff`)
  }
  if (file.binary) return fail(`comment ${n} is on a binary file`)
  if (!isLineNumber(line)) {
    return fail(`the line of comment ${n} is not a whole number of 1 or more`)
  }
  if (typeof side !== 'string' || !SIDES.includes(side)) {
    return fail(`the side of comment ${n} is not LEFT or RIGHT`)
  }
  const comment: ResultComment = { body: '', line, path, side: side as Side }
  if (Object.hasOwn(value, 'startLine')) {
    const { startLine } = value
    if (!isLineNumber(startLine)) {
      return fail(`the startLine of comment ${n} is not a whole number of 1 or more`)
    }
    if (startLine >= line) return fail(`the startLine of comment ${n} is not below its line`)
    comment.startLine = startLine
    if (Object.hasOwn(value, 'startSide')) {
      if (value.startSide !== side) return fail(`the startSide of comment ${n} is not its side`)
      comment.startSide = side as Side
    }
  } else if (Object.hasOwn(value, 'startSide')) {
    return fail(`comment ${n} has a startSide with no startLine`)
  }
  if (typeof body !== 'string') return fail(`the body of comment ${n} is not text`)
  if (blank(body)) return fail(`the body of comment ${n} is empty`)
  if (body.length > MAX_COMMENT_BODY) {
    return fail(`the body of comment ${n} is longer than ${count(MAX_COMMENT_BODY)} characters`)
  }
  comment.body = body
  return { ok: true, value: comment }
}

// Check the text of a result file. The result holds only the known fields, so nothing else from
// the file goes further. A summary with only white space becomes empty.
export function parseReviewResult(
  text: string,
  expect: { pr: string; headSha: string; files: readonly DiffFile[] },
): Parsed {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    // The error text of JSON.parse can hold a part of the file.
    return fail('the result is not valid JSON')
  }
  if (!isObject(data)) return fail('the result is not a JSON object')
  const keys = keyProblem(data, RESULT_KEYS, RESULT_KEYS, k => `the ${k} field is missing`)
  if (keys !== null) return fail(keys)

  const { version, pr, headSha, recommendation, why, summary, comments } = data
  if (version !== RESULT_VERSION) return fail('the version field is not 1')
  if (pr !== expect.pr) return fail('the pr field is not this pull request')
  if (headSha !== expect.headSha) return fail('the headSha field is not the reviewed commit')
  const value = RECOMMENDATIONS.find(r => r === recommendation)
  if (value === undefined) {
    return fail('the recommendation field is not approve, comment or request-changes')
  }
  if (typeof why !== 'string') return fail('the why field is not text')
  if (blank(why)) return fail('the why field is empty')
  if (why.length > MAX_WHY) return fail(`the why field is longer than ${count(MAX_WHY)} characters`)
  if (typeof summary !== 'string') return fail('the summary field is not text')
  if (summary.length > MAX_SUMMARY) {
    return fail(`the summary field is longer than ${count(MAX_SUMMARY)} characters`)
  }
  if (!Array.isArray(comments)) return fail('the comments field is not a list')
  if (comments.length > MAX_COMMENTS) {
    return fail(`the comments field has more than ${count(MAX_COMMENTS)} comments`)
  }
  const checked: ResultComment[] = []
  for (const [index, item] of comments.entries()) {
    const comment = checkComment(item, index + 1, expect.files)
    if (!comment.ok) return comment
    checked.push(comment.value)
  }

  const cleanSummary = blank(summary) ? '' : summary
  if (value === 'approve' && checked.length > 0) {
    return fail('an Approve recommendation has line comments')
  }
  if (value !== 'approve' && cleanSummary === '' && checked.length === 0) {
    return fail(`a ${RECOMMENDATION_TEXT[value]} recommendation has no text`)
  }
  return {
    ok: true,
    result: {
      comments: checked,
      headSha: expect.headSha,
      pr: expect.pr,
      recommendation: value,
      summary: cleanSummary,
      version: RESULT_VERSION,
      why,
    },
  }
}

// GitHub refuses the whole review when one comment is on a line outside the diff. So a comment
// outside the hunks moves into the summary, with its path and line. The summary of the session
// stays first.
export function placeComments(
  result: ReviewResult,
  files: readonly DiffFile[],
): { summary: string; comments: ResultComment[]; moved: number } {
  const kept: ResultComment[] = []
  const parts = blank(result.summary) ? [] : [result.summary]
  for (const c of result.comments) {
    if (lineInDiff(files, c.path, c.side, c.line, c.startLine, c.startSide)) kept.push(c)
    else parts.push(`\`${c.path}\` line ${c.line}: ${c.body}`)
  }
  return {
    comments: kept,
    moved: result.comments.length - kept.length,
    summary: parts.join('\n\n'),
  }
}
