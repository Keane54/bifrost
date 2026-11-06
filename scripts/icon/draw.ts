// This module draws the Bifrost app icon. It uses the colours of app.css and no library.
import { crc32, deflateSync } from 'node:zlib'

type Rgb = [number, number, number]

export interface IconPalette {
  bg: Rgb
  edge: Rgb
  bands: Rgb[]
}

// Read the value of a colour token. It accepts #rrggbb and rgb(r g b / a).
function readColour(css: string, name: string): Rgb {
  const match = css.match(new RegExp(`--color-${name}:\\s*([^;]+);`))
  if (!match) throw new Error(`No colour token --color-${name}`)
  const value = match[1].trim()
  const hex = value.match(/^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/)
  if (hex) return [hex[1], hex[2], hex[3]].map(h => Number.parseInt(h, 16)) as Rgb
  const fn = value.match(/^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/)
  if (fn) return [Number(fn[1]), Number(fn[2]), Number(fn[3])]
  throw new Error(`The token --color-${name} has a form that this script cannot read: ${value}`)
}

export function readPalette(css: string): IconPalette {
  return {
    bands: ['tab-1', 'tab-4', 'tab-2'].map(name => readColour(css, name)),
    bg: readColour(css, 'bg'),
    edge: readColour(css, 'panel-edge'),
  }
}

// The distance from the point to the rounded square that fills the image. Negative is inside.
function roundedBoxDistance(x: number, y: number, size: number, radius: number): number {
  const half = size / 2
  const dx = Math.abs(x - half) - (half - radius)
  const dy = Math.abs(y - half) - (half - radius)
  return Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) - radius
}

const RING_RADII = [0.38, 0.29, 0.2]
const RING_WIDTH = 0.07

// The colour at one point, or null when the point is outside the rounded square.
function sample(x: number, y: number, size: number, palette: IconPalette): Rgb | null {
  const distance = roundedBoxDistance(x, y, size, size * 0.22)
  if (distance > 0) return null
  if (distance > -size / 32) return palette.edge
  // The bridge is the upper half of three rings.
  const dy = y - size * 0.74
  if (dy <= 0) {
    const r = Math.hypot(x - size / 2, dy)
    for (let i = 0; i < RING_RADII.length; i++) {
      const outer = size * RING_RADII[i]
      if (r <= outer && r >= outer - size * RING_WIDTH) return palette.bands[i]
    }
  }
  return palette.bg
}

// RGBA bytes. The anti-alias uses 4 x 4 samples for each pixel. A pixel colour is the mean of
// the colours of the samples inside the rounded square. Its alpha is the share of those samples.
export function drawIcon(size: number, palette: IconPalette): Uint8Array {
  const out = new Uint8Array(size * size * 4)
  const n = 4
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let r = 0
      let g = 0
      let b = 0
      let hits = 0
      for (let sy = 0; sy < n; sy++) {
        for (let sx = 0; sx < n; sx++) {
          const c = sample(px + (sx + 0.5) / n, py + (sy + 0.5) / n, size, palette)
          if (!c) continue
          r += c[0]
          g += c[1]
          b += c[2]
          hits++
        }
      }
      if (hits === 0) continue
      const i = (py * size + px) * 4
      out[i] = Math.round(r / hits)
      out[i + 1] = Math.round(g / hits)
      out[i + 2] = Math.round(b / hits)
      out[i + 3] = Math.round((hits / (n * n)) * 255)
    }
  }
  return out
}

function chunk(type: string, data: Buffer): Buffer {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(data.length, 0)
  head.write(type, 4, 'latin1')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0)
  return Buffer.concat([head, data, crc])
}

export function encodePng(width: number, height: number, rgba: Uint8Array): Buffer {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // colour type: RGBA
  // Bytes 10 to 12 (compression, filter, interlace) stay 0.
  const stride = width * 4
  const rows = Buffer.alloc((stride + 1) * height)
  for (let y = 0; y < height; y++) {
    // The filter byte of each row is 0.
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(rows, y * (stride + 1) + 1)
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(rows)),
    chunk('IEND', Buffer.alloc(0)),
  ])
}
