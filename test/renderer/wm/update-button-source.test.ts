// The repository has no DOM test. So this test reads the source text of the side bar.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../../src/renderer/src')
const BAR = readFileSync(join(SRC, 'wm/SideBar.tsx'), 'utf8')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')
const SECTION = readFileSync(join(SRC, 'settings/UpdatesSection.tsx'), 'utf8')

describe('side bar update button', () => {
  it('sits between the minimised frames and the Layouts button', () => {
    const minimised = BAR.indexOf('minimised.length > 0')
    const button = BAR.indexOf('<UpdateButton')
    const layouts = BAR.indexOf('<LayoutMenu')
    expect(minimised).toBeGreaterThan(-1)
    expect(button).toBeGreaterThan(minimised)
    expect(layouts).toBeGreaterThan(button)
  })

  it('shows a pulsing green dot and restarts for a ready update', () => {
    expect(BAR).toContain('dot={UPDATE_TEXTS.ready(update.version)}')
    expect(BAR).toContain('icon={CircleArrowDown}')
    expect(BAR).toMatch(/dotClass=\{cx\([^)]*bg-ctx-low[^)]*\)\}|dotClass='[^']*bg-ctx-low/s)
    expect(BAR).toContain('animate-update-pulse')
    expect(BAR).toContain('motion-reduce:animate-none')
    expect(BAR).toContain('window.bifrost.updates.restart()')
    expect(BAR).toContain("label='Update Bifrost'")
  })

  it('shows an orange triangle with no dot and opens Settings for a failed update', () => {
    expect(BAR).toContain('icon={TriangleAlert}')
    expect(BAR).toContain('text-ctx-mid')
    expect(BAR).toContain('dot={UPDATE_TEXTS.failed}')
    expect(BAR).toContain('dotHidden={true}')
    expect(BAR).toContain("settingsNav.open('updates')")
  })

  it('has the pulse animation in the style sheet', () => {
    expect(CSS).toMatch(/--animate-update-pulse:\s*update-pulse 1\.6s/)
    const keyframes = CSS.slice(CSS.indexOf('@keyframes update-pulse'))
    expect(keyframes).toContain('opacity: 0.35')
    expect(keyframes).toContain('scale: 0.8')
  })
})

describe('Settings Updates section', () => {
  it('hides the status block until the store has loaded', () => {
    expect(SECTION).toContain('useUpdatesLoaded()')
    expect(SECTION).toMatch(/only === null && loaded && \(/)
  })
})
