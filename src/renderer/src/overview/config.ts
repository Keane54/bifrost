// The config of one Overview: its tabs, filters, columns, widths and sort.
import type { SessionState } from '../../../shared/types'
import { panelKind } from '../wm/state'
import { COLUMN_IDS, type ColumnId, DESC_FIRST, isColumnId, MAX_WIDTH, MIN_WIDTH } from './columns'
import type { SortSpec, TabFilter } from './rows'

export interface OverviewTab {
  id: string
  name: string
  color: number
  filter: TabFilter
  // The visible columns in display order. The kind column is always first.
  columns: ColumnId[]
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
export const TAB_COLOURS = 6

const STATES: readonly SessionState[] = ['working', 'needs-you', 'error', 'idle', 'parked']
const LIVE: SessionState[] = ['working', 'needs-you', 'error', 'idle']
// A tab ID has at most 4 digits, so the counter stays a safe whole number.
const TAB_ID = /^t\d{1,4}$/
const MAX_TAB_NUMBER = 9999
const NAME_SORT: SortSpec = { column: 'name', desc: false }

function tab(id: number, name: string, filter: TabFilter): OverviewTab {
  return {
    color: id - 1,
    columns: [...COLUMN_IDS],
    filter,
    id: `t${id}`,
    name,
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
      tab(1, 'All', { boxOnly: false, states: [...LIVE] }),
      tab(2, 'Needs you', { boxOnly: true, states: [...LIVE] }),
      tab(3, 'Working', { boxOnly: false, states: ['working'] }),
      tab(4, 'Idle', { boxOnly: false, states: ['idle'] }),
      tab(5, 'Parked', { boxOnly: false, states: ['parked'] }),
    ],
  }
}

// Shared by all Overviews that have no saved config. Never change it.
export const DEFAULT_CONFIG: OverviewConfig = Object.freeze(defaultOverviewConfig())

export function activeTab(config: OverviewConfig): OverviewTab {
  return config.tabs.find(t => t.id === config.active) ?? (config.tabs[0] as OverviewTab)
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function clampWidth(value: number): number {
  return Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(value)))
}

function parseWidths(value: unknown): Partial<Record<ColumnId, number>> {
  const widths: Partial<Record<ColumnId, number>> = {}
  if (!isObject(value)) return widths
  for (const [key, raw] of Object.entries(value)) {
    if (isColumnId(key) && typeof raw === 'number' && Number.isFinite(raw)) {
      widths[key] = clampWidth(raw)
    }
  }
  return widths
}

function parseColumns(value: unknown): ColumnId[] {
  // A missing or damaged list gives all columns. A list gives its valid IDs.
  if (!Array.isArray(value)) return [...COLUMN_IDS]
  const columns: ColumnId[] = []
  if (Array.isArray(value)) {
    for (const id of value) {
      if (isColumnId(id) && id !== 'kind' && !columns.includes(id)) columns.push(id)
    }
  }
  return ['kind', ...columns]
}

function parseFilter(value: unknown): TabFilter {
  const states: SessionState[] = []
  if (isObject(value) && Array.isArray(value.states)) {
    for (const s of value.states) {
      const state = STATES.find(known => known === s)
      if (state && !states.includes(state)) states.push(state)
    }
  }
  return { boxOnly: isObject(value) && value.boxOnly === true, states }
}

function parseSort(value: unknown): SortSpec {
  if (!isObject(value) || !isColumnId(value.column)) return { ...NAME_SORT }
  return { column: value.column, desc: value.desc === true }
}

function parseTab(value: unknown, index: number): OverviewTab | null {
  if (!isObject(value) || typeof value.id !== 'string' || !TAB_ID.test(value.id)) return null
  if (typeof value.name !== 'string') return null
  const name = value.name.trim()
  if (name.length < 1 || name.length > MAX_TAB_NAME) return null
  const color =
    typeof value.color === 'number' &&
    Number.isInteger(value.color) &&
    value.color >= 0 &&
    value.color < TAB_COLOURS
      ? value.color
      : index % TAB_COLOURS
  return {
    color,
    columns: parseColumns(value.columns),
    filter: parseFilter(value.filter),
    id: value.id,
    name,
    sort: parseSort(value.sort),
    widths: parseWidths(value.widths),
  }
}

function tabNumber(id: string): number {
  return Number(id.slice(1))
}

// Check a config that the renderer read from ui-state.json. Give null when no tab is valid.
export function parseOverviewConfig(data: unknown): OverviewConfig | null {
  if (!isObject(data) || !Array.isArray(data.tabs)) return null
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
  if (!isObject(data)) return result
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

export function overviewReducer(config: OverviewConfig, action: OverviewAction): OverviewConfig {
  switch (action.type) {
    case 'addTab': {
      if (config.tabs.length >= MAX_TABS) return config
      const n = config.nextTab
      if (n > MAX_TAB_NUMBER || config.tabs.some(t => t.id === `t${n}`)) return config
      const added: OverviewTab = {
        ...tab(1, `Tab ${n}`, { boxOnly: false, states: [...LIVE] }),
        color: (n - 1) % TAB_COLOURS,
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
        const { boxOnly, states } = action.filter
        const same =
          t.filter.boxOnly === boxOnly &&
          t.filter.states.length === states.length &&
          t.filter.states.every((state, i) => state === states[i])
        return same ? t : { ...t, filter: { boxOnly, states: [...states] } }
      })
    case 'toggleColumn': {
      if (action.column === 'kind') return config
      return withTab(config, action.tabId, t => ({
        ...t,
        columns: t.columns.includes(action.column)
          ? t.columns.filter(c => c !== action.column)
          : [...t.columns, action.column],
      }))
    }
    case 'moveColumn': {
      const { column, before } = action
      if (column === 'kind' || column === before) return config
      return withTab(config, action.tabId, t => {
        if (!t.columns.includes(column)) return t
        if (before !== null && !t.columns.includes(before)) return t
        const rest = t.columns.filter(c => c !== column)
        const at = before === null ? rest.length : Math.max(1, rest.indexOf(before))
        const columns = [...rest.slice(0, at), column, ...rest.slice(at)]
        return columns.every((c, i) => c === t.columns[i]) ? t : { ...t, columns }
      })
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
      return withTab(config, action.tabId, t => ({
        ...t,
        sort:
          t.sort.column === action.column
            ? { column: action.column, desc: !t.sort.desc }
            : { column: action.column, desc: DESC_FIRST.has(action.column) },
      }))
    case 'rename': {
      const name = action.name.trim()
      if (name.length < 1 || name.length > MAX_SET_NAME || name === config.name) return config
      return { ...config, name }
    }
  }
}

export type OverviewsAction =
  | { type: 'load'; overviews: Record<string, OverviewConfig> }
  | { type: 'update'; panelId: string; action: OverviewAction }

export function overviewsReducer(
  state: Record<string, OverviewConfig>,
  action: OverviewsAction,
): Record<string, OverviewConfig> {
  if (action.type === 'load') return action.overviews
  const current = configOf(state, action.panelId)
  const next = overviewReducer(current, action.action)
  if (next === current) return state
  return { ...state, [action.panelId]: next }
}

export function configOf(state: Record<string, OverviewConfig>, panelId: string): OverviewConfig {
  return state[panelId] ?? DEFAULT_CONFIG
}
