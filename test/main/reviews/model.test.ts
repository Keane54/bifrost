import { describe, expect, it } from 'vitest'
import {
  approvedOnHead,
  autoFixOn,
  baselineOf,
  buildSnapshot,
  type DraftEntry,
  isCopilot,
  isIgnored,
  isTrustedHuman,
  needsRound,
  outcomeOf,
  reviewStatus,
  splitWork,
  type ToReviewContext,
  toReviewState,
  viewerApproved,
  workSince,
} from '../../../src/main/reviews/model'
import type {
  Author,
  PollData,
  PrComment,
  PrData,
  PrReview,
  PrThread,
  ReviewState,
  ViewerOpinion,
} from '../../../src/main/reviews/pr-data'
import {
  EMPTY_STATE,
  emptyPrState,
  handledEntry,
  type Outbox,
  type PrState,
  type Question,
  type RecommendationMark,
} from '../../../src/main/reviews/state'
import { COPILOT_LOGIN, PR_KEY, REPO_KEY, repoOf } from '../../../src/shared/reviews'

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
    approvals: 0,
    author: VIEWER,
    baseRef: 'main',
    ci: null,
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
    viewerReviews: [],
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

  it('a comment of the viewer with another case of the login is never trusted work', () => {
    const upper = { ...viewer, login: viewer.login.toUpperCase() }
    expect(isTrustedHuman(upper, VIEWER)).toBe(false)
    expect(isTrustedHuman(viewer, VIEWER.toUpperCase())).toBe(false)
    const p = pr({ threads: [thread('t1', upper)] })
    expect(splitWork(p, VIEWER, prState(), NONE, null).work).toEqual([])
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

function snapshotInput(poll: PollData, state: typeof EMPTY_STATE) {
  return {
    claude: () => ({ claude: 'waiting' as const, error: null, fixing: 0, sessionId: null }),
    now: 5000,
    poll,
    pollStartedAt: 0,
    session: () => null,
    sessionOf: () => null,
    settings: { reviewsAutoFix: true, reviewsIgnore: [] as string[], reviewsTeamRequests: true },
    state,
    trust: [],
  }
}

describe('toReviewState', () => {
  const direct = pr({ requestedUsers: [VIEWER] })
  const ctx = (over: Partial<ToReviewContext> = {}): ToReviewContext => ({
    acted: false,
    known: undefined,
    now: 1000,
    outcome: null,
    pauseEndsAt: null,
    session: null,
    teamRequests: true,
    ...over,
  })

  it(
    'toReviewState: precedence session > draft-ready > reviewed > failed > ' +
      'paused > approved-by-others > team > waiting > new',
    () => {
      const full = pr({
        requestedUsers: [VIEWER],
        reviewDecision: 'APPROVED',
        viewerPendingReviewId: 'rv',
      })
      const base = ctx({ known: { baseline: true }, pauseEndsAt: 2000 })
      expect(toReviewState(full, VIEWER, { ...base, session: 'reviewing' })).toBe('reviewing')
      expect(toReviewState(full, VIEWER, { ...base, session: 'queued' })).toBe('queued')
      expect(toReviewState(full, VIEWER, { ...base, session: 'trust-needed' })).toBe('trust-needed')
      expect(toReviewState(full, VIEWER, base)).toBe('draft-ready')
      const noDraft = { ...full, viewerPendingReviewId: null }
      expect(toReviewState(noDraft, VIEWER, { ...base, outcome: 'drafted' })).toBe('draft-ready')
      expect(toReviewState(noDraft, VIEWER, { ...base, outcome: 'reviewed' })).toBe('reviewed')
      expect(toReviewState(noDraft, VIEWER, { ...base, outcome: 'failed' })).toBe('failed')
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
    },
  )

  it('an acted request is waiting, not new, and does not flash', () => {
    expect(toReviewState(direct, VIEWER, ctx({ acted: true }))).toBe('waiting')
    const state = structuredClone(EMPTY_STATE)
    state.requests['acme/app#1'] = { baseline: false, firstSeen: 100 }
    state.prs['acme/app#1'] = { ...emptyPrState(), actedAt: 100 }
    const poll: PollData = {
      errors: [],
      mine: [],
      mineHasMore: false,
      rateLimit: null,
      toReview: [pr({ requestedUsers: [VIEWER] })],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    const row = (s: typeof state) => buildSnapshot(snapshotInput(poll, s)).toReview[0]
    expect(row(state)?.state).toBe('waiting')
    expect(row(state)?.flash).toBe(false)
    state.prs['acme/app#1'] = { ...emptyPrState(), actedAt: 99 }
    expect(row(state)?.state).toBe('new')
  })

  it('outcomeOf: drafted only while the poll is older than the mark', () => {
    const mark = { at: 500, headSha: 'abc', reviewId: 'r1', value: 'comment' as const, why: 'w' }
    const prState = { ...emptyPrState(), recommendation: mark }
    expect(outcomeOf(prState, 'abc', 400)).toBe('drafted')
    expect(outcomeOf(prState, 'abc', 500)).toBeNull()
    expect(outcomeOf(prState, 'abc', 600)).toBeNull()
    expect(outcomeOf(undefined, 'abc', 0)).toBeNull()
    expect(outcomeOf({ ...prState, lastError: 'boom' }, 'abc', 600)).toBe('failed')
  })

  it('outcomeOf: reviewed only for the same head', () => {
    const mark = { at: 500, headSha: 'abc', reviewId: null, value: 'approve' as const, why: 'w' }
    const prState = { ...emptyPrState(), recommendation: mark }
    expect(outcomeOf(prState, 'abc', 600)).toBe('reviewed')
    expect(outcomeOf(prState, 'def', 600)).toBeNull()
  })

  it('PR_KEY refuses acme/..#1 and REPO_KEY refuses acme/.', () => {
    expect(PR_KEY.test('acme/..#1')).toBe(false)
    expect(PR_KEY.test('acme/.#1')).toBe(false)
    expect(PR_KEY.test('acme/a.b#1')).toBe(true)
    expect(REPO_KEY.test('acme/.')).toBe(false)
    expect(REPO_KEY.test('acme/..')).toBe(false)
    expect(REPO_KEY.test('acme/app')).toBe(true)
  })

  it('repoOf gives a lower-case key', () => {
    expect(repoOf('Acme/Api#7')).toBe('acme/api')
    expect(repoOf('acme/api#7')).toBe('acme/api')
    expect(repoOf('Acme/Api')).toBe('acme/api')
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
  const settings = {
    reviewsAutoFix: true,
    reviewsIgnore: [] as string[],
    reviewsTeamRequests: true,
  }
  const waiting = { claude: 'waiting' as const, error: null, fixing: 0, sessionId: null }

  function input(poll: PollData, over: Partial<Parameters<typeof buildSnapshot>[0]> = {}) {
    return {
      claude: () => waiting,
      now: 5000,
      poll,
      pollStartedAt: 0,
      session: () => null,
      sessionOf: () => null,
      settings,
      state: structuredClone(EMPTY_STATE),
      trust: [],
      ...over,
    }
  }

  it('buildSnapshot: an ignored repo shows in neither list', () => {
    const poll: PollData = {
      errors: [],
      mine: [
        pr({ key: 'acme/app#2', number: 2 }),
        pr({ key: 'keep/app#3', number: 3, owner: 'keep' }),
      ],
      mineHasMore: false,
      rateLimit: null,
      toReview: [pr({ key: 'acme/app#1', requestedUsers: [VIEWER] })],
      toReviewHasMore: false,
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
      errors: [],
      mine: [mine],
      mineHasMore: false,
      rateLimit: null,
      toReview: [
        pr({ key: 'acme/app#1', requestedAt: 50, requestedUsers: [VIEWER] }),
        pr({ key: 'acme/app#9', number: 9, requestedAt: 10, requestedUsers: [VIEWER] }),
      ],
      toReviewHasMore: false,
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
    expect(row?.reviewers).toEqual([
      { name: 'bob', stance: 'none' },
      { name: 'Copilot', stance: 'none' },
      { name: 'alice', stance: 'approved' },
    ])
    expect(row?.laterCopilot).toBe(1)
    expect(row?.olderOpen).toBe(1)
    expect(row?.claude).toBe('waiting')
  })
})

describe('buildSnapshot team flag', () => {
  it('sets team for each team-only request, in each state', () => {
    const poll: PollData = {
      errors: [],
      mine: [],
      mineHasMore: false,
      rateLimit: null,
      toReview: [
        pr({ key: 'acme/app#1', number: 1, requestedTeams: ['core'] }),
        pr({ key: 'acme/app#2', number: 2, requestedTeams: ['core'], reviewDecision: 'APPROVED' }),
        pr({ key: 'acme/app#3', number: 3, requestedTeams: ['core'] }),
        pr({ key: 'acme/app#4', number: 4, requestedTeams: ['core'], requestedUsers: [VIEWER] }),
      ],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    const state = structuredClone(EMPTY_STATE)
    state.pauses['acme/app#3'] = 9000
    const snap = buildSnapshot({
      claude: () => ({ claude: 'waiting', error: null, fixing: 0, sessionId: null }),
      now: 5000,
      poll,
      pollStartedAt: 0,
      session: () => null,
      sessionOf: () => null,
      settings: { reviewsAutoFix: true, reviewsIgnore: [], reviewsTeamRequests: true },
      state,
      trust: [],
    })
    expect(snap.toReview.map(r => [r.key, r.state, r.team]).sort()).toEqual([
      ['acme/app#1', 'team', true],
      ['acme/app#2', 'approved-by-others', true],
      ['acme/app#3', 'paused', true],
      ['acme/app#4', 'new', false],
    ])
  })
})

describe('buildSnapshot recommendation', () => {
  it('buildSnapshot fills the recommendation only for draft-ready and reviewed rows', () => {
    const mark = (reviewId: string | null) => ({
      at: 500,
      headSha: 'abc',
      reviewId,
      value: 'request-changes' as const,
      why: 'Bug in a.ts',
    })
    const mk = (n: number, over: Partial<PrData> = {}) =>
      pr({ key: `acme/app#${n}`, number: n, requestedUsers: [VIEWER], ...over })
    const poll: PollData = {
      errors: [],
      mine: [],
      mineHasMore: false,
      rateLimit: null,
      toReview: [mk(1), mk(2), mk(3), mk(4)],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('r1') }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark(null) }
    state.prs['acme/app#3'] = {
      ...emptyPrState(),
      lastError: 'The review failed.',
      recommendation: mark('r1'),
    }
    state.prs['acme/app#4'] = { ...emptyPrState(), recommendation: mark(null) }
    const input = snapshotInput(poll, state)
    input.pollStartedAt = 400
    const snap = buildSnapshot({
      ...input,
      session: key => (key === 'acme/app#4' ? 'reviewing' : null),
      sessionOf: key => (key === 'acme/app#4' ? 'row-4' : null),
      trust: [{ repo: 'acme/app', waiting: 1 }],
    })
    const rows = Object.fromEntries(snap.toReview.map(r => [r.key, r]))
    expect(rows['acme/app#1']).toMatchObject({
      error: null,
      recommendation: 'request-changes',
      state: 'draft-ready',
      why: 'Bug in a.ts',
    })
    expect(rows['acme/app#2']).toMatchObject({
      recommendation: 'request-changes',
      state: 'reviewed',
    })
    expect(rows['acme/app#3']).toMatchObject({
      error: 'The review failed.',
      recommendation: null,
      state: 'failed',
      why: null,
    })
    expect(rows['acme/app#4']).toMatchObject({
      recommendation: null,
      sessionId: 'row-4',
      state: 'reviewing',
      why: null,
    })
    expect(snap.trust).toEqual([{ repo: 'acme/app', waiting: 1 }])
  })
})

describe('buildSnapshot stale recommendation', () => {
  it('shows a mark only for the current pending review or a draft the poll does not show', () => {
    const mark = (reviewId: string | null, at = 100) => ({
      at,
      headSha: 'abc',
      reviewId,
      value: 'comment' as const,
      why: 'Small risk.',
    })
    const mk = (n: number, pending: string | null) =>
      pr({
        key: `acme/app#${n}`,
        number: n,
        requestedUsers: [VIEWER],
        viewerPendingReviewId: pending,
      })
    const poll: PollData = {
      errors: [],
      mine: [],
      mineHasMore: false,
      rateLimit: null,
      toReview: [mk(1, 'r1'), mk(2, 'r-user'), mk(3, 'r-user'), mk(4, null), mk(5, 'r-user')],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    const state = structuredClone(EMPTY_STATE)
    // 1: the mark of the pending review. 2: an old mark of another review. 3: an old mark with
    // no review. 4: a new draft that the poll does not show yet. 5: a failed round on top of
    // the draft of Bifrost.
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('r1') }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('r1') }
    state.prs['acme/app#3'] = { ...emptyPrState(), recommendation: mark(null) }
    state.prs['acme/app#4'] = { ...emptyPrState(), recommendation: mark('r9', 500) }
    state.prs['acme/app#5'] = {
      ...emptyPrState(),
      lastError: 'The review failed.',
      recommendation: mark('r-user'),
    }
    const input = snapshotInput(poll, state)
    input.pollStartedAt = 400
    const rows = Object.fromEntries(buildSnapshot(input).toReview.map(r => [r.key, r]))
    const shown = { recommendation: 'comment', state: 'draft-ready', why: 'Small risk.' }
    const hidden = { recommendation: null, state: 'draft-ready', why: null }
    expect(rows['acme/app#1']).toMatchObject(shown)
    expect(rows['acme/app#2']).toMatchObject(hidden)
    expect(rows['acme/app#3']).toMatchObject(hidden)
    expect(rows['acme/app#4']).toMatchObject(shown)
    expect(rows['acme/app#5']).toMatchObject(shown)
  })
})

describe('buildSnapshot of a busy PR', () => {
  const input = (mine: PrData[]) => ({
    claude: () => ({ claude: 'waiting' as const, error: null, fixing: 0, sessionId: null }),
    now: 5000,
    poll: {
      errors: [],
      mine,
      mineHasMore: false,
      rateLimit: null,
      toReview: [],
      toReviewHasMore: false,
      viewer: VIEWER,
    },
    pollStartedAt: 0,
    session: () => null,
    sessionOf: () => null,
    settings: { reviewsAutoFix: true, reviewsIgnore: [] as string[], reviewsTeamRequests: true },
    state: structuredClone(EMPTY_STATE),
    trust: [],
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
    expect(buildSnapshot(input([p])).mine[0]?.reviewers).toEqual([
      { name: 'alice', stance: 'approved' },
    ])
  })
})

describe('baselineOf', () => {
  it('collects the open items of My PRs and the To review keys', () => {
    const poll: PollData = {
      errors: [],
      mine: [pr({ comments: [comment('pc1', member)], threads: [thread('t1', member)] })],
      mineHasMore: false,
      rateLimit: null,
      toReview: [pr({ key: 'acme/app#7' }), pr({ key: 'acme/app#8' })],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    const b = baselineOf(poll)
    expect([...b.items].sort()).toEqual(['pc1', 't1'])
    expect(b.requests).toEqual(['acme/app#7', 'acme/app#8'])
  })

  it('adds the visible items of a truncated PR to the baseline', () => {
    const poll: PollData = {
      errors: [],
      mine: [pr({ threads: [thread('t1', member)], truncatedThreads: true })],
      mineHasMore: false,
      rateLimit: null,
      toReview: [],
      toReviewHasMore: false,
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
    const st = (p: PrData) =>
      reviewStatus(p, VIEWER, { laterCopilot: [], older: [], posting: [], questions: [], work: [] })
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

const SHA = 'a'.repeat(40)

function question(over: Partial<Question> = {}): Question {
  return {
    answer: null,
    at: 1,
    question: 'Which limit?',
    seenUntil: 200,
    where: 'a.ts line 1',
    ...over,
  }
}

describe('splitWork R3', () => {
  it('an open question is neither work nor older', () => {
    const p = pr({
      comments: [comment('pc1', member)],
      threads: [thread('t1', member), thread('t2', member)],
    })
    const state = prState({ questions: { pc1: question(), t1: question() } })
    const split = splitWork(p, VIEWER, state, new Set(['t1']), null)
    expect(ids(split.work)).toEqual(['t2'])
    expect(split.older).toEqual([])
    expect(split.questions).toEqual([
      { id: 't1', kind: 'thread' },
      { id: 'pc1', kind: 'comment' },
    ])
    // The thread of the question is still open, so the PR shows Comments.
    const approved = pr({
      decisions: [review('r1', member, { state: 'APPROVED' })],
      threads: [thread('t1', member)],
    })
    expect(reviewStatus(approved, VIEWER, splitWork(approved, VIEWER, state, NONE, null))).toBe(
      'comments',
    )
  })

  it('an answered question is work, also when it is older', () => {
    const p = pr({
      comments: [comment('pc1', member, 50)],
      threads: [thread('t1', member, { comments: [comment('c1', member, 50)] })],
    })
    const state = prState({
      questions: { pc1: question({ answer: 'Use 10.' }), t1: question({ answer: 'Yes.' }) },
    })
    const split = splitWork(p, VIEWER, state, new Set(['t1', 'pc1']), 100)
    expect(ids(split.work).sort()).toEqual(['pc1', 't1'])
    expect(split.older).toEqual([])
    expect(split.questions).toEqual([])
  })

  it('a trusted comment after seenUntil reopens a question', () => {
    const t = (late: Author, at: number) =>
      thread('t1', member, { comments: [comment('c1', member, 100), comment('c2', late, at)] })
    const state = prState({ questions: { t1: question({ seenUntil: 200 }) } })
    const split = (p: PrData) => splitWork(p, VIEWER, state, NONE, null)
    expect(ids(split(pr({ threads: [t(member, 300)] })).work)).toEqual(['t1'])
    expect(ids(split(pr({ threads: [t(member, 200)] })).questions)).toEqual(['t1'])
    expect(ids(split(pr({ threads: [t(outsider, 300)] })).questions)).toEqual(['t1'])
    expect(ids(split(pr({ threads: [t(viewer, 300)] })).questions)).toEqual(['t1'])
  })

  it('an open question stays a question, also when it is held', () => {
    const t = (at: number) =>
      thread('t1', member, { comments: [comment('c1', member, 100), comment('c2', member, at)] })
    const state = prState({ checkedAt: 300, held: ['t1'], questions: { t1: question() } })
    // No trusted comment after seenUntil (200): the item waits for the answer.
    const waiting = splitWork(pr({ threads: [t(150)] }), VIEWER, state, NONE, null)
    expect(ids(waiting.questions)).toEqual(['t1'])
    expect(waiting.older).toEqual([])
    expect(waiting.work).toEqual([])
    // A comment after seenUntil reopens it. The hold then applies: the failed round saw that
    // comment, so the item waits for Handle now.
    const seen = splitWork(pr({ threads: [t(250)] }), VIEWER, state, NONE, null)
    expect(ids(seen.older)).toEqual(['t1'])
    expect(ids(splitWork(pr({ threads: [t(400)] }), VIEWER, state, NONE, null).work)).toEqual([
      't1',
    ])
  })

  it('a held item is older until Handle now', () => {
    const p = pr({
      comments: [comment('pc1', member, 500)],
      reviews: [review('r1', member, { body: 'Fix it', state: 'CHANGES_REQUESTED' })],
      threads: [thread('t1', member, { comments: [comment('c1', member, 500)] })],
    })
    const held = prState({ held: ['t1', 'pc1', 'r1'] })
    const split = splitWork(p, VIEWER, held, NONE, 100)
    expect(split.work).toEqual([])
    expect(ids(split.older).sort()).toEqual(['pc1', 'r1', 't1'])
    const now = splitWork(p, VIEWER, { ...held, handleOlder: true }, NONE, 100)
    expect(ids(now.work).sort()).toEqual(['pc1', 'r1', 't1'])
    expect(now.older).toEqual([])
    // A held answered question waits too, so a failed round does not start again by itself.
    const answered = { ...held, questions: { t1: question({ answer: 'Yes.' }) } }
    expect(ids(splitWork(p, VIEWER, answered, NONE, 100).older)).toContain('t1')
  })

  it('a trusted comment after checkedAt reopens a held thread', () => {
    const t = (at: number) =>
      thread('t1', member, { comments: [comment('c1', member, 100), comment('c2', member, at)] })
    // A handled thread with a reply after lastReplyAt stays held: the failed round saw it.
    const state = prState({
      checkedAt: 300,
      handled: { t1: handledEntry(150, 150) },
      held: ['t1'],
    })
    expect(ids(splitWork(pr({ threads: [t(250)] }), VIEWER, state, NONE, null).older)).toEqual([
      't1',
    ])
    expect(ids(splitWork(pr({ threads: [t(400)] }), VIEWER, state, NONE, null).work)).toEqual([
      't1',
    ])
    const unread = { ...state, checkedAt: null }
    expect(ids(splitWork(pr({ threads: [t(400)] }), VIEWER, unread, NONE, null).older)).toEqual([
      't1',
    ])
  })

  it('an item in the outbox is neither work nor older', () => {
    const p = pr({
      comments: [comment('pc1', member), comment('pc2', member)],
      threads: [thread('t1', member), thread('t2', member), thread('t3', member)],
    })
    const outbox: Outbox = {
      headSha: SHA,
      mergeBase: SHA,
      posts: [
        { id: 'reply:t1', itemId: 't1', kind: 'reply', state: 'done', text: null },
        { id: 'resolve:t1', itemId: 't1', kind: 'resolve', state: 'todo' },
        {
          id: 'comment:pc1',
          itemId: 'pc1',
          kind: 'comment',
          quote: '> x',
          state: 'todo',
          text: 'y',
        },
        { id: 'resolve:t2', itemId: 't2', kind: 'resolve', state: 'dropped' },
      ],
      seen: {},
      startedAt: 1,
    }
    const state = prState({ held: ['t2'], outbox, questions: { t1: question() } })
    const split = splitWork(p, VIEWER, state, new Set(['t3']), null)
    expect(ids(split.work)).toEqual(['pc2'])
    expect(ids(split.older)).toEqual(['t3'])
    expect(split.questions).toEqual([])
    expect(ids(split.posting)).toEqual(['t1', 't2', 'pc1'])
  })

  it('an open thread in the outbox still gives Comments', () => {
    const p = pr({
      comments: [comment('pc1', member)],
      decisions: [review('r1', member, { state: 'APPROVED' })],
      threads: [thread('t1', member)],
    })
    const outbox: Outbox = {
      headSha: SHA,
      mergeBase: SHA,
      posts: [
        { id: 'reply:t1', itemId: 't1', kind: 'reply', state: 'dropped', text: null },
        {
          id: 'comment:pc1',
          itemId: 'pc1',
          kind: 'comment',
          quote: '> x',
          state: 'todo',
          text: 'y',
        },
      ],
      seen: {},
      startedAt: 1,
    }
    const split = splitWork(p, VIEWER, prState({ outbox }), NONE, null)
    expect(reviewStatus(p, VIEWER, split)).toBe('comments')
    // A PR comment in the outbox alone does not change the status word.
    const top = pr({ comments: p.comments, decisions: p.decisions })
    expect(reviewStatus(top, VIEWER, splitWork(top, VIEWER, prState({ outbox }), NONE, null))).toBe(
      'approved',
    )
  })

  it('a No action item that a trusted human answers later is work again', () => {
    const state = prState({
      handled: { pc1: handledEntry(150, null), t1: handledEntry(150, null) },
    })
    const t = (extra: PrComment[]) =>
      thread('t1', member, { comments: [comment('c1', member, 100), ...extra] })
    expect(splitWork(pr({ threads: [t([])] }), VIEWER, state, NONE, null).work).toEqual([])
    const later = pr({ threads: [t([comment('c2', member, 200)])] })
    expect(ids(splitWork(later, VIEWER, state, NONE, null).work)).toEqual(['t1'])
    // A PR comment has no thread. A new trusted PR comment is a new item.
    const top = pr({ comments: [comment('pc1', member, 100), comment('pc2', member, 200)] })
    expect(ids(splitWork(top, VIEWER, state, NONE, null).work)).toEqual(['pc2'])
  })

  it('the saved first Copilot review wins over an earlier review that shows later', () => {
    const p = pr({
      reviews: [
        review('r1', copilot, { submittedAt: 1000 }),
        review('r2', copilot, { submittedAt: 2000 }),
      ],
      threads: [
        thread('t1', copilot, { reviewId: 'r1' }),
        thread('t2', copilot, { reviewId: 'r2' }),
      ],
    })
    const fresh = splitWork(p, VIEWER, prState(), NONE, null)
    expect(ids(fresh.work)).toEqual(['t1'])
    const saved = splitWork(p, VIEWER, prState({ firstCopilotReview: 'r2' }), NONE, null)
    expect(ids(saved.work)).toEqual(['t2'])
    expect(ids(saved.laterCopilot)).toEqual(['t1'])
    // A saved first review that GitHub deleted makes no later review the first.
    const gone = splitWork(p, VIEWER, prState({ firstCopilotReview: 'r0' }), NONE, null)
    expect(gone.work).toEqual([])
    expect(ids(gone.laterCopilot)).toEqual(['t1', 't2'])
  })

  it('an item from before fixFrom is older', () => {
    const p = pr({ comments: [comment('pc1', member, 200), comment('pc2', member, 400)] })
    const state = { ...structuredClone(EMPTY_STATE), fixFrom: 300, turnedOnAt: 100 }
    expect(workSince(state)).toBe(300)
    expect(workSince({ ...state, fixFrom: null })).toBe(100)
    expect(workSince({ ...state, fixFrom: null, turnedOnAt: null })).toBeNull()
    const split = splitWork(p, VIEWER, prState(), NONE, workSince(state))
    expect(ids(split.older)).toEqual(['pc1'])
    expect(ids(split.work)).toEqual(['pc2'])
    const poll: PollData = {
      errors: [],
      mine: [p],
      mineHasMore: false,
      rateLimit: null,
      toReview: [],
      toReviewHasMore: false,
      viewer: VIEWER,
    }
    expect(buildSnapshot({ ...snapshotInput(poll, state) }).mine[0]?.olderOpen).toBe(1)
  })
})

describe('needsRound', () => {
  const work = (n: number) => ({
    laterCopilot: [],
    older: [],
    posting: [],
    questions: [],
    work: Array.from({ length: n }, (_, i) => ({ id: `t${i}`, kind: 'thread' as const })),
  })

  it('needsRound: no for a fork or autoFix off, yes for work or a newer cut thread list', () => {
    expect(needsRound(pr(), work(1), prState(), true)).toBe(true)
    expect(needsRound(pr(), work(0), prState(), true)).toBe(false)
    expect(needsRound(pr({ isCrossRepository: true }), work(1), prState(), true)).toBe(false)
    expect(needsRound(pr(), work(1), prState(), false)).toBe(false)
    const cut = pr({ truncatedThreads: true, updatedAt: 500 })
    expect(needsRound(cut, work(0), prState(), true)).toBe(true)
    expect(needsRound(cut, work(0), prState({ checkedAt: 400 }), true)).toBe(true)
    expect(needsRound(cut, work(0), prState({ checkedAt: 500 }), true)).toBe(false)
    expect(needsRound(cut, work(0), prState(), false)).toBe(false)
    expect(needsRound({ ...cut, isCrossRepository: true }, work(0), prState(), true)).toBe(false)
    // Only a cut thread list asks for a full read.
    const comments = pr({ truncatedComments: true, updatedAt: 500 })
    expect(needsRound(comments, work(0), prState(), true)).toBe(false)
  })
})

describe('buildSnapshot R3', () => {
  const poll = (mine: PrData[]): PollData => ({
    errors: [],
    mine,
    mineHasMore: false,
    rateLimit: null,
    toReview: [],
    toReviewHasMore: false,
    viewer: VIEWER,
  })

  it('olderOpen counts the work too while autoFix is off', () => {
    const p = pr({ threads: [thread('t1', member), thread('t2', member)] })
    const state = { ...structuredClone(EMPTY_STATE), baseline: ['t1'] }
    const input = snapshotInput(poll([p]), state)
    expect(buildSnapshot(input).mine[0]?.olderOpen).toBe(1)
    const off = { ...input, settings: { ...input.settings, reviewsAutoFix: false } }
    expect(buildSnapshot(off).mine[0]?.olderOpen).toBe(2)
  })

  it('buildSnapshot gives the open questions with where and question', () => {
    const p = pr({ threads: [thread('t1', member)] })
    const state = structuredClone(EMPTY_STATE)
    state.prs[p.key] = prState({
      questions: {
        pc1: question({ at: 30, question: 'Is the README in scope?', where: 'Comment from alice' }),
        t1: question({ at: 10, question: 'Which limit?', where: 'a.ts line 1' }),
        t9: question({ answer: 'Ten.', at: 5 }),
      },
    })
    const row = buildSnapshot(snapshotInput(poll([p]), state)).mine[0]
    expect(row?.questions).toEqual([
      { id: 't1', question: 'Which limit?', where: 'a.ts line 1' },
      { id: 'pc1', question: 'Is the README in scope?', where: 'Comment from alice' },
    ])
    const empty = buildSnapshot(snapshotInput(poll([p]), structuredClone(EMPTY_STATE))).mine[0]
    expect(empty?.questions).toEqual([])
  })

  it('a saved flag of ruling S20 counts the work as waiting and asks for the hint', () => {
    const p = pr({ threads: [thread('t1', member), thread('t2', member)] })
    const state = { ...structuredClone(EMPTY_STATE), autoFixConsent: false, baseline: ['t1'] }
    const snap = buildSnapshot(snapshotInput(poll([p]), state))
    expect(snap.autoFixConfirm).toBe(true)
    expect(snap.mine[0]?.olderOpen).toBe(2)
    for (const autoFixConsent of [null, true]) {
      const on = buildSnapshot(snapshotInput(poll([p]), { ...state, autoFixConsent }))
      expect(on.autoFixConfirm).toBe(false)
      expect(on.mine[0]?.olderOpen).toBe(1)
    }
  })

  it('autoFixOn needs the setting and no saved flag of ruling S20', () => {
    expect(autoFixOn({ reviewsAutoFix: true }, { autoFixConsent: null })).toBe(true)
    expect(autoFixOn({ reviewsAutoFix: true }, { autoFixConsent: true })).toBe(true)
    expect(autoFixOn({ reviewsAutoFix: true }, { autoFixConsent: false })).toBe(false)
    expect(autoFixOn({ reviewsAutoFix: false }, { autoFixConsent: true })).toBe(false)
  })

  it('buildSnapshot marks a row with an outbox as unsent', () => {
    const p = pr({ threads: [thread('t1', member)] })
    const state = structuredClone(EMPTY_STATE)
    const outbox = {
      headSha: 'a'.repeat(40),
      mergeBase: 'b'.repeat(40),
      posts: [],
      seen: {},
      startedAt: 1,
    }
    state.prs[p.key] = prState({ outbox })
    expect(buildSnapshot(snapshotInput(poll([p]), state)).mine[0]?.unsent).toBe(true)
    const none = buildSnapshot(snapshotInput(poll([p]), structuredClone(EMPTY_STATE))).mine[0]
    expect(none?.unsent).toBe(false)
  })

  it('buildSnapshot gives the last error of the PR', () => {
    const p = pr({ threads: [thread('t1', member)] })
    const state = structuredClone(EMPTY_STATE)
    state.prs[p.key] = prState({ lastError: 'It broke.' })
    expect(buildSnapshot(snapshotInput(poll([p]), state)).mine[0]?.lastError).toBe('It broke.')
    const none = buildSnapshot(snapshotInput(poll([p]), structuredClone(EMPTY_STATE))).mine[0]
    expect(none?.lastError).toBeNull()
  })
})

describe('the Approve button (user decision, 2026-11-13)', () => {
  const HEAD = 'a'.repeat(40)
  const mark = (value: 'approve' | 'comment' | 'request-changes', reviewId: string | null) => ({
    at: 100,
    headSha: HEAD,
    reviewId,
    value,
    why: 'Small and safe.',
  })
  const mk = (n: number, over: Partial<PrData> = {}) =>
    pr({ headSha: HEAD, key: `acme/app#${n}`, number: n, requestedUsers: [VIEWER], ...over })
  const pollOf = (toReview: PrData[]): PollData => ({
    errors: [],
    mine: [],
    mineHasMore: false,
    rateLimit: null,
    toReview,
    toReviewHasMore: false,
    viewer: VIEWER,
  })
  const rowsOf = (input: ReturnType<typeof snapshotInput>) =>
    Object.fromEntries(buildSnapshot(input).toReview.map(r => [r.key, r]))

  it('shows only for an Approve mark on a reviewed row and on a draft-ready row', () => {
    const poll = pollOf([
      mk(1),
      mk(2, { viewerPendingReviewId: 'r2' }),
      mk(3),
      mk(4, { viewerPendingReviewId: 'r4' }),
      mk(5, { viewerPendingReviewId: 'r5' }),
      mk(6),
    ])
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('approve', 'r2') }
    state.prs['acme/app#3'] = { ...emptyPrState(), recommendation: mark('comment', null) }
    state.prs['acme/app#4'] = { ...emptyPrState(), recommendation: mark('comment', 'r4') }
    state.prs['acme/app#5'] = { ...emptyPrState(), recommendation: mark('request-changes', 'r5') }
    const rows = rowsOf(snapshotInput(poll, state))
    expect(rows['acme/app#1']).toMatchObject({ approve: 'ready', state: 'reviewed' })
    expect(rows['acme/app#2']).toMatchObject({ approve: 'ready', state: 'draft-ready' })
    expect(rows['acme/app#3']).toMatchObject({ approve: null, state: 'reviewed' })
    expect(rows['acme/app#4']).toMatchObject({ approve: null, state: 'draft-ready' })
    expect(rows['acme/app#5']).toMatchObject({ approve: null, state: 'draft-ready' })
    expect(rows['acme/app#6']).toMatchObject({ approve: null, approveIssue: null, state: 'new' })
  })

  it('does not show for a draft of the user, or for a mark on an older head', () => {
    const poll = pollOf([
      mk(1, { viewerPendingReviewId: 'r-user' }),
      mk(2, { headSha: 'b'.repeat(40), viewerPendingReviewId: 'r2' }),
    ])
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('approve', 'r1') }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('approve', 'r2') }
    // The poll is newer than the marks.
    const rows = rowsOf({ ...snapshotInput(poll, state), pollStartedAt: 400 })
    expect(rows['acme/app#1']).toMatchObject({ approve: null, state: 'draft-ready' })
    expect(rows['acme/app#2']).toMatchObject({ approve: null, state: 'draft-ready' })
  })

  it('is disabled while the write runs, and hides after an unknown result until a poll', () => {
    const poll = pollOf([mk(1), mk(2), mk(3)])
    const state = structuredClone(EMPTY_STATE)
    for (const n of [1, 2, 3]) {
      state.prs[`acme/app#${n}`] = { ...emptyPrState(), recommendation: mark('approve', null) }
    }
    const input = {
      ...snapshotInput(poll, state),
      approval: (key: string) => {
        if (key === 'acme/app#1') return { at: 900, phase: 'running' as const }
        if (key === 'acme/app#2') {
          return { at: 900, message: 'Not sure.', phase: 'unknown' as const }
        }
        return { at: 900, message: 'It failed.', phase: 'failed' as const }
      },
      pollStartedAt: 800,
    }
    const rows = rowsOf(input)
    expect(rows['acme/app#1']).toMatchObject({ approve: 'running', approveIssue: null })
    expect(rows['acme/app#2']).toMatchObject({
      approve: null,
      approveIssue: { message: 'Not sure.', unknown: true },
      state: 'reviewed',
    })
    // A known failure wrote nothing, so the button shows again.
    expect(rows['acme/app#3']).toMatchObject({
      approve: 'ready',
      approveIssue: { message: 'It failed.', unknown: false },
    })
    // The next poll shows the true state.
    const later = rowsOf({ ...input, pollStartedAt: 1000 })
    expect(later['acme/app#1']).toMatchObject({ approve: 'running' })
    expect(later['acme/app#2']).toMatchObject({ approve: 'ready', approveIssue: null })
    expect(later['acme/app#3']).toMatchObject({ approve: 'ready', approveIssue: null })
  })

  it('a click that worked shows You approved at once, before the poll', () => {
    const poll = pollOf([mk(1), mk(2, { viewerPendingReviewId: 'r2' })])
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('approve', 'r2') }
    const input = {
      ...snapshotInput(poll, state),
      approval: () => ({ at: 900, phase: 'approved' as const }),
      pollStartedAt: 800,
    }
    const rows = rowsOf(input)
    for (const key of ['acme/app#1', 'acme/app#2']) {
      expect(rows[key]).toMatchObject({ approve: null, approveIssue: null, state: 'you-approved' })
    }
  })

  it('hides after the poll shows an approval of the viewer on the head', () => {
    const approved = { commit: HEAD, state: 'APPROVED' as const, submittedAt: 100 }
    const later = (state: 'COMMENTED' | 'CHANGES_REQUESTED' | 'PENDING') => ({
      ...approved,
      state,
      submittedAt: 200,
    })
    const poll = pollOf([
      mk(1, { viewerReviews: [approved] }),
      mk(2, { viewerReviews: [{ ...approved, commit: 'b'.repeat(40) }] }),
      mk(3, { viewerReviews: [{ ...approved, state: 'COMMENTED' }] }),
      // An approval and then a comment or a draft on the head: the approval stands.
      mk(4, { viewerReviews: [approved, later('COMMENTED')] }),
      mk(5, { viewerReviews: [approved, later('PENDING')] }),
      // A later Request changes ends the approval.
      mk(6, { viewerReviews: [approved, later('CHANGES_REQUESTED')] }),
    ])
    const state = structuredClone(EMPTY_STATE)
    for (const n of [1, 2, 3, 4, 5, 6]) {
      // The user clicked Review after the request came.
      state.requests[`acme/app#${n}`] = { baseline: false, firstSeen: 10 }
      state.prs[`acme/app#${n}`] = {
        ...emptyPrState(),
        actedAt: 50,
        recommendation: mark('approve', null),
      }
    }
    const rows = rowsOf(snapshotInput(poll, state))
    expect(rows['acme/app#1']).toMatchObject({ approve: null, state: 'you-approved' })
    expect(rows['acme/app#2']).toMatchObject({ approve: 'ready', state: 'reviewed' })
    expect(rows['acme/app#3']).toMatchObject({ approve: 'ready', state: 'reviewed' })
    expect(rows['acme/app#4']).toMatchObject({ approve: null, state: 'you-approved' })
    expect(rows['acme/app#5']).toMatchObject({ approve: null, state: 'you-approved' })
    expect(rows['acme/app#6']).toMatchObject({ approve: 'ready', state: 'reviewed' })
  })

  it('the poll and the fresh check use one rule: the latest opinion of the viewer', () => {
    const at = (
      state: ReviewState,
      submittedAt: number | null,
      commit: string | null = HEAD,
    ): ViewerOpinion => ({ commit, state, submittedAt })
    const cases: [ReturnType<typeof at>[], boolean][] = [
      [[], false],
      [[at('APPROVED', 1)], true],
      [[at('APPROVED', 1, 'b'.repeat(40))], false],
      [[at('APPROVED', 1), at('COMMENTED', 2)], true],
      [[at('APPROVED', 1), at('PENDING', null)], true],
      [[at('APPROVED', 1), at('CHANGES_REQUESTED', 2)], false],
      [[at('APPROVED', 1), at('DISMISSED', 2)], false],
      [[at('CHANGES_REQUESTED', 1), at('APPROVED', 2)], true],
      [[at('COMMENTED', 1)], false],
    ]
    for (const [reviews, expected] of cases) {
      expect(approvedOnHead(reviews, HEAD)).toBe(expected)
      expect(viewerApproved({ headSha: HEAD, viewerReviews: reviews })).toBe(expected)
    }
  })

  it('toReviewState: an approval of the viewer gives you-approved, a new request stays new', () => {
    const ctx: ToReviewContext = {
      acted: true,
      known: { baseline: false },
      now: 1000,
      outcome: 'reviewed',
      pauseEndsAt: null,
      session: null,
      teamRequests: true,
    }
    const approved = mk(1, {
      reviewDecision: 'APPROVED',
      viewerReviews: [{ commit: HEAD, state: 'APPROVED', submittedAt: 100 }],
    })
    expect(toReviewState(approved, VIEWER, ctx)).toBe('you-approved')
    expect(toReviewState(approved, VIEWER, { ...ctx, outcome: null })).toBe('you-approved')
    // A session and a draft of the user come first.
    expect(toReviewState(approved, VIEWER, { ...ctx, session: 'reviewing' })).toBe('reviewing')
    const pending = { ...approved, viewerPendingReviewId: 'r-user' }
    expect(toReviewState(pending, VIEWER, ctx)).toBe('draft-ready')
    // A new request on the same commit flashes as before.
    const fresh = { ...ctx, acted: false, outcome: null }
    expect(toReviewState({ ...approved, reviewDecision: null }, VIEWER, fresh)).toBe('new')
    // A click that worked wins over the draft that the poll still shows.
    expect(toReviewState(pending, VIEWER, { ...ctx, approved: true })).toBe('you-approved')
  })
})

describe('the row results and the Review panel (user decision, 2026-11-13)', () => {
  const HEAD = 'a'.repeat(40)
  type Value = 'approve' | 'comment' | 'request-changes'
  const mark = (value: Value, reviewId: string | null, over: Partial<RecommendationMark> = {}) => ({
    at: 100,
    headSha: HEAD,
    reviewId,
    value,
    why: 'Because.',
    ...over,
  })
  const mk = (n: number, over: Partial<PrData> = {}) =>
    pr({ headSha: HEAD, key: `acme/app#${n}`, number: n, requestedUsers: [VIEWER], ...over })
  const pollOf = (toReview: PrData[]): PollData => ({
    errors: [],
    mine: [],
    mineHasMore: false,
    rateLimit: null,
    toReview,
    toReviewHasMore: false,
    viewer: VIEWER,
  })
  const rowsOf = (input: Parameters<typeof buildSnapshot>[0]) =>
    Object.fromEntries(buildSnapshot(input).toReview.map(r => [r.key, r]))
  const draftOf = (reviewId: string, path: string, line = 1) => ({
    at: 50,
    body: 'x',
    line,
    path,
    prKey: 'acme/app#1',
    reviewId,
  })

  it('B1: says what Claude drafted, from the saved drafts of the mark', () => {
    const poll = pollOf([
      mk(1, { viewerPendingReviewId: 'r1' }),
      mk(2, { viewerPendingReviewId: 'r2' }),
      mk(3),
      mk(4, { viewerPendingReviewId: 'r4' }),
      mk(5),
    ])
    const state = structuredClone(EMPTY_STATE)
    state.drafts = [
      draftOf('r1', 'src/a.ts'),
      draftOf('r1', 'src/b.ts', 2),
      draftOf('r1', ''),
      draftOf('r2', ''),
      draftOf('other', 'src/c.ts'),
    ]
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('comment', 'r1') }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('approve', 'r2') }
    state.prs['acme/app#3'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    // Bifrost kept no drafts for r4, so the counts are not known.
    state.prs['acme/app#4'] = { ...emptyPrState(), recommendation: mark('request-changes', 'r4') }
    const rows = rowsOf(snapshotInput(poll, state))
    expect(rows['acme/app#1']?.drafted).toEqual({ comments: 2, summary: true })
    expect(rows['acme/app#2']?.drafted).toEqual({ comments: 0, summary: true })
    expect(rows['acme/app#3']?.drafted).toEqual({ comments: 0, summary: false })
    expect(rows['acme/app#4']?.drafted).toBeNull()
    expect(rows['acme/app#5']?.drafted).toBeNull()
  })

  it('B1: gives the count of the approvals of others', () => {
    const poll = pollOf([mk(1, { approvals: 2, reviewDecision: 'APPROVED' })])
    const rows = rowsOf(snapshotInput(poll, structuredClone(EMPTY_STATE)))
    expect(rows['acme/app#1']).toMatchObject({ approvals: 2, state: 'approved-by-others' })
  })

  it('B4: offers the Review panel only for a Comment or Request changes draft of Claude', () => {
    const poll = pollOf([
      mk(1, { viewerPendingReviewId: 'r1' }),
      mk(2, { viewerPendingReviewId: 'r2' }),
      mk(3, { viewerPendingReviewId: 'r3' }),
      mk(4),
      mk(5, { viewerPendingReviewId: 'r-user' }),
    ])
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('comment', 'r1') }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('request-changes', 'r2') }
    state.prs['acme/app#3'] = { ...emptyPrState(), recommendation: mark('approve', 'r3') }
    state.prs['acme/app#4'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    const rows = rowsOf({ ...snapshotInput(poll, state), pollStartedAt: 400 })
    expect(rows['acme/app#1']).toMatchObject({ draft: 'ready', state: 'draft-ready' })
    expect(rows['acme/app#2']).toMatchObject({ draft: 'ready', state: 'draft-ready' })
    expect(rows['acme/app#3']).toMatchObject({ approve: 'ready', draft: null })
    expect(rows['acme/app#4']).toMatchObject({ approve: 'ready', draft: null })
    // A draft of the user has no mark, so it has no panel.
    expect(rows['acme/app#5']).toMatchObject({ draft: null, state: 'draft-ready' })
  })

  it('B7: a panel action that runs, fails or is not known shows on the row until a poll', () => {
    const poll = pollOf([1, 2, 3].map(n => mk(n, { viewerPendingReviewId: `r${n}` })))
    const state = structuredClone(EMPTY_STATE)
    for (const n of [1, 2, 3]) {
      state.prs[`acme/app#${n}`] = { ...emptyPrState(), recommendation: mark('comment', `r${n}`) }
    }
    const input = {
      ...snapshotInput(poll, state),
      draft: (key: string): DraftEntry | null => {
        if (key === 'acme/app#1') return { action: 'send', at: 900, phase: 'running' }
        if (key === 'acme/app#2') {
          return { action: 'send', at: 900, message: 'Not sure.', phase: 'unknown' }
        }
        return { action: 'discard', at: 900, message: 'It failed.', phase: 'failed' }
      },
      pollStartedAt: 800,
    }
    const rows = rowsOf(input)
    expect(rows['acme/app#1']).toMatchObject({ draft: 'running', draftIssue: null })
    expect(rows['acme/app#2']).toMatchObject({
      draft: null,
      draftIssue: { action: 'send', message: 'Not sure.', unknown: true },
    })
    expect(rows['acme/app#3']).toMatchObject({
      draft: 'ready',
      draftIssue: { action: 'discard', message: 'It failed.', unknown: false },
    })
    const later = rowsOf({ ...input, pollStartedAt: 1000 })
    expect(later['acme/app#2']).toMatchObject({ draft: 'ready', draftIssue: null })
    expect(later['acme/app#3']).toMatchObject({ draft: 'ready', draftIssue: null })
  })

  it('B7: a sent review shows Review sent at once, and hides the old draft of the poll', () => {
    const poll = pollOf([mk(1, { viewerPendingReviewId: 'r1' })])
    const state = structuredClone(EMPTY_STATE)
    // The send cleared the mark.
    const entry: DraftEntry = { action: 'send', at: 900, gone: 'r1', phase: 'sent' }
    const input = { ...snapshotInput(poll, state), draft: () => entry, pollStartedAt: 800 }
    expect(rowsOf(input)['acme/app#1']).toMatchObject({ draft: null, state: 'you-reviewed' })
    // A poll after the send shows the true state of GitHub.
    const after = pollOf([mk(1)])
    expect(rowsOf({ ...input, poll: after, pollStartedAt: 1000 })['acme/app#1']?.state).toBe('new')
  })

  it('B8: after a discard the row no longer offers the draft, and offers Review', () => {
    const poll = pollOf([mk(1, { viewerPendingReviewId: 'r1' })])
    const state = structuredClone(EMPTY_STATE)
    state.requests['acme/app#1'] = { baseline: false, firstSeen: 10 }
    state.prs['acme/app#1'] = { ...emptyPrState(), actedAt: 50 }
    const entry: DraftEntry = { action: 'discard', at: 900, gone: 'r1', phase: 'discarded' }
    const row = rowsOf({ ...snapshotInput(poll, state), draft: () => entry, pollStartedAt: 800 })[
      'acme/app#1'
    ]
    expect(row).toMatchObject({ draft: null, recommendation: null, state: 'waiting' })
  })

  it('B9: a deleted draft gives the Approve button and says that the draft is gone', () => {
    const poll = pollOf([mk(1, { viewerPendingReviewId: 'r1' })])
    const state = structuredClone(EMPTY_STATE)
    const deleted = mark('request-changes', null, { deleted: true })
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: deleted }
    const entry: DraftEntry = { action: 'approve', at: 900, gone: 'r1', phase: 'discarded' }
    const input = { ...snapshotInput(poll, state), draft: () => entry, pollStartedAt: 800 }
    expect(rowsOf(input)['acme/app#1']).toMatchObject({
      approve: 'ready',
      draft: null,
      draftDeleted: true,
      recommendation: 'request-changes',
      state: 'reviewed',
    })
    // The approval failed: the button shows again, with the text.
    const failed = {
      ...input,
      approval: () => ({ at: 950, message: 'No.', phase: 'failed' as const }),
    }
    expect(rowsOf(failed)['acme/app#1']).toMatchObject({
      approve: 'ready',
      approveIssue: { message: 'No.', unknown: false },
      draftDeleted: true,
    })
    // A deleted mark of another commit gives no button.
    const moved = pollOf([mk(1, { headSha: 'b'.repeat(40) })])
    expect(rowsOf({ ...input, poll: moved })['acme/app#1']?.approve).toBeNull()
  })

  it('B3: a removed PR shows nowhere: no row, no count and no flash', () => {
    const poll = pollOf([
      mk(1, { approvals: 1, reviewDecision: 'APPROVED' }),
      mk(2, { reviewDecision: 'APPROVED' }),
    ])
    const state = structuredClone(EMPTY_STATE)
    state.hidden = { 'acme/app#1': 900 }
    const snapshot = buildSnapshot(snapshotInput(poll, state))
    expect(snapshot.toReview.map(r => r.key)).toEqual(['acme/app#2'])
  })

  describe('the stance of a reviewer', () => {
    const bob: Author = { association: 'MEMBER', bot: false, login: 'bob' }
    const stances = (p: PrData): unknown => {
      const poll: PollData = {
        errors: [],
        mine: [p],
        mineHasMore: false,
        rateLimit: null,
        toReview: [],
        toReviewHasMore: false,
        viewer: VIEWER,
      }
      const snap = buildSnapshot(snapshotInput(poll, structuredClone(EMPTY_STATE)))
      return snap.mine[0]?.reviewers.map(r => [r.name, r.stance])
    }
    const rev = (author: Author, state: PrReview['state'], at: number, id = `r${at}`): PrReview =>
      review(id, author, { state, submittedAt: at })

    it('approved, commented only, changes requested and asked only', () => {
      const p = pr({
        requestedUsers: ['carol'],
        reviews: [
          rev(member, 'APPROVED', 1),
          rev(bob, 'COMMENTED', 2),
          rev(outsider, 'CHANGES_REQUESTED', 3),
        ],
      })
      expect(stances(p)).toEqual([
        ['carol', 'none'],
        ['alice', 'approved'],
        ['bob', 'commented'],
        ['mallory', 'changes'],
      ])
    })

    it('the newest opinion wins, and a later comment does not change it', () => {
      const p = pr({
        reviews: [
          rev(member, 'CHANGES_REQUESTED', 5),
          rev(member, 'APPROVED', 9),
          rev(member, 'COMMENTED', 12),
          rev(bob, 'APPROVED', 2),
          rev(bob, 'CHANGES_REQUESTED', 1),
        ],
      })
      expect(stances(p)).toEqual([
        ['alice', 'approved'],
        ['bob', 'approved'],
      ])
    })

    it('reads the opinion from the decisions too', () => {
      const p = pr({ decisions: [rev(member, 'CHANGES_REQUESTED', 3)] })
      expect(stances(p)).toEqual([['alice', 'changes']])
    })

    it('a dismissed latest opinion is grey, even after a comment', () => {
      const p = pr({
        reviews: [
          rev(member, 'APPROVED', 1),
          rev(member, 'DISMISSED', 2),
          rev(member, 'COMMENTED', 3),
        ],
      })
      expect(stances(p)).toEqual([['alice', 'none']])
    })

    it('a new request keeps the colour of the last opinion', () => {
      const p = pr({ requestedUsers: ['alice'], reviews: [rev(member, 'CHANGES_REQUESTED', 1)] })
      expect(stances(p)).toEqual([['alice', 'changes']])
    })

    it('Copilot is always grey, and the viewer is not listed', () => {
      const p = pr({
        reviews: [
          rev(copilot, 'APPROVED', 1),
          rev(copilot, 'CHANGES_REQUESTED', 2),
          rev(viewer, 'APPROVED', 3),
        ],
      })
      expect(stances(p)).toEqual([['Copilot', 'none']])
    })
  })
})

describe('CI state on To review rows (user decision, 2026-11-13)', () => {
  const HEAD = 'a'.repeat(40)
  const mk = (n: number, over: Partial<PrData> = {}) =>
    pr({ headSha: HEAD, key: `acme/app#${n}`, number: n, requestedUsers: [VIEWER], ...over })
  const pollOf = (toReview: PrData[]): PollData => ({
    errors: [],
    mine: [],
    mineHasMore: false,
    rateLimit: null,
    toReview,
    toReviewHasMore: false,
    viewer: VIEWER,
  })
  const mark = (value: 'approve' | 'comment', reviewId: string | null) => ({
    at: 100,
    headSha: HEAD,
    reviewId,
    value,
    why: 'Small and safe.',
  })
  const rowsOf = (poll: PollData, state = structuredClone(EMPTY_STATE)) =>
    Object.fromEntries(buildSnapshot(snapshotInput(poll, state)).toReview.map(r => [r.key, r]))

  it('gives the row the CI state: failing, running, or null for passed and no CI', () => {
    const rows = rowsOf(
      pollOf([
        mk(1, { ci: 'failing' }),
        mk(2, { ci: 'running' }),
        mk(3, { ci: 'passed' }),
        mk(4, { ci: null }),
      ]),
    )
    expect(rows['acme/app#1']?.ci).toBe('failing')
    expect(rows['acme/app#2']?.ci).toBe('running')
    expect(rows['acme/app#3']?.ci).toBeNull()
    expect(rows['acme/app#4']?.ci).toBeNull()
  })

  it('keeps the row state of Bifrost: the CI state does not change it', () => {
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('comment', null) }
    const rows = rowsOf(pollOf([mk(1, { ci: 'failing' }), mk(2, { ci: 'failing' })]), state)
    expect(rows['acme/app#1']).toMatchObject({ ci: 'failing', state: 'reviewed' })
    expect(rows['acme/app#2']).toMatchObject({ ci: 'failing', state: 'new' })
  })

  it('shows no Approve button for failing CI', () => {
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    state.prs['acme/app#2'] = { ...emptyPrState(), recommendation: mark('approve', 'r2') }
    const rows = rowsOf(
      pollOf([mk(1, { ci: 'failing' }), mk(2, { ci: 'failing', viewerPendingReviewId: 'r2' })]),
      state,
    )
    expect(rows['acme/app#1']?.approve).toBeNull()
    expect(rows['acme/app#2']?.approve).toBeNull()
  })

  it('disables the Approve button while CI runs, and enables it for passed and no CI', () => {
    const state = structuredClone(EMPTY_STATE)
    for (const n of [1, 2, 3]) {
      state.prs[`acme/app#${n}`] = { ...emptyPrState(), recommendation: mark('approve', null) }
    }
    const rows = rowsOf(
      pollOf([mk(1, { ci: 'running' }), mk(2, { ci: 'passed' }), mk(3, { ci: null })]),
      state,
    )
    expect(rows['acme/app#1']?.approve).toBe('ci-running')
    expect(rows['acme/app#2']?.approve).toBe('ready')
    expect(rows['acme/app#3']?.approve).toBe('ready')
  })

  it('shows no button for a row that has no Approve mark, whatever the CI state', () => {
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('comment', null) }
    const rows = rowsOf(pollOf([mk(1, { ci: 'running' }), mk(2, { ci: 'running' })]), state)
    expect(rows['acme/app#1']?.approve).toBeNull()
    expect(rows['acme/app#2']?.approve).toBeNull()
  })

  it('a running Approve write wins over the CI wait', () => {
    const state = structuredClone(EMPTY_STATE)
    state.prs['acme/app#1'] = { ...emptyPrState(), recommendation: mark('approve', null) }
    const input = {
      ...snapshotInput(pollOf([mk(1, { ci: 'running' })]), state),
      approval: () => ({ at: 900, phase: 'running' as const }),
    }
    expect(buildSnapshot(input).toReview[0]?.approve).toBe('running')
  })
})
