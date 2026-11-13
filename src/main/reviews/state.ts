import { githubCommentUrl } from '../../shared/github-url'
import { isRecord as isObject } from '../../shared/plain-object'
import {
  ITEM_ID,
  MAX_ANSWER,
  PR_KEY,
  RECOMMENDATIONS,
  REPO_KEY,
  type Recommendation,
} from '../../shared/reviews'
import { SHORT_ID } from '../actions/claude-output'
import { OBJECT_ID } from './repo-store'

// The Reviews state. Bifrost keeps it in ~/.bifrost/reviews/state.json.
// R1 uses turnedOnAt, baseline, requests and pauses.
// R2 and R3 use the other fields. R3 adds the request rounds: the outbox, the questions, the held
// items, checkedAt, fixFrom and autoFixConsent.

export interface SessionRef {
  sessionId: string
  name: string
  // The short ID of the session. Kept only when it has 8 hex digits.
  shortId?: string
}

export type RoundPhase = 'preparing' | 'running' | 'posting'

// A review job reviews the PR of another person. A request job fixes and answers the comments on
// a PR of the user.
export type JobKind = 'review' | 'request'

// One round of a PR. `at` is the `at` of the queue entry that started the round.
export interface ActiveRound {
  phase: RoundPhase
  startedAt: number
  at: number
  headSha: string | null
  // The base commit of the diff of the round. After a restart, Bifrost makes the diff again from
  // its clone with this commit. A file without it parses with no baseSha.
  baseSha?: string
  shortId: string | null
  sessionId: string | null
  stoppedByUser: boolean
  // The job of the round. A file from R2 has no kind: that is a review round.
  kind?: JobKind
  // Request rounds only. Each item ID of the round, with the newest GitHub time of its comments
  // when the round read them (seenUntil).
  items?: Record<string, number>
  // Request rounds only. The fix commit of the round.
  fixSha?: string
}

export interface RecommendationMark {
  value: Recommendation
  why: string
  headSha: string
  reviewId: string | null
  at: number
}

export interface QueueEntry {
  key: string
  kind: JobKind
  at: number
}

export type PostState = 'todo' | 'sending' | 'done' | 'dropped'

// One GitHub write of the outbox, or the commit before the push. A text of null is the
// "Fixed by" text. signed: true on the push post means that the round sends the fix commit to
// GitHub with createCommitOnBranch, and not with git. The outbox keeps this choice, so a resume
// uses it and not the setting of now (ruling S24). The sha of a signed push is the commit that
// GitHub made.
export type Post = { id: string; state: PostState } & (
  | { kind: 'commit'; paths: string[]; message: string; sha?: string }
  | { kind: 'push'; sha?: string; signed?: true }
  | { kind: 'reply'; itemId: string; text: string | null; by?: string; commentId?: string }
  | { kind: 'resolve'; itemId: string }
  | {
      kind: 'comment'
      itemId: string
      quote: string
      text: string | null
      by?: string
      commentId?: string
    }
  | { kind: 'rerequest'; logins?: string[] }
)

// The writes of one request round, in order. The outbox stays in the state file until each post
// is done or dropped, so a restart goes on with the rest. `seen` gives the seenUntil of each item.
export interface Outbox {
  headSha: string
  mergeBase: string
  startedAt: number
  seen: Record<string, number>
  posts: Post[]
}

// A question of Claude for the user about one item. `answer` stays null until the user answers.
// `seenUntil` is the newest GitHub time of the comments of the item when the round read them.
// `author`, `body` and `url` hold the quote of the comment of the reviewer. They are optional, so
// a file from before the quote still loads.
export interface Question {
  question: string
  where: string
  author?: string
  body?: string
  url?: string
  kind?: 'thread' | 'comment'
  at: number
  answer: string | null
  seenUntil: number
}

export interface PrState {
  // Keys are item IDs. The value tells when Bifrost handled the item.
  // R3 writes each entry with handledEntry. An R1 entry can have a null lastReplyAt.
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
  // The writes of the last request round that are not all sent.
  outbox: Outbox | null
  // Keys are item IDs.
  questions: Record<string, Question>
  // The item IDs of a failed request round. They wait for Handle now or Try again.
  held: string[]
  // The GitHub updatedAt of the PR at the last full read of a request round.
  checkedAt: number | null
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
  // An item from before this time is older: it waits for Handle now. Bifrost sets it at the
  // first poll of R3 and at each turn-on.
  fixFrom: number | null
  // Ruling S20. False when Watch GitHub was on before R3: the confirm of the user then did not
  // name the fixes, so no automatic request round starts. The confirm of Handle comments
  // automatically sets true. Null when nothing asked for the confirm.
  autoFixConsent: boolean | null
}

export const MAX_QUEUE = 200
// The most items in one request round.
export const MAX_ROUND_ITEMS = 30
// The longest question, answer and where text, in characters.
export const MAX_QUESTION = 500
export { MAX_ANSWER }
export const MAX_WHERE = 300
// The longest quote of the comment of a reviewer, and the longest login, in characters.
export const MAX_QUOTE = 600
export const MAX_AUTHOR = 60
// The most held items of one PR. The newest stay.
export const MAX_HELD = 200

// The handled entry of an item. It never has a null lastReplyAt, so a later trusted comment
// makes the item work again (R3 note).
export function handledEntry(
  at: number,
  lastReplyAt: number | null,
): { at: number; lastReplyAt: number } {
  return { at, lastReplyAt: lastReplyAt ?? at }
}

export const EMPTY_STATE: ReviewsState = {
  autoFixConsent: null,
  baseline: [],
  drafts: [],
  fixFrom: null,
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
    checkedAt: null,
    firstCopilotReview: null,
    handleCopilot: false,
    handled: {},
    handleOlder: false,
    held: [],
    lastError: null,
    lastReviewedCommit: null,
    outbox: null,
    questions: {},
    recommendation: null,
    request: null,
    rerequested: {},
    review: null,
    round: null,
  }
}

// The caps keep the newest entries. The oldest go first. The queue is the exception: it keeps
// the oldest entries, because the oldest entry runs first.
export const MAX_POSTED = 2000
export const MAX_DRAFTS = 2000
export const MAX_VOICE_PAIRS = 1000

type Obj = Record<string, unknown>

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

const JOB_KINDS: readonly JobKind[] = ['review', 'request']

const isJobKind = (value: unknown): value is JobKind => JOB_KINDS.includes(value as JobKind)

// An item ID: the form of a GitHub node ID, and never a key that changes an object.
const isItemId = (value: unknown): value is string =>
  isString(value) && ITEM_ID.test(value) && safeKey(value)

const isObjectId = (value: unknown): value is string => isString(value) && OBJECT_ID.test(value)

// The entries of a record of item IDs and times. A bad entry goes.
function itemTimes(value: Obj): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [id, time] of Object.entries(value)) {
    if (isItemId(id) && isNumber(time)) out[id] = time
  }
  return out
}

function parseRound(value: unknown): ActiveRound | null {
  if (!isObject(value)) return null
  const { phase } = value
  if (phase !== 'preparing' && phase !== 'running' && phase !== 'posting') return null
  if (!isNumber(value.startedAt) || !isNumber(value.at)) return null
  // An unknown kind gives no round, so that one job never acts on a round of the other job.
  if (value.kind !== undefined && !isJobKind(value.kind)) return null
  const round: ActiveRound = {
    at: value.at,
    headSha: stringOrNull(value.headSha),
    phase,
    sessionId: stringOrNull(value.sessionId),
    shortId: isString(value.shortId) && SHORT_ID.test(value.shortId) ? value.shortId : null,
    startedAt: value.startedAt,
    stoppedByUser: value.stoppedByUser === true,
  }
  if (isString(value.baseSha) && OBJECT_ID.test(value.baseSha)) round.baseSha = value.baseSha
  if (isJobKind(value.kind)) round.kind = value.kind
  if (isObject(value.items)) round.items = itemTimes(value.items)
  if (isObjectId(value.fixSha)) round.fixSha = value.fixSha
  return round
}

const POST_STATES: readonly PostState[] = ['todo', 'sending', 'done', 'dropped']
// The value of a bad optional field.
const BAD = Symbol('bad')

// An optional field: absent, or a valid value. Else BAD.
function optional<T>(value: unknown, check: (v: unknown) => v is T): T | undefined | typeof BAD {
  if (value === undefined) return undefined
  return check(value) ? value : BAD
}

const isText = (value: unknown): value is string | null => value === null || isString(value)
const isBool = (value: unknown): value is boolean => typeof value === 'boolean'
const isNames = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every(name => isString(name) && name !== '')

// A post with a bad field gives null.
function parsePost(value: unknown): Post | null {
  if (!isObject(value) || !isString(value.id) || value.id === '') return null
  const state = value.state as PostState
  if (!POST_STATES.includes(state)) return null
  const head = { id: value.id, state }
  const sha = optional(value.sha, isObjectId)
  const by = optional(value.by, isObjectId)
  const commentId = optional(value.commentId, isItemId)
  const logins = optional(value.logins, isNames)
  const signed = optional(value.signed, isBool)
  if (sha === BAD || by === BAD || commentId === BAD || logins === BAD || signed === BAD) {
    return null
  }
  const sent = {
    ...(by === undefined ? {} : { by }),
    ...(commentId === undefined ? {} : { commentId }),
  }
  const itemId = isItemId(value.itemId) ? value.itemId : null
  switch (value.kind) {
    case 'commit':
      if (!isNames(value.paths) || !isString(value.message)) return null
      return {
        ...head,
        kind: 'commit',
        message: value.message,
        paths: [...value.paths],
        ...(sha === undefined ? {} : { sha }),
      }
    case 'push':
      return {
        ...head,
        kind: 'push',
        ...(sha === undefined ? {} : { sha }),
        ...(signed === true ? { signed: true } : {}),
      }
    case 'reply':
      if (itemId === null || !isText(value.text)) return null
      return { ...head, itemId, kind: 'reply', text: value.text, ...sent }
    case 'resolve':
      if (itemId === null) return null
      return { ...head, itemId, kind: 'resolve' }
    case 'comment':
      if (itemId === null || !isString(value.quote) || !isText(value.text)) return null
      return { ...head, itemId, kind: 'comment', quote: value.quote, text: value.text, ...sent }
    case 'rerequest':
      return {
        ...head,
        kind: 'rerequest',
        ...(logins === undefined ? {} : { logins: [...logins] }),
      }
    default:
      return null
  }
}

// An outbox is whole or null. A bad part, also one bad post, gives null: Bifrost must not send
// a part of a damaged list of writes.
function parseOutbox(value: unknown): Outbox | null {
  if (!isObject(value) || !isObjectId(value.headSha) || !isObjectId(value.mergeBase)) return null
  if (!isNumber(value.startedAt) || !isObject(value.seen) || !Array.isArray(value.posts)) {
    return null
  }
  const seen = itemTimes(value.seen)
  if (Object.keys(seen).length !== Object.keys(value.seen).length) return null
  const posts: Post[] = []
  const ids = new Set<string>()
  for (const entry of value.posts) {
    const post = parsePost(entry)
    if (post === null || ids.has(post.id)) return null
    ids.add(post.id)
    posts.push(post)
  }
  return {
    headSha: value.headSha,
    mergeBase: value.mergeBase,
    posts,
    seen,
    startedAt: value.startedAt,
  }
}

// A question over MAX_QUESTION, a where over MAX_WHERE or an answer over MAX_ANSWER gives null.
function parseQuestion(value: unknown): Question | null {
  if (!isObject(value) || !isString(value.question) || !isString(value.where)) return null
  if (value.question.length > MAX_QUESTION || value.where.length > MAX_WHERE) return null
  if (!isNumber(value.at) || !isNumber(value.seenUntil)) return null
  const { answer } = value
  if (answer !== null && (!isString(answer) || answer.length > MAX_ANSWER)) return null
  const question: Question = {
    answer,
    at: value.at,
    question: value.question,
    seenUntil: value.seenUntil,
    where: value.where,
  }
  // A bad quote field goes. The question stays.
  if (isString(value.author) && value.author.length <= MAX_AUTHOR) question.author = value.author
  if (isString(value.body) && value.body.length <= MAX_QUOTE) question.body = value.body
  const url = githubCommentUrl(value.url)
  if (url !== null) question.url = url
  if (value.kind === 'thread' || value.kind === 'comment') question.kind = value.kind
  return question
}

// Keep each valid item ID one time. Keep the newest, up to MAX_HELD.
function parseHeld(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  const list = [...new Set(value.filter(isItemId))]
  return list.length > MAX_HELD ? list.slice(list.length - MAX_HELD) : list
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

// Keep the valid entries. Sort by time. For one key and kind, the entry with the earliest time
// wins. Keep the oldest entries, up to the cap.
function parseQueue(value: unknown): QueueEntry[] {
  if (!Array.isArray(value)) return []
  const valid: QueueEntry[] = []
  for (const entry of value) {
    if (!isObject(entry) || !keyOk(entry.key) || !isJobKind(entry.kind) || !isNumber(entry.at)) {
      continue
    }
    valid.push({ at: entry.at, key: entry.key, kind: entry.kind })
  }
  valid.sort((a, b) => a.at - b.at)
  const seen = new Set<string>()
  const list: QueueEntry[] = []
  for (const entry of valid) {
    const id = `${entry.kind}:${entry.key}`
    if (seen.has(id)) continue
    seen.add(id)
    list.push(entry)
  }
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
  state.outbox = parseOutbox(value.outbox)
  if (isObject(value.questions)) {
    for (const [id, entry] of Object.entries(value.questions)) {
      const question = isItemId(id) ? parseQuestion(entry) : null
      if (question !== null) state.questions[id] = question
    }
  }
  state.held = parseHeld(value.held)
  state.checkedAt = isNumber(value.checkedAt) ? value.checkedAt : null
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
    autoFixConsent: typeof data.autoFixConsent === 'boolean' ? data.autoFixConsent : null,
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
    fixFrom: isNumber(data.fixFrom) ? data.fixFrom : null,
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
