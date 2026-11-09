import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { REVIEWS_ROWS } from '../../../src/renderer/src/settings/reviews-rows'

// The repository has no DOM test. So this test reads the source text of the section.
const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')
const SECTION = readFileSync(join(SETTINGS, 'ReviewsSection.tsx'), 'utf8')

describe('Settings > Reviews', () => {
  it('has the labels from the spec', () => {
    expect(REVIEWS_ROWS).toEqual({
      autoFix: 'Handle comments on my PRs automatically',
      ignore: 'Repositories to ignore',
      maxSessions: 'Maximum PR sessions',
      pauseTime: 'Pause time',
      pollInterval: 'GitHub poll interval',
      requestModel: 'Model for request sessions',
      reviewModel: 'Model for review sessions',
      teamRequests: 'Show team requests',
      watch: 'Watch GitHub',
    })
  })

  it('takes each row label from REVIEWS_ROWS, and uses each label', () => {
    const labels = [...SECTION.matchAll(/(?<![\w-])label=(\{[^}]*\}|'[^']*'|"[^"]*")/g)].map(
      m => m[1],
    )
    const used = new Set([...SECTION.matchAll(/REVIEWS_ROWS\.(\w+)/g)].map(m => m[1]))
    for (const label of labels) {
      expect(label, 'a label from REVIEWS_ROWS or props').toMatch(
        /^\{(?:REVIEWS_ROWS\.\w+|props\.label)\}$/,
      )
    }
    expect(used).toEqual(new Set(Object.keys(REVIEWS_ROWS)))
  })

  it('asks with useConfirm before it saves each turn-on of Watch GitHub', () => {
    expect(SECTION).toContain('useConfirm()')
    const ask = SECTION.indexOf('await confirm(')
    const save = SECTION.indexOf('update({ reviewsWatch: true })')
    expect(ask).toBeGreaterThan(-1)
    expect(save).toBeGreaterThan(ask)
    expect(SECTION).toContain('!settings.reviewsWatch')
  })

  it('shows the later-version hint on each row that has no effect in R1', () => {
    for (const row of ['autoFix', 'maxSessions', 'requestModel', 'reviewModel']) {
      const at = SECTION.indexOf(`label={REVIEWS_ROWS.${row}}`)
      expect(at, row).toBeGreaterThan(-1)
      // The hint is a prop of the same element: it comes before the next element.
      const start = SECTION.lastIndexOf('<', at)
      const end = SECTION.indexOf('/>', at)
      expect(SECTION.slice(start, end), row).toContain('hint={LATER}')
    }
    expect(SECTION).toContain("const LATER = 'Comes in a later version.'")
    expect(SECTION).toMatch(/<SettingRow[\s\S]*?hint=\{props\.hint\}[\s\S]*?label=\{props\.label\}/)
  })

  it('has the ignore field, the Add button and the Remove button', () => {
    expect(SECTION).toContain("placeholder='owner/repo or owner/*'")
    expect(SECTION).toContain('Add')
    expect(SECTION).toContain("title='Remove'")
  })

  it('has a RowFilterContext provider', () => {
    expect(SECTION).toContain('<RowFilterContext value={only}>')
  })
})
