import { describe, expect, it } from 'vitest'
import {
  baselineOf,
  buildSnapshot,
  isCopilot,
  isIgnored,
  isTrustedHuman,
  type RequestContext,
  reviewStatus,
  splitWork,
  toReviewState,
} from '../../../src/main/reviews/model'
import type {
  Author,
  PollData,
  PrComment,
  PrData,
  PrReview,
  PrThread,
} from '../../../src/main/reviews/pr-data'
import { EMPTY_STATE, emptyPrState, type PrState } from '../../../src/main/reviews/state'
import { COPILOT_LOGIN } from '../../../src/shared/reviews'

const VIEWER = 'dev-user'
const NONE = new Set<string>()

const member: Author = { association: 'MEMBER', bot: false, login: 'alice' }
const outsider: Author = { association: 'NONE', bot: false, login: 'mallory' }
const viewer: Author = { association: 'OWNER', bot: false, login: VIEWER }
const copilot: Author = { association: 'NONE', bot: true, login: COPILOT_LOGIN }
const otherBot: Author = { association: 'NONE', bot: true, login: 'dependabot' }

function comment(id: string, author: Author, createdAt = 100): PrComment {
  return { author, body: 'text', createdAt, databaseId: 1, id }
}

function thread(id: string, author: Author, over: Partial<PrThread> = {}): PrThread {
  return {
    comments: [comment(`${id}-c1`, author)],
    id,
    isResolved: false,
    line: 1,
    path: 'a.ts',
    reviewId: null,
    ...over,
  }
}

function review(id: string, author: Author, over: Partial<PrReview> = {}): PrReview {
  return {
    author,
    body: '',
    commit: null,
    databaseId: 1,
    id,
    state: 'COMMENTED',
    submittedAt: 1000,
    ...over,
  }
}

function pr(over: Partial<PrData> = {}): PrData {
  return {
    additions: 1,
    author: VIEWER,
    baseRef: 'main',
    comments: [],
    createdAt: 1,
    decisions: [],
    deletions: 1,
    failedChecks: 0,
    headRef: 'f',
    headSha: 'abc',
    isCrossRepository: false,
    isDraft: false,
    key: 'acme/app#1',
    number: 1,
    owner: 'acme',
    repo: 'app',
    requestedAt: 1,
    requestedTeams: [],
    requestedUsers: [],
    reviewDecision: null,
    reviews: [],
    threads: [],
    title: 't',
    truncatedChecks: false,
    truncatedComments: false,
    truncatedReviews: false,
    truncatedThreads: false,
    updatedAt: 5,
    url: 'https://github.com/acme/app/pull/1',
    viewerPendingReviewId: null,
    ...over,
  }
}

function ids(items: { id: string }[]): string[] {
  return items.map(i => i.id)
}

function prState(over: Partial<PrState> = {}): PrState {
  return { ...emptyPrState(), ...over }
}

describe('author tests', () => {
  it('knows Copilot and trusted humans', () => {
    expect(isCopilot(copilot)).toBe(true)
    expect(isCopilot(otherBot)).toBe(false)
    expect(isTrustedHuman(member, VIEWER)).toBe(true)
    expect(isTrustedHuman(copilot, VIEWER)).toBe(false)
    expect(isTrustedHuman(outsider, VIEWER)).toBe(false)
    expect(isTrustedHuman(viewer, VIEWER)).toBe(false)
  })
})

describe('splitWork', () => {
  it('a MEMBER thread is work and an outsider thread is not', () => {
    const p = pr({ threads: [thread('t1', member), thread('t2', outsider)] })
    const split = splitWork(p, VIEWER, prState(), NONE, null)
    expect(split.work).toEqual([{ id: 't1', kind: 'thread' }])
    expect(split.older).toEqual([])
    expect(split.laterCopilot).toEqual([])
  })

  it('a thread with no comments, or a resolved thread, is not work', () => {
    const p = pr({
      threads: [thread('t1', member, { comments: [] }), thread('t2', member, { isResolved: true })],
    })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([])
  })

  it('only the first Copilot review gives work; later Copilot threads count as laterCopilot', () => {
    const p = pr({
      reviews: [
        review('r2', copilot, { submittedAt: 2000 }),
        review('r1', copilot, { submittedAt: 1000 }),
      ],
      threads: [
        thread('t1', copilot, { reviewId: 'r1' }),
        thread('t2', copilot, { reviewId: 'r2' }),
      ],
    })
    const split = splitWork(p, VIEWER, prState(), NONE, null)
    expect(ids(split.work)).toEqual(['t1'])
    expect(ids(split.laterCopilot)).toEqual(['t2'])
    const again = splitWork(p, VIEWER, prState({ handleCopilot: true }), NONE, null)
    expect(ids(again.work)).toEqual(['t1', 't2'])
    expect(again.laterCopilot).toEqual([])
  })

  it('a handled thread is work again only after a trusted comment newer than lastReplyAt', () => {
    const t = thread('t1', member, {
      comments: [comment('c1', member, 100), comment('c2', outsider, 300)],
    })
    const handled = (lastReplyAt: number | null): PrState =>
      prState({ handled: { t1: { at: 150, lastReplyAt } } })
    expect(splitWork(pr({ threads: [t] }), VIEWER, handled(200), NONE, null).work).toEqual([])
    const t2 = { ...t, comments: [...t.comments, comment('c3', member, 400)] }
    expect(ids(splitWork(pr({ threads: [t2] }), VIEWER, handled(200), NONE, null).work)).toEqual([
      't1',
    ])
    expect(splitWork(pr({ threads: [t2] }), VIEWER, handled(500), NONE, null).work).toEqual([])
    expect(splitWork(pr({ threads: [t2] }), VIEWER, handled(null), NONE, null).work).toEqual([])
  })

  it("the viewer's own comments are never work", () => {
    const p = pr({
      comments: [comment('pc1', viewer)],
      reviews: [review('r1', viewer, { body: 'note' })],
      threads: [thread('t1', viewer)],
    })
    const split = splitWork(p, VIEWER, prState(), NONE, null)
    expect(split.work).toEqual([])
    expect(split.older).toEqual([])
  })

  it('an empty review body is not work, a CHANGES_REQUESTED body from a MEMBER is', () => {
    const p = pr({
      reviews: [
        review('r1', member, { body: '   ' }),
        review('r2', member, { body: 'Please fix', state: 'CHANGES_REQUESTED' }),
        review('r3', outsider, { body: 'hi' }),
        review('r4', copilot, { body: 'summary' }),
        review('r5', otherBot, { body: 'bot' }),
      ],
    })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([
      { id: 'r2', kind: 'review-body' },
    ])
  })

  it('a PR comment from a trusted human is work, from a bot or outsider it is not', () => {
    const p = pr({
      comments: [comment('pc1', member), comment('pc2', outsider), comment('pc3', otherBot)],
    })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([
      { id: 'pc1', kind: 'comment' },
    ])
  })

  it('baseline items go to older', () => {
    const p = pr({
      comments: [comment('pc1', member)],
      threads: [thread('t1', member), thread('t2', member)],
    })
    const split = splitWork(p, VIEWER, prState(), new Set(['t1', 'pc1']), null)
    expect(ids(split.work)).toEqual(['t2'])
    expect(ids(split.older).sort()).toEqual(['pc1', 't1'])
    const now = splitWork(p, VIEWER, prState({ handleOlder: true }), new Set(['t1', 'pc1']), null)
    expect(now.older).toEqual([])
    expect(ids(now.work).sort()).toEqual(['pc1', 't1', 't2'])
  })
})

describe('reviewStatus', () => {
  const status = (p: PrData, state: PrState = prState(), baseline = NONE) =>
    reviewStatus(p, VIEWER, splitWork(p, VIEWER, state, baseline, null))

  it('reviewStatus: changes requested wins over open threads', () => {
    const p = pr({
      decisions: [review('r1', member, { state: 'CHANGES_REQUESTED' })],
      threads: [thread('t1', member)],
    })
    expect(status(p)).toBe('changes-requested')
  })

  it('an APPROVED review body is not work, so an approved PR with no open thread gives approved', () => {
    const p = pr({
      reviews: [
        review('r1', member, { body: 'LGTM', state: 'APPROVED' }),
        review('r2', outsider, { body: 'x', state: 'DISMISSED' }),
        review('r3', member, { body: 'x', state: 'DISMISSED', submittedAt: 5 }),
      ],
    })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([])
    const lgtm = review('r1', member, { body: 'LGTM', state: 'APPROVED' })
    expect(status(pr({ decisions: [lgtm], reviews: [lgtm] }))).toBe('approved')
  })

  it('the latest review of a reviewer counts', () => {
    const p = pr({
      decisions: [
        review('r1', member, { state: 'CHANGES_REQUESTED', submittedAt: 1 }),
        review('r2', member, { state: 'APPROVED', submittedAt: 2 }),
      ],
    })
    expect(status(p)).toBe('approved')
  })

  it('reviewStatus: open Copilot thread gives comments, Copilot approval never gives approved', () => {
    const open = pr({
      reviews: [review('r1', copilot)],
      threads: [thread('t1', copilot, { reviewId: 'r1' })],
    })
    expect(status(open)).toBe('comments')
    const approved = pr({ decisions: [review('r1', copilot, { state: 'APPROVED' })] })
    expect(status(approved)).toBe('pending')
  })

  it('reviewStatus: an open thread of a later Copilot review alone gives pending, not comments', () => {
    const p = pr({
      reviews: [
        review('r1', copilot, { submittedAt: 1 }),
        review('r2', copilot, { submittedAt: 2 }),
      ],
      threads: [thread('t2', copilot, { reviewId: 'r2' })],
    })
    expect(status(p)).toBe('pending')
  })

  it('reviewStatus: approved with all threads resolved gives approved; no reviewer gives pending', () => {
    const approved = pr({
      decisions: [review('r1', member, { state: 'APPROVED' })],
      threads: [thread('t1', member, { isResolved: true })],
    })
    expect(status(approved)).toBe('approved')
    expect(status(pr())).toBe('pending')
  })

  it('an older open thread gives comments, a top-level work item does not', () => {
    const p = pr({
      decisions: [review('r1', member, { state: 'APPROVED' })],
      threads: [thread('t1', member)],
    })
    expect(status(p, prState(), new Set(['t1']))).toBe('comments')
    const q = pr({
      comments: [comment('pc1', member)],
      decisions: [review('r1', member, { state: 'APPROVED' })],
    })
    // The comment stays work for a later round, but it does not change the status word.
    expect(ids(splitWork(q, VIEWER, prState(), NONE, null).work)).toEqual(['pc1'])
    expect(status(q)).toBe('approved')
    expect(status(q, prState({ handled: { pc1: { at: 1, lastReplyAt: null } } }))).toBe('approved')
  })

  it('a CHANGES_REQUESTED body followed by an approval gives approved', () => {
    const approval = review('r2', member, { state: 'APPROVED', submittedAt: 2 })
    const p = pr({
      decisions: [approval],
      reviews: [
        review('r1', member, { body: 'Please fix', state: 'CHANGES_REQUESTED', submittedAt: 1 }),
        approval,
      ],
    })
    expect(ids(splitWork(p, VIEWER, prState(), NONE, null).work)).toEqual(['r1'])
    expect(status(p)).toBe('approved')
  })

  it("an approved PR with a member's Thanks comment gives approved", () => {
    const p = pr({
      comments: [{ ...comment('pc1', member), body: 'Thanks!' }],
      decisions: [review('r1', member, { state: 'APPROVED' })],
    })
    expect(status(p)).toBe('approved')
  })

  it('takes the decisions from latestOpinionatedReviews, not from the first 30 reviews', () => {
    // The first page of reviews has an old request for changes. The newest decision is an
    // approval that is not on the first page.
    const p = pr({
      decisions: [review('r40', member, { state: 'APPROVED', submittedAt: 40 })],
      reviews: [review('r1', member, { state: 'CHANGES_REQUESTED', submittedAt: 1 })],
    })
    expect(status(p)).toBe('approved')
    const q = pr({ decisions: [review('r40', member, { state: 'CHANGES_REQUESTED' })] })
    expect(status(q)).toBe('changes-requested')
  })

  it('a top-level work item alone gives pending, not comments', () => {
    const p = pr({
      comments: [comment('pc1', member)],
      reviews: [review('r1', member, { body: 'See below', state: 'COMMENTED' })],
    })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toHaveLength(2)
    expect(status(p)).toBe('pending')
  })
})

describe('toReviewState', () => {
  const direct = pr({ requestedUsers: [VIEWER] })
  const ctx = (over: Partial<RequestContext> = {}): RequestContext => ({
    known: undefined,
    now: 1000,
    pauseEndsAt: null,
    session: null,
    teamRequests: true,
    ...over,
  })

  it('toReviewState: precedence session > draft-ready > paused > approved-by-others > team > waiting > new', () => {
    const full = pr({
      requestedUsers: [VIEWER],
      reviewDecision: 'APPROVED',
      viewerPendingReviewId: 'rv',
    })
    const base = ctx({ known: { baseline: true }, pauseEndsAt: 2000 })
    expect(toReviewState(full, VIEWER, { ...base, session: 'reviewing' })).toBe('reviewing')
    expect(toReviewState(full, VIEWER, { ...base, session: 'queued' })).toBe('queued')
    expect(toReviewState(full, VIEWER, base)).toBe('draft-ready')
    const noDraft = { ...full, viewerPendingReviewId: null }
    expect(toReviewState(noDraft, VIEWER, base)).toBe('paused')
    expect(toReviewState(noDraft, VIEWER, { ...base, pauseEndsAt: 1000 })).toBe(
      'approved-by-others',
    )
    const team = pr({ requestedTeams: ['core'], reviewDecision: 'APPROVED' })
    expect(toReviewState(team, VIEWER, ctx())).toBe('approved-by-others')
    expect(toReviewState({ ...team, reviewDecision: null }, VIEWER, ctx())).toBe('team')
    expect(toReviewState(direct, VIEWER, ctx({ known: { baseline: true } }))).toBe('waiting')
    expect(toReviewState(direct, VIEWER, ctx({ known: { baseline: false } }))).toBe('new')
    expect(toReviewState(direct, VIEWER, ctx())).toBe('new')
  })

  it('toReviewState: a team request is null when teamRequests is off', () => {
    const team = pr({ requestedTeams: ['core'] })
    expect(toReviewState(team, VIEWER, ctx({ teamRequests: false }))).toBeNull()
    expect(toReviewState(direct, VIEWER, ctx({ teamRequests: false }))).toBe('new')
  })

  it('toReviewState: teamRequests off hides a paused team request but keeps a session', () => {
    const off = ctx({ teamRequests: false })
    const team = pr({ requestedTeams: ['core'] })
    expect(toReviewState(team, VIEWER, { ...off, pauseEndsAt: 2000 })).toBeNull()
    expect(toReviewState({ ...team, reviewDecision: 'APPROVED' }, VIEWER, off)).toBeNull()
    expect(toReviewState(team, VIEWER, { ...off, session: 'reviewing' })).toBe('reviewing')
    expect(toReviewState(team, VIEWER, { ...off, session: 'queued' })).toBe('queued')
  })
})

describe('isIgnored', () => {
  it('isIgnored matches owner/* and owner/repo, case-insensitive', () => {
    expect(isIgnored('Acme', 'App', ['acme/*'])).toBe(true)
    expect(isIgnored('acme', 'app', ['ACME/App'])).toBe(true)
    expect(isIgnored('acme', 'app', ['acme/other', 'other/*'])).toBe(false)
    expect(isIgnored('acme', 'app', [])).toBe(false)
  })
})

describe('buildSnapshot', () => {
  const settings = { reviewsIgnore: [] as string[], reviewsTeamRequests: true }
  const waiting = { claude: 'waiting' as const, error: null, fixing: 0, sessionId: null }

  function input(poll: PollData, over: Partial<Parameters<typeof buildSnapshot>[0]> = {}) {
    return {
      claude: () => waiting,
      now: 5000,
      poll,
      session: () => null,
      settings,
      state: structuredClone(EMPTY_STATE),
      ...over,
    }
  }

  it('buildSnapshot: an ignored repo shows in neither list', () => {
    const poll: PollData = {
      mine: [
        pr({ key: 'acme/app#2', number: 2 }),
        pr({ key: 'keep/app#3', number: 3, owner: 'keep' }),
      ],
      toReview: [pr({ key: 'acme/app#1', requestedUsers: [VIEWER] })],
      viewer: VIEWER,
    }
    const snap = buildSnapshot(
      input(poll, { settings: { ...settings, reviewsIgnore: ['acme/*'] } }),
    )
    expect(snap.toReview).toEqual([])
    expect(snap.mine.map(r => r.key)).toEqual(['keep/app#3'])
  })

  it('builds rows, flash, reviewers and counts', () => {
    const mine = pr({
      key: 'acme/app#2',
      number: 2,
      requestedUsers: ['bob', COPILOT_LOGIN],
      reviews: [
        review('r1', copilot, { submittedAt: 1 }),
        review('r2', copilot, { submittedAt: 2 }),
        review('r3', member, { state: 'APPROVED' }),
        review('r4', viewer),
      ],
      threads: [
        thread('t1', member),
        thread('t2', member),
        thread('t3', copilot, { reviewId: 'r2' }),
      ],
    })
    const poll: PollData = {
      mine: [mine],
      toReview: [
        pr({ key: 'acme/app#1', requestedAt: 50, requestedUsers: [VIEWER] }),
        pr({ key: 'acme/app#9', number: 9, requestedAt: 10, requestedUsers: [VIEWER] }),
      ],
      viewer: VIEWER,
    }
    const state = structuredClone(EMPTY_STATE)
    state.baseline = ['t1']
    state.requests['acme/app#9'] = { baseline: true, firstSeen: 1 }
    const snap = buildSnapshot(input(poll, { state }))
    expect(snap.availability).toBe('ok')
    expect(snap.polledAt).toBe(5000)
    expect(snap.toReview.map(r => [r.key, r.state, r.flash])).toEqual([
      ['acme/app#1', 'new', true],
      ['acme/app#9', 'waiting', false],
    ])
    const row = snap.mine[0]
    expect(row?.status).toBe('comments')
    expect(row?.reviewers).toEqual(['bob', 'Copilot', 'alice'])
    expect(row?.laterCopilot).toBe(1)
    expect(row?.olderOpen).toBe(1)
    expect(row?.claude).toBe('waiting')
  })
})

describe('buildSnapshot of a busy PR', () => {
  const input = (mine: PrData[]) => ({
    claude: () => ({ claude: 'waiting' as const, error: null, fixing: 0, sessionId: null }),
    now: 5000,
    poll: { mine, toReview: [], viewer: VIEWER },
    session: () => null,
    settings: { reviewsIgnore: [] as string[], reviewsTeamRequests: true },
    state: structuredClone(EMPTY_STATE),
  })

  it('a My PRs row is truncated when one of its lists is cut', () => {
    const flags = [
      'truncatedThreads',
      'truncatedReviews',
      'truncatedComments',
      'truncatedChecks',
    ] as const
    const rows = buildSnapshot(
      input([
        pr({ key: 'acme/app#1', number: 1 }),
        ...flags.map((flag, i) => pr({ key: `acme/app#${i + 2}`, number: i + 2, [flag]: true })),
      ]),
    ).mine
    expect(rows.map(r => [r.key, r.truncated]).sort()).toEqual([
      ['acme/app#1', false],
      ['acme/app#2', true],
      ['acme/app#3', true],
      ['acme/app#4', true],
      ['acme/app#5', true],
    ])
  })

  it('a reviewer with only a decision shows in the reviewers', () => {
    const p = pr({ decisions: [review('r9', member, { state: 'APPROVED' })] })
    expect(buildSnapshot(input([p])).mine[0]?.reviewers).toEqual(['alice'])
  })
})

describe('baselineOf', () => {
  it('collects the open items of My PRs and the To review keys', () => {
    const poll: PollData = {
      mine: [pr({ comments: [comment('pc1', member)], threads: [thread('t1', member)] })],
      toReview: [pr({ key: 'acme/app#7' }), pr({ key: 'acme/app#8' })],
      viewer: VIEWER,
    }
    const b = baselineOf(poll)
    expect([...b.items].sort()).toEqual(['pc1', 't1'])
    expect(b.requests).toEqual(['acme/app#7', 'acme/app#8'])
  })

  it('adds the visible items of a truncated PR to the baseline', () => {
    const poll: PollData = {
      mine: [pr({ threads: [thread('t1', member)], truncatedThreads: true })],
      toReview: [],
      viewer: VIEWER,
    }
    expect(baselineOf(poll).items).toEqual(['t1'])
  })
})

describe('splitWork pins', () => {
  it('an item created before the first turn-on and not in the baseline is older', () => {
    const p = pr({
      comments: [comment('pc1', member, 50), comment('pc2', member, 500)],
      threads: [thread('t1', member, { comments: [comment('c1', member, 60)] })],
    })
    const split = splitWork(p, VIEWER, prState(), NONE, 100)
    expect(ids(split.older).sort()).toEqual(['pc1', 't1'])
    expect(ids(split.work)).toEqual(['pc2'])
    expect(ids(splitWork(p, VIEWER, prState({ handleOlder: true }), NONE, 100).older)).toEqual([])
  })

  it('a handled thread from a later Copilot review with a newer MEMBER comment is work', () => {
    const reviews = [
      review('r1', copilot, { submittedAt: 1 }),
      review('r2', copilot, { submittedAt: 2 }),
    ]
    const t = thread('t2', copilot, {
      comments: [comment('c1', copilot, 100), comment('c2', member, 400)],
      reviewId: 'r2',
    })
    const handled = prState({ handled: { t2: { at: 150, lastReplyAt: 200 } } })
    expect(ids(splitWork(pr({ reviews, threads: [t] }), VIEWER, handled, NONE, null).work)).toEqual(
      ['t2'],
    )
    const never = splitWork(pr({ reviews, threads: [t] }), VIEWER, prState(), NONE, null)
    expect(ids(never.laterCopilot)).toEqual(['t2'])
    expect(never.work).toEqual([])
  })

  it('a reopened item in the baseline goes to work, not older', () => {
    const t = thread('t1', member, {
      comments: [comment('c1', member, 100), comment('c2', member, 400)],
    })
    const handled = prState({ handled: { t1: { at: 150, lastReplyAt: 200 } } })
    const split = splitWork(pr({ threads: [t] }), VIEWER, handled, new Set(['t1']), 1000)
    expect(ids(split.work)).toEqual(['t1'])
    expect(split.older).toEqual([])
  })

  it('a non-empty COMMENTED body from a trusted human is work', () => {
    const p = pr({ reviews: [review('r1', member, { body: 'See below', state: 'COMMENTED' })] })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([
      { id: 'r1', kind: 'review-body' },
    ])
  })

  it('a COMMENTED or PENDING review after a decision does not change the decision', () => {
    const later = [
      review('r2', member, { state: 'COMMENTED', submittedAt: 9 }),
      review('r3', member, { state: 'PENDING', submittedAt: 10 }),
    ]
    const cr = pr({
      decisions: [review('r1', member, { state: 'CHANGES_REQUESTED', submittedAt: 1 }), ...later],
    })
    const ap = pr({
      decisions: [review('r1', member, { state: 'APPROVED', submittedAt: 1 }), ...later],
    })
    const st = (p: PrData) => reviewStatus(p, VIEWER, { laterCopilot: [], older: [], work: [] })
    expect(st(cr)).toBe('changes-requested')
    expect(st(ap)).toBe('approved')
  })

  it('an older top-level item does not give comments', () => {
    const p = pr({
      comments: [comment('pc1', member)],
      decisions: [review('r1', member, { state: 'APPROVED' })],
    })
    const split = splitWork(p, VIEWER, prState(), new Set(['pc1']), null)
    expect(ids(split.older)).toEqual(['pc1'])
    expect(reviewStatus(p, VIEWER, split)).toBe('approved')
  })
})
