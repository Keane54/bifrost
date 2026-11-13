// The read of the draft review of Claude for the Review panel (user decision, 2026-11-13). The
// query reads the review by its node ID: its state, its body, its commit and each comment. Only
// reads. Each value goes as a variable, never inside the query text.

import { MAX_DRAFT_COMMENTS } from '../../shared/reviews'
import type { Gh } from './gh'
import { asRec, asString, call, nextCursor, nodesOf } from './review-query'

const PAGE = 100
// The most pages of comments that the read gets.
export const DRAFT_PAGES = Math.ceil(MAX_DRAFT_COMMENTS / PAGE)

const DRAFT_QUERY = `query DraftReview($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequestReview {
      id
      state
      body
      viewerDidAuthor
      commit { oid }
      comments(first: ${PAGE}, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id path line startLine originalLine originalStartLine diffHunk body }
      }
    }
  }
}`

// One comment of the draft. hunk is the full diff hunk that GitHub gives.
export interface DraftReadComment {
  id: string
  path: string
  line: number | null
  startLine: number | null
  hunk: string
  body: string
}

// The draft review as GitHub gives it. mine is true when the viewer wrote the review. truncated is
// true when the review has more comments than DRAFT_PAGES pages.
export interface DraftRead {
  id: string
  state: string
  body: string
  commit: string | null
  mine: boolean
  comments: DraftReadComment[]
  truncated: boolean
}

// detail is the raw text from gh or GitHub. The caller writes it to the Event log.
type Fail = { ok: false; message: string; detail?: string }

const lineOf = (now: unknown, original: unknown): number | null => {
  if (typeof now === 'number') return now
  return typeof original === 'number' ? original : null
}

function readComment(n: Record<string, unknown>): DraftReadComment | null {
  const id = asString(n.id)
  if (id === '') return null
  return {
    body: asString(n.body),
    hunk: asString(n.diffHunk),
    id,
    line: lineOf(n.line, n.originalLine),
    path: asString(n.path),
    startLine: lineOf(n.startLine, n.originalStartLine),
  }
}

// Read the review with this node ID, with its comments, up to DRAFT_PAGES pages.
export async function fetchDraft(
  gh: Gh,
  reviewId: string,
): Promise<{ ok: true; draft: DraftRead } | Fail> {
  const comments: DraftReadComment[] = []
  let head: Record<string, unknown> = {}
  let truncated = false
  let after: string | null = null
  for (let page = 1; ; page++) {
    const r = await call(gh, DRAFT_QUERY, { after, id: reviewId }, data => asRec(data).node)
    if (!r.ok) return r
    if (page === 1) head = r.pr
    for (const n of nodesOf(r.pr.comments)) {
      const comment = readComment(n)
      if (comment !== null) comments.push(comment)
    }
    after = nextCursor(r.pr.comments)
    if (after === null) break
    if (page >= DRAFT_PAGES) {
      truncated = true
      break
    }
  }
  const oid = asRec(head.commit).oid
  return {
    draft: {
      body: asString(head.body),
      comments,
      commit: typeof oid === 'string' ? oid : null,
      id: asString(head.id),
      mine: head.viewerDidAuthor === true,
      state: asString(head.state),
      truncated,
    },
    ok: true,
  }
}
