// The on-demand context query of one review: the PR, the reviews of the viewer, and the
// threads of the viewer. Only reads. Each value goes as a variable, never inside the query text.

import { isRecord } from '../../shared/plain-object'
import type { Gh } from './gh'
import { ghFailure } from './gh'
import type { ReviewState } from './pr-data'
import { REASON_PR_READ_FAILED } from './round-text'

export const MAX_PAGES = 10

export interface ViewerReview {
  state: ReviewState
  body: string
  submittedAt: number | null
  url: string
  commit: string | null
  // A COMMENTED review with no body and only replies.
  replyOnly: boolean
}

export interface ViewerThread {
  path: string
  line: number | null
  isResolved: boolean
  isOutdated: boolean
  url: string
  comments: { author: string; body: string }[]
}

export interface ReviewContext {
  owner: string
  repo: string
  number: number
  url: string
  title: string
  body: string
  author: string
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  baseRef: string
  baseSha: string
  headRef: string
  headSha: string
  reviews: ViewerReview[]
  threads: ViewerThread[]
  pending: { id: string; body: string; commit: string | null } | null
  truncated: boolean
}

const CONTEXT_QUERY = `query ReviewContext(
  $owner: String!, $repo: String!, $number: Int!, $login: String!, $after: String, $head: Boolean!
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      title @include(if: $head)
      body @include(if: $head)
      url @include(if: $head)
      state @include(if: $head)
      author @include(if: $head) { login }
      baseRefName @include(if: $head)
      baseRefOid @include(if: $head)
      headRefName @include(if: $head)
      headRefOid @include(if: $head)
      pending: reviews(states: PENDING, first: 10) @include(if: $head) {
        nodes { id body viewerDidAuthor commit { oid } }
      }
      reviews(author: $login, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          state
          body
          submittedAt
          url
          commit { oid }
          comments(first: 100) { nodes { replyTo { id } } }
        }
      }
    }
  }
}`

const THREADS_QUERY = `query ReviewThreads(
  $owner: String!, $repo: String!, $number: Int!, $after: String
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          line
          comments(first: 30) { nodes { author { login } body url } }
        }
      }
    }
  }
}`

type Rec = Record<string, unknown>
// detail is the raw text from gh or GitHub. The caller writes it to the Event log.
type Fail = { ok: false; message: string; detail?: string }

export const BAD_ANSWER = 'GitHub gave an answer that Bifrost could not read.'
const REVIEW_STATES: readonly string[] = [
  'APPROVED',
  'CHANGES_REQUESTED',
  'COMMENTED',
  'DISMISSED',
  'PENDING',
]
const PR_STATES: readonly string[] = ['OPEN', 'CLOSED', 'MERGED']

// The answer of GitHub is not typed. Each read checks the type of its value.
const asRec = (x: unknown): Rec => (isRecord(x) ? x : {})
const asArray = (x: unknown): unknown[] => (Array.isArray(x) ? x : [])
const asString = (x: unknown): string => (typeof x === 'string' ? x : '')
const nodesOf = (x: unknown): Rec[] => asArray(asRec(x).nodes).filter(isRecord)
const oidOf = (x: unknown): string | null => {
  const oid = asRec(x).oid
  return typeof oid === 'string' ? oid : null
}

interface Vars {
  owner: string
  repo: string
  number: number
  login?: string
  after?: string | null
  // Page 1 of the context reads the PR fields. Later pages read only the reviews.
  head?: boolean
}

function args(query: string, v: Vars): string[] {
  const out = ['api', 'graphql', '-f', `query=${query}`, '-f', `owner=${v.owner}`]
  out.push('-f', `repo=${v.repo}`, '-F', `number=${v.number}`)
  if (v.login !== undefined) out.push('-f', `login=${v.login}`)
  if (v.head !== undefined) out.push('-F', `head=${v.head}`)
  if (v.after) out.push('-f', `after=${v.after}`)
  return out
}

// Run one operation and give the pull request object of the answer.
async function call(gh: Gh, query: string, v: Vars): Promise<{ ok: true; pr: Rec } | Fail> {
  const result = await gh.run(args(query, v))
  const failure = ghFailure(result)
  if (failure) {
    if (failure.detail === undefined) return { message: failure.message, ok: false }
    return { detail: failure.detail, message: REASON_PR_READ_FAILED, ok: false }
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { message: BAD_ANSWER, ok: false }
  }
  const top = asRec(parsed)
  // An answer with errors fails, also when it has data. A part of the data must not look whole.
  const errors = asArray(top.errors)
  if (errors.length > 0) {
    const first = asString(asRec(errors[0]).message)
    if (!first) return { message: BAD_ANSWER, ok: false }
    return { detail: first, message: REASON_PR_READ_FAILED, ok: false }
  }
  const pr = asRec(asRec(top.data).repository).pullRequest
  if (!isRecord(pr)) return { message: BAD_ANSWER, ok: false }
  return { ok: true, pr }
}

function readReview(n: Rec): ViewerReview | null {
  const state = asString(n.state)
  if (!REVIEW_STATES.includes(state)) return null
  const comments = nodesOf(n.comments)
  const time = typeof n.submittedAt === 'string' ? Date.parse(n.submittedAt) : Number.NaN
  return {
    body: asString(n.body),
    commit: oidOf(n.commit),
    replyOnly:
      state === 'COMMENTED' &&
      asString(n.body).trim() === '' &&
      comments.length > 0 &&
      comments.every(c => c.replyTo != null),
    state: state as ReviewState,
    submittedAt: Number.isNaN(time) ? null : time,
    url: asString(n.url),
  }
}

function readThread(n: Rec): ViewerThread {
  const comments = nodesOf(n.comments)
  return {
    comments: comments.map(c => ({
      author: asString(asRec(c.author).login),
      body: asString(c.body),
    })),
    isOutdated: n.isOutdated === true,
    isResolved: n.isResolved === true,
    line: typeof n.line === 'number' ? n.line : null,
    path: asString(n.path),
    url: asString(comments[0]?.url),
  }
}

// The next cursor of a page, or null when the list ends.
function nextCursor(list: unknown): string | null {
  const info = asRec(asRec(list).pageInfo)
  const cursor = info.endCursor
  return info.hasNextPage === true && typeof cursor === 'string' ? cursor : null
}

export async function fetchReviewContext(
  gh: Gh,
  pr: { owner: string; repo: string; number: number },
  viewer: string,
): Promise<{ ok: true; context: ReviewContext } | Fail> {
  const base = { number: pr.number, owner: pr.owner, repo: pr.repo }
  let head: Rec = {}
  let pending: ReviewContext['pending'] = null
  const reviews: ViewerReview[] = []
  let truncated = false
  let after: string | null = null
  for (let page = 1; ; page++) {
    const r = await call(gh, CONTEXT_QUERY, { ...base, after, head: page === 1, login: viewer })
    if (!r.ok) return r
    if (page === 1) {
      head = r.pr
      if (!PR_STATES.includes(asString(head.state))) return { message: BAD_ANSWER, ok: false }
      const mine = nodesOf(head.pending).find(
        n => n.viewerDidAuthor === true && asString(n.id) !== '',
      )
      if (mine) {
        pending = { body: asString(mine.body), commit: oidOf(mine.commit), id: asString(mine.id) }
      }
    }
    for (const n of nodesOf(r.pr.reviews)) {
      const review = readReview(n)
      if (review) reviews.push(review)
    }
    after = nextCursor(r.pr.reviews)
    if (after === null) break
    if (page >= MAX_PAGES) {
      truncated = true
      break
    }
  }

  const threads: ViewerThread[] = []
  if (reviews.some(r => r.state !== 'PENDING')) {
    let cursor: string | null = null
    for (let page = 1; ; page++) {
      const r = await call(gh, THREADS_QUERY, { ...base, after: cursor })
      if (!r.ok) return r
      for (const n of nodesOf(r.pr.reviewThreads)) {
        const first = nodesOf(n.comments)[0]
        const author = asString(asRec(first?.author).login)
        if (author.toLowerCase() === viewer.toLowerCase()) threads.push(readThread(n))
      }
      cursor = nextCursor(r.pr.reviewThreads)
      if (cursor === null) break
      if (page >= MAX_PAGES) {
        truncated = true
        break
      }
    }
  }

  const state = asString(head.state) as ReviewContext['state']
  return {
    context: {
      author: asString(asRec(head.author).login),
      baseRef: asString(head.baseRefName),
      baseSha: asString(head.baseRefOid),
      body: asString(head.body),
      headRef: asString(head.headRefName),
      headSha: asString(head.headRefOid),
      number: pr.number,
      owner: pr.owner,
      pending,
      repo: pr.repo,
      reviews,
      state,
      threads,
      title: asString(head.title),
      truncated,
      url: asString(head.url),
    },
    ok: true,
  }
}

// A submitted review that is not a reply-only review.
export const isRealReview = (r: ViewerReview): boolean => r.state !== 'PENDING' && !r.replyOnly

// The newest submitted review that is not a reply-only review.
export function lastSubmittedReview(reviews: readonly ViewerReview[]): ViewerReview | null {
  let best: ViewerReview | null = null
  for (const r of reviews) {
    if (!isRealReview(r)) continue
    if (best === null || (r.submittedAt ?? -1) >= (best.submittedAt ?? -1)) best = r
  }
  return best
}
