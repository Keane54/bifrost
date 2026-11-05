import { describe, expect, it } from 'vitest'
import type { Rect } from '../../../src/renderer/src/wm/geometry'
import { frameAt, titleBarAt } from '../../../src/renderer/src/wm/hit'
import type { Frame } from '../../../src/renderer/src/wm/state'

function frame(id: string, rect: Rect, minimised = false): Frame {
  return {
    active: 'overview:1',
    id,
    locked: false,
    minimised,
    opacity: 1,
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
})
