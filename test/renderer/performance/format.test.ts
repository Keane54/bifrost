// The texts and the trend line points of the Performance panel (design section 5.2).
import { describe, expect, it } from 'vitest'
import {
  gb,
  mb,
  ms,
  percent,
  pointsText,
  pressureText,
  rate,
  thermalText,
  trendLines,
} from '../../../src/renderer/src/performance/format'

describe('mb', () => {
  it('gives a whole number of MB below 1024 MB', () => {
    expect(mb(712)).toBe('712 MB')
    expect(mb(0)).toBe('0 MB')
    expect(mb(1000)).toBe('1000 MB')
    expect(mb(1023.4)).toBe('1023 MB')
  })

  it('gives GB with two decimals from 1024 MB, divided by 1024', () => {
    expect(mb(1024)).toBe('1.00 GB')
    expect(mb(1341)).toBe('1.31 GB')
    expect(mb(2775)).toBe('2.71 GB')
  })

  it('lets the rounded MB value decide, so 1023.6 MB gives GB', () => {
    expect(mb(1023.6)).toBe('1.00 GB')
  })
})

describe('percent', () => {
  it('rounds to a whole percent', () => {
    expect(percent(2)).toBe('2%')
    expect(percent(1.6)).toBe('2%')
    expect(percent(0.4)).toBe('0%')
    expect(percent(112.5)).toBe('113%')
  })
})

describe('rate', () => {
  it('uses steps of 1000, as the network does', () => {
    expect(rate(84_000)).toBe('84 KB/s')
    expect(rate(1_200_000)).toBe('1.2 MB/s')
    expect(rate(512)).toBe('512 B/s')
    expect(rate(0)).toBe('0 B/s')
  })

  it('lets the rounded value decide the unit', () => {
    expect(rate(999.6)).toBe('1 KB/s')
    expect(rate(999_600)).toBe('1.0 MB/s')
  })
})

describe('ms', () => {
  it('gives a whole number of ms, or a word', () => {
    expect(ms(142)).toBe('142 ms')
    expect(ms(141.6)).toBe('142 ms')
    expect(ms('no-answer')).toBe('No answer')
    expect(ms('unreachable')).toBe("Can't reach")
    expect(ms(null)).toBe('-')
  })
})

describe('thermalText', () => {
  it('gives a word for each macOS thermal state', () => {
    expect(thermalText('nominal')).toBe('Normal')
    expect(thermalText('fair')).toBe('Fair')
    expect(thermalText('serious')).toBe('Serious')
    expect(thermalText('critical')).toBe('Critical')
    expect(thermalText(null)).toBe('-')
    expect(thermalText('unknown')).toBe('-')
  })
})

describe('pressureText', () => {
  it('gives Normal, Medium or High', () => {
    expect(pressureText('normal')).toBe('Normal')
    expect(pressureText('warn')).toBe('Medium')
    expect(pressureText('critical')).toBe('High')
    expect(pressureText(null)).toBe('-')
  })
})

describe('gb', () => {
  it('gives a whole number of GB (ruling 5)', () => {
    expect(gb(212.4)).toBe('212 GB')
    expect(gb(null)).toBe('-')
  })
})

describe('pointsText', () => {
  it('gives the points left of the limit and the reset time (ruling 6)', () => {
    const resetAt = Date.UTC(2026, 10, 9, 14, 52)
    expect(pointsText({ limit: 5000, remaining: 4320, resetAt }, 'UTC')).toBe(
      '4,320 of 5,000 left · resets 14:52',
    )
  })

  it('gives the reason when the points are not available', () => {
    expect(pointsText({ unavailable: "GitHub CLI isn't installed" })).toBe(
      "Not available - GitHub CLI isn't installed",
    )
    expect(pointsText(null)).toBe('-')
  })
})

describe('trendLines', () => {
  const t0 = 1_000_000

  it('gives no points for an empty trend', () => {
    expect(trendLines([])).toEqual({ cpu: '', ram: '' })
  })

  it('puts the last point at the right edge and 10 minutes at the full width', () => {
    const lines = trendLines([
      { at: t0, cpu: 0, ramMb: 700 },
      { at: t0 + 600_000, cpu: 50, ramMb: 1300 },
    ])
    // The RAM uses its own range. The CPU uses 0 to 100%.
    expect(lines.ram).toBe('0,32 500,2')
    expect(lines.cpu).toBe('0,32 500,17')
  })

  it('starts a short trend at the right side', () => {
    const lines = trendLines([
      { at: t0, cpu: 10, ramMb: 700 },
      { at: t0 + 60_000, cpu: 10, ramMb: 700 },
    ])
    // One minute is a tenth of the width. A flat RAM line is in the middle.
    expect(lines.ram).toBe('450,17 500,17')
  })

  it('drops points older than 10 minutes', () => {
    const lines = trendLines([
      { at: t0 - 1, cpu: 0, ramMb: 0 },
      { at: t0, cpu: 0, ramMb: 700 },
      { at: t0 + 600_000, cpu: 0, ramMb: 1300 },
    ])
    expect(lines.ram).toBe('0,32 500,2')
  })

  it('lets the CPU scale grow above 100%', () => {
    const lines = trendLines([
      { at: t0, cpu: 0, ramMb: 700 },
      { at: t0 + 600_000, cpu: 200, ramMb: 700 },
    ])
    expect(lines.cpu).toBe('0,32 500,2')
  })
})
