import { describe, expect, it } from 'vitest'
import {
  centreRect,
  clampRect,
  contains,
  type Edge,
  MIN_SIZE,
  moveRect,
  type Rect,
  resizeRect,
  SNAP_DISTANCE,
  shownRect,
  snapMarks,
  titleBar,
} from '../../../src/renderer/src/wm/geometry'

const bounds = { h: 800, w: 1200 }

describe('moveRect', () => {
  it('moves by dx and dy far from all edges', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    expect(moveRect(start, 10, 5, [], bounds)).toEqual({ h: 200, w: 300, x: 110, y: 105 })
  })

  it('snaps the left edge to the bounds at 8 pixels', () => {
    const start = { h: 200, w: 300, x: 20, y: 100 }
    expect(moveRect(start, -12, 0, [], bounds).x).toBe(0)
  })

  it('does not snap at 9 pixels', () => {
    const start = { h: 200, w: 300, x: 21, y: 100 }
    expect(moveRect(start, -12, 0, [], bounds).x).toBe(9)
  })

  it('snaps the right edge to the bounds', () => {
    const start = { h: 200, w: 300, x: 895, y: 100 }
    expect(moveRect(start, 0, 0, [], bounds).x).toBe(900)
  })

  it('snaps to the right edge of another rect with a y overlap', () => {
    const other = { h: 300, w: 400, x: 0, y: 100 }
    const start = { h: 200, w: 300, x: 405, y: 150 }
    expect(moveRect(start, 0, 0, [other], bounds).x).toBe(400)
  })

  it('does not snap to another rect without a y overlap', () => {
    const other = { h: 100, w: 400, x: 0, y: 600 }
    const start = { h: 200, w: 300, x: 405, y: 100 }
    expect(moveRect(start, 0, 0, [other], bounds).x).toBe(405)
  })

  it('aligns left edges', () => {
    const other = { h: 200, w: 200, x: 300, y: 400 }
    const start = { h: 250, w: 300, x: 306, y: 150 }
    expect(moveRect(start, 0, 0, [other], bounds).x).toBe(300)
  })

  it('prefers the bounds line on a tie', () => {
    // The left edge is 4 from the bounds line at 0 and 4 from the other right edge at 8.
    const other = { h: 200, w: 8, x: 0, y: 100 }
    const start = { h: 200, w: 300, x: 4, y: 150 }
    expect(moveRect(start, 0, 0, [other], bounds).x).toBe(0)
  })

  it('prefers the left edge on an equal distance', () => {
    const start = { h: 200, w: 1192, x: 4, y: 100 }
    expect(moveRect(start, 0, 0, [], bounds).x).toBe(0)
  })

  it('snaps the top edge to the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 20 }
    expect(moveRect(start, 0, -12, [], bounds).y).toBe(0)
  })

  it('gives the raw position with a snap of 0', () => {
    const start = { h: 200, w: 300, x: 20, y: 100 }
    expect(moveRect(start, -12, 0, [], bounds, 0).x).toBe(8)
  })

  it('clamps the rect inside the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = moveRect(start, 5000, 5000, [], bounds)
    expect(result.x).toBe(bounds.w - 300)
    expect(result.y).toBe(bounds.h - 200)
  })
})

describe('resizeRect', () => {
  it('se snaps the right and bottom edges', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'se', 797, 497, [], bounds)
    expect(result).toEqual({ h: 700, w: 1100, x: 100, y: 100 })
  })

  it('gives the raw edges with a snap of 0', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'se', 797, 497, [], bounds, 0)
    expect(result).toEqual({ h: 697, w: 1097, x: 100, y: 100 })
  })

  it('keeps the minimum size', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'se', -1000, -1000, [], bounds)
    expect(result).toEqual({ h: 120, w: 200, x: 100, y: 100 })
  })

  it('nw keeps the right and bottom edges fixed at the minimum', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'nw', 500, 500, [], bounds)
    expect(result).toEqual({ h: 120, w: 200, x: 200, y: 180 })
  })

  it('stops an edge at the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'e', 5000, 0, [], bounds)
    expect(result.x + result.w).toBe(bounds.w)
    expect(result.y).toBe(100)
    expect(result.h).toBe(200)
  })

  it('stops the left edge at the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'w', -5000, 0, [], bounds)
    expect(result).toEqual({ h: 200, w: 400, x: 0, y: 100 })
  })

  it('snaps a moving edge to another rect', () => {
    const other = { h: 200, w: 200, x: 600, y: 100 }
    const start = { h: 200, w: 300, x: 100, y: 100 }
    expect(resizeRect(start, 'e', 195, 0, [other], bounds).w).toBe(500)
  })

  it('keeps the minimum size when a snap line is inside it', () => {
    // The raw right edge is 300, 5 from the other left edge at 295. The minimum stops it at 300.
    const other = { h: 200, w: 200, x: 295, y: 100 }
    const start = { h: 200, w: 300, x: 100, y: 100 }
    expect(resizeRect(start, 'e', -100, 0, [other], bounds).w).toBe(200)
  })
})

describe('fixes after review', () => {
  const start = { h: 200, w: 300, x: 100, y: 100 }

  it('keeps the fixed edges with a fractional delta', () => {
    const w = resizeRect(start, 'w', 0.5, 0, [], bounds)
    expect(w.x + w.w).toBe(400)
    const n = resizeRect(start, 'n', 0, 0.5, [], bounds)
    expect(n.y + n.h).toBe(300)
    const nw = resizeRect(start, 'nw', 0.5, 0.5, [], bounds)
    expect(nw.x + nw.w).toBe(400)
    expect(nw.y + nw.h).toBe(300)
  })

  it('moveRect clamps the rect after a snap to a line outside the bounds', () => {
    // The right edge snaps to the other left edge at 1207. The clamp then moves it to 1200.
    const other = { h: 200, w: 100, x: 1207, y: 100 }
    const wide = { h: 200, w: 300, x: 910, y: 100 }
    expect(moveRect(wide, 0, 0, [other], bounds).x).toBe(900)
  })

  it('counts a non-finite delta as 0', () => {
    expect(moveRect(start, Number.NaN, Number.POSITIVE_INFINITY, [], bounds)).toEqual(start)
    expect(resizeRect(start, 'se', Number.NaN, Number.NEGATIVE_INFINITY, [], bounds)).toEqual(start)
  })

  it('resizeRect snaps the y axis to another rect', () => {
    const other = { h: 100, w: 200, x: 100, y: 600 }
    expect(resizeRect(start, 's', 0, 297, [other], bounds).h).toBe(500)
  })

  it('resizeRect nw snaps both edges', () => {
    const other = { h: 100, w: 50, x: 40, y: 40 }
    const result = resizeRect(start, 'nw', -56, -56, [other], bounds)
    expect(result).toEqual({ h: 260, w: 360, x: 40, y: 40 })
  })

  it('resizeRect ne snaps both edges', () => {
    const other = { h: 100, w: 100, x: 500, y: 40 }
    const result = resizeRect(start, 'ne', 97, -57, [other], bounds)
    expect(result).toEqual({ h: 260, w: 400, x: 100, y: 40 })
  })

  it('snaps at an overlap of exactly snap pixels', () => {
    // The moved rect ends at y 300. The other starts at y 308, exactly 8 away.
    // The left edge goes to 403, 2 from the other left edge at 405.
    const other = { h: 100, w: 100, x: 405, y: 308 }
    const result = moveRect({ h: 200, w: 300, x: 100, y: 100 }, 303, 0, [other], bounds)
    expect(result.x).toBe(405)
    const far = moveRect({ h: 200, w: 300, x: 100, y: 100 }, 303, 0, [{ ...other, y: 309 }], bounds)
    expect(far.x).toBe(403)
  })

  it('rounds the rect after a snap to a fractional edge', () => {
    const other = { h: 200, w: 100.4, x: 0, y: 100 }
    const result = moveRect({ h: 200, w: 300, x: 105, y: 100 }, 0, 0, [other], bounds)
    expect(result.x).toBe(100)
  })
})

describe('snapMarks', () => {
  // The panel follows the pointer with no snap. The snapped rect gives the marks only.
  function move(start: Rect, dx: number, dy: number, others: Rect[] = []) {
    const raw = moveRect(start, dx, dy, others, bounds, 0)
    const snapped = moveRect(start, dx, dy, others, bounds, SNAP_DISTANCE)
    return { marks: snapMarks(raw, snapped, others, bounds), raw, snapped }
  }
  function resize(start: Rect, edge: Edge, dx: number, dy: number, others: Rect[] = []) {
    const raw = resizeRect(start, edge, dx, dy, others, bounds, 0)
    const snapped = resizeRect(start, edge, dx, dy, others, bounds, SNAP_DISTANCE)
    return { marks: snapMarks(raw, snapped, others, bounds), raw, snapped }
  }

  it('marks a snap to another panel at the line, at the middle of the y overlap', () => {
    // The right edge goes to 595, 5 from the other left edge at 600. The y overlap is 200 to 300.
    const other = { h: 200, w: 300, x: 600, y: 100 }
    const result = move({ h: 300, w: 300, x: 100, y: 200 }, 195, 0, [other])
    expect(result.raw.x).toBe(295)
    expect(result.snapped.x).toBe(300)
    expect(result.marks).toEqual([{ dir: 'right', x: 600, y: 250 }])
  })

  it('marks a snap to the window left edge at the middle of the panel edge', () => {
    const result = move({ h: 200, w: 300, x: 20, y: 100 }, -14, 0)
    expect(result.raw.x).toBe(6)
    expect(result.snapped.x).toBe(0)
    expect(result.marks).toEqual([{ dir: 'left', x: 0, y: 200 }])
  })

  it('gives two marks for a corner snap', () => {
    const result = move({ h: 200, w: 300, x: 20, y: 20 }, -15, -14)
    expect(result.marks).toEqual([
      { dir: 'left', x: 0, y: 100 },
      { dir: 'up', x: 150, y: 0 },
    ])
  })

  it('moves two marks at one corner apart, each along its own edge', () => {
    // The right edge snaps to 600 and the bottom edge snaps to 305, at the corner of the other.
    // Both marks start at x 600, y 305. Each moves 8 along its edge, to the middle of the edge.
    const other = { h: 100, w: 300, x: 600, y: 305 }
    const result = move({ h: 200, w: 300, x: 100, y: 100 }, 195, 0, [other])
    expect(result.snapped).toEqual({ h: 200, w: 300, x: 300, y: 105 })
    expect(result.marks).toEqual([
      { dir: 'right', x: 600, y: 297 },
      { dir: 'down', x: 592, y: 305 },
    ])
  })

  it('marks an x snap across a y gap at the middle of the gap', () => {
    // A resize of the right edge only. The bottom edge at 300 stays 4 from the other at 304.
    const other = { h: 100, w: 300, x: 600, y: 304 }
    const result = resize({ h: 200, w: 300, x: 100, y: 100 }, 'e', 195, 0, [other])
    expect(result.marks).toEqual([{ dir: 'right', x: 600, y: 302 }])
  })

  it('gives no mark when no edge is near a line', () => {
    expect(move({ h: 200, w: 300, x: 100, y: 100 }, 10, 5).marks).toEqual([])
  })

  it('gives no mark for an edge that is already on the line', () => {
    // The release does not change the rect. So no edge snaps.
    expect(move({ h: 200, w: 300, x: 0, y: 100 }, 0, 50).marks).toEqual([])
  })

  it('points the mark in the direction of the snap', () => {
    // The left edge goes to 395, 5 past the other right edge at 400. The snap moves it right.
    const other = { h: 300, w: 400, x: 0, y: 100 }
    const result = move({ h: 200, w: 300, x: 500, y: 150 }, -105, 0, [other])
    expect(result.marks).toEqual([{ dir: 'right', x: 400, y: 250 }])
  })

  it('marks a y snap to another panel at the middle of the x overlap', () => {
    // The bottom edge goes to 597, 3 from the other top edge at 600. The x overlap is 100 to 300.
    const other = { h: 100, w: 200, x: 100, y: 600 }
    const result = resize({ h: 200, w: 300, x: 100, y: 100 }, 's', 0, 297, [other])
    expect(result.raw.h).toBe(497)
    expect(result.snapped.h).toBe(500)
    expect(result.marks).toEqual([{ dir: 'down', x: 200, y: 600 }])
  })

  it('gives two marks for a corner resize to the window edges', () => {
    const result = resize({ h: 200, w: 300, x: 100, y: 100 }, 'se', 797, 497)
    expect(result.marks).toEqual([
      { dir: 'right', x: 1200, y: 450 },
      { dir: 'down', x: 650, y: 800 },
    ])
  })

  it('gives no mark when the minimum size stops the edge', () => {
    // The raw right edge is 300, 5 from the other left edge at 295. The minimum stops it at 300.
    const other = { h: 200, w: 200, x: 295, y: 100 }
    const result = resize({ h: 200, w: 300, x: 100, y: 100 }, 'e', -100, 0, [other])
    expect(result.snapped.w).toBe(200)
    expect(result.marks).toEqual([])
  })

  it('gives no mark when the clamp moves the rect off the line', () => {
    // The right edge snaps to the other left edge at 1207. The clamp then moves it to 1200.
    const other = { h: 200, w: 100, x: 1207, y: 100 }
    const result = move({ h: 200, w: 300, x: 910, y: 100 }, 0, 0, [other])
    expect(result.snapped.x).toBe(900)
    expect(result.marks).toEqual([])
  })

  it('rounds the edge of a fractional rect', () => {
    const other = { h: 200, w: 100.4, x: 0, y: 100 }
    const result = move({ h: 200, w: 300, x: 105, y: 100 }, 0, 0, [other])
    expect(result.marks).toEqual([{ dir: 'left', x: 100, y: 200 }])
  })
})

describe('clampRect', () => {
  it('grows a rect below min up to min', () => {
    expect(clampRect({ h: 10, w: 10, x: 50, y: 50 }, bounds)).toEqual({
      h: 120,
      w: 200,
      x: 50,
      y: 50,
    })
  })

  it('uses the bounds when they are below min', () => {
    expect(clampRect({ h: 100, w: 300, x: 50, y: 50 }, { h: 100, w: 150 })).toEqual({
      h: 100,
      w: 150,
      x: 0,
      y: 0,
    })
  })

  it('shrinks a rect larger than the bounds', () => {
    expect(clampRect({ h: 1500, w: 2000, x: 0, y: 0 }, bounds)).toEqual({
      h: 800,
      w: 1200,
      x: 0,
      y: 0,
    })
  })

  it('moves a rect from outside into the bounds', () => {
    expect(clampRect({ h: 200, w: 300, x: 1500, y: -50 }, bounds)).toEqual({
      h: 200,
      w: 300,
      x: 900,
      y: 0,
    })
  })
})

describe('shownRect', () => {
  it('keeps a rect that fits the area', () => {
    const r = { h: 300, w: 400, x: 700, y: 400 }
    expect(shownRect(r, bounds)).toEqual(r)
  })

  it('moves and shrinks a saved rect into a smaller area and keeps the minimum size', () => {
    const area = { h: 500, w: 800 }
    expect(shownRect({ h: 356, w: 420, x: 1052, y: 526 }, area)).toEqual({
      h: 356,
      w: 420,
      x: 380,
      y: 144,
    })
    expect(shownRect({ h: 900, w: 1440, x: 0, y: 0 }, area)).toEqual({ h: 500, w: 800, x: 0, y: 0 })
    expect(shownRect({ h: 10, w: 10, x: 5, y: 5 }, area)).toEqual({ ...MIN_SIZE, x: 5, y: 5 })
  })
})

describe('centreRect', () => {
  it('centres with whole numbers', () => {
    expect(centreRect({ h: 201, w: 301 }, bounds)).toEqual({ h: 201, w: 301, x: 450, y: 300 })
  })
})

describe('titleBar and contains', () => {
  it('titleBar gives the top 28 pixels', () => {
    expect(titleBar({ h: 200, w: 300, x: 10, y: 20 })).toEqual({ h: 28, w: 300, x: 10, y: 20 })
  })

  it('contains includes the top-left edge and excludes the bottom-right edge', () => {
    const r = { h: 50, w: 100, x: 10, y: 20 }
    expect(contains(r, { x: 10, y: 20 })).toBe(true)
    expect(contains(r, { x: 109, y: 69 })).toBe(true)
    expect(contains(r, { x: 110, y: 40 })).toBe(false)
    expect(contains(r, { x: 50, y: 70 })).toBe(false)
  })
})
