// The pending review on GitHub. This is the only GitHub write of a review round. Bifrost creates
// a pending review, or adds threads to the pending review of the user and sets its body. Only the
// user submits the review. test/main/reviews/github-writes-source.test.ts guards this rule.
// Each value goes as a -f or -F field, or in the JSON on stdin. No value goes in the query text.

import { PR_KEY, prKey } from '../../shared/reviews'
import { type Gh, ghFailure, MESSAGE_MAX } from './gh'
import { MAX_REVIEW_BODY, type ResultComment } from './result-file'
import { BAD_ANSWER } from './review-query'
import {
  REASON_NOT_PENDING,
  REASON_OTHER_COMMIT,
  reasonPartlyAdded,
  reasonPostFailed,
} from './round-text'

export interface PostArgs {
  owner: string
  repo: string
  number: number
  headSha: string
  pending: { id: string; body: string; commit: string | null } | null
  summary: string
  comments: ResultComment[]
}

export type PostOutcome =
  | { ok: true; reviewId: string; added: number }
  | { ok: false; message: string; added: number }

const NOTHING_TO_POST = 'nothing to post'
const LIMIT = MAX_REVIEW_BODY.toLocaleString('en-GB')
const TOO_LONG = `the review text is longer than ${LIMIT} characters.`
const BAD_NAME = 'the name of the pull request is not valid.'

// The optional variables (startLine, startSide) go only with a range comment.
const ADD_THREAD = `mutation AddThread(
  $review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int,
  $startSide: DiffSide, $body: String!
) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $review, path: $path, line: $line, side: $side,
    startLine: $startLine, startSide: $startSide, body: $body
  }) {
    thread { id }
  }
}`

const SET_BODY = `mutation SetBody($review: ID!, $body: String!) {
  updatePullRequestReview(input: { pullRequestReviewId: $review, body: $body }) {
    pullRequestReview { id state }
  }
}`

type Rec = Record<string, unknown>
type Answer = { ok: true; data: Rec } | { ok: false; message: string }

// The answer of GitHub is not typed. Each read checks the type of its value.
const isRecord = (x: unknown): x is Rec => typeof x === 'object' && x !== null && !Array.isArray(x)
const asRec = (x: unknown): Rec => (isRecord(x) ? x : {})
const isId = (x: unknown): x is string => typeof x === 'string' && x !== ''
const hasText = (text: string): boolean => text.trim() !== ''

function parse(stdout: string): unknown {
  try {
    return JSON.parse(stdout)
  } catch {
    return null
  }
}

function restComment(c: ResultComment): Rec {
  const out: Rec = { body: c.body, line: c.line, path: c.path, side: c.side }
  if (c.startLine !== undefined) {
    out.start_line = c.startLine
    out.start_side = c.startSide ?? c.side
  }
  return out
}

// The JSON of a new pending review. With no event key, GitHub keeps the review as pending.
export function reviewPayload(args: PostArgs): Rec {
  const payload: Rec = { commit_id: args.headSha }
  if (hasText(args.summary)) payload.body = args.summary
  if (args.comments.length > 0) payload.comments = args.comments.map(restComment)
  return payload
}

// The body that Bifrost sets on the pending review of the user: the body of the user, a blank
// line and the summary. An empty body gets only the summary.
function joinedBody(body: string, summary: string): string {
  return hasText(body) ? `${body}\n\n${summary}` : summary
}

function threadFields(review: string, c: ResultComment): string[] {
  const out = ['-f', `review=${review}`, '-f', `path=${c.path}`, '-F', `line=${c.line}`]
  out.push('-f', `side=${c.side}`)
  if (c.startLine !== undefined) {
    out.push('-F', `startLine=${c.startLine}`, '-f', `startSide=${c.startSide ?? c.side}`)
  }
  out.push('-f', `body=${c.body}`)
  return out
}

// Run one GraphQL mutation. An answer with errors fails, also when it has data.
async function mutate(gh: Gh, query: string, fields: string[]): Promise<Answer> {
  const result = await gh.run(['api', 'graphql', '-f', `query=${query}`, ...fields])
  const failure = ghFailure(result)
  if (failure) return { message: failure.message, ok: false }
  const top = asRec(parse(result.stdout))
  const errors = Array.isArray(top.errors) ? top.errors : []
  if (errors.length > 0) {
    const first = asRec(errors[0]).message
    const message = typeof first === 'string' ? first.trim().slice(0, MESSAGE_MAX) : ''
    return { message: message || BAD_ANSWER, ok: false }
  }
  if (!isRecord(top.data)) return { message: BAD_ANSWER, ok: false }
  return { data: top.data, ok: true }
}

async function createReview(gh: Gh, args: PostArgs): Promise<PostOutcome> {
  const path = `repos/${args.owner}/${args.repo}/pulls/${args.number}/reviews`
  const result = await gh.run(['api', '--method', 'POST', path, '--input', '-'], {
    input: JSON.stringify(reviewPayload(args)),
  })
  const failure = ghFailure(result)
  if (failure) return { added: 0, message: reasonPostFailed(failure.message), ok: false }
  // GitHub made the review with all its comments in one step.
  const added = args.comments.length
  const answer = asRec(parse(result.stdout))
  if (answer.state !== 'PENDING' || !isId(answer.node_id)) {
    return { added, message: REASON_NOT_PENDING, ok: false }
  }
  return { added, ok: true, reviewId: answer.node_id }
}

async function addToReview(gh: Gh, args: PostArgs, id: string, body: string): Promise<PostOutcome> {
  const total = args.comments.length
  let added = 0
  const stop = (message: string): PostOutcome => ({
    added,
    message: added === 0 ? reasonPostFailed(message) : reasonPartlyAdded(added, total, message),
    ok: false,
  })
  for (const comment of args.comments) {
    const r = await mutate(gh, ADD_THREAD, threadFields(id, comment))
    if (!r.ok) return stop(r.message)
    if (!isId(asRec(asRec(r.data.addPullRequestReviewThread).thread).id)) return stop(BAD_ANSWER)
    added++
  }
  if (hasText(args.summary)) {
    const r = await mutate(gh, SET_BODY, ['-f', `review=${id}`, '-f', `body=${body}`])
    if (!r.ok) return stop(r.message)
    const review = asRec(asRec(r.data.updatePullRequestReview).pullRequestReview)
    if (!isId(review.id)) return stop(BAD_ANSWER)
    if (review.state !== 'PENDING') return { added, message: REASON_NOT_PENDING, ok: false }
  }
  return { added, ok: true, reviewId: id }
}

// Write the review as a pending review. Each check runs before the first call. The first failed
// call stops the work. This function never rejects when gh.run does not reject.
export async function postPendingReview(gh: Gh, args: PostArgs): Promise<PostOutcome> {
  const refuse = (message: string): PostOutcome => ({ added: 0, message, ok: false })
  if (!hasText(args.summary) && args.comments.length === 0) return refuse(NOTHING_TO_POST)
  // The REST path holds the owner, the repository and the number.
  if (!PR_KEY.test(prKey(args.owner, args.repo, args.number))) {
    return refuse(reasonPostFailed(BAD_NAME))
  }
  const { pending } = args
  // A thread goes on the commit of the pending review. So that commit must be the reviewed one.
  if (pending !== null && pending.commit !== args.headSha) return refuse(REASON_OTHER_COMMIT)
  const body = pending === null ? args.summary : joinedBody(pending.body, args.summary)
  if (hasText(args.summary) && body.length > MAX_REVIEW_BODY) {
    return refuse(reasonPostFailed(TOO_LONG))
  }
  return pending === null ? createReview(gh, args) : addToReview(gh, args, pending.id, body)
}
