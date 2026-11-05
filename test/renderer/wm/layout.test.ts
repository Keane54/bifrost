import { describe, expect, it } from 'vitest'
import {
  deleteLayout,
  EMPTY_STORE,
  type LayoutSnapshot,
  MAX_LAYOUTS,
  MAX_NAME,
  parseUiStore,
  saveLayout,
  toSnapshot,
  type UiStore,
} from '../../../src/renderer/src/wm/layout'
import { initialState, wmReducer } from '../../../src/renderer/src/wm/state'

const rect = { h: 200, w: 300, x: 10, y: 20 }
const frame = {
  active: 'integration',
  locked: false,
  minimised: false,
  opacity: 1,
  panels: ['integration'],
  rect,
}
const snap = (n = 1): LayoutSnapshot => ({
  frames: Array.from({ length: n }, () => ({ ...frame })),
  memory: {},
})
const store = (layouts: UiStore['layouts'] = []): UiStore => ({
  current: null,
  layouts,
  overviews: {},
  version: 1,
})

describe('layout', () => {
  it('toSnapshot keeps the frames in z-order without IDs and keeps the memory', () => {
    let state = initialState({ h: 800, w: 1200 })
    state = wmReducer(state, { panelId: 'integration', type: 'open' })
    state = wmReducer(state, { panelId: 'selected-item', type: 'open' })
    state = wmReducer(state, { panelId: 'integration', type: 'close' })
    state = wmReducer(state, { panelId: 'overview:1', type: 'open' })
    const snapshot = toSnapshot(state)
    expect(snapshot.frames.map(f => f.panels)).toEqual([['selected-item'], ['overview:1']])
    expect(snapshot.frames.every(f => !('id' in f))).toBe(true)
    expect(Object.keys(snapshot.memory)).toEqual(['integration'])
  })

  it('parseUiStore gives the empty store for bad data', () => {
    for (const bad of [null, [], 'x', { version: 2 }, undefined, 7]) {
      expect(parseUiStore(bad)).toEqual(EMPTY_STORE)
    }
  })

  it('parseUiStore drops bad rects, invalid panel IDs and empty frames', () => {
    const parsed = parseUiStore({
      current: {
        frames: [
          { ...frame, panels: ['integration', 'nope', 7] },
          { ...frame, rect: { ...rect, w: 0 } },
          { ...frame, rect: { ...rect, x: Number.NaN } },
          { ...frame, rect: { ...rect, x: '1' } },
          { ...frame, panels: ['nope'] },
          { ...frame, panels: [] },
          { ...frame, panels: 'integration' },
          null,
        ],
        memory: { integration: rect, nope: rect, 'overview:1': { ...rect, h: -1 } },
      },
      layouts: [{ name: 'a', snapshot: 'bad' }],
      version: 1,
    })
    expect(parsed.current?.frames).toHaveLength(1)
    expect(parsed.current?.frames[0]?.panels).toEqual(['integration'])
    expect(parsed.current?.memory).toEqual({ integration: rect })
    expect(parsed.layouts).toEqual([])
  })

  it('parseUiStore clamps opacity and fills the defaults', () => {
    const parsed = parseUiStore({
      current: {
        frames: [
          { panels: ['integration'], rect },
          { opacity: 0.1, panels: ['selected-item'], rect },
          { active: 'zzz', minimised: 'yes', opacity: 5, panels: ['overview:1'], rect },
        ],
        memory: {},
      },
      version: 1,
    })
    const [a, b, c] = parsed.current?.frames ?? []
    expect(a).toEqual(frame)
    expect(b?.opacity).toBe(0.3)
    expect(c).toMatchObject({ active: 'overview:1', locked: false, minimised: false, opacity: 1 })
  })

  it('parseUiStore keeps the first of two layouts with the same name and at most 20 layouts', () => {
    const first = snap(1)
    const same = parseUiStore({
      layouts: [
        { name: ' a ', snapshot: first },
        { name: 'a', snapshot: snap(2) },
        { name: '', snapshot: first },
        { name: 'x'.repeat(MAX_NAME + 1), snapshot: first },
      ],
      version: 1,
    })
    expect(same.layouts).toEqual([{ name: 'a', snapshot: first }])
    const many = parseUiStore({
      layouts: Array.from({ length: 30 }, (_, i) => ({ name: `n${i}`, snapshot: first })),
      version: 1,
    })
    expect(many.layouts).toHaveLength(MAX_LAYOUTS)
    expect(many.layouts[0]?.name).toBe('n0')
  })

  it('parseUiStore of toSnapshot output gives the same snapshot', () => {
    let state = initialState({ h: 800, w: 1200 })
    state = wmReducer(state, { panelId: 'integration', type: 'open' })
    state = wmReducer(state, { panelId: 'overview:2', type: 'open' })
    state = wmReducer(state, { frameId: 'f2', opacity: 0.5, type: 'opacity' })
    state = wmReducer(state, { panelId: 'integration', type: 'close' })
    const snapshot = toSnapshot(state)
    const parsed = parseUiStore({ current: snapshot, layouts: [], version: 1 })
    expect(parsed.current).toEqual(snapshot)
  })

  it('saveLayout appends, replaces in place, and refuses bad names and a full store', () => {
    let s = saveLayout(store(), ' one ', snap(1))
    s = saveLayout(s, 'two', snap(1))
    expect(s.layouts.map(l => l.name)).toEqual(['one', 'two'])
    const replaced = saveLayout(s, 'one', snap(2))
    expect(replaced.layouts.map(l => l.name)).toEqual(['one', 'two'])
    expect(replaced.layouts[0]?.snapshot.frames).toHaveLength(2)
    expect(saveLayout(s, '   ', snap())).toBe(s)
    expect(saveLayout(s, 'x'.repeat(MAX_NAME + 1), snap())).toBe(s)
    expect(saveLayout(s, 'x'.repeat(MAX_NAME), snap()).layouts).toHaveLength(3)
    const full = store(
      Array.from({ length: MAX_LAYOUTS }, (_, i) => ({ name: `n${i}`, snapshot: snap() })),
    )
    expect(saveLayout(full, 'new', snap())).toBe(full)
    expect(saveLayout(full, 'n3', snap(2)).layouts[3]?.snapshot.frames).toHaveLength(2)
  })

  it('deleteLayout removes only that name', () => {
    const s = store([
      { name: 'a', snapshot: snap() },
      { name: 'b', snapshot: snap() },
    ])
    expect(deleteLayout(s, 'a').layouts.map(l => l.name)).toEqual(['b'])
    expect(deleteLayout(s, 'zzz').layouts).toHaveLength(2)
  })

  it('parseUiStore reads an M2 store without overviews and keeps its layouts', () => {
    const parsed = parseUiStore({
      current: null,
      layouts: [{ name: 'A', snapshot: snap() }],
      version: 1,
    })
    expect(parsed.overviews).toEqual({})
    expect(parsed.layouts.map(l => l.name)).toEqual(['A'])
  })

  it('parseUiStore drops overviews with a bad panel ID or a bad config', () => {
    const good = { tabs: [{ id: 't1', name: 'All' }] }
    const parsed = parseUiStore({
      current: null,
      layouts: [],
      overviews: { 'chat:x': good, 'overview:0': good, 'overview:2': good, 'overview:3': {} },
      version: 1,
    })
    expect(Object.keys(parsed.overviews)).toEqual(['overview:2'])
  })
})
