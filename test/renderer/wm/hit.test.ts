import { describe, expect, it } from 'vitest'
import type { Rect } from '../../../src/renderer/src/wm/geometry'
import {
  frameAt,
  movedToStack,
  STACK_DISTANCE,
  TEAR_DISTANCE,
  TEAR_OFFSET,
  tearOutRect,
  titleBarAt,
  tornOut,
} from '../../../src/renderer/src/wm/hit'
import type { Frame } from '../../../src/renderer/src/wm/state'

function frame(id: string, rect: Rect, minimised = false): Frame {
  return {
    active: 'overview:1',
    id,
    locked: false,
    minimised,
    panels: ['overview:1'],
    rect,
  }
}

// In z-order: f1 at the bottom, f3 on top. All three cover the point (150, 150).
const low = frame('f1', { h: 300, w: 300, x: 0, y: 0 })
const mid = frame('f2', { h: 300, w: 300, x: 100, y: 100 })
const high = frame('f3', { h: 300, w: 300, x: 120, y: 120 })

describe('wm hit tests', () => {
  it('frameAt gives the top frame that contains the point and skips minimised frames', () => {
    expect(frameAt([low, mid, high], { x: 150, y: 150 })?.id).toBe('f3')
    expect(frameAt([low, mid], { x: 150, y: 150 })?.id).toBe('f2')
    expect(frameAt([low, mid, { ...high, minimised: true }], { x: 150, y: 150 })?.id).toBe('f2')
    expect(frameAt([low, mid, high], { x: 50, y: 50 })?.id).toBe('f1')
    expect(frameAt([low, mid, high], { x: 500, y: 500 })).toBeUndefined()
    expect(frameAt([{ ...low, minimised: true }], { x: 50, y: 50 })).toBeUndefined()
  })

  it('frameAt skips the excluded frame', () => {
    expect(frameAt([low, mid, high], { x: 150, y: 150 }, 'f3')?.id).toBe('f2')
    expect(frameAt([low, mid, high], { x: 150, y: 150 }, 'f2')?.id).toBe('f3')
    expect(frameAt([low], { x: 50, y: 50 }, 'f1')).toBeUndefined()
  })

  it('titleBarAt gives the frame whose title bar has the point', () => {
    const target = frame('f1', { h: 300, w: 300, x: 0, y: 0 })
    const dragged = frame('f2', { h: 200, w: 200, x: 10, y: 5 })
    // The dragged frame is on top and covers the point, but it does not count.
    expect(titleBarAt([target, dragged], { x: 20, y: 10 }, 'f2')?.id).toBe('f1')
    // The last row of the title bar (TITLE_H = 28) has the point. The next row does not.
    expect(titleBarAt([target, dragged], { x: 20, y: 27 }, 'f2')?.id).toBe('f1')
    expect(titleBarAt([target, dragged], { x: 20, y: 28 }, 'f2')).toBeUndefined()
    // A minimised frame has no title bar on the screen.
    expect(titleBarAt([{ ...target, minimised: true }, dragged], { x: 20, y: 10 }, 'f2')).toBe(
      undefined,
    )
  })

  it('titleBarAt gives nothing when a higher frame covers the point', () => {
    const target = frame('f1', { h: 300, w: 300, x: 0, y: 0 })
    const cover = frame('f2', { h: 200, w: 200, x: 0, y: 0 })
    const dragged = frame('f3', { h: 200, w: 200, x: 400, y: 400 })
    // The point is in the title bar of f2, which is above f1. So f2 is the result.
    expect(titleBarAt([target, cover, dragged], { x: 20, y: 10 }, 'f3')?.id).toBe('f2')
    // The point is in the title bar of f1, but the body of f2 covers it.
    const lower = { ...cover, rect: { h: 200, w: 200, x: 0, y: -100 } }
    expect(titleBarAt([target, lower, dragged], { x: 20, y: 10 }, 'f3')).toBeUndefined()
    // The same frames in the other z-order: f1 is on top, so its title bar has the point.
    expect(titleBarAt([lower, target, dragged], { x: 20, y: 10 }, 'f3')?.id).toBe('f1')
  })

  it('movedToStack is false for a move of less than 4 pixels from the drag start', () => {
    expect(STACK_DISTANCE).toBe(4)
    const start = { x: 200, y: 100 }
    expect(movedToStack(start, start)).toBe(false)
    expect(movedToStack(start, { x: 201, y: 100 })).toBe(false)
    expect(movedToStack(start, { x: 197, y: 100 })).toBe(false)
    expect(movedToStack(start, { x: 202, y: 102 })).toBe(false)
  })

  it('movedToStack is true for a move of 4 pixels or more from the drag start', () => {
    const start = { x: 200, y: 100 }
    expect(movedToStack(start, { x: 204, y: 100 })).toBe(true)
    expect(movedToStack(start, { x: 200, y: 96 })).toBe(true)
    expect(movedToStack(start, { x: 197, y: 97 })).toBe(true)
    expect(movedToStack(start, { x: 900, y: 600 })).toBe(true)
  })

  it('tearOutRect gives the saved size of the panel at the pointer', () => {
    const area = { h: 800, w: 1200 }
    const stack = { h: 420, w: 800, x: 200, y: 352 }
    const p = { x: 700, y: 150 }
    const saved = { h: 356, w: 420, x: 900, y: 40 }
    expect(TEAR_OFFSET).toEqual({ x: 60, y: 14 })
    expect(tearOutRect(p, saved, stack, area)).toEqual({ h: 356, w: 420, x: 640, y: 136 })
  })

  it('tearOutRect gives the size of the stack when the panel has no saved size', () => {
    const area = { h: 800, w: 1200 }
    const stack = { h: 420, w: 800, x: 200, y: 352 }
    expect(tearOutRect({ x: 700, y: 150 }, undefined, stack, area)).toEqual({
      h: 420,
      w: 800,
      x: 640,
      y: 136,
    })
  })

  it('tearOutRect fits a saved size that is larger than the area', () => {
    const area = { h: 500, w: 800 }
    const stack = { h: 300, w: 400, x: 0, y: 0 }
    const saved = { h: 900, w: 1440, x: 0, y: 0 }
    const rect = tearOutRect({ x: 100, y: 100 }, saved, stack, area)
    expect({ h: rect.h, w: rect.w }).toEqual({ h: 500, w: 800 })
  })

  // The title bar of a frame at x 100, y 50. Its edges are x 100 and 400, y 50 and 78.
  const bar: Rect = { h: 28, w: 300, x: 100, y: 50 }

  it('tornOut is false inside the title bar and at 12 pixels', () => {
    expect(TEAR_DISTANCE).toBe(12)
    expect(tornOut(bar, { x: 150, y: 60 })).toBe(false)
    expect(tornOut(bar, { x: 100, y: 50 })).toBe(false)
    expect(tornOut(bar, { x: 399, y: 77 })).toBe(false)
    // 12 pixels above, below, left and right of the edges.
    expect(tornOut(bar, { x: 150, y: 38 })).toBe(false)
    expect(tornOut(bar, { x: 150, y: 90 })).toBe(false)
    expect(tornOut(bar, { x: 88, y: 60 })).toBe(false)
    expect(tornOut(bar, { x: 412, y: 60 })).toBe(false)
    // 12 pixels from two edges at the same time.
    expect(tornOut(bar, { x: 88, y: 38 })).toBe(false)
    expect(tornOut(bar, { x: 412, y: 90 })).toBe(false)
  })

  it('tornOut is true at 13 pixels above, below, left or right', () => {
    expect(tornOut(bar, { x: 150, y: 37 })).toBe(true)
    expect(tornOut(bar, { x: 150, y: 91 })).toBe(true)
    expect(tornOut(bar, { x: 87, y: 60 })).toBe(true)
    expect(tornOut(bar, { x: 413, y: 60 })).toBe(true)
    // Far away on one axis and inside on the other axis.
    expect(tornOut(bar, { x: 250, y: 500 })).toBe(true)
    expect(tornOut(bar, { x: -300, y: 60 })).toBe(true)
  })
})
