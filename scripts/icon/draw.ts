// This module draws the Bifrost app icon. It uses the colours of app.css and no library.
// The icon is a rainbow gradient inside the rounded square.
import { crc32, deflateSync } from 'node:zlib'

type Rgb = [number, number, number]

export interface IconPalette {
  // The gradient colours from the bottom-right corner to the top-left corner.
  stops: Rgb[]
  edge: Rgba
}

// A colour and its alpha from 0 to 1.
interface Rgba {
  rgb: Rgb
  alpha: number
}

// Read the value of a colour token. It accepts #rrggbb and rgb(r g b / a). Without an alpha, the
// colour is opaque.
function readColour(css: string, name: string): Rgba {
  const match = css.match(new RegExp(`--color-${name}:\\s*([^;]+);`))
  if (!match) throw new Error(`No colour token --color-${name}`)
  const value = match[1].trim()
  const hex = value.match(/^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/)
  if (hex) {
    return { alpha: 1, rgb: [hex[1], hex[2], hex[3]].map(h => Number.parseInt(h, 16)) as Rgb }
  }
  const fn = value.match(/^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)(?:\s*[/,]\s*([\d.]+))?/)
  if (fn) {
    const alpha = fn[4] === undefined ? 1 : Math.min(1, Math.max(0, Number(fn[4])))
    return { alpha, rgb: [Number(fn[1]), Number(fn[2]), Number(fn[3])] }
  }
  throw new Error(`The token --color-${name} has a form that this script cannot read: ${value}`)
}

// The colour of a translucent colour over an opaque background.
function blend(top: Rgba, under: Rgb): Rgb {
  return top.rgb.map((c, i) => Math.round(under[i] + (c - under[i]) * top.alpha)) as Rgb
}

// The icon has six gradient stops and a panel edge. The edge token is translucent white. The
// icon blends it over the gradient colour at each point.
export function readPalette(css: string): IconPalette {
  return {
    edge: readColour(css, 'panel-edge'),
    stops: [1, 2, 3, 4, 5, 6].map(i => blend(readColour(css, `icon-${i}`), [0, 0, 0])),
  }
}

type Lab = [number, number, number]

const toLinear = (c: number): number => {
  const v = c / 255
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
}

const fromLinear = (v: number): number => {
  const c = v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055
  return Math.round(Math.min(1, Math.max(0, c)) * 255)
}

// Convert sRGB to OKLab (Bjorn Ottosson).
function toOklab([r8, g8, b8]: Rgb): Lab {
  const r = toLinear(r8)
  const g = toLinear(g8)
  const b = toLinear(b8)
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ]
}

function fromOklab([L, a, b]: Lab): Rgb {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3
  return [
    fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ]
}

// The gradient colour at t from 0 (the first stop) to 1 (the last stop). It blends in OKLab. A
// Catmull-Rom spline passes through the stops. So the stops show no sharp ridge.
function gradient(t: number, stops: Rgb[]): Rgb {
  const labs = stops.map(toOklab)
  const pos = Math.min(1, Math.max(0, t)) * (labs.length - 1)
  const i = Math.min(labs.length - 2, Math.floor(pos))
  const f = pos - i
  const p0 = labs[Math.max(0, i - 1)]
  const p1 = labs[i]
  const p2 = labs[i + 1]
  const p3 = labs[Math.min(labs.length - 1, i + 2)]
  const lab = p1.map((v, k) => {
    const a = p0[k]
    const d = p3[k]
    const c = p2[k]
    return (
      0.5 *
      (2 * v + (c - a) * f + (2 * a - 5 * v + 4 * c - d) * f * f + (3 * v - a - 3 * c + d) * f ** 3)
    )
  })
  return fromOklab(lab as Lab)
}

// The distance from the point to the rounded square that fills the image. Negative is inside.
function roundedBoxDistance(x: number, y: number, size: number, radius: number): number {
  const half = size / 2
  const dx = Math.abs(x - half) - (half - radius)
  const dy = Math.abs(y - half) - (half - radius)
  return Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) - radius
}

// The colour at one point, or null when the point is outside the rounded square.
function sample(x: number, y: number, size: number, palette: IconPalette): Rgb | null {
  const distance = roundedBoxDistance(x, y, size, size * 0.22)
  if (distance > 0) return null
  // The gradient runs along the diagonal. It is 0 at the bottom-right and 1 at the top-left.
  const colour = gradient(1 - (x + y) / (2 * size), palette.stops)
  if (distance > -size / 128) return blend(palette.edge, colour)
  return colour
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
