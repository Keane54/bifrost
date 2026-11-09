// The data of one PR, as the poll reads it from GitHub. Main process only.
// All times are milliseconds since the epoch.

export interface Author {
  login: string
  bot: boolean
  association: string
}

export interface PrComment {
  id: string
  databaseId: number
  author: Author
  body: string
  createdAt: number
}

export interface PrThread {
  id: string
  isResolved: boolean
  path: string
  line: number | null
  // The review of the first comment of the thread.
  reviewId: string | null
  comments: PrComment[]
}

export type ReviewState = 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | 'DISMISSED' | 'PENDING'

export interface PrReview {
  id: string
  databaseId: number
  author: Author
  state: ReviewState
  body: string
  submittedAt: number | null
  commit: string | null
}

// In R1, a To review PR carries no reviews, threads or comments: these lists are empty.
export interface PrData {
  key: string
  owner: string
  repo: string
  number: number
  title: string
  url: string
  author: string
  isDraft: boolean
  additions: number
  deletions: number
  createdAt: number
  updatedAt: number
  reviewDecision: 'APPROVED' | 'CHANGES_REQUESTED' | 'REVIEW_REQUIRED' | null
  // Logins of the users with an open review request.
  requestedUsers: string[]
  // Slugs of the teams with an open review request.
  requestedTeams: string[]
  requestedAt: number
  reviews: PrReview[]
  threads: PrThread[]
  comments: PrComment[]
  failedChecks: number
  headRef: string
  headSha: string
  baseRef: string
  isCrossRepository: boolean
  viewerPendingReviewId: string | null
  // True when a list of the PR has more items than the query reads.
  truncated: boolean
}

export interface PollData {
  viewer: string
  toReview: PrData[]
  mine: PrData[]
}
