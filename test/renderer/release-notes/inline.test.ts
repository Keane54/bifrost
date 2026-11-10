import { describe, expect, it } from 'vitest'
import { inlineParts } from '../../../src/renderer/src/release-notes/inline'

describe('inlineParts', () => {
  it('gives one text part for plain text', () => {
    expect(inlineParts('add a Clear button')).toEqual([
      { kind: 'text', text: 'add a Clear button' },
    ])
  })

  it('reads bold and code', () => {
    expect(inlineParts('the **Performance** panel runs `pnpm dev` now')).toEqual([
      { kind: 'text', text: 'the ' },
      { kind: 'bold', text: 'Performance' },
      { kind: 'text', text: ' panel runs ' },
      { kind: 'code', text: 'pnpm dev' },
      { kind: 'text', text: ' now' },
    ])
  })

  it('keeps a marker with no end, and an empty pair, as text', () => {
    expect(inlineParts('a **b and `c')).toEqual([{ kind: 'text', text: 'a **b and `c' }])
    expect(inlineParts('x **** y `` z')).toEqual([{ kind: 'text', text: 'x **** y `` z' }])
  })

  it('shows the markers inside code as text, and code inside bold as text', () => {
    expect(inlineParts('`**not bold**`')).toEqual([{ kind: 'code', text: '**not bold**' }])
    expect(inlineParts('**a `b` c**')).toEqual([{ kind: 'bold', text: 'a `b` c' }])
  })

  it('keeps HTML, links and each other character as plain text', () => {
    const text = '<img src=x onerror=alert(1)> [a link](https://example.com) & _x_ *y*'
    expect(inlineParts(text)).toEqual([{ kind: 'text', text }])
  })

  it('gives no part for an empty text', () => {
    expect(inlineParts('')).toEqual([])
  })
})
