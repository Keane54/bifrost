// Hit tests on the frames. The frames are in z-order, so the last frame is on top.
import { contains, type Point, titleBar } from './geometry'
import type { Frame } from './state'

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
