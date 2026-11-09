import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { countFailed, POLL_QUERY, parsePoll, pollArgs } from '../../../src/main/reviews/query'

const fixture = (name: string): string =>
  readFileSync(new URL(`../../fixtures/reviews/${name}.json`, import.meta.url), 'utf8')

function basic() {
  const r = parsePoll(fixture('poll-basic'))
  if (!r.ok) throw new Error(r.message)
  return r.data
}

describe('pollArgs', () => {
  it('builds the gh api graphql call', () => {
    expect(pollArgs()).toEqual(['api', 'graphql', '-f', `query=${POLL_QUERY}`])
    expect(POLL_QUERY).toContain('toReview: search(')
    expect(POLL_QUERY).toContain('mine: search(')
    expect(POLL_QUERY).toContain('review-requested:@me')
    expect(POLL_QUERY).toContain('author:@me')
  })
})

describe('parsePoll', () => {
  it('reads the viewer and the two lists', () => {
    const d = basic()
    expect(d.viewer).toBe('dev-user')
    expect(d.toReview).toHaveLength(3)
    expect(d.mine).toHaveLength(2)
    expect(d.toReview[0]).toMatchObject({
      author: 'alice',
      baseRef: 'main',
      headRef: 'feature-101',
      key: 'acme/web#101',
      number: 101,
      owner: 'acme',
      repo: 'web',
      truncated: false,
      url: 'https://github.com/acme/web/pull/101',
    })
  })

  it('keeps users as logins and teams as slugs', () => {
    const [direct, team] = basic().toReview
    expect(direct?.requestedUsers).toEqual(['dev-user'])
    expect(direct?.requestedTeams).toEqual(['web-team'])
    expect(team?.requestedUsers).not.toContain('dev-user')
    expect(team?.requestedUsers).toEqual(['carol'])
    expect(team?.requestedTeams).toEqual(['api-team'])
  })

  it('uses the newest request event as requestedAt, else createdAt', () => {
    const [direct, team, approved] = basic().toReview
    expect(direct?.requestedAt).toBe(Date.parse('2026-11-05T12:30:00Z'))
    expect(team?.requestedAt).toBe(Date.parse('2026-11-04T08:00:00Z'))
    expect(approved?.requestedAt).toBe(Date.parse('2026-11-01T09:00:00Z'))
    expect(approved?.reviewDecision).toBe('APPROVED')
  })

  it('reads the Copilot author as a bot', () => {
    const pr = basic().mine[0]
    const thread = pr?.threads[0]
    expect(thread?.isResolved).toBe(false)
    expect(thread?.path).toBe('src/menu.ts')
    expect(thread?.line).toBe(42)
    expect(thread?.reviewId).toBe('R_c2')
    expect(thread?.comments[0]?.author).toEqual({
      association: 'NONE',
      bot: true,
      login: 'copilot-pull-request-reviewer',
    })
    expect(pr?.reviews[0]).toMatchObject({
      author: { association: 'MEMBER', bot: false, login: 'erin' },
      commit: 'bbbb222',
      state: 'CHANGES_REQUESTED',
    })
    expect(pr?.comments).toHaveLength(1)
  })

  it('counts failed checks and reads the head', () => {
    const [changes, approved] = basic().mine
    expect(changes?.failedChecks).toBe(1)
    expect(changes?.headSha).toBe('bbbb222')
    expect(approved?.failedChecks).toBe(0)
    expect(approved?.viewerPendingReviewId).toBe('R_p1')
    expect(changes?.viewerPendingReviewId).toBeNull()
    expect(approved?.threads[0]?.line).toBeNull()
  })

  it('sets truncated when a page has a next page', () => {
    const r = parsePoll(fixture('poll-truncated'))
    expect(r.ok && r.data.toReview[0]?.truncated).toBe(true)
  })

  it('drops a PR that lacks a key field', () => {
    const raw = JSON.parse(fixture('poll-basic'))
    delete raw.data.toReview.nodes[0].url
    raw.data.toReview.nodes[1] = null
    const r = parsePoll(JSON.stringify(raw))
    expect(r.ok && r.data.toReview).toHaveLength(1)
  })

  it('fails on bad JSON, on errors and on a missing viewer', () => {
    expect(parsePoll('not json').ok).toBe(false)
    const err = parsePoll(JSON.stringify({ errors: [{ message: 'Bad credentials' }] }))
    expect(err).toEqual({ message: 'Bad credentials', ok: false })
    expect(parsePoll('{"data":{}}').ok).toBe(false)
  })
})

describe('countFailed', () => {
  it('counts the six failure kinds and ignores the rest', () => {
    const contexts = [
      { __typename: 'CheckRun', conclusion: 'FAILURE' },
      { __typename: 'CheckRun', conclusion: 'TIMED_OUT' },
      { __typename: 'CheckRun', conclusion: 'CANCELLED' },
      { __typename: 'CheckRun', conclusion: 'STARTUP_FAILURE' },
      { __typename: 'CheckRun', conclusion: 'ACTION_REQUIRED' },
      { __typename: 'StatusContext', state: 'FAILURE' },
      { __typename: 'StatusContext', state: 'ERROR' },
      { __typename: 'CheckRun', conclusion: 'SUCCESS' },
      { __typename: 'CheckRun', conclusion: 'NEUTRAL' },
      { __typename: 'StatusContext', state: 'SUCCESS' },
      null,
      'x',
    ]
    expect(countFailed(contexts)).toBe(7)
  })
})
