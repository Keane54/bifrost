// The Reviews watcher (Reviews design sections 6, 7 and 8). While Watch GitHub is on, it polls
// GitHub with gh, keeps the Reviews state, and sends each new snapshot to the page.
// It has the shape of the account usage poller: a generation counter, a busy flag, a deadline
// for each poll, and the next poll after the end of a poll.
import {
  type ClaudeState,
  EMPTY_REVIEWS,
  PR_KEY,
  REASON_GH_TIMEOUT,
  type ReviewsSnapshot,
  type ToReviewRow,
} from '../../shared/reviews'
import type { Settings } from '../../shared/settings'
import { type Gh, type GhFailure, ghFailure } from './gh'
import { baselineOf, buildSnapshot } from './model'
import type { PollData } from './pr-data'
import { parsePoll, pollArgs } from './query'
import type { ReviewsState } from './state'
import type { ReviewsStateStore } from './state-store'

// A poll ends at this time, even when gh does not.
export const POLL_DEADLINE_MS = 60_000
// Refresh polls at once, but not more than one time in 5 seconds.
export const REFRESH_GAP_MS = 5_000
export const REFUSED_UNKNOWN_PR = 'refused: unknown pull request'
export const REFUSED_REVIEWS_OFF = 'refused: reviews are off'

// Bifrost opens only a PR URL that starts with this text.
const GITHUB_URL = 'https://github.com/'

// In R1, no PR has a session (R1-7). R2 and R3 get these values from the sessions.
const R1_CLAUDE: { claude: ClaudeState; fixing: number; error: string | null; sessionId: null } = {
  claude: 'waiting',
  error: null,
  fixing: 0,
  sessionId: null,
}

// ghFailure gives its general text for a failure with no stderr. A throw gets this text.
const THROWN = ghFailure({ code: 1, stderr: '', stdout: '' }) as GhFailure
const TIMEOUT: GhFailure = { availability: 'error', message: REASON_GH_TIMEOUT }

export interface WatcherDeps {
  gh: Gh
  store: ReviewsStateStore
  // The watcher reads the settings at each use, so a change applies at once.
  settings(): Pick<
    Settings,
    'reviewsTeamRequests' | 'reviewsIgnore' | 'reviewsPollMinutes' | 'reviewsPauseMinutes'
  >
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  emit(s: ReviewsSnapshot): void
  // A new direct request arrived. The main process decides if a notification shows.
  notifyRequest(row: ToReviewRow): void
  log(m: string): void
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
  current(): ReviewsSnapshot
  // Stop the flash of a To review row for the pause time. A key that is not a To review row of
  // the current snapshot gets REFUSED_UNKNOWN_PR.
  pause(key: string): Promise<void>
  // End the pause of a To review row now. The same refusal as pause.
  endPause(key: string): Promise<void>
  // The URL of the PR from the last poll, or null. Only a URL that starts with
  // https://github.com/.
  urlOf(key: string): string | null
}

type Outcome = { ok: true; data: PollData } | { ok: false; failure: GhFailure }

// The state after a good poll. arrived holds the To review keys that were not in requests before
// this poll. changed is false when the poll changes nothing in the state.
// The first poll after the first turn-on writes the baseline. No key arrives with that poll.
// A key that goes loses its request entry and its pause, so a request that comes back is new.
function nextState(
  s: ReviewsState,
  poll: PollData,
  now: number,
): { state: ReviewsState; arrived: Set<string>; changed: boolean } {
  const first = s.turnedOnAt === null
  const open = new Set(poll.toReview.map(pr => pr.key))
  const requests: ReviewsState['requests'] = {}
  const arrived = new Set<string>()
  for (const key of open) {
    const known = s.requests[key]
    if (first) requests[key] = { baseline: true, firstSeen: known?.firstSeen ?? now }
    else if (known !== undefined) requests[key] = known
    else {
      requests[key] = { baseline: false, firstSeen: now }
      arrived.add(key)
    }
  }
  const pauses: ReviewsState['pauses'] = {}
  for (const [key, until] of Object.entries(s.pauses)) {
    if (until > now && open.has(key)) pauses[key] = until
  }
  const gone = Object.keys(s.requests).some(key => !open.has(key))
  const ended = Object.keys(pauses).length !== Object.keys(s.pauses).length
  const changed = first || arrived.size > 0 || gone || ended
  const state: ReviewsState = first
    ? { ...s, baseline: baselineOf(poll).items, pauses, requests, turnedOnAt: now }
    : { ...s, pauses, requests }
  return { arrived, changed, state }
}

export function createReviewsWatcher(deps: WatcherDeps): ReviewsWatcher {
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
  let lastPoll: PollData | null = null
  let polledAt: number | null = null
  // The failure of the last poll, or null after a good poll.
  let failure: GhFailure | null = null
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
      claude: () => R1_CLAUDE,
      now: deps.now(),
      poll: lastPoll,
      session: () => null,
      settings: deps.settings(),
      state: deps.store.get(),
    })
    return { ...built, polledAt, ...failed }
  }

  function schedule(): void {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => void poll(), deps.settings().reviewsPollMinutes * 60_000)
  }

  // When a pause ends, the row flashes again at once. A poll can be minutes away.
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
      Math.max(0, Math.min(...ends) - deps.now()),
    )
  }

  function rebuild(): void {
    if (!running || lastPoll === null) return
    set(build())
  }

  async function fetchPoll(): Promise<Outcome> {
    const result = await deps.gh.run(pollArgs())
    const failed = ghFailure(result)
    if (failed !== null) return { failure: failed, ok: false }
    const parsed = parsePoll(result.stdout)
    if (!parsed.ok) {
      return { failure: { availability: 'error', message: parsed.message }, ok: false }
    }
    return { data: parsed.data, ok: true }
  }

  function fail(next: GhFailure): void {
    if (failure?.message !== next.message) deps.log(`The Reviews poll failed: ${next.message}`)
    failure = next
    set(build())
  }

  // Save the state once, then emit the snapshot. Notify each new direct request that arrived
  // with this poll. A failed save notifies nothing, because the next poll finds the same keys.
  async function apply(gen: number, data: PollData): Promise<void> {
    const now = deps.now()
    let arrived = new Set<string>()
    let saved = true
    if (nextState(deps.store.get(), data, now).changed) {
      try {
        // The function sees the newest state, also a pause that came during the poll.
        await deps.store.change(s => {
          const next = nextState(s, data, now)
          arrived = next.arrived
          return next.state
        })
      } catch (error) {
        saved = false
        deps.log(`Bifrost cannot save the Reviews state. ${error}`)
      }
    }
    if (!running || gen !== generation) return
    lastPoll = data
    polledAt = now
    failure = null
    set(build())
    if (!saved) return
    for (const row of snapshot.toReview) {
      if (row.state === 'new' && arrived.has(row.key)) deps.notifyRequest(row)
    }
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
      if (outcome.ok) await apply(gen, outcome.data)
      else fail(outcome.failure)
    } catch (error) {
      deps.log(`Bifrost cannot apply the Reviews poll. ${error}`)
    } finally {
      if (gen === generation) {
        clearTimeout(deadline)
        deadline = undefined
        endPoll = null
        busy = false
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
      await deps.store.change(s => ({
        ...s,
        pauses: Object.fromEntries(Object.entries(s.pauses).filter(([k]) => k !== key)),
      }))
      rebuild()
    },
    async pause(key) {
      requestRow(key)
      const until = deps.now() + deps.settings().reviewsPauseMinutes * 60_000
      await deps.store.change(s => ({ ...s, pauses: { ...s.pauses, [key]: until } }))
      rebuild()
    },
    rebuild,
    requestPoll() {
      if (!running || busy) return
      if (deps.now() - lastPollAt < REFRESH_GAP_MS) return
      void poll()
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
      lastPoll = null
      polledAt = null
      failure = null
      if (snapshot !== EMPTY_REVIEWS) set(EMPTY_REVIEWS)
    },
    urlOf(key) {
      if (lastPoll === null) return null
      const pr = [...lastPoll.toReview, ...lastPoll.mine].find(p => p.key === key)
      return pr?.url.startsWith(GITHUB_URL) ? pr.url : null
    },
  }
}

// The PR key that the page sent. A value that is not a PR key is not in the list.
export function checkPrKey(value: unknown): string {
  if (typeof value !== 'string' || !PR_KEY.test(value)) throw new Error(REFUSED_UNKNOWN_PR)
  return value
}

// The watcher while Watch GitHub is on. Else refuse with REFUSED_REVIEWS_OFF.
export function whileOn(watcher: ReviewsWatcher | null): ReviewsWatcher {
  if (watcher === null || watcher.current().availability === 'off') {
    throw new Error(REFUSED_REVIEWS_OFF)
  }
  return watcher
}

// The URL that Open on GitHub opens for the key that the page sent. Refuse while the watcher is
// off, and for a key with no PR or no GitHub URL.
export function urlToOpen(watcher: ReviewsWatcher | null, key: unknown): string {
  const url = whileOn(watcher).urlOf(checkPrKey(key))
  if (url === null) throw new Error(REFUSED_UNKNOWN_PR)
  return url
}

// The title and the body of the notification of a new review request.
export function requestNotice(row: ToReviewRow): { title: string; body: string } {
  return {
    body: `${row.author} asked for your review: ${row.title}`,
    title: `${row.repo} #${row.number}`,
  }
}
