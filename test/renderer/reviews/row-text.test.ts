import { describe, expect, it } from 'vitest'
import {
  AUTO_FIX_HINT,
  ageText,
  approveTip,
  buttonTip,
  ciText,
  ciTip,
  claudeText,
  claudeTip,
  laterCopilotText,
  menuItems,
  mineMenuItems,
  olderText,
  resultLine,
  resultOf,
  rightText,
  rowButtons,
  rowTip,
  showSpinner,
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
    approvals: 0,
    approve: null,
    approveIssue: null,
    author: 'sam',
    ci: null,
    deletions: 1,
    draft: null,
    draftDeleted: false,
    drafted: null,
    draftIssue: null,
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
    lastError: null,
    laterCopilot: 0,
    number: 1,
    olderOpen: 0,
    owner: 'a',
    questions: [],
    repo: 'b',
    reviewers: [],
    sessionId: null,
    status: 'pending',
    title: 't',
    truncated: false,
    unsent: false,
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
    expect(toReviewText(to({ state: 'you-reviewed' }), NOW)).toBe('Review sent')
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

  it('claudeText gives Fork for a fork row', () => {
    expect(claudeText(mine({ claude: 'fork' }))).toBe('Fork')
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
  it('gives one text for each result of Claude (ruling B1)', () => {
    expect(rightText(to({ recommendation: 'request-changes', state: 'draft-ready' }), NOW)).toBe(
      'Changes required',
    )
    expect(rightText(to({ recommendation: 'comment', state: 'draft-ready' }), NOW)).toBe(
      'Draft ready',
    )
    expect(rightText(to({ recommendation: 'approve', state: 'draft-ready' }), NOW)).toBe(
      'Approval recommended',
    )
    expect(rightText(to({ recommendation: 'approve', state: 'reviewed' }), NOW)).toBe(
      'Approval recommended',
    )
    expect(rightText(to({ state: 'approved-by-others' }), NOW)).toBe('Approved by others')
    const deleted = { draftDeleted: true, recommendation: 'comment', state: 'reviewed' } as const
    expect(rightText(to(deleted), NOW)).toBe('Draft deleted')
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
    ).toBe('Claude suggests: Comment. Small risk. Click Comment to check the draft and send it.')
    expect(rowTip(to({ recommendation: 'request-changes', state: 'draft-ready' }))).toBe(
      'Claude suggests: Request changes. Click Request changes to check the draft and send it.',
    )
    expect(rowTip(to({ recommendation: 'approve', state: 'draft-ready', why: 'Fine.' }))).toBe(
      "Claude suggests: Approve. Fine. Click Approve to submit Claude's draft as an approval.",
    )
    expect(rowTip(to({ state: 'draft-ready' }))).toBeNull()
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
    expect(menuItems(to({ state: 'approved-by-others' }))).toEqual([
      'Open on GitHub',
      'Review',
      'Remove',
    ])
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
    // A draft-ready row with the mark of Bifrost has no Review: a new round would add each
    // comment a second time to the draft of Bifrost.
    const own = { recommendation: 'comment', state: 'draft-ready' } as const
    expect(menuItems(to({ ...own, sessionId: S }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Stop session',
    ])
    expect(menuItems(to(own))).toEqual(['Open on GitHub'])
    // A pending review that the user made has no mark. Review adds the comments to it.
    expect(menuItems(to({ sessionId: S, state: 'draft-ready' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Review',
      'Stop session',
    ])
    expect(menuItems(to({ state: 'draft-ready' }))).toEqual(['Open on GitHub', 'Review'])
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

describe('olderText', () => {
  it('uses the singular and the plural form', () => {
    expect(olderText(0)).toBeNull()
    expect(olderText(1)).toBe('1 older comment')
    expect(olderText(3)).toBe('3 older comments')
  })
})

describe('claudeTip', () => {
  const q = (id: string) => ({ id, question: 'q', where: 'w' })
  it('gives the tip of each state', () => {
    expect(claudeTip(mine({ claude: 'needs-you', questions: [q('a')] }))).toBe(
      'Claude needs your answer on 1 comment. Click to answer.',
    )
    expect(claudeTip(mine({ claude: 'needs-you', questions: [q('a'), q('b')] }))).toBe(
      'Claude needs your answer on 2 comments. Click to answer.',
    )
    expect(claudeTip(mine({ claude: 'fixing', fixing: 1 }))).toBe('Claude is working on 1 comment.')
    expect(claudeTip(mine({ claude: 'fixing', fixing: 4 }))).toBe(
      'Claude is working on 4 comments.',
    )
    expect(claudeTip(mine({ claude: 'queued' }))).toBe('Waiting for a free session slot.')
    expect(claudeTip(mine({ claude: 'trust-needed' }))).toBe(
      'Bifrost needs you to trust this repository first. Click Trust at the top of the panel.',
    )
    expect(claudeTip(mine({ claude: 'cloning' }))).toBe('Bifrost is copying this repository.')
    expect(claudeTip(mine({ claude: 'error', error: 'It broke.' }))).toBe('It broke.')
    expect(claudeTip(mine({ claude: 'fork', error: 'A fork.' }))).toBe('A fork.')
    expect(claudeTip(mine({ claude: 'waiting' }))).toBeNull()
  })
})

describe('mineMenuItems', () => {
  const q = { id: 'a', question: 'q', where: 'w' }
  it('gives only Open on GitHub to a plain row and to a fork row', () => {
    expect(mineMenuItems(mine({}))).toEqual(['Open on GitHub'])
    expect(
      mineMenuItems(mine({ claude: 'fork', laterCopilot: 1, olderOpen: 2, sessionId: 's' })),
    ).toEqual(['Open on GitHub'])
  })

  it('adds Handle now and Handle Copilot comments in the three states', () => {
    for (const claude of ['waiting', 'needs-you', 'error'] as const) {
      expect(mineMenuItems(mine({ claude, laterCopilot: 1, olderOpen: 2 }))).toEqual(
        expect.arrayContaining(['Handle now', 'Handle Copilot comments']),
      )
    }
    for (const claude of ['fixing', 'queued', 'cloning', 'trust-needed'] as const) {
      const items = mineMenuItems(mine({ claude, laterCopilot: 1, olderOpen: 2 }))
      expect(items).not.toContain('Handle now')
      expect(items).not.toContain('Handle Copilot comments')
    }
    expect(mineMenuItems(mine({ olderOpen: 1 }))).toEqual(['Open on GitHub', 'Handle now'])
    expect(mineMenuItems(mine({ laterCopilot: 1 }))).toEqual([
      'Open on GitHub',
      'Handle Copilot comments',
    ])
  })

  it('lists the items in order', () => {
    expect(
      mineMenuItems(mine({ claude: 'needs-you', olderOpen: 1, questions: [q], sessionId: 's' })),
    ).toEqual(['Open on GitHub', 'Open session', 'Answer Claude', 'Handle now'])
    expect(mineMenuItems(mine({ claude: 'error', olderOpen: 1, sessionId: 's' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Handle now',
      'Try again',
    ])
    expect(mineMenuItems(mine({ claude: 'fixing', sessionId: 's' }))).toEqual([
      'Open on GitHub',
      'Open session',
      'Stop session',
    ])
    expect(mineMenuItems(mine({ claude: 'fixing' }))).toEqual(['Open on GitHub'])
  })

  it('adds Cancel for queued, trust-needed and cloning', () => {
    for (const claude of ['queued', 'trust-needed', 'cloning'] as const) {
      expect(mineMenuItems(mine({ claude }))).toEqual(['Open on GitHub', 'Cancel'])
    }
  })

  it('adds Cancel to an error row with posts that Bifrost did not send', () => {
    expect(mineMenuItems(mine({ claude: 'error', unsent: true }))).toEqual([
      'Open on GitHub',
      'Try again',
      'Cancel',
    ])
    expect(mineMenuItems(mine({ claude: 'error' }))).toEqual(['Open on GitHub', 'Try again'])
    // A row that posts now has no Cancel.
    expect(mineMenuItems(mine({ claude: 'fixing', unsent: true }))).toEqual(['Open on GitHub'])
  })
})

describe('AUTO_FIX_HINT', () => {
  it('says how to turn on the automatic fixes', () => {
    expect(AUTO_FIX_HINT).toBe(
      'Want Claude to fix and answer new review comments for you? ' +
        'Turn on Handle comments on my PRs automatically in Settings.',
    )
  })

  it('shows Open session only with a session ID', () => {
    expect(mineMenuItems(mine({ sessionId: 's' }))).toEqual(['Open on GitHub', 'Open session'])
  })
})

describe('the Approve button (user decision, 2026-11-13)', () => {
  const reviewed = { recommendation: 'approve', state: 'reviewed' } as const
  const drafted = { recommendation: 'approve', state: 'draft-ready' } as const

  it('shows You approved after the approval', () => {
    expect(toReviewText(to({ state: 'you-approved' }), NOW)).toBe('You approved')
    expect(rightText(to({ state: 'you-approved' }), NOW)).toBe('You approved')
    expect(rowTip(to({ state: 'you-approved' }))).toBe('You approved this pull request on GitHub.')
  })

  it('tips the button for each kind of row and while the write runs', () => {
    expect(approveTip(to({ ...reviewed, approve: 'ready' }))).toBe(
      'Approve this pull request on GitHub.',
    )
    expect(approveTip(to({ ...drafted, approve: 'ready' }))).toBe(
      "Submit Claude's draft review on GitHub as an approval.",
    )
    expect(approveTip(to({ ...reviewed, approve: 'running' }))).toBe('Approving…')
  })

  it('shows the text of an approval that did not work in place of the state', () => {
    const failed = to({ ...reviewed, approveIssue: { message: 'GitHub said no.', unknown: false } })
    expect(rightText(failed, NOW)).toBe("Couldn't approve")
    expect(rowTip(failed)).toBe('GitHub said no.')
    const unsure = to({ ...drafted, approveIssue: { message: 'Not sure.', unknown: true } })
    expect(rightText(unsure, NOW)).toBe('Approval not confirmed')
    expect(rowTip(unsure)).toBe('Not sure.')
  })

  it('adds Approve to the menu only when the button is ready', () => {
    expect(menuItems(to({ ...reviewed, approve: 'ready' }))).toEqual([
      'Open on GitHub',
      'Approve',
      'Review',
    ])
    expect(menuItems(to({ ...drafted, approve: 'ready' }))).toEqual(['Open on GitHub', 'Approve'])
    expect(menuItems(to({ ...reviewed, approve: 'running' }))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to(reviewed))).toEqual(['Open on GitHub', 'Review'])
    expect(menuItems(to({ state: 'you-approved' }))).toEqual(['Open on GitHub', 'Review'])
  })
})

describe('the results of Claude on a row (ruling B1)', () => {
  const approve = { recommendation: 'approve', state: 'reviewed' } as const
  const approveDraft = { recommendation: 'approve', state: 'draft-ready' } as const
  const comment = { draft: 'ready', recommendation: 'comment', state: 'draft-ready' } as const
  const changes = {
    draft: 'ready',
    recommendation: 'request-changes',
    state: 'draft-ready',
  } as const
  const deleted = {
    draftDeleted: true,
    recommendation: 'request-changes',
    state: 'reviewed',
  } as const

  it('gives the kind of each row', () => {
    expect(resultOf(to(approve))).toBe('approve')
    expect(resultOf(to(approveDraft))).toBe('approve')
    expect(resultOf(to(comment))).toBe('comment')
    expect(resultOf(to(changes))).toBe('changes')
    expect(resultOf(to(deleted))).toBe('deleted')
    expect(resultOf(to({ state: 'approved-by-others' }))).toBe('others')
    for (const state of ['new', 'waiting', 'failed', 'draft-ready', 'you-approved'] as const) {
      expect(resultOf(to({ state }))).toBeNull()
    }
  })

  it('says what Claude did on the second line', () => {
    const line = (patch: Partial<ToReviewRow>) => resultLine(to(patch))
    expect(line({ ...approve, drafted: { comments: 0, summary: false } })).toBe(
      'Claude found nothing to change.',
    )
    expect(line({ ...approveDraft, drafted: { comments: 0, summary: true } })).toBe(
      'Claude drafted a summary.',
    )
    expect(line({ ...comment, drafted: { comments: 2, summary: true } })).toBe(
      'Claude drafted a summary and 2 comments.',
    )
    expect(line({ ...changes, drafted: { comments: 1, summary: true } })).toBe(
      'Claude drafted a summary and 1 comment.',
    )
    expect(line({ ...changes, drafted: { comments: 3, summary: false } })).toBe(
      'Claude drafted 3 comments.',
    )
    expect(line({ ...changes, drafted: null })).toBe('Claude drafted a review.')
    expect(line(deleted)).toBe("You deleted Claude's draft. Approve when you're ready.")
    expect(line({ approvals: 2, state: 'approved-by-others' })).toBe(
      "2 people approved it, so you don't need to review it.",
    )
    expect(line({ approvals: 1, state: 'approved-by-others' })).toBe(
      "1 person approved it, so you don't need to review it.",
    )
    expect(line({ approvals: 0, state: 'approved-by-others' })).toBe(
      "Others approved it, so you don't need to review it.",
    )
    expect(line({ state: 'new' })).toBeNull()
    expect(line({ state: 'you-reviewed' })).toBeNull()
  })

  it('gives one button for each result, and Remove only for approved-by-others', () => {
    expect(rowButtons(to({ ...approve, approve: 'ready' }))).toEqual(['Approve'])
    expect(rowButtons(to({ ...approveDraft, approve: 'running' }))).toEqual(['Approve'])
    expect(rowButtons(to(comment))).toEqual(['Comment'])
    expect(rowButtons(to({ ...changes, draft: 'running' }))).toEqual(['Request changes'])
    expect(rowButtons(to({ ...deleted, approve: 'ready' }))).toEqual(['Approve'])
    expect(rowButtons(to({ state: 'approved-by-others' }))).toEqual(['Remove'])
    expect(rowButtons(to({ state: 'new' }))).toEqual(['Review', 'Pause'])
    expect(rowButtons(to({ state: 'waiting' }))).toEqual(['Review'])
    expect(rowButtons(to({ state: 'team' }))).toEqual(['Review'])
    expect(rowButtons(to({ state: 'failed' }))).toEqual(['Try again'])
    // A reviewed row whose Approve button is hidden gets Review back.
    expect(rowButtons(to(approve))).toEqual(['Review'])
    for (const state of [
      'reviewing',
      'queued',
      'paused',
      'you-approved',
      'you-reviewed',
    ] as const) {
      expect(rowButtons(to({ state }))).toEqual([])
    }
    // An unknown result of a panel action hides the button until the next poll.
    expect(rowButtons(to({ ...comment, draft: null }))).toEqual([])
    for (const state of ['new', 'waiting', 'draft-ready', 'reviewed', 'team'] as const) {
      expect(rowButtons(to({ state }))).not.toContain('Remove')
    }
  })

  it('puts each button in the menu', () => {
    expect(menuItems(to(comment))).toEqual(['Open on GitHub', 'Comment'])
    expect(menuItems(to(changes))).toEqual(['Open on GitHub', 'Request changes'])
    expect(menuItems(to({ ...changes, draft: 'running' }))).toEqual(['Open on GitHub'])
    expect(menuItems(to({ ...deleted, approve: 'ready' }))).toEqual([
      'Open on GitHub',
      'Approve',
      'Review',
    ])
  })

  it('tips each button', () => {
    expect(buttonTip('Comment', to(comment))).toBe(
      "Check Claude's draft, change it if you like, and send it.",
    )
    expect(buttonTip('Request changes', to(changes))).toBe(
      "Check Claude's draft, change it if you like, and send it.",
    )
    const running = to({ ...comment, draft: 'running' })
    expect(buttonTip('Comment', running)).toBe('Working on the draft…')
    expect(buttonTip('Remove', to({ state: 'approved-by-others' }))).toBe(
      'Hide this pull request in Bifrost. Nothing changes on GitHub. ' +
        'It comes back if someone asks for your review again.',
    )
  })

  it('tips a deleted draft and a sent review', () => {
    expect(rowTip(to(deleted))).toBe(
      "You deleted Claude's draft. Click Approve to approve this pull request.",
    )
    expect(rowTip(to({ state: 'you-reviewed' }))).toBe('You sent your review on GitHub.')
    expect(rightText(to({ state: 'you-reviewed' }), NOW)).toBe('Review sent')
  })

  it('shows the text of a panel action that did not work in place of the state', () => {
    const issue = (action: 'send' | 'discard' | 'approve', unknown: boolean) =>
      to({ ...changes, draftIssue: { action, message: 'Why.', unknown } })
    expect(rightText(issue('send', false), NOW)).toBe("Couldn't send")
    expect(rightText(issue('discard', false), NOW)).toBe("Couldn't discard")
    expect(rightText(issue('approve', false), NOW)).toBe("Couldn't approve")
    expect(rightText(issue('send', true), NOW)).toBe('Not confirmed')
    expect(rowTip(issue('send', true))).toBe('Why.')
  })
})

describe('CI state on a row (user decision, 2026-11-13)', () => {
  const failing = (patch: Partial<ToReviewRow> = {}) => to({ ci: 'failing', ...patch })
  const running = (patch: Partial<ToReviewRow> = {}) => to({ ci: 'running', ...patch })

  it('gives the status text for failing and running CI, and null with no CI problem', () => {
    expect(ciText(failing())).toBe('CI failing')
    expect(ciText(running())).toBe('CI running')
    expect(ciText(to({}))).toBeNull()
  })

  it('shows the CI text over the other statuses of a row that waits for the user', () => {
    for (const state of ['new', 'waiting', 'team', 'failed', 'reviewed', 'draft-ready'] as const) {
      expect(rightText(failing({ state }), NOW)).toBe('CI failing')
      expect(rightText(running({ state }), NOW)).toBe('CI running')
    }
    expect(rightText(failing({ pauseEndsAt: NOW + 5 * MIN, state: 'paused' }), NOW)).toBe(
      'CI failing',
    )
  })

  it('keeps the status of a session, and of a row that needs no review', () => {
    for (const state of ['reviewing', 'queued', 'trust-needed'] as const) {
      expect(ciText(failing({ state }))).toBeNull()
      expect(ciText(running({ state }))).toBeNull()
    }
    for (const state of ['you-approved', 'you-reviewed', 'approved-by-others'] as const) {
      expect(ciText(failing({ state }))).toBeNull()
    }
    expect(rightText(failing({ state: 'reviewing' }), NOW)).toBe('Reviewing')
    expect(rightText(failing({ state: 'approved-by-others' }), NOW)).toBe('Approved by others')
  })

  it('keeps the result of Claude on the second line when CI fails', () => {
    const row = failing({
      drafted: { comments: 2, summary: true },
      recommendation: 'comment',
      state: 'draft-ready',
    })
    expect(rightText(row, NOW)).toBe('CI failing')
    expect(resultLine(row)).toBe('Claude drafted a summary and 2 comments.')
    expect(resultOf(row)).toBe('comment')
  })

  it('an action that did not work still shows its own text', () => {
    const row = failing({
      approveIssue: { message: 'CI is failing on this pull request.', unknown: false },
      state: 'reviewed',
    })
    expect(rightText(row, NOW)).toBe("Couldn't approve")
  })

  it('shows the spinner only for running CI', () => {
    expect(showSpinner(running())).toBe(true)
    expect(showSpinner(failing())).toBe(false)
    expect(showSpinner(to({}))).toBe(false)
    // No text, no spinner: a session row keeps its own status.
    expect(showSpinner(running({ state: 'reviewing' }))).toBe(false)
  })

  it('gives a Review button to no row with failing CI, and keeps Pause', () => {
    for (const state of ['new', 'waiting', 'team', 'failed', 'reviewed'] as const) {
      expect(rowButtons(failing({ state }))).not.toContain('Review')
      expect(rowButtons(failing({ state }))).not.toContain('Try again')
    }
    expect(rowButtons(failing({ state: 'new' }))).toEqual(['Pause'])
    expect(rowButtons(failing({ state: 'waiting' }))).toEqual([])
    expect(menuItems(failing({ state: 'new' }))).not.toContain('Review')
    expect(menuItems(failing({ state: 'paused' }))).not.toContain('Review')
    expect(menuItems(failing({ state: 'new' }))).toContain('Pause')
  })

  it('keeps the Review button for running CI', () => {
    expect(rowButtons(running({ state: 'new' }))).toEqual(['Review', 'Pause'])
    expect(rowButtons(running({ state: 'failed' }))).toEqual(['Try again'])
    expect(menuItems(running({ state: 'new' }))).toContain('Review')
  })

  it('keeps the draft buttons and Remove when CI fails', () => {
    const draft = failing({ draft: 'ready', recommendation: 'comment', state: 'draft-ready' })
    expect(rowButtons(draft)).toEqual(['Comment'])
    expect(rowButtons(failing({ state: 'approved-by-others' }))).toEqual(['Remove'])
  })

  it('disables the Approve button with a friendly tip while CI runs, and gives no menu item', () => {
    const row = running({ approve: 'ci-running', recommendation: 'approve', state: 'reviewed' })
    expect(rowButtons(row)).toContain('Approve')
    expect(approveTip(row)).toBe('CI is still running. Approve when it has passed.')
    expect(buttonTip('Approve', row)).toBe('CI is still running. Approve when it has passed.')
    expect(menuItems(row)).not.toContain('Approve')
  })

  it('tips the note of a dropped review before the CI tip on a failed row', () => {
    const row = failing({ error: 'CI started failing.', state: 'failed' })
    expect(rowTip(row)).toBe('CI started failing.')
  })

  it('tips the CI text', () => {
    expect(ciTip(failing())).toBe(
      "CI is failing on this pull request, so Bifrost won't review or approve it. " +
        'It can be reviewed again when CI passes.',
    )
    expect(ciTip(running())).toBe(
      'CI is still running. Claude can review now, but you can approve only when it has passed.',
    )
    expect(ciTip(to({}))).toBeNull()
    expect(rowTip(failing({ state: 'new' }))).toBe(ciTip(failing()))
  })
})
