import { describe, expect, it } from 'vitest'
import {
  BASE_ANGLE,
  BASE_COLOURS,
  basePainter,
  basePixels,
  CANVAS_SCALE,
  canvasSize,
  DITHER_TILE,
  ditherNoise,
  FIELD_FADE,
  fieldFade,
  fieldPainter,
  fieldPixels,
  gradientLine,
  hexColour,
  MAX_CANVAS_SIDE,
  MOTION_RATE,
  MOTION_STEP_MS,
  motionTime,
  partOf,
  stopColour,
  unpremultiplied,
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
// stays small, so the grain of the dither stays fine.
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

// The premultiplied value that the canvas stores for a pixel of the dithered paint: the canvas
// gets the colour without the alpha and multiplies it by the alpha, with rounding.
function stored(pixels: Uint8ClampedArray, i: number, channel: number): number {
  return Math.round((pixels[i + channel] * pixels[i + 3]) / 255)
}

// The number of times that a list of values changes its direction (up to down, or down to up).
function turns(values: number[]): number {
  let count = 0
  let last = 0
  for (let i = 1; i < values.length; i++) {
    const direction = Math.sign(values[i] - values[i - 1])
    if (direction === 0) continue
    if (last !== 0 && direction !== last) count += 1
    last = direction
  }
  return count
}

// User decision, 2026-11-10: the paint adds a fine dither to each canvas. A plain gradient of a
// faint colour has only a few 8-bit steps, and each step shows as a soft band.
describe('the dither', () => {
  it('makes the same tile of triangular noise from -1 to 1 for the same seed', () => {
    const noise = ditherNoise(1)
    expect(noise.length).toBe(DITHER_TILE * DITHER_TILE)
    expect(ditherNoise(1)).toEqual(noise)
    expect(ditherNoise(2)).not.toEqual(noise)
    let sum = 0
    let near = 0
    for (const n of noise) {
      expect(n).toBeGreaterThan(-1)
      expect(n).toBeLessThan(1)
      sum += n
      if (Math.abs(n) < 0.5) near += 1
    }
    expect(Math.abs(sum / noise.length)).toBeLessThan(0.01)
    // Triangular noise has 3/4 of its values from -0.5 to 0.5. Flat noise has 1/2.
    expect(near / noise.length).toBeGreaterThan(0.72)
    expect(near / noise.length).toBeLessThan(0.78)
  })

  it('gives a colour that the canvas multiplies back to the same premultiplied value', () => {
    for (let alpha = 1; alpha <= 255; alpha++) {
      for (let premultiplied = 0; premultiplied <= alpha; premultiplied++) {
        const colour = unpremultiplied(premultiplied, alpha)
        expect(Number.isInteger(colour)).toBe(true)
        expect(Math.round((colour * alpha) / 255)).toBe(premultiplied)
        // A fast path of the canvas divides by 256, not 255. The faint alphas of the background
        // give the same value on that path too.
        if (alpha <= 128) expect((colour * alpha + 255) >> 8).toBe(premultiplied)
      }
    }
    expect(unpremultiplied(0, 0)).toBe(0)
  })

  it('gives the fade of a field at a distance from its centre', () => {
    expect(fieldFade(0)).toBe(1)
    expect(fieldFade(0.2)).toBeCloseTo(0.7, 9)
    expect(fieldFade(0.1)).toBeCloseTo(0.85, 9)
    expect(fieldFade(0.9)).toBeCloseTo(0.015, 9)
    expect(fieldFade(1)).toBe(0)
    expect(fieldFade(1.5)).toBe(0)
  })

  describe('the pixels of a field', () => {
    const size = { height: 300, width: 500 }
    const colour = [155, 128, 230] as const
    const glow = 0.15
    const pixels = fieldPixels(size, colour, glow, 3)
    // The smooth premultiplied value of a channel (0 to 3, 3 is the alpha) at a pixel.
    const smooth = (x: number, y: number, channel: number): number => {
      const u = (x + 0.5 - size.width / 2) / (size.width / 2)
      const v = (y + 0.5 - size.height / 2) / (size.height / 2)
      const alpha = 255 * glow * fieldFade(Math.hypot(u, v))
      return channel === 3 ? alpha : (colour[channel] * alpha) / 255
    }

    it('gives one RGBA pixel for each pixel of the canvas', () => {
      expect(pixels.length).toBe(size.width * size.height * 4)
    })

    it('gives the same pixels each time, so the dither does not move', () => {
      expect(fieldPixels(size, colour, glow, 3)).toEqual(pixels)
      expect(fieldPixels(size, colour, glow, 4)).not.toEqual(pixels)
    })

    it('gives the same pixels when it paints a few rows at a time', () => {
      const painter = fieldPainter(size, colour, glow, 3)
      for (let row = 0; row < size.height; row += 37) painter.rows(row, row + 37)
      expect(painter.pixels).toEqual(pixels)
    })

    it('keeps each value less than 1.5 steps from the smooth value', () => {
      for (let y = 0; y < size.height; y += 7) {
        for (let x = 0; x < size.width; x += 3) {
          const i = (y * size.width + x) * 4
          for (const channel of [0, 1, 2]) {
            expect(Math.abs(stored(pixels, i, channel) - smooth(x, y, channel))).toBeLessThan(1.5)
          }
          expect(Math.abs(pixels[i + 3] - smooth(x, y, 3))).toBeLessThan(1.5)
        }
      }
    })

    it('keeps the mean of each area at the smooth value', () => {
      for (const [x0, y0] of [
        [240, 140],
        [100, 150],
        [250, 40],
        [380, 220],
      ]) {
        const sums = [0, 0, 0, 0]
        const targets = [0, 0, 0, 0]
        for (let y = y0; y < y0 + 20; y++) {
          for (let x = x0; x < x0 + 20; x++) {
            const i = (y * size.width + x) * 4
            for (const channel of [0, 1, 2]) sums[channel] += stored(pixels, i, channel)
            sums[3] += pixels[i + 3]
            for (const channel of [0, 1, 2, 3]) targets[channel] += smooth(x, y, channel)
          }
        }
        for (const channel of [0, 1, 2, 3]) {
          expect(Math.abs(sums[channel] - targets[channel]) / 400).toBeLessThan(0.1)
        }
      }
    })

    it('keeps a full glow valid: white at the centre, not black', () => {
      // The centre pixel of an odd size gets the full glow. With the noise, the alpha can go
      // over 255 before the rounding. The seeds give many values of the noise at the centre.
      for (let seed = 1; seed <= 64; seed++) {
        const full = fieldPixels({ height: 41, width: 41 }, [255, 255, 255], 1, seed)
        const i = (20 * 41 + 20) * 4
        expect([...full.slice(i, i + 3)]).toEqual([255, 255, 255])
        expect(full[i + 3]).toBeGreaterThanOrEqual(254)
      }
    })

    it('leaves the corners out of the ellipse empty', () => {
      for (const [x, y] of [
        [0, 0],
        [size.width - 1, 0],
        [0, size.height - 1],
        [size.width - 1, size.height - 1],
      ]) {
        const i = (y * size.width + x) * 4
        expect([...pixels.slice(i, i + 4)]).toEqual([0, 0, 0, 0])
      }
    })

    it('mixes the steps of the gradient, so it shows no bands', () => {
      // From the edge to the centre, a plain gradient only goes up, in steps of about 7 pixels on
      // this row. Each step edge is a band. The dither mixes the two values at each edge.
      const row = size.height / 2
      const alphas: number[] = []
      for (let x = 20; x < size.width / 2 - 20; x++)
        alphas.push(pixels[(row * size.width + x) * 4 + 3])
      expect(turns(alphas)).toBeGreaterThan(40)
    })
  })

  describe('the pixels of the base', () => {
    const size = { height: 200, width: 400 }
    const stops = [
      [0, [116, 200, 142]],
      [0.5, [94, 155, 236]],
      [1, [232, 85, 78]],
    ] as const
    const alpha = 0.09
    const pixels = basePixels(size, stops, alpha, BASE_ANGLE, 6)
    const [x0, y0, x1, y1] = gradientLine(BASE_ANGLE, size.width, size.height)
    // The smooth premultiplied value of a colour channel at a pixel.
    const smooth = (x: number, y: number, channel: number): number => {
      const dx = x1 - x0
      const dy = y1 - y0
      const t = Math.min(
        1,
        Math.max(0, ((x + 0.5 - x0) * dx + (y + 0.5 - y0) * dy) / (dx * dx + dy * dy)),
      )
      const [a, b, part] =
        t < 0.5 ? [stops[0][1], stops[1][1], t / 0.5] : [stops[1][1], stops[2][1], (t - 0.5) / 0.5]
      return (a[channel] + (b[channel] - a[channel]) * part) * alpha
    }

    it('gives the same pixels each time, so the dither does not move', () => {
      expect(pixels.length).toBe(size.width * size.height * 4)
      expect(basePixels(size, stops, alpha, BASE_ANGLE, 6)).toEqual(pixels)
    })

    it('gives the same pixels when it paints a few rows at a time', () => {
      const painter = basePainter(size, stops, alpha, BASE_ANGLE, 6)
      for (let row = 0; row < size.height; row += 23) painter.rows(row, row + 23)
      expect(painter.pixels).toEqual(pixels)
    })

    it('mixes the steps of the gradient, so it shows no bands', () => {
      // Along this row, a plain gradient goes one way between two stops. The dither mixes the
      // two values at each step edge.
      const row = size.height / 2
      const reds: number[] = []
      for (let x = 0; x < size.width; x++) reds.push(stored(pixels, (row * size.width + x) * 4, 0))
      expect(turns(reds)).toBeGreaterThan(40)
    })

    it('keeps each value less than 1.5 steps from the smooth value', () => {
      for (let y = 0; y < size.height; y += 5) {
        for (let x = 0; x < size.width; x += 3) {
          const i = (y * size.width + x) * 4
          for (const channel of [0, 1, 2]) {
            expect(Math.abs(stored(pixels, i, channel) - smooth(x, y, channel))).toBeLessThan(1.5)
          }
          expect(Math.abs(pixels[i + 3] - 255 * alpha)).toBeLessThan(1.5)
        }
      }
    })

    it('keeps the mean of each area at the smooth value', () => {
      for (const [ax, ay] of [
        [0, 0],
        [190, 90],
        [370, 170],
      ]) {
        const sums = [0, 0, 0]
        const targets = [0, 0, 0]
        for (let y = ay; y < ay + 30; y++) {
          for (let x = ax; x < ax + 30; x++) {
            const i = (y * size.width + x) * 4
            for (const channel of [0, 1, 2]) {
              sums[channel] += stored(pixels, i, channel)
              targets[channel] += smooth(x, y, channel)
            }
          }
        }
        for (const channel of [0, 1, 2]) {
          expect(Math.abs(sums[channel] - targets[channel]) / 900).toBeLessThan(0.1)
        }
      }
    })
  })
})
