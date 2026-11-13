// A render of the Review panel body with react-dom/server (ruling B4). All GitHub text is not
// trusted, so the panel must show it as text only, never as HTML or Markdown.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { LOCKED_TEXT } from '../../../src/renderer/src/reviews/draft-text'
import { ReviewDraft, type ReviewDraftProps } from '../../../src/renderer/src/reviews/ReviewDraft'
import type { DraftView } from '../../../src/shared/reviews'

const EVIL = '<img src=x onerror="alert(1)">'

const draft: DraftView = {
  body: `Summary ${EVIL} **bold**`,
  changed: false,
  comments: [
    {
      body: `Comment ${EVIL}`,
      hunk: ['@@ -1 +1 @@', '+<script>alert(2)</script>'],
      id: 'C_1',
      line: 4,
      path: 'src/<b>a</b>.ts',
      startLine: null,
      yours: false,
    },
    {
      body: 'Mine',
      hunk: ['+two'],
      id: 'C_2',
      line: 9,
      path: 'src/b.ts',
      startLine: null,
      yours: true,
    },
  ],
  key: 'acme/web#402',
  recommendation: 'request-changes',
  why: `Why ${EVIL} [link](https://evil.example)`,
}

const noop = (): void => undefined

// The opening tag of the button with the data attribute.
const tag = (html: string, attr: string): string =>
  new RegExp(`<button[^>]*${attr}[^>]*>`).exec(html)?.[0] ?? ''

function render(over: Partial<ReviewDraftProps> = {}): string {
  const props: ReviewDraftProps = {
    body: draft.body,
    busy: false,
    confirm: null,
    draft,
    locked: false,
    onApprove: noop,
    onBody: noop,
    onDiscard: noop,
    onKeep: noop,
    onRemove: noop,
    onSend: noop,
    onText: noop,
    onVerdict: noop,
    removed: {},
    texts: {},
    verdict: 'request-changes',
    ...over,
  }
  return renderToStaticMarkup(createElement(ReviewDraft, props))
}

describe('the Review panel body', () => {
  it('shows each GitHub text as text, never as HTML', () => {
    const html = render()
    expect(html).not.toContain('<img')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('<b>a</b>')
    expect(html).toContain('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;')
    expect(html).toContain('+&lt;script&gt;alert(2)&lt;/script&gt;')
    expect(html).toContain('src/&lt;b&gt;a&lt;/b&gt;.ts line 4')
    // Markdown stays as it is.
    expect(html).toContain('**bold**')
    expect(html).toContain('[link](https://evil.example)')
    expect(html).not.toContain('href=')
  })

  it("shows Claude's recommendation, the summary box and each comment with its box", () => {
    const html = render()
    expect(html).toContain('Claude suggests:')
    expect(html).toContain('Request changes')
    expect(html).toContain('Summary')
    expect(html).toContain('Comments (2)')
    expect(html.match(/<textarea/g)).toHaveLength(3)
    expect(html).toContain('data-draft-summary')
    expect(html).toContain('data-draft-comment="C_1"')
    expect(html).toContain('Added by you')
    expect(html.match(/>Remove</g)).toHaveLength(2)
  })

  it('shows a removed comment with Undo and no text box', () => {
    const html = render({ removed: { C_1: true } })
    expect(html.match(/<textarea/g)).toHaveLength(2)
    expect(html).toContain('You removed this comment.')
    expect(html).toContain('Undo')
  })

  it('has the footer: Discard draft, Approve instead, the Send as switch and Send review', () => {
    const html = render()
    for (const text of ['Discard draft', 'Approve instead', 'Send as', 'Comment', 'Send review']) {
      expect(html).toContain(text)
    }
    expect(tag(html, 'data-draft-send')).toContain('bg-review-changes/15')
    expect(tag(render({ verdict: 'comment' }), 'data-draft-send')).toContain('bg-review-comment/15')
  })

  it('asks first when a delete also deletes the comments of the user', () => {
    const html = render({ confirm: 'discard' })
    expect(html).toContain(
      'Discard draft also deletes the comment you added to this draft on GitHub.',
    )
    expect(html).toContain('Keep draft')
  })

  it('disables Send review and Approve instead when the PR changed', () => {
    const html = render({ draft: { ...draft, changed: true } })
    expect(html).toContain('This pull request changed after Claude&#x27;s review')
    expect(tag(html, 'data-draft-send')).toContain('disabled=""')
    expect(tag(html, 'data-draft-approve')).toContain('disabled=""')
    expect(tag(html, 'data-draft-discard')).not.toContain('disabled=""')
  })

  it('disables the actions and says why when the row no longer offers the draft', () => {
    const html = render({ locked: true })
    expect(html).toContain(LOCKED_TEXT.replaceAll("'", '&#x27;'))
    for (const attr of ['data-draft-send', 'data-draft-approve', 'data-draft-discard']) {
      expect(tag(html, attr), attr).toContain('disabled=""')
    }
    expect(render()).not.toContain(LOCKED_TEXT.replaceAll("'", '&#x27;'))
  })

  it('never uses dangerouslySetInnerHTML, a link or Markdown in the source', () => {
    const dir = join(__dirname, '../../../src/renderer/src/reviews')
    for (const file of ['ReviewDraft.tsx', 'ReviewPanel.tsx']) {
      const text = readFileSync(join(dir, file), 'utf8')
      expect(text, file).not.toContain('dangerouslySetInnerHTML')
      expect(text, file).not.toMatch(/<a\b|href=|markdown/i)
      expect(text, file).not.toMatch(/className=\{`/)
    }
  })
})
