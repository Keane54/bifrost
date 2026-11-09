// The one GraphQL query of a poll, and the reader of its answer.
import { prKey } from '../../shared/reviews'
import type {
  Author,
  PollData,
  PrComment,
  PrData,
  PrReview,
  PrThread,
  ReviewState,
} from './pr-data'

const SEARCH_OPEN = 'is:pr is:open archived:false'

// A thread reads 10 comments. With 50, GitHub refuses the query: more than 500,000 nodes.
const AUTHOR = 'author { login __typename } authorAssociation'
// IssueComment (top level) has no pullRequestReview. Only a thread comment has it.
const COMMENT_FIELDS = `id databaseId ${AUTHOR} body createdAt`
const THREAD_COMMENT_FIELDS = `${COMMENT_FIELDS} pullRequestReview { id }`

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

const PR_CONVERSATION = `
  reviews(first: 30) {
    pageInfo { hasNextPage }
    nodes { id databaseId ${AUTHOR} state body submittedAt commit { oid } }
  }
  reviewThreads(first: 20) {
    pageInfo { hasNextPage }
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
  rateLimit { cost remaining }
  toReview: search(query: "review-requested:@me ${SEARCH_OPEN}", type: ISSUE, first: 50) {
    nodes { ... on PullRequest { ...ToReviewFields } }
  }
  mine: search(query: "author:@me ${SEARCH_OPEN}", type: ISSUE, first: 50) {
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
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null
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

function readComment(v: unknown): PrComment | null {
  const o = obj(v)
  const id = str(o?.id)
  if (!o || id === null) return null
  return {
    author: authorOf(o),
    body: str(o.body) ?? '',
    createdAt: time(o.createdAt) ?? 0,
    databaseId: num(o.databaseId),
    id,
  }
}

function readComments(v: unknown): PrComment[] {
  return nodes(v).flatMap(c => readComment(c) ?? [])
}

const REVIEW_STATES: readonly string[] = [
  'APPROVED',
  'CHANGES_REQUESTED',
  'COMMENTED',
  'DISMISSED',
  'PENDING',
]

function readReview(v: unknown): PrReview | null {
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
  }
}

function readThread(v: unknown): { thread: PrThread; truncated: boolean } | null {
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

  const requestedUsers: string[] = []
  const requestedTeams: string[] = []
  for (const n of nodes(o.reviewRequests)) {
    const r = reviewer(obj(n)?.requestedReviewer)
    if (r.user) requestedUsers.push(r.user)
    if (r.team) requestedTeams.push(r.team)
  }

  const createdAt = time(o.createdAt) ?? 0
  // The request time: the newest request event for the viewer or for a team.
  let requestedAt = 0
  for (const n of nodes(o.timelineItems)) {
    const e = obj(n)
    const r = reviewer(e?.requestedReviewer)
    const at = time(e?.createdAt)
    if (at === null || (r.user !== viewer && r.team === null)) continue
    if (at > requestedAt) requestedAt = at
  }

  const threads: PrThread[] = []
  let truncated = more(o.reviewThreads) || more(o.reviews) || more(o.comments)
  for (const t of nodes(o.reviewThreads)) {
    const read = readThread(t)
    if (!read) continue
    threads.push(read.thread)
    if (read.truncated) truncated = true
  }

  const commit = obj(obj(nodes(o.commits)[0])?.commit)
  const contexts = obj(obj(commit?.statusCheckRollup)?.contexts)
  if (more(contexts)) truncated = true

  const decision = str(o.reviewDecision)
  return {
    additions: num(o.additions),
    author: str(obj(o.author)?.login) ?? 'ghost',
    baseRef: str(o.baseRefName) ?? '',
    comments: readComments(o.comments),
    createdAt,
    deletions: num(o.deletions),
    failedChecks: countFailed(nodes(contexts)),
    headRef: str(o.headRefName) ?? '',
    headSha: str(o.headRefOid) ?? '',
    isCrossRepository: o.isCrossRepository === true,
    isDraft: o.isDraft === true,
    key: prKey(owner, repo, number),
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
    truncated,
    updatedAt: time(o.updatedAt) ?? createdAt,
    url,
    viewerPendingReviewId: str(obj(nodes(o.pendingReviews)[0])?.id),
  }
}

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
  const errors = top?.errors
  if (Array.isArray(errors) && errors.length > 0) {
    const message = str(obj(errors[0])?.message)
    return { message: message ?? 'GitHub gave an error.', ok: false }
  }
  const data = obj(top?.data)
  const viewer = str(obj(data?.viewer)?.login)
  if (!data || !viewer) return { message: 'GitHub did not say who you are.', ok: false }
  const list = (v: unknown): PrData[] => nodes(v).flatMap(n => readPr(n, viewer) ?? [])
  return { data: { mine: list(data.mine), toReview: list(data.toReview), viewer }, ok: true }
}
