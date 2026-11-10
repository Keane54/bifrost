import { describe, expect, it } from 'vitest'
import {
  BASE_ANGLE,
  BASE_COLOURS,
  CANVAS_SCALE,
  canvasSize,
  FIELD_FADE,
  gradientLine,
  hexColour,
  MAX_CANVAS_SIDE,
  MOTION_RATE,
  MOTION_STEP_MS,
  motionTime,
  partOf,
  stopColour,
} from '../../src/renderer/src/wm/background-paint'

// User decision, 2026-11-10: the motion moves 30 times each second, not at the display rate.
describe('the motion steps', () => {
  it('moves the background 30 times each second', () => {
    expect(MOTION_RATE).toBe(30)
    expect(MOTION_STEP_MS).toBeCloseTo(1000 / 30, 6)
  })

  it('gives the time of the motion clock: the time at the start of a run plus the run time', () => {
    expect(motionTime(0, 1000, 1000)).toBe(0)
    expect(motionTime(0, 1000, 1500)).toBe(500)
    // A run that starts after a pause continues from the paused time.
    expect(motionTime(12_345, 5000, 5100)).toBe(12_445)
  })

  it('never moves the clock back', () => {
    expect(motionTime(800, 1000, 900)).toBe(800)
  })
})

// User decision, 2026-11-10: each layer is a canvas that CSS scales up to its box. The stretch
// stays small, so the gradient keeps its fine dither and shows no bands or lines.
describe('the canvas size', () => {
  it('draws each canvas at a part of the device pixels of its box: from 1/4 to 1', () => {
    expect(CANVAS_SCALE).toBeGreaterThanOrEqual(1 / 4)
    expect(CANVAS_SCALE).toBeLessThanOrEqual(1)
  })

  it('gives the device size times the part, rounded up', () => {
    expect(canvasSize({ height: 2160, width: 3840 }, 1 / 2)).toEqual({ height: 1080, width: 1920 })
    expect(canvasSize({ height: 1001, width: 999 }, 1 / 2)).toEqual({ height: 501, width: 500 })
    expect(canvasSize({ height: 100, width: 100 }, 1 / 3)).toEqual({ height: 34, width: 34 })
  })

  it('uses CANVAS_SCALE when no part is given', () => {
    const size = canvasSize({ height: 1200, width: 2400 })
    expect(size).toEqual({
      height: Math.ceil(1200 * CANVAS_SCALE),
      width: Math.ceil(2400 * CANVAS_SCALE),
    })
  })

  it('keeps each side from 1 pixel to the largest side', () => {
    expect(canvasSize({ height: 0, width: 0 }, 1 / 2)).toEqual({ height: 1, width: 1 })
    expect(canvasSize({ height: 40_000, width: 50_000 }, 1 / 2)).toEqual({
      height: MAX_CANVAS_SIDE,
      width: MAX_CANVAS_SIDE,
    })
    expect(MAX_CANVAS_SIDE).toBeGreaterThanOrEqual(4096)
    expect(MAX_CANVAS_SIDE).toBeLessThanOrEqual(16_384)
  })

  it('gives 1 pixel for a size that is not a number', () => {
    expect(canvasSize({ height: Number.NaN, width: Number.POSITIVE_INFINITY }, 1 / 2)).toEqual({
      height: 1,
      width: 1,
    })
  })
})

describe('the paint of the layers', () => {
  // The fade of a field goes out from the centre on an eased curve. It is almost zero before the
  // edge, so the edge of the ellipse shows no line and no fringe of colour.
  it('fades each field from its full glow at the centre to zero at the edge', () => {
    expect(FIELD_FADE[0]).toEqual([0, 1])
    expect(FIELD_FADE[FIELD_FADE.length - 1]).toEqual([1, 0])
    expect(FIELD_FADE.length).toBeGreaterThanOrEqual(6)
    for (let i = 1; i < FIELD_FADE.length; i++) {
      expect(FIELD_FADE[i][0]).toBeGreaterThan(FIELD_FADE[i - 1][0])
      expect(FIELD_FADE[i][1]).toBeLessThan(FIELD_FADE[i - 1][1])
    }
    expect(FIELD_FADE[FIELD_FADE.length - 2][1]).toBeLessThanOrEqual(0.05)
  })

  // Yellow and orange come only from the fields, because a dark yellow or orange looks brown.
  it('makes the base from icon tokens, with no yellow or orange', () => {
    expect(BASE_COLOURS.length).toBeGreaterThanOrEqual(4)
    for (const name of BASE_COLOURS) expect(name).toMatch(/^icon-[1-6]$/)
    expect(BASE_COLOURS).not.toContain('icon-2')
    expect(BASE_COLOURS).not.toContain('icon-3')
    expect(BASE_ANGLE).toBe(120)
  })

  it('gives the gradient line of a CSS angle, through the centre of the box', () => {
    // Round to 6 places. The + 0 changes -0 to 0.
    const round = (line: number[]): number[] => line.map(n => Math.round(n * 1e6) / 1e6 + 0)
    // 90 degrees goes from the left edge to the right edge.
    expect(round(gradientLine(90, 200, 100))).toEqual([0, 50, 200, 50])
    // 180 degrees goes from the top edge to the bottom edge.
    expect(round(gradientLine(180, 200, 100))).toEqual([100, 0, 100, 100])
    // With an angle, the line is long enough that the corners get the first and the last stop.
    const [x0, y0, x1, y1] = gradientLine(120, 400, 300)
    const turn = (120 * Math.PI) / 180
    const length = 400 * Math.abs(Math.sin(turn)) + 300 * Math.abs(Math.cos(turn))
    expect(Math.hypot(x1 - x0, y1 - y0)).toBeCloseTo(length, 6)
    expect((x0 + x1) / 2).toBeCloseTo(200, 6)
    expect((y0 + y1) / 2).toBeCloseTo(150, 6)
    // 120 degrees points to the right and down.
    expect(x1).toBeGreaterThan(x0)
    expect(y1).toBeGreaterThan(y0)
  })

  it('reads a hex colour token', () => {
    expect(hexColour('#e8554e')).toEqual([232, 85, 78])
    expect(hexColour(' #5E9BEC ')).toEqual([94, 155, 236])
    expect(hexColour('#fff')).toEqual([255, 255, 255])
    expect(hexColour('')).toBeNull()
    expect(hexColour('red')).toBeNull()
    expect(hexColour('#12345')).toBeNull()
  })

  it('reads a strength token as a part of 1', () => {
    expect(partOf('15%')).toBeCloseTo(0.15, 9)
    expect(partOf(' 9% ')).toBeCloseTo(0.09, 9)
    expect(partOf('0.85')).toBeCloseTo(0.85, 9)
    expect(partOf('')).toBe(0)
    expect(partOf('none')).toBe(0)
  })

  it('writes a colour with an alpha for a canvas gradient stop', () => {
    expect(stopColour([232, 85, 78], 0.15)).toBe(
      `color(srgb ${232 / 255} ${85 / 255} ${78 / 255} / 0.15)`,
    )
    expect(stopColour([255, 0, 51], 0)).toBe('color(srgb 1 0 0.2 / 0)')
  })
})
