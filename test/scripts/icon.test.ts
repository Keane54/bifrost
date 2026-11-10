import { readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { drawDevIcon } from '../../scripts/icon/dev-badge'
import { drawIcon, encodePng, type IconPalette, readPalette } from '../../scripts/icon/draw'

const CSS = readFileSync(join(__dirname, '../../src/renderer/src/styles/app.css'), 'utf8')

const SIZE = 256

function reader(pixels: Uint8Array, size: number) {
  return (x: number, y: number): number[] => {
    const i = (Math.round(y) * size + Math.round(x)) * 4
    return [...pixels.subarray(i, i + 4)]
  }
}

// A drawIcon call at 512 pixels takes up to 3 seconds on a fast Mac. A CI runner with fewer and
// slower cores can take more than the default limit of 5 seconds. So these tests get 30 seconds.
describe('the icon script', { timeout: 30_000 }, () => {
  it('readPalette reads the six stops and the edge from app.css', () => {
    const palette = readPalette(CSS)
    expect(palette.stops).toHaveLength(6)
    expect(palette.edge.alpha).toBeCloseTo(0.1)
  })

  it('readPalette throws for a missing token', () => {
    expect(() => readPalette('@theme { --color-bg: #0a0a0a; }')).toThrow(/--color-/)
  })

  it('encodePng gives the PNG signature and the IHDR size', () => {
    const png = encodePng(16, 16, new Uint8Array(16 * 16 * 4))
    expect([...png.subarray(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    expect(png.readUInt32BE(16)).toBe(16)
    expect(png.readUInt32BE(20)).toBe(16)
    expect(png.subarray(12, 16).toString('latin1')).toBe('IHDR')
  })

  it('drawIcon keeps the 100 pixel margin of the macOS grid (scaled to 256)', () => {
    const at = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)
    // Margin 25 pixels. A corner and a point at (50, 50) of 1024 are transparent.
    expect(at(0, 0)[3]).toBe(0)
    expect(at(SIZE - 1, 0)[3]).toBe(0)
    expect(at(12, 12)[3]).toBe(0)
    // The middle of each side is opaque just inside the margin and is clear just outside.
    expect(at(SIZE / 2, 27)[3]).toBe(255)
    expect(at(27, SIZE / 2)[3]).toBe(255)
    expect(at(SIZE / 2, 22)[3]).toBe(0)
    expect(at(22, SIZE / 2)[3]).toBe(0)
    // The shape corner is inside the margin: the corner point of the box is outside the curve.
    expect(at(27, 27)[3]).toBe(0)
  })

  it('drawIcon draws a soft black shadow below the shape and none above it', () => {
    const at = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)
    const below = at(SIZE / 2, SIZE - 25 + 3)
    expect(below[3]).toBeGreaterThan(10)
    expect(below[3]).toBeLessThan(255 * 0.31)
    expect(below.slice(0, 3)).toEqual([0, 0, 0])
    // The shadow is weaker above the shape than below it.
    expect(at(SIZE / 2, 25 - 3)[3]).toBeLessThan(below[3])
    // Far from the shape, the pixel is fully transparent.
    expect(at(SIZE / 2, 2)[3]).toBe(0)
  })

  it('drawIcon is red near the bottom-right corner', () => {
    // The point is to the right of the B, which fills most of the bottom-right quadrant.
    const [r, g, b, a] = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)(SIZE * 0.88, SIZE * 0.7)
    expect(a).toBe(255)
    expect(r).toBeGreaterThan(g + 60)
    expect(r).toBeGreaterThan(b + 60)
  })

  it('drawIcon is violet near the top-left corner', () => {
    const [r, g, b] = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)(SIZE * 0.16, SIZE * 0.16)
    // Violet has a strong blue part and a red part as large as its green part.
    expect(b).toBeGreaterThan(g + 40)
    expect(b).toBeGreaterThan(r + 40)
    expect(r).toBeGreaterThan(g - 20)
  })

  it('drawIcon is between red and violet at the centre', () => {
    const [r, g, b] = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)(SIZE / 2, SIZE / 2)
    // The centre is between yellow and green: green is high and blue is low.
    expect(g).toBeGreaterThan(r - 40)
    expect(g).toBeGreaterThan(b)
  })

  it('drawIcon blends the stops of a palette in a straight line from the corner to the corner', () => {
    const palette: IconPalette = {
      edge: { alpha: 0, rgb: [255, 255, 255] },
      mark: [255, 255, 255],
      stops: [
        [255, 0, 0],
        [0, 0, 255],
        [0, 0, 255],
        [0, 0, 255],
        [0, 0, 255],
        [0, 0, 255],
      ],
    }
    const at = reader(drawIcon(SIZE, palette), SIZE)
    // Points on the same anti-diagonal have the same colour.
    expect(at(SIZE * 0.4, SIZE * 0.6)).toEqual(at(SIZE * 0.6, SIZE * 0.4))
    expect(at(SIZE * 0.8, SIZE * 0.8)[0]).toBeGreaterThan(at(SIZE * 0.2, SIZE * 0.2)[0])
  })

  it('drawIcon draws a white B in the bottom-right quadrant', () => {
    const size = 512
    const pixels = drawIcon(size, readPalette(CSS))
    const at = reader(pixels, size)
    const white = (x: number, y: number): boolean => {
      const [r, g, b] = at(Math.round(x), Math.round(y))
      return r > 250 && g > 250 && b > 250
    }
    let minX = size
    let minY = size
    let maxX = 0
    let maxY = 0
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        if (!white(x, y)) continue
        minX = Math.min(minX, x)
        minY = Math.min(minY, y)
        maxX = Math.max(maxX, x)
        maxY = Math.max(maxY, y)
      }
    }
    // All white is in the bottom-right quadrant of the canvas.
    expect(minX).toBeGreaterThan(size / 2)
    expect(minY).toBeGreaterThan(size / 2)
    const w = maxX - minX
    const h = maxY - minY
    // The left stem of the B is white over its whole height.
    for (const f of [0.1, 0.5, 0.9]) expect(white(minX + w * 0.1, minY + h * f)).toBe(true)
    // The inside of the upper bowl is not white.
    expect(white(minX + w * 0.5, minY + h * 0.25)).toBe(false)
  })

  // User decision (2026-11-06): the B is 75% of the height of the quadrant, and it has the same space to
  // the right edge and to the bottom edge of the rounded square.
  it('drawIcon draws the B at 75% of the quadrant, with equal space right and below', () => {
    const size = 512
    const pixels = drawIcon(size, readPalette(CSS))
    const at = reader(pixels, size)
    const quadrant = (824 * size) / 1024 / 2
    const edge = ((100 + 824) * size) / 1024
    let minY = size
    let maxX = 0
    let maxY = 0
    for (let y = Math.floor(size / 2); y < size; y++) {
      for (let x = Math.floor(size / 2); x < size; x++) {
        const [r, g, b] = at(x, y)
        if (r > 250 && g > 250 && b > 250) {
          minY = Math.min(minY, y)
          maxX = Math.max(maxX, x)
          maxY = Math.max(maxY, y)
        }
      }
    }
    const height = maxY - minY + 1
    expect(height / quadrant).toBeGreaterThan(0.72)
    expect(height / quadrant).toBeLessThan(0.78)
    const right = edge - (maxX + 1)
    const bottom = edge - (maxY + 1)
    expect(Math.abs(right - bottom)).toBeLessThanOrEqual(2)
  })

  it('drawIcon draws no white in the top-left quadrant', () => {
    const size = 256
    const pixels = drawIcon(size, readPalette(CSS))
    for (let y = 0; y < size / 2; y++) {
      for (let x = 0; x < size / 2; x++) {
        const i = (y * size + x) * 4
        const white =
          pixels[i] > 250 && pixels[i + 1] > 250 && pixels[i + 2] > 250 && pixels[i + 3] > 250
        expect(white).toBe(false)
      }
    }
  })

  it('drawDevIcon differs from drawIcon only in the top-left badge', () => {
    const palette = readPalette(CSS)
    const plain = drawIcon(SIZE, palette)
    const dev = drawDevIcon(SIZE, palette)
    expect(dev.length).toBe(plain.length)
    let changed = 0
    for (let y = 0; y < SIZE; y++) {
      for (let x = 0; x < SIZE; x++) {
        const i = (y * SIZE + x) * 4
        if (plain.subarray(i, i + 4).some((v, k) => v !== dev[i + k])) {
          changed++
          // Each changed pixel is in the top-left part of the icon.
          expect(x).toBeLessThan(SIZE * 0.6)
          expect(y).toBeLessThan(SIZE * 0.4)
        }
      }
    }
    expect(changed).toBeGreaterThan(500)
    // The badge has dark pixels and white pixels of the text.
    const at = reader(dev, SIZE)
    expect(at(SIZE * 0.2, SIZE * 0.2).slice(0, 3)).toEqual([14, 14, 18])
    const lit = Array.from({ length: SIZE * SIZE }, (_, p) => p).some(
      p =>
        dev[p * 4] > 250 && dev[p * 4 + 1] > 250 && dev[p * 4 + 2] > 250 && p % SIZE < SIZE * 0.6,
    )
    expect(lit).toBe(true)
  })

  it('resources/icon-dev.png is a 512 pixel PNG that differs from icon.png', () => {
    const dev = readFileSync(join(__dirname, '../../resources/icon-dev.png'))
    const plain = readFileSync(join(__dirname, '../../resources/icon.png'))
    expect(dev.subarray(12, 16).toString('latin1')).toBe('IHDR')
    expect(dev.readUInt32BE(16)).toBe(512)
    expect(dev.readUInt32BE(20)).toBe(512)
    expect(dev.equals(plain)).toBe(false)
    expect(statSync(join(__dirname, '../../resources/icon-dev.png')).size).toBeGreaterThan(1000)
  })

  it('the glyph module names the font, the weight, the version and the licence', () => {
    const source = readFileSync(join(__dirname, '../../scripts/icon/glyph-b.ts'), 'utf8')
    expect(source).toMatch(/Geist Mono/)
    expect(source).toMatch(/weight 600/)
    expect(source).toMatch(/5\.3\.0/)
    expect(source).toMatch(/SIL Open Font License 1\.1/)
    expect(source).toMatch(/Geist Project Authors/)
  })

  it('the dev glyph module names the font, the weight, the version and the licence', () => {
    const source = readFileSync(join(__dirname, '../../scripts/icon/glyph-dev.ts'), 'utf8')
    expect(source).toMatch(/Geist Mono/)
    expect(source).toMatch(/weight 600/)
    expect(source).toMatch(/5\.3\.0/)
    expect(source).toMatch(/SIL Open Font License 1\.1/)
  })
})
