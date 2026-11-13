// The pure texts and values of the Review panel (user decision, 2026-11-13).
import { describe, expect, it } from 'vitest'
import {
  CHANGED_TEXT,
  confirmText,
  draftTitle,
  editsOf,
  firstVerdict,
  placeText,
  yoursCount,
} from '../../../src/renderer/src/reviews/draft-text'
import type { DraftView } from '../../../src/shared/reviews'

const draft: DraftView = {
  body: 'Summary',
  changed: false,
  comments: [
    { body: 'One', hunk: [], id: 'C_1', line: 42, path: 'src/a.ts', startLine: null, yours: false },
    { body: 'Two', hunk: [], id: 'C_2', line: 9, path: 'src/b.ts', startLine: 7, yours: true },
    {
      body: 'Three',
      hunk: [],
      id: 'C_3',
      line: null,
      path: 'src/c.ts',
      startLine: null,
      yours: true,
    },
  ],
  key: 'acme/web#402',
  recommendation: 'request-changes',
  why: 'Why.',
}

describe('the Review panel texts', () => {
  it('gives the title with the PR', () => {
    expect(draftTitle('acme/web#402')).toBe('Review: acme/web #402')
    expect(draftTitle(null)).toBe('Review')
  })

  it('names the place of a comment', () => {
    expect(placeText(draft.comments[0] as DraftView['comments'][number])).toBe('src/a.ts line 42')
    expect(placeText(draft.comments[1] as DraftView['comments'][number])).toBe('src/b.ts lines 7-9')
    expect(placeText(draft.comments[2] as DraftView['comments'][number])).toBe('src/c.ts')
  })

  it('sets the switch first to the recommendation of Claude', () => {
    expect(firstVerdict('request-changes')).toBe('request-changes')
    expect(firstVerdict('comment')).toBe('comment')
    expect(firstVerdict('approve')).toBe('comment')
  })

  it('gives the edits of the panel: each comment with its text, or null when removed', () => {
    expect(editsOf(draft, 'New', { C_1: 'One more' }, { C_3: true }, 'comment')).toEqual({
      body: 'New',
      comments: [
        { body: 'One more', id: 'C_1' },
        { body: 'Two', id: 'C_2' },
        { body: null, id: 'C_3' },
      ],
      verdict: 'comment',
    })
  })

  it('counts the comments that the user added on GitHub', () => {
    expect(yoursCount(draft)).toBe(2)
    expect(yoursCount({ ...draft, comments: [] })).toBe(0)
  })

  it('says first that a delete of the draft also deletes the comments of the user', () => {
    expect(confirmText('discard', 1)).toBe(
      'Discard draft also deletes the comment you added to this draft on GitHub.',
    )
    expect(confirmText('discard', 2)).toBe(
      'Discard draft also deletes the 2 comments you added to this draft on GitHub.',
    )
    expect(confirmText('approve', 1)).toBe(
      'Approve instead also deletes the comment you added to this draft on GitHub.',
    )
  })

  it('says what a changed PR allows', () => {
    expect(CHANGED_TEXT).toBe(
      "This pull request changed after Claude's review, so you can't send or approve this " +
        'draft. You can still discard it.',
    )
  })
})
