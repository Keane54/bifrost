// The result file of a request round. The session writes it after it read the comments of the
// PR, so Bifrost trusts none of it. The check is strict: one failed rule refuses the whole file,
// and Bifrost then commits nothing and posts nothing. A reason names a known field or a limit
// only. It never holds text from the file, because Bifrost shows and logs the reason.

import { isRecord as isObject } from '../../shared/plain-object'
import { OBJECT_ID } from './repo-store'
import { CONTROL, count } from './result-file'
import { MAX_QUESTION } from './state'

export const REQUEST_RESULT_VERSION = 1
// The longest reply, first line of the commit message and commit message, in characters.
export const MAX_REPLY = 4_000
export const MAX_SUBJECT = 100
export const MAX_MESSAGE = 4_000
// The most paths in the commit.
export const MAX_PATHS = 200

export type ChecksState = 'passed' | 'failed' | 'blocked' | 'none'

// A fixed item with `by` names an earlier commit of the PR that did the fix. A fixed item with no
// `by` is fixed by the commit of the round.
export type ItemResult =
  | { id: string; outcome: 'fixed'; by?: string }
  | { id: string; outcome: 'no-fix'; reply: string }
  | { id: string; outcome: 'no-action' }
  | { id: string; outcome: 'needs-you'; question: string }

export interface RequestResult {
  version: 1
  pr: string
  headSha: string
  items: ItemResult[]
  commit: { message: string; paths: string[] } | null
  checks: ChecksState
}

type Outcome = ItemResult['outcome']
type Commit = NonNullable<RequestResult['commit']>
type Parsed = { ok: true; result: RequestResult } | { ok: false; reason: string }
type Checked<T> = { ok: true; value: T } | { ok: false; reason: string }

const RESULT_KEYS = ['version', 'pr', 'headSha', 'items', 'commit', 'checks']
const ITEM_KEYS = ['id', 'outcome', 'by', 'reply', 'question']
const COMMIT_KEYS = ['message', 'paths']
const OUTCOMES: readonly Outcome[] = ['fixed', 'no-fix', 'no-action', 'needs-you']
const CHECKS: readonly ChecksState[] = ['passed', 'failed', 'blocked', 'none']
// The field that each outcome has, together with id and outcome.
const OUTCOME_FIELD: Record<Outcome, string | null> = {
  fixed: 'by',
  'needs-you': 'question',
  'no-action': null,
  'no-fix': 'reply',
}
const UNKNOWN_FIELD = 'an unknown field'
// A text that tells GitHub not to run CI or checks for a commit. The session cannot install
// packages, so CI must run on the pushed fix.
const SKIP_CI =
  /\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]|skip-checks\s*:\s*true/i

const fail = (reason: string): { ok: false; reason: string } => ({ ok: false, reason })
const blank = (text: string): boolean => text.trim() === ''

// True when the text has a control character other than a new line, and other than a tab when
// tabs is true.
function hasControl(text: string, tabs: boolean): boolean {
  return CONTROL.test(text.replace(tabs ? /[\n\t]/g : /\n/g, ''))
}

// A reply or a question. `what` names the field and the item, for example "the reply of item 2".
function checkText(value: unknown, what: string, max: number): Checked<string> {
  if (typeof value !== 'string') return fail(`${what} is not text`)
  if (blank(value)) return fail(`${what} is empty`)
  if (value.length > max) return fail(`${what} is longer than ${count(max)} characters`)
  if (hasControl(value, true)) return fail(`${what} has a control character`)
  return { ok: true, value }
}

function checkItem(
  value: unknown,
  n: number,
  expected: ReadonlySet<string>,
  seen: ReadonlySet<string>,
): Checked<ItemResult> {
  if (!isObject(value)) return fail(`item ${n} is not a JSON object`)
  const keys = Object.keys(value)
  if (keys.some(key => !ITEM_KEYS.includes(key))) return fail(UNKNOWN_FIELD)
  if (!Object.hasOwn(value, 'id')) return fail(`item ${n} has no id field`)
  if (!Object.hasOwn(value, 'outcome')) return fail(`item ${n} has no outcome field`)
  const { id, outcome } = value
  if (typeof id !== 'string' || !expected.has(id)) return fail('an item that is not in the input')
  if (seen.has(id)) return fail('a second result for one item')
  const kind = OUTCOMES.find(o => o === outcome)
  if (kind === undefined) {
    return fail(`the outcome of item ${n} is not fixed, no-fix, no-action or needs-you`)
  }
  const field = OUTCOME_FIELD[kind]
  // The key is one of ITEM_KEYS here, so the reason holds no text from the file.
  const other = keys.find(key => key !== 'id' && key !== 'outcome' && key !== field)
  if (other !== undefined) {
    return fail(`item ${n} has a ${other} field, which a ${kind} item does not have`)
  }

  if (kind === 'no-action') return { ok: true, value: { id, outcome: kind } }
  if (kind === 'fixed') {
    if (!Object.hasOwn(value, 'by')) return { ok: true, value: { id, outcome: kind } }
    const { by } = value
    if (typeof by !== 'string' || !OBJECT_ID.test(by)) {
      return fail(`the by field of item ${n} is not a full commit ID`)
    }
    return { ok: true, value: { by, id, outcome: kind } }
  }
  if (kind === 'no-fix') {
    if (!Object.hasOwn(value, 'reply')) return fail(`item ${n} has no reply field`)
    const reply = checkText(value.reply, `the reply of item ${n}`, MAX_REPLY)
    if (!reply.ok) return reply
    return { ok: true, value: { id, outcome: kind, reply: reply.value } }
  }
  if (!Object.hasOwn(value, 'question')) return fail(`item ${n} has no question field`)
  const question = checkText(value.question, `the question of item ${n}`, MAX_QUESTION)
  if (!question.ok) return question
  return { ok: true, value: { id, outcome: kind, question: question.value } }
}

// The first problem of one path of the commit, or null. Bifrost commits only the paths that
// changed in the worktree. A path is relative to the worktree, with "/" between its parts.
function pathProblem(
  path: unknown,
  n: number,
  changed: ReadonlySet<string>,
  seen: ReadonlySet<string>,
): string | null {
  if (typeof path !== 'string') return `path ${n} of the commit is not text`
  const parts = path.split('/')
  if (path.includes('\\') || parts.some(part => part === '' || part === '.' || part === '..')) {
    return `path ${n} of the commit is not a clean relative path`
  }
  // A file system that ignores case finds the .git folder also with another case.
  if (parts.some(part => part.toLowerCase() === '.git')) {
    return `path ${n} of the commit is in a .git folder`
  }
  if (!changed.has(path)) return `path ${n} of the commit did not change`
  if (seen.has(path)) return `path ${n} of the commit shows more than one time`
  return null
}

function checkCommit(value: unknown, changed: ReadonlySet<string>): Checked<Commit | null> {
  if (value === null) return { ok: true, value: null }
  if (!isObject(value)) return fail('the commit field is not null or a JSON object')
  if (Object.keys(value).some(key => !COMMIT_KEYS.includes(key))) return fail(UNKNOWN_FIELD)
  const absent = COMMIT_KEYS.find(key => !Object.hasOwn(value, key))
  if (absent !== undefined) return fail(`the commit has no ${absent} field`)

  const { message, paths } = value
  if (typeof message !== 'string') return fail('the commit message is not text')
  const subject = message.split('\n', 1)[0] ?? ''
  if (blank(subject)) return fail('the first line of the commit message is empty')
  if (subject.length > MAX_SUBJECT) {
    return fail(
      `the first line of the commit message is longer than ${count(MAX_SUBJECT)} characters`,
    )
  }
  if (message.length > MAX_MESSAGE) {
    return fail(`the commit message is longer than ${count(MAX_MESSAGE)} characters`)
  }
  if (hasControl(message, false)) return fail('the commit message has a control character')
  if (SKIP_CI.test(message)) return fail('the commit message asks to skip CI')

  if (!Array.isArray(paths)) return fail('the paths field of the commit is not a list')
  if (paths.length === 0) return fail('the commit has no paths')
  if (paths.length > MAX_PATHS) return fail(`the commit has more than ${count(MAX_PATHS)} paths`)
  const seen = new Set<string>()
  for (const [index, path] of paths.entries()) {
    const problem = pathProblem(path, index + 1, changed, seen)
    if (problem !== null) return fail(problem)
    seen.add(path as string)
  }
  return { ok: true, value: { message, paths: [...seen] } }
}

// Check the text of a result file. `items` holds the item IDs of the round, and `changed` the
// paths that changed in the worktree. The result holds only the known fields, so nothing else
// from the file goes further.
export function parseRequestResult(
  text: string,
  expect: {
    pr: string
    headSha: string
    items: readonly string[]
    changed: ReadonlySet<string>
  },
): Parsed {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    // The error text of JSON.parse can hold a part of the file.
    return fail('the result is not valid JSON')
  }
  if (!isObject(data)) return fail('the result is not a JSON object')
  if (Object.keys(data).some(key => !RESULT_KEYS.includes(key))) return fail(UNKNOWN_FIELD)
  const absent = RESULT_KEYS.find(key => !Object.hasOwn(data, key))
  if (absent !== undefined) return fail(`the ${absent} field is missing`)

  const { version, pr, headSha, items, commit, checks } = data
  if (version !== REQUEST_RESULT_VERSION) return fail('the version field is not 1')
  if (pr !== expect.pr) return fail('the pr field is not this pull request')
  if (headSha !== expect.headSha) {
    return fail('the headSha field is not the head commit of the round')
  }

  if (!Array.isArray(items)) return fail('the items field is not a list')
  const expected = new Set(expect.items)
  const seen = new Set<string>()
  const results: ItemResult[] = []
  for (const [index, value] of items.entries()) {
    const item = checkItem(value, index + 1, expected, seen)
    if (!item.ok) return item
    seen.add(item.value.id)
    results.push(item.value)
  }
  // Each ID in seen is in expected, so a smaller set means a missing item.
  if (seen.size < expected.size) return fail('a missing item')

  const fix = checkCommit(commit, expect.changed)
  if (!fix.ok) return fix
  const state = CHECKS.find(c => c === checks)
  if (state === undefined) return fail('the checks field is not passed, failed, blocked or none')

  // Only a Fixed item with no by needs the commit of the round.
  const needsCommit = results.some(item => item.outcome === 'fixed' && item.by === undefined)
  if (needsCommit && fix.value === null) return fail('a Fixed item has no commit')
  if (!needsCommit && fix.value !== null) return fail('a commit with no Fixed item')
  if (state === 'failed' && fix.value !== null) return fail('a commit with failed checks')

  return {
    ok: true,
    result: {
      checks: state,
      commit: fix.value,
      headSha: expect.headSha,
      items: results,
      pr: expect.pr,
      version: REQUEST_RESULT_VERSION,
    },
  }
}
