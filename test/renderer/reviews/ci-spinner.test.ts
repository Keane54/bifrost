// A render of the CI spinner with react-dom/server. The spinner turns, and a system with reduced
// motion gets a still icon.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { CiSpinner } from '../../../src/renderer/src/reviews/CiSpinner'

const ROW = readFileSync(join(__dirname, '../../../src/renderer/src/reviews/ReviewRow.tsx'), 'utf8')

describe('CiSpinner', () => {
  const html = renderToStaticMarkup(createElement(CiSpinner))

  it('turns, and does not turn with the reduced motion setting of the system', () => {
    expect(html).toContain('animate-spin')
    expect(html).toContain('motion-reduce:animate-none')
  })

  it('is hidden from screen readers, because the text next to it says the state', () => {
    expect(html).toContain('aria-hidden="true"')
  })

  it('the row shows it only when showSpinner says so', () => {
    expect(ROW).toMatch(/showSpinner\(row\) && <CiSpinner/)
  })
})
