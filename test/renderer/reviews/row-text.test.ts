import { describe, expect, it } from 'vitest'
import {
  ageText,
  claudeText,
  laterCopilotText,
  sizeText,
  statusText,
  toReviewText,
} from '../../../src/renderer/src/reviews/row-text'
import type { MyPrRow, ToReviewRow } from '../../../src/shared/reviews'

const MIN = 60_000
const NOW = 1_000_000_000

function to(patch: Partial<ToReviewRow>): ToReviewRow {
  return {
    additions: 1,
    author: 'sam',
    deletions: 1,
    flash: false,
    key: 'a/b#1',
    number: 1,
    owner: 'a',
    pauseEndsAt: null,
    repo: 'b',
    requestedAt: NOW,
    sessionId: null,
    state: 'new',
    title: 't',
    ...patch,
  }
}

function mine(patch: Partial<MyPrRow>): MyPrRow {
  return {
    claude: 'waiting',
    error: null,
    failedChecks: 0,
    fixing: 0,
    key: 'a/b#1',
    laterCopilot: 0,
    number: 1,
    olderOpen: 0,
    owner: 'a',
    repo: 'b',
    reviewers: [],
    sessionId: null,
    status: 'pending',
    title: 't',
    updatedAt: NOW,
    ...patch,
  }
}

describe('row text', () => {
  it('ageText', () => {
    expect(ageText(0)).toBe('just now')
    expect(ageText(59_999)).toBe('just now')
    expect(ageText(15 * MIN)).toBe('15m ago')
    expect(ageText(2 * 60 * MIN)).toBe('2h ago')
    expect(ageText(3 * 24 * 60 * MIN)).toBe('3d ago')
    expect(ageText(-5)).toBe('just now')
  })

  it('sizeText uses the minus sign U+2212', () => {
    expect(sizeText(184, 22)).toBe('+184 −22')
  })

  it('toReviewText', () => {
    expect(toReviewText(to({ state: 'draft-ready' }), NOW)).toBe('Draft ready')
    expect(toReviewText(to({ state: 'waiting' }), NOW)).toBe('Waiting for you')
    expect(toReviewText(to({ state: 'reviewing' }), NOW)).toBe('Reviewing')
    expect(toReviewText(to({ state: 'queued' }), NOW)).toBe('Queued')
    expect(toReviewText(to({ pauseEndsAt: NOW + 42 * MIN, state: 'paused' }), NOW)).toBe(
      'Paused 42m',
    )
    expect(toReviewText(to({ pauseEndsAt: NOW + 30_000, state: 'paused' }), NOW)).toBe('Paused 1m')
    expect(toReviewText(to({ state: 'approved-by-others' }), NOW)).toBe('Approved by others')
    expect(toReviewText(to({ state: 'team' }), NOW)).toBe('Team request')
    expect(toReviewText(to({ state: 'new' }), NOW)).toBe('')
  })

  it('statusText', () => {
    expect(statusText('changes-requested')).toBe('Changes requested')
    expect(statusText('comments')).toBe('Comments')
    expect(statusText('approved')).toBe('Approved')
    expect(statusText('pending')).toBe('Pending')
  })

  it('claudeText', () => {
    expect(claudeText(mine({ claude: 'needs-you' }))).toBe('Needs you')
    expect(claudeText(mine({ claude: 'fixing', fixing: 3 }))).toBe('Fixing 3')
    expect(claudeText(mine({ claude: 'queued' }))).toBe('Queued')
    expect(claudeText(mine({ claude: 'trust-needed' }))).toBe('Trust needed')
    expect(claudeText(mine({ claude: 'cloning' }))).toBe('Cloning')
    expect(claudeText(mine({ claude: 'waiting' }))).toBe('Waiting')
    expect(claudeText(mine({ claude: 'error' }))).toBe('Error')
  })

  it('laterCopilotText', () => {
    expect(laterCopilotText(0)).toBeNull()
    expect(laterCopilotText(3)).toBe('Copilot: 3 more')
  })
})
