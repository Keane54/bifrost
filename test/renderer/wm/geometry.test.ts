import { describe, expect, it } from 'vitest'
import {
  centreRect,
  clampRect,
  contains,
  moveRect,
  resizeRect,
  titleBar,
} from '../../../src/renderer/src/wm/geometry'

const bounds = { h: 800, w: 1200 }

describe('moveRect', () => {
  it('moves by dx and dy far from all edges', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    expect(moveRect(start, 10, 5, [], bounds)).toEqual({
      guides: [],
      rect: { h: 200, w: 300, x: 110, y: 105 },
    })
  })

  it('snaps the left edge to the bounds at 8 pixels', () => {
    const start = { h: 200, w: 300, x: 20, y: 100 }
    const result = moveRect(start, -12, 0, [], bounds)
    expect(result.rect.x).toBe(0)
    expect(result.guides).toEqual([{ at: 0, axis: 'x' }])
  })

  it('does not snap at 9 pixels', () => {
    const start = { h: 200, w: 300, x: 21, y: 100 }
    const result = moveRect(start, -12, 0, [], bounds)
    expect(result.rect.x).toBe(9)
    expect(result.guides).toEqual([])
  })

  it('snaps the right edge to the bounds', () => {
    const start = { h: 200, w: 300, x: 895, y: 100 }
    const result = moveRect(start, 0, 0, [], bounds)
    expect(result.rect.x).toBe(900)
    expect(result.guides).toEqual([{ at: 1200, axis: 'x' }])
  })

  it('snaps to the right edge of another rect with a y overlap', () => {
    const other = { h: 300, w: 400, x: 0, y: 100 }
    const start = { h: 200, w: 300, x: 405, y: 150 }
    const result = moveRect(start, 0, 0, [other], bounds)
    expect(result.rect.x).toBe(400)
    expect(result.guides).toEqual([{ at: 400, axis: 'x' }])
  })

  it('does not snap to another rect without a y overlap', () => {
    const other = { h: 100, w: 400, x: 0, y: 600 }
    const start = { h: 200, w: 300, x: 405, y: 100 }
    const result = moveRect(start, 0, 0, [other], bounds)
    expect(result.rect.x).toBe(405)
    expect(result.guides).toEqual([])
  })

  it('aligns left edges', () => {
    const other = { h: 200, w: 200, x: 300, y: 400 }
    const start = { h: 250, w: 300, x: 306, y: 150 }
    const result = moveRect(start, 0, 0, [other], bounds)
    expect(result.rect.x).toBe(300)
  })

  it('prefers the bounds line on a tie', () => {
    // The left edge is 4 from the bounds line at 0 and 4 from the other right edge at 8.
    const other = { h: 200, w: 8, x: 0, y: 100 }
    const start = { h: 200, w: 300, x: 4, y: 150 }
    const result = moveRect(start, 0, 0, [other], bounds)
    expect(result.rect.x).toBe(0)
    expect(result.guides).toEqual([{ at: 0, axis: 'x' }])
  })

  it('prefers the left edge on an equal distance', () => {
    const start = { h: 200, w: 1192, x: 4, y: 100 }
    const result = moveRect(start, 0, 0, [], bounds)
    expect(result.rect.x).toBe(0)
  })

  it('snaps the top edge to the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 20 }
    const result = moveRect(start, 0, -12, [], bounds)
    expect(result.rect.y).toBe(0)
    expect(result.guides).toEqual([{ at: 0, axis: 'y' }])
  })

  it('clamps the rect inside the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = moveRect(start, 5000, 5000, [], bounds)
    expect(result.rect.x).toBe(bounds.w - 300)
    expect(result.rect.y).toBe(bounds.h - 200)
  })
})

describe('resizeRect', () => {
  it('se snaps the right and bottom edges', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'se', 797, 497, [], bounds)
    expect(result.rect).toEqual({ h: 700, w: 1100, x: 100, y: 100 })
    expect(result.guides).toEqual([
      { at: 1200, axis: 'x' },
      { at: 800, axis: 'y' },
    ])
  })

  it('keeps the minimum size', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'se', -1000, -1000, [], bounds)
    expect(result.rect).toEqual({ h: 120, w: 200, x: 100, y: 100 })
    expect(result.guides).toEqual([])
  })

  it('nw keeps the right and bottom edges fixed at the minimum', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'nw', 500, 500, [], bounds)
    expect(result.rect).toEqual({ h: 120, w: 200, x: 200, y: 180 })
  })

  it('stops an edge at the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'e', 5000, 0, [], bounds)
    expect(result.rect.x + result.rect.w).toBe(bounds.w)
    expect(result.rect.y).toBe(100)
    expect(result.rect.h).toBe(200)
  })

  it('stops the left edge at the bounds', () => {
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'w', -5000, 0, [], bounds)
    expect(result.rect).toEqual({ h: 200, w: 400, x: 0, y: 100 })
  })

  it('snaps a moving edge to another rect', () => {
    const other = { h: 200, w: 200, x: 600, y: 100 }
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'e', 195, 0, [other], bounds)
    expect(result.rect.w).toBe(500)
    expect(result.guides).toEqual([{ at: 600, axis: 'x' }])
  })

  it('drops the guide when the minimum size stops the edge', () => {
    // The raw right edge is 300, 5 from the other left edge at 295. The minimum stops it at 300.
    const other = { h: 200, w: 200, x: 295, y: 100 }
    const start = { h: 200, w: 300, x: 100, y: 100 }
    const result = resizeRect(start, 'e', -100, 0, [other], bounds)
    expect(result.rect.w).toBe(200)
    expect(result.guides).toEqual([])
  })
})

describe('fixes after review', () => {
  const start = { h: 200, w: 300, x: 100, y: 100 }

  it('keeps the fixed edges with a fractional delta', () => {
    const w = resizeRect(start, 'w', 0.5, 0, [], bounds).rect
    expect(w.x + w.w).toBe(400)
    const n = resizeRect(start, 'n', 0, 0.5, [], bounds).rect
    expect(n.y + n.h).toBe(300)
    const nw = resizeRect(start, 'nw', 0.5, 0.5, [], bounds).rect
    expect(nw.x + nw.w).toBe(400)
    expect(nw.y + nw.h).toBe(300)
  })

  it('moveRect gives no guide when the clamp moves the rect off the line', () => {
    // The right edge snaps to the other left edge at 1207. The clamp then moves it to 1200.
    const other = { h: 200, w: 100, x: 1207, y: 100 }
    const wide = { h: 200, w: 300, x: 910, y: 100 }
    const result = moveRect(wide, 0, 0, [other], bounds)
    expect(result.rect.x).toBe(900)
    expect(result.guides.filter(g => g.axis === 'x')).toEqual([])
  })

  it('counts a non-finite delta as 0', () => {
    expect(moveRect(start, Number.NaN, Number.POSITIVE_INFINITY, [], bounds).rect).toEqual(start)
    expect(resizeRect(start, 'se', Number.NaN, Number.NEGATIVE_INFINITY, [], bounds).rect).toEqual(
      start,
    )
  })

  it('resizeRect snaps the y axis to another rect', () => {
    const other = { h: 100, w: 200, x: 100, y: 600 }
    const result = resizeRect(start, 's', 0, 297, [other], bounds)
    expect(result.rect.h).toBe(500)
    expect(result.guides).toEqual([{ at: 600, axis: 'y' }])
  })

  it('resizeRect nw snaps both edges', () => {
    const other = { h: 100, w: 50, x: 40, y: 40 }
    const result = resizeRect(start, 'nw', -56, -56, [other], bounds)
    expect(result.rect).toEqual({ h: 260, w: 360, x: 40, y: 40 })
    expect(result.guides).toEqual([
      { at: 40, axis: 'x' },
      { at: 40, axis: 'y' },
    ])
  })

  it('resizeRect ne snaps both edges', () => {
    const other = { h: 100, w: 100, x: 500, y: 40 }
    const result = resizeRect(start, 'ne', 97, -57, [other], bounds)
    expect(result.rect).toEqual({ h: 260, w: 400, x: 100, y: 40 })
    expect(result.guides).toEqual([
      { at: 500, axis: 'x' },
      { at: 40, axis: 'y' },
    ])
  })

  it('snaps at an overlap of exactly snap pixels', () => {
    // The moved rect ends at y 300. The other starts at y 308, exactly 8 away.
    const other = { h: 100, w: 100, x: 405, y: 308 }
    const result = moveRect({ h: 200, w: 300, x: 100, y: 100 }, 305, 0, [other], bounds)
    expect(result.rect.x).toBe(405)
    const far = moveRect({ h: 200, w: 300, x: 100, y: 100 }, 305, 0, [{ ...other, y: 309 }], bounds)
    expect(far.rect.x).toBe(405)
    expect(far.guides).toEqual([])
  })

  it('rounds a guide from a fractional rect', () => {
    const other = { h: 200, w: 100.4, x: 0, y: 100 }
    const result = moveRect({ h: 200, w: 300, x: 105, y: 100 }, 0, 0, [other], bounds)
    expect(result.guides).toContainEqual({ at: 100, axis: 'x' })
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
