// The Reviews watcher (Reviews design sections 6, 7 and 8). While Watch GitHub is on, it polls
// GitHub with gh, keeps the Reviews state, and sends each new snapshot to the page.
// It has the shape of the account usage poller: a generation counter, a busy flag, a deadline
// for each poll, and the next poll after the end of a poll.

import { githubCommentUrl } from '../../shared/github-url'
import {
  type ClaudeState,
  EMPTY_REVIEWS,
  PR_KEY,
  REASON_GH_FAILED,
  REASON_GH_TIMEOUT,
  type ReviewsSnapshot,
  type ToReviewRow,
} from '../../shared/reviews'
import type { Settings } from '../../shared/settings'
import { MAX_NOTIFICATIONS } from '../alerts/alert-monitor'
import { type HealthEvents, NO_HEALTH } from '../performance/health-log'
import { REFUSED_NO_DRAFT } from './draft-panel'
import { type Gh, type GhFailure, ghFailure } from './gh'
import { type ApproveEntry, baselineOf, buildSnapshot, type DraftEntry } from './model'
import type { PollData, PrData, RateLimit } from './pr-data'
import { parsePoll, pollArgs } from './query'
import type { ReviewRunner } from './rounds'
import type { ReviewsState } from './state'
import type { ReviewsStateStore } from './state-store'

// A poll ends at this time, even when gh does not.
export const POLL_DEADLINE_MS = 60_000
// Refresh polls at once, but not more than one time in 5 seconds.
export const REFRESH_GAP_MS = 5_000
export const REFUSED_NO_COMMENT_LINK = 'refused: no GitHub link for this comment'
export const REFUSED_UNKNOWN_PR = 'refused: unknown pull request'
export const REFUSED_REVIEWS_OFF = 'refused: reviews are off'
export const REFUSED_NOT_REMOVABLE = 'refused: only a pull request that others approved can go'

// Bifrost opens only a PR URL that starts with this text.
const GITHUB_URL = 'https://github.com/'

// The state of a My PRs row when no runner gives one.
export const IDLE_MINE: {
  claude: ClaudeState
  fixing: number
  error: string | null
  sessionId: null
} = {
  claude: 'waiting',
  error: null,
  fixing: 0,
  sessionId: null,
}

const THROWN: GhFailure = { availability: 'error', message: REASON_GH_FAILED }
const TIMEOUT: GhFailure = { availability: 'error', message: REASON_GH_TIMEOUT }

// The text of one notification.
export interface RequestNotice {
  title: string
  body: string
}

export interface WatcherDeps {
  gh: Gh
  store: ReviewsStateStore
  // The watcher reads the settings at each use, so a change applies at once.
  settings(): Pick<
    Settings,
    | 'reviewsTeamRequests'
    | 'reviewsIgnore'
    | 'reviewsPollMinutes'
    | 'reviewsPauseMinutes'
    | 'reviewsAutoFix'
  >
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  emit(s: ReviewsSnapshot): void
  // One notification for new direct requests (see requestNotices). The main process decides if
  // it shows.
  notify(notice: RequestNotice): void
  log(m: string): void
  // The health log gets the result of each poll and the stop (P5, P7). The default does nothing.
  health?: Pick<HealthEvents, 'poll' | 'stopped'>
  // The review runner. Without it, no PR has a session.
  reviews?: Pick<ReviewRunner, 'session' | 'sessionOf' | 'trust' | 'afterPoll' | 'mine'>
  // The result of the last Approve click of a PR (approve.ts). Without it, no row has one.
  approval?(key: string): ApproveEntry | null
  // The result of the last action of the Review panel for a PR (draft-panel.ts).
  draft?(key: string): DraftEntry | null
}

export interface ReviewsWatcher {
  // Emit 'starting' and poll at once. A second call does nothing.
  start(): void
  // End the polling and emit EMPTY_REVIEWS.
  stop(): void
  // Poll now, but not during a poll and not within REFRESH_GAP_MS of the last poll.
  requestPoll(): void
  // Build the snapshot again from the last poll data, with no gh call.
  rebuild(): void
  // The poll interval changed. Set the next poll again: the new interval after the end of the
  // last poll, or at once when that time is past. During a poll, the end of the poll does this.
  reschedule(): void
  current(): ReviewsSnapshot
  // Stop the flash of a To review row for the pause time. A key that is not a To review row of
  // the current snapshot gets REFUSED_UNKNOWN_PR.
  pause(key: string): Promise<void>
  // End the pause of a To review row now. The same refusal as pause.
  endPause(key: string): Promise<void>
  // Hide an approved-by-others row in Bifrost (ruling B3). Nothing changes on GitHub. Another row
  // gets REFUSED_NOT_REMOVABLE.
  remove(key: string): Promise<void>
  // The URL of the PR from the last poll, or null. Only a URL that starts with
  // https://github.com/.
  urlOf(key: string): string | null
  // The GraphQL rate limit of the last good poll, or null (P11). It is null before the first good
  // poll, after a good poll with no rate limit, and after stop.
  rateLimit(): RateLimit | null
  // The To review PR with this key from the last poll, or null.
  toReviewPr(key: string): PrData | null
  // The My PRs PR with this key from the last poll, or null.
  minePr(key: string): PrData | null
  // The login of the user from the last poll, or null before the first good poll and after stop.
  viewer(): string | null
  // The start time of the last good poll, or 0 before it.
  pollStartedAt(): number
}

type Outcome = { ok: true; data: PollData } | { ok: false; failure: GhFailure }

// The state after a good poll. arrived holds the To review keys that are new with this poll: a
// key that was not in requests before, or a re-request. changed is false when the poll changes
// nothing in the state.
// The first poll after the first turn-on writes the baseline. No key arrives with that poll.
// A key that goes loses its request entry and its pause, so a request that comes back is new.
// Rules for more than 50 requests and for a re-request (final review I3):
// - A key that shows later, with a request from before the turn-on, goes in the baseline. It was
//   beyond the first page at the turn-on.
// - While GitHub has more requests than the first page, a key that is not in the answer can
//   still be open. It keeps its entry and its pause. A partial answer (with errors) does the
//   same, because it can lack PRs that are open.
// - A known key with a request time after its firstSeen is a re-request when the PR is a direct
//   request. It is new again and loses its pause. A team row keeps its pause and its entry.
// firstSeen is never before the request time, so a late local clock cannot give a re-request at
// each poll.
function nextState(
  s: ReviewsState,
  poll: PollData,
  now: number,
): { state: ReviewsState; arrived: Set<string>; changed: boolean } {
  const first = s.turnedOnAt === null
  const requests: ReviewsState['requests'] = {}
  const arrived = new Set<string>()
  // The PR states that a re-request changes: the mark and the error go.
  const prs: ReviewsState['prs'] = { ...s.prs }
  let edited = false
  for (const pr of poll.toReview) {
    const { key } = pr
    const known = s.requests[key]
    const seen = Math.max(now, pr.requestedAt)
    if (first) {
      requests[key] = { baseline: true, firstSeen: known?.firstSeen ?? seen }
    } else if (known === undefined) {
      const baseline = s.turnedOnAt !== null && pr.requestedAt < s.turnedOnAt
      requests[key] = { baseline, firstSeen: seen }
      if (!baseline) arrived.add(key)
    } else if (pr.requestedAt > known.firstSeen && pr.requestedUsers.includes(poll.viewer)) {
      requests[key] = { baseline: false, firstSeen: seen }
      arrived.add(key)
      const old = s.prs[key]
      if (old !== undefined && (old.recommendation !== null || old.lastError !== null)) {
        prs[key] = { ...old, lastError: null, recommendation: null }
      }
    } else {
      requests[key] = known
    }
    if (requests[key] !== known) edited = true
  }
  if (poll.toReviewHasMore || poll.errors.length > 0) {
    for (const [key, known] of Object.entries(s.requests)) {
      if (!Object.hasOwn(requests, key)) requests[key] = known
    }
  }
  const pauses: ReviewsState['pauses'] = {}
  for (const [key, until] of Object.entries(s.pauses)) {
    if (until > now && Object.hasOwn(requests, key) && !arrived.has(key)) pauses[key] = until
  }
  // A removed PR shows again after a new request for the review (ruling B3). A PR that goes from
  // the list (closed, merged, or the request went) loses its entry. A partial answer keeps it.
  const hidden: ReviewsState['hidden'] = {}
  for (const [key, at] of Object.entries(s.hidden)) {
    const pr = poll.toReview.find(p => p.key === key)
    if (pr === undefined ? Object.hasOwn(requests, key) : pr.requestedAt <= at) hidden[key] = at
  }
  const gone = Object.keys(s.requests).some(key => !Object.hasOwn(requests, key))
  const ended = Object.keys(pauses).length !== Object.keys(s.pauses).length
  const cleared = Object.keys(prs).some(key => prs[key] !== s.prs[key])
  const shown = Object.keys(hidden).length !== Object.keys(s.hidden).length
  const changed = first || edited || gone || ended || cleared || shown
  const state: ReviewsState = first
    ? { ...s, baseline: baselineOf(poll).items, hidden, pauses, requests, turnedOnAt: now }
    : { ...s, hidden, pauses, prs, requests }
  return { arrived, changed, state }
}

export function createReviewsWatcher(deps: WatcherDeps): ReviewsWatcher {
  const health = deps.health ?? NO_HEALTH
  let running = false
  let busy = false
  // Each start and each stop makes a new generation. A poll of an old generation sends nothing,
  // changes nothing and sets no timer.
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let pauseTimer: ReturnType<typeof setTimeout> | null = null
  let deadline: ReturnType<typeof setTimeout> | undefined
  // Ends the poll that runs now. stop calls it.
  let endPoll: (() => void) | null = null
  let lastPollAt = Number.NEGATIVE_INFINITY
  // The end of the last poll. The next poll comes the poll interval after it.
  let lastEndAt = Number.NEGATIVE_INFINITY
  let lastPoll: PollData | null = null
  let polledAt: number | null = null
  // The start time of the last good poll.
  let pollStartedAt = 0
  // The failure of the last poll, or null after a good poll.
  let failure: GhFailure | null = null
  // The state of the last good poll when the store could not save it, or null. The snapshot uses
  // it, so a failed save does not change the rows. Without it, each row of the first poll would
  // flash.
  let unsaved: ReviewsState | null = null
  // True after a failed save, until a save works again. One log line for each failure period.
  let saveFailing = false
  // The joined errors of the last partial answer, or null after a poll with no errors.
  let lastErrors: string | null = null
  let snapshot: ReviewsSnapshot = EMPTY_REVIEWS

  function set(next: ReviewsSnapshot): void {
    snapshot = next
    deps.emit(next)
    schedulePauseEnd()
  }

  // The snapshot from the last poll data and the newest state. A failure keeps the rows of the
  // last good poll and gives its own availability and message.
  function build(): ReviewsSnapshot {
    const failed = failure === null ? {} : { ...failure }
    if (lastPoll === null) return { ...EMPTY_REVIEWS, availability: 'starting', ...failed }
    const built = buildSnapshot({
      approval: key => deps.approval?.(key) ?? null,
      claude: key => deps.reviews?.mine(key) ?? IDLE_MINE,
      draft: key => deps.draft?.(key) ?? null,
      now: deps.now(),
      poll: lastPoll,
      pollStartedAt,
      session: key => deps.reviews?.session(key) ?? null,
      sessionOf: key => deps.reviews?.sessionOf(key) ?? null,
      settings: deps.settings(),
      state: unsaved ?? deps.store.get(),
      trust: deps.reviews?.trust() ?? [],
    })
    return { ...built, polledAt, ...failed }
  }

  function pollInterval(): number {
    return deps.settings().reviewsPollMinutes * 60_000
  }

  // The next poll comes the poll interval after the end of the last poll.
  function schedule(): void {
    if (timer) clearTimeout(timer)
    const wait = Math.max(0, lastEndAt + pollInterval() - deps.now())
    timer = setTimeout(() => void poll(), wait)
  }

  function saveWorked(): void {
    saveFailing = false
  }

  function saveFailed(error: unknown): void {
    if (!saveFailing) deps.log(`Bifrost cannot save the Reviews state. ${error}`)
    saveFailing = true
  }

  // When a pause ends, the row flashes again at once. A poll can be minutes away.
  // The wait is at most the poll interval. A pause far in the future or a clock change cannot
  // give a wait above the timer limit, which Node runs after 1 ms.
  function schedulePauseEnd(): void {
    if (pauseTimer) clearTimeout(pauseTimer)
    pauseTimer = null
    if (!running) return
    const ends = snapshot.toReview.flatMap(row =>
      row.state === 'paused' && row.pauseEndsAt !== null ? [row.pauseEndsAt] : [],
    )
    if (ends.length === 0) return
    const gen = generation
    pauseTimer = setTimeout(
      () => {
        pauseTimer = null
        if (running && gen === generation) rebuild()
      },
      Math.min(Math.max(0, Math.min(...ends) - deps.now()), pollInterval()),
    )
  }

  function rebuild(): void {
    if (!running || lastPoll === null) return
    set(build())
  }

  async function fetchPoll(): Promise<Outcome> {
    const result = await deps.gh.run(pollArgs())
    const failed = ghFailure(result)
    if (failed !== null) {
      // gh exits with an error code when GitHub gives errors next to the data. Such a partial
      // answer keeps its data. Each other failure fails the poll (final review M7).
      const partial = result.timedOut ? null : parsePoll(result.stdout)
      if (partial?.ok && partial.data.errors.length > 0) return { data: partial.data, ok: true }
      return { failure: failed, ok: false }
    }
    const parsed = parsePoll(result.stdout)
    if (!parsed.ok) {
      return { failure: { availability: 'error', message: parsed.message }, ok: false }
    }
    return { data: parsed.data, ok: true }
  }

  // Only an error is a failure for the health log. No gh and a logged-out gh give no data (P7).
  function fail(next: GhFailure): void {
    if (failure?.message !== next.message) deps.log(`The Reviews poll failed: ${next.message}`)
    failure = next
    health.poll('reviews', next.availability === 'error' ? 'failed' : 'no-data')
    set(build())
  }

  // Save the state once, then emit the snapshot. Notify the new direct requests that arrived
  // with this poll. A failed save notifies nothing, because the next poll finds the same keys.
  async function apply(gen: number, data: PollData): Promise<void> {
    const now = deps.now()
    let arrived = new Set<string>()
    let computed: ReviewsState | null = null
    let notSaved: ReviewsState | null = null
    const planned = nextState(deps.store.get(), data, now)
    if (planned.changed) {
      try {
        // The function sees the newest state, also a pause that came during the poll.
        await deps.store.change(s => {
          const next = nextState(s, data, now)
          arrived = next.arrived
          computed = next.state
          return next.state
        })
        saveWorked()
      } catch (error) {
        arrived = new Set()
        notSaved = computed ?? planned.state
        saveFailed(error)
      }
    }
    if (!running || gen !== generation) return
    unsaved = notSaved
    lastPoll = data
    polledAt = now
    pollStartedAt = lastPollAt
    failure = null
    health.poll('reviews', 'ok')
    set(build())
    const rows = snapshot.toReview.filter(row => row.state === 'new' && arrived.has(row.key))
    for (const notice of requestNotices(rows)) deps.notify(notice)
    // The runner starts its work at once. A throw of it must not fail the poll.
    try {
      deps.reviews?.afterPoll(data)
    } catch (error) {
      deps.log(`The review runner failed after a poll. ${error}`)
    }
  }

  // Change the state for a pause or the end of a pause. A state that the store could not save
  // gets the same change, so the rows stay correct.
  async function changeState(fn: (s: ReviewsState) => ReviewsState): Promise<void> {
    await deps.store.change(fn)
    saveWorked()
    if (unsaved !== null) unsaved = fn(unsaved)
    rebuild()
  }

  // A poll never lasts longer than the deadline, so a hung gh cannot stop all later polls.
  async function poll(): Promise<void> {
    if (!running || busy) return
    busy = true
    const gen = generation
    lastPollAt = deps.now()
    try {
      const outcome = await Promise.race([
        fetchPoll().catch((): Outcome => ({ failure: THROWN, ok: false })),
        new Promise<Outcome | null>(resolve => {
          endPoll = () => resolve(null)
          deadline = setTimeout(() => resolve({ failure: TIMEOUT, ok: false }), POLL_DEADLINE_MS)
        }),
      ])
      if (outcome === null || !running || gen !== generation) return
      if (outcome.ok) {
        // One log line for each new error text. It has only the messages, no PR text.
        const { errors } = outcome.data
        const text = errors.length > 0 ? errors.join(' | ') : null
        if (text !== null && text !== lastErrors) {
          deps.log(`GitHub gave errors with the Reviews poll: ${text}`)
        }
        lastErrors = text
        await apply(gen, outcome.data)
      } else fail(outcome.failure)
    } catch (error) {
      deps.log(`Bifrost cannot apply the Reviews poll. ${error}`)
    } finally {
      if (gen === generation) {
        clearTimeout(deadline)
        deadline = undefined
        endPoll = null
        busy = false
        lastEndAt = deps.now()
        if (running) schedule()
      }
    }
  }

  function requestRow(key: string): void {
    if (!snapshot.toReview.some(row => row.key === key)) throw new Error(REFUSED_UNKNOWN_PR)
  }

  return {
    current: () => snapshot,
    async endPause(key) {
      requestRow(key)
      await changeState(s => ({
        ...s,
        pauses: Object.fromEntries(Object.entries(s.pauses).filter(([k]) => k !== key)),
      }))
    },
    minePr: key => lastPoll?.mine.find(p => p.key === key) ?? null,
    async pause(key) {
      requestRow(key)
      const until = deps.now() + deps.settings().reviewsPauseMinutes * 60_000
      await changeState(s => ({ ...s, pauses: { ...s.pauses, [key]: until } }))
    },
    pollStartedAt: () => pollStartedAt,
    rateLimit: () => lastPoll?.rateLimit ?? null,
    rebuild,
    async remove(key) {
      const row = snapshot.toReview.find(r => r.key === key)
      if (row?.state !== 'approved-by-others') throw new Error(REFUSED_NOT_REMOVABLE)
      // A request before this time never shows the PR again, also with a late local clock.
      const at = Math.max(deps.now(), row.requestedAt)
      await changeState(s => ({ ...s, hidden: { ...s.hidden, [key]: at } }))
    },
    requestPoll() {
      if (!running || busy) return
      if (deps.now() - lastPollAt < REFRESH_GAP_MS) return
      void poll()
    },
    reschedule() {
      if (!running || busy) return
      schedule()
    },
    start() {
      if (running) return
      running = true
      generation += 1
      set({ ...EMPTY_REVIEWS, availability: 'starting' })
      void poll()
    },
    stop() {
      running = false
      generation += 1
      endPoll?.()
      endPoll = null
      clearTimeout(deadline)
      deadline = undefined
      busy = false
      if (timer) clearTimeout(timer)
      timer = null
      if (pauseTimer) clearTimeout(pauseTimer)
      pauseTimer = null
      lastPollAt = Number.NEGATIVE_INFINITY
      lastEndAt = Number.NEGATIVE_INFINITY
      lastPoll = null
      polledAt = null
      failure = null
      unsaved = null
      lastErrors = null
      // No more polls come. So the failures in a row of Reviews go to 0.
      health.stopped('reviews')
      if (snapshot !== EMPTY_REVIEWS) set(EMPTY_REVIEWS)
    },
    toReviewPr: key => lastPoll?.toReview.find(p => p.key === key) ?? null,
    urlOf(key) {
      if (lastPoll === null) return null
      const pr = [...lastPoll.toReview, ...lastPoll.mine].find(p => p.key === key)
      return pr?.url.startsWith(GITHUB_URL) ? pr.url : null
    },
    viewer: () => lastPoll?.viewer ?? null,
  }
}

// The PR key that the page sent. A value that is not a PR key is not in the list.
export function checkPrKey(value: unknown): string {
  if (typeof value !== 'string' || !PR_KEY.test(value)) throw new Error(REFUSED_UNKNOWN_PR)
  return value
}

// The PR key that the page sent, when it is a To review row of the current snapshot. Else refuse
// with REFUSED_UNKNOWN_PR.
export function toReviewKey(watcher: ReviewsWatcher, value: unknown): string {
  const key = checkPrKey(value)
  if (!watcher.current().toReview.some(row => row.key === key)) {
    throw new Error(REFUSED_UNKNOWN_PR)
  }
  return key
}

// The PR key of a reviews:approve call (ruling A1): exactly one value, the PR key of a To review
// row of the current snapshot. Else refuse with REFUSED_UNKNOWN_PR.
export function approveKey(watcher: ReviewsWatcher, args: readonly unknown[]): string {
  if (args.length !== 1) throw new Error(REFUSED_UNKNOWN_PR)
  return toReviewKey(watcher, args[0])
}

// The PR key of a reviews:remove call (ruling B3): exactly one value, the PR key of an
// approved-by-others row of the current snapshot. Else refuse.
export function removeKey(watcher: ReviewsWatcher, args: readonly unknown[]): string {
  if (args.length !== 1) throw new Error(REFUSED_UNKNOWN_PR)
  const key = toReviewKey(watcher, args[0])
  const row = watcher.current().toReview.find(r => r.key === key)
  if (row?.state !== 'approved-by-others') throw new Error(REFUSED_NOT_REMOVABLE)
  return key
}

// The PR key of a call of the Review panel (ruling B10): count values, the first the PR key of a
// To review row of the current snapshot that offers the panel. The caller checks the other
// values. Else refuse.
export function draftKey(watcher: ReviewsWatcher, args: readonly unknown[], count: number): string {
  if (args.length !== count) throw new Error(REFUSED_UNKNOWN_PR)
  const key = toReviewKey(watcher, args[0])
  const row = watcher.current().toReview.find(r => r.key === key)
  if (row?.draft !== 'ready') throw new Error(REFUSED_NO_DRAFT)
  return key
}

// The watcher while Watch GitHub is on. Else refuse with REFUSED_REVIEWS_OFF.
export function whileOn(watcher: ReviewsWatcher | null): ReviewsWatcher {
  if (watcher === null || watcher.current().availability === 'off') {
    throw new Error(REFUSED_REVIEWS_OFF)
  }
  return watcher
}

// The PR key that the page sent, when it is a row of either tab of the current snapshot. Else
// refuse with REFUSED_UNKNOWN_PR.
export function rowKey(watcher: ReviewsWatcher, value: unknown): string {
  const key = checkPrKey(value)
  const snapshot = watcher.current()
  if (![...snapshot.toReview, ...snapshot.mine].some(row => row.key === key)) {
    throw new Error(REFUSED_UNKNOWN_PR)
  }
  return key
}

// The PR key that the page sent, when it is a My PRs row of the current snapshot. Else refuse
// with REFUSED_UNKNOWN_PR.
export function mineKey(watcher: ReviewsWatcher, value: unknown): string {
  const key = checkPrKey(value)
  if (!watcher.current().mine.some(row => row.key === key)) throw new Error(REFUSED_UNKNOWN_PR)
  return key
}

// The URL that Open on GitHub opens for the key that the page sent. Refuse while the watcher is
// off, and for a key with no PR or no GitHub URL.
export function urlToOpen(watcher: ReviewsWatcher | null, key: unknown): string {
  const url = whileOn(watcher).urlOf(checkPrKey(key))
  if (url === null) throw new Error(REFUSED_UNKNOWN_PR)
  return url
}

// The link that View on GitHub opens for a question of the Answer panel. The page sends the PR
// key and the item ID only. The link is the one that Bifrost saved with the question. Refuse
// while the watcher is off, for an unknown PR or question, and for a link that is not a https
// link on github.com.
export function commentUrlToOpen(
  watcher: ReviewsWatcher | null,
  key: unknown,
  itemId: unknown,
): string {
  const on = whileOn(watcher)
  const prKey = checkPrKey(key)
  const row = on.current().mine.find(r => r.key === prKey)
  const question =
    typeof itemId === 'string' ? row?.questions.find(q => q.id === itemId) : undefined
  if (question === undefined) throw new Error(REFUSED_UNKNOWN_PR)
  const url = githubCommentUrl(question.url)
  if (url === null) throw new Error(REFUSED_NO_COMMENT_LINK)
  return url
}

// The title and the body of the notification of a new review request.
export function requestNotice(row: ToReviewRow): RequestNotice {
  return {
    body: `${row.author} asked for your review: ${row.title}`,
    title: `${row.repo} #${row.number}`,
  }
}

// The notifications for the new requests of one poll. At most MAX_NOTIFICATIONS single
// notifications, as for the boxes. More requests give one summary.
export function requestNotices(rows: readonly ToReviewRow[]): RequestNotice[] {
  if (rows.length <= MAX_NOTIFICATIONS) return rows.map(requestNotice)
  return [{ body: `${rows.length} new review requests`, title: 'Reviews' }]
}
