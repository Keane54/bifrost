import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const PANEL = readFileSync(
  join(__dirname, '../../../src/renderer/src/service/ServiceStatusPanel.tsx'),
  'utf8',
)

// Review Minor 2: Geist Mono can load after the first measure. Then the width of the text changes,
// but the size of the panel does not.
describe('ServiceStatusPanel source', () => {
  it('observes each measure copy, so a change of its text width chooses the view again', () => {
    expect(PANEL).toMatch(
      /querySelectorAll\('\[data-service-measure\]'\)\)\s*\w+\??\.observe\(row\)/,
    )
  })

  it('chooses the view again when a web font loads', () => {
    expect(PANEL).toContain('document.fonts')
    expect(PANEL).toContain("'loadingdone'")
  })
})
