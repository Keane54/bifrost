import { describe, expect, it } from 'vitest'
import { COLUMN_IDS } from '../../../src/renderer/src/overview/columns'
import { defaultOverviewConfig, type OverviewTab } from '../../../src/renderer/src/overview/config'
import {
  dropBefore,
  inResizeZone,
  RESIZE_ZONE,
  toTableState,
} from '../../../src/renderer/src/overview/table-state'

function tabWith(over: Partial<OverviewTab>): OverviewTab {
  const base = defaultOverviewConfig().tabs[0] as OverviewTab
  return { ...base, ...over }
}

describe('overview table state', () => {
  it('toTableState maps the sort, the order, the visibility and the widths', () => {
    const state = toTableState(
      tabWith({
        columns: ['kind', 'state', 'name'],
        sort: { column: 'cost', desc: true },
        widths: { name: 200 },
      }),
    )
    expect(state.sorting).toEqual([{ desc: true, id: 'cost' }])
    expect(state.columnOrder).toEqual([
      'kind',
      'state',
      'name',
      'priority',
      'project',
      'branch',
      'model',
      'context',
      'cost',
      'activity',
    ])
    expect(state.columnVisibility.kind).toBe(true)
    expect(state.columnVisibility.state).toBe(true)
    expect(state.columnVisibility.name).toBe(true)
    expect(state.columnVisibility.project).toBe(false)
    expect(Object.keys(state.columnVisibility).sort()).toEqual([...COLUMN_IDS].sort())
    expect(state.columnSizing.name).toBe(200)
    expect(state.columnSizing.cost).toBe(60)
    expect(Object.keys(state.columnSizing).sort()).toEqual([...COLUMN_IDS].sort())
  })

  it('toTableState of a default tab shows the default columns first', () => {
    const state = toTableState(tabWith({}))
    expect(state.sorting).toEqual([{ desc: false, id: 'name' }])
    expect(state.columnOrder.join(',')).toBe(
      'kind,name,state,project,activity,priority,branch,model,context,cost',
    )
    expect(COLUMN_IDS.filter(id => state.columnVisibility[id])).toEqual([
      'kind',
      'name',
      'state',
      'project',
      'activity',
    ])
  })

  it('dropBefore puts a column after a target on its right and before a target on its left', () => {
    const columns = ['kind', 'name', 'state', 'cost'] as const
    expect(dropBefore([...columns], 'name', 'state')).toEqual({ before: 'cost' })
    expect(dropBefore([...columns], 'name', 'cost')).toEqual({ before: null })
    expect(dropBefore([...columns], 'cost', 'name')).toEqual({ before: 'name' })
    expect(dropBefore([...columns], 'cost', 'kind')).toEqual({ before: 'kind' })
  })

  it('dropBefore gives null for the kind column, the same column or a hidden column', () => {
    const columns = ['kind', 'name', 'state', 'cost'] as const
    expect(dropBefore([...columns], 'kind', 'name')).toBeNull()
    expect(dropBefore([...columns], 'name', 'name')).toBeNull()
    expect(dropBefore([...columns], 'model', 'name')).toBeNull()
    expect(dropBefore([...columns], 'name', 'model')).toBeNull()
  })

  it('inResizeZone is true only in the handle area at the right edge of the header', () => {
    expect(inResizeZone(200, 200)).toBe(true)
    expect(inResizeZone(200 - RESIZE_ZONE, 200)).toBe(true)
    expect(inResizeZone(200 - RESIZE_ZONE - 1, 200)).toBe(false)
    expect(inResizeZone(201, 200)).toBe(false)
  })
})
