// A render of the reviewer names of a My PRs row. Each name has the colour of its stance.
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ReviewerNames } from '../../../src/renderer/src/reviews/ReviewRow'
import type { MyPrRow } from '../../../src/shared/reviews'

type Reviewers = MyPrRow['reviewers']

const html = (reviewers: Reviewers): string =>
  renderToStaticMarkup(createElement(ReviewerNames, { reviewers }))

describe('ReviewerNames', () => {
  it('colours each name by its stance', () => {
    const out = html([
      { name: 'ann', stance: 'approved' },
      { name: 'bob', stance: 'commented' },
      { name: 'cat', stance: 'changes' },
      { name: 'dan', stance: 'none' },
    ])
    expect(out).toMatch(/<span class="[^"]*text-svc-ok[^"]*">ann<\/span>/)
    expect(out).toMatch(/<span class="[^"]*text-review-comment[^"]*">bob<\/span>/)
    expect(out).toMatch(/<span class="[^"]*text-review-changes[^"]*">cat<\/span>/)
    expect(out).toMatch(/<span class="[^"]*text-text-dim[^"]*">dan<\/span>/)
  })

  it('keeps the order, and the separator stays dim', () => {
    const out = html([
      { name: 'ann', stance: 'approved' },
      { name: 'dan', stance: 'none' },
    ])
    expect(out.indexOf('ann')).toBeLessThan(out.indexOf('dan'))
    expect(out).toMatch(/<span class="[^"]*text-text-dim[^"]*">, <\/span>/)
  })

  it('renders nothing for no reviewers', () => {
    expect(html([])).toBe('')
  })
})
