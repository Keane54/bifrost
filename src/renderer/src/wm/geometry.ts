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
// An arrow mark for one snap (spec 8.1): a point in panel-area coordinates on the snap line,
// and the direction in which the snap moves the panel edge.
export interface SnapMark {
  x: number
  y: number
  dir: 'left' | 'right' | 'up' | 'down'
}

export const SNAP_DISTANCE = 8
export const MIN_SIZE: Size = { h: 120, w: 200 }
export const TITLE_H = 28

type Axis = 'x' | 'y'

function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(value, low), high)
}

// A delta that is not a finite number counts as 0.
function finite(n: number): number {
  return Number.isFinite(n) ? n : 0
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
function snapLines(axis: Axis, r: Rect, others: Rect[], bounds: Size, snap: number) {
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

// The rect that the screen shows for a saved rect in the current area.
// The saved rect does not change. So a panel goes back to its saved rect when the area grows again.
export function shownRect(rect: Rect, bounds: Size): Rect {
  return clampRect(rect, bounds, MIN_SIZE)
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
): Rect {
  const raw = { ...start, x: start.x + finite(dx), y: start.y + finite(dy) }
  let { x, y } = raw

  const hit = closest([raw.x, raw.x + raw.w], snapLines('x', raw, others, bounds, snap), snap)
  if (hit) x = hit.edge === 0 ? hit.line : hit.line - raw.w
  const vit = closest([raw.y, raw.y + raw.h], snapLines('y', raw, others, bounds, snap), snap)
  if (vit) y = vit.edge === 0 ? vit.line : vit.line - raw.h

  return round({
    h: raw.h,
    w: raw.w,
    x: clamp(x, 0, Math.max(0, bounds.w - raw.w)),
    y: clamp(y, 0, Math.max(0, bounds.h - raw.h)),
  })
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
): Rect {
  let left = start.x
  let right = start.x + start.w
  let top = start.y
  let bottom = start.y + start.h
  if (edge.includes('w')) left += finite(dx)
  if (edge.includes('e')) right += finite(dx)
  if (edge.includes('n')) top += finite(dy)
  if (edge.includes('s')) bottom += finite(dy)
  // Round the four edges first. Then w and h come from whole edges, so a fixed edge never moves.
  left = Math.round(left)
  right = Math.round(right)
  top = Math.round(top)
  bottom = Math.round(bottom)

  // The moved rect, used to find the other rects that overlap it.
  const raw = {
    h: Math.abs(bottom - top),
    w: Math.abs(right - left),
    x: Math.min(left, right),
    y: Math.min(top, bottom),
  }
  const xLines = snapLines('x', raw, others, bounds, snap)
  const yLines = snapLines('y', raw, others, bounds, snap)

  // Rule for a start rect closer than min to the bounds: the limit low wins over the limit high,
  // so the minimum size holds and the edge can pass the bounds. The input is a clamped rect,
  // so this case does not occur in normal use.
  // Snap one moving edge, then apply the limits.
  function place(value: number, lines: number[], low: number, high: number) {
    const hit = closest([value], lines, snap)
    return clamp(hit ? hit.line : value, low, Math.max(low, high))
  }

  const moveLeft = edge.includes('w')
  const moveRight = edge.includes('e')
  const moveTop = edge.includes('n')
  const moveBottom = edge.includes('s')
  if (moveLeft) left = place(left, xLines, 0, right - min.w)
  if (moveRight) right = place(right, xLines, left + min.w, bounds.w)
  if (moveTop) top = place(top, yLines, 0, bottom - min.h)
  if (moveBottom) bottom = place(bottom, yLines, top + min.h, bounds.h)

  return {
    h: Math.round(bottom) - Math.round(top),
    w: Math.round(right) - Math.round(left),
    x: Math.round(left),
    y: Math.round(top),
  }
}

// The start and the end of a rect on one axis.
function extent(r: Rect, axis: Axis): [number, number] {
  return axis === 'x' ? [r.x, r.x + r.w] : [r.y, r.y + r.h]
}

// True when the two rects overlap on the axis, or come within SNAP_DISTANCE on it.
function near(a: Rect, b: Rect, axis: Axis): boolean {
  const [aStart, aEnd] = extent(a, axis)
  const [bStart, bEnd] = extent(b, axis)
  return overlaps(aStart, aEnd - aStart, bStart, bEnd - bStart, SNAP_DISTANCE)
}

// The mark for one axis, or null when no edge snaps on that axis.
// An edge snaps when the snapped rect puts it on a line, and the raw rect does not.
// The start edge comes first. A window edge comes before the edge of another panel.
function axisMark(
  axis: Axis,
  raw: Rect,
  snapped: Rect,
  others: Rect[],
  bounds: Size,
): SnapMark | null {
  const cross: Axis = axis === 'x' ? 'y' : 'x'
  const rawEdges = extent(raw, axis)
  const snappedEdges = extent(snapped, axis)
  const [low, high] = extent(snapped, cross)
  const limit = axis === 'x' ? bounds.w : bounds.h
  for (const i of [0, 1] as const) {
    const from = rawEdges[i]
    const line = snappedEdges[i]
    if (line === from) continue
    // For a window edge, the mark is at the middle of the panel edge.
    let along: number | null = null
    if (line === 0 || line === limit) along = (low + high) / 2
    else {
      // For another panel, the mark is at the middle of the overlap of the two edges.
      // The snap found that panel from the raw rect. The overlap uses the snapped rect.
      const other = others.find(
        o =>
          extent(o, axis).some(e => Math.round(e) === line) &&
          (near(raw, o, cross) || near(snapped, o, cross)),
      )
      if (other) {
        const [oLow, oHigh] = extent(other, cross)
        along = (Math.max(low, oLow) + Math.min(high, oHigh)) / 2
      }
    }
    if (along === null) continue
    const at = Math.round(along)
    const forward = line > from
    if (axis === 'x') return { dir: forward ? 'right' : 'left', x: line, y: at }
    return { dir: forward ? 'down' : 'up', x: at, y: line }
  }
  return null
}

// The arrow marks of the snap that a release applies (spec 8.1). The raw rect follows the
// pointer with no snap. The snapped rect is the same drag with the snap. Each axis that
// snaps gives one mark. The x mark comes first.
export function snapMarks(raw: Rect, snapped: Rect, others: Rect[], bounds: Size): SnapMark[] {
  const marks: SnapMark[] = []
  for (const axis of ['x', 'y'] as const) {
    const mark = axisMark(axis, raw, snapped, others, bounds)
    if (mark) marks.push(mark)
  }
  return marks
}

export function contains(r: Rect, p: Point): boolean {
  return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

export function titleBar(r: Rect): Rect {
  return { h: Math.min(TITLE_H, r.h), w: r.w, x: r.x, y: r.y }
}
