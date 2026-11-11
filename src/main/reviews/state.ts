import { PR_KEY, RECOMMENDATIONS, REPO_KEY, type Recommendation } from '../../shared/reviews'
import { SHORT_ID } from '../actions/claude-output'

// The Reviews state. Bifrost keeps it in ~/.bifrost/reviews/state.json.
// R1 uses turnedOnAt, baseline, requests and pauses.
// R2 and R3 use the other fields.

export interface SessionRef {
  sessionId: string
  name: string
  // The short ID of the session. Kept only when it has 8 hex digits.
  shortId?: string
}

export type RoundPhase = 'preparing' | 'running' | 'posting'

// One review round of a PR. `at` is the `at` of the queue entry that started the round.
export interface ActiveRound {
  phase: RoundPhase
  startedAt: number
  at: number
  headSha: string | null
  shortId: string | null
  sessionId: string | null
  stoppedByUser: boolean
}

export interface RecommendationMark {
  value: Recommendation
  why: string
  headSha: string
  reviewId: string | null
  at: number
}

// R3 adds 'request'.
export type JobKind = 'review'

export interface QueueEntry {
  key: string
  kind: JobKind
  at: number
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
  round: ActiveRound | null
  recommendation: RecommendationMark | null
  actedAt: number | null
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
  // One entry for each key and kind, sorted by at.
  queue: QueueEntry[]
  repos: Record<string, { trustNotifiedAt: number | null }>
  // The end of the trust set-up. Null until the set-up ran.
  setUpAt: number | null
}

export const MAX_QUEUE = 200

export const EMPTY_STATE: ReviewsState = {
  baseline: [],
  drafts: [],
  pauses: {},
  posted: [],
  prs: {},
  queue: [],
  repos: {},
  requests: {},
  setUpAt: null,
  turnedOnAt: null,
  version: 1,
  voicePairs: [],
}

export function emptyPrState(): PrState {
  return {
    actedAt: null,
    firstCopilotReview: null,
    handleCopilot: false,
    handled: {},
    handleOlder: false,
    lastError: null,
    lastReviewedCommit: null,
    recommendation: null,
    request: null,
    rerequested: {},
    review: null,
    round: null,
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
  const ref: SessionRef = { name: value.name, sessionId: value.sessionId }
  if (isString(value.shortId) && SHORT_ID.test(value.shortId)) ref.shortId = value.shortId
  return ref
}

function parseRound(value: unknown): ActiveRound | null {
  if (!isObject(value)) return null
  const { phase } = value
  if (phase !== 'preparing' && phase !== 'running' && phase !== 'posting') return null
  if (!isNumber(value.startedAt) || !isNumber(value.at)) return null
  return {
    at: value.at,
    headSha: stringOrNull(value.headSha),
    phase,
    sessionId: stringOrNull(value.sessionId),
    shortId: isString(value.shortId) && SHORT_ID.test(value.shortId) ? value.shortId : null,
    startedAt: value.startedAt,
    stoppedByUser: value.stoppedByUser === true,
  }
}

function parseMark(value: unknown): RecommendationMark | null {
  if (!isObject(value) || !isNumber(value.at)) return null
  const { value: mark } = value
  if (!RECOMMENDATIONS.includes(mark as Recommendation)) return null
  if (!isString(value.why) || !isString(value.headSha)) return null
  return {
    at: value.at,
    headSha: value.headSha,
    reviewId: stringOrNull(value.reviewId),
    value: mark as Recommendation,
    why: value.why,
  }
}

// Keep the valid entries. One entry for each key and kind, the first wins. Sort by time and keep
// the newest, up to the cap.
function parseQueue(value: unknown): QueueEntry[] {
  if (!Array.isArray(value)) return []
  const seen = new Set<string>()
  const list: QueueEntry[] = []
  for (const entry of value) {
    if (!isObject(entry) || !keyOk(entry.key) || entry.kind !== 'review' || !isNumber(entry.at)) {
      continue
    }
    const id = `${entry.kind}:${entry.key}`
    if (seen.has(id)) continue
    seen.add(id)
    list.push({ at: entry.at, key: entry.key, kind: entry.kind })
  }
  list.sort((a, b) => a.at - b.at)
  return list.length > MAX_QUEUE ? list.slice(0, MAX_QUEUE) : list
}

// Keys that change an object or its prototype. A file can hold them as own keys, because
// JSON.parse makes an own key __proto__ (final review M13).
const UNSAFE_KEYS: readonly string[] = ['__proto__', 'constructor', 'prototype']

function safeKey(key: string): boolean {
  return key !== '' && !UNSAFE_KEYS.includes(key)
}

function parsePrState(value: unknown): PrState {
  const state = emptyPrState()
  if (!isObject(value)) return state
  if (isObject(value.handled)) {
    for (const [id, entry] of Object.entries(value.handled)) {
      if (!safeKey(id) || !isObject(entry) || !isNumber(entry.at)) continue
      state.handled[id] = {
        at: entry.at,
        lastReplyAt: isNumber(entry.lastReplyAt) ? entry.lastReplyAt : null,
      }
    }
  }
  if (isObject(value.rerequested)) {
    for (const [id, text] of Object.entries(value.rerequested)) {
      if (safeKey(id) && isString(text)) state.rerequested[id] = text
    }
  }
  state.firstCopilotReview = stringOrNull(value.firstCopilotReview)
  state.lastReviewedCommit = stringOrNull(value.lastReviewedCommit)
  state.lastError = stringOrNull(value.lastError)
  state.request = sessionRef(value.request)
  state.review = sessionRef(value.review)
  state.handleOlder = value.handleOlder === true
  state.handleCopilot = value.handleCopilot === true
  state.round = parseRound(value.round)
  state.recommendation = parseMark(value.recommendation)
  state.actedAt = isNumber(value.actedAt) ? value.actedAt : null
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
  const repos: ReviewsState['repos'] = {}
  if (isObject(data.repos)) {
    for (const [key, entry] of Object.entries(data.repos)) {
      if (!REPO_KEY.test(key) || !isObject(entry)) continue
      repos[key] = {
        trustNotifiedAt: isNumber(entry.trustNotifiedAt) ? entry.trustNotifiedAt : null,
      }
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
    queue: parseQueue(data.queue),
    repos,
    requests,
    setUpAt: isNumber(data.setUpAt) ? data.setUpAt : null,
    turnedOnAt: isNumber(data.turnedOnAt) ? data.turnedOnAt : null,
    version: 1,
    voicePairs: parseList(data.voicePairs, MAX_VOICE_PAIRS, e =>
      keyOk(e.prKey) && isString(e.draft) && isString(e.final) && isNumber(e.at)
        ? { at: e.at, draft: e.draft, final: e.final, prKey: e.prKey }
        : null,
    ),
  }
}
