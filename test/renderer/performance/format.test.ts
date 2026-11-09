// The texts and the trend line points of the Performance panel (design section 5.2).
import { describe, expect, it } from 'vitest'
import {
  batteryText,
  gb,
  mb,
  ms,
  percent,
  pointsText,
  pressureText,
  rate,
  thermalText,
  trendLabel,
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
  it('gives a whole number of GB', () => {
    expect(gb(212.4)).toBe('212 GB')
    expect(gb(null)).toBe('-')
  })
})

describe('pointsText', () => {
  it('gives the points left of the limit and the reset time', () => {
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

  it('spreads a short trend over the full width, from the oldest point to the newest', () => {
    const lines = trendLines([
      { at: t0, cpu: 10, ramMb: 700 },
      { at: t0 + 60_000, cpu: 10, ramMb: 700 },
    ])
    // One minute fills the width. A flat RAM line is in the middle.
    expect(lines.ram).toBe('0,17 500,17')
    const three = trendLines([
      { at: t0, cpu: 0, ramMb: 700 },
      { at: t0 + 30_000, cpu: 0, ramMb: 700 },
      { at: t0 + 120_000, cpu: 0, ramMb: 700 },
    ])
    expect(three.ram).toBe('0,17 125,17 500,17')
  })

  it('puts one point at the right edge', () => {
    expect(trendLines([{ at: t0, cpu: 0, ramMb: 700 }])).toEqual({ cpu: '500,32', ram: '500,17' })
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

describe('trendLabel', () => {
  const t0 = 1_000_000
  const span = (ms: number) => [
    { at: t0, cpu: 0, ramMb: 700 },
    { at: t0 + ms, cpu: 0, ramMb: 700 },
  ]

  it('gives the whole minutes of a short trend, rounded up, from 1', () => {
    expect(trendLabel([])).toBe('Last 1 min')
    expect(trendLabel([{ at: t0, cpu: 0, ramMb: 700 }])).toBe('Last 1 min')
    expect(trendLabel(span(30_000))).toBe('Last 1 min')
    expect(trendLabel(span(60_000))).toBe('Last 1 min')
    expect(trendLabel(span(61_000))).toBe('Last 2 min')
    expect(trendLabel(span(8 * 60_000 + 30_000))).toBe('Last 9 min')
  })

  it('gives "Last 10 minutes" when the trend fills its 10 minutes', () => {
    expect(trendLabel(span(9 * 60_000 + 1000))).toBe('Last 10 minutes')
    expect(trendLabel(span(600_000))).toBe('Last 10 minutes')
    // Only the points of the 10-minute window count.
    expect(trendLabel([{ at: t0 - 60_000, cpu: 0, ramMb: 1 }, ...span(600_000)])).toBe(
      'Last 10 minutes',
    )
  })
})

describe('batteryText', () => {
  it('says charging, plugged in or on battery, with the whole percent', () => {
    expect(batteryText({ charging: true, onBattery: false, percent: 82.4 })).toBe('82%, charging')
    // A full battery on power is "charged", and macOS can also hold the charge at 80%. Both are on
    // power and not charging, which is not a fault.
    expect(batteryText({ charging: false, onBattery: false, percent: 100 })).toBe(
      '100%, plugged in',
    )
    expect(batteryText({ charging: false, onBattery: true, percent: 64 })).toBe('64%, on battery')
    expect(batteryText(null)).toBe('-')
  })
})
