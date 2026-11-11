// The on-demand context query of one review: the PR, the reviews of the viewer, and the
// threads of the viewer. Only reads. Each value goes as a variable, never inside the query text.

import type { Gh } from './gh'
import { ghFailure } from './gh'
import type { ReviewState } from './pr-data'

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

const CONTEXT_QUERY = `query ReviewContext($owner: String!, $repo: String!, $number: Int!, $login: String!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      title
      body
      url
      state
      author { login }
      baseRefName
      baseRefOid
      headRefName
      headRefOid
      pending: reviews(states: PENDING, first: 10) {
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

const THREADS_QUERY = `query ReviewThreads($owner: String!, $repo: String!, $number: Int!, $after: String) {
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

// The answer of GitHub is not typed. Each read checks the type of its value.
// biome-ignore lint/suspicious/noExplicitAny: untyped JSON from GitHub
type Json = Record<string, any> | null | undefined
type Fail = { ok: false; message: string }

const BAD_ANSWER = 'GitHub gave an answer that Bifrost could not read.'

interface Vars {
  owner: string
  repo: string
  number: number
  login?: string
  after?: string | null
}

function args(query: string, v: Vars): string[] {
  const out = ['api', 'graphql', '-f', `query=${query}`, '-f', `owner=${v.owner}`]
  out.push('-f', `repo=${v.repo}`, '-F', `number=${v.number}`)
  if (v.login !== undefined) out.push('-f', `login=${v.login}`)
  if (v.after) out.push('-f', `after=${v.after}`)
  return out
}

// Run one operation and give the pull request object of the answer.
async function call(gh: Gh, query: string, v: Vars): Promise<{ ok: true; pr: Json } | Fail> {
  const result = await gh.run(args(query, v))
  const failure = ghFailure(result)
  if (failure) return { message: failure.message, ok: false }
  let parsed: Json
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { message: BAD_ANSWER, ok: false }
  }
  const pr = parsed?.data?.repository?.pullRequest as Json
  if (!pr) {
    const first = Array.isArray(parsed?.errors) ? parsed?.errors[0]?.message : undefined
    return { message: typeof first === 'string' && first ? first : BAD_ANSWER, ok: false }
  }
  return { ok: true, pr }
}

const asString = (x: unknown): string => (typeof x === 'string' ? x : '')

function readReview(n: Json): ViewerReview {
  const comments: Json[] = Array.isArray(n?.comments?.nodes) ? n.comments.nodes : []
  const time = typeof n?.submittedAt === 'string' ? Date.parse(n.submittedAt) : Number.NaN
  const state = asString(n?.state) as ReviewState
  return {
    body: asString(n?.body),
    commit: typeof n?.commit?.oid === 'string' ? n.commit.oid : null,
    replyOnly:
      state === 'COMMENTED' &&
      asString(n?.body).trim() === '' &&
      comments.length > 0 &&
      comments.every(c => c?.replyTo != null),
    state,
    submittedAt: Number.isNaN(time) ? null : time,
    url: asString(n?.url),
  }
}

function readThread(n: Json): ViewerThread {
  const comments: Json[] = Array.isArray(n?.comments?.nodes) ? n.comments.nodes : []
  return {
    comments: comments.map(c => ({
      author: asString(c?.author?.login),
      body: asString(c?.body),
    })),
    isOutdated: n?.isOutdated === true,
    isResolved: n?.isResolved === true,
    line: typeof n?.line === 'number' ? n.line : null,
    path: asString(n?.path),
    url: asString(comments[0]?.url),
  }
}

export async function fetchReviewContext(
  gh: Gh,
  pr: { owner: string; repo: string; number: number },
  viewer: string,
): Promise<{ ok: true; context: ReviewContext } | Fail> {
  const base = { number: pr.number, owner: pr.owner, repo: pr.repo }
  let head: Json
  let pending: ReviewContext['pending'] = null
  const reviews: ViewerReview[] = []
  let truncated = false
  let after: string | null = null
  for (let page = 1; ; page++) {
    const r = await call(gh, CONTEXT_QUERY, { ...base, after, login: viewer })
    if (!r.ok) return r
    if (page === 1) {
      head = r.pr
      const mine = (Array.isArray(r.pr?.pending?.nodes) ? r.pr.pending.nodes : []).find(
        (n: Json) => n?.viewerDidAuthor === true,
      ) as Json
      if (mine) {
        pending = {
          body: asString(mine.body),
          commit: typeof mine.commit?.oid === 'string' ? mine.commit.oid : null,
          id: asString(mine.id),
        }
      }
    }
    for (const n of Array.isArray(r.pr?.reviews?.nodes) ? r.pr.reviews.nodes : []) {
      reviews.push(readReview(n))
    }
    const info = r.pr?.reviews?.pageInfo
    if (info?.hasNextPage !== true || typeof info.endCursor !== 'string') break
    if (page >= MAX_PAGES) {
      truncated = true
      break
    }
    after = info.endCursor
  }

  const threads: ViewerThread[] = []
  if (reviews.some(r => r.state !== 'PENDING')) {
    let cursor: string | null = null
    for (let page = 1; ; page++) {
      const r = await call(gh, THREADS_QUERY, { ...base, after: cursor })
      if (!r.ok) return r
      const list: Json[] = Array.isArray(r.pr?.reviewThreads?.nodes) ? r.pr.reviewThreads.nodes : []
      for (const n of list) {
        const t = readThread(n)
        const first = (n?.comments?.nodes as Json[] | undefined)?.[0]
        if (asString(first?.author?.login).toLowerCase() === viewer.toLowerCase()) threads.push(t)
      }
      const info = r.pr?.reviewThreads?.pageInfo
      if (info?.hasNextPage !== true || typeof info.endCursor !== 'string') break
      if (page >= MAX_PAGES) {
        truncated = true
        break
      }
      cursor = info.endCursor
    }
  }

  const state = asString(head?.state)
  return {
    context: {
      author: asString(head?.author?.login),
      baseRef: asString(head?.baseRefName),
      baseSha: asString(head?.baseRefOid),
      body: asString(head?.body),
      headRef: asString(head?.headRefName),
      headSha: asString(head?.headRefOid),
      number: pr.number,
      owner: pr.owner,
      pending,
      repo: pr.repo,
      reviews,
      state: state === 'CLOSED' || state === 'MERGED' ? state : 'OPEN',
      threads,
      title: asString(head?.title),
      truncated,
      url: asString(head?.url),
    },
    ok: true,
  }
}

// The newest submitted review that is not a reply-only review.
export function lastSubmittedReview(reviews: readonly ViewerReview[]): ViewerReview | null {
  let best: ViewerReview | null = null
  for (const r of reviews) {
    if (r.state === 'PENDING' || r.replyOnly) continue
    if (best === null || (r.submittedAt ?? -1) >= (best.submittedAt ?? -1)) best = r
  }
  return best
}
