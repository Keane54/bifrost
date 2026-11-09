import { PR_KEY } from '../../shared/reviews'

// The Reviews state. Bifrost keeps it in ~/.bifrost/reviews/state.json.
// R1 uses turnedOnAt, baseline, requests and pauses.
// R2 and R3 use the other fields.

export interface SessionRef {
  sessionId: string
  name: string
}

export interface PrState {
  // Keys are item IDs. The value tells when Bifrost handled the item.
  handled: Record<string, { at: number; lastReplyAt: number | null }>
  firstCopilotReview: string | null
  lastReviewedCommit: string | null
  request: SessionRef | null
  review: SessionRef | null
  handleOlder: boolean
  handleCopilot: boolean
  rerequested: Record<string, string>
  lastError: string | null
}

export interface PostedComment {
  id: string
  prKey: string
  body: string
  at: number
}

export interface DraftComment {
  reviewId: string
  prKey: string
  path: string
  line: number
  body: string
  at: number
}

export interface VoicePair {
  prKey: string
  draft: string
  final: string
  at: number
}

export interface ReviewsState {
  version: 1
  turnedOnAt: number | null
  // Item IDs (GitHub node IDs) that existed when the user turned Reviews on.
  baseline: string[]
  requests: Record<string, { firstSeen: number; baseline: boolean }>
  pauses: Record<string, number>
  prs: Record<string, PrState>
  posted: PostedComment[]
  drafts: DraftComment[]
  voicePairs: VoicePair[]
}

export const EMPTY_STATE: ReviewsState = {
  baseline: [],
  drafts: [],
  pauses: {},
  posted: [],
  prs: {},
  requests: {},
  turnedOnAt: null,
  version: 1,
  voicePairs: [],
}

export function emptyPrState(): PrState {
  return {
    firstCopilotReview: null,
    handleCopilot: false,
    handled: {},
    handleOlder: false,
    lastError: null,
    lastReviewedCommit: null,
    request: null,
    rerequested: {},
    review: null,
  }
}

// The caps keep the newest entries. The oldest go first.
export const MAX_POSTED = 2000
export const MAX_DRAFTS = 2000
export const MAX_VOICE_PAIRS = 1000

type Obj = Record<string, unknown>

function isObject(value: unknown): value is Obj {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

function stringOrNull(value: unknown): string | null {
  return isString(value) ? value : null
}

function sessionRef(value: unknown): SessionRef | null {
  if (!isObject(value) || !isString(value.sessionId) || !isString(value.name)) return null
  return { name: value.name, sessionId: value.sessionId }
}

function parsePrState(value: unknown): PrState {
  const state = emptyPrState()
  if (!isObject(value)) return state
  if (isObject(value.handled)) {
    for (const [id, entry] of Object.entries(value.handled)) {
      if (id === '' || !isObject(entry) || !isNumber(entry.at)) continue
      state.handled[id] = {
        at: entry.at,
        lastReplyAt: isNumber(entry.lastReplyAt) ? entry.lastReplyAt : null,
      }
    }
  }
  if (isObject(value.rerequested)) {
    for (const [id, text] of Object.entries(value.rerequested)) {
      if (isString(text)) state.rerequested[id] = text
    }
  }
  state.firstCopilotReview = stringOrNull(value.firstCopilotReview)
  state.lastReviewedCommit = stringOrNull(value.lastReviewedCommit)
  state.lastError = stringOrNull(value.lastError)
  state.request = sessionRef(value.request)
  state.review = sessionRef(value.review)
  state.handleOlder = value.handleOlder === true
  state.handleCopilot = value.handleCopilot === true
  return state
}

// Keep the valid entries of a list. Sort by time and keep the newest, up to the cap.
function parseList<T extends { at: number }>(
  value: unknown,
  cap: number,
  parseEntry: (entry: Obj) => T | null,
): T[] {
  if (!Array.isArray(value)) return []
  const list: T[] = []
  for (const entry of value) {
    const parsed = isObject(entry) ? parseEntry(entry) : null
    if (parsed !== null) list.push(parsed)
  }
  // The sort is stable, so entries with the same time keep their order.
  list.sort((a, b) => a.at - b.at)
  return list.length > cap ? list.slice(list.length - cap) : list
}

function keyOk(key: unknown): key is string {
  return isString(key) && PR_KEY.test(key)
}

// Check each field. A bad field gets its empty value.
// A key that fails PR_KEY goes. A version other than 1 gives EMPTY_STATE.
export function parseState(data: unknown): ReviewsState {
  if (!isObject(data) || data.version !== 1) return structuredClone(EMPTY_STATE)
  const requests: ReviewsState['requests'] = {}
  if (isObject(data.requests)) {
    for (const [key, entry] of Object.entries(data.requests)) {
      if (!keyOk(key) || !isObject(entry) || !isNumber(entry.firstSeen)) continue
      requests[key] = { baseline: entry.baseline === true, firstSeen: entry.firstSeen }
    }
  }
  const pauses: ReviewsState['pauses'] = {}
  if (isObject(data.pauses)) {
    for (const [key, until] of Object.entries(data.pauses)) {
      if (keyOk(key) && isNumber(until)) pauses[key] = until
    }
  }
  const prs: ReviewsState['prs'] = {}
  if (isObject(data.prs)) {
    for (const [key, entry] of Object.entries(data.prs)) {
      if (keyOk(key)) prs[key] = parsePrState(entry)
    }
  }
  return {
    baseline: Array.isArray(data.baseline)
      ? data.baseline.filter((id): id is string => isString(id) && id !== '')
      : [],
    drafts: parseList(data.drafts, MAX_DRAFTS, e =>
      isString(e.reviewId) &&
      keyOk(e.prKey) &&
      isString(e.path) &&
      isNumber(e.line) &&
      isString(e.body) &&
      isNumber(e.at)
        ? {
            at: e.at,
            body: e.body,
            line: e.line,
            path: e.path,
            prKey: e.prKey,
            reviewId: e.reviewId,
          }
        : null,
    ),
    pauses,
    posted: parseList(data.posted, MAX_POSTED, e =>
      isString(e.id) && keyOk(e.prKey) && isString(e.body) && isNumber(e.at)
        ? { at: e.at, body: e.body, id: e.id, prKey: e.prKey }
        : null,
    ),
    prs,
    requests,
    turnedOnAt: isNumber(data.turnedOnAt) ? data.turnedOnAt : null,
    version: 1,
    voicePairs: parseList(data.voicePairs, MAX_VOICE_PAIRS, e =>
      keyOk(e.prKey) && isString(e.draft) && isString(e.final) && isNumber(e.at)
        ? { at: e.at, draft: e.draft, final: e.final, prKey: e.prKey }
        : null,
    ),
  }
}
