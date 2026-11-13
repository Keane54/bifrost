// The one GraphQL query of a poll, and the reader of its answer.
import { isRecord } from '../../shared/plain-object'
import { PR_KEY, prKey } from '../../shared/reviews'
import type {
  Author,
  PollData,
  PrComment,
  PrData,
  PrReview,
  PrThread,
  RateLimit,
  ReviewState,
} from './pr-data'

const SEARCH_OPEN = 'is:pr is:open archived:false'

// A thread reads 10 comments. With 50, GitHub refuses the query: more than 500,000 nodes.
const AUTHOR = 'author { login __typename } authorAssociation'
// The request context query (request-query.ts) reads the same fields, so these are exported.
// IssueComment (top level) has no pullRequestReview. Only a thread comment has it.
export const COMMENT_FIELDS = `id databaseId ${AUTHOR} body createdAt url`
export const THREAD_COMMENT_FIELDS = `${COMMENT_FIELDS} pullRequestReview { id }`
export const REVIEW_FIELDS = `id databaseId ${AUTHOR} state body submittedAt commit { oid } url`

// The fields of both fragments. A fragment of To review PRs has no reviews, threads or comments.
const PR_HEAD = `
  number
  title
  url
  isDraft
  additions
  deletions
  createdAt
  updatedAt
  repository { name owner { login } }
  author { login }
  reviewDecision
  reviewRequests(first: 10) {
    nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
  }
  timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
    nodes {
      ... on ReviewRequestedEvent {
        createdAt
        requestedReviewer { __typename ... on User { login } ... on Team { slug } }
      }
    }
  }
  pendingReviews: reviews(states: PENDING, first: 1) { nodes { id } }`

const prChecks = (contexts: number): string => `
  commits(last: 1) {
    nodes {
      commit {
        oid
        statusCheckRollup {
          state
          contexts(first: ${contexts}) {
            pageInfo { hasNextPage }
            nodes {
              __typename
              ... on CheckRun { conclusion }
              ... on StatusContext { state }
            }
          }
        }
      }
    }
  }
  headRefName
  headRefOid
  baseRefName
  isCrossRepository`

// A busy PR has more reviews and threads than one page. The decisions come from
// latestOpinionatedReviews, and the threads are the newest 20 (final review I2).
const PR_CONVERSATION = `
  reviews(first: 30) {
    pageInfo { hasNextPage }
    nodes { ${REVIEW_FIELDS} }
  }
  latestOpinionatedReviews(first: 20) {
    pageInfo { hasNextPage }
    nodes { id ${AUTHOR} state submittedAt }
  }
  reviewThreads(last: 20) {
    pageInfo { hasPreviousPage }
    nodes {
      id
      isResolved
      path
      line
      comments(first: 10) {
        pageInfo { hasNextPage }
        nodes { ${THREAD_COMMENT_FIELDS} }
      }
    }
  }
  comments(last: 30) {
    pageInfo { hasPreviousPage }
    nodes { ${COMMENT_FIELDS} }
  }`

export const TO_REVIEW_FRAGMENT = `fragment ToReviewFields on PullRequest {${PR_HEAD}${prChecks(20)}
}`
export const MINE_FRAGMENT = `fragment MineFields on PullRequest {${PR_HEAD}${PR_CONVERSATION}${prChecks(20)}
}`

export const POLL_QUERY = `query Poll {
  viewer { login }
  rateLimit { cost limit remaining resetAt }
  toReview: search(query: "review-requested:@me ${SEARCH_OPEN}", type: ISSUE, first: 50) {
    pageInfo { hasNextPage }
    nodes { ... on PullRequest { ...ToReviewFields } }
  }
  mine: search(query: "author:@me ${SEARCH_OPEN}", type: ISSUE, first: 50) {
    pageInfo { hasNextPage }
    nodes { ... on PullRequest { ...MineFields } }
  }
}
${TO_REVIEW_FRAGMENT}
${MINE_FRAGMENT}
`

export function pollArgs(): string[] {
  return ['api', 'graphql', '-f', `query=${POLL_QUERY}`]
}

const FAILED_CONCLUSIONS = new Set([
  'FAILURE',
  'TIMED_OUT',
  'CANCELLED',
  'STARTUP_FAILURE',
  'ACTION_REQUIRED',
])
const FAILED_STATES = new Set(['FAILURE', 'ERROR'])
// The longest error message that a partial answer keeps.
const ERROR_MAX = 200

// Count the check contexts that failed.
export function countFailed(contexts: unknown[]): number {
  let count = 0
  for (const c of contexts) {
    const o = obj(c)
    if (!o) continue
    if (o.__typename === 'CheckRun' && typeof o.conclusion === 'string') {
      if (FAILED_CONCLUSIONS.has(o.conclusion)) count++
    } else if (o.__typename === 'StatusContext' && typeof o.state === 'string') {
      if (FAILED_STATES.has(o.state)) count++
    }
  }
  return count
}

function obj(v: unknown): Record<string, unknown> | null {
  return isRecord(v) ? v : null
}

const str = (v: unknown): string | null => (typeof v === 'string' ? v : null)
const num = (v: unknown, fallback = 0): number =>
  typeof v === 'number' && Number.isFinite(v) ? v : fallback

function time(v: unknown): number | null {
  if (typeof v !== 'string') return null
  const t = Date.parse(v)
  return Number.isNaN(t) ? null : t
}

function nodes(v: unknown): unknown[] {
  const list = obj(v)?.nodes
  return Array.isArray(list) ? list : []
}

function more(v: unknown): boolean {
  const page = obj(obj(v)?.pageInfo)
  return page?.hasNextPage === true || page?.hasPreviousPage === true
}

function author(v: unknown): Author {
  const o = obj(v)
  return { association: 'NONE', bot: o?.__typename === 'Bot', login: str(o?.login) ?? 'ghost' }
}

function authorOf(node: Record<string, unknown>): Author {
  return { ...author(node.author), association: str(node.authorAssociation) ?? 'NONE' }
}

// The optional link of a comment or a review.
function urlField(o: Record<string, unknown>): { url?: string } {
  const url = str(o.url)
  return url === null ? {} : { url }
}

export function readComment(v: unknown): PrComment | null {
  const o = obj(v)
  const id = str(o?.id)
  if (!o || id === null) return null
  return {
    author: authorOf(o),
    body: str(o.body) ?? '',
    createdAt: time(o.createdAt) ?? 0,
    databaseId: num(o.databaseId),
    id,
    ...urlField(o),
  }
}

function readComments(v: unknown): PrComment[] {
  return nodes(v).flatMap(c => readComment(c) ?? [])
}

export const REVIEW_STATES: readonly string[] = [
  'APPROVED',
  'CHANGES_REQUESTED',
  'COMMENTED',
  'DISMISSED',
  'PENDING',
]

export function readReview(v: unknown): PrReview | null {
  const o = obj(v)
  const id = str(o?.id)
  const state = str(o?.state)
  if (!o || id === null || state === null || !REVIEW_STATES.includes(state)) return null
  return {
    author: authorOf(o),
    body: str(o.body) ?? '',
    commit: str(obj(o.commit)?.oid),
    databaseId: num(o.databaseId),
    id,
    state: state as ReviewState,
    submittedAt: time(o.submittedAt),
    ...urlField(o),
  }
}

export function readThread(v: unknown): { thread: PrThread; truncated: boolean } | null {
  const o = obj(v)
  const id = str(o?.id)
  if (!o || id === null) return null
  const raw = nodes(o.comments)
  const first = obj(raw[0])
  return {
    thread: {
      comments: readComments(o.comments),
      id,
      isResolved: o.isResolved === true,
      line: typeof o.line === 'number' ? o.line : null,
      path: str(o.path) ?? '',
      reviewId: str(obj(first?.pullRequestReview)?.id),
    },
    truncated: more(o.comments),
  }
}

// The reviewer of a request or of a request event: a user login or a team slug.
function reviewer(v: unknown): { user: string | null; team: string | null } {
  const o = obj(v)
  return {
    team: o?.__typename === 'Team' ? str(o.slug) : null,
    user: o?.__typename === 'User' ? str(o.login) : null,
  }
}

const DECISIONS = ['APPROVED', 'CHANGES_REQUESTED', 'REVIEW_REQUIRED'] as const

function readPr(v: unknown, viewer: string): PrData | null {
  const o = obj(v)
  if (!o) return null
  const number = o.number
  const url = str(o.url)
  const repository = obj(o.repository)
  const owner = str(obj(repository?.owner)?.login)
  const repo = str(repository?.name)
  if (typeof number !== 'number' || !Number.isInteger(number) || number < 1) return null
  if (!url || !owner || !repo) return null
  // The state and the IPC take only a valid PR key. A PR with another key would notify again
  // after each restart, and the page could not act on it.
  const key = prKey(owner, repo, number)
  if (!PR_KEY.test(key)) return null

  const requestedUsers: string[] = []
  const requestedTeams: string[] = []
  for (const n of nodes(o.reviewRequests)) {
    const r = reviewer(obj(n)?.requestedReviewer)
    if (r.user) requestedUsers.push(r.user)
    if (r.team) requestedTeams.push(r.team)
  }

  const createdAt = time(o.createdAt) ?? 0
  // The request time. A direct request uses only the request events for the viewer. A team
  // request uses the newest team event. Without an event, the time is createdAt
  // (final review M10).
  const direct = requestedUsers.includes(viewer)
  let requestedAt = 0
  for (const n of nodes(o.timelineItems)) {
    const e = obj(n)
    const r = reviewer(e?.requestedReviewer)
    const at = time(e?.createdAt)
    const counts = direct ? r.user === viewer : r.team !== null
    if (at === null || !counts) continue
    if (at > requestedAt) requestedAt = at
  }

  const threads: PrThread[] = []
  let truncatedThreads = more(o.reviewThreads)
  for (const t of nodes(o.reviewThreads)) {
    const read = readThread(t)
    if (!read) continue
    threads.push(read.thread)
    if (read.truncated) truncatedThreads = true
  }

  const commit = obj(obj(nodes(o.commits)[0])?.commit)
  const rollup = obj(commit?.statusCheckRollup)
  const contexts = obj(rollup?.contexts)
  // The rollup state also counts the checks that the query does not read. A failed rollup with
  // no failed context in the first page gives one failed check (final review M6).
  const failedChecks = Math.max(
    countFailed(nodes(contexts)),
    FAILED_STATES.has(str(rollup?.state) ?? '') ? 1 : 0,
  )

  const decision = str(o.reviewDecision)
  return {
    additions: num(o.additions),
    author: str(obj(o.author)?.login) ?? 'ghost',
    baseRef: str(o.baseRefName) ?? '',
    comments: readComments(o.comments),
    createdAt,
    decisions: nodes(o.latestOpinionatedReviews).flatMap(r => readReview(r) ?? []),
    deletions: num(o.deletions),
    failedChecks,
    headRef: str(o.headRefName) ?? '',
    headSha: str(o.headRefOid) ?? '',
    isCrossRepository: o.isCrossRepository === true,
    isDraft: o.isDraft === true,
    key,
    number,
    owner,
    repo,
    requestedAt: requestedAt || createdAt,
    requestedTeams,
    requestedUsers,
    reviewDecision: DECISIONS.find(d => d === decision) ?? null,
    reviews: nodes(o.reviews).flatMap(r => readReview(r) ?? []),
    threads,
    title: str(o.title) ?? '',
    truncatedChecks: more(contexts),
    truncatedComments: more(o.comments),
    truncatedReviews: more(o.reviews) || more(o.latestOpinionatedReviews),
    truncatedThreads,
    updatedAt: time(o.updatedAt) ?? createdAt,
    url,
    viewerPendingReviewId: str(obj(nodes(o.pendingReviews)[0])?.id),
  }
}

// A count of the rate limit: a finite number, 0 or more.
function count(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null
}

// The rate limit of the answer (P11). GitHub gives resetAt as an ISO time. A missing or bad value
// gives null.
function readRateLimit(v: unknown): RateLimit | null {
  const o = obj(v)
  const cost = count(o?.cost)
  const limit = count(o?.limit)
  const remaining = count(o?.remaining)
  const resetAt = time(o?.resetAt)
  if (cost === null || limit === null || remaining === null || resetAt === null) return null
  return { cost, limit, remaining, resetAt }
}

// The messages of the errors of an answer, each one time. Only the message, cut to ERROR_MAX.
// An error with no message gives a general text.
function errorMessages(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  const messages = new Set<string>()
  for (const e of v) {
    const message = str(obj(e)?.message)?.trim().slice(0, ERROR_MAX)
    messages.add(message ? message : 'GitHub gave an error.')
  }
  return [...messages]
}

// Read the answer of the poll. An answer with data and errors (a partial answer) keeps its data,
// and data.errors has the messages. An answer with errors fails only when it has no viewer or no
// result for one of the two searches (final review M7).
export function parsePoll(
  stdout: string,
): { ok: true; data: PollData } | { ok: false; message: string } {
  let root: unknown
  try {
    root = JSON.parse(stdout)
  } catch {
    return { message: "GitHub gave an answer that Bifrost can't read.", ok: false }
  }
  const top = obj(root)
  const errors = errorMessages(top?.errors)
  const data = obj(top?.data)
  const viewer = str(obj(data?.viewer)?.login)
  if (errors.length > 0) {
    const usable = viewer !== null && obj(data?.toReview) !== null && obj(data?.mine) !== null
    if (!usable) return { message: errors[0] ?? 'GitHub gave an error.', ok: false }
  }
  if (!data || !viewer) return { message: 'GitHub did not say who you are.', ok: false }
  const list = (v: unknown): PrData[] => nodes(v).flatMap(n => readPr(n, viewer) ?? [])
  return {
    data: {
      errors,
      mine: list(data.mine),
      mineHasMore: more(data.mine),
      rateLimit: readRateLimit(data.rateLimit),
      toReview: list(data.toReview),
      toReviewHasMore: more(data.toReview),
      viewer,
    },
    ok: true,
  }
}
