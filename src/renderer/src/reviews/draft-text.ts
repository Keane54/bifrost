// The texts and the values of the Review panel (user decision, 2026-11-13).
import type {
  DraftCommentView,
  DraftEdits,
  DraftView,
  Recommendation,
  SendVerdict,
} from '../../../shared/reviews'

export const CHANGED_TEXT =
  "This pull request changed after Claude's review, so you can't send or approve this " +
  'draft. You can still discard it.'

// The panel shows this text when the row no longer offers the draft: after an unknown result, an
// action that runs, or a draft that is gone.
export const LOCKED_TEXT =
  "You can't change this draft right now. The row in the Reviews panel shows why."

export const VERDICT_TEXT: Record<SendVerdict, string> = {
  comment: 'Comment',
  'request-changes': 'Request changes',
}

// The title of the panel, with the PR of the key.
export function draftTitle(key: string | null): string {
  return key === null ? 'Review' : `Review: ${key.replace('#', ' #')}`
}

// The place of a comment: the file and the line or the lines.
export function placeText(c: Pick<DraftCommentView, 'path' | 'line' | 'startLine'>): string {
  if (c.line === null) return c.path
  if (c.startLine !== null && c.startLine !== c.line)
    return `${c.path} lines ${c.startLine}-${c.line}`
  return `${c.path} line ${c.line}`
}

// The first value of the "Send as" switch: the recommendation of Claude.
export function firstVerdict(recommendation: Recommendation): SendVerdict {
  return recommendation === 'request-changes' ? 'request-changes' : 'comment'
}

// The edits of the panel for Send review: each comment of the draft with its text, or null when
// the user removed it.
export function editsOf(
  draft: DraftView,
  body: string,
  texts: Readonly<Record<string, string>>,
  removed: Readonly<Record<string, boolean>>,
  verdict: SendVerdict,
): DraftEdits {
  return {
    body,
    comments: draft.comments.map(c => ({
      body: removed[c.id] === true ? null : (texts[c.id] ?? c.body),
      id: c.id,
    })),
    verdict,
  }
}

// The count of the comments that the user added to the draft on GitHub.
export function yoursCount(draft: DraftView): number {
  return draft.comments.filter(c => c.yours).length
}

// The text that the panel shows before a delete of the draft that also deletes the comments of
// the user (ruling B8).
export function confirmText(action: 'discard' | 'approve', n: number): string {
  const button = action === 'discard' ? 'Discard draft' : 'Approve instead'
  const what = n === 1 ? 'the comment' : `the ${n} comments`
  return `${button} also deletes ${what} you added to this draft on GitHub.`
}
