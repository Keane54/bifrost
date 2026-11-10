// The frames that get the backdrop blur (spec 8.10). This module is pure.
//
// User decision, 2026-11-10: a frame keeps its backdrop blur only while it overlaps a lower frame
// that shows. A frame over the background only has no blur. The GPU must blur the area behind
// each blurred frame again at each new frame of the background. So fewer blurred frames cost
// less.
import type { Rect } from './geometry'

// A frame of the z-order list: the first frame is at the bottom.
export interface StackedFrame {
  id: string
  rect: Rect
  minimised: boolean
}

// The rect of the dragged frame during a drag. The state gets it only when the drag ends.
export interface LiveRect {
  frameId: string
  rect: Rect
}

// True when the two rects share an area. Rects that only touch at an edge or a corner do not
// overlap. Frames that snap together touch at an edge.
export function rectsOverlap(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// The IDs of the frames that overlap a lower frame that shows. A minimised frame does not show,
// so it gets no blur and does not count as a lower frame. During a drag, the live rect replaces
// the rect of the dragged frame.
export function blurredFrames(
  frames: readonly StackedFrame[],
  live?: LiveRect | null,
): ReadonlySet<string> {
  const rectOf = (frame: StackedFrame): Rect =>
    live && live.frameId === frame.id ? live.rect : frame.rect
  const result = new Set<string>()
  frames.forEach((frame, z) => {
    if (frame.minimised) return
    const rect = rectOf(frame)
    const over = frames
      .slice(0, z)
      .some(lower => !lower.minimised && rectsOverlap(rect, rectOf(lower)))
    if (over) result.add(frame.id)
  })
  return result
}
