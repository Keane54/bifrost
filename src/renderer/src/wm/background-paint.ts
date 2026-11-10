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
// this part of the device pixels of its box in each direction. The stretch is small, so the fine
// dither of the gradient stays fine and the gradient shows no bands or lines.
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
