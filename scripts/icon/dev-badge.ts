// This module draws the "dev" badge on the top-left corner of the Bifrost icon. The dev app uses
// the result as its Dock icon. The word is set in the font Geist Mono with the outlines of
// glyph-dev.ts and the advance width of the font. All values are in pixels of an icon of 1024
// pixels. They scale with the image size.
import { drawIcon, flattenContour, type IconPalette, inPolygons } from './draw.ts'
import { GEIST_MONO_B, type Glyph } from './glyph-b.ts'
import {
  GEIST_MONO_ADVANCE,
  GEIST_MONO_ASCENDER,
  GEIST_MONO_DESCENDER,
  GEIST_MONO_DEV,
} from './glyph-dev.ts'

const BADGE_LEFT = 180
const BADGE_TOP = 180
const BADGE_RADIUS = 50.4
// The space between the ink of the word and each edge of the badge.
const PADDING = 39.6
// Pixels for each font unit. The word is 3 advances wide.
const SCALE = 0.153
const BADGE_COLOUR = [14, 14, 18]
const TEXT_COLOUR = [255, 255, 255]

// The ink of the word in font units: from the left of the d to the right of the v, and from the
// bottom of the e to the top of the d.
const INK_LEFT = GEIST_MONO_DEV[0].bbox[0]
const INK_RIGHT = 2 * GEIST_MONO_ADVANCE + GEIST_MONO_DEV[2].bbox[2]
const INK_WIDTH = (INK_RIGHT - INK_LEFT) * SCALE
const INK_HEIGHT = (GEIST_MONO_ASCENDER - GEIST_MONO_DESCENDER) * SCALE
const BADGE_WIDTH = INK_WIDTH + 2 * PADDING
const BADGE_HEIGHT = INK_HEIGHT + 2 * PADDING

// The word as polygons in pixel units. The ink is in the middle of the badge.
const WORD = GEIST_MONO_DEV.flatMap((letter, index) =>
  letter.contours.map(contour =>
    flattenContour(contour, (x, y) => [
      BADGE_LEFT + PADDING + (x + index * GEIST_MONO_ADVANCE - INK_LEFT) * SCALE,
      BADGE_TOP + PADDING + (GEIST_MONO_ASCENDER - y) * SCALE,
    ]),
  ),
)

function inBadge(x: number, y: number): boolean {
  const cx = BADGE_LEFT + BADGE_WIDTH / 2
  const cy = BADGE_TOP + BADGE_HEIGHT / 2
  const dx = Math.abs(x - cx) - (BADGE_WIDTH / 2 - BADGE_RADIUS)
  const dy = Math.abs(y - cy) - (BADGE_HEIGHT / 2 - BADGE_RADIUS)
  return (
    Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) <= BADGE_RADIUS
  )
}

// The Bifrost icon with the dev badge. The badge covers the part of the icon in its box. The
// anti-alias uses 4 x 4 samples for each pixel, as drawIcon does.
export function drawDevIcon(
  size: number,
  palette: IconPalette,
  glyph: Glyph = GEIST_MONO_B,
): Uint8Array {
  const out = drawIcon(size, palette, glyph)
  const unit = 1024 / size
  const n = 4
  const from = Math.floor((BADGE_LEFT - 2) / unit)
  const to = Math.ceil((BADGE_LEFT + BADGE_WIDTH + 2) / unit)
  const top = Math.floor((BADGE_TOP - 2) / unit)
  const bottom = Math.ceil((BADGE_TOP + BADGE_HEIGHT + 2) / unit)
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
          if (inPolygons(x, y, WORD)) text++
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
