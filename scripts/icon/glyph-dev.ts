// The outlines of the letters d, e and v of the font Geist Mono, for the "dev" badge.
// Font: Geist Mono, weight 600 (SemiBold), from @fontsource/geist-mono 5.3.0.
// Copyright The Geist Project Authors. Licence: SIL Open Font License 1.1.
// A script took the outlines one time from geist-mono-latin-600-normal.woff. The icon script needs
// no font file and no font library. Each point is [x, y, on], in font units with the y axis up.
// "on" is 1 for a point on the curve and 0 for a quadratic control point. The font is
// monospaced, so each letter has the same advance.

import type { GlyphPoint } from './glyph-b.ts'

export interface DevLetter {
  // The box of the outline: xMin, yMin, xMax, yMax.
  bbox: [number, number, number, number]
  contours: GlyphPoint[][]
}

export const GEIST_MONO_UNITS_PER_EM = 1000
export const GEIST_MONO_ADVANCE = 600
export const GEIST_MONO_ASCENDER = 710 // The height of d: the top of the word.
export const GEIST_MONO_DESCENDER = -12 // The overshoot below the baseline of d and e.

export const GEIST_MONO_DEV: DevLetter[] = [
  {
    bbox: [32, -12, 526, 710],
    contours: [
      [
        [250, -12, 1],
        [183, -12, 0],
        [85, 55, 0],
        [32, 180, 0],
        [32, 354, 0],
        [85, 479, 0],
        [183, 546, 0],
        [250, 546, 1],
        [294, 546, 0],
        [364, 514, 0],
        [387, 488, 1],
        [400, 473, 0],
        [408, 457, 1],
        [408, 710, 1],
        [526, 710, 1],
        [526, 0, 1],
        [414, 0, 1],
        [410, 83, 1],
        [401, 65, 0],
        [388, 50, 1],
        [364, 21, 0],
        [295, -12, 0],
      ],
      [
        [278, 94, 1],
        [317, 94, 0],
        [376, 136, 0],
        [408, 213, 0],
        [408, 267, 1],
        [408, 322, 0],
        [376, 399, 0],
        [317, 440, 0],
        [276, 440, 1],
        [219, 440, 0],
        [155, 349, 0],
        [155, 185, 0],
        [219, 94, 0],
      ],
    ],
  },
  {
    bbox: [53, -12, 547, 546],
    contours: [
      [
        [304, -12, 1],
        [229, -12, 0],
        [116, 56, 0],
        [53, 182, 0],
        [53, 267, 1],
        [53, 351, 0],
        [115, 476, 0],
        [227, 546, 0],
        [301, 546, 1],
        [373, 546, 0],
        [484, 478, 0],
        [547, 352, 0],
        [547, 265, 1],
        [547, 234, 1],
        [175, 234, 1],
        [180, 166, 0],
        [249, 94, 0],
        [306, 94, 1],
        [348, 94, 0],
        [405, 135, 0],
        [416, 168, 1],
        [537, 159, 1],
        [512, 79, 0],
        [392, -12, 0],
      ],
      [
        [177, 320, 1],
        [419, 320, 1],
        [414, 381, 0],
        [350, 440, 0],
        [300, 440, 1],
        [250, 440, 0],
        [185, 379, 0],
      ],
    ],
  },
  {
    bbox: [40, 0, 560, 534],
    contours: [
      [
        [227, 0, 1],
        [40, 534, 1],
        [167, 534, 1],
        [300, 128, 1],
        [433, 534, 1],
        [560, 534, 1],
        [373, 0, 1],
      ],
    ],
  },
]
