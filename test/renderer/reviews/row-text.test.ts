import { describe, expect, it } from 'vitest'
import {
  ageText,
  claudeText,
  laterCopilotText,
  menuItems,
  rightText,
  rowTip,
  sizeText,
  statusText,
  toReviewText,
  truncatedText,
} from '../../../src/renderer/src/reviews/row-text'
import type { MyPrRow, ToReviewRow } from '../../../src/shared/reviews'

const MIN = 60_000
const NOW = 1_000_000_000

function to(patch: Partial<ToReviewRow>): ToReviewRow {
  return {
    additions: 1,
    author: 'sam',
    deletions: 1,
    error: null,
    flash: false,
    key: 'a/b#1',
    number: 1,
    owner: 'a',
    pauseEndsAt: null,
    recommendation: null,
    repo: 'b',
    requestedAt: NOW,
    sessionId: null,
    state: 'new',
    team: false,
    title: 't',
    why: null,
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
    truncated: false,
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
    expect(toReviewText(to({ state: 'reviewed' }), NOW)).toBe('Looks good')
    expect(toReviewText(to({ state: 'failed' }), NOW)).toBe('Review failed')
    expect(toReviewText(to({ state: 'trust-needed' }), NOW)).toBe('Trust needed')
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

  it('truncatedText gives the tip only for a row that GitHub cut', () => {
    expect(truncatedText(mine({}))).toBeNull()
    expect(truncatedText(mine({ truncated: true }))).toBe(
      'Bifrost read only the newest items of this PR.',
    )
  })

  it('laterCopilotText', () => {
    expect(laterCopilotText(0)).toBeNull()
    expect(laterCopilotText(3)).toBe('Copilot: 3 more')
  })
})

describe('rightText', () => {
  it('adds the recommendation to a draft or a reviewed row', () => {
    expect(rightText(to({ recommendation: 'request-changes', state: 'draft-ready' }), NOW)).toBe(
      'Draft ready · Request changes',
    )
    expect(rightText(to({ recommendation: 'approve', state: 'reviewed' }), NOW)).toBe(
      'Looks good · Approve',
    )
  })

  it('adds nothing without a recommendation or in another state', () => {
    expect(rightText(to({ state: 'draft-ready' }), NOW)).toBe('Draft ready')
    expect(rightText(to({ recommendation: 'comment', state: 'failed' }), NOW)).toBe('Review failed')
  })
})

describe('rowTip', () => {
  it('explains a draft', () => {
    expect(
      rowTip(to({ recommendation: 'comment', state: 'draft-ready', why: 'Small risk.' })),
    ).toBe('Claude suggests: Comment. Small risk. Check the draft on GitHub, then submit it.')
  })

  it('explains a reviewed row', () => {
    expect(rowTip(to({ state: 'reviewed', why: 'Clean.' }))).toBe(
      'Claude suggests: Approve. Clean. Nothing was posted.',
    )
  })

  it('gives the error of a failed row as it is', () => {
    expect(
      rowTip(to({ error: 'Bifrost cannot tell if the draft was saved.', state: 'failed' })),
    ).toBe('Bifrost cannot tell if the draft was saved.')
  })

  it('gives the texts of the waiting states', () => {
    expect(rowTip(to({ state: 'trust-needed' }))).toBe(
      'Bifrost needs you to trust this repository first. Click Trust at the top of the panel.',
    )
    expect(rowTip(to({ state: 'queued' }))).toBe('Waiting for a free review slot.')
    expect(rowTip(to({ state: 'reviewing' }))).toBe('Claude is reviewing this pull request.')
  })

  it('gives null for the other states', () => {
    for (const state of ['new', 'waiting', 'paused', 'team', 'approved-by-others'] as const) {
      expect(rowTip(to({ state }))).toBeNull()
    }
  })
})

describe('menuItems', () => {
  const S = 's1'
  it('lists the items of each state in order', () => {
    expect(menuItems(to({ state: 'new' }))).toEqual(['Open on GitHub', 'Review', 'Pause'])
    expect(menuItems(to({ state: 'paused' }))).toEqual([
      'Open on GitHub',
      'Review',
      'End pause now',
    ])
    expect(menuItems(to({ state: 'waiting' }))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to({ state: 'team' }))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to({ state: 'approved-by-others' }))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to({ state: 'queued' }))).toEqual(['Open on GitHub', 'Cancel review'])
    expect(menuItems(to({ state: 'trust-needed' }))).toEqual(['Open on GitHub', 'Cancel review'])
    expect(menuItems(to({ state: 'reviewing' }))).toEqual(['Open on GitHub'])
  })

  it('adds the session items only for a row with a session', () => {
    expect(menuItems(to({ sessionId: S, state: 'reviewing' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Stop session',
    ])
    // A draft-ready row has no Review: a new round would add each comment a second time.
    expect(menuItems(to({ sessionId: S, state: 'draft-ready' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Stop session',
    ])
    expect(menuItems(to({ state: 'draft-ready' }))).toEqual(['Open on GitHub'])
    expect(menuItems(to({ sessionId: S, state: 'failed' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Review',
      'Stop session',
    ])
    expect(menuItems(to({ state: 'reviewed' }))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to({ sessionId: S, state: 'queued' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Cancel review',
      'Stop session',
    ])
  })
})
