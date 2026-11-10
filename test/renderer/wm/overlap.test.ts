import { describe, expect, it } from 'vitest'
import type { Rect } from '../../../src/renderer/src/wm/geometry'
import { blurredFrames, rectsOverlap } from '../../../src/renderer/src/wm/overlap'

// A frame in the z-order list. The first frame is at the bottom.
function frame(id: string, rect: Rect, minimised = false) {
  return { id, minimised, rect }
}

const A = { h: 200, w: 300, x: 0, y: 0 }
// To the right of A, with a gap.
const APART = { h: 200, w: 300, x: 400, y: 0 }
// To the right of A, with the left edge on the right edge of A (a snap).
const TOUCH = { h: 200, w: 300, x: 300, y: 0 }
// Over the bottom-right corner of A.
const OVER = { h: 200, w: 300, x: 200, y: 100 }

describe('rectsOverlap', () => {
  it('is true when two rects share an area', () => {
    expect(rectsOverlap(A, OVER)).toBe(true)
    expect(rectsOverlap(OVER, A)).toBe(true)
  })

  it('is true for an overlap of 1 pixel', () => {
    expect(rectsOverlap(A, { ...TOUCH, x: 299 })).toBe(true)
    expect(rectsOverlap(A, { ...A, y: 199 })).toBe(true)
  })

  it('is true when one rect is inside the other', () => {
    expect(rectsOverlap(A, { h: 10, w: 10, x: 50, y: 50 })).toBe(true)
  })

  it('is false for rects that only touch at an edge or a corner', () => {
    expect(rectsOverlap(A, TOUCH)).toBe(false)
    expect(rectsOverlap(A, { ...A, y: 200 })).toBe(false)
    expect(rectsOverlap(A, { ...A, x: 300, y: 200 })).toBe(false)
  })

  it('is false for rects with a gap', () => {
    expect(rectsOverlap(A, APART)).toBe(false)
  })
})

// User decision, 2026-11-10: a frame keeps its backdrop blur only while it overlaps a lower frame
// that shows. A frame over the background only has no blur.
describe('blurredFrames', () => {
  it('blurs no frame when one frame shows', () => {
    expect([...blurredFrames([frame('f1', A)])]).toEqual([])
  })

  it('blurs no frame when the frames do not overlap', () => {
    expect([...blurredFrames([frame('f1', A), frame('f2', APART)])]).toEqual([])
  })

  it('blurs no frame when the frames only touch at an edge', () => {
    expect([...blurredFrames([frame('f1', A), frame('f2', TOUCH)])]).toEqual([])
  })

  it('blurs the upper frame of two frames that overlap, not the lower frame', () => {
    expect([...blurredFrames([frame('f1', A), frame('f2', OVER)])]).toEqual(['f2'])
    // The z-order and not the ID sets which frame is upper.
    expect([...blurredFrames([frame('f2', OVER), frame('f1', A)])]).toEqual(['f1'])
  })

  it('does not count a minimised lower frame', () => {
    expect([...blurredFrames([frame('f1', A, true), frame('f2', OVER)])]).toEqual([])
  })

  it('does not blur a minimised frame', () => {
    expect([...blurredFrames([frame('f1', A), frame('f2', OVER, true)])]).toEqual([])
  })

  it('counts each lower frame, not only the frame just below', () => {
    const frames = [frame('f1', A), frame('f2', APART), frame('f3', { ...OVER, x: 100 })]
    expect([...blurredFrames(frames)]).toEqual(['f3'])
  })

  it('does not blur a frame for a frame above it', () => {
    const frames = [frame('f1', A), frame('f2', APART), frame('f3', { ...APART, y: 100 })]
    expect([...blurredFrames(frames)]).toEqual(['f3'])
  })

  it('uses the live rect of a frame during a drag', () => {
    const frames = [frame('f1', A), frame('f2', APART)]
    // The drag moves f2 over f1.
    expect([...blurredFrames(frames, { frameId: 'f2', rect: OVER })]).toEqual(['f2'])
    // The drag moves f2 away from f1.
    const over = [frame('f1', A), frame('f2', OVER)]
    expect([...blurredFrames(over, { frameId: 'f2', rect: APART })]).toEqual([])
  })

  it('uses the live rect of a lower frame for the frames above it', () => {
    const frames = [frame('f1', APART), frame('f2', A)]
    expect([...blurredFrames(frames, { frameId: 'f1', rect: OVER })]).toEqual(['f2'])
  })

  it('ignores a live rect of a frame that is not in the list', () => {
    const frames = [frame('f1', A), frame('f2', APART)]
    expect([...blurredFrames(frames, { frameId: 'f9', rect: OVER })]).toEqual([])
    expect([...blurredFrames(frames, null)]).toEqual([])
  })
})
