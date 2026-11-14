// Tests of the dictation look: the values of the level, the smoothing and the parts that show.
import { describe, expect, it } from 'vitest'
import {
  BAR_WIDTH,
  dictationShows,
  EDGE_CLASS,
  edgeStyleOf,
  frameEdgeStyleOf,
  GLOW_CLASS,
  GREEN_VAR,
  glowStyleOf,
  greenAlpha,
  lookOf,
  smoothLevel,
} from '../../../src/renderer/src/chat/dictation-look'

describe('lookOf', () => {
  it('gives the spec values at level 0', () => {
    const look = lookOf(0)
    expect(look.borderAlpha).toBeCloseTo(0.35)
    expect(look.glowHeight).toBeCloseTo(3.5)
    expect(look.glowAlpha).toBeCloseTo(0.05)
    expect(look.glowBlur).toBeCloseTo(3.5)
    expect(look.barWidth).toBe(0)
  })

  it('gives the spec values at level 1', () => {
    const look = lookOf(1)
    expect(look.borderAlpha).toBeCloseTo(1)
    expect(look.glowHeight).toBeCloseTo(65)
    expect(look.glowAlpha).toBeCloseTo(0.65)
    expect(look.glowBlur).toBeCloseTo(12.3)
    expect(look.barWidth).toBe(BAR_WIDTH)
    expect(BAR_WIDTH).toBe(44)
  })

  it('rises with the level and has no jump', () => {
    let last = lookOf(0)
    for (let i = 1; i <= 100; i++) {
      const next = lookOf(i / 100)
      expect(next.glowHeight).toBeGreaterThanOrEqual(last.glowHeight)
      expect(next.glowAlpha).toBeGreaterThanOrEqual(last.glowAlpha)
      expect(next.glowBlur).toBeGreaterThanOrEqual(last.glowBlur)
      expect(next.borderAlpha).toBeGreaterThanOrEqual(last.borderAlpha)
      expect(next.glowHeight - last.glowHeight).toBeLessThan(5)
      expect(next.glowAlpha - last.glowAlpha).toBeLessThan(0.06)
      expect(next.glowBlur - last.glowBlur).toBeLessThan(0.8)
      expect(next.borderAlpha - last.borderAlpha).toBeLessThan(0.06)
      last = next
    }
  })

  it('keeps a level out of range inside the values', () => {
    expect(lookOf(-3)).toEqual(lookOf(0))
    expect(lookOf(7)).toEqual(lookOf(1))
    expect(lookOf(Number.NaN)).toEqual(lookOf(0))
  })
})

describe('smoothLevel', () => {
  it('rises faster than it falls', () => {
    const up = smoothLevel(0, 1, 0.03)
    const down = 1 - smoothLevel(1, 0, 0.03)
    expect(up).toBeGreaterThan(down)
  })

  it('reaches 63% of a step after the time constant', () => {
    expect(smoothLevel(0, 1, 0.06)).toBeCloseTo(1 - Math.exp(-1), 5)
    expect(1 - smoothLevel(1, 0, 0.22)).toBeCloseTo(1 - Math.exp(-1), 5)
  })

  it('stays still with no time and never passes the target', () => {
    expect(smoothLevel(0.4, 0.9, 0)).toBe(0.4)
    expect(smoothLevel(0.4, 0.9, 100)).toBeLessThanOrEqual(0.9)
    expect(smoothLevel(0.9, 0.4, 100)).toBeGreaterThanOrEqual(0.4)
  })
})

describe('what shows', () => {
  it('shows the green look only while the microphone listens', () => {
    expect(dictationShows('listening')).toBe(true)
    for (const phase of ['off', 'starting', 'downloading', 'stopping'] as const) {
      expect(dictationShows(phase)).toBe(false)
    }
  })

  it('never lets the glow take pointer input', () => {
    expect(GLOW_CLASS).toContain('pointer-events-none')
    expect(glowStyleOf(lookOf(0.5)).pointerEvents).toBe('none')
  })

  it('paints the glow down from the top border with the look values', () => {
    const style = glowStyleOf(lookOf(1))
    expect(style.height).toBe('65.0px')
    expect(style.left).toBe('3%')
    expect(style.right).toBe('3%')
    expect(style.filter).toBe('blur(12.3px)')
    expect(style.background).toContain('radial-gradient(ellipse 67% 100% at 50% 0%')
  })
})

describe('the green values', () => {
  it('mixes the green token with an alpha', () => {
    expect(greenAlpha(0.35)).toBe(`color-mix(in srgb, ${GREEN_VAR} 35.0%, transparent)`)
    expect(greenAlpha(0)).toBe(`color-mix(in srgb, ${GREEN_VAR} 0.0%, transparent)`)
  })

  it('gives the 1 px inner edge and the border and shadow of the frame', () => {
    const look = lookOf(1)
    expect(edgeStyleOf(look).background).toBe(greenAlpha(1))
    expect(EDGE_CLASS).toContain('pointer-events-none')
    const frame = frameEdgeStyleOf(look)
    expect(frame.borderTopColor).toBe(greenAlpha(1))
    expect(frame.boxShadow).toBe(`0 -12.0px 12.0px -12.0px ${greenAlpha(0.85)}`)
  })

  it('shows the shadow above the top edge only', () => {
    for (const level of [0, 0.5, 1]) {
      const m = /^0 -([\d.]+)px ([\d.]+)px -([\d.]+)px /.exec(
        String(frameEdgeStyleOf(lookOf(level)).boxShadow),
      )
      expect(m).not.toBeNull()
      const [offset, blur, spread] = [m?.[1], m?.[2], m?.[3]]
      // The shadow shrinks by the blur at each side, so the blur reaches the side edge, no more.
      expect(spread).toBe(blur)
      expect(offset).toBe(blur)
    }
  })

  it('has the glow stops of the mock', () => {
    const background = String(glowStyleOf(lookOf(1)).background)
    expect(background).toBe(
      'radial-gradient(ellipse 67% 100% at 50% 0%, ' +
        `${greenAlpha(0.65)} 0%, ${greenAlpha(0.65 * 0.35)} 45%, ${greenAlpha(0)} 75%)`,
    )
    expect(glowStyleOf(lookOf(1)).top).toBe('1px')
  })
})
