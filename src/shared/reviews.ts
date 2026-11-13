// Types and values of the Reviews panel. Main and renderer both use this file.

// A PR key looks like owner/repo#123. The renderer sends only this key, never a path or a URL.
// The repository name is never . or .. (a path part).
export const PR_KEY =
  /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/(?!\.{1,2}#)[A-Za-z0-9._-]{1,100}#[1-9][0-9]{0,9}$/

// A repository key looks like owner/repo.
export const REPO_KEY = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/(?!\.{1,2}$)[A-Za-z0-9._-]{1,100}$/

// The owner/repo part of a PR key, in lower case. GitHub ignores case in these names.
export function repoOf(key: string): string {
  const hash = key.lastIndexOf('#')
  return (hash === -1 ? key : key.slice(0, hash)).toLowerCase()
}

export function prKey(owner: string, repo: string, number: number): string {
  return `${owner}/${repo}#${number}`
}

// An item ID has the form of a GitHub node ID, for example PRRT_kwDOexample1. A legacy node ID
// is base64, so it can end with one or two = signs. The renderer sends only this ID for an item.
export const ITEM_ID = /^[A-Za-z0-9_-]{1,100}={0,2}$/

// The GraphQL login of the Copilot review bot.
export const COPILOT_LOGIN = 'copilot-pull-request-reviewer'
// Only these authors may give instructions to a session.
export const TRUSTED_ASSOCIATIONS: readonly string[] = ['OWNER', 'MEMBER', 'COLLABORATOR']

export type ReviewsAvailability = 'off' | 'starting' | 'ok' | 'no-gh' | 'logged-out' | 'error'
export type ToReviewState =
  | 'new'
  | 'draft-ready'
  | 'reviewed'
  | 'failed'
  | 'waiting'
  | 'trust-needed'
  | 'reviewing'
  | 'queued'
  | 'paused'
  | 'approved-by-others'
  | 'team'
export type Recommendation = 'approve' | 'comment' | 'request-changes'
export const RECOMMENDATIONS: readonly Recommendation[] = ['approve', 'comment', 'request-changes']
export const RECOMMENDATION_TEXT: Record<Recommendation, string> = {
  approve: 'Approve',
  comment: 'Comment',
  'request-changes': 'Request changes',
}
export type ReviewStatus = 'changes-requested' | 'comments' | 'approved' | 'pending'
export type ClaudeState =
  | 'needs-you'
  | 'fixing'
  | 'queued'
  | 'trust-needed'
  | 'cloning'
  | 'waiting'
  | 'error'
  | 'fork'

export interface ToReviewRow {
  key: string
  owner: string
  repo: string
  number: number
  title: string
  author: string
  additions: number
  deletions: number
  requestedAt: number
  state: ToReviewState
  // True for a team request: the open requests do not list the viewer. The row shows a team tag
  // in each state (design 8.1).
  team: boolean
  flash: boolean
  pauseEndsAt: number | null
  sessionId: string | null
  // The recommendation of the last review. Set for draft-ready and reviewed rows only.
  recommendation: Recommendation | null
  why: string | null
  // The error of the last review. Set for failed rows only.
  error: string | null
}

// An open question of a request round. `where` names the file and line, or the author.
// The longest answer to a question of Claude, in characters.
export const MAX_ANSWER = 2_000
// The most answers in one call of reviews.answer.
export const MAX_ANSWERS = 50

export interface QuestionRow {
  id: string
  where: string
  question: string
  // The comment of the reviewer. These are missing for a question that was saved before the quote
  // was added, and for a comment that GitHub no longer has.
  author?: string
  body?: string
  url?: string
  // The kind of comment: a review thread or a PR comment or review.
  kind?: 'thread' | 'comment'
}

export interface MyPrRow {
  key: string
  owner: string
  repo: string
  number: number
  title: string
  status: ReviewStatus
  reviewers: string[]
  failedChecks: number
  laterCopilot: number
  // The last error of the PR. The row error hides it while a question is open, so the Answer
  // panel shows it.
  lastError: string | null
  olderOpen: number
  claude: ClaudeState
  fixing: number
  error: string | null
  sessionId: string | null
  updatedAt: number
  // True when GitHub has more items of the PR than the poll reads (final review I2).
  truncated: boolean
  // True when a request round left posts that Bifrost did not send. Cancel on an error row drops
  // them, and their comments wait for Handle now.
  unsent: boolean
  // The open questions of the PR, oldest first.
  questions: QuestionRow[]
}

export interface TrustNeed {
  repo: string
  waiting: number
}

export interface ReviewsSnapshot {
  // True when automatic fixes wait for the confirm of the user (ruling S20). The My PRs tab shows
  // how to turn them on.
  autoFixConfirm: boolean
  availability: ReviewsAvailability
  message: string | null
  polledAt: number | null
  toReview: ToReviewRow[]
  mine: MyPrRow[]
  trust: TrustNeed[]
}

export const EMPTY_REVIEWS: ReviewsSnapshot = {
  autoFixConfirm: false,
  availability: 'off',
  message: null,
  mine: [],
  polledAt: null,
  toReview: [],
  trust: [],
}

export const REASON_GH_MISSING =
  "GitHub CLI (gh) isn't installed. Install it with Homebrew (brew install gh), log in with gh auth login, then click Refresh."
export const REASON_GH_LOGGED_OUT =
  "GitHub CLI (gh) isn't logged in. Run gh auth login in a terminal, then click Refresh."
export const REASON_GH_TIMEOUT = "GitHub didn't answer in time. Bifrost will try again."
// gh failed and gave no error text, or the run of gh threw.
export const REASON_GH_FAILED = "GitHub CLI (gh) couldn't read GitHub."
// Node stopped gh because the answer was longer than the buffer.
export const REASON_GH_OVERFLOW = 'GitHub gave more data than Bifrost can read.'
