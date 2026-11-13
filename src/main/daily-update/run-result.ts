// The result file of a draft run. The run read text from the board and from PRs, so Bifrost
// trusts none of it. The check is strict: one failed rule gives bad-result.

import type { DailyAreaResult, DailyItem, FailureCode } from '../../shared/daily-state'
import { isRecord } from '../../shared/plain-object'

export const RESULT_VERSION = 1
export const RESULT_BEGIN = 'BIFROST-DAILY-RESULT-BEGIN'
export const RESULT_END = 'BIFROST-DAILY-RESULT-END'
export const MAX_OUTPUT_BYTES = 1024 * 1024

const MAX_ITEMS = 100
export const MAX_ID = 100
const MAX_TITLE = 300
const MAX_STATE = 60
const MAX_URL = 2000
const MAX_DRAFT = 8000
const FAILURES = ['no-user', 'source-unavailable', 'tool-denied']
const ITEM_KEYS = ['kind', 'id', 'title', 'from', 'to', 'url']
const AREA_KEYS = ['id', 'moved', 'items', 'draft']
const TOP_KEYS = ['version', 'areas', 'unplaced']

type Result =
  | { ok: true; areas: DailyAreaResult[]; unplaced: DailyItem[] }
  | { ok: false; failure: FailureCode }

const BAD: Result = { failure: 'bad-result', ok: false }

const onlyKeys = (value: Record<string, unknown>, allowed: readonly string[]): boolean =>
  Object.keys(value).every(key => allowed.includes(key))

const shortText = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length <= max

function checkItem(value: unknown): DailyItem | null {
  if (!isRecord(value) || !onlyKeys(value, ITEM_KEYS)) return null
  const { kind, id, title } = value
  if (kind !== 'ticket' && kind !== 'pr') return null
  if (!shortText(id, MAX_ID) || !shortText(title, MAX_TITLE)) return null
  const item: DailyItem = { id, kind, title }
  for (const key of ['from', 'to'] as const) {
    if (!Object.hasOwn(value, key)) continue
    const text = value[key]
    if (!shortText(text, MAX_STATE)) return null
    item[key] = text
  }
  if (Object.hasOwn(value, 'url')) {
    const { url } = value
    if (!shortText(url, MAX_URL) || !url.startsWith('https://')) return null
    item.url = url
  }
  return item
}

// Two items with the same kind and ID in one list are refused, so openItem cannot open the
// wrong one.
function checkItems(value: unknown): DailyItem[] | null {
  if (!Array.isArray(value) || value.length > MAX_ITEMS) return null
  const items: DailyItem[] = []
  for (const raw of value) {
    const item = checkItem(raw)
    if (!item || items.some(i => i.kind === item.kind && i.id === item.id)) return null
    items.push(item)
  }
  return items
}

function checkArea(value: unknown): DailyAreaResult | null {
  if (!isRecord(value) || !onlyKeys(value, AREA_KEYS)) return null
  const { id, moved, items, draft } = value
  if (typeof id !== 'string' || typeof moved !== 'boolean') return null
  if (typeof draft !== 'string' || draft.length < 1 || draft.length > MAX_DRAFT) return null
  const checked = checkItems(items)
  return checked ? { draft, id, items: checked, moved } : null
}

// Check the text of the result file. onAreaIds are the IDs of the areas that are on. Each one
// must show exactly once. The result holds only the known fields.
export function checkDailyResult(text: string, onAreaIds: readonly string[]): Result {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return BAD
  }
  if (!isRecord(data) || data.version !== RESULT_VERSION) return BAD
  if (Object.hasOwn(data, 'failure')) {
    const { failure } = data
    const alone = Object.keys(data).length === 2
    if (alone && typeof failure === 'string' && FAILURES.includes(failure)) {
      return { failure: failure as FailureCode, ok: false }
    }
    return BAD
  }
  if (!onlyKeys(data, TOP_KEYS) || !Array.isArray(data.areas)) return BAD
  const unplaced = checkItems(data.unplaced)
  if (!unplaced) return BAD
  const areas: DailyAreaResult[] = []
  for (const raw of data.areas) {
    const area = checkArea(raw)
    if (!area || areas.some(a => a.id === area.id)) return BAD
    areas.push(area)
  }
  if (areas.length !== onAreaIds.length) return BAD
  if (!areas.every(a => onAreaIds.includes(a.id))) return BAD
  return { areas, ok: true, unplaced }
}

// Take the result text from the stdout of claude -p with --output-format json. The text sits
// between the last line that is only RESULT_BEGIN and the next line that is only RESULT_END.
export function extractResult(stdout: string): { ok: true; text: string } | { ok: false } {
  if (Buffer.byteLength(stdout, 'utf8') > MAX_OUTPUT_BYTES) return { ok: false }
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    return { ok: false }
  }
  if (!isRecord(data) || data.is_error !== false || typeof data.result !== 'string') {
    return { ok: false }
  }
  const lines = data.result.split(/\r?\n/)
  const begin = lines.map(l => l.trim()).lastIndexOf(RESULT_BEGIN)
  if (begin === -1) return { ok: false }
  const end = lines.findIndex((l, i) => i > begin && l.trim() === RESULT_END)
  if (end === -1) return { ok: false }
  return { ok: true, text: lines.slice(begin + 1, end).join('\n') }
}
