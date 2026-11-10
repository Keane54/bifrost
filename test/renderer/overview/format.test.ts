import { describe, expect, it } from 'vitest'
import { DEFAULT_WIDTHS } from '../../../src/renderer/src/overview/columns'
import {
  barFill,
  contextBand,
  formatAge,
  formatCost,
  formatPercent,
  previewLines,
  projectLabel,
  shownContextBand,
  stateLabel,
  stateTone,
} from '../../../src/renderer/src/overview/format'

describe('format', () => {
  it('shownContextBand uses the rounded percent, as the text shows it', () => {
    expect(shownContextBand(39.4)).toBe('low')
    expect(shownContextBand(39.6)).toBe('mid')
    expect(shownContextBand(69.6)).toBe('high')
    expect(shownContextBand(undefined)).toBeNull()
  })

  it('contextBand gives low below 40, mid from 40 to below 70, and high from 70', () => {
    expect(contextBand(0)).toBe('low')
    expect(contextBand(39.9)).toBe('low')
    expect(contextBand(40)).toBe('mid')
    expect(contextBand(69.9)).toBe('mid')
    expect(contextBand(70)).toBe('high')
    expect(contextBand(100)).toBe('high')
    expect(contextBand(undefined)).toBeNull()
    expect(contextBand(Number.NaN)).toBeNull()
  })

  it('projectLabel gives the last two parts of the path', () => {
    expect(projectLabel('/Users/o/Developer/bifrost')).toBe('Developer/bifrost')
    expect(projectLabel('/a')).toBe('a')
    expect(projectLabel('/')).toBe('/')
    expect(projectLabel('')).toBe('')
    expect(projectLabel('/x/y/')).toBe('x/y')
  })

  it('projectLabel shows the repository for a Claude worktree path', () => {
    expect(projectLabel('/Users/o/Developer/bifrost/.claude/worktrees/fix-a')).toBe(
      'Developer/bifrost',
    )
  })

  it('formatCost, formatPercent and formatAge give the cell text', () => {
    expect(formatCost(0.4249)).toBe('≈$0.42')
    expect(formatPercent(41.6)).toBe('42%')
    expect([59, 60, 3600, 86400].map(s => formatAge(0, s * 1000))).toEqual([
      '59 s',
      '1 min',
      '1 h',
      '1 d',
    ])
    expect(formatCost()).toBe('')
    expect(formatPercent()).toBe('')
  })

  it('formatCost gives <$0.01 for a cost above 0 and below one cent', () => {
    expect(formatCost(0.0042)).toBe('<$0.01')
    expect(formatCost(0.0099)).toBe('<$0.01')
    expect(formatCost(0.00001)).toBe('<$0.01')
    expect(formatCost(0.01)).toBe('≈$0.01')
    expect(formatCost(0)).toBe('≈$0.00')
  })

  // The cost is a simulated API cost, so it has the mark of an approximate value (user decision,
  // 2026-11-10). The text keeps two decimals.
  it('formatCost puts the approximate mark before the cost', () => {
    expect(formatCost(1.234)).toBe('≈$1.23')
    expect(formatCost(12)).toBe('≈$12.00')
    expect(formatCost(1234.5)).toBe('≈$1234.50')
    expect(formatCost(Number.POSITIVE_INFINITY)).toBe('')
  })

  // A cell has 4 px of padding on each side, and a character is 7.2 px wide (columns.ts). The
  // mark makes the text one character longer, so the default width must still hold ≈$123.45.
  it('the default width of the Cost column holds a cost of three digits with the mark', () => {
    const text = formatCost(123.45)
    expect(text.length * 7.2 + 8).toBeLessThanOrEqual(DEFAULT_WIDTHS.cost)
  })

  it('stateLabel gives the label of each state', () => {
    expect(stateLabel('needs-you')).toBe('Alert')
    expect(stateLabel('parked')).toBe('Parked')
  })

  it('stateTone gives red for an error and for a red box, and yellow for a yellow box', () => {
    expect(stateTone({ box: 'yellow', state: 'needs-you' })).toBe('yellow')
    expect(stateTone({ box: 'red', state: 'needs-you' })).toBe('red')
    expect(stateTone({ box: 'none', state: 'error' })).toBe('red')
    expect(stateTone({ box: 'none', state: 'working' })).toBe('active')
    expect(stateTone({ box: 'none', state: 'idle' })).toBe('dim')
    expect(stateTone({ box: 'none', state: 'parked' })).toBe('parked')
  })

  it('previewLines gives the first 3 lines with text', () => {
    expect(previewLines('\n a \n\nb\nc\nd')).toEqual(['a', 'b', 'c'])
    expect(previewLines(undefined)).toEqual([])
  })

  it('format functions give an empty text for a value that is not a finite number', () => {
    expect(formatCost(0)).toBe('≈$0.00')
    expect(formatPercent(0)).toBe('0%')
    expect(formatCost(Number.NaN)).toBe('')
    expect(formatPercent(null as unknown as number)).toBe('')
    expect(formatAge(Number.NaN, 5)).toBe('')
  })

  it('projectLabel shows the repository for a folder inside a Claude worktree', () => {
    expect(projectLabel('/Users/o/Developer/bifrost/.claude/worktrees/fix-a/src')).toBe(
      'Developer/bifrost',
    )
  })

  it('barFill gives the context bar fill from 0 to 100, and 0 without a value', () => {
    expect([41.6, -5, 140].map(p => barFill(p))).toEqual([41.6, 0, 100])
    expect(barFill(undefined)).toBe(0)
    expect(barFill(Number.NaN)).toBe(0)
  })
})
