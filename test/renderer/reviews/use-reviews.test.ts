// The app-wide Reviews store: one subscription, and the attention flag for the side bar.
import { describe, expect, it, vi } from 'vitest'
import { createReviewsStore, reviewsAttention } from '../../../src/renderer/src/reviews/use-reviews'
import {
  type ClaudeState,
  EMPTY_REVIEWS,
  type MyPrRow,
  type QuestionRow,
  type ReviewsSnapshot,
  type ToReviewRow,
} from '../../../src/shared/reviews'

function row(flash: boolean): ToReviewRow {
  return {
    additions: 1,
    author: 'a',
    deletions: 1,
    error: null,
    flash,
    key: 'o/r#1',
    number: 1,
    owner: 'o',
    pauseEndsAt: null,
    recommendation: null,
    repo: 'r',
    requestedAt: 0,
    sessionId: null,
    state: 'queued',
    team: false,
    title: 't',
    why: null,
  } as ToReviewRow
}

function mine(claude: ClaudeState, questions: QuestionRow[] = []): MyPrRow {
  return {
    claude,
    error: null,
    failedChecks: 0,
    fixing: 0,
    key: 'o/r#2',
    lastError: null,
    laterCopilot: 0,
    number: 2,
    olderOpen: 0,
    owner: 'o',
    questions,
    repo: 'r',
    reviewers: [],
    sessionId: null,
    status: 'pending',
    title: 't',
    truncated: false,
    unsent: false,
    updatedAt: 0,
  }
}

const QUESTION: QuestionRow = { id: 'PRRT_1', question: 'Which name?', where: 'src/a.ts line 3' }

function fakeApi() {
  const off = vi.fn()
  const api = {
    onUpdate: vi.fn((_cb: (s: ReviewsSnapshot) => void) => off),
    snapshot: vi.fn(() => new Promise<ReviewsSnapshot>(() => {})),
  }
  return { api, off }
}

describe('reviews store', () => {
  it('reviewsAttention is true only for a To review row that flashes', () => {
    expect(reviewsAttention(EMPTY_REVIEWS)).toBe(false)
    expect(reviewsAttention({ ...EMPTY_REVIEWS, toReview: [row(false)] })).toBe(false)
    expect(reviewsAttention({ ...EMPTY_REVIEWS, toReview: [row(false), row(true)] })).toBe(true)
  })

  it('reviewsAttention is true for a My PRs row that needs the user (ruling M1)', () => {
    const of = (...rows: MyPrRow[]): ReviewsSnapshot => ({ ...EMPTY_REVIEWS, mine: rows })
    expect(reviewsAttention(of(mine('waiting'), mine('fixing'), mine('error')))).toBe(false)
    expect(reviewsAttention(of(mine('waiting'), mine('needs-you')))).toBe(true)
    // An open question waits for the user, also while a round runs.
    expect(reviewsAttention(of(mine('fixing', [QUESTION])))).toBe(true)
  })

  it('two listeners share one subscription', () => {
    const { api, off } = fakeApi()
    const store = createReviewsStore(() => api)
    expect(store.get()).toBe(EMPTY_REVIEWS)
    const a = store.subscribe(() => {})
    const b = store.subscribe(() => {})
    expect(api.onUpdate).toHaveBeenCalledTimes(1)
    a()
    expect(off).not.toHaveBeenCalled()
    b()
    expect(off).toHaveBeenCalledTimes(1)
  })
})
