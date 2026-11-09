import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')

// The Save rule (review of batch C, Important 1): the state of a row goes away when the row
// unmounts. A General row that a search hides keeps its hooks, so it must act as unmounted.
describe('a row that the search hides', () => {
  const general = readFileSync(join(SETTINGS, 'GeneralSection.tsx'), 'utf8')
  const row = readFileSync(join(SETTINGS, 'SettingRow.tsx'), 'utf8')
  const keys = readFileSync(join(SETTINGS, 'KeysSection.tsx'), 'utf8')
  const rows = readFileSync(join(SETTINGS, 'rows.tsx'), 'utf8')
  const reviews = readFileSync(join(SETTINGS, 'ReviewsSection.tsx'), 'utf8')

  // The shared rows moved to rows.tsx (decision R1-6). Their three useRowSave calls take the label
  // from props. Each section keeps the calls of its own rows.
  it('gives the label of each General row to useRowSave', () => {
    const calls = [...general.matchAll(/useRowSave\(([^)]*)\)/g)].map(m => m[1])
    expect(calls).toHaveLength(5)
    for (const arg of calls) expect(arg).toMatch(/^GENERAL_ROWS\.\w+$/)
  })

  it('gives the label of each shared row to useRowSave in rows.tsx', () => {
    const calls = [...rows.matchAll(/useRowSave\(([^)]*)\)/g)].map(m => m[1])
    expect(calls).toHaveLength(3)
    for (const arg of calls) expect(arg).toBe('props.label')
  })

  it('gives the label of each Reviews row to useRowSave', () => {
    const calls = [...reviews.matchAll(/useRowSave\(([^)]*)\)/g)].map(m => m[1])
    expect(calls.length).toBeGreaterThan(0)
    for (const arg of calls) expect(arg).toMatch(/^(?:REVIEWS_ROWS\.\w+|props\.label)$/)
  })

  // Re-review Important 1: a hook runs in the component that calls it. The filter of the search
  // reaches a useRowSave call only when the provider is in a component above that component.
  it.each([
    ['GeneralSection.tsx', 'GeneralSection', general],
    ['ReviewsSection.tsx', 'ReviewsSection', reviews],
  ])(
    'calls useRowSave only in components below the filter provider in %s',
    (_file, section, text) => {
      const functions = [
        ...text.matchAll(/^(?:export (?:default )?)?function (\w+)[\s\S]*?^\}$/gm),
      ].map(m => ({ body: m[0], name: m[1] }))
      const providers = functions.filter(f => f.body.includes('<RowFilterContext'))
      expect(providers.map(f => f.name)).toEqual([section])
      for (const f of providers) expect(f.body, f.name).not.toContain('useRowSave(')
      // Each other component with a useRowSave call renders inside the provider.
      const callers = functions.filter(f => f.body.includes('useRowSave(')).map(f => f.name)
      expect(callers.length).toBeGreaterThan(0)
      for (const name of callers) expect(text, name).toMatch(new RegExp(`<${name}\\b`))
    },
  )

  // The shared rows have no provider. Each one renders in a section that has the provider.
  it('calls useRowSave in rows.tsx only in components that a section renders', () => {
    expect(rows).not.toContain('<RowFilterContext')
    const functions = [
      ...rows.matchAll(/^(?:export (?:default )?)?function (\w+)[\s\S]*?^\}$/gm),
    ].map(m => ({ body: m[0], name: m[1] }))
    const callers = functions.filter(f => f.body.includes('useRowSave(')).map(f => f.name)
    expect(callers).toEqual(['NumberRow', 'CheckRow', 'SelectRow'])
    for (const name of callers) {
      expect(general + reviews, name).toMatch(new RegExp(`<${name}\\b`))
    }
  })

  it('removes its save state and its error while the search hides it', () => {
    expect(row).toMatch(/if \(shown\) return\s+tracker\?\.remove\(key\)\s+setError\(null\)/)
  })

  it('in Keys, shows the error at the top when the search hides the row of the error', () => {
    expect(keys).toContain('errorShownAtTop')
  })
})
