import { describe, expect, it } from 'vitest'
import { centreRect, type Rect, shownRect } from '../../../src/renderer/src/wm/geometry'
import { toSnapshot } from '../../../src/renderer/src/wm/layout'
import {
  DEFAULT_SIZES,
  frameOf,
  initialState,
  panelKind,
  shownFrames,
  topFrame,
  type WmAction,
  type WmState,
  wmReducer,
} from '../../../src/renderer/src/wm/state'

const bounds = { h: 800, w: 1200 }
const CHAT = 'chat:123e4567-e89b-12d3-a456-426614174000'

function run(actions: WmAction[], from: WmState = initialState(bounds)): WmState {
  return actions.reduce(wmReducer, from)
}
const open = (panelId: string): WmAction => ({ panelId, type: 'open' })

describe('wm state', () => {
  it('panelKind accepts the fixed panel IDs and refuses all others', () => {
    expect(panelKind('overview:1')).toBe('overview')
    expect(panelKind('overview:99')).toBe('overview')
    expect(panelKind('selected-item')).toBe('selected-item')
    expect(panelKind('integration')).toBe('integration')
    expect(panelKind(CHAT)).toBe('chat')
    expect(panelKind(CHAT.toUpperCase().replace('CHAT', 'chat'))).toBe('chat')
    for (const bad of [
      'overview:0',
      'overview:100',
      'overview:x',
      'chat:abc',
      'foo',
      'overview:01',
    ]) {
      expect(panelKind(bad)).toBeNull()
    }
  })

  it('open adds a centred frame with the default size', () => {
    const s = run([open('integration')])
    expect(s.frames).toHaveLength(1)
    expect(s.frames[0]).toMatchObject({
      active: 'integration',
      id: 'f1',
      locked: false,
      minimised: false,
      opacity: 1,
      panels: ['integration'],
      rect: centreRect(DEFAULT_SIZES.integration, bounds),
    })
    expect(s.nextFrame).toBe(2)
  })

  it('open uses the saved position from memory and clamps it', () => {
    const base = {
      ...initialState(bounds),
      memory: { 'overview:1': { h: 360, w: 760, x: 1000, y: 10 } },
    }
    const s = run([open('overview:1')], base)
    expect(s.frames[0]?.rect).toEqual({ h: 360, w: 760, x: 440, y: 10 })
  })

  it('open focuses, activates and restores a panel that is open', () => {
    let s = run([open('overview:1'), open('overview:2')])
    s = run([{ frameId: 'f1', targetId: 'f2', type: 'stack' as const }], s)
    s = run([{ frameId: 'f2', type: 'minimise' }, open('overview:1')], s)
    const f = frameOf(s, 'overview:1')
    expect(f?.active).toBe('overview:1')
    expect(f?.minimised).toBe(false)
    expect(s.frames).toHaveLength(1)

    let t = run([open('overview:1'), open('overview:2'), { frameId: 'f1', type: 'minimise' }])
    t = run([open('overview:1')], t)
    expect(t.frames.map(x => x.id)).toEqual(['f2', 'f1'])
    expect(t.frames[1]?.minimised).toBe(false)
  })

  it('open ignores an invalid panel ID', () => {
    const s = initialState(bounds)
    expect(wmReducer(s, open('nope'))).toBe(s)
  })

  it('close keeps the position in memory and removes an empty frame', () => {
    const s = run([open('integration')])
    const rect = s.frames[0]?.rect
    const c = run([{ panelId: 'integration', type: 'close' }], s)
    expect(c.frames).toEqual([])
    expect(c.memory.integration).toEqual(rect)
    expect(frameOf(run([open('integration')], c), 'integration')?.rect).toEqual(rect)
  })

  it('close of one tab keeps the other tabs and activates the tab to the left', () => {
    let s = run([open('overview:1'), open('overview:2'), open('overview:3')])
    s = run(
      [
        { frameId: 'f2', targetId: 'f1', type: 'stack' },
        { frameId: 'f3', targetId: 'f1', type: 'stack' },
      ],
      s,
    )
    expect(s.frames[0]?.panels).toEqual(['overview:1', 'overview:2', 'overview:3'])
    s = run([{ panelId: 'overview:3', type: 'close' }], s)
    expect(s.frames[0]).toMatchObject({
      active: 'overview:2',
      panels: ['overview:1', 'overview:2'],
    })
    s = run(
      [
        { panelId: 'overview:1', type: 'activate' },
        { panelId: 'overview:1', type: 'close' },
      ],
      s,
    )
    expect(s.frames[0]).toMatchObject({ active: 'overview:2', panels: ['overview:2'] })
  })

  it('closeActive closes the active panel of the top frame', () => {
    const s = run([open('overview:1'), open('integration'), { frameId: 'f2', type: 'minimise' }])
    const c = run([{ type: 'closeActive' }], s)
    expect(c.frames.map(f => f.id)).toEqual(['f2'])
    expect(topFrame(s)?.id).toBe('f1')
  })

  it('focus moves the frame to the top', () => {
    const s = run([open('overview:1'), open('overview:2'), { frameId: 'f1', type: 'focus' }])
    expect(s.frames.map(f => f.id)).toEqual(['f2', 'f1'])
  })

  it('setRect clamps and ignores a locked or minimised frame', () => {
    let s = run([open('overview:1')])
    s = run([{ frameId: 'f1', rect: { h: 300, w: 400, x: 5000, y: -20 }, type: 'setRect' }], s)
    expect(s.frames[0]?.rect).toEqual({ h: 300, w: 400, x: 800, y: 0 })
    const locked = run([{ frameId: 'f1', locked: true, type: 'lock' }], s)
    const move: WmAction = { frameId: 'f1', rect: { h: 300, w: 400, x: 1, y: 1 }, type: 'setRect' }
    expect(wmReducer(locked, move)).toBe(locked)
    const min = run([{ frameId: 'f1', type: 'minimise' }], s)
    expect(wmReducer(min, move)).toBe(min)
  })

  it('stack moves the panels of the source into the target', () => {
    const s = run([open('overview:1'), open('overview:2'), open('overview:3')])
    const t = run([{ frameId: 'f1', targetId: 'f2', type: 'stack' }], s)
    expect(t.frames.map(f => f.id)).toEqual(['f3', 'f2'])
    expect(t.frames[1]).toMatchObject({
      active: 'overview:1',
      panels: ['overview:2', 'overview:1'],
    })
  })

  it('stack refuses the same frame, a minimised frame or a locked source', () => {
    const s = run([open('overview:1'), open('overview:2')])
    const same: WmAction = { frameId: 'f1', targetId: 'f1', type: 'stack' }
    expect(wmReducer(s, same)).toBe(s)
    const min = run([{ frameId: 'f2', type: 'minimise' }], s)
    expect(wmReducer(min, { frameId: 'f1', targetId: 'f2', type: 'stack' })).toBe(min)
    expect(wmReducer(min, { frameId: 'f2', targetId: 'f1', type: 'stack' })).toBe(min)
    const locked = run([{ frameId: 'f1', locked: true, type: 'lock' }], s)
    expect(wmReducer(locked, { frameId: 'f1', targetId: 'f2', type: 'stack' })).toBe(locked)
  })

  it('unstack makes a new frame on top with the old opacity', () => {
    let s = run([
      open('overview:1'),
      open('overview:2'),
      { frameId: 'f2', targetId: 'f1', type: 'stack' },
      { frameId: 'f1', opacity: 0.5, type: 'opacity' },
    ])
    const old = s.frames[0]?.rect
    s = run([{ panelId: 'overview:2', rect: { h: 300, w: 400, x: 50, y: 60 }, type: 'unstack' }], s)
    expect(s.frames.map(f => f.id)).toEqual(['f1', 'f3'])
    expect(s.frames[0]).toMatchObject({ active: 'overview:1', panels: ['overview:1'] })
    expect(s.frames[1]).toMatchObject({
      locked: false,
      opacity: 0.5,
      panels: ['overview:2'],
      rect: { h: 300, w: 400, x: 50, y: 60 },
    })
    expect(s.memory['overview:2']).toEqual(old)
    expect(s.nextFrame).toBe(4)
  })

  it('unstack refuses a frame with one panel or a locked frame', () => {
    const rect = { h: 300, w: 400, x: 50, y: 60 }
    const one = run([open('overview:1')])
    expect(wmReducer(one, { panelId: 'overview:1', rect, type: 'unstack' })).toBe(one)
    const two = run([
      open('overview:1'),
      open('overview:2'),
      { frameId: 'f2', targetId: 'f1', type: 'stack' },
    ])
    const locked = run([{ frameId: 'f1', locked: true, type: 'lock' }], two)
    expect(wmReducer(locked, { panelId: 'overview:2', rect, type: 'unstack' })).toBe(locked)
  })

  it('opacity is clamped to 0.3 and 1', () => {
    const s = run([open('overview:1')])
    const at = (opacity: number) =>
      wmReducer(s, { frameId: 'f1', opacity, type: 'opacity' }).frames[0]?.opacity
    expect(at(0)).toBe(0.3)
    expect(at(5)).toBe(1)
    expect(at(0.456)).toBe(0.46)
  })

  it('bounds keeps the saved rects and shows each frame inside a smaller window', () => {
    const before = run([open('overview:1'), open('integration')])
    const s = run([{ bounds: { h: 400, w: 600 }, type: 'bounds' }], before)
    expect(s.bounds).toEqual({ h: 400, w: 600 })
    expect(s.frames.map(f => f.rect)).toEqual(before.frames.map(f => f.rect))
    for (const f of s.frames) {
      const shown = shownRect(f.rect, s.bounds)
      expect(shown.x).toBeGreaterThanOrEqual(0)
      expect(shown.y).toBeGreaterThanOrEqual(0)
      expect(shown.x + shown.w).toBeLessThanOrEqual(600)
      expect(shown.y + shown.h).toBeLessThanOrEqual(400)
    }
  })

  it('a layout from a 1440 x 900 area shows inside 800 x 500 and goes back in 1440 x 900', () => {
    const large = { h: 900, w: 1440 }
    const small = { h: 500, w: 800 }
    const saved: Rect[] = [
      { h: 360, w: 760, x: 16, y: 16 },
      { h: 356, w: 420, x: 1004, y: 528 },
      { h: 900, w: 1440, x: 0, y: 0 },
    ]
    const frames = saved.map((rect, i) => ({
      active: `overview:${i + 1}`,
      locked: false,
      minimised: false,
      opacity: 1,
      panels: [`overview:${i + 1}`],
      rect,
    }))
    let s = run([{ frames, memory: {}, type: 'load' }], initialState(small))
    expect(s.frames.map(f => f.rect)).toEqual(saved)
    for (const f of shownFrames(s)) {
      expect(f.rect.x + f.rect.w).toBeLessThanOrEqual(small.w)
      expect(f.rect.y + f.rect.h).toBeLessThanOrEqual(small.h)
    }
    expect(shownFrames(s).map(f => f.rect)).not.toEqual(saved)
    // The save keeps the saved rects, not the shown rects.
    expect(toSnapshot(s).frames.map(f => f.rect)).toEqual(saved)
    s = run([{ bounds: large, type: 'bounds' }], s)
    expect(shownFrames(s).map(f => f.rect)).toEqual(saved)
  })

  it('shownFrames keeps the frame objects whose rects fit the area', () => {
    let s = run([open('overview:1'), open('integration')])
    s = run([{ frameId: 'f2', rect: { h: 300, w: 400, x: 700, y: 400 }, type: 'setRect' }], s)
    const shown = shownFrames(run([{ bounds: { h: 600, w: 1000 }, type: 'bounds' }], s))
    expect(shown[0]).toBe(s.frames[0])
    expect(shown[1]?.rect).toEqual({ h: 300, w: 400, x: 600, y: 300 })
  })

  it('load replaces the frames, drops invalid and repeated panels, and keeps the rects', () => {
    const base = run([open('integration')])
    const r = { h: 300, w: 400, x: 5000, y: 5000 }
    const mk = (panels: string[], active: string) => ({
      active,
      locked: false,
      minimised: false,
      opacity: 1,
      panels,
      rect: r,
    })
    const memory = { 'overview:9': { h: 200, w: 200, x: 1, y: 1 } }
    const s = wmReducer(base, {
      frames: [
        mk(['overview:1', 'bad'], 'bad'),
        mk(['bad'], 'bad'),
        mk(['overview:1'], 'overview:1'),
        mk(['overview:2', 'selected-item'], 'selected-item'),
      ],
      memory,
      type: 'load',
    })
    expect(s.frames.map(f => f.id)).toEqual(['f2', 'f3'])
    expect(s.frames[0]).toMatchObject({ active: 'overview:1', panels: ['overview:1'] })
    expect(s.frames[0]?.rect).toEqual(r)
    expect(shownFrames(s)[0]?.rect).toEqual({ h: 300, w: 400, x: 800, y: 500 })
    expect(s.frames[1]?.panels).toEqual(['overview:2', 'selected-item'])
    expect(s.memory).toEqual(memory)
    expect(s.nextFrame).toBe(4)
  })

  it('a no-change action returns the same state object', () => {
    const s = run([open('overview:1'), open('overview:2')])
    const f2 = s.frames[1]
    const actions: WmAction[] = [
      open('nope'),
      open('overview:2'),
      { panelId: 'integration', type: 'close' },
      { frameId: 'zz', type: 'focus' },
      { frameId: 'f2', type: 'focus' },
      { frameId: 'f2', rect: f2?.rect as never, type: 'setRect' },
      { frameId: 'f2', targetId: 'zz', type: 'stack' },
      { panelId: 'zz', rect: f2?.rect as never, type: 'unstack' },
      { panelId: 'overview:2', type: 'activate' },
      { frameId: 'f2', type: 'restore' },
      { frameId: 'f2', locked: false, type: 'lock' },
      { frameId: 'f2', opacity: 1, type: 'opacity' },
      { bounds, type: 'bounds' },
    ]
    for (const a of actions) expect(wmReducer(s, a)).toBe(s)
    const empty = initialState(bounds)
    expect(wmReducer(empty, { type: 'closeActive' })).toBe(empty)
    const min = run([{ frameId: 'f1', type: 'minimise' }], s)
    expect(wmReducer(min, { frameId: 'f1', type: 'minimise' })).toBe(min)
  })

  it('close of a stack tab then open puts the panel at the stack rect', () => {
    let s = run([open('overview:1'), open('integration')])
    s = run([{ frameId: 'f2', targetId: 'f1', type: 'stack' }], s)
    const moved = { h: 300, w: 400, x: 120, y: 90 }
    s = run([{ frameId: 'f1', rect: moved, type: 'setRect' }], s)
    const rectAtClose = s.frames[0]?.rect
    s = run([{ panelId: 'integration', type: 'close' }], s)
    expect(s.frames).toHaveLength(1)
    s = run([open('integration')], s)
    expect(frameOf(s, 'integration')?.rect).toEqual(rectAtClose)
    expect(frameOf(s, 'integration')?.rect).toEqual(moved)
  })

  it('the reducer does not mutate its input', () => {
    const deepFreeze = <T>(value: T): T => {
      if (typeof value === 'object' && value !== null) {
        for (const v of Object.values(value)) deepFreeze(v)
        Object.freeze(value)
      }
      return value
    }
    const base = run([open('overview:1'), open('integration'), open('selected-item')])
    const stacked = run([{ frameId: 'f2', targetId: 'f1', type: 'stack' }], base)
    const s = deepFreeze(run([{ panelId: 'selected-item', type: 'close' }], stacked))
    expect(s.frames.length).toBe(1)
    expect(Object.keys(s.memory).length).toBeGreaterThan(0)
    const second = deepFreeze(run([open('overview:2')], s))
    const f = second.frames
    const r = { h: 250, w: 350, x: 40, y: 50 }
    const actions: WmAction[] = [
      open('chat:123e4567-e89b-12d3-a456-426614174000'),
      open('selected-item'),
      { panelId: 'integration', type: 'close' },
      { type: 'closeActive' },
      { frameId: f[0]?.id ?? '', type: 'focus' },
      { frameId: f[0]?.id ?? '', rect: r, type: 'setRect' },
      { frameId: f[1]?.id ?? '', targetId: f[0]?.id ?? '', type: 'stack' },
      { panelId: 'integration', rect: r, type: 'unstack' },
      { panelId: 'integration', type: 'activate' },
      { frameId: f[0]?.id ?? '', type: 'minimise' },
      { frameId: f[0]?.id ?? '', type: 'restore' },
      { frameId: f[0]?.id ?? '', locked: true, type: 'lock' },
      { frameId: f[0]?.id ?? '', opacity: 0.5, type: 'opacity' },
      { bounds: { h: 400, w: 500 }, type: 'bounds' },
      { frames: [], memory: {}, type: 'load' },
    ]
    for (const a of actions) expect(() => wmReducer(second, a)).not.toThrow()
  })

  it('bounds with a width or height under 1 changes nothing', () => {
    const s = run([open('integration')])
    for (const b of [
      { h: 800, w: 0 },
      { h: 0, w: 1200 },
      { h: -5, w: -5 },
      { h: 0.5, w: 900 },
    ]) {
      expect(wmReducer(s, { bounds: b, type: 'bounds' })).toBe(s)
    }
  })
})
