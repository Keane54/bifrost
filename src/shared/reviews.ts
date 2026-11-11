// Types and values of the Reviews panel. Main and renderer both use this file.

// A PR key looks like owner/repo#123. The renderer sends only this key, never a path or a URL.
// The repository name is never . or .. (a path part).
export const PR_KEY =
  /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/(?!\.{1,2}#)[A-Za-z0-9._-]{1,100}#[1-9][0-9]{0,9}$/

// A repository key looks like owner/repo.
export const REPO_KEY = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/(?!\.{1,2}$)[A-Za-z0-9._-]{1,100}$/

// The owner/repo part of a PR key, in lower case. GitHub ignores case in these names.
export function repoOf(key: string): string {
  return key.slice(0, key.lastIndexOf('#')).toLowerCase()
}

export function prKey(owner: string, repo: string, number: number): string {
  return `${owner}/${repo}#${number}`
}

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
  olderOpen: number
  claude: ClaudeState
  fixing: number
  error: string | null
  sessionId: string | null
  updatedAt: number
  // True when GitHub has more items of the PR than the poll reads (final review I2).
  truncated: boolean
}

export interface TrustNeed {
  repo: string
  waiting: number
}

export interface ReviewsSnapshot {
  availability: ReviewsAvailability
  message: string | null
  polledAt: number | null
  toReview: ToReviewRow[]
  mine: MyPrRow[]
  trust: TrustNeed[]
}

export const EMPTY_REVIEWS: ReviewsSnapshot = {
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
