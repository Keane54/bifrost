// The outline of the capital letter B of the font Geist Mono.
// Font: Geist Mono, weight 600 (SemiBold), from @fontsource/geist-mono 5.3.0.
// Copyright The Geist Project Authors. Licence: SIL Open Font License 1.1.
// A script took the outline one time from geist-mono-latin-600-normal.woff. The icon script needs
// no font file. Each point is [x, y, on], in font units with the y axis up. "on" is 1 for a point
// on the curve and 0 for a quadratic control point.

export type GlyphPoint = [x: number, y: number, on: number]

export interface Glyph {
  // The size of the em square in font units.
  unitsPerEm: number
  // The box of the outline: xMin, yMin, xMax, yMax.
  bbox: [number, number, number, number]
  contours: GlyphPoint[][]
}

export const GEIST_MONO_B: Glyph = {
  bbox: [76, 0, 560, 710],
  contours: [
    [
      [76, 0, 1],
      [76, 710, 1],
      [288, 710, 1],
      [406, 710, 0],
      [530, 611, 0],
      [530, 518, 1],
      [530, 475, 0],
      [491, 406, 0],
      [453, 386, 1],
      [427, 372, 0],
      [395, 366, 1],
      [439, 361, 0],
      [471, 345, 1],
      [515, 323, 0],
      [560, 246, 0],
      [560, 196, 1],
      [560, 101, 0],
      [430, 0, 0],
      [311, 0, 1],
    ],
    [
      [199, 112, 1],
      [311, 112, 1],
      [373, 113, 0],
      [432, 162, 0],
      [432, 206, 1],
      [432, 253, 0],
      [371, 305, 0],
      [311, 305, 1],
      [199, 305, 1],
    ],
    [
      [199, 415, 1],
      [288, 415, 1],
      [347, 415, 0],
      [402, 463, 0],
      [402, 551, 0],
      [347, 598, 0],
      [288, 598, 1],
      [199, 598, 1],
    ],
  ],
  unitsPerEm: 1000,
}
