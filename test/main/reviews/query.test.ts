import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import {
  countFailed,
  MINE_FRAGMENT,
  POLL_QUERY,
  parsePoll,
  pollArgs,
  TO_REVIEW_FRAGMENT,
} from '../../../src/main/reviews/query'

const fixture = (name: string): string =>
  readFileSync(new URL(`../../fixtures/reviews/${name}.json`, import.meta.url), 'utf8')

// Set a value deep in a raw answer. The path has keys and list indexes.
function setAt(root: unknown, path: (string | number)[], value: unknown): void {
  let node = root as Record<string | number, unknown>
  for (const key of path.slice(0, -1)) node = node[key] as Record<string | number, unknown>
  node[path.at(-1) as string | number] = value
}

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
    expect(POLL_QUERY).toMatch(/toReview: search\([^)]*\) \{\s*pageInfo \{ hasNextPage \}/)
    expect(POLL_QUERY).toMatch(/mine: search\([^)]*\) \{\s*pageInfo \{ hasNextPage \}/)
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
      truncatedChecks: false,
      truncatedComments: false,
      truncatedReviews: false,
      truncatedThreads: false,
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

  it('reads the decision of each reviewer from latestOpinionatedReviews', () => {
    const [changes, approved] = basic().mine
    expect(changes?.decisions).toHaveLength(1)
    expect(changes?.decisions[0]).toMatchObject({
      author: { association: 'MEMBER', bot: false, login: 'erin' },
      id: 'R_c1',
      state: 'CHANGES_REQUESTED',
      submittedAt: Date.parse('2026-11-06T10:00:00Z'),
    })
    expect(approved?.decisions.map(d => [d.author.login, d.state])).toEqual([['frank', 'APPROVED']])
    // A To review PR reads no decisions.
    expect(basic().toReview[0]?.decisions).toEqual([])
  })

  it('sets truncatedThreads when GitHub has older threads', () => {
    const r = parsePoll(fixture('poll-truncated'))
    expect(r.ok && r.data.mine[0]).toMatchObject({
      truncatedChecks: false,
      truncatedComments: false,
      truncatedReviews: false,
      truncatedThreads: true,
    })
  })

  it('sets one flag for each list that GitHub cut', () => {
    // Set one value of the first My PR of the raw answer, then give the four flags.
    const cut = (path: (string | number)[], value: unknown) => {
      const raw = JSON.parse(fixture('poll-basic'))
      setAt(raw.data.mine.nodes[0], path, value)
      const r = parsePoll(JSON.stringify(raw))
      if (!r.ok) throw new Error(r.message)
      const pr = r.data.mine[0]
      return [
        pr?.truncatedThreads,
        pr?.truncatedReviews,
        pr?.truncatedComments,
        pr?.truncatedChecks,
      ]
    }
    const none = [false, false, false, false]
    expect(cut(['title'], 'x')).toEqual(none)
    const threadComments = ['reviewThreads', 'nodes', 0, 'comments', 'pageInfo', 'hasNextPage']
    expect(cut(threadComments, true)).toEqual([true, false, false, false])
    expect(cut(['reviewThreads', 'pageInfo', 'hasPreviousPage'], true)).toEqual([
      true,
      false,
      false,
      false,
    ])
    expect(cut(['reviews', 'pageInfo', 'hasNextPage'], true)).toEqual([false, true, false, false])
    expect(cut(['latestOpinionatedReviews', 'pageInfo', 'hasNextPage'], true)).toEqual([
      false,
      true,
      false,
      false,
    ])
    expect(cut(['comments', 'pageInfo', 'hasPreviousPage'], true)).toEqual([
      false,
      false,
      true,
      false,
    ])
    const contexts = ['commits', 'nodes', 0, 'commit', 'statusCheckRollup', 'contexts']
    expect(cut([...contexts, 'pageInfo', 'hasNextPage'], true)).toEqual([false, false, false, true])
  })

  it('reads whether each search has more PRs than the first page', () => {
    expect(basic()).toMatchObject({ mineHasMore: false, toReviewHasMore: false })
    const raw = JSON.parse(fixture('poll-basic'))
    raw.data.toReview.pageInfo.hasNextPage = true
    const r = parsePoll(JSON.stringify(raw))
    expect(r.ok && r.data).toMatchObject({ mineHasMore: false, toReviewHasMore: true })
    raw.data.toReview.pageInfo.hasNextPage = false
    raw.data.mine.pageInfo.hasNextPage = true
    const m = parsePoll(JSON.stringify(raw))
    expect(m.ok && m.data).toMatchObject({ mineHasMore: true, toReviewHasMore: false })
  })

  it('drops a PR that lacks a key field', () => {
    const raw = JSON.parse(fixture('poll-basic'))
    delete raw.data.toReview.nodes[0].url
    raw.data.toReview.nodes[1] = null
    const r = parsePoll(JSON.stringify(raw))
    expect(r.ok && r.data.toReview).toHaveLength(1)
  })

  it('drops a PR whose key is not a PR key', () => {
    const raw = JSON.parse(fixture('poll-basic'))
    raw.data.toReview.nodes[0].repository.owner.login = '-acme'
    raw.data.toReview.nodes[1].repository.name = 'a/b'
    const r = parsePoll(JSON.stringify(raw))
    expect(r.ok && r.data.toReview.map(pr => pr.key)).toEqual(['acme/web#102'])
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

describe('POLL_QUERY comment selections', () => {
  it('asks for pullRequestReview only inside reviewThreads', () => {
    const at = POLL_QUERY.indexOf('reviewThreads(')
    const top = POLL_QUERY.indexOf('comments(last:')
    expect(at).toBeGreaterThan(-1)
    expect(top).toBeGreaterThan(at)
    expect(POLL_QUERY.slice(0, at)).not.toContain('pullRequestReview')
    expect(POLL_QUERY.slice(top)).not.toContain('pullRequestReview')
    expect(POLL_QUERY.slice(at, top)).toContain('pullRequestReview { id }')
  })
})

describe('POLL_QUERY lists of a busy PR', () => {
  it('reads the newest 20 threads, the first 30 reviews and the decisions', () => {
    expect(MINE_FRAGMENT).toContain('reviewThreads(last: 20)')
    expect(MINE_FRAGMENT).toContain('reviews(first: 30)')
    expect(MINE_FRAGMENT).toMatch(
      /latestOpinionatedReviews\(first: 20\) \{[\s\S]*?author \{ login __typename \}[\s\S]*?state[\s\S]*?submittedAt/,
    )
    expect(TO_REVIEW_FRAGMENT).not.toContain('latestOpinionatedReviews')
  })
})

describe('POLL_QUERY fragments', () => {
  it('has no threads and no comments in the To review fragment', () => {
    expect(TO_REVIEW_FRAGMENT).not.toContain('reviewThreads')
    expect(TO_REVIEW_FRAGMENT).not.toContain('comments(')
    expect(MINE_FRAGMENT).toContain('reviewThreads')
    expect(POLL_QUERY).toContain('...ToReviewFields')
    expect(POLL_QUERY).toContain('...MineFields')
  })

  it('gives empty lists for a To review PR', () => {
    for (const pr of basic().toReview) {
      expect(pr.threads).toEqual([])
      expect(pr.comments).toEqual([])
    }
  })
})
