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

  it('opens Settings from the off state', () => {
    expect(PANEL).toContain('useSettingsNav')
  })
})
