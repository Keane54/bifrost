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
  TAB_COLOURS,
} from '../../../src/renderer/src/overview/config'

const base = (): OverviewConfig => defaultOverviewConfig()
const tabIds = (c: OverviewConfig) => c.tabs.map(t => t.id)

describe('overview config', () => {
  it('renames a saved tab t2 named Needs you to Alerts and keeps every other name', () => {
    const tabs = (t2: string, t7: string) => [
      { id: 't1', name: 'All' },
      { id: 't2', name: t2 },
      { id: 't7', name: t7 },
    ]
    const names = (data: unknown) =>
      (parseOverviewConfig(data) as OverviewConfig).tabs.map(t => t.name)
    expect(names({ nextTab: 8, tabs: tabs('Needs you', 'Needs you') })).toEqual([
      'All',
      'Alerts',
      'Needs you',
    ])
    expect(names({ nextTab: 8, tabs: tabs('My alerts', 'x') })).toEqual(['All', 'My alerts', 'x'])
    expect(names({ nextTab: 8, tabs: tabs('needs you', 'x') })).toEqual(['All', 'needs you', 'x'])
  })

  it('defaultOverviewConfig has the 6 tabs of spec 8.3 and the Watched tab with the default columns and Name ascending', () => {
    const c = defaultOverviewConfig()
    expect(c.name).toBe('Default')
    expect(c.active).toBe('t1')
    expect(c.nextTab).toBe(6)
    expect(c.tabs.map(t => [t.id, t.name, t.color, t.filter.boxOnly])).toEqual([
      ['t1', 'All', 0, false],
      ['t2', 'Alerts', 1, true],
      ['t0', 'Watched', 5, false],
      ['t3', 'Working', 2, false],
      ['t4', 'Idle', 3, false],
      ['t5', 'Parked', 4, false],
    ])
    expect(c.tabs.map(t => t.filter.watchedOnly)).toEqual([false, false, true, false, false, false])
    expect(c.tabs[3]?.filter.states).toEqual(['working'])
    for (const t of c.tabs) {
      expect(t.columns).toEqual(['kind', 'name', 'state', 'project', 'activity'])
      expect(t.order).toEqual([...COLUMN_IDS])
      expect(t.filter.kinds).toEqual(['owned', 'external'])
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
    const added = c.tabs[6]
    expect(added).toMatchObject({ color: 5, id: 't6', name: 'Tab 6' })
    expect(added?.filter).toEqual(base().tabs[0]?.filter)
    expect(c.active).toBe('t6')
    expect(c.nextTab).toBe(7)
    for (let i = 0; i < 5; i++) c = overviewReducer(c, { type: 'addTab' })
    expect(c.tabs).toHaveLength(12)
    expect(overviewReducer(c, { type: 'addTab' })).toBe(c)
  })

  it('removeTab activates the tab to the left and refuses the last tab', () => {
    let c = overviewReducer(base(), { tabId: 't3', type: 'activate' })
    c = overviewReducer(c, { tabId: 't3', type: 'removeTab' })
    expect(tabIds(c)).toEqual(['t1', 't2', 't0', 't4', 't5'])
    expect(c.active).toBe('t0')
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
      't0',
      't3',
      't4',
      't5',
    ])
    expect(overviewReducer(c, { by: -1, tabId: 't1', type: 'moveTab' })).toBe(c)
    expect(overviewReducer(c, { by: 1, tabId: 't5', type: 'moveTab' })).toBe(c)
  })

  it('toggleColumn adds a column at its place in the order, removes it, and never removes kind', () => {
    const c = base()
    const on = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    expect(on.tabs[0]?.columns).toEqual(['kind', 'name', 'state', 'project', 'cost', 'activity'])
    const off = overviewReducer(on, { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    expect(off.tabs[0]?.columns).toEqual(c.tabs[0]?.columns)
    expect(off.tabs[0]?.order).toEqual(c.tabs[0]?.order)
    expect(overviewReducer(c, { column: 'kind', tabId: 't1', type: 'toggleColumn' })).toBe(c)
  })

  it('moveColumn moves before a column, to the end for null, and never before kind', () => {
    const c = base()
    const cols = (x: OverviewConfig) => x.tabs[0]?.columns.join(',')
    const order = (x: OverviewConfig) => x.tabs[0]?.order.join(',')
    const a = overviewReducer(c, {
      before: 'name',
      column: 'activity',
      tabId: 't1',
      type: 'moveColumn',
    })
    expect(cols(a)).toBe('kind,activity,name,state,project')
    expect(order(a)).toBe('kind,activity,name,priority,state,project,branch,model,context,cost')
    const b = overviewReducer(c, { before: null, column: 'name', tabId: 't1', type: 'moveColumn' })
    expect(cols(b)).toBe('kind,state,project,activity,name')
    const d = overviewReducer(c, {
      before: 'kind',
      column: 'project',
      tabId: 't1',
      type: 'moveColumn',
    })
    expect(cols(d)).toBe('kind,project,name,state,activity')
    // A hidden column moves in the order only.
    const e = overviewReducer(c, {
      before: 'name',
      column: 'cost',
      tabId: 't1',
      type: 'moveColumn',
    })
    expect(cols(e)).toBe(cols(c))
    expect(order(e)).toBe('kind,cost,name,priority,state,project,branch,model,context,activity')
    expect(
      overviewReducer(c, { before: 'name', column: 'kind', tabId: 't1', type: 'moveColumn' }),
    ).toBe(c)
    expect(
      overviewReducer(c, { before: 'name', column: 'name', tabId: 't1', type: 'moveColumn' }),
    ).toBe(c)
  })

  it('sortBy flips the direction of the same column and starts Cost descending', () => {
    const c = overviewReducer(base(), { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    const flip = overviewReducer(c, { column: 'name', tabId: 't1', type: 'sortBy' })
    expect(flip.tabs[0]?.sort).toEqual({ column: 'name', desc: true })
    const cost = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'sortBy' })
    expect(cost.tabs[0]?.sort).toEqual({ column: 'cost', desc: true })
    const state = overviewReducer(c, { column: 'state', tabId: 't1', type: 'sortBy' })
    expect(state.tabs[0]?.sort).toEqual({ column: 'state', desc: false })
  })

  it('sortBy refuses a hidden column', () => {
    const c = base()
    expect(overviewReducer(c, { column: 'cost', tabId: 't1', type: 'sortBy' })).toBe(c)
  })

  it('a hidden column never sorts: hiding the sort column sorts by Name ascending', () => {
    let c = overviewReducer(base(), { column: 'state', tabId: 't1', type: 'sortBy' })
    c = overviewReducer(c, { column: 'state', tabId: 't1', type: 'sortBy' })
    expect(c.tabs[0]?.sort).toEqual({ column: 'state', desc: true })
    const hidden = overviewReducer(c, { column: 'state', tabId: 't1', type: 'toggleColumn' })
    expect(hidden.tabs[0]?.sort).toEqual({ column: 'name', desc: false })
    // A column that is not the sort column does not change the sort.
    const other = overviewReducer(c, { column: 'project', tabId: 't1', type: 'toggleColumn' })
    expect(other.tabs[0]?.sort).toEqual({ column: 'state', desc: true })
  })

  it('hiding Name while it is the sort column sorts by the first visible column after kind', () => {
    const c = overviewReducer(base(), { column: 'name', tabId: 't1', type: 'sortBy' })
    expect(c.tabs[0]?.sort).toEqual({ column: 'name', desc: true })
    const hidden = overviewReducer(c, { column: 'name', tabId: 't1', type: 'toggleColumn' })
    expect(hidden.tabs[0]?.columns).toEqual(['kind', 'state', 'project', 'activity'])
    expect(hidden.tabs[0]?.sort).toEqual({ column: 'state', desc: false })
  })

  it('a reset that hides the sort column sorts by Name ascending', () => {
    let c = overviewReducer(base(), { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    c = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'sortBy' })
    expect(c.tabs[0]?.sort).toEqual({ column: 'cost', desc: true })
    const reset = overviewReducer(c, { tabId: 't1', type: 'resetTab' })
    expect(reset.tabs[0]?.columns).not.toContain('cost')
    expect(reset.tabs[0]?.sort).toEqual({ column: 'name', desc: false })
  })

  it('resetTab clears the widths of a tab and of no other tab', () => {
    const c = overviewReducer(
      overviewReducer(base(), { tabId: 't1', type: 'setWidths', widths: { name: 207 } }),
      { tabId: 't2', type: 'setWidths', widths: { project: 90 } },
    )
    const reset = overviewReducer(c, { tabId: 't1', type: 'resetTab' })
    expect(reset.tabs[0]?.widths).toEqual({})
    expect(reset.tabs[1]).toBe(c.tabs[1])
  })

  it('setWidths for one column leaves the other widths unchanged', () => {
    let c = overviewReducer(base(), {
      tabId: 't1',
      type: 'setWidths',
      widths: { name: 207, project: 150 },
    })
    c = overviewReducer(c, { tabId: 't1', type: 'setWidths', widths: { name: 230 } })
    expect(c.tabs[0]?.widths).toEqual({ name: 230, project: 150 })
  })

  it('parseOverviewConfig moves the sort of a saved tab off a hidden column', () => {
    const c = parseOverviewConfig({
      tabs: [
        {
          columns: ['kind', 'name', 'state'],
          id: 't1',
          name: 'A',
          sort: { column: 'cost', desc: true },
        },
        {
          columns: ['kind', 'state', 'project'],
          id: 't2',
          name: 'B',
          sort: { column: 'name', desc: true },
        },
        { columns: ['kind'], id: 't3', name: 'C', sort: { column: 'state', desc: true } },
        { columns: ['kind', 'cost'], id: 't4', name: 'D', sort: { column: 'cost', desc: true } },
      ],
    })
    expect(c?.tabs.map(t => t.sort)).toEqual([
      { column: 'name', desc: false },
      { column: 'state', desc: false },
      { column: 'kind', desc: false },
      { column: 'cost', desc: true },
    ])
  })

  it('setFilter and setWidths change only the named tab', () => {
    const c = base()
    const f = overviewReducer(c, {
      filter: { boxOnly: true, kinds: ['owned'], states: ['idle'] },
      tabId: 't4',
      type: 'setFilter',
    })
    expect(f.tabs[4]?.filter).toEqual({ boxOnly: true, kinds: ['owned'], states: ['idle'] })
    expect(f.tabs[0]).toBe(c.tabs[0])
    const w = overviewReducer(f, {
      tabId: 't2',
      type: 'setWidths',
      widths: { cost: 1, name: 700.4 },
    })
    expect(w.tabs[1]?.widths).toEqual({ cost: 24, name: 600 })
    expect(w.tabs[4]).toBe(f.tabs[4])
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
    expect(configOf(s, 'overview:1').tabs).toHaveLength(7)
    expect(configOf(s, 'overview:2').tabs).toHaveLength(6)
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

  it('parseOverviewConfig gives the default columns for a tab with a damaged column list', () => {
    const c = parseOverviewConfig({
      tabs: [
        { id: 't1', name: 'A' },
        { columns: 'name', id: 't2', name: 'B' },
      ],
    })
    const defaults = base().tabs[0]
    expect(c?.tabs.map(t => t.columns)).toEqual([defaults?.columns, defaults?.columns])
    expect(c?.tabs.map(t => t.order)).toEqual([[...COLUMN_IDS], [...COLUMN_IDS]])
  })

  it('a saved config keeps its columns: a tab from before the column order keeps its list', () => {
    const c = parseOverviewConfig({
      tabs: [
        { columns: [...COLUMN_IDS], id: 't1', name: 'All' },
        { columns: ['kind', 'cost', 'name'], id: 't2', name: 'B' },
      ],
    }) as OverviewConfig
    expect(c.tabs[0]?.columns).toEqual([...COLUMN_IDS])
    expect(c.tabs[0]?.order).toEqual([...COLUMN_IDS])
    expect(c.tabs[1]?.columns).toEqual(['kind', 'cost', 'name'])
    expect(c.tabs[1]?.order.join(',')).toBe(
      'kind,cost,name,priority,state,project,branch,model,context,activity',
    )
  })

  it('parseOverviewConfig keeps the places of hidden columns and adds missing columns', () => {
    const c = parseOverviewConfig({
      tabs: [
        {
          columns: ['kind', 'name', 'cost'],
          id: 't1',
          name: 'A',
          order: ['cost', 'kind', 'branch', 'name', 'foo', 'name'],
        },
      ],
    })
    expect(c?.tabs[0]?.order.join(',')).toBe(
      'kind,cost,branch,name,priority,state,project,model,context,activity',
    )
    // The visible columns follow the saved order.
    expect(c?.tabs[0]?.columns).toEqual(['kind', 'cost', 'name'])
  })

  it('parseOverviewConfig reads watchedOnly and gives false for an old filter', () => {
    const tab = (filter: unknown) => ({ filter, id: 't1', name: 'A' })
    const parse = (filter: unknown) =>
      parseOverviewConfig({ tabs: [tab(filter)] })?.tabs[0]?.filter.watchedOnly
    expect(parse({ boxOnly: false, kinds: ['owned'], states: ['idle'], watchedOnly: true })).toBe(
      true,
    )
    expect(parse({ boxOnly: false, kinds: ['owned'], states: ['idle'] })).toBe(false)
    expect(parse({ watchedOnly: 'yes' })).toBe(false)
    expect(parse(undefined)).toBe(false)
  })

  it('the Watched tab has a valid tab colour and parses back unchanged', () => {
    const c = defaultOverviewConfig()
    const watched = c.tabs[2]
    expect(watched?.color).toBeGreaterThanOrEqual(0)
    expect(watched?.color).toBeLessThan(6)
    expect(parseOverviewConfig(JSON.parse(JSON.stringify(c)))?.tabs[2]).toEqual(watched)
  })

  it('a saved config keeps its own tabs: no Watched tab is added', () => {
    const saved = { name: 'Mine', tabs: [{ id: 't1', name: 'One' }] }
    expect(parseOverviewConfig(saved)?.tabs.map(t => t.name)).toEqual(['One'])
  })

  it('setFilter keeps watchedOnly', () => {
    const c = overviewReducer(base(), {
      filter: { boxOnly: false, kinds: ['owned'], states: ['idle'], watchedOnly: true },
      tabId: 't4',
      type: 'setFilter',
    })
    expect(c.tabs[4]?.filter.watchedOnly).toBe(true)
  })

  it('parseOverviewConfig gives both kinds to a filter without kinds and drops unknown kinds', () => {
    const c = parseOverviewConfig({
      tabs: [
        { filter: { states: ['idle'] }, id: 't1', name: 'A' },
        { filter: { kinds: ['external', 'x', 'external'], states: [] }, id: 't2', name: 'B' },
        { filter: { kinds: 'owned', states: [] }, id: 't3', name: 'C' },
      ],
    })
    expect(c?.tabs.map(t => t.filter.kinds)).toEqual([
      ['owned', 'external'],
      ['external'],
      ['owned', 'external'],
    ])
  })

  it('resetTab restores the default columns and filter, and returns the same object for a default tab', () => {
    const c = base()
    expect(overviewReducer(c, { tabId: 't2', type: 'resetTab' })).toBe(c)
    const changed = overviewReducer(
      overviewReducer(c, { column: 'cost', tabId: 't2', type: 'toggleColumn' }),
      { filter: { boxOnly: false, kinds: [], states: [] }, tabId: 't2', type: 'setFilter' },
    )
    expect(overviewReducer(changed, { tabId: 't2', type: 'resetTab' }).tabs[1]).toEqual(c.tabs[1])
  })

  it('overviewsReducer edit applies a change to the current config of one panel', () => {
    const s = overviewsReducer(
      {},
      {
        edit: c => overviewReducer(c, { type: 'addTab' }),
        panelId: 'overview:2',
        type: 'edit',
      },
    )
    expect(configOf(s, 'overview:2').tabs).toHaveLength(7)
    expect(configOf(s, 'overview:1')).toBe(DEFAULT_CONFIG)
    expect(overviewsReducer(s, { edit: c => c, panelId: 'overview:2', type: 'edit' })).toBe(s)
  })

  it('setFilter with the same filter returns the same object', () => {
    const c = base()
    const filter = c.tabs[1]?.filter
    const same = {
      boxOnly: true,
      kinds: [...(filter?.kinds ?? [])],
      states: [...(filter?.states ?? [])],
      watchedOnly: false,
    }
    expect(overviewReducer(c, { filter: same, tabId: 't2', type: 'setFilter' })).toBe(c)
  })

  it('parseTab keeps a saved colour and refuses 12', () => {
    const colourOf = (color: unknown, index: number): number | undefined => {
      const tabs = Array.from({ length: index }, (_, i) => ({ id: `t${i + 1}`, name: `T${i + 1}` }))
      const saved = {
        active: 't1',
        name: 'X',
        nextTab: 20,
        tabs: [...tabs, { color, id: 't19', name: 'Last' }],
      }
      return parseOverviewConfig(saved)?.tabs[index]?.color
    }
    expect(TAB_COLOURS).toBe(12)
    for (const color of [0, 5, 11]) expect(colourOf(color, 1)).toBe(color)
    for (const color of [12, -1, 1.5, '3']) expect(colourOf(color, 8)).toBe(8 % 6)
  })

  it('addTab cycles through the first six colours', () => {
    let c = base()
    c = { ...c, nextTab: 7, tabs: c.tabs.slice(0, 1) }
    c = overviewReducer(c, { type: 'addTab' })
    expect(c.tabs.at(-1)).toMatchObject({ color: 0, id: 't7' })
    c = { ...c, nextTab: 13, tabs: c.tabs.slice(0, 1) }
    c = overviewReducer(c, { type: 'addTab' })
    expect(c.tabs.at(-1)).toMatchObject({ color: 0, id: 't13' })
  })

  it('setTabColour sets the colour of one tab', () => {
    const c = base()
    const next = overviewReducer(c, { color: 11, tabId: 't2', type: 'setTabColour' })
    expect(next.tabs.map(t => t.color)).toEqual(c.tabs.map(t => (t.id === 't2' ? 11 : t.color)))
    expect(overviewReducer(next, { color: 11, tabId: 't2', type: 'setTabColour' })).toBe(next)
  })

  it('setTabColour ignores a bad colour or an unknown tab', () => {
    const c = base()
    for (const color of [12, -1, 2.5, Number.NaN]) {
      expect(overviewReducer(c, { color, tabId: 't1', type: 'setTabColour' })).toBe(c)
    }
    expect(overviewReducer(c, { color: 3, tabId: 'none', type: 'setTabColour' })).toBe(c)
  })

  it('resetTab keeps the colour', () => {
    let c = overviewReducer(base(), { color: 8, tabId: 't1', type: 'setTabColour' })
    c = overviewReducer(c, { column: 'cost', tabId: 't1', type: 'toggleColumn' })
    const reset = overviewReducer(c, { tabId: 't1', type: 'resetTab' })
    expect(reset).not.toBe(c)
    expect(reset.tabs[0]?.color).toBe(8)
    expect(reset.tabs[0]?.columns).toEqual(base().tabs[0]?.columns)
  })
})
