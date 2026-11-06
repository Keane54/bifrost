import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { drawIcon, encodePng, type IconPalette, readPalette } from '../../scripts/icon/draw'

const CSS = readFileSync(join(__dirname, '../../src/renderer/src/styles/app.css'), 'utf8')

const PALETTE: IconPalette = {
  bands: [
    [124, 196, 214],
    [95, 179, 161],
    [143, 184, 232],
  ],
  bg: [10, 10, 10],
  edge: [255, 255, 255],
}

describe('the icon script', () => {
  it('readPalette reads the tokens of app.css', () => {
    const palette = readPalette(CSS)
    expect(palette.bg).toEqual([10, 10, 10])
    expect(palette.edge).toEqual([255, 255, 255])
    expect(palette.bands).toHaveLength(3)
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

  it('drawIcon gives transparent corners and the background colour inside', () => {
    const size = 64
    const pixels = drawIcon(size, PALETTE)
    expect(pixels).toHaveLength(size * size * 4)
    expect(pixels[3]).toBe(0)
    const at = (x: number, y: number): number[] => {
      const i = (y * size + x) * 4
      return [...pixels.subarray(i, i + 4)]
    }
    expect(at(32, 8)).toEqual([10, 10, 10, 255])
  })

  it('drawIcon draws the three bands in the palette colours', () => {
    const size = 256
    const pixels = drawIcon(size, PALETTE)
    const cx = size / 2
    const cy = size * 0.74
    // The middle of each ring is above the centre. Radii 38%, 29% and 20%, width 7%.
    PALETTE.bands.forEach((band, i) => {
      const r = size * ([0.38, 0.29, 0.2][i] - 0.035)
      const idx = (Math.round(cy - r) * size + Math.round(cx)) * 4
      expect([...pixels.subarray(idx, idx + 4)]).toEqual([...band, 255])
    })
  })
})
