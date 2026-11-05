// Hit tests on the frames. The frames are in z-order, so the last frame is on top.
import { contains, type Point, type Rect, titleBar } from './geometry'
import type { Frame } from './state'

// A tab leaves its stack when the pointer goes more than this distance from the title bar.
export const TEAR_DISTANCE = 12

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
