// The request context query: all threads, comments and reviews of one PR of the user, with
// pages. A request round reads it before it chooses its items, because the poll reads only the
// newest items. Only reads. Each value goes as a variable, never inside the query text.

import type { Gh } from './gh'
import type { PrComment, PrData, PrReview, PrThread, ReviewState } from './pr-data'
import {
  COMMENT_FIELDS,
  REVIEW_FIELDS,
  REVIEW_STATES,
  readComment,
  readReview,
  readThread,
  THREAD_COMMENT_FIELDS,
} from './query'
import {
  asRec,
  asString,
  BAD_ANSWER,
  call,
  MAX_PAGES,
  nextCursor,
  nodesOf,
  PR_STATES,
  type Rec,
} from './review-query'

export interface RequestThread extends PrThread {
  isOutdated: boolean
  // The diff hunk of the first comment. Empty when GitHub gives none.
  diffHunk: string
  viewerCanReply: boolean
}

export interface RequestContext {
  owner: string
  repo: string
  number: number
  // The GraphQL node ID of the PR.
  id: string
  url: string
  title: string
  body: string
  author: string
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  isCrossRepository: boolean
  defaultBranch: string
  baseRef: string
  baseSha: string
  headRef: string
  headSha: string
  updatedAt: number
  threads: RequestThread[]
  comments: PrComment[]
  reviews: PrReview[]
  // The latest decision of each reviewer. userId is null for a bot.
  decisions: { login: string; userId: string | null; bot: boolean; state: ReviewState }[]
  // The logins of the users with an open review request.
  requested: string[]
  // True when the viewer has a pending review on the PR.
  viewerPending: boolean
  // True when GitHub has more items in one or more lists than Bifrost read.
  truncated: boolean
}

// detail is the raw text from gh or GitHub. The caller writes it to the Event log.
type Fail = { ok: false; message: string; detail?: string }
type Found = { ok: true; pr: Rec } | Fail

// The most gh calls of one read. The three main lists need at most 3 * MAX_PAGES (30) calls, so
// 170 calls stay for the long threads: for example 18 threads with all 9 more pages of comments.
// Without this limit, a busy PR could need about 4,500 calls, and GitHub gives 5,000 points in
// one hour. One read uses at most 4 percent of that hour.
export const MAX_READ_CALLS = 200

// The calls that one read can still make.
interface Budget {
  left: number
}

const CONTEXT_QUERY = `query RequestContext(
  $owner: String!, $repo: String!, $number: Int!, $after: String, $head: Boolean!
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id @include(if: $head)
      url @include(if: $head)
      title @include(if: $head)
      body @include(if: $head)
      state @include(if: $head)
      author @include(if: $head) { login }
      isCrossRepository @include(if: $head)
      baseRefName @include(if: $head)
      baseRefOid @include(if: $head)
      headRefName @include(if: $head)
      headRefOid @include(if: $head)
      updatedAt @include(if: $head)
      repository @include(if: $head) { defaultBranchRef { name } }
      latestOpinionatedReviews(first: 100) @include(if: $head) {
        pageInfo { hasNextPage }
        nodes { state author { login __typename ... on User { id } } }
      }
      reviewRequests(first: 100) @include(if: $head) {
        pageInfo { hasNextPage }
        nodes { requestedReviewer { __typename ... on User { login } } }
      }
      pending: reviews(states: PENDING, first: 10) @include(if: $head) {
        nodes { viewerDidAuthor }
      }
      reviews(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ${REVIEW_FIELDS} }
      }
    }
  }
}`

const THREADS_QUERY = `query RequestThreads(
  $owner: String!, $repo: String!, $number: Int!, $after: String
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          viewerCanReply
          comments(first: 50) {
            pageInfo { hasNextPage endCursor }
            nodes { ${THREAD_COMMENT_FIELDS} diffHunk }
          }
        }
      }
    }
  }
}`

const THREAD_COMMENTS_QUERY = `query ThreadComments($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ${THREAD_COMMENT_FIELDS} }
      }
    }
  }
}`

const COMMENTS_QUERY = `query RequestComments(
  $owner: String!, $repo: String!, $number: Int!, $after: String
) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { ${COMMENT_FIELDS} }
      }
    }
  }
}`

const hasMore = (list: unknown): boolean => asRec(asRec(list).pageInfo).hasNextPage === true

type Paged = { ok: true; first: Rec; nodes: Rec[]; truncated: boolean } | Fail

// Read the pages of one list, up to MAX_PAGES pages in all. A list can start at a later page
// with its cursor: a thread reads the first page of its comments in RequestThreads. `first` is
// the object of the first page that this call reads. Each call uses one call of the budget. With
// no call left, the list stops and is cut.
async function readPages(
  budget: Budget,
  load: (after: string | null, page: number) => Promise<Found>,
  listOf: (found: Rec) => unknown,
  start: { page: number; after: string | null } = { after: null, page: 1 },
): Promise<Paged> {
  let first: Rec | null = null
  const nodes: Rec[] = []
  let { after } = start
  for (let page = start.page; ; page++) {
    if (budget.left <= 0) return { first: first ?? {}, nodes, ok: true, truncated: true }
    budget.left -= 1
    const r = await load(after, page)
    if (!r.ok) return r
    first ??= r.pr
    const list = listOf(r.pr)
    nodes.push(...nodesOf(list))
    after = nextCursor(list)
    // A page that has more items but no cursor also cuts the list.
    if (after === null) return { first, nodes, ok: true, truncated: hasMore(list) }
    if (page >= MAX_PAGES) return { first, nodes, ok: true, truncated: true }
  }
}

function readDecision(n: Rec): RequestContext['decisions'][number] | null {
  const state = asString(n.state)
  if (!REVIEW_STATES.includes(state)) return null
  const author = asRec(n.author)
  const user = author.__typename === 'User'
  const userId = asString(author.id)
  return {
    bot: author.__typename === 'Bot',
    login: asString(author.login),
    state: state as ReviewState,
    userId: user && userId !== '' ? userId : null,
  }
}

// Read one thread of a page, then the next pages of its comments.
async function readRequestThread(
  gh: Gh,
  budget: Budget,
  n: Rec,
): Promise<{ ok: true; thread: RequestThread; truncated: boolean } | Fail | null> {
  const read = readThread(n)
  if (read === null) return null
  const { thread } = read
  let { truncated } = read
  const after = nextCursor(n.comments)
  if (after !== null) {
    const more = await readPages(
      budget,
      cursor =>
        call(gh, THREAD_COMMENTS_QUERY, { after: cursor, id: thread.id }, data => data.node),
      found => found.comments,
      { after, page: 2 },
    )
    if (!more.ok) return more
    for (const c of more.nodes) {
      const comment = readComment(c)
      if (comment) thread.comments.push(comment)
    }
    truncated = more.truncated
  }
  return {
    ok: true,
    thread: {
      ...thread,
      diffHunk: asString(nodesOf(n.comments)[0]?.diffHunk),
      isOutdated: n.isOutdated === true,
      viewerCanReply: n.viewerCanReply === true,
    },
    truncated,
  }
}

export async function fetchRequestContext(
  gh: Gh,
  pr: { owner: string; repo: string; number: number },
): Promise<{ ok: true; context: RequestContext } | Fail> {
  const base = { number: pr.number, owner: pr.owner, repo: pr.repo }
  const budget: Budget = { left: MAX_READ_CALLS }

  // The PR fields come with the first page of the reviews. The main lists come first, so that
  // the long threads cannot use their part of the budget.
  const head = await readPages(
    budget,
    (after, page) => call(gh, CONTEXT_QUERY, { ...base, after, head: page === 1 }),
    found => found.reviews,
  )
  if (!head.ok) return head
  const fields = head.first
  if (!PR_STATES.includes(asString(fields.state))) return { message: BAD_ANSWER, ok: false }
  let truncated =
    head.truncated || hasMore(fields.latestOpinionatedReviews) || hasMore(fields.reviewRequests)

  const threadPages = await readPages(
    budget,
    after => call(gh, THREADS_QUERY, { ...base, after }),
    found => found.reviewThreads,
  )
  if (!threadPages.ok) return threadPages
  truncated ||= threadPages.truncated

  const commentPages = await readPages(
    budget,
    after => call(gh, COMMENTS_QUERY, { ...base, after }),
    found => found.comments,
  )
  if (!commentPages.ok) return commentPages
  truncated ||= commentPages.truncated

  const threads: RequestThread[] = []
  for (const n of threadPages.nodes) {
    const read = await readRequestThread(gh, budget, n)
    if (read === null) continue
    if (!read.ok) return read
    threads.push(read.thread)
    truncated ||= read.truncated
  }

  const requested: string[] = []
  for (const n of nodesOf(fields.reviewRequests)) {
    const reviewer = asRec(n.requestedReviewer)
    const login = asString(reviewer.login)
    if (reviewer.__typename === 'User' && login !== '') requested.push(login)
  }
  const updatedAt = Date.parse(asString(fields.updatedAt))
  return {
    context: {
      author: asString(asRec(fields.author).login),
      baseRef: asString(fields.baseRefName),
      baseSha: asString(fields.baseRefOid),
      body: asString(fields.body),
      comments: commentPages.nodes.flatMap(n => readComment(n) ?? []),
      decisions: nodesOf(fields.latestOpinionatedReviews).flatMap(n => readDecision(n) ?? []),
      defaultBranch: asString(asRec(asRec(fields.repository).defaultBranchRef).name),
      headRef: asString(fields.headRefName),
      headSha: asString(fields.headRefOid),
      id: asString(fields.id),
      isCrossRepository: fields.isCrossRepository === true,
      number: pr.number,
      owner: pr.owner,
      repo: pr.repo,
      requested,
      reviews: head.nodes.flatMap(n => readReview(n) ?? []),
      state: asString(fields.state) as RequestContext['state'],
      threads,
      title: asString(fields.title),
      truncated,
      updatedAt: Number.isNaN(updatedAt) ? 0 : updatedAt,
      url: asString(fields.url),
      viewerPending: nodesOf(fields.pending).some(n => n.viewerDidAuthor === true),
    },
    ok: true,
  }
}

// The polled PR with the full threads, reviews and comments of the context. The context does
// not read the checks, so the checks flag stays as the poll gave it.
export function asPrData(context: RequestContext, polled: PrData): PrData {
  return {
    ...polled,
    comments: context.comments,
    reviews: context.reviews,
    threads: context.threads,
    truncatedComments: context.truncated,
    truncatedReviews: context.truncated,
    truncatedThreads: context.truncated,
  }
}
