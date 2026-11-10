// The paint and the motion clock of the animated background (spec 8.10). This module is pure.

// User decision, 2026-11-10: the motion moves 30 times each second, not at the refresh rate of
// the display. The compositor then makes a new frame of the background only at each step.
export const MOTION_RATE = 30

// The time between two steps of the motion, in milliseconds.
export const MOTION_STEP_MS = 1000 / MOTION_RATE

// The time of the motion clock in milliseconds: the time at the start of a run plus the time
// since the start. A run starts when the motion goes on, and it ends when the motion stops. The
// clock never goes back.
export function motionTime(from: number, startedAt: number, now: number): number {
  return from + Math.max(0, now - startedAt)
}

// User decision, 2026-11-10: each layer is a canvas that CSS scales up to its box. A canvas has
// this part of the device pixels of its box in each direction. The stretch is small, so the grain
// of the dither stays fine.
export const CANVAS_SCALE = 1 / 2

// The largest side of a canvas, in pixels. A GPU texture has a limit on its size.
export const MAX_CANVAS_SIDE = 8192

export interface PixelSize {
  width: number
  height: number
}

// The size of the canvas of a box with this size in device pixels: the part of each side, up to
// the next whole pixel. Each side is from 1 pixel to MAX_CANVAS_SIDE. A side that is not a
// finite number gives 1 pixel.
export function canvasSize(device: PixelSize, scale: number = CANVAS_SCALE): PixelSize {
  const side = (pixels: number): number => {
    const value = Math.ceil(pixels * scale)
    if (!Number.isFinite(value)) return 1
    return Math.min(MAX_CANVAS_SIDE, Math.max(1, value))
  }
  return { height: side(device.height), width: side(device.width) }
}

// The fade of a colour field from its centre (0) to its edge (1): the place, and the part of the
// glow. The fade is on an eased curve. It is almost zero before the edge, so the edge of the
// ellipse shows no line and no fringe of colour.
export const FIELD_FADE: readonly (readonly [number, number])[] = [
  [0, 1],
  [0.2, 0.7],
  [0.4, 0.38],
  [0.6, 0.14],
  [0.8, 0.03],
  [1, 0],
]

// The base layer is a linear gradient at this angle, as in CSS: 0 degrees points up and 90
// degrees points to the right.
export const BASE_ANGLE = 120

// The icon tokens of the stops of the base gradient, each at the base strength. The base goes from
// green through blue and violet to red. Yellow and orange come only from the fields, because a
// dark yellow or orange looks brown.
export const BASE_COLOURS = ['icon-4', 'icon-5', 'icon-6', 'icon-1', 'icon-6'] as const

// The two ends of the gradient line of a CSS linear gradient at this angle, in a box of w by h,
// as x0, y0, x1 and y1 from the top-left corner. The line goes through the centre. It is long
// enough that the corners get the first and the last stop, as in CSS.
export function gradientLine(
  angle: number,
  w: number,
  h: number,
): [number, number, number, number] {
  const turn = (angle * Math.PI) / 180
  const dx = Math.sin(turn)
  const dy = -Math.cos(turn)
  const half = (Math.abs(w * dx) + Math.abs(h * dy)) / 2
  return [w / 2 - dx * half, h / 2 - dy * half, w / 2 + dx * half, h / 2 + dy * half]
}

// The red, green and blue of a hex colour token with 3 or 6 digits, or null.
export function hexColour(text: string): [number, number, number] | null {
  const match = text.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i)
  if (!match) return null
  const digits = match[1].length === 3 ? [...match[1]].map(d => d + d).join('') : match[1]
  const value = Number.parseInt(digits, 16)
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
}

// A strength token as a part of 1: "15%" gives 0.15 and "0.85" gives 0.85. Text that is not a
// number gives 0.
export function partOf(text: string): number {
  const value = Number.parseFloat(text)
  if (!Number.isFinite(value)) return 0
  return text.trim().endsWith('%') ? value / 100 : value
}

// A colour with an alpha, as CSS text for a stop of a canvas gradient. The colour() form keeps
// the full precision of the alpha.
export function stopColour([r, g, b]: readonly number[], alpha: number): string {
  return `color(srgb ${r / 255} ${g / 255} ${b / 255} / ${alpha})`
}

// User decision, 2026-11-10: the paint adds a fine dither to each canvas. A field is a faint
// colour: its alpha goes from 0 to about 38 of 255. A plain gradient of the field has only that
// many 8-bit steps, and each step shows as a soft ring. The dither adds a fixed triangular noise of
// up to one step before the rounding to 8 bits. The rings then change into a fine grain.

// The side of the square tile of noise, in pixels: a power of 2. The tile repeats over the canvas.
export const DITHER_TILE = 256

// A tile of triangular noise from -1 to 1, with a fixed seed. The same seed gives the same
// tile, so the dither does not move when the paint occurs again.
export function ditherNoise(seed: number): Float32Array {
  let state = seed >>> 0
  // A small generator of random numbers (mulberry32): a number from 0 to 1.
  const next = (): number => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  const noise = new Float32Array(DITHER_TILE * DITHER_TILE)
  // The difference of two flat random numbers has a triangular distribution.
  for (let i = 0; i < noise.length; i++) noise[i] = next() - next()
  return noise
}

// The colour value without the alpha (0 to 255) that the canvas stores as this premultiplied
// value at this alpha. The canvas gets pixels without the alpha and multiplies each colour value
// by the alpha, with rounding. Some paths divide by 256, not 255. For an alpha up to 128, the
// value gives the same result on both paths.
export function unpremultiplied(premultiplied: number, alpha: number): number {
  if (alpha <= 0) return 0
  const near = Math.round((premultiplied * 255) / alpha)
  for (const step of [0, -1, 1, -2, 2]) {
    const colour = near + step
    if (colour < 0 || colour > 255) continue
    const product = colour * alpha
    if (Math.round(product / 255) === premultiplied && (product + 255) >> 8 === premultiplied) {
      return colour
    }
  }
  return Math.min(255, Math.max(0, near))
}

// The colour values of unpremultiplied for each alpha and each premultiplied value, as
// alpha * 256 + premultiplied. The paint makes the table one time.
let unpremultipliedTable: Uint8Array | null = null

function unpremultipliedValues(): Uint8Array {
  if (unpremultipliedTable) return unpremultipliedTable
  const table = new Uint8Array(256 * 256)
  for (let alpha = 1; alpha < 256; alpha++) {
    for (let value = 0; value <= alpha; value++) {
      table[(alpha << 8) | value] = unpremultiplied(value, alpha)
    }
  }
  unpremultipliedTable = table
  return table
}

// True when the host stores the low byte of a number first. Each Mac does that.
const LOW_BYTE_FIRST = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1

// The shifts of red, green, blue and alpha in a pixel as one 32-bit number. ImageData stores the
// bytes of a pixel in the order red, green, blue, alpha.
const [RED, GREEN, BLUE, ALPHA] = LOW_BYTE_FIRST ? [0, 8, 16, 24] : [24, 16, 8, 0]

// One dithered pixel as a 32-bit number. The alpha and the colour values are premultiplied
// values from 0 to 255, before the rounding. The same noise goes to each value, so the grain has
// no colour of its own. A colour value is never more than the alpha, so after the noise and the
// rounding it is also never more than the alpha, and the pixel stays valid.
function dithered(
  table: Uint8Array,
  noise: number,
  alpha: number,
  red: number,
  green: number,
  blue: number,
): number {
  // The | 0 cuts a number to an integer. A number from -0.5 to 0 gives 0.
  let a = (alpha + noise + 0.5) | 0
  if (a <= 0) return 0
  let n = noise
  if (a > 255) {
    // Near a full alpha, a smaller noise keeps each value at 255 or less.
    a = 255
    n = Math.min(noise, 255 - alpha)
  }
  const row = a << 8
  return (
    ((table[row | ((red + n + 0.5) | 0)] << RED) |
      (table[row | ((green + n + 0.5) | 0)] << GREEN) |
      (table[row | ((blue + n + 0.5) | 0)] << BLUE) |
      (a << ALPHA)) >>>
    0
  )
}

// The tile of noise is a square with a side that is a power of 2. So x & TILE_MASK is the
// place of x in the tile.
const TILE_MASK = DITHER_TILE - 1

// The steps of the tables of the smooth values: the fade of a field and the colours of the base.
// The step is small, so the error is much less than one 8-bit step.
const SMOOTH_STEPS = 4096

// The fade of a field (0 to 1) at a distance from its centre. The distance is 0 at the centre
// and 1 at the edge of the ellipse. The fade is linear between the steps of FIELD_FADE, as the
// canvas gradient.
export function fieldFade(distance: number): number {
  const last = FIELD_FADE[FIELD_FADE.length - 1]
  if (distance >= last[0]) return last[1]
  if (distance <= FIELD_FADE[0][0]) return FIELD_FADE[0][1]
  for (let i = 1; i < FIELD_FADE.length; i++) {
    const [at, part] = FIELD_FADE[i]
    if (distance <= at) {
      const [from, start] = FIELD_FADE[i - 1]
      return start + ((part - start) * (distance - from)) / (at - from)
    }
  }
  return last[1]
}

// A paint of the pixels of one canvas, a few rows at a time. The pixels are RGBA without the
// alpha in the colour, as ImageData. The view paints all rows in a series of short tasks, so no
// task holds the page for a long time.
export interface Painter {
  readonly pixels: Uint8ClampedArray<ArrayBuffer>
  // Paint the rows from the first row up to the row before the last row.
  rows(first: number, last: number): void
}

// The paint of a colour field with the dither. The field is the ellipse that touches the four
// sides of the canvas, with the glow at the centre and the fade of FIELD_FADE. The seed selects
// the tile of noise.
export function fieldPainter(
  size: PixelSize,
  colour: readonly number[],
  glow: number,
  seed: number,
): Painter {
  const { height, width } = size
  const pixels = new Uint8ClampedArray(width * height * 4)
  const words = new Uint32Array(pixels.buffer)
  const noise = ditherNoise(seed)
  const table = unpremultipliedValues()
  // The alpha (0 to 255) at each step of the distance from the centre.
  const alphaAt = new Float32Array(SMOOTH_STEPS + 1)
  for (let i = 0; i <= SMOOTH_STEPS; i++) alphaAt[i] = 255 * glow * fieldFade(i / SMOOTH_STEPS)
  const [red, green, blue] = colour.map(value => value / 255)
  const cx = width / 2
  const cy = height / 2
  const rows = (first: number, last: number): void => {
    for (let y = Math.max(0, first); y < Math.min(height, last); y++) {
      const v = (y + 0.5 - cy) / cy
      const v2 = v * v
      if (v2 >= 1) continue
      const tileRow = (y & TILE_MASK) * DITHER_TILE
      const rowStart = y * width
      for (let x = 0; x < width; x++) {
        const u = (x + 0.5 - cx) / cx
        const d2 = u * u + v2
        // Out of the ellipse, the pixel stays empty.
        if (d2 >= 1) continue
        const alpha = alphaAt[(Math.sqrt(d2) * SMOOTH_STEPS + 0.5) | 0]
        const n = noise[tileRow | (x & TILE_MASK)]
        words[rowStart + x] = dithered(table, n, alpha, red * alpha, green * alpha, blue * alpha)
      }
    }
  }
  return { pixels, rows }
}

// The paint of the base with the dither. The base is a linear gradient at the angle, as in CSS.
// Each stop is a place on the gradient line (0 to 1) and a colour. Each colour has the alpha.
// Between two stops, the colour is linear, as in the canvas gradient. The seed selects the tile
// of noise.
export function basePainter(
  size: PixelSize,
  stops: readonly (readonly [number, readonly number[]])[],
  alpha: number,
  angle: number,
  seed: number,
): Painter {
  const { height, width } = size
  const pixels = new Uint8ClampedArray(width * height * 4)
  if (stops.length === 0) return { pixels, rows: () => {} }
  const words = new Uint32Array(pixels.buffer)
  const noise = ditherNoise(seed)
  const table = unpremultipliedValues()
  // The premultiplied red, green and blue at each step of the gradient line.
  const colourAt = new Float32Array((SMOOTH_STEPS + 1) * 3)
  for (let i = 0; i <= SMOOTH_STEPS; i++) {
    const t = i / SMOOTH_STEPS
    let to = stops.findIndex(([at]) => at >= t)
    if (to === -1) to = stops.length - 1
    const from = Math.max(0, to - 1)
    const [fromAt, fromColour] = stops[from]
    const [toAt, toColour] = stops[to]
    const part = toAt > fromAt ? Math.min(1, Math.max(0, (t - fromAt) / (toAt - fromAt))) : 1
    for (let c = 0; c < 3; c++) {
      colourAt[i * 3 + c] = (fromColour[c] + (toColour[c] - fromColour[c]) * part) * alpha
    }
  }
  const fullAlpha = 255 * alpha
  const [x0, y0, x1, y1] = gradientLine(angle, width, height)
  const dx = x1 - x0
  const dy = y1 - y0
  const length2 = dx * dx + dy * dy || 1
  const stepX = dx / length2
  const rows = (first: number, last: number): void => {
    for (let y = Math.max(0, first); y < Math.min(height, last); y++) {
      const tileRow = (y & TILE_MASK) * DITHER_TILE
      const rowStart = y * width
      // The place on the gradient line (0 to 1) of the first pixel of the row. It changes by the
      // same amount at each pixel of the row.
      let t = ((0.5 - x0) * dx + (y + 0.5 - y0) * dy) / length2
      for (let x = 0; x < width; x++, t += stepX) {
        const at = t <= 0 ? 0 : t >= 1 ? SMOOTH_STEPS * 3 : ((t * SMOOTH_STEPS + 0.5) | 0) * 3
        const n = noise[tileRow | (x & TILE_MASK)]
        words[rowStart + x] = dithered(
          table,
          n,
          fullAlpha,
          colourAt[at],
          colourAt[at + 1],
          colourAt[at + 2],
        )
      }
    }
  }
  return { pixels, rows }
}

// All pixels of a colour field with the dither, in one call.
export function fieldPixels(
  size: PixelSize,
  colour: readonly number[],
  glow: number,
  seed: number,
): Uint8ClampedArray<ArrayBuffer> {
  const painter = fieldPainter(size, colour, glow, seed)
  painter.rows(0, size.height)
  return painter.pixels
}

// All pixels of the base with the dither, in one call.
export function basePixels(
  size: PixelSize,
  stops: readonly (readonly [number, readonly number[]])[],
  alpha: number,
  angle: number,
  seed: number,
): Uint8ClampedArray<ArrayBuffer> {
  const painter = basePainter(size, stops, alpha, angle, seed)
  painter.rows(0, size.height)
  return painter.pixels
}
