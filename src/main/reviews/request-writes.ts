// The GitHub writes of a request round: a reply to a thread, the resolve of a thread, a PR
// comment, a review request, and the signed fix commit when the user turned on signed commits.
// Each function runs one GraphQL call with one mutation field. For the first four writes, each
// value goes as a -f field, never in the query text and never as -F, because -F reads a file for
// a value that starts with @. The signed commit holds the files of the fix, so its request body
// goes to gh on stdin (gh api graphql --input -), never in the arguments.
// test/main/reviews/github-writes-source.test.ts guards these rules. request-posts.ts decides when
// each write runs. Only request-push.ts sends the signed commit.

import { isRecord } from '../../shared/plain-object'
import { REPO_KEY } from '../../shared/reviews'
import type { ExecResult } from '../claude/cli'
import { EXIT_AUTH, type Gh, ghFailure, MESSAGE_MAX } from './gh'
import { OBJECT_ID } from './repo-store'
import { asRec, asString, type Rec } from './review-query'
import {
  REASON_FILES_REFUSED,
  REASON_PUSH_TARGET,
  REASON_WRITE_FAILED,
  REASON_WRITE_TIMEOUT,
  REASON_WRITE_UNREADABLE,
} from './round-text'

// The longest part of a request that a PR comment quotes, in characters.
export const MAX_QUOTE = 300
// The most lines of a request that a PR comment quotes.
const QUOTE_LINES = 3

export const fixedBy = (sha: string): string => `Fixed by ${sha.slice(0, 7)}`

// The zero-width space that Bifrost puts after an @. GitHub then finds no login after the @,
// so it sends no notification. The space does not show.
export const ZWSP = '​'
// An HTML entity that makes an @. HTML also reads a number entity with no semicolon.
const AT_ENTITY = /&(?:#0*64|#[xX]0*40|commat);?/g
const ALNUM = /[A-Za-z0-9]/
// A tag or a comment of HTML. GitHub makes no link in an HTML block, so a text with HTML keeps
// no link as it is.
const HTML = /<[A-Za-z/!?]/
// A link that GitHub makes from a bare URL. GitHub sends no notification for an @ in a link. The
// pattern is stricter than the rule of GitHub. A text that it does not find gets a zero-width
// space, and that is safe. A link starts at the start of the text or after an ASCII space
// (http and https also after *, _, ~ or a bracket). The host has a dot, has no _ in its last two
// parts, and ends at /, ?, # or :. The path ends at a space, a bracket, a quote, a backtick or a
// backslash.
const LINK = new RegExp(
  String.raw`(?:(?<=^|[ \t\n\r*_~(])https?:\/\/|(?<=^|[ \t\n\r])www\.)` +
    String.raw`(?:[A-Za-z0-9_-]+\.)*[A-Za-z0-9-]+\.[A-Za-z0-9-]+[/?#:][^\s<>()[\]"'\x60\\]*`,
  'g',
)

// True when the @ at the index comes right after a word, as in an email address. GitHub starts
// no mention there. A word after & or &# can be the end of an entity, so it does not count.
function afterWord(text: string, at: number): boolean {
  let start = at
  while (start > 0 && ALNUM.test(text[start - 1] ?? '')) start--
  if (start === at) return false
  return text[start - 1] !== '&' && text.slice(Math.max(0, start - 2), start) !== '&#'
}

// Put a zero-width space after each @ that can start a mention, so GitHub sends no
// notification. An entity that makes an @ becomes an @ with the space. An @ in an email address,
// and an @ in a link that GitHub makes, stay as they are. A second pass changes nothing.
export function defuseMentions(text: string): string {
  const plain = text.replace(AT_ENTITY, `@${ZWSP}`)
  const links = HTML.test(plain)
    ? []
    : [...plain.matchAll(LINK)].map(m => ({ from: m.index, to: m.index + m[0].length }))
  // An @ before a space or at the end starts no mention.
  return plain.replace(/@(?=\S)/g, (at: string, index: number) => {
    if (plain[index + 1] === ZWSP || afterWord(plain, index)) return at
    if (links.some(link => index > link.from && index < link.to)) return at
    return `@${ZWSP}`
  })
}

// The quote of a request for a PR comment: the first 3 lines, cut at MAX_QUOTE, each with "> "
// before it. An empty request gives an empty quote.
export function quoteRequest(body: string): string {
  const lines = body.replace(/\r\n?/g, '\n').trim().split('\n').slice(0, QUOTE_LINES)
  let text = lines.join('\n').trimEnd().slice(0, MAX_QUOTE)
  // Do not cut a character in two.
  if (/[\uD800-\uDBFF]$/.test(text)) text = text.slice(0, -1)
  if (text.trim() === '') return ''
  return defuseMentions(
    text
      .split('\n')
      .map(line => `> ${line}`.trimEnd())
      .join('\n'),
  )
}

// unknown is true when the write can have reached GitHub: a timeout, or an answer that Bifrost
// cannot read. The caller then checks GitHub before it sends the write again. detail is the raw
// error text of gh or GitHub. The caller writes it only to the Event log, and the row gets the
// message.
export type WriteOutcome<T> =
  | { ok: true; value: T }
  | { ok: false; message: string; unknown: boolean; detail?: string }

const REPLY = `mutation ReplyToThread($thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body }) {
    comment { id createdAt state }
  }
}`

const RESOLVE = `mutation ResolveThread($thread: ID!) {
  resolveReviewThread(input: { threadId: $thread }) {
    thread { id isResolved }
  }
}`

const COMMENT = `mutation CommentOnPr($subject: ID!, $body: String!) {
  addComment(input: { subjectId: $subject, body: $body }) {
    commentEdge { node { id createdAt } }
  }
}`

// union: true adds the reviewer and keeps the other review requests.
const REQUEST = `mutation RequestReviewer($pr: ID!, $user: ID!) {
  requestReviews(input: { pullRequestId: $pr, userIds: [$user], union: true }) {
    pullRequest { id }
  }
}`

// GitHub makes the commit on the branch and signs it. expectedHeadOid makes GitHub refuse the
// commit when the branch moved, so the write never replaces a commit.
const COMMIT_ON_BRANCH = `mutation CommitOnBranch($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid }
  }
}`

// notFound is true when GitHub found no node for the ID of the write. The Review panel counts the
// delete of a node that is gone as done.
type Failure = { ok: false; message: string; unknown: boolean; detail?: string; notFound?: true }

const isId = (x: unknown): x is string => typeof x === 'string' && x !== ''
const unreadable: Failure = { message: REASON_WRITE_UNREADABLE, ok: false, unknown: true }

function parse(stdout: string): unknown {
  try {
    return JSON.parse(stdout)
  } catch {
    return null
  }
}

const timeOf = (x: unknown): number => {
  const time = Date.parse(asString(x))
  return Number.isNaN(time) ? 0 : time
}

// GitHub refused the request. gh puts the status at the end of its error line.
const HTTP_4XX = /\(HTTP 4\d\d\)/

// The failure of a write call, or null when gh ended well. A failure is known only when GitHub
// did not save the write: gh did not start, the user is logged out (exit code 4), or GitHub
// refused the request (HTTP 4xx). Each other failure can come after GitHub saved the write.
function writeFailure(result: ExecResult): Failure | null {
  if (result.timedOut) return { message: REASON_WRITE_TIMEOUT, ok: false, unknown: true }
  if (result.overflow) return unreadable
  const failure = ghFailure(result)
  if (failure === null) return null
  const known =
    failure.availability === 'no-gh' || result.code === EXIT_AUTH || HTTP_4XX.test(result.stderr)
  // The raw line of gh goes to the Event log. The row gets a fixed text.
  if (failure.detail !== undefined) {
    return { detail: failure.detail, message: REASON_WRITE_FAILED, ok: false, unknown: !known }
  }
  return { message: failure.message, ok: false, unknown: !known }
}

// Run one write with -f fields. approve-review.ts and draft-writes.ts use it for their writes.
export async function send(
  gh: Gh,
  query: string,
  fields: Record<string, string>,
): Promise<{ ok: true; data: Rec } | Failure> {
  const args = ['api', 'graphql', '-f', `query=${query}`]
  for (const [name, value] of Object.entries(fields)) args.push('-f', `${name}=${value}`)
  return answerOf(await gh.run(args))
}

// The answer of one write. An answer with errors fails, also when it has data: GitHub then did
// not do the write, so the result is known. gh prints the answer also when it exits with an
// error, so the check of the errors comes first.
function answerOf(result: ExecResult): { ok: true; data: Rec } | Failure {
  // After a timeout or an overflow, stdout can be a part of the answer only.
  const top = result.timedOut || result.overflow ? null : parse(result.stdout)
  const errors = isRecord(top) && Array.isArray(top.errors) ? top.errors : []
  if (errors.length > 0) {
    const first = asString(asRec(errors[0]).message).trim().split('\n')[0]?.trim() ?? ''
    const detail = first.slice(0, MESSAGE_MAX)
    const gone = asRec(errors[0]).type === 'NOT_FOUND' ? { notFound: true as const } : {}
    if (detail === '')
      return { message: REASON_WRITE_UNREADABLE, ok: false, unknown: false, ...gone }
    return { detail, message: REASON_WRITE_FAILED, ok: false, unknown: false, ...gone }
  }
  const failure = writeFailure(result)
  if (failure !== null) return failure
  return isRecord(top) && isRecord(top.data) ? { data: top.data, ok: true } : unreadable
}

export async function replyToThread(
  gh: Gh,
  o: { threadId: string; body: string },
): Promise<WriteOutcome<{ id: string; createdAt: number; pending: boolean }>> {
  const r = await send(gh, REPLY, { body: o.body, thread: o.threadId })
  if (!r.ok) return r
  const comment = asRec(asRec(r.data.addPullRequestReviewThreadReply).comment)
  if (!isId(comment.id)) return unreadable
  const value = { createdAt: timeOf(comment.createdAt), id: comment.id }
  return { ok: true, value: { ...value, pending: comment.state === 'PENDING' } }
}

export async function resolveThread(
  gh: Gh,
  threadId: string,
): Promise<WriteOutcome<{ resolved: boolean }>> {
  const r = await send(gh, RESOLVE, { thread: threadId })
  if (!r.ok) return r
  const thread = asRec(asRec(r.data.resolveReviewThread).thread)
  if (!isId(thread.id)) return unreadable
  return { ok: true, value: { resolved: thread.isResolved === true } }
}

export async function commentOnPr(
  gh: Gh,
  o: { prId: string; body: string },
): Promise<WriteOutcome<{ id: string; createdAt: number }>> {
  const r = await send(gh, COMMENT, { body: o.body, subject: o.prId })
  if (!r.ok) return r
  const node = asRec(asRec(asRec(r.data.addComment).commentEdge).node)
  if (!isId(node.id)) return unreadable
  return { ok: true, value: { createdAt: timeOf(node.createdAt), id: node.id } }
}

// The longest time of the signed commit write. Its body can hold 4 MB of files, so it can take
// longer than the other writes.
export const COMMIT_TIMEOUT_MS = 120_000

// The PR of a signed fix commit, from the fresh context of the PR. crossRepository is true for a
// PR from a fork. A missing value counts as a fork.
export interface CommitTarget {
  owner: string
  repo: string
  headRef: string
  baseRef: string
  defaultBranch: string
  crossRepository?: boolean
}

// A commit for createCommitOnBranch. repository is owner/repo. Each contents is base64. body is
// empty for a message of one line.
export interface BranchCommit {
  repository: string
  branch: string
  expectedHeadOid: string
  headline: string
  body: string
  additions: { path: string; contents: string }[]
  deletions: { path: string }[]
}

// The write guard of the signed commit (ruling S27). The commit goes only to the head branch of
// the PR, in the repository of the PR. Never a fork, the default branch or the base branch.
function commitAllowed(pr: CommitTarget, c: BranchCommit): boolean {
  const repository = `${pr.owner}/${pr.repo}`
  if (pr.crossRepository !== false || !REPO_KEY.test(repository)) return false
  if (c.repository.toLowerCase() !== repository.toLowerCase()) return false
  if (c.branch === '' || c.branch.startsWith('-') || c.branch !== pr.headRef) return false
  if (pr.baseRef === '' || pr.defaultBranch === '') return false
  const branch = c.branch.toLowerCase()
  if (branch === pr.baseRef.toLowerCase() || branch === pr.defaultBranch.toLowerCase()) {
    return false
  }
  if (!OBJECT_ID.test(c.expectedHeadOid)) return false
  return c.headline.trim() !== '' && !/[\r\n]/.test(c.headline)
}

// The shortest start of a file that the check of an error text looks for.
const QUOTED_START = 12

// GitHub can quote a bad value in its error text. A failure whose message or detail holds the
// start of a file of the fix gives a fixed text and no detail, so no file content shows or goes
// to a log.
function withoutFiles(f: Failure, c: BranchCommit): Failure {
  const quotes = (text: string): boolean =>
    c.additions.some(
      ({ contents }) => contents !== '' && text.includes(contents.slice(0, QUOTED_START)),
    )
  if (!quotes(f.message) && (f.detail === undefined || !quotes(f.detail))) return f
  return { message: REASON_FILES_REFUSED, ok: false, unknown: f.unknown }
}

// Send the signed fix commit. The request body goes on stdin, so no file and no message goes in
// the arguments of gh. A refusal of the guard sends nothing and gives REASON_PUSH_TARGET.
export async function commitOnBranch(
  gh: Gh,
  pr: CommitTarget,
  c: BranchCommit,
): Promise<WriteOutcome<{ oid: string }>> {
  if (!commitAllowed(pr, c)) return { message: REASON_PUSH_TARGET, ok: false, unknown: false }
  const input = {
    branch: { branchName: c.branch, repositoryNameWithOwner: c.repository },
    expectedHeadOid: c.expectedHeadOid,
    fileChanges: { additions: c.additions, deletions: c.deletions },
    message: { headline: c.headline, ...(c.body === '' ? {} : { body: c.body }) },
  }
  const body = JSON.stringify({ query: COMMIT_ON_BRANCH, variables: { input } })
  const result = await gh.run(['api', 'graphql', '--input', '-'], {
    input: body,
    timeoutMs: COMMIT_TIMEOUT_MS,
  })
  const r = answerOf(result)
  if (!r.ok) return withoutFiles(r, c)
  const oid = asRec(asRec(r.data.createCommitOnBranch).commit).oid
  if (typeof oid !== 'string' || !OBJECT_ID.test(oid)) return unreadable
  return { ok: true, value: { oid } }
}

export async function requestReviewer(
  gh: Gh,
  o: { prId: string; userId: string },
): Promise<WriteOutcome<null>> {
  const r = await send(gh, REQUEST, { pr: o.prId, user: o.userId })
  if (!r.ok) return r
  if (!isId(asRec(asRec(r.data.requestReviews).pullRequest).id)) return unreadable
  return { ok: true, value: null }
}
