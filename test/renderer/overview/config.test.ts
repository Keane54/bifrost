import { describe, expect, it } from 'vitest'
import { COLUMN_IDS } from '../../../src/renderer/src/overview/columns'
import {
  activeTab,
  configOf,
  DEFAULT_CONFIG,
  defaultOverviewConfig,
  type OverviewConfig,
  overviewReducer,
  overviewsReducer,
  parseOverviewConfig,
  parseOverviews,
} from '../../../src/renderer/src/overview/config'

const base = (): OverviewConfig => defaultOverviewConfig()
const tabIds = (c: OverviewConfig) => c.tabs.map(t => t.id)

describe('overview config', () => {
  it('defaultOverviewConfig has the 5 tabs of spec 8.3 with all columns and Name ascending', () => {
    const c = defaultOverviewConfig()
    expect(c.name).toBe('Default')
    expect(c.active).toBe('t1')
    expect(c.nextTab).toBe(6)
    expect(c.tabs.map(t => [t.id, t.name, t.color, t.filter.boxOnly])).toEqual([
      ['t1', 'All', 0, false],
      ['t2', 'Needs you', 1, true],
      ['t3', 'Working', 2, false],
      ['t4', 'Idle', 3, false],
      ['t5', 'Parked', 4, false],
    ])
    expect(c.tabs[2]?.filter.states).toEqual(['working'])
    for (const t of c.tabs) {
      expect(t.columns).toEqual([...COLUMN_IDS])
      expect(t.widths).toEqual({})
      expect(t.sort).toEqual({ column: 'name', desc: false })
    }
    expect(Object.isFrozen(DEFAULT_CONFIG)).toBe(true)
    expect(activeTab(c).id).toBe('t1')
  })

  it('parseOverviewConfig of the default config gives the same config', () => {
    const c = defaultOverviewConfig()
    expect(parseOverviewConfig(JSON.parse(JSON.stringify(c)))).toEqual(c)
  })

  it('parseOverviewConfig gives null for bad data and for zero valid tabs', () => {
    for (const bad of [null, [], { tabs: [] }, { tabs: [{}] }, 'x']) {
      expect(parseOverviewConfig(bad)).toBeNull()
    }
  })

  it('parseOverviewConfig drops a repeated tab ID, a bad name and unknown columns, and keeps kind first', () => {
    const c = parseOverviewConfig({
      tabs: [
        { columns: ['name', 'kind', 'foo', 'name'], id: 't1', name: ' A ' },
        { id: 't1', name: 'Again' },
        { id: 't2', name: '' },
        { id: 't3', name: 'x'.repeat(25) },
        { id: 'x4', name: 'Bad ID' },
        { id: 't7', name: 'Seven' },
      ],
    })
    expect(c?.tabs.map(t => [t.id, t.name])).toEqual([
      ['t1', 'A'],
      ['t7', 'Seven'],
    ])
    expect(c?.tabs[0]?.columns).toEqual(['kind', 'name'])
    expect(c?.name).toBe('Default')
    expect(c?.nextTab).toBe(8)
    expect(c?.tabs[1]?.color).toBe(1)
  })

  it('parseOverviewConfig clamps widths and fixes a bad sort and a bad active tab', () => {
    const c = parseOverviewConfig({
      active: 't99',
      tabs: [
        {
          id: 't1',
          name: 'A',
          sort: { column: 'foo', desc: true },
          widths: { cost: 33.6, foo: 5, name: 9999, state: 5 },
        },
      ],
    })
    expect(c?.tabs[0]?.widths).toEqual({ cost: 34, name: 600, state: 24 })
    expect(c?.tabs[0]?.sort).toEqual({ column: 'name', desc: false })
    expect(c?.active).toBe('t1')
  })

  it('parseOverviewConfig keeps the first 12 tabs', () => {
    const tabs = Array.from({ length: 15 }, (_, i) => ({ id: `t${i + 1}`, name: `T${i + 1}` }))
    const c = parseOverviewConfig({ tabs })
    expect(c?.tabs).toHaveLength(12)
    expect(c?.nextTab).toBe(13)
  })

  it('addTab appends Tab 6 with colour 5, activates it, and refuses a 13th tab', () => {
    let c = overviewReducer(base(), { type: 'addTab' })
    const added = c.tabs[5]
    expect(added).toMatchObject({ color: 5, id: 't6', name: 'Tab 6' })
    expect(added?.filter).toEqual(base().tabs[0]?.filter)
    expect(c.active).toBe('t6')
    expect(c.nextTab).toBe(7)
    for (let i = 0; i < 6; i++) c = overviewReducer(c, { type: 'addTab' })
    expect(c.tabs).toHaveLength(12)
    expect(overviewReducer(c, { type: 'addTab' })).toBe(c)
  })

  it('removeTab activates the tab to the left and refuses the last tab', () => {
    let c = overviewReducer(base(), { tabId: 't3', type: 'activate' })
    c = overviewReducer(c, { tabId: 't3', type: 'removeTab' })
    expect(tabIds(c)).toEqual(['t1', 't2', 't4', 't5'])
    expect(c.active).toBe('t2')
    c = overviewReducer(c, { tabId: 't1', type: 'activate' })
    c = overviewReducer(c, { tabId: 't1', type: 'removeTab' })
    expect(c.active).toBe('t2')
    const one = parseOverviewConfig({ tabs: [{ id: 't1', name: 'A' }] }) as OverviewConfig
    expect(overviewReducer(one, { tabId: 't1', type: 'removeTab' })).toBe(one)
  })

  it('renameTab trims and refuses an empty name and a 25-character name', () => {
    const c = base()
    const r = overviewReducer(c, { name: '  Mine ', tabId: 't2', type: 'renameTab' })
    expect(r.tabs[1]?.name).toBe('Mine')
    expect(overviewReducer(c, { name: '  ', tabId: 't2', type: 'renameTab' })).toBe(c)
    expect(overviewReducer(c, { name: 'x'.repeat(25), tabId: 't2', type: 'renameTab' })).toBe(c)
  })

  it('moveTab swaps with the neighbour and does nothing at the edge', () => {
    const c = base()
    expect(tabIds(overviewReducer(c, { by: 1, tabId: 't1', type: 'moveTab' }))).toEqual([
      't2',
      't1',
      't3',
      't4',
      't5',
    ])
    expect(overviewReducer(c, { by: -1, tabId: 't1', type: 'moveTab' })).toBe(c)
    expect(overviewReducer(c, { by: 1, tabId: 't5', type: 'moveTab' })).toBe(c)
  })

  it('toggleColumn adds at the end, removes, and never removes kind', () => {
    const c = base()
    const off = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    expect(off.tabs[0]?.columns).not.toContain('cost')
    const on = overviewReducer(off, { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    expect(on.tabs[0]?.columns.at(-1)).toBe('cost')
    expect(overviewReducer(c, { column: 'kind', tabId: 't1', type: 'toggleColumn' })).toBe(c)
  })

  it('moveColumn moves before a column, to the end for null, and never before kind', () => {
    const c = base()
    const cols = (x: OverviewConfig) => x.tabs[0]?.columns.join(',')
    const a = overviewReducer(c, {
      before: 'name',
      column: 'cost',
      tabId: 't1',
      type: 'moveColumn',
    })
    expect(cols(a)).toBe('kind,cost,name,priority,state,project,branch,model,context,activity')
    const b = overviewReducer(c, { before: null, column: 'name', tabId: 't1', type: 'moveColumn' })
    expect(cols(b)).toBe('kind,priority,state,project,branch,model,context,cost,activity,name')
    const d = overviewReducer(c, {
      before: 'kind',
      column: 'cost',
      tabId: 't1',
      type: 'moveColumn',
    })
    expect(cols(d)).toBe('kind,cost,name,priority,state,project,branch,model,context,activity')
    expect(
      overviewReducer(c, { before: 'name', column: 'kind', tabId: 't1', type: 'moveColumn' }),
    ).toBe(c)
    expect(
      overviewReducer(c, { before: 'name', column: 'name', tabId: 't1', type: 'moveColumn' }),
    ).toBe(c)
  })

  it('sortBy flips the direction of the same column and starts Cost descending', () => {
    const c = base()
    const flip = overviewReducer(c, { column: 'name', tabId: 't1', type: 'sortBy' })
    expect(flip.tabs[0]?.sort).toEqual({ column: 'name', desc: true })
    const cost = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'sortBy' })
    expect(cost.tabs[0]?.sort).toEqual({ column: 'cost', desc: true })
    const state = overviewReducer(c, { column: 'state', tabId: 't1', type: 'sortBy' })
    expect(state.tabs[0]?.sort).toEqual({ column: 'state', desc: false })
  })

  it('setFilter and setWidths change only the named tab', () => {
    const c = base()
    const f = overviewReducer(c, {
      filter: { boxOnly: true, states: ['idle'] },
      tabId: 't4',
      type: 'setFilter',
    })
    expect(f.tabs[3]?.filter).toEqual({ boxOnly: true, states: ['idle'] })
    expect(f.tabs[0]).toBe(c.tabs[0])
    const w = overviewReducer(f, {
      tabId: 't2',
      type: 'setWidths',
      widths: { cost: 1, name: 700.4 },
    })
    expect(w.tabs[1]?.widths).toEqual({ cost: 24, name: 600 })
    expect(w.tabs[3]).toBe(f.tabs[3])
  })

  it('an unknown tab ID or a no-change action returns the same object', () => {
    const c = base()
    expect(overviewReducer(c, { tabId: 'nope', type: 'activate' })).toBe(c)
    expect(overviewReducer(c, { tabId: 't1', type: 'activate' })).toBe(c)
    expect(overviewReducer(c, { column: 'cost', tabId: 'nope', type: 'sortBy' })).toBe(c)
    expect(overviewReducer(c, { tabId: 'nope', type: 'removeTab' })).toBe(c)
    expect(overviewReducer(c, { name: 'Default', type: 'rename' })).toBe(c)
    expect(overviewReducer(c, { name: '', type: 'rename' })).toBe(c)
    expect(overviewReducer(c, { name: ' Work ', type: 'rename' }).name).toBe('Work')
  })

  it('overviewsReducer keeps the config of each panel apart and starts from the default', () => {
    expect(configOf({}, 'overview:1')).toBe(DEFAULT_CONFIG)
    let s = overviewsReducer(
      {},
      { action: { type: 'addTab' }, panelId: 'overview:1', type: 'update' },
    )
    expect(configOf(s, 'overview:1').tabs).toHaveLength(6)
    expect(configOf(s, 'overview:2').tabs).toHaveLength(5)
    s = overviewsReducer(s, { overviews: { 'overview:3': base() }, type: 'load' })
    expect(Object.keys(s)).toEqual(['overview:3'])
    expect(
      parseOverviews({
        'chat:x': base(),
        'overview:0': base(),
        'overview:2': base(),
        'overview:4': 5,
      }),
    ).toEqual({
      'overview:2': base(),
    })
  })

  it('parseOverviewConfig bounds nextTab and never repeats a tab ID', () => {
    const tabs = [{ id: 't1', name: 'A' }]
    for (const nextTab of [1e21, 2 ** 53, -1, 1.5, '9', 0, 10000]) {
      expect(parseOverviewConfig({ nextTab, tabs })?.nextTab).toBe(2)
    }
    expect(parseOverviewConfig({ nextTab: 40, tabs })?.nextTab).toBe(40)
    expect(parseOverviewConfig({ tabs: [{ id: 't12345', name: 'A' }] })).toBeNull()
    const full = parseOverviewConfig({ nextTab: 9999, tabs }) as OverviewConfig
    const last = overviewReducer(full, { type: 'addTab' })
    expect(last.tabs.map(t => t.id)).toEqual(['t1', 't9999'])
    expect(overviewReducer(last, { type: 'addTab' })).toBe(last)
    const clash = { ...base(), nextTab: 3 }
    expect(overviewReducer(clash, { type: 'addTab' })).toBe(clash)
  })

  it('parseOverviewConfig gives all columns for a tab with a damaged column list', () => {
    const c = parseOverviewConfig({
      tabs: [
        { id: 't1', name: 'A' },
        { columns: 'name', id: 't2', name: 'B' },
      ],
    })
    expect(c?.tabs.map(t => t.columns)).toEqual([[...COLUMN_IDS], [...COLUMN_IDS]])
  })

  it('setFilter with the same filter returns the same object', () => {
    const c = base()
    const same = { boxOnly: true, states: [...(c.tabs[1]?.filter.states ?? [])] }
    expect(overviewReducer(c, { filter: same, tabId: 't2', type: 'setFilter' })).toBe(c)
  })
})
