// The config of one Overview: its tabs, filters, columns, widths and sort.

import { isRecord } from '../../../shared/plain-object'
import type { SessionKind, SessionState } from '../../../shared/types'
import { panelKind } from '../wm/state'
import {
  COLUMN_IDS,
  type ColumnId,
  DEFAULT_COLUMNS,
  DESC_FIRST,
  isColumnId,
  MAX_WIDTH,
  MIN_WIDTH,
} from './columns'
import type { SortSpec, TabFilter } from './rows'

export interface OverviewTab {
  id: string
  name: string
  color: number
  filter: TabFilter
  // The visible columns in display order. The kind column is always first.
  columns: ColumnId[]
  // All columns in display order, also the hidden columns. The kind column is always first.
  // A hidden column keeps its place. When you turn it on, it shows at that place.
  // The visible columns are always in this order.
  order: ColumnId[]
  widths: Partial<Record<ColumnId, number>>
  sort: SortSpec
}

export interface OverviewConfig {
  name: string
  tabs: OverviewTab[]
  active: string
  nextTab: number
}

export const MAX_TABS = 12
export const MAX_TAB_NAME = 24
export const MAX_SET_NAME = 40
// The colours that a user can choose for a tab. The first DEFAULT_TAB_COLOURS are automatic.
export const TAB_COLOURS = 12
export const DEFAULT_TAB_COLOURS = 6

// The states and the kinds of a tab filter, in the order of the filter lists.
export const STATES: readonly SessionState[] = ['working', 'needs-you', 'error', 'idle', 'parked']
export const KINDS: readonly SessionKind[] = ['owned', 'external']
const LIVE: SessionState[] = ['working', 'needs-you', 'error', 'idle']
// A tab ID has at most 4 digits, so the counter stays a safe whole number.
const TAB_ID = /^t\d{1,4}$/
const MAX_TAB_NUMBER = 9999
// The tab colour of the Watched tab (an index of the first DEFAULT_TAB_COLOURS).
const WATCHED_COLOUR = 5
const NAME_SORT: SortSpec = { column: 'name', desc: false }

// A filter that shows both kinds.
function filterOf(
  states: readonly SessionState[],
  boxOnly = false,
  watchedOnly = false,
): TabFilter {
  return { boxOnly, kinds: [...KINDS], states: [...states], watchedOnly }
}

// The colour of a default tab follows its number. The Watched tab is t0, so it has its own colour.
function tab(id: number, name: string, filter: TabFilter, color = id - 1): OverviewTab {
  return {
    color,
    columns: [...DEFAULT_COLUMNS],
    filter,
    id: `t${id}`,
    name,
    order: [...COLUMN_IDS],
    sort: { ...NAME_SORT },
    widths: {},
  }
}

export function defaultOverviewConfig(): OverviewConfig {
  return {
    active: 't1',
    name: 'Default',
    nextTab: 6,
    tabs: [
      tab(1, 'All', filterOf(LIVE)),
      tab(2, 'Alerts', filterOf(LIVE, true)),
      // The Watched tab shows the watched rows of every state. Its ID is t0. A tab that the user
      // adds never has t0, because nextTab starts at 1. So a saved config cannot clash with it.
      tab(0, 'Watched', filterOf(STATES, false, true), WATCHED_COLOUR),
      tab(3, 'Working', filterOf(['working'])),
      tab(4, 'Idle', filterOf(['idle'])),
      tab(5, 'Parked', filterOf(['parked'])),
    ],
  }
}

// The filter of a default tab (spec 8.3). A tab that the user added starts with the filter of All.
function defaultFilter(tabId: string): TabFilter {
  return defaultOverviewConfig().tabs.find(t => t.id === tabId)?.filter ?? filterOf(LIVE)
}

// Shared by all Overviews that have no saved config. Never change it.
export const DEFAULT_CONFIG: OverviewConfig = Object.freeze(defaultOverviewConfig())

export function activeTab(config: OverviewConfig): OverviewTab {
  return config.tabs.find(t => t.id === config.active) ?? (config.tabs[0] as OverviewTab)
}

function clampWidth(value: number): number {
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(value)))
}

function parseWidths(value: unknown): Partial<Record<ColumnId, number>> {
  const widths: Partial<Record<ColumnId, number>> = {}
  if (!isRecord(value)) return widths
  for (const [key, raw] of Object.entries(value)) {
    if (isColumnId(key) && typeof raw === 'number' && Number.isFinite(raw)) {
      widths[key] = clampWidth(raw)
    }
  }
  return widths
}

function parseColumns(value: unknown): ColumnId[] {
  // A missing or damaged list gives the default columns. A list gives its valid IDs.
  if (!Array.isArray(value)) return [...DEFAULT_COLUMNS]
  const columns: ColumnId[] = []
  for (const id of value) {
    if (isColumnId(id) && id !== 'kind' && !columns.includes(id)) columns.push(id)
  }
  return ['kind', ...columns]
}

// The saved order gives the place of each column. A tab from before the order has no saved order.
// Then the saved visible columns come first in their order, and the hidden columns follow in the
// default order. So a saved tab keeps its columns.
function parseOrder(value: unknown, columns: ColumnId[]): ColumnId[] {
  const order: ColumnId[] = ['kind']
  const add = (id: unknown): void => {
    if (isColumnId(id) && !order.includes(id)) order.push(id)
  }
  if (Array.isArray(value)) value.forEach(add)
  columns.forEach(add)
  COLUMN_IDS.forEach(add)
  return order
}

// The known values of a list, without repeats. A value that is not a list gives an empty list.
function knownValues<T>(value: unknown, known: readonly T[]): T[] {
  const result: T[] = []
  if (!Array.isArray(value)) return result
  for (const item of value) {
    const found = known.find(k => k === item)
    if (found !== undefined && !result.includes(found)) result.push(found)
  }
  return result
}

function parseFilter(value: unknown): TabFilter {
  const filter = isRecord(value) ? value : {}
  return {
    boxOnly: filter.boxOnly === true,
    // A filter from before the kinds, or a damaged kind list, shows both kinds.
    kinds: Array.isArray(filter.kinds) ? knownValues(filter.kinds, KINDS) : [...KINDS],
    states: knownValues(filter.states, STATES),
    // A filter from before the Watchlist shows the rows that are not watched too.
    watchedOnly: filter.watchedOnly === true,
  }
}

function parseSort(value: unknown): SortSpec {
  if (!isRecord(value) || !isColumnId(value.column)) return { ...NAME_SORT }
  return { column: value.column, desc: value.desc === true }
}

// A hidden column never sorts, because the sort column shows its arrow (spec 8.3).
// When the sort column is hidden, the tab sorts by Name ascending if Name is visible.
// Else it sorts by the first visible column after kind, ascending. The kind column is always
// visible, so it is the last choice. A tab with a visible sort column keeps its object.
function withVisibleSort(t: OverviewTab): OverviewTab {
  if (t.columns.includes(t.sort.column)) return t
  const column = t.columns.includes('name') ? 'name' : (t.columns[1] ?? 'kind')
  return { ...t, sort: { column, desc: false } }
}

function parseTab(value: unknown, index: number): OverviewTab | null {
  if (!isRecord(value) || typeof value.id !== 'string' || !TAB_ID.test(value.id)) return null
  if (typeof value.name !== 'string') return null
  const trimmed = value.name.trim()
  if (trimmed.length < 1 || trimmed.length > MAX_TAB_NAME) return null
  // Bifrost used to call the second default tab Needs you. Rename only that tab.
  const name = value.id === 't2' && trimmed === 'Needs you' ? 'Alerts' : trimmed
  const color =
    typeof value.color === 'number' &&
    Number.isInteger(value.color) &&
    value.color >= 0 &&
    value.color < TAB_COLOURS
      ? value.color
      : index % DEFAULT_TAB_COLOURS
  const columns = parseColumns(value.columns)
  // Default columns for a damaged list keep the default order, as in a new tab.
  const order = parseOrder(value.order, Array.isArray(value.columns) ? columns : [])
  return withVisibleSort({
    color,
    columns: order.filter(id => columns.includes(id)),
    filter: parseFilter(value.filter),
    id: value.id,
    name,
    order,
    sort: parseSort(value.sort),
    widths: parseWidths(value.widths),
  })
}

function tabNumber(id: string): number {
  return Number(id.slice(1))
}

// Check a config that the renderer read from ui-state.json. Give null when no tab is valid.
export function parseOverviewConfig(data: unknown): OverviewConfig | null {
  if (!isRecord(data) || !Array.isArray(data.tabs)) return null
  const tabs: OverviewTab[] = []
  for (const raw of data.tabs) {
    if (tabs.length >= MAX_TABS) break
    const parsed = parseTab(raw, tabs.length)
    if (parsed && !tabs.some(t => t.id === parsed.id)) tabs.push(parsed)
  }
  const first = tabs[0]
  if (!first) return null
  const name = typeof data.name === 'string' ? data.name.trim() : ''
  const highest = Math.max(...tabs.map(t => tabNumber(t.id)))
  const nextTab =
    typeof data.nextTab === 'number' &&
    Number.isSafeInteger(data.nextTab) &&
    data.nextTab >= 1 &&
    data.nextTab <= MAX_TAB_NUMBER
      ? data.nextTab
      : 0
  return {
    active: tabs.some(t => t.id === data.active) ? (data.active as string) : first.id,
    name: name.length >= 1 && name.length <= MAX_SET_NAME ? name : 'Default',
    nextTab: Math.max(nextTab, highest + 1),
    tabs,
  }
}

export function parseOverviews(data: unknown): Record<string, OverviewConfig> {
  const result: Record<string, OverviewConfig> = {}
  if (!isRecord(data)) return result
  for (const [key, raw] of Object.entries(data)) {
    if (panelKind(key) !== 'overview') continue
    const config = parseOverviewConfig(raw)
    if (config) result[key] = config
  }
  return result
}

export type OverviewAction =
  | { type: 'addTab' }
  | { type: 'removeTab'; tabId: string }
  | { type: 'renameTab'; tabId: string; name: string }
  | { type: 'moveTab'; tabId: string; by: -1 | 1 }
  | { type: 'activate'; tabId: string }
  | { type: 'setFilter'; tabId: string; filter: TabFilter }
  | { type: 'toggleColumn'; tabId: string; column: ColumnId }
  | { type: 'moveColumn'; tabId: string; column: ColumnId; before: ColumnId | null }
  | { type: 'resetTab'; tabId: string }
  | { type: 'setTabColour'; tabId: string; color: number }
  | { type: 'setWidths'; tabId: string; widths: Partial<Record<ColumnId, number>> }
  | { type: 'sortBy'; tabId: string; column: ColumnId }
  | { type: 'rename'; name: string }

// Replace one tab. An unknown tab, or a tab that does not change, gives the same config.
function withTab(
  config: OverviewConfig,
  tabId: string,
  change: (tab: OverviewTab) => OverviewTab,
): OverviewConfig {
  const index = config.tabs.findIndex(t => t.id === tabId)
  const current = config.tabs[index]
  if (!current) return config
  const next = change(current)
  if (next === current) return config
  return { ...config, tabs: config.tabs.map((t, i) => (i === index ? next : t)) }
}

function sameList<T>(a: readonly T[], b: readonly T[]): boolean {
  return a.length === b.length && a.every((item, i) => item === b[i])
}

function sameFilter(a: TabFilter, b: TabFilter): boolean {
  return (
    a.boxOnly === b.boxOnly &&
    a.watchedOnly === b.watchedOnly &&
    sameList(a.states, b.states) &&
    sameList(a.kinds, b.kinds)
  )
}

export function overviewReducer(config: OverviewConfig, action: OverviewAction): OverviewConfig {
  switch (action.type) {
    case 'addTab': {
      if (config.tabs.length >= MAX_TABS) return config
      const n = config.nextTab
      if (n > MAX_TAB_NUMBER || config.tabs.some(t => t.id === `t${n}`)) return config
      const added: OverviewTab = {
        ...tab(1, `Tab ${n}`, filterOf(LIVE)),
        color: (n - 1) % DEFAULT_TAB_COLOURS,
        id: `t${n}`,
      }
      return { ...config, active: added.id, nextTab: n + 1, tabs: [...config.tabs, added] }
    }
    case 'removeTab': {
      const index = config.tabs.findIndex(t => t.id === action.tabId)
      if (index < 0 || config.tabs.length <= 1) return config
      const tabs = config.tabs.filter((_, i) => i !== index)
      let active = config.active
      const fallback = tabs[index - 1] ?? tabs[0]
      if (active === action.tabId && fallback) active = fallback.id
      return { ...config, active, tabs }
    }
    case 'renameTab': {
      const name = action.name.trim()
      if (name.length < 1 || name.length > MAX_TAB_NAME) return config
      return withTab(config, action.tabId, t => (t.name === name ? t : { ...t, name }))
    }
    case 'moveTab': {
      const from = config.tabs.findIndex(t => t.id === action.tabId)
      const to = from + action.by
      if (from < 0 || to < 0 || to >= config.tabs.length) return config
      const tabs = [...config.tabs]
      const moved = tabs[from] as OverviewTab
      tabs[from] = tabs[to] as OverviewTab
      tabs[to] = moved
      return { ...config, tabs }
    }
    case 'activate':
      if (config.active === action.tabId || !config.tabs.some(t => t.id === action.tabId)) {
        return config
      }
      return { ...config, active: action.tabId }
    case 'setFilter':
      return withTab(config, action.tabId, t => {
        const { boxOnly, kinds, states, watchedOnly } = action.filter
        if (sameFilter(t.filter, action.filter)) return t
        return { ...t, filter: { boxOnly, kinds: [...kinds], states: [...states], watchedOnly } }
      })
    case 'toggleColumn': {
      const { column } = action
      if (column === 'kind') return config
      // A column that you turn on shows at its place in the order.
      return withTab(config, action.tabId, t =>
        withVisibleSort({
          ...t,
          columns: t.columns.includes(column)
            ? t.columns.filter(c => c !== column)
            : t.order.filter(c => c === column || t.columns.includes(c)),
        }),
      )
    }
    case 'moveColumn': {
      // The move changes the order of all columns. A hidden column can move too.
      const { column, before } = action
      if (column === 'kind' || column === before) return config
      return withTab(config, action.tabId, t => {
        if (!t.order.includes(column)) return t
        if (before !== null && !t.order.includes(before)) return t
        const rest = t.order.filter(c => c !== column)
        const at = before === null ? rest.length : Math.max(1, rest.indexOf(before))
        const order = [...rest.slice(0, at), column, ...rest.slice(at)]
        if (sameList(order, t.order)) return t
        return { ...t, columns: order.filter(c => t.columns.includes(c)), order }
      })
    }
    case 'resetTab':
      // The reset also restores the default widths. The sort changes only when the reset hides
      // the sort column.
      return withTab(config, action.tabId, t => {
        const filter = defaultFilter(t.id)
        const same =
          sameList(t.columns, DEFAULT_COLUMNS) &&
          sameList(t.order, COLUMN_IDS) &&
          Object.keys(t.widths).length === 0 &&
          sameFilter(t.filter, filter)
        if (same) return t
        return withVisibleSort({
          ...t,
          columns: [...DEFAULT_COLUMNS],
          filter,
          order: [...COLUMN_IDS],
          widths: {},
        })
      })
    case 'setTabColour': {
      const { color } = action
      if (!Number.isInteger(color) || color < 0 || color >= TAB_COLOURS) return config
      return withTab(config, action.tabId, t => (t.color === color ? t : { ...t, color }))
    }
    case 'setWidths':
      return withTab(config, action.tabId, t => {
        const widths = { ...t.widths }
        for (const [key, value] of Object.entries(action.widths)) {
          if (isColumnId(key) && typeof value === 'number' && Number.isFinite(value)) {
            widths[key] = clampWidth(value)
          }
        }
        const same = COLUMN_IDS.every(id => widths[id] === t.widths[id])
        return same ? t : { ...t, widths }
      })
    case 'sortBy':
      // A hidden column never sorts.
      return withTab(config, action.tabId, t => {
        if (!t.columns.includes(action.column)) return t
        return {
          ...t,
          sort:
            t.sort.column === action.column
              ? { column: action.column, desc: !t.sort.desc }
              : { column: action.column, desc: DESC_FIRST.has(action.column) },
        }
      })
    case 'rename': {
      const name = action.name.trim()
      if (name.length < 1 || name.length > MAX_SET_NAME || name === config.name) return config
      return { ...config, name }
    }
  }
}

// An edit gives the next config from the current config. So it always reads the current config.
export type OverviewsAction =
  | { type: 'load'; overviews: Record<string, OverviewConfig> }
  | { type: 'update'; panelId: string; action: OverviewAction }
  | { type: 'edit'; panelId: string; edit(config: OverviewConfig): OverviewConfig }

export function overviewsReducer(
  state: Record<string, OverviewConfig>,
  action: OverviewsAction,
): Record<string, OverviewConfig> {
  if (action.type === 'load') return action.overviews
  const current = configOf(state, action.panelId)
  const next =
    action.type === 'edit' ? action.edit(current) : overviewReducer(current, action.action)
  if (next === current) return state
  return { ...state, [action.panelId]: next }
}

export function configOf(state: Record<string, OverviewConfig>, panelId: string): OverviewConfig {
  return state[panelId] ?? DEFAULT_CONFIG
}
