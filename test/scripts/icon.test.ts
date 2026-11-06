import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { drawIcon, encodePng, type IconPalette, readPalette } from '../../scripts/icon/draw'

const CSS = readFileSync(join(__dirname, '../../src/renderer/src/styles/app.css'), 'utf8')

const SIZE = 256

function reader(pixels: Uint8Array, size: number) {
  return (x: number, y: number): number[] => {
    const i = (Math.round(y) * size + Math.round(x)) * 4
    return [...pixels.subarray(i, i + 4)]
  }
}

describe('the icon script', () => {
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

  it('drawIcon makes the pixels outside the rounded square fully transparent', () => {
    const pixels = drawIcon(SIZE, readPalette(CSS))
    expect(pixels).toHaveLength(SIZE * SIZE * 4)
    const at = reader(pixels, SIZE)
    for (const [x, y] of [
      [0, 0],
      [SIZE - 1, 0],
      [0, SIZE - 1],
      [SIZE - 1, SIZE - 1],
    ]) {
      expect(at(x, y)[3]).toBe(0)
    }
    // The middle of each side is inside and opaque.
    expect(at(SIZE / 2, 1)[3]).toBe(255)
    expect(at(1, SIZE / 2)[3]).toBe(255)
  })

  it('drawIcon is red near the bottom-right corner', () => {
    const [r, g, b, a] = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)(SIZE * 0.82, SIZE * 0.82)
    expect(a).toBe(255)
    expect(r).toBeGreaterThan(g + 60)
    expect(r).toBeGreaterThan(b + 60)
  })

  it('drawIcon is violet near the top-left corner', () => {
    const [r, g, b] = reader(drawIcon(SIZE, readPalette(CSS)), SIZE)(SIZE * 0.08, SIZE * 0.08)
    // Violet has a strong blue part and a red part as large as its green part.
    expect(b).toBeGreaterThan(g + 60)
    expect(b).toBeGreaterThan(r + 60)
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
})
