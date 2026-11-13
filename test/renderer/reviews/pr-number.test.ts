// The PR number on line 1 of a review row is a link to the PR. It must look like a link on
// hover, and a click on it must open the PR and not the action of the row under it.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement, type ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { PR_NUMBER_LINK, PrNumber } from '../../../src/renderer/src/reviews/PrNumber'

const ROOT = join(__dirname, '../../..')

describe('PrNumber', () => {
  it('shows the number as a button with a clear name', () => {
    const html = renderToStaticMarkup(createElement(PrNumber, { number: 42, onOpen: () => {} }))
    expect(html).toContain('type="button"')
    expect(html).toContain('aria-label="Open PR #42 on GitHub"')
    expect(html).toContain('>#42</button>')
  })

  it('shows a pointer, an underline and a brighter colour on hover, with a transition', () => {
    const classes = PR_NUMBER_LINK.split(' ')
    for (const name of [
      'cursor-pointer',
      'text-text-dim',
      'hover:text-text',
      'hover:underline',
      'transition-colors',
      'duration-150',
    ]) {
      expect(classes).toContain(name)
    }
  })

  it('opens the PR and stops the click before it reaches the row', () => {
    const onOpen = vi.fn()
    const button = PrNumber({ number: 7, onOpen }) as ReactElement<{
      onClick: (e: { stopPropagation: () => void }) => void
    }>
    const stopPropagation = vi.fn()
    button.props.onClick({ stopPropagation })
    expect(stopPropagation).toHaveBeenCalledOnce()
    expect(onOpen).toHaveBeenCalledOnce()
  })
})

describe('the review rows', () => {
  const source = readFileSync(join(ROOT, 'src/renderer/src/reviews/ReviewRow.tsx'), 'utf8')

  it('show the PR number through PrNumber on both kinds of row', () => {
    expect(source).toContain('<PrNumber number={number} onOpen={onOpenPr} />')
    const opens = source.match(
      /onOpenPr=\{\(\) => onAct\(\(\) => window\.bifrost\.reviews\.openPr\(row\.key\)\)\}/g,
    )
    expect(opens).toHaveLength(2)
    expect(source).not.toContain("<span className='shrink-0 text-text-dim'>#{number}</span>")
  })
})

describe('the other text links', () => {
  const read = (path: string): string => readFileSync(join(ROOT, path), 'utf8')

  it('change colour with a short transition on hover', () => {
    expect(read('src/renderer/src/reviews/AnswerPanel.tsx')).toContain(
      "const LINK =\n  'shrink-0 cursor-pointer text-text underline transition-colors duration-150 hover:text-text-strong'",
    )
    expect(read('src/renderer/src/reviews/ReviewDraft.tsx')).toContain(
      'transition-colors duration-150 hover:text-text disabled:opacity-40',
    )
    expect(read('src/renderer/src/info/ShowInfoPanel.tsx')).toContain(
      'underline transition-opacity duration-150 hover:opacity-80',
    )
  })
})
