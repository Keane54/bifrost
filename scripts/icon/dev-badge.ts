// This module draws the "dev" badge on the top-left corner of the Bifrost icon. The dev app uses
// the result as its Dock icon. The three letters are shapes of lines and rings. So the script
// needs no font and no library. All values are in pixels of an icon of 1024 pixels. They scale
// with the image size.
import { drawIcon, type IconPalette } from './draw.ts'
import type { Glyph } from './glyph-b.ts'
import { GEIST_MONO_B } from './glyph-b.ts'

const BADGE = { height: 190, left: 180, radius: 60, top: 180, width: 380 }
const STROKE = 18
const HALF = STROKE / 2
const LETTER = 84 // The width and the x-height of a letter.
const GAP = 20
const ASCENDER = 205
const X_TOP = 240
const BASE = X_TOP + LETTER
const BADGE_COLOUR = [14, 14, 18]
const TEXT_COLOUR = [255, 255, 255]

// The first letter starts here. The text is in the middle of the badge.
const TEXT_LEFT = BADGE.left + (BADGE.width - (3 * LETTER + 2 * GAP)) / 2

function inBadge(x: number, y: number): boolean {
  const cx = BADGE.left + BADGE.width / 2
  const cy = BADGE.top + BADGE.height / 2
  const dx = Math.abs(x - cx) - (BADGE.width / 2 - BADGE.radius)
  const dy = Math.abs(y - cy) - (BADGE.height / 2 - BADGE.radius)
  return (
    Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) <= BADGE.radius
  )
}

function segmentDistance(
  x: number,
  y: number,
  [x1, y1, x2, y2]: [number, number, number, number],
): number {
  const lx = x2 - x1
  const ly = y2 - y1
  const t = Math.min(1, Math.max(0, ((x - x1) * lx + (y - y1) * ly) / (lx * lx + ly * ly)))
  return Math.hypot(x - (x1 + t * lx), y - (y1 + t * ly))
}

// True when the point is on the bowl of the letter d or e that starts at x position left.
function onRing(x: number, y: number, left: number): boolean {
  const cx = left + LETTER / 2
  const cy = X_TOP + LETTER / 2
  return Math.abs(Math.hypot(x - cx, y - cy) - (LETTER / 2 - HALF)) <= HALF
}

function inD(x: number, y: number, left: number): boolean {
  const stem = left + LETTER - HALF
  return onRing(x, y, left) || (Math.abs(x - stem) <= HALF && y >= ASCENDER && y <= BASE)
}

function inE(x: number, y: number, left: number): boolean {
  const cx = left + LETTER / 2
  const cy = X_TOP + LETTER / 2
  if (Math.abs(y - cy) <= HALF && Math.abs(x - cx) <= LETTER / 2 - HALF) return true
  // The opening of the e is on the right, below the bar.
  const opening = x > cx && y > cy + HALF && y < cy + 28
  return onRing(x, y, left) && !opening
}

function inV(x: number, y: number, left: number): boolean {
  const mid = left + LETTER / 2
  return (
    segmentDistance(x, y, [left + HALF, X_TOP + HALF, mid, BASE - HALF]) <= HALF ||
    segmentDistance(x, y, [left + LETTER - HALF, X_TOP + HALF, mid, BASE - HALF]) <= HALF
  )
}

function inText(x: number, y: number): boolean {
  return (
    inD(x, y, TEXT_LEFT) ||
    inE(x, y, TEXT_LEFT + LETTER + GAP) ||
    inV(x, y, TEXT_LEFT + 2 * (LETTER + GAP))
  )
}

// The Bifrost icon with the dev badge. The badge covers the part of the icon in its box.
export function drawDevIcon(
  size: number,
  palette: IconPalette,
  glyph: Glyph = GEIST_MONO_B,
): Uint8Array {
  const out = drawIcon(size, palette, glyph)
  const unit = 1024 / size
  const n = 4
  const from = Math.floor((BADGE.left - 2) / unit)
  const to = Math.ceil((BADGE.left + BADGE.width + 2) / unit)
  const top = Math.floor((BADGE.top - 2) / unit)
  const bottom = Math.ceil((BADGE.top + BADGE.height + 2) / unit)
  for (let py = top; py < bottom; py++) {
    for (let px = from; px < to; px++) {
      let badge = 0
      let text = 0
      for (let sy = 0; sy < n; sy++) {
        for (let sx = 0; sx < n; sx++) {
          const x = (px + (sx + 0.5) / n) * unit
          const y = (py + (sy + 0.5) / n) * unit
          if (!inBadge(x, y)) continue
          badge++
          if (inText(x, y)) text++
        }
      }
      if (badge === 0) continue
      const cover = badge / (n * n)
      const white = text / badge
      const i = (py * size + px) * 4
      for (let k = 0; k < 3; k++) {
        const paint = BADGE_COLOUR[k] + (TEXT_COLOUR[k] - BADGE_COLOUR[k]) * white
        out[i + k] = Math.round(out[i + k] + (paint - out[i + k]) * cover)
      }
    }
  }
  return out
}
