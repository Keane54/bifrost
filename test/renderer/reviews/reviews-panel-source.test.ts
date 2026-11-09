import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const dir = join(__dirname, '../../../src/renderer/src/reviews')
const ROW = readFileSync(join(dir, 'ReviewRow.tsx'), 'utf8')
const PANEL = readFileSync(join(dir, 'ReviewsPanel.tsx'), 'utf8')

describe('Reviews panel source', () => {
  it('puts the flash class on an aria-hidden overlay', () => {
    expect(ROW).toMatch(/<span[^>]*aria-hidden=\{true\}[^>]*animate-box-flash[^>]*bg-box-red\/35/s)
  })

  it('shows the flash only with the rowFlash setting', () => {
    expect(ROW).toContain('settings.rowFlash')
    expect(ROW).toMatch(/flash\s*&&\s*settings\.rowFlash/)
  })

  it('opens the PR on a Cmd+click', () => {
    expect(ROW).toMatch(/metaKey[\s\S]{0,200}openPr/)
  })

  it('shows the truncated tip on the status of a My PRs row', () => {
    expect(ROW).toMatch(
      /<Tip label=\{truncatedText\(row\)\}>\s*<span[^>]*STATUS_TEXT\[row\.status\]/,
    )
  })

  it('shows the team tag for each team request, not only in the team state', () => {
    expect(ROW).toMatch(/extra=\{\s*row\.team && \(/)
    expect(ROW).not.toContain("row.state === 'team' &&")
  })

  it('keeps the right side of line 2 in view when the row is narrow', () => {
    const lines = [
      ...ROW.matchAll(/<div className='relative flex [^']*whitespace-nowrap text-text-dim'/g),
    ].map(m => m[0])
    expect(lines).toHaveLength(2)
    for (const line of lines) expect(line).toMatch(/\bmin-w-0\b.*\boverflow-hidden\b/)
    expect(ROW).toMatch(/<span className='min-w-0 truncate'>\{row\.author\}<\/span>/)
    expect(ROW).toMatch(
      /<span className='min-w-0 truncate'>\{row\.reviewers\.join\(', '\)\}<\/span>/,
    )
    // The state on the right does not shrink.
    expect(ROW.match(/ml-auto[^']*shrink-0|shrink-0[^']*ml-auto/g)).toHaveLength(2)
  })

  it('takes the body from panelBody', () => {
    expect(PANEL).toContain('panelBody(snapshot, rows.length)')
    expect(PANEL).toContain("kind === 'error'")
    expect(PANEL.indexOf("kind === 'error'")).toBeLessThan(PANEL.indexOf('Nothing needs you here.'))
  })

  it('opens Settings from the off state', () => {
    expect(PANEL).toContain('useSettingsNav')
  })
})
