// Hit tests on the frames. The frames are in z-order, so the last frame is on top.
import { clampRect, contains, type Point, type Rect, type Size, titleBar } from './geometry'
import type { Frame } from './state'

// A tab leaves its stack when the pointer goes more than this distance from the title bar.
export const TEAR_DISTANCE = 12
// When a tab leaves its stack, the top left corner of the new frame is 60 pixels left of
// the pointer and 14 pixels above it.
export const TEAR_OFFSET: Point = { x: 60, y: 14 }
// A move can stack its frame only after the pointer went this distance from the drag start.
// So a small move of a frame whose title bar is on another title bar does not stack the frames.
export const STACK_DISTANCE = 4

// True when p is STACK_DISTANCE pixels or more from the start point of the drag.
export function movedToStack(start: Point, p: Point): boolean {
  return Math.hypot(p.x - start.x, p.y - start.y) >= STACK_DISTANCE
}

// The top visible frame that contains p. The excluded frame does not count.
export function frameAt(frames: Frame[], p: Point, excludeId?: string): Frame | undefined {
  for (let i = frames.length - 1; i >= 0; i--) {
    const frame = frames[i]
    if (!frame || frame.minimised || frame.id === excludeId) continue
    if (contains(frame.rect, p)) return frame
  }
  return undefined
}

// The top visible frame whose title bar contains p.
// If the body of a higher frame covers p, the result is nothing.
export function titleBarAt(frames: Frame[], p: Point, excludeId: string): Frame | undefined {
  const frame = frameAt(frames, p, excludeId)
  return frame && contains(titleBar(frame.rect), p) ? frame : undefined
}

// True when p is more than TEAR_DISTANCE pixels above, below, left or right of the title bar.
// The distance counts from the edges of the rect: x, x + w, y and y + h.
export function tornOut(bar: Rect, p: Point): boolean {
  return (
    p.y < bar.y - TEAR_DISTANCE ||
    p.y > bar.y + bar.h + TEAR_DISTANCE ||
    p.x < bar.x - TEAR_DISTANCE ||
    p.x > bar.x + bar.w + TEAR_DISTANCE
  )
}

// The rect of a tab that leaves its stack, at the pointer p.
// It has the saved size of the panel, or else the size of the stack. The size fits in the area.
// The reducer moves the rect into the area.
export function tearOutRect(p: Point, saved: Rect | undefined, stack: Rect, bounds: Size): Rect {
  const size = saved && Number.isFinite(saved.w) && Number.isFinite(saved.h) ? saved : stack
  const fit = clampRect({ h: size.h, w: size.w, x: 0, y: 0 }, bounds)
  return { h: fit.h, w: fit.w, x: p.x - TEAR_OFFSET.x, y: p.y - TEAR_OFFSET.y }
}
