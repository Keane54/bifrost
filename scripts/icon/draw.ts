// This module draws the Bifrost app icon. It uses the colours of app.css and no library.
// The icon is a rainbow gradient inside the rounded square.
import { crc32, deflateSync } from 'node:zlib'
import { GEIST_MONO_B, type Glyph } from './glyph-b.ts'

type Rgb = [number, number, number]

export interface IconPalette {
  // The gradient colours from the bottom-right corner to the top-left corner.
  stops: Rgb[]
  edge: Rgba
  // The colour of the letter B.
  mark: Rgb
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
    mark: readColour(css, 'icon-mark').rgb,
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

// The icon follows the macOS icon grid at 1024 pixels. The rounded square is 824 pixels wide and
// has a 100 pixel margin. Its corner radius is 22.5% of its width. The shadow is black with 30%
// alpha. It is 10 pixels down and 20 pixels of blur. All values scale with the image size.
const MARGIN = 100 / 1024
const SHAPE = 824 / 1024
const RADIUS = 0.225 * SHAPE
const SHADOW_ALPHA = 0.3
const SHADOW_DOWN = 10 / 1024
const SHADOW_BLUR = 20 / 1024

// The distance from the point to the rounded square. Negative is inside. The centre of the square
// is (cx, cy), its width is side, and its corner radius is radius.
function roundedBoxDistance(
  x: number,
  y: number,
  cx: number,
  cy: number,
  side: number,
  radius: number,
): number {
  const half = side / 2
  const dx = Math.abs(x - cx) - (half - radius)
  const dy = Math.abs(y - cy) - (half - radius)
  return Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) - radius
}

// The letter B is a set of closed polygons in pixel units. The curves are cut into short lines.
interface Mark {
  polygons: [number, number][][]
  // The box of the letter: left, top, right, bottom.
  box: [number, number, number, number]
}

const CURVE_STEPS = 8
const MARK_HEIGHT = 0.65 // The height of the letter as a share of the height of the quadrant.

// Place the letter in the centre of the bottom-right quadrant of the rounded square.
function buildMark(size: number, glyph: Glyph): Mark {
  const side = size * SHAPE
  const [xMin, yMin, xMax, yMax] = glyph.bbox
  const scale = (side / 2 / (yMax - yMin)) * MARK_HEIGHT
  const cx = size / 2 + side / 4
  const cy = size / 2 + side / 4
  const map = (x: number, y: number): [number, number] => [
    cx + (x - (xMin + xMax) / 2) * scale,
    cy - (y - (yMin + yMax) / 2) * scale,
  ]
  const polygons = glyph.contours.map(contour => {
    // Rotate the contour so that it starts on a point on the curve.
    const start = contour.findIndex(p => p[2] === 1)
    const pts = [...contour.slice(start), ...contour.slice(0, start)]
    const out: [number, number][] = []
    let current = pts[0]
    out.push(map(current[0], current[1]))
    let i = 1
    while (i <= pts.length) {
      const next = pts[i % pts.length]
      if (next[2] === 1) {
        out.push(map(next[0], next[1]))
        current = next
        i++
        continue
      }
      // A control point. The end is the next point, or the middle to the next control point.
      const after = pts[(i + 1) % pts.length]
      const end: [number, number, number] =
        after[2] === 1 ? after : [(next[0] + after[0]) / 2, (next[1] + after[1]) / 2, 1]
      for (let k = 1; k <= CURVE_STEPS; k++) {
        const t = k / CURVE_STEPS
        const u = 1 - t
        out.push(
          map(
            u * u * current[0] + 2 * u * t * next[0] + t * t * end[0],
            u * u * current[1] + 2 * u * t * next[1] + t * t * end[1],
          ),
        )
      }
      current = end
      i += after[2] === 1 ? 2 : 1
    }
    return out
  })
  const all = polygons.flat()
  return {
    box: [
      Math.min(...all.map(p => p[0])),
      Math.min(...all.map(p => p[1])),
      Math.max(...all.map(p => p[0])),
      Math.max(...all.map(p => p[1])),
    ],
    polygons,
  }
}

// True when the point is inside the letter. The test uses the non-zero winding rule.
function inMark(x: number, y: number, mark: Mark): boolean {
  const [left, top, right, bottom] = mark.box
  if (x < left || x > right || y < top || y > bottom) return false
  let winding = 0
  for (const poly of mark.polygons) {
    for (let i = 0; i < poly.length; i++) {
      const [x1, y1] = poly[i]
      const [x2, y2] = poly[(i + 1) % poly.length]
      if (y1 <= y === y2 <= y) continue
      const cross = (x2 - x1) * (y - y1) - (x - x1) * (y2 - y1)
      if (y2 > y1 ? cross > 0 : cross < 0) winding += y2 > y1 ? 1 : -1
    }
  }
  return winding !== 0
}

// The colour and alpha at one point. A point outside the shape has the shadow or is transparent.
function sample(x: number, y: number, size: number, palette: IconPalette, mark: Mark): Rgba {
  const side = size * SHAPE
  const c = size / 2
  const radius = size * RADIUS
  const distance = roundedBoxDistance(x, y, c, c, side, radius)
  if (distance > 0) {
    // The shadow fades from full to nothing across the blur width, centred on the moved edge.
    const moved = roundedBoxDistance(x, y - size * SHADOW_DOWN, c, c, side, radius)
    const blur = size * SHADOW_BLUR
    const k = Math.min(1, Math.max(0, 0.5 - moved / blur))
    return { alpha: SHADOW_ALPHA * k * k * (3 - 2 * k), rgb: [0, 0, 0] }
  }
  // The gradient runs along the diagonal of the shape. It is 0 at the bottom-right corner and 1
  // at the top-left corner.
  const origin = size * MARGIN
  const t = 1 - (x - origin + (y - origin)) / (2 * side)
  const colour = gradient(t, palette.stops)
  if (distance > -size / 128) return { alpha: 1, rgb: blend(palette.edge, colour) }
  if (inMark(x, y, mark)) return { alpha: 1, rgb: palette.mark }
  return { alpha: 1, rgb: colour }
}

// RGBA bytes. The anti-alias uses 4 x 4 samples for each pixel. The samples are mixed with their
// alpha as weight. The alpha of the pixel is the mean alpha of the samples.
export function drawIcon(
  size: number,
  palette: IconPalette,
  glyph: Glyph = GEIST_MONO_B,
): Uint8Array {
  const mark = buildMark(size, glyph)
  const out = new Uint8Array(size * size * 4)
  const n = 4
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let r = 0
      let g = 0
      let b = 0
      let a = 0
      for (let sy = 0; sy < n; sy++) {
        for (let sx = 0; sx < n; sx++) {
          const c = sample(px + (sx + 0.5) / n, py + (sy + 0.5) / n, size, palette, mark)
          r += c.rgb[0] * c.alpha
          g += c.rgb[1] * c.alpha
          b += c.rgb[2] * c.alpha
          a += c.alpha
        }
      }
      if (a === 0) continue
      const i = (py * size + px) * 4
      out[i] = Math.round(r / a)
      out[i + 1] = Math.round(g / a)
      out[i + 2] = Math.round(b / a)
      out[i + 3] = Math.round((a / (n * n)) * 255)
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
