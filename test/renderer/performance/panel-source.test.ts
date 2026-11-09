// The Performance panel and its side bar button (design section 5, mockup v4).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the files.
const SRC = join(__dirname, '../../../src/renderer/src')
const read = (name: string): string => readFileSync(join(SRC, name), 'utf8')

const PANEL = read('performance/PerformancePanel.tsx')
const TREND = read('performance/TrendLine.tsx')
const STORE = read('performance/use-performance.ts')
const SIDE_BAR = read('wm/SideBar.tsx')
const WM = read('wm/WindowManager.tsx')

describe('PerformancePanel source', () => {
  it('shows each reason as its own item with a 6 px gap (user decision, 2026-11-09)', () => {
    expect(PANEL).toMatch(/className='[^']*\bgap-1\.5\b[^']*'\s+data-perf-reasons/)
  })

  it('starts each reason with a small square in the colour of its level', () => {
    expect(PANEL).toMatch(/problem: 'bg-ctx-high'/)
    expect(PANEL).toMatch(/warning: 'bg-ctx-mid'/)
    expect(PANEL).toMatch(/cx\('[^']*\bsize-1\b[^']*', REASON_SQUARE\[reason\.level\]\)/)
  })

  it('colours the headline with the state tokens', () => {
    expect(PANEL).toMatch(/ok: 'text-ctx-low'/)
    expect(PANEL).toMatch(/warning: 'text-ctx-mid'/)
    expect(PANEL).toMatch(/problem: 'text-ctx-high'/)
  })

  it('gives the Details row a bottom border only while it is open (user decision, 2026-11-09)', () => {
    const details = PANEL.slice(PANEL.indexOf('data-perf-details'))
    const button = PANEL.slice(PANEL.lastIndexOf('<button', PANEL.indexOf('data-perf-details')))
    expect(details.length).toBeGreaterThan(0)
    expect(button).toMatch(/aria-expanded=\{open\}/)
    expect(PANEL).toMatch(/open && 'border-panel-edge border-b'/)
    // The base class of the row has no bottom border.
    const base = button.match(/cx\(\s*'([^']*)'/)?.[1] ?? ''
    expect(base).not.toMatch(/\bborder-b\b/)
  })

  it('keeps the Details choice in the UI state (P10)', () => {
    expect(PANEL).toContain('usePerformanceDetails()')
  })

  it('shows Stop only when actionStateFor allows it, and uses the Stop action', () => {
    const check = PANEL.indexOf("actionStateFor('stop'")
    const stop = PANEL.indexOf("run('stop', ")
    expect(check).toBeGreaterThan(-1)
    expect(stop).toBeGreaterThan(check)
    expect(PANEL).toMatch(/\.enabled && \(/)
    // The row comes from the registry by the session ID, never from a pid.
    expect(PANEL).toMatch(/rows\.find\(r => r\.sessionId === session\.sessionId\)/)
  })

  it('draws the trend line as an inline SVG polyline in token colours', () => {
    expect(TREND).toContain('<polyline')
    expect(TREND).toContain("stroke='currentColor'")
    expect(PANEL).toContain('<TrendLine')
  })
})

describe('one Performance subscription', () => {
  it('has one onUpdate subscription, in the store', () => {
    expect(STORE.match(/\.onUpdate\(/g)).toHaveLength(1)
    expect(PANEL).not.toContain('onUpdate(')
    expect(SIDE_BAR).not.toContain('onUpdate(')
  })

  it('feeds the panel and the side bar from the store', () => {
    expect(PANEL).toMatch(/from '\.\/use-performance'/)
    expect(PANEL).toContain('usePerformance()')
    expect(SIDE_BAR).toMatch(/from '\.\.\/performance\/use-performance'/)
    expect(SIDE_BAR).toContain('usePerformanceState()')
  })

  it('has one view reporter, in the window manager (ruling 4)', () => {
    expect(STORE.match(/performance\.view\(/g)).toHaveLength(1)
    expect(PANEL).not.toContain('.view(')
    expect(WM).toContain('usePerformanceReport(state.frames)')
  })

  it('saves the Details choice with the UI state (P10)', () => {
    expect(WM).toMatch(/performance: performanceRef\.current/)
  })
})

describe('Performance side bar button', () => {
  it('uses the HeartPulse icon and opens the panel', () => {
    expect(SIDE_BAR).toContain('HeartPulse')
    expect(SIDE_BAR).toMatch(/label='Performance'/)
    expect(SIDE_BAR).toContain("open('performance')")
  })

  it('shows a dot in the state colour with the state in the tooltip', () => {
    expect(SIDE_BAR).toMatch(/problem: 'bg-ctx-high'/)
    expect(SIDE_BAR).toMatch(/warning: 'bg-ctx-mid'/)
    expect(SIDE_BAR).toContain("'Performance - Problem'")
    expect(SIDE_BAR).toContain("'Performance - Warning'")
  })

  it('keeps the white dot of the other buttons', () => {
    expect(SIDE_BAR).toMatch(/props\.dotClass \?\? 'bg-text-strong'/)
  })
})
