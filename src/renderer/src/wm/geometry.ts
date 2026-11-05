// Pure geometry for the panels. All results are whole numbers.

export interface Rect {
  x: number
  y: number
  w: number
  h: number
}
export interface Size {
  w: number
  h: number
}
export interface Point {
  x: number
  y: number
}
export type Edge = 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw'
// A vertical line at x, or a horizontal line at y.
export interface Guide {
  axis: 'x' | 'y'
  at: number
}

export const SNAP_DISTANCE = 8
export const MIN_SIZE: Size = { h: 120, w: 200 }
export const TITLE_H = 28

interface Result {
  rect: Rect
  guides: Guide[]
}

function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(value, low), high)
}

function round(r: Rect): Rect {
  return { h: Math.round(r.h), w: Math.round(r.w), x: Math.round(r.x), y: Math.round(r.y) }
}

// Two ranges overlap when they touch or come within `snap` pixels.
function overlaps(aStart: number, aLen: number, bStart: number, bLen: number, snap: number) {
  return bStart <= aStart + aLen + snap && aStart <= bStart + bLen + snap
}

// The lines on one axis: the bounds first, then the edges of each other rect that
// overlaps the moving rect on the other axis.
function snapLines(axis: 'x' | 'y', r: Rect, others: Rect[], bounds: Size, snap: number) {
  const lines = [0, axis === 'x' ? bounds.w : bounds.h]
  for (const o of others) {
    const near =
      axis === 'x' ? overlaps(r.y, r.h, o.y, o.h, snap) : overlaps(r.x, r.w, o.x, o.w, snap)
    if (!near) continue
    if (axis === 'x') lines.push(o.x, o.x + o.w)
    else lines.push(o.y, o.y + o.h)
  }
  return lines
}

// Finds the closest line for the given edge positions.
// The first edge wins an equal distance. The first line wins an equal distance.
function closest(edges: number[], lines: number[], snap: number) {
  let best: { edge: number; line: number; dist: number } | null = null
  edges.forEach((value, edge) => {
    for (const line of lines) {
      const dist = Math.abs(value - line)
      if (dist <= snap && (best === null || dist < best.dist)) best = { dist, edge, line }
    }
  })
  return best as { edge: number; line: number; dist: number } | null
}

export function clampRect(r: Rect, bounds: Size, min: Size = MIN_SIZE): Rect {
  const w = Math.min(bounds.w, Math.max(r.w, min.w))
  const h = Math.min(bounds.h, Math.max(r.h, min.h))
  return round({
    h,
    w,
    x: clamp(r.x, 0, bounds.w - w),
    y: clamp(r.y, 0, bounds.h - h),
  })
}

export function centreRect(size: Size, bounds: Size): Rect {
  return round({
    h: size.h,
    w: size.w,
    x: (bounds.w - size.w) / 2,
    y: (bounds.h - size.h) / 2,
  })
}

export function moveRect(
  start: Rect,
  dx: number,
  dy: number,
  others: Rect[],
  bounds: Size,
  snap: number = SNAP_DISTANCE,
): Result {
  const raw = { ...start, x: start.x + dx, y: start.y + dy }
  const guides: Guide[] = []
  let { x, y } = raw

  const hit = closest([raw.x, raw.x + raw.w], snapLines('x', raw, others, bounds, snap), snap)
  if (hit) {
    x = hit.edge === 0 ? hit.line : hit.line - raw.w
    guides.push({ at: hit.line, axis: 'x' })
  }
  const vit = closest([raw.y, raw.y + raw.h], snapLines('y', raw, others, bounds, snap), snap)
  if (vit) {
    y = vit.edge === 0 ? vit.line : vit.line - raw.h
    guides.push({ at: vit.line, axis: 'y' })
  }

  return {
    guides,
    rect: round({
      h: raw.h,
      w: raw.w,
      x: clamp(x, 0, Math.max(0, bounds.w - raw.w)),
      y: clamp(y, 0, Math.max(0, bounds.h - raw.h)),
    }),
  }
}

export function resizeRect(
  start: Rect,
  edge: Edge,
  dx: number,
  dy: number,
  others: Rect[],
  bounds: Size,
  snap: number = SNAP_DISTANCE,
  min: Size = MIN_SIZE,
): Result {
  let left = start.x
  let right = start.x + start.w
  let top = start.y
  let bottom = start.y + start.h
  if (edge.includes('w')) left += dx
  if (edge.includes('e')) right += dx
  if (edge.includes('n')) top += dy
  if (edge.includes('s')) bottom += dy

  // The moved rect, used to find the other rects that overlap it.
  const raw = {
    h: Math.abs(bottom - top),
    w: Math.abs(right - left),
    x: Math.min(left, right),
    y: Math.min(top, bottom),
  }
  const guides: Guide[] = []
  const xLines = snapLines('x', raw, others, bounds, snap)
  const yLines = snapLines('y', raw, others, bounds, snap)

  // Snap one moving edge, apply the limits, and keep the guide only if the edge stays on it.
  function place(value: number, lines: number[], low: number, high: number, axis: 'x' | 'y') {
    const hit = closest([value], lines, snap)
    const snapped = hit ? hit.line : value
    const result = clamp(snapped, low, Math.max(low, high))
    if (hit && result === snapped) guides.push({ at: snapped, axis })
    return result
  }

  const moveLeft = edge.includes('w')
  const moveRight = edge.includes('e')
  const moveTop = edge.includes('n')
  const moveBottom = edge.includes('s')
  if (moveLeft) left = place(left, xLines, 0, right - min.w, 'x')
  if (moveRight) right = place(right, xLines, left + min.w, bounds.w, 'x')
  if (moveTop) top = place(top, yLines, 0, bottom - min.h, 'y')
  if (moveBottom) bottom = place(bottom, yLines, top + min.h, bounds.h, 'y')

  return {
    guides,
    rect: round({ h: bottom - top, w: right - left, x: left, y: top }),
  }
}

export function contains(r: Rect, p: Point): boolean {
  return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

export function titleBar(r: Rect): Rect {
  return { h: Math.min(TITLE_H, r.h), w: r.w, x: r.x, y: r.y }
}
