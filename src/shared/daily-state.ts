// The day state of the Daily update. All changes are pure and give a new state.
import { type DayMarks, freshMarks } from './daily-schedule'
import type { WorkArea } from './daily-update'
import { isPlainObject } from './plain-object'

export interface DailyItem {
  kind: 'ticket' | 'pr'
  id: string
  title: string
  from?: string
  to?: string
  url?: string
}

export interface AreaView {
  items: DailyItem[]
  moved: boolean
  draft: string
  // True when the user changed the draft.
  edited: boolean
  // A newer draft that Bifrost keeps apart from the changed draft.
  pending?: string
  // The start of the run that made the items, in ms. A view from an older file has none.
  since?: number
}

export interface DailyAreaResult {
  id: string
  moved: boolean
  items: DailyItem[]
  draft: string
}

export const FAILURE_CODES = [
  'no-user',
  'source-unavailable',
  'tool-denied',
  'bad-result',
  'timeout',
  'claude-failed',
  'nothing-to-read',
] as const
export type FailureCode = (typeof FAILURE_CODES)[number]

export interface DailyState {
  version: 1
  marks: DayMarks
  // Area id to the time of the last send, and of the send before it.
  lastSent: Record<string, number>
  prevSent: Record<string, number>
  areas: Record<string, AreaView>
  unplaced: DailyItem[]
  lastRun: { at: number; ok: boolean; failure?: FailureCode; detail?: string } | null
}

// What the panel shows. The main process makes it.
export interface DailySnapshot {
  // True when an area is on.
  configured: boolean
  // True when today is one of the days of the settings.
  due: boolean
  // True while the side bar button shows its marker.
  marker: boolean
  // True while a run runs.
  running: boolean
  // The deadline of the settings, HH:MM.
  deadline: string
  // Area id to the start of "since your last update", in ms.
  since: Record<string, number>
  // The areas that are on, in the order of the settings.
  areas: WorkArea[]
  // The state of today. Marks from an earlier day are fresh marks here.
  state: DailyState
}

export const EMPTY_DAILY_STATE: DailyState = {
  areas: {},
  lastRun: null,
  lastSent: {},
  marks: freshMarks(''),
  prevSent: {},
  unplaced: [],
  version: 1,
}

// Records are keyed by area id. Own keys only, so an id such as "constructor" is safe.
function without<T>(record: Record<string, T>, id: string): Record<string, T> {
  return Object.fromEntries(Object.entries(record).filter(([key]) => key !== id))
}

function withKey<T>(record: Record<string, T>, id: string, value: T): Record<string, T> {
  return Object.fromEntries([...Object.entries(record).filter(([key]) => key !== id), [id, value]])
}

function own<T>(record: Record<string, T>, id: string): T | undefined {
  return Object.hasOwn(record, id) ? record[id] : undefined
}

function view(result: DailyAreaResult, since: number | undefined): AreaView {
  const area: AreaView = {
    draft: result.draft,
    edited: false,
    items: result.items,
    moved: result.moved,
  }
  if (since !== undefined) area.since = since
  return area
}

const dropPending = ({ pending: _pending, ...rest }: AreaView): AreaView => rest

// A new day gives fresh marks. A draft that the user changed on an earlier day is not kept apart
// any more, so the run of the new day replaces it.
export function rollDay(s: DailyState, today: string): DailyState {
  if (s.marks.date === today) return s
  const areas = Object.fromEntries(
    Object.entries(s.areas).map(([id, area]) => [id, { ...dropPending(area), edited: false }]),
  )
  return { ...s, areas, marks: freshMarks(today) }
}

// since: area id to the start of the run for that area, in ms.
export function applyResult(
  s: DailyState,
  areas: DailyAreaResult[],
  unplaced: DailyItem[],
  at: number,
  since: Readonly<Record<string, number>> = {},
): DailyState {
  let next = s.areas
  for (const result of areas) {
    const old = own(next, result.id)
    let area = view(result, own(since, result.id))
    if (old?.edited) {
      area = { ...area, draft: old.draft, edited: true }
      if (result.draft !== old.draft) area.pending = result.draft
    }
    next = withKey(next, result.id, area)
  }
  return { ...s, areas: next, lastRun: { at, ok: true }, unplaced }
}

export function redoArea(s: DailyState, area: DailyAreaResult, since?: number): DailyState {
  return { ...s, areas: withKey(s.areas, area.id, view(area, since)) }
}

function changeArea(s: DailyState, id: string, fn: (a: AreaView) => AreaView): DailyState {
  const old = own(s.areas, id)
  return old ? { ...s, areas: withKey(s.areas, id, fn(old)) } : s
}

export function editDraft(s: DailyState, id: string, text: string): DailyState {
  return changeArea(s, id, a => ({ ...a, draft: text, edited: true }))
}

export function usePending(s: DailyState, id: string): DailyState {
  return changeArea(s, id, a =>
    a.pending === undefined ? a : { ...dropPending(a), draft: a.pending, edited: false },
  )
}

export function keepMine(s: DailyState, id: string): DailyState {
  return changeArea(s, id, dropPending)
}

export function markSent(s: DailyState, id: string, at: number): DailyState {
  const earlier = own(s.lastSent, id)
  return {
    ...s,
    lastSent: withKey(s.lastSent, id, at),
    marks: { ...s.marks, sent: withKey(s.marks.sent, id, at) },
    prevSent: earlier === undefined ? without(s.prevSent, id) : withKey(s.prevSent, id, earlier),
  }
}

export function undoSent(s: DailyState, id: string): DailyState {
  const earlier = own(s.prevSent, id)
  return {
    ...s,
    lastSent: earlier === undefined ? without(s.lastSent, id) : withKey(s.lastSent, id, earlier),
    marks: { ...s.marks, sent: without(s.marks.sent, id) },
    prevSent: without(s.prevSent, id),
  }
}

export function setSkipped(s: DailyState, skipped: boolean): DailyState {
  return { ...s, marks: { ...s.marks, skipped } }
}

export function setFirstShown(s: DailyState): DailyState {
  return { ...s, marks: { ...s.marks, firstShown: true } }
}

export function setSecondShown(s: DailyState): DailyState {
  return { ...s, marks: { ...s.marks, secondShown: true } }
}

export function failRun(
  s: DailyState,
  at: number,
  failure: FailureCode,
  detail?: string,
): DailyState {
  const lastRun: NonNullable<DailyState['lastRun']> = { at, failure, ok: false }
  if (detail !== undefined) lastRun.detail = detail
  return { ...s, lastRun }
}

const SETTINGS_PLACE = 'Settings > Daily update'

// The text of a failure for the panel and the Event log. server is the name of the ticket source.
// detail is the status of the server, or the short reason of a failed claude.
export function failureText(failure: FailureCode, detail?: string, server?: string | null): string {
  switch (failure) {
    case 'nothing-to-read':
      return `Choose a ticket source or turn on merged PRs in ${SETTINGS_PLACE}.`
    case 'source-unavailable': {
      const name = server ? server : 'the ticket source'
      const reason = detail ? ` (${detail})` : ''
      return `Bifrost couldn't reach ${name}${reason}. Check it in Claude Code with /mcp.`
    }
    case 'no-user':
      return (
        "Claude couldn't find you on the board. " +
        `Add your name, email or ID in ${SETTINGS_PLACE}.`
      )
    case 'tool-denied':
      return (
        "The run needed a tool that it isn't allowed to use. " +
        `Check the tools in ${SETTINGS_PLACE}.`
      )
    case 'bad-result':
      return "Claude's answer didn't have the right shape, so Bifrost didn't use it. Try Refresh."
    case 'timeout':
      return 'The run took more than 5 minutes, so Bifrost stopped it.'
    case 'claude-failed': {
      const text = "Claude Code couldn't run the daily update."
      return detail ? `${text} ${detail}` : text
    }
  }
}

// Parsing. A bad value gives the empty value. A bad item is dropped.

const isString = (v: unknown): v is string => typeof v === 'string'
const isNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

function parseItem(value: unknown): DailyItem | null {
  if (!isPlainObject(value)) return null
  const { kind, id, title } = value
  if ((kind !== 'ticket' && kind !== 'pr') || !isString(id) || !isString(title)) return null
  const item: DailyItem = { id, kind, title }
  for (const key of ['from', 'to', 'url'] as const) {
    if (isString(value[key])) item[key] = value[key]
  }
  return item
}

function parseItems(value: unknown): DailyItem[] {
  if (!Array.isArray(value)) return []
  return value.flatMap(v => parseItem(v) ?? [])
}

function parseTimes(value: unknown): Record<string, number> {
  if (!isPlainObject(value)) return {}
  return Object.fromEntries(Object.entries(value).filter(([, v]) => isNumber(v))) as Record<
    string,
    number
  >
}

function parseArea(value: unknown): AreaView | null {
  if (!isPlainObject(value) || !isString(value.draft)) return null
  const area: AreaView = {
    draft: value.draft,
    edited: value.edited === true,
    items: parseItems(value.items),
    moved: value.moved === true,
  }
  if (isString(value.pending)) area.pending = value.pending
  if (isNumber(value.since)) area.since = value.since
  return area
}

function parseMarks(value: unknown): DayMarks {
  if (!isPlainObject(value) || !isString(value.date)) return freshMarks('')
  return {
    date: value.date,
    firstShown: value.firstShown === true,
    secondShown: value.secondShown === true,
    sent: parseTimes(value.sent),
    skipped: value.skipped === true,
  }
}

function parseLastRun(value: unknown): DailyState['lastRun'] {
  if (!isPlainObject(value) || !isNumber(value.at) || typeof value.ok !== 'boolean') return null
  const run: NonNullable<DailyState['lastRun']> = { at: value.at, ok: value.ok }
  const failure = FAILURE_CODES.find(code => code === value.failure)
  if (failure) run.failure = failure
  if (isString(value.detail)) run.detail = value.detail
  return run
}

export function parseDailyState(value: unknown): DailyState {
  if (!isPlainObject(value) || value.version !== 1) return structuredClone(EMPTY_DAILY_STATE)
  const entries = isPlainObject(value.areas) ? Object.entries(value.areas) : []
  const areas = entries.flatMap(([id, raw]): [string, AreaView][] => {
    const area = parseArea(raw)
    return area ? [[id, area]] : []
  })
  return {
    areas: Object.fromEntries(areas),
    lastRun: parseLastRun(value.lastRun),
    lastSent: parseTimes(value.lastSent),
    marks: parseMarks(value.marks),
    prevSent: parseTimes(value.prevSent),
    unplaced: parseItems(value.unplaced),
    version: 1,
  }
}
