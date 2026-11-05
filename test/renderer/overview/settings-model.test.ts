import { describe, expect, it } from 'vitest'
import { TAB_COLOUR_NAMES, TAB_SWATCH, TAB_TEXT } from '../../../src/renderer/src/overview/cells'
import { COLUMN_IDS, type ColumnId } from '../../../src/renderer/src/overview/columns'
import {
  defaultOverviewConfig,
  type OverviewConfig,
  type OverviewTab,
  overviewReducer,
  parseOverviewConfig,
} from '../../../src/renderer/src/overview/config'
import {
  columnRows,
  DROP_MARGIN,
  dropTarget,
  inDropArea,
  moveColumn,
  nextColour,
  resetTab,
  setBoxOnly,
  showKind,
  showState,
  toggleColumn,
} from '../../../src/renderer/src/overview/settings-model'

const base = (): OverviewConfig => defaultOverviewConfig()
const tabOf = (c: OverviewConfig, id = 't1') => c.tabs.find(t => t.id === id) as OverviewTab
const ids = (c: OverviewConfig, id = 't1') => columnRows(c, id).map(r => r.id)
const shown = (c: OverviewConfig, id = 't1') => tabOf(c, id).columns

describe('overview settings model', () => {
  it('columnRows gives all columns in order, with the default columns on and kind locked', () => {
    const rows = columnRows(base(), 't1')
    expect(rows.map(r => r.id)).toEqual([...COLUMN_IDS])
    expect(rows.filter(r => r.visible).map(r => r.id)).toEqual([
      'kind',
      'name',
      'state',
      'project',
      'activity',
    ])
    expect(rows[0]).toEqual({ id: 'kind', label: 'Kind', locked: true, visible: true })
    expect(rows.find(r => r.id === 'activity')).toEqual({
      id: 'activity',
      label: 'Last activity',
      locked: false,
      visible: true,
    })
    expect(rows.filter(r => r.locked).map(r => r.id)).toEqual(['kind'])
    expect(columnRows(base(), 'nope')).toEqual([])
  })

  it('toggleColumn turns a column on at its place in the order, and off again', () => {
    const c = base()
    const on = toggleColumn(c, 't1', 'cost')
    expect(shown(on)).toEqual(['kind', 'name', 'state', 'project', 'cost', 'activity'])
    // The row stays in its place in the list.
    expect(ids(on)).toEqual(ids(c))
    const off = toggleColumn(on, 't1', 'cost')
    expect(shown(off)).toEqual(shown(c))
    expect(shown(toggleColumn(c, 't1', 'state'))).toEqual(['kind', 'name', 'project', 'activity'])
    // Other tabs do not change.
    expect(on.tabs[1]).toBe(c.tabs[1])
  })

  it('toggleColumn refuses the kind column and an unknown tab', () => {
    const c = base()
    expect(toggleColumn(c, 't1', 'kind')).toBe(c)
    expect(toggleColumn(c, 'nope', 'cost')).toBe(c)
  })

  it('moveColumn moves a column before another column, and the Overview order follows', () => {
    const c = base()
    const up = moveColumn(c, 't1', 'activity', 'name')
    expect(ids(up)).toEqual([
      'kind',
      'activity',
      'name',
      'priority',
      'state',
      'project',
      'branch',
      'model',
      'context',
      'cost',
    ])
    expect(shown(up)).toEqual(['kind', 'activity', 'name', 'state', 'project'])
    // A hidden column keeps its new place. It shows there when you turn it on.
    const hidden = moveColumn(c, 't1', 'cost', 'state')
    expect(shown(hidden)).toEqual(shown(c))
    expect(shown(toggleColumn(hidden, 't1', 'cost'))).toEqual([
      'kind',
      'name',
      'cost',
      'state',
      'project',
      'activity',
    ])
  })

  it('moveColumn moves a column to the end for null and never before kind', () => {
    const c = base()
    const end = moveColumn(c, 't1', 'name', null)
    expect(ids(end).at(-1)).toBe('name')
    expect(shown(end)).toEqual(['kind', 'state', 'project', 'activity', 'name'])
    expect(ids(moveColumn(c, 't1', 'state', 'kind')).slice(0, 2)).toEqual(['kind', 'state'])
  })

  it('moveColumn returns the same object when nothing changes', () => {
    const c = base()
    expect(moveColumn(c, 't1', 'kind', 'name')).toBe(c)
    expect(moveColumn(c, 't1', 'name', 'name')).toBe(c)
    expect(moveColumn(c, 't1', 'name', 'priority')).toBe(c)
    expect(moveColumn(c, 't1', 'activity', null)).toBe(c)
    expect(moveColumn(c, 'nope', 'name', null)).toBe(c)
  })

  it('resetTab gives the tab its default columns, filter and widths, and keeps the sort', () => {
    let c = overviewReducer(base(), { column: 'activity', tabId: 't2', type: 'sortBy' })
    c = overviewReducer(c, { tabId: 't2', type: 'setWidths', widths: { name: 200 } })
    const before = { ...tabOf(c, 't2'), widths: {} }
    let changed = moveColumn(toggleColumn(c, 't2', 'branch'), 't2', 'activity', 'name')
    changed = setBoxOnly(
      showKind(showState(changed, 't2', 'parked', true), 't2', 'external', false),
      't2',
      false,
    )
    const reset = resetTab(changed, 't2')
    expect(tabOf(reset, 't2')).toEqual(before)
    expect(tabOf(reset, 't2').sort).toEqual({ column: 'activity', desc: true })
    expect(tabOf(reset, 't2').widths).toEqual({})
    expect(reset.tabs[0]).toBe(changed.tabs[0])
  })

  it('resetTab returns the same object for a default tab and an unknown tab', () => {
    const c = base()
    expect(resetTab(c, 't3')).toBe(c)
    expect(resetTab(c, 'nope')).toBe(c)
  })

  it('resetTab gives an added tab the filter of All', () => {
    const added = overviewReducer(base(), { type: 'addTab' })
    const changed = showState(toggleColumn(added, 't6', 'model'), 't6', 'working', false)
    const reset = resetTab(changed, 't6')
    expect(tabOf(reset, 't6').filter).toEqual(tabOf(base(), 't1').filter)
    expect(shown(reset, 't6')).toEqual(shown(base()))
  })

  it('Reset tab of a user tab t6 in a saved M3 config gives the All filter', () => {
    const m3 = {
      nextTab: 6,
      tabs: ['All', 'Needs you', 'Working', 'Idle', 'Parked'].map((name, i) => ({
        id: `t${i + 1}`,
        name,
      })),
    }
    const saved = parseOverviewConfig(m3) as OverviewConfig
    const added = overviewReducer(saved, { type: 'addTab' })
    expect(tabOf(added, 't6').name).toBe('Tab 6')
    const changed = showState(added, 't6', 'working', false)
    const reset = resetTab(changed, 't6')
    expect(tabOf(reset, 't6').filter).toEqual(tabOf(base(), 't1').filter)
    expect(tabOf(reset, 't6').filter.watchedOnly).toBe(false)
  })

  it('Reset tab of the Watched tab gives the Watched filter', () => {
    const changed = showState(base(), 't0', 'working', false)
    const reset = resetTab(changed, 't0')
    expect(tabOf(reset, 't0').filter).toEqual(tabOf(base(), 't0').filter)
    expect(tabOf(reset, 't0').filter.watchedOnly).toBe(true)
  })

  it('showState, showKind and setBoxOnly change the tab filter and keep a fixed order', () => {
    const c = base()
    const parked = showState(c, 't1', 'parked', true)
    expect(tabOf(parked).filter.states).toEqual(['working', 'needs-you', 'error', 'idle', 'parked'])
    const noIdle = showState(c, 't1', 'idle', false)
    expect(tabOf(noIdle).filter.states).toEqual(['working', 'needs-you', 'error'])
    const owned = showKind(c, 't1', 'external', false)
    expect(tabOf(owned).filter.kinds).toEqual(['owned'])
    expect(tabOf(showKind(owned, 't1', 'external', true)).filter.kinds).toEqual([
      'owned',
      'external',
    ])
    expect(tabOf(setBoxOnly(c, 't1', true)).filter.boxOnly).toBe(true)
  })

  it('the filter setters return the same object when nothing changes', () => {
    const c = base()
    expect(showState(c, 't1', 'working', true)).toBe(c)
    expect(showState(c, 't1', 'parked', false)).toBe(c)
    expect(showKind(c, 't1', 'owned', true)).toBe(c)
    expect(setBoxOnly(c, 't2', true)).toBe(c)
    expect(showState(c, 'nope', 'parked', true)).toBe(c)
  })
})

describe('inDropArea', () => {
  const list = { h: 200, w: 300, x: 100, y: 50 }

  it('accepts a release on the list and up to DROP_MARGIN px outside it', () => {
    expect(DROP_MARGIN).toBe(24)
    expect(inDropArea(list, { x: 250, y: 150 })).toBe(true)
    expect(inDropArea(list, { x: 100 - 24, y: 50 - 24 })).toBe(true)
    expect(inDropArea(list, { x: 400 + 24, y: 250 + 24 })).toBe(true)
  })

  it('refuses a release more than DROP_MARGIN px outside the list', () => {
    expect(inDropArea(list, { x: 100 - 25, y: 150 })).toBe(false)
    expect(inDropArea(list, { x: 400 + 25, y: 150 })).toBe(false)
    expect(inDropArea(list, { x: 250, y: 50 - 25 })).toBe(false)
    expect(inDropArea(list, { x: 250, y: 250 + 25 })).toBe(false)
  })
})

describe('dropTarget', () => {
  const order: ColumnId[] = ['kind', 'name', 'state', 'project', 'activity']

  it('moves a row down: the lower half of a row puts it after that row', () => {
    expect(dropTarget(order, 'name', 3, false)).toBe('activity')
    expect(dropTarget(order, 'name', 3, true)).toBe('project')
  })

  it('moves a row up: the upper half of a row puts it before that row', () => {
    expect(dropTarget(order, 'activity', 1, true)).toBe('name')
    expect(dropTarget(order, 'activity', 1, false)).toBe('state')
  })

  it('a drop on the dragged row gives no change', () => {
    for (const upperHalf of [true, false]) {
      expect(dropTarget(order, 'state', 2, upperHalf)).toBe('project')
    }
    // The lower half of the row above the dragged row is also the old place.
    expect(dropTarget(order, 'state', 1, false)).toBe('project')
    expect(dropTarget(order, 'activity', 4, true)).toBeNull()
  })

  it('a drop on the lower half of the last row gives null for the end', () => {
    expect(dropTarget(order, 'name', 4, false)).toBeNull()
    expect(dropTarget(order, 'name', 99, false)).toBeNull()
  })

  it('a row never goes before the kind row', () => {
    expect(dropTarget(order, 'project', 0, true)).toBe('name')
    expect(dropTarget(order, 'project', 0, false)).toBe('name')
    expect(dropTarget(order, 'project', -3, true)).toBe('name')
    expect(dropTarget(order, 'name', 0, true)).toBe('state')
  })

  it('the result applied with moveColumn gives the expected order', () => {
    const c = base()
    const order0 = tabOf(c).order
    const before = dropTarget(order0, 'activity', 2, true)
    expect(shown(moveColumn(c, 't1', 'activity', before))).toEqual([
      'kind',
      'name',
      'activity',
      'state',
      'project',
    ])
    const same = dropTarget(order0, 'state', order0.indexOf('state'), true)
    expect(moveColumn(c, 't1', 'state', same)).toBe(c)
  })

  it('the Colour row has 12 colours in order, with a text class and a swatch class for each', () => {
    expect(TAB_COLOUR_NAMES).toEqual([
      'Cyan',
      'Light blue',
      'Green',
      'Teal',
      'Blue',
      'Mint',
      'Red',
      'Amber',
      'Yellow',
      'Lime',
      'White',
      'Sky blue',
    ])
    expect(TAB_TEXT).toHaveLength(12)
    expect(TAB_SWATCH).toEqual(Array.from({ length: 12 }, (_, i) => `bg-tab-${i + 1}`))
    expect(TAB_TEXT[11]).toBe('text-tab-12')
  })

  it('nextColour moves with the arrow keys and wraps at the ends', () => {
    expect(nextColour(11, 'ArrowRight')).toBe(0)
    expect(nextColour(0, 'ArrowLeft')).toBe(11)
    expect(nextColour(3, 'ArrowRight')).toBe(4)
    expect(nextColour(3, 'ArrowLeft')).toBe(2)
    expect(TAB_COLOUR_NAMES[nextColour(TAB_COLOUR_NAMES.indexOf('Sky blue'), 'ArrowRight')]).toBe(
      'Cyan',
    )
    expect(nextColour(3, 'Enter')).toBe(3)
    expect(nextColour(3, 'ArrowUp')).toBe(3)
  })
})
