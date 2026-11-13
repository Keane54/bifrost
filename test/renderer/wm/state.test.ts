import { describe, expect, it } from 'vitest'
import { centreRect, type Rect, shownRect, TITLE_H } from '../../../src/renderer/src/wm/geometry'
import { toSnapshot } from '../../../src/renderer/src/wm/layout'
import {
  DEFAULT_SIZES,
  frameOf,
  initialState,
  overviewSettingsId,
  panelKind,
  settingsOverviewId,
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
  it('a new Selected Item panel opens at 360 x 300 when the memory has no rect for it', () => {
    expect(DEFAULT_SIZES['selected-item']).toEqual({ h: 300, w: 360 })
    const s = run([open('selected-item')])
    expect(s.frames[0]?.rect).toMatchObject({ h: 300, w: 360 })
  })

  it('panelKind accepts event-log', () => {
    expect(panelKind('event-log')).toBe('event-log')
    expect(DEFAULT_SIZES['event-log']).toEqual({ h: 360, w: 640 })
    expect(run([open('event-log')]).frames[0]?.rect).toMatchObject({ h: 360, w: 640 })
  })

  it('panelKind accepts service-status', () => {
    expect(panelKind('service-status')).toBe('service-status')
    expect(DEFAULT_SIZES['service-status']).toEqual({ h: 240, w: 420 })
    expect(run([open('service-status')]).frames[0]?.rect).toMatchObject({ h: 240, w: 420 })
  })

  it('panelKind accepts trust', () => {
    expect(panelKind('trust')).toBe('trust')
    expect(DEFAULT_SIZES.trust).toEqual({ h: 380, w: 640 })
    expect(run([open('trust')]).frames[0]?.rect).toMatchObject({ h: 380, w: 640 })
  })

  it('panelKind accepts reviews', () => {
    expect(panelKind('reviews')).toBe('reviews')
    expect(DEFAULT_SIZES.reviews).toEqual({ h: 420, w: 480 })
    expect(run([open('reviews')]).frames[0]?.rect).toMatchObject({ h: 420, w: 480 })
  })

  it('panelKind accepts performance', () => {
    expect(panelKind('performance')).toBe('performance')
    expect(DEFAULT_SIZES.performance).toEqual({ h: 460, w: 520 })
    expect(run([open('performance')]).frames[0]?.rect).toMatchObject({ h: 460, w: 520 })
  })

  it('panelKind accepts daily-update', () => {
    expect(panelKind('daily-update')).toBe('daily-update')
    expect(DEFAULT_SIZES['daily-update']).toEqual({ h: 520, w: 560 })
    expect(run([open('daily-update')]).frames[0]?.rect).toMatchObject({ h: 520, w: 560 })
  })

  it('panelKind accepts usage-hud', () => {
    expect(panelKind('usage-hud')).toBe('usage-hud')
    expect(DEFAULT_SIZES['usage-hud']).toEqual({ h: 180, w: 360 })
    expect(run([open('usage-hud')]).frames[0]?.rect).toMatchObject({ h: 180, w: 360 })
  })

  it('the Usage HUD default height holds its content with a margin', () => {
    // The Task 9 check measured 146 px of content. The frame has the title bar and a 1 px border
    // at the top and at the bottom. The margin is at least 4 px.
    const CONTENT_H = 146
    const area = DEFAULT_SIZES['usage-hud'].h - TITLE_H - 2
    expect(area).toBeGreaterThanOrEqual(CONTENT_H + 4)
  })

  it('panelKind accepts the fixed panel IDs and refuses all others', () => {
    expect(panelKind('overview:1')).toBe('overview')
    expect(panelKind('overview:99')).toBe('overview')
    expect(panelKind('overview-settings:1')).toBe('overview-settings')
    expect(panelKind('overview-settings:99')).toBe('overview-settings')
    expect(panelKind('selected-item')).toBe('selected-item')
    expect(panelKind('watchlist')).toBe('watchlist')
    expect(DEFAULT_SIZES.watchlist).toEqual({ h: 280, w: 320 })
    expect(panelKind('settings')).toBe('settings')
    expect(panelKind(CHAT)).toBe('chat')
    expect(panelKind(CHAT.toUpperCase().replace('CHAT', 'chat'))).toBe('chat')
    for (const bad of [
      'overview:0',
      'overview:100',
      'overview:x',
      'chat:abc',
      'foo',
      'overview:01',
      'overview-settings:0',
      'overview-settings:100',
      'overview-settings',
    ]) {
      expect(panelKind(bad)).toBeNull()
    }
  })

  it('panelKind accepts show-info with a session ID and refuses show-info:x', () => {
    const id = '0f8fad5b-d9cb-469f-a165-70867728950e'
    expect(panelKind(`show-info:${id}`)).toBe('show-info')
    expect(panelKind(`show-info:${id.toUpperCase()}`)).toBe('show-info')
    for (const bad of [
      'show-info:x',
      'show-info:',
      'show-info',
      `show-info:${id}0`,
      `info:${id}`,
    ]) {
      expect(panelKind(bad)).toBeNull()
    }
    expect(DEFAULT_SIZES['show-info']).toEqual({ h: 560, w: 460 })
  })

  it('the Overview Settings panel of overview:<n> is overview-settings:<n> with 360 by 420', () => {
    expect(overviewSettingsId('overview:1')).toBe('overview-settings:1')
    expect(overviewSettingsId('overview:12')).toBe('overview-settings:12')
    expect(settingsOverviewId('overview-settings:12')).toBe('overview:12')
    expect(DEFAULT_SIZES['overview-settings']).toEqual({ h: 420, w: 360 })
    const s = run([open('overview-settings:2')])
    expect(s.frames[0]?.rect).toEqual(centreRect({ h: 420, w: 360 }, bounds))
  })

  it('open adds a centred frame with the default size', () => {
    const s = run([open('settings')])
    expect(s.frames).toHaveLength(1)
    // A frame has no opacity field (spec 8.1).
    expect(s.frames[0]).toEqual({
      active: 'settings',
      id: 'f1',
      locked: false,
      minimised: false,
      panels: ['settings'],
      rect: centreRect(DEFAULT_SIZES.settings, bounds),
    })
    expect(s.nextFrame).toBe(2)
  })

  // M5a removes the M1 debug panel (D15). The Settings panel has the Live details section now.
  it('panelKind refuses integration', () => {
    expect(panelKind('integration')).toBeNull()
    expect('integration' in DEFAULT_SIZES).toBe(false)
    // open ignores a panel ID that is not valid.
    expect(run([open('integration')]).frames).toEqual([])
  })

  it('panelKind accepts settings', () => {
    expect(panelKind('settings')).toBe('settings')
    expect(panelKind('settings:2')).toBeNull()
  })

  it('open settings uses the default size 640 x 540', () => {
    expect(DEFAULT_SIZES.settings).toEqual({ h: 540, w: 640 })
    const s = run([open('settings')])
    expect(s.frames[0]?.rect).toEqual(centreRect({ h: 540, w: 640 }, bounds))
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

  it('open moves a new panel without memory 24 pixels from a frame with the same rect', () => {
    const centre = centreRect(DEFAULT_SIZES.overview, bounds)
    const s = run([open('overview:1'), open('overview:2'), open('overview:3')])
    expect(s.frames.map(f => f.rect)).toEqual([
      centre,
      { ...centre, x: centre.x + 24, y: centre.y + 24 },
      { ...centre, x: centre.x + 48, y: centre.y + 48 },
    ])
    // A minimised frame is not on the screen, so it does not count.
    const min = run([open('overview:1'), { frameId: 'f1', type: 'minimise' }, open('overview:2')])
    expect(min.frames[1]?.rect).toEqual(centre)
    // A saved position from memory does not move.
    const saved = { ...initialState(bounds), memory: { 'overview:2': centre } }
    expect(run([open('overview:1'), open('overview:2')], saved).frames[1]?.rect).toEqual(centre)
  })

  it('open stops the 24 pixel step at the edge of the area', () => {
    const area = { h: 380, w: 780 }
    const s = run([open('overview:1'), open('overview:2'), open('overview:3')], initialState(area))
    expect(s.frames.map(f => f.rect)).toEqual([
      { h: 360, w: 760, x: 10, y: 10 },
      { h: 360, w: 760, x: 20, y: 20 },
      { h: 360, w: 760, x: 20, y: 20 },
    ])
  })

  it('open ignores an invalid panel ID', () => {
    const s = initialState(bounds)
    expect(wmReducer(s, open('nope'))).toBe(s)
  })

  it('close keeps the position in memory and removes an empty frame', () => {
    const s = run([open('settings')])
    const rect = s.frames[0]?.rect
    const c = run([{ panelId: 'settings', type: 'close' }], s)
    expect(c.frames).toEqual([])
    expect(c.memory.settings).toEqual(rect)
    expect(frameOf(run([open('settings')], c), 'settings')?.rect).toEqual(rect)
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
    const s = run([open('overview:1'), open('settings'), { frameId: 'f2', type: 'minimise' }])
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

  it('stack keeps the rect of each source panel in memory', () => {
    let s = run([open('overview:1'), open('settings')])
    const own = { h: 356, w: 420, x: 700, y: 40 }
    s = run([{ frameId: 'f2', rect: own, type: 'setRect' }], s)
    s = run([{ frameId: 'f2', targetId: 'f1', type: 'stack' }], s)
    expect(s.memory.settings).toEqual(own)
    expect(s.memory['overview:1']).toBeUndefined()
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

  it('unstack makes a new frame on top', () => {
    let s = run([
      open('overview:1'),
      open('overview:2'),
      { frameId: 'f2', targetId: 'f1', type: 'stack' },
    ])
    const old = s.frames[0]?.rect
    s = run([{ panelId: 'overview:2', rect: { h: 300, w: 400, x: 50, y: 60 }, type: 'unstack' }], s)
    expect(s.frames.map(f => f.id)).toEqual(['f1', 'f3'])
    expect(s.frames[0]).toMatchObject({ active: 'overview:1', panels: ['overview:1'] })
    expect(s.frames[1]).toMatchObject({
      locked: false,
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

  it('bounds keeps the saved rects and shows each frame inside a smaller window', () => {
    const before = run([open('overview:1'), open('settings')])
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
    let s = run([open('overview:1'), open('settings')])
    s = run([{ frameId: 'f2', rect: { h: 300, w: 400, x: 700, y: 400 }, type: 'setRect' }], s)
    const shown = shownFrames(run([{ bounds: { h: 600, w: 1000 }, type: 'bounds' }], s))
    expect(shown[0]).toBe(s.frames[0])
    expect(shown[1]?.rect).toEqual({ h: 300, w: 400, x: 600, y: 300 })
  })

  it('load replaces the frames, drops invalid and repeated panels, and keeps the rects', () => {
    const base = run([open('settings')])
    const r = { h: 300, w: 400, x: 5000, y: 5000 }
    const mk = (panels: string[], active: string) => ({
      active,
      locked: false,
      minimised: false,
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
      { panelId: 'settings', type: 'close' },
      { frameId: 'zz', type: 'focus' },
      { frameId: 'f2', type: 'focus' },
      { frameId: 'f2', rect: f2?.rect as never, type: 'setRect' },
      { frameId: 'f2', targetId: 'zz', type: 'stack' },
      { panelId: 'zz', rect: f2?.rect as never, type: 'unstack' },
      { panelId: 'overview:2', type: 'activate' },
      { frameId: 'f2', type: 'restore' },
      { frameId: 'f2', locked: false, type: 'lock' },
      { bounds, type: 'bounds' },
    ]
    for (const a of actions) expect(wmReducer(s, a)).toBe(s)
    const empty = initialState(bounds)
    expect(wmReducer(empty, { type: 'closeActive' })).toBe(empty)
    const min = run([{ frameId: 'f1', type: 'minimise' }], s)
    expect(wmReducer(min, { frameId: 'f1', type: 'minimise' })).toBe(min)
  })

  it('close of a stack tab then open puts the panel at the stack rect', () => {
    let s = run([open('overview:1'), open('settings')])
    s = run([{ frameId: 'f2', targetId: 'f1', type: 'stack' }], s)
    const moved = { h: 300, w: 400, x: 120, y: 90 }
    s = run([{ frameId: 'f1', rect: moved, type: 'setRect' }], s)
    const rectAtClose = s.frames[0]?.rect
    s = run([{ panelId: 'settings', type: 'close' }], s)
    expect(s.frames).toHaveLength(1)
    s = run([open('settings')], s)
    expect(frameOf(s, 'settings')?.rect).toEqual(rectAtClose)
    expect(frameOf(s, 'settings')?.rect).toEqual(moved)
  })

  it('the reducer does not mutate its input', () => {
    const deepFreeze = <T>(value: T): T => {
      if (typeof value === 'object' && value !== null) {
        for (const v of Object.values(value)) deepFreeze(v)
        Object.freeze(value)
      }
      return value
    }
    const base = run([open('overview:1'), open('settings'), open('selected-item')])
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
      { panelId: 'settings', type: 'close' },
      { type: 'closeActive' },
      { frameId: f[0]?.id ?? '', type: 'focus' },
      { frameId: f[0]?.id ?? '', rect: r, type: 'setRect' },
      { frameId: f[1]?.id ?? '', targetId: f[0]?.id ?? '', type: 'stack' },
      { panelId: 'settings', rect: r, type: 'unstack' },
      { panelId: 'settings', type: 'activate' },
      { frameId: f[0]?.id ?? '', type: 'minimise' },
      { frameId: f[0]?.id ?? '', type: 'restore' },
      { frameId: f[0]?.id ?? '', locked: true, type: 'lock' },
      { bounds: { h: 400, w: 500 }, type: 'bounds' },
      { frames: [], memory: {}, type: 'load' },
    ]
    for (const a of actions) expect(() => wmReducer(second, a)).not.toThrow()
  })

  it('bounds with a width or height under 1 changes nothing', () => {
    const s = run([open('settings')])
    for (const b of [
      { h: 800, w: 0 },
      { h: 0, w: 1200 },
      { h: -5, w: -5 },
      { h: 0.5, w: 900 },
    ]) {
      expect(wmReducer(s, { bounds: b, type: 'bounds' })).toBe(s)
    }
  })

  describe('replace', () => {
    const OLD = 'chat:11111111-1111-4111-8111-111111111111'
    const NEW = 'chat:22222222-2222-4222-8222-222222222222'
    const replace = (panelId: string, withId: string): WmAction => ({
      panelId,
      type: 'replace',
      withId,
    })

    it('puts the new panel in the frame of the old panel and keeps the frame', () => {
      const before = run([open(OLD)])
      const after = run([replace(OLD, NEW)], before)
      expect(after.frames).toHaveLength(1)
      expect(after.frames[0]).toEqual({ ...before.frames[0], active: NEW, panels: [NEW] })
      expect(frameOf(after, OLD)).toBeUndefined()
    })

    it('keeps the tab place and the active tab of a stack', () => {
      const s = run([open('watchlist'), open(OLD), open('reviews')])
      const id = (panelId: string) => frameOf(s, panelId)?.id ?? ''
      const stacked = run(
        [
          { frameId: id(OLD), targetId: id('watchlist'), type: 'stack' },
          { frameId: id('reviews'), targetId: id('watchlist'), type: 'stack' },
          { panelId: OLD, type: 'activate' },
        ],
        s,
      )
      const before = frameOf(stacked, OLD)
      expect(before?.panels).toHaveLength(3)
      const after = frameOf(run([replace(OLD, NEW)], stacked), NEW)
      expect(after?.panels).toEqual(before?.panels.map(p => (p === OLD ? NEW : p)))
      expect(after?.active).toBe(NEW)
      expect(after?.id).toBe(before?.id)
    })

    it('keeps another active tab of the stack', () => {
      const s = run([open('watchlist'), open(OLD)])
      const stacked = run(
        [{ frameId: s.frames[1]?.id ?? '', targetId: s.frames[0]?.id ?? '', type: 'stack' }],
        s,
      )
      const after = run([{ panelId: 'watchlist', type: 'activate' }, replace(OLD, NEW)], stacked)
      expect(frameOf(after, NEW)?.active).toBe('watchlist')
      expect(frameOf(after, NEW)?.panels).toEqual(['watchlist', NEW])
    })

    it('closes only the old panel when the new panel already has a frame', () => {
      const s = run([open(OLD), open(NEW)])
      const after = run([replace(OLD, NEW)], s)
      expect(after.frames.map(f => f.panels)).toEqual([[NEW]])
      expect(after.frames[0]?.id).toBe(s.frames[1]?.id)
    })

    it('gives the same state for an unknown old panel', () => {
      const s = run([open(NEW)])
      expect(wmReducer(s, replace(OLD, NEW))).toBe(s)
    })

    it('gives the same state for a new panel that panelKind refuses', () => {
      const s = run([open(OLD)])
      expect(wmReducer(s, replace(OLD, 'nonsense'))).toBe(s)
    })
  })
})
