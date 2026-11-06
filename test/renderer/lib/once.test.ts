import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { once } from '../../../src/renderer/src/lib/once'

const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')

it('once runs the function at the first call only', () => {
  let calls = 0
  const run = once(() => {
    calls += 1
  })
  run()
  run()
  run()
  expect(calls).toBe(1)
})

// Review Minor 1: a search mounts the Live details block at many queries. Each status read runs
// claude plugin list. So the Settings panel reads the status one time for each view.
it('Live details reads its status through the one read of the Settings view', () => {
  const live = readFileSync(join(SETTINGS, 'LiveSection.tsx'), 'utf8')
  const panel = readFileSync(join(SETTINGS, 'SettingsPanel.tsx'), 'utf8')
  expect(live).not.toMatch(/void refresh\(\)\s*\n\s*\}, \[refresh\]\)/)
  expect(live).toContain('readStatus()')
  expect(panel).toMatch(/once\(\(\) => \{?\s*void refresh\(\)/)
})
