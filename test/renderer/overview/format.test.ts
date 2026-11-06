import { describe, expect, it } from 'vitest'
import {
  barFill,
  formatAge,
  formatCost,
  formatPercent,
  previewLines,
  projectLabel,
  stateLabel,
  stateTone,
} from '../../../src/renderer/src/overview/format'

describe('format', () => {
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
    expect(formatCost(0.4249)).toBe('$0.42')
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
    expect(formatCost(0.01)).toBe('$0.01')
    expect(formatCost(0)).toBe('$0.00')
  })

  it('stateLabel gives the label of each state', () => {
    expect(stateLabel('needs-you')).toBe('Needs you')
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
    expect(formatCost(0)).toBe('$0.00')
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
