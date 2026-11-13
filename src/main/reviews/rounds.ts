// The runner core (design 11 and 12). It makes the clones of the repositories, keeps the queue
// and the slots, checks the end of each running round, and keeps the sessions of the rounds. The
// steps of a round are in its job: review-job.ts for a review round, request-job.ts for a request
// round. The core picks the job of a queue entry by its kind, and the job of a round by the kind
// of the round.

import { lstatSync } from 'node:fs'
import { type ClaudeState, PR_KEY, REPO_KEY, repoOf, type TrustNeed } from '../../shared/reviews'
import type { Settings } from '../../shared/settings'
import type { SessionRow } from '../../shared/types'
import { messageOf } from '../actions/session-actions'
import { maskToken } from '../log/mask'
import type { DiffFile } from './diff-lines'
import type { Gh } from './gh'
import {
  changePr,
  type EndCheck,
  type Job,
  type JobContext,
  kindOf,
  partsOf,
  type ReadFailure,
  type Recovery,
  resultFileOf,
  rowOf,
} from './jobs'
import { isIgnored } from './model'
import type { PollData, PrData } from './pr-data'
import { enqueue, pickNext } from './queue'
import type { RepoStore } from './repo-store'
import { dropOutbox, dropUnsentOutbox } from './request-job'
import { createReviewJob } from './review-job'
import type { ReviewSessions } from './review-session'
import { REASON_CI_DROPPED, REASON_FORK, REASON_REPLIES_WAITING, trustNotice } from './round-text'
import {
  type ActiveRound,
  emptyPrState,
  handledEntry,
  type JobKind,
  MAX_ANSWER,
  type PrState,
  type Question,
  type QueueEntry,
  type ReviewsState,
  type SessionRef,
} from './state'
import type { ReviewsStateStore } from './state-store'
import { trustedDirs } from './trust'
import type { RequestNotice } from './watcher'

export type { EndCheck } from './jobs'

export const ROUND_LIMIT_MS = 30 * 60_000
export const IDLE_STOP_MS = 10 * 60_000
export const END_SETTLE_MS = 10_000
export const NO_START_MS = 120_000
export const GONE_GRACE_MS = 60_000
export const CLONE_RETRY_MS = 60 * 60_000
// The runner checks each running round at this interval.
export const PASS_MS = 5_000

export const REFUSED_NOT_REVIEWABLE = 'refused: this pull request cannot get a review now'
// A PR with failing CI gets no review (user decision, 2026-11-13).
export const REFUSED_CI_FAILING = 'refused: CI is failing on this pull request'
export const REFUSED_REVIEWS_BUSY = 'refused: reviews are busy'
export const REFUSED_UNKNOWN_REPO = 'refused: unknown repository'
export const REFUSED_NOT_HANDLEABLE = 'refused: this pull request cannot be handled now'
export const REFUSED_UNKNOWN_QUESTION = 'refused: unknown question'
export const REFUSED_BAD_ANSWER = 'refused: bad answer'

const isPromptBox = (row: SessionRow): boolean => row.box === 'red' && row.boxReason === 'prompt'

// rowsSince is the time of the first good registry update after the start of the round, or after
// a restart.
export interface RoundEndInput {
  row: SessionRow | undefined
  seenWorking: boolean
  idleSince: number | null
  startedAt: number
  rowsSince: number
  now: number
  resultExists: boolean
}

// The end check of a running round. The first rule that matches gives the result.
export function roundEnd(o: RoundEndInput): EndCheck {
  // A session of a round must never ask. So a prompt ends the round at once.
  if (o.row !== undefined && isPromptBox(o.row)) return 'blocked'
  if (o.now - o.startedAt >= ROUND_LIMIT_MS) return pastLimit(o)
  if (o.row === undefined) return o.now - o.rowsSince >= GONE_GRACE_MS ? 'gone' : 'wait'
  if (o.row.state === 'working') return 'wait'
  // Idle, parked or an error box.
  if (o.idleSince === null) return 'wait'
  const idle = o.now - o.idleSince
  if (idle >= END_SETTLE_MS && (o.resultExists || o.seenWorking)) return 'ended'
  return idle >= NO_START_MS ? 'ended' : 'wait'
}

// After the time limit, a result file wins over the limit when the session is idle, parked or
// gone. This occurs when Bifrost did not run at the end of the session. The rule waits for the
// settle time of an idle row, and for the grace time of a missing row.
function pastLimit(o: RoundEndInput): EndCheck {
  if (!o.resultExists || o.row?.state === 'working') return 'timeout'
  const settled =
    o.row === undefined
      ? o.now - o.rowsSince >= GONE_GRACE_MS
      : o.idleSince !== null && o.now - o.idleSince >= END_SETTLE_MS
  return settled ? 'ended' : 'wait'
}

export interface RunnerDeps {
  store: ReviewsStateStore
  settings(): Pick<
    Settings,
    | 'reviewsMaxSessions'
    | 'reviewsReviewModel'
    | 'reviewsIgnore'
    | 'reviewsAutoFix'
    | 'reviewsRequestModel'
    | 'reviewsSignedCommits'
  >
  testHome: boolean
  bifrostHome: string
  skillsDir: string
  claudeJson: string
  // The user settings file of Claude Code (claudeSettingsFile). The request job checks it with
  // readUserSandboxProblem before each session start. Bifrost only reads it.
  claudeSettings: string
  repos: RepoStore
  gh: Gh
  sessions: ReviewSessions
  rows(): SessionRow[]
  toReviewPr(key: string): PrData | null
  // The My PRs PR with this key from the last poll, or null.
  minePr(key: string): PrData | null
  viewer(): string | null
  now(): number
  // A change that the panel shows. The caller builds the snapshot again.
  changed(): void
  requestPoll(): void
  notify(n: RequestNotice): void
  log(m: string): void
  // A line for the Event log.
  eventNotice(text: string): void
  // Turn Handle comments automatically off in the settings (ruling S20). The settings effect
  // then calls autoFixChanged(false).
  turnOffAutoFix?(): Promise<void>
  // The jobs of the runner. The default is the review job only.
  jobs?: readonly Job[]
}

// The Claude state of a My PRs row, from the request round, the queue and the PR state.
export interface MineState {
  claude: ClaudeState
  fixing: number
  error: string | null
  sessionId: string | null
}

export interface ReviewRunner {
  start(): void
  stop(): void
  review(key: string): Promise<void>
  // Queue a request round for a PR of the user: all older and held items, or the later Copilot
  // items.
  handle(key: string, what: 'all' | 'copilot'): Promise<void>
  // Send the rest of the outbox of the PR, with no session and no slot. With no outbox, handle
  // all items.
  retry(key: string): Promise<void>
  // Save the answers of the user to the open questions of the PR. A null text means that the user
  // handles the item. One or more texts queue a request round.
  answer(key: string, answers: readonly { id: string; text: string | null }[]): Promise<void>
  // Handle comments on my PRs automatically changed. A turn-on comes after its confirm, so it
  // also saves the consent of ruling S20.
  autoFixChanged(on: boolean): Promise<void>
  // Watch GitHub was turned on. Comments from before wait for Handle now (fixFrom is now).
  watchTurnedOn(): Promise<void>
  mine(key: string): MineState
  // A queue entry of either job. With no entry, the outbox of a request round that stopped: it
  // goes, and its items wait in held.
  cancel(key: string): Promise<void>
  stopSession(key: string): Promise<void>
  onRows(rows: readonly SessionRow[]): void
  afterPoll(poll: PollData): void
  // repo: the repository of a trust step that ended. It gets one start.
  trustChanged(repo?: string): void
  removeClones(): Promise<void>
  session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null
  sessionOf(key: string): string | null
  trust(): TrustNeed[]
  busy(): boolean
  clonePathOf(repo: string): string | null
  // For tests only. Resolves when the background work of the runner ends.
  settled(): Promise<void>
}

// The session references of a PR state: the review session, then the request session.
function refsOf(pr: PrState): { field: 'review' | 'request'; ref: SessionRef }[] {
  const refs: { field: 'review' | 'request'; ref: SessionRef }[] = []
  if (pr.review !== null) refs.push({ field: 'review', ref: pr.review })
  if (pr.request !== null) refs.push({ field: 'request', ref: pr.request })
  return refs
}

// The PR state without the rounds and the sessions of both jobs.
function clearRounds(p: PrState): PrState {
  return {
    ...p,
    actedAt: null,
    lastError: null,
    recommendation: null,
    request: null,
    review: null,
    round: null,
  }
}

// The answer of the job of a saved round at the start.
interface Plan {
  job: Job
  recovery: Recovery
  round: ActiveRound
}

// What the runner knows of a running round. It is not saved, so a restart starts it again.
interface RoundWatch {
  seenWorking: boolean
  idleSince: number | null
  rowsSince: number | null
}

export function createReviewRunner(deps: RunnerDeps): ReviewRunner {
  const { store, repos } = deps
  const jobs: readonly Job[] = deps.jobs ?? [createReviewJob()]
  const jobOf = (kind: JobKind): Job | undefined => jobs.find(job => job.kind === kind)
  let running = false
  // Each start, stop and remove of the clones makes a new generation. The clone order of an older
  // generation ends.
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastPoll: PollData | null = null
  // The clones that the last trust read gave as trusted, by clone path.
  let trusted = new Set<string>()
  let trustChain: Promise<void> = Promise.resolve()
  // The clones where claude refused the start for trust. They stay untrusted until the trust step
  // of the user (trustChanged), so a refused start does not run again at each poll.
  const refused = new Set<string>()
  // The clones where a session of a round started. Claude Code trusts them, so they count as
  // trusted also when the trust read says no.
  const startedIn = new Set<string>()
  // The clones that get one start although the trust read says no: after a Review click or after
  // the trust step. The trust error of that start is the real check.
  const tryOnce = new Set<string>()
  // The keys of the rounds whose session start runs now.
  const starting = new Set<string>()
  // The clone order: repository keys, one clone at a time.
  const order: string[] = []
  let cloning = false
  // The repositories whose clone runs now, with the count of the clone calls.
  const clonesNow = new Map<string, number>()
  // The time of the last failed clone of each repository.
  const failedAt = new Map<string, number>()
  // One token for each round that this process runs. A step of a round whose token changed
  // stops, and it saves and posts nothing.
  const tokens = new Map<string, number>()
  let tokenCount = 0
  // The diff files of each running round. The session can change the files in its input folder,
  // so the check of the result uses these.
  const diffs = new Map<string, DiffFile[]>()
  const watches = new Map<string, RoundWatch>()
  // The rounds whose end, or whose resume, runs now.
  const ending = new Set<string>()
  // The rounds that go on after a restart (Job.resume). A resume can post, so each one waits for
  // a poll that gives the viewer and lists its PR as open.
  const resumes = new Map<string, { job: Job; token: number; round: ActiveRound }>()
  // The sessions that got the idle stop, by row ID.
  const idleStopped = new Set<string>()
  // The names of late sessions that no PR state holds any more: a start gave no row in time, and
  // then the request went or a new round replaced the session. When the row of such a session
  // shows, Bifrost removes the session. No new session gets one of these names. The list is not
  // saved.
  const late = new Set<string>()
  const work = new Set<Promise<unknown>>()
  let pumping = false
  let pumpAgain = false
  let removing = false
  let lastSessions = ''

  // Run a task in the background. A failure goes to the log.
  function bg(task: Promise<unknown>): void {
    const done: Promise<unknown> = task.catch(error => {
      deps.log(`The round runner failed: ${messageOf(error)}`)
    })
    work.add(done)
    void done.finally(() => work.delete(done))
  }

  const alive = (key: string, token: number): boolean => tokens.get(key) === token

  // Forget the memory of the round of the key.
  function forget(key: string): void {
    tokens.delete(key)
    diffs.delete(key)
    watches.delete(key)
    ending.delete(key)
    resumes.delete(key)
  }

  // Forget the memory of a round, when the token is still the token of that round.
  function release(key: string, token: number): void {
    if (alive(key, token)) forget(key)
  }

  function cloneOfRepo(repo: string): string | null {
    const { owner, name } = partsOf(repo)
    try {
      return repos.cloneOf(owner, name)
    } catch {
      return null
    }
  }

  const isTrusted = (clone: string): boolean =>
    (trusted.has(clone) || startedIn.has(clone)) && !refused.has(clone)

  // An entry is ready when its key has no round, and its clone does not exist yet, is trusted,
  // or gets one start (tryOnce).
  function ready(key: string): boolean {
    if (store.get().prs[key]?.round != null) return false
    const clone = cloneOfRepo(repoOf(key))
    return clone === null || isTrusted(clone) || tryOnce.has(clone)
  }

  function recentlyFailed(repo: string): boolean {
    const at = failedAt.get(repo)
    return at !== undefined && deps.now() - at < CLONE_RETRY_MS
  }

  const isCloning = (repo: string): boolean => {
    const name = repo.toLowerCase()
    return order.includes(name) || clonesNow.has(name)
  }

  // The repositories of the last poll, without the ignored ones, in the order of the poll.
  function pollRepos(): string[] {
    if (lastPoll === null) return []
    const ignore = deps.settings().reviewsIgnore
    const list: string[] = []
    for (const pr of [...lastPoll.toReview, ...lastPoll.mine]) {
      if (isIgnored(pr.owner, pr.repo, ignore)) continue
      const repo = repoOf(pr.key)
      if (!list.includes(repo)) list.push(repo)
    }
    return list
  }

  // The repositories of the last poll, of the queue and of the rounds.
  function knownRepos(): string[] {
    const s = store.get()
    const all = new Set(pollRepos())
    for (const entry of s.queue) all.add(repoOf(entry.key))
    for (const [key, pr] of Object.entries(s.prs)) if (pr.round !== null) all.add(repoOf(key))
    return [...all]
  }

  function needsTrust(): boolean {
    return knownRepos().some(repo => {
      const clone = cloneOfRepo(repo)
      return clone !== null && !isTrusted(clone)
    })
  }

  // Read the trust of each known clone (one read of ~/.claude.json). The reads run one at a time,
  // so the newest read gives the result. A change runs the pump.
  function readTrust(): Promise<void> {
    const next = trustChain.then(async () => {
      const clones = knownRepos().flatMap(repo => {
        const clone = cloneOfRepo(repo)
        return clone === null ? [] : [clone]
      })
      const found = await trustedDirs(deps.claudeJson, clones)
      const same = found.size === trusted.size && [...found].every(c => trusted.has(c))
      trusted = found
      if (same) return
      deps.changed()
      bg(pump())
    })
    trustChain = next.catch(() => undefined)
    return next
  }

  // After the set-up, a new clone that needs trust gets one notification.
  async function noticeIfNeeded(repo: string, clone: string): Promise<void> {
    if (isTrusted(clone)) return
    const s = store.get()
    if (s.setUpAt === null || s.repos[repo]?.trustNotifiedAt != null) return
    const at = deps.now()
    let sent = false
    await store.change(x => {
      if (x.setUpAt === null || x.repos[repo]?.trustNotifiedAt != null) return x
      sent = true
      return { ...x, repos: { ...x.repos, [repo]: { trustNotifiedAt: at } } }
    })
    if (sent) deps.notify(trustNotice(repo))
  }

  // Make the clone of a repository. A failure logs one line for each repository until a clone
  // works again, then throws. After the clone, read the trust and apply the notification rule.
  async function cloneRepo(repo: string): Promise<string> {
    const { owner, name } = partsOf(repo)
    const gen = generation
    const busy = repo.toLowerCase()
    clonesNow.set(busy, (clonesNow.get(busy) ?? 0) + 1)
    let clone: string
    try {
      clone = await repos.ensureClone(owner, name)
    } catch (error) {
      if (!failedAt.has(repo)) deps.log(`The clone of ${repo} failed. ${messageOf(error)}`)
      failedAt.set(repo, deps.now())
      throw error
    } finally {
      const left = (clonesNow.get(busy) ?? 1) - 1
      if (left > 0) clonesNow.set(busy, left)
      else clonesNow.delete(busy)
    }
    failedAt.delete(repo)
    if (gen === generation) {
      await readTrust()
      await noticeIfNeeded(repo, clone)
      deps.changed()
    }
    return clone
  }

  // The set-up ends when its clone order is empty: read the trust, then save setUpAt.
  async function endSetUp(): Promise<void> {
    await readTrust()
    const at = deps.now()
    await store.change(s => (s.setUpAt === null ? { ...s, setUpAt: at } : s))
    deps.changed()
  }

  // Run the clone order, one clone at a time. A clone uses no slot.
  async function runClones(): Promise<void> {
    if (cloning) return
    cloning = true
    const gen = generation
    try {
      while (running && gen === generation) {
        const repo = order.shift()
        if (repo === undefined) break
        if (cloneOfRepo(repo) !== null || recentlyFailed(repo)) continue
        await cloneRepo(repo).catch(() => undefined)
      }
      const s = store.get()
      if (running && gen === generation && s.setUpAt === null && lastPoll !== null) {
        await endSetUp()
      }
    } finally {
      cloning = false
    }
    // A poll of a new generation can add entries while an old order ends.
    if (running && order.length > 0) bg(runClones())
  }

  // The running rounds of all kinds. A round whose session has a red prompt box ends at the next
  // end check, so it does not count.
  function countRunning(s: ReviewsState): number {
    const rows = deps.rows()
    let count = 0
    for (const pr of Object.values(s.prs)) {
      const round = pr.round
      if (round === null) continue
      // A request round that posts has no session that works.
      if (kindOf(round) === 'request' && round.phase === 'posting') continue
      const row =
        round.sessionId === null ? undefined : rows.find(r => r.sessionId === round.sessionId)
      if (row !== undefined && isPromptBox(row)) continue
      count++
    }
    return count
  }

  // Start the oldest ready entries while slots are free. One pump runs at a time. A call during a
  // pump makes the pump run one more time. An entry with no job stays and blocks nothing.
  async function pump(): Promise<void> {
    if (pumping) {
      pumpAgain = true
      return
    }
    pumping = true
    try {
      do {
        pumpAgain = false
        // The rounds wait for the first poll, which gives the viewer.
        if (!running || removing || lastPoll === null || deps.viewer() === null) return
        const s = store.get()
        const picked = pickNext({
          max: deps.settings().reviewsMaxSessions,
          queue: s.queue.filter(entry => jobOf(entry.kind) !== undefined),
          ready,
          running: countRunning(s),
        })
        for (const entry of picked) {
          const job = jobOf(entry.kind)
          if (job !== undefined) await begin(entry, job)
        }
      } while (pumpAgain)
    } finally {
      pumping = false
    }
  }

  // Step 3 starts: save the phase preparing and remove the queue entry.
  async function begin(entry: QueueEntry, job: Job): Promise<void> {
    const { key } = entry
    // A queued review does not start when CI fails before its turn (user decision, 2026-11-13).
    // The entry goes, and the next entry can use the slot.
    if (entry.kind === 'review' && deps.toReviewPr(key)?.ci === 'failing') {
      // The click no longer counts as an action, and the row says why nothing started.
      await store.change(s => ({
        ...changePr(s, key, p => ({ ...p, actedAt: null, lastError: REASON_CI_DROPPED })),
        queue: s.queue.filter(e => !(e.key === key && e.kind === entry.kind)),
      }))
      deps.changed()
      pumpAgain = true
      return
    }
    const token = ++tokenCount
    const now = deps.now()
    let begun = false
    await store.change(s => {
      const queued = s.queue.some(e => e.key === key && e.kind === entry.kind)
      if (!queued || s.prs[key]?.round != null) return s
      begun = true
      // The token is set when the change applies, so a later drop of the key sees it.
      tokens.set(key, token)
      const round: ActiveRound = {
        at: entry.at,
        headSha: null,
        kind: entry.kind,
        phase: 'preparing',
        sessionId: null,
        shortId: null,
        startedAt: now,
        stoppedByUser: false,
      }
      return {
        ...changePr(s, key, p => ({ ...p, round })),
        queue: s.queue.filter(e => !(e.key === key && e.kind === entry.kind)),
      }
    })
    if (!begun) return
    deps.changed()
    bg(job.run(contextOf(job), key, token, entry.at))
  }

  // Change the PR state of a round that is still alive. Give false when the round went.
  async function changeRound(
    key: string,
    token: number,
    fn: (p: PrState) => PrState,
    more: (s: ReviewsState) => ReviewsState = s => s,
  ): Promise<boolean> {
    let done = false
    await store.change(s => {
      if (!alive(key, token)) return s
      done = true
      return more(changePr(s, key, fn))
    })
    return done
  }

  // A failed round saves the error and clears the round. It never posts.
  async function fail(
    key: string,
    token: number,
    message: string,
    fn: (p: PrState) => PrState = p => p,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<void> {
    const saved = await changeRound(
      key,
      token,
      p => ({ ...fn(p), lastError: message, round: null }),
      more,
    )
    release(key, token)
    if (saved) deps.changed()
    bg(pump())
  }

  // A failed read of the pull request. The raw gh line goes to the Event log. The row gets
  // the friendly text.
  async function failRead(
    key: string,
    token: number,
    read: ReadFailure,
    fn?: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<void> {
    if (read.detail !== undefined) {
      deps.eventNotice(
        `Reviews: GitHub couldn't load ${key}. It said: ${maskToken(read.detail, null)}`,
      )
    }
    return await fail(key, token, read.message, fn, more)
  }

  // The entry goes back to the queue with its first time. The row then shows Trust needed.
  async function putBack(key: string, token: number, at: number, kind: JobKind): Promise<void> {
    const saved = await changeRound(
      key,
      token,
      p => ({ ...p, round: null }),
      s => ({ ...s, queue: enqueue(s.queue, { at, key, kind }) }),
    )
    release(key, token)
    if (saved) deps.changed()
    bg(pump())
  }

  // Save the result of a round that worked, and clear the round.
  async function succeed(
    key: string,
    token: number,
    fn: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<boolean> {
    const saved = await changeRound(
      key,
      token,
      p => ({ ...fn(p), lastError: null, round: null }),
      more,
    )
    release(key, token)
    if (saved) deps.changed()
    bg(pump())
    return saved
  }

  async function stopQuietly(shortId: string): Promise<void> {
    try {
      await deps.sessions.stop(shortId)
    } catch (error) {
      deps.log(`Bifrost couldn't stop the PR session ${shortId}. ${messageOf(error)}`)
    }
  }

  // Stop and remove a session. With no short ID, there is nothing to remove. A late session with
  // no row yet keeps its name in late, so it goes when its row shows.
  async function removeSession(ref: SessionRef): Promise<void> {
    const row = rowOf(ref, deps.rows())
    const shortId = ref.shortId ?? row?.shortId
    const sessionId = row?.sessionId ?? ref.sessionId
    if (row === undefined && ref.sessionId === '') {
      late.add(ref.name)
      return
    }
    if (shortId === undefined || sessionId === '') return
    idleStopped.delete(sessionId)
    try {
      await deps.sessions.remove({ name: ref.name, sessionId, shortId })
    } catch (error) {
      deps.log(`Bifrost couldn't remove the PR session ${shortId}. ${messageOf(error)}`)
    }
  }

  async function removeWorktree(clone: string, number: number): Promise<void> {
    try {
      await repos.removeWorktree(clone, number)
    } catch (error) {
      deps.log(`Bifrost couldn't remove the worktree of a pull request. ${messageOf(error)}`)
    }
  }

  // Count the changes of the session in its worktree, then reset and clean it.
  async function clean(clone: string, number: number, head: string | null): Promise<void> {
    if (head === null) return
    try {
      const { changed } = await repos.checkAndClean(clone, number, head)
      if (changed > 0) deps.log(`The PR session changed ${changed} files in its worktree.`)
    } catch (error) {
      deps.log(`Bifrost couldn't clean the worktree of a pull request. ${messageOf(error)}`)
    }
  }

  // The names of the sessions in the registry, and the names of the late sessions. A late session
  // can still show, so a new session never gets its name.
  function namesInUse(): Set<string> {
    const names = new Set<string>(late)
    for (const row of deps.rows()) {
      names.add(row.name)
      names.add(row.claudeName)
    }
    for (const pr of Object.values(store.get().prs)) {
      for (const { ref } of refsOf(pr)) if (ref.sessionId === '') names.add(ref.name)
    }
    return names
  }

  // The context of a job. Only putBack knows the job: it queues the entry with the kind of the
  // job.
  const contexts = new Map<JobKind, JobContext>()
  function contextOf(job: Job): JobContext {
    const known = contexts.get(job.kind)
    if (known !== undefined) return known
    const ctx: JobContext = {
      addLate: name => {
        late.add(name)
      },
      alive,
      changeRound,
      clean,
      cloneOfRepo,
      cloneRepo,
      deps,
      diffs,
      fail,
      failRead,
      forget,
      generation: () => generation,
      isCloning,
      isTrusted,
      markStarting: (key, on) => {
        if (on) starting.add(key)
        else starting.delete(key)
      },
      namesInUse,
      pump,
      putBack: (key, token, at) => putBack(key, token, at, job.kind),
      refusedTrust: clone => {
        refused.add(clone)
        startedIn.delete(clone)
      },
      release,
      removeSession,
      removeWorktree,
      stopped: gen => !running || gen !== generation,
      stopQuietly,
      store,
      succeed,
      takeTryOnce: clone => tryOnce.delete(clone),
      trustedByStart: clone => {
        if (isTrusted(clone)) return
        startedIn.add(clone)
        refused.delete(clone)
        bg(pump())
      },
      watchRound: key => {
        watches.set(key, { idleSince: null, rowsSince: null, seenWorking: false })
      },
    }
    contexts.set(job.kind, ctx)
    return ctx
  }

  function watchOf(key: string): RoundWatch {
    let watch = watches.get(key)
    if (watch === undefined) {
      watch = { idleSince: null, rowsSince: null, seenWorking: false }
      watches.set(key, watch)
    }
    return watch
  }

  function resultExists(key: string): boolean {
    try {
      lstatSync(resultFileOf(deps.bifrostHome, key))
      return true
    } catch {
      return false
    }
  }

  // Step 5: check the end of each running round. The job of the round ends it.
  function pass(rows: readonly SessionRow[]): void {
    const now = deps.now()
    for (const [key, pr] of Object.entries(store.get().prs)) {
      const round = pr.round
      if (round === null || round.phase !== 'running' || ending.has(key)) continue
      const job = jobOf(kindOf(round))
      if (job === undefined) continue
      const token = tokens.get(key)
      if (token === undefined) continue
      const watch = watchOf(key)
      const row =
        round.sessionId === null ? undefined : rows.find(r => r.sessionId === round.sessionId)
      if (row !== undefined) {
        if (row.state === 'working') watch.seenWorking = true
        if (row.state === 'working' || isPromptBox(row)) watch.idleSince = null
        else if (watch.idleSince === null) watch.idleSince = now
      }
      const exists = resultExists(key)
      const check = roundEnd({
        idleSince: watch.idleSince,
        now,
        resultExists: exists,
        row,
        rowsSince: watch.rowsSince ?? now,
        // A session that the user stopped has no more work to wait for.
        seenWorking: watch.seenWorking || round.stoppedByUser,
        startedAt: round.startedAt,
      })
      if (check === 'wait') continue
      // The post needs the viewer of a poll. After a restart, the first poll gives it.
      const posts = check === 'ended' || (check === 'blocked' && exists)
      if (posts && deps.viewer() === null) continue
      ending.add(key)
      bg(job.end(contextOf(job), key, token, check))
    }
  }

  // The keys of a job: a queue entry of its kind, a round of its kind, or a PR state with its
  // session.
  function keysOf(job: Job): Set<string> {
    const s = store.get()
    const keys = new Set<string>()
    for (const [key, pr] of Object.entries(s.prs)) {
      const own = pr.round !== null && kindOf(pr.round) === job.kind
      if (own || pr[job.ref] !== null) keys.add(key)
    }
    for (const entry of s.queue) if (entry.kind === job.kind) keys.add(entry.key)
    return keys
  }

  // Go on with a round of a job after a restart, or at Try again. A throw releases the round, so
  // it does not stay busy for ever.
  function runResume(job: Job, key: string, token: number, round: ActiveRound): void {
    ending.add(key)
    bg(
      job.resume(contextOf(job), key, token, round).catch(error => {
        deps.log(`Bifrost couldn't go on with the round of ${key}. ${messageOf(error)}`)
        release(key, token)
      }),
    )
  }

  // Start each waiting resume whose PR the poll lists. Each list of a poll holds only open PRs.
  function startResumes(poll: PollData): void {
    if (deps.viewer() === null) return
    const listed = new Set([...poll.toReview, ...poll.mine].map(pr => pr.key))
    for (const [key, held] of [...resumes]) {
      if (!listed.has(key)) continue
      resumes.delete(key)
      if (alive(key, held.token)) runResume(held.job, key, held.token, held.round)
    }
  }

  // Step 12 for each job whose list is complete: drop the keys that are not open. Then the waiting
  // resumes, the hook of each job, and the pump.
  async function afterPollJobs(poll: PollData): Promise<void> {
    // A drop that throws stops the drops of its job only.
    for (const job of jobs) {
      try {
        const open = job.openKeys(poll)
        if (open === null) continue
        for (const key of keysOf(job)) if (!open.has(key)) await job.drop(contextOf(job), key)
      } catch (error) {
        deps.log(`The round runner failed: ${messageOf(error)}`)
      }
    }
    startResumes(poll)
    for (const job of jobs) {
      try {
        await job.afterPoll?.(contextOf(job), poll)
      } catch (error) {
        deps.log(`The round runner failed: ${messageOf(error)}`)
      }
    }
    await pump()
  }

  // Step 11: one stop for a session with no round that is idle for IDLE_STOP_MS.
  function idleStops(rows: readonly SessionRow[], now: number): void {
    for (const pr of Object.values(store.get().prs)) {
      if (pr.round !== null) continue
      for (const { ref } of refsOf(pr)) {
        if (ref.sessionId === '') continue
        const row = rows.find(r => r.sessionId === ref.sessionId)
        if (row === undefined) continue
        if (row.state === 'working') {
          idleStopped.delete(row.sessionId)
          continue
        }
        if (row.state !== 'idle' || row.box !== 'none' || idleStopped.has(row.sessionId)) continue
        if (now - row.lastActivity < IDLE_STOP_MS) continue
        const shortId = ref.shortId ?? row.shortId
        if (shortId === undefined) continue
        idleStopped.add(row.sessionId)
        bg(stopQuietly(shortId))
      }
    }
  }

  // A start that gave no row in time keeps the name of the session. When its row shows, the
  // reference gets the row, and the session gets one stop when its round is over.
  function bindLate(rows: readonly SessionRow[]): void {
    for (const [key, pr] of Object.entries(store.get().prs)) {
      for (const { field, ref } of refsOf(pr)) {
        if (ref.sessionId !== '') continue
        const row = rowOf(ref, rows)
        if (row?.shortId === undefined) continue
        const bound: SessionRef = { name: ref.name, sessionId: row.sessionId, shortId: row.shortId }
        bg(bind(key, field, bound))
      }
    }
  }

  async function bind(key: string, field: 'review' | 'request', bound: SessionRef): Promise<void> {
    let done = false
    let stop = false
    await store.change(s => {
      const ref = s.prs[key]?.[field]
      if (ref?.sessionId !== '' || ref.name !== bound.name) return s
      done = true
      stop = s.prs[key]?.round == null
      return changePr(s, key, p => ({ ...p, [field]: bound }))
    })
    if (!done) return
    if (stop && bound.shortId !== undefined) await stopQuietly(bound.shortId)
    deps.changed()
  }

  // Remove each late session whose row shows now.
  function removeLate(rows: readonly SessionRow[]): void {
    for (const name of late) {
      const row = rows.find(r => r.kind === 'owned' && r.claudeName === name)
      if (row?.shortId === undefined) continue
      late.delete(name)
      bg(removeSession({ name, sessionId: row.sessionId, shortId: row.shortId }))
    }
  }

  // The row ID of the session of the PR when it is not parked: the review session, else the
  // request session.
  function sessionOf(key: string): string | null {
    const pr = store.get().prs[key]
    if (pr === undefined) return null
    const first = refsOf(pr)[0]
    if (first === undefined) return null
    const row = rowOf(first.ref, deps.rows())
    return row !== undefined && row.state !== 'parked' ? row.sessionId : null
  }

  // A text of the session IDs of the PRs. A change of it is a change on the panel.
  function sessionsText(): string {
    return Object.entries(store.get().prs)
      .filter(([, pr]) => refsOf(pr).length > 0)
      .map(([key]) => `${key}=${sessionOf(key) ?? ''}`)
      .join('|')
  }

  // A request round or a request entry of the key.
  const requestBusy = (s: ReviewsState, key: string): boolean =>
    s.prs[key]?.round != null || s.queue.some(e => e.key === key && e.kind === 'request')

  // A click gives one start to a clone that the trust read gives as untrusted.
  function giveTryOnce(key: string): void {
    const clone = cloneOfRepo(repoOf(key))
    if (clone !== null && !isTrusted(clone)) tryOnce.add(clone)
  }

  // A round of a job refuses with the code of that job.
  const refusedFor = (round: ActiveRound): string =>
    kindOf(round) === 'request' ? REFUSED_NOT_HANDLEABLE : REFUSED_NOT_REVIEWABLE

  async function handle(key: string, what: 'all' | 'copilot'): Promise<void> {
    if (removing) throw new Error(REFUSED_REVIEWS_BUSY)
    const pr = PR_KEY.test(key) ? deps.minePr(key) : null
    const known = what === 'all' || what === 'copilot'
    if (pr === null || pr.isCrossRepository || !known || requestBusy(store.get(), key)) {
      throw new Error(REFUSED_NOT_HANDLEABLE)
    }
    const now = deps.now()
    const flag = what === 'all' ? { handleOlder: true } : { handleCopilot: true }
    await store.change(s => {
      if (requestBusy(s, key)) throw new Error(REFUSED_NOT_HANDLEABLE)
      return {
        ...changePr(s, key, p => ({ ...p, ...flag, lastError: null })),
        queue: enqueue(s.queue, { at: now, key, kind: 'request' }),
      }
    })
    giveTryOnce(key)
    deps.changed()
    bg(pump())
  }

  // Try again with an outbox: a round in the posting phase sends the rest, as after a restart.
  // It needs no session and no slot. The last poll must give the viewer and list the PR.
  async function retry(key: string): Promise<void> {
    if (removing) throw new Error(REFUSED_REVIEWS_BUSY)
    const outbox = store.get().prs[key]?.outbox ?? null
    if (outbox === null) return handle(key, 'all')
    const job = jobOf('request')
    const listed = PR_KEY.test(key) && deps.minePr(key) !== null && deps.viewer() !== null
    if (job === undefined || !running || !listed || requestBusy(store.get(), key)) {
      throw new Error(REFUSED_NOT_HANDLEABLE)
    }
    const token = ++tokenCount
    const now = deps.now()
    const round: ActiveRound = {
      at: now,
      baseSha: outbox.mergeBase,
      headSha: outbox.headSha,
      items: { ...outbox.seen },
      kind: 'request',
      phase: 'posting',
      sessionId: null,
      shortId: null,
      startedAt: now,
      stoppedByUser: false,
    }
    await store.change(s => {
      if (s.prs[key]?.outbox !== outbox || requestBusy(s, key)) {
        throw new Error(REFUSED_NOT_HANDLEABLE)
      }
      tokens.set(key, token)
      return changePr(s, key, p => ({ ...p, lastError: null, round }))
    })
    deps.changed()
    runResume(job, key, token, round)
  }

  // Check all answers first, so that a bad answer changes nothing.
  async function answer(
    key: string,
    answers: readonly { id: string; text: string | null }[],
  ): Promise<void> {
    if (removing) throw new Error(REFUSED_REVIEWS_BUSY)
    if (answers.length === 0) return
    const now = deps.now()
    let texts = 0
    await store.change(s => {
      const p = s.prs[key] ?? emptyPrState()
      let questions: Record<string, Question> = { ...p.questions }
      const handled = { ...p.handled }
      const ids = new Set<string>()
      texts = 0
      for (const { id, text } of answers) {
        const asked = Object.hasOwn(p.questions, id) ? p.questions[id] : undefined
        if (asked === undefined || asked.answer !== null || ids.has(id)) {
          throw new Error(REFUSED_UNKNOWN_QUESTION)
        }
        ids.add(id)
        if (text === null) {
          // The user handles the item.
          questions = Object.fromEntries(Object.entries(questions).filter(([k]) => k !== id))
          handled[id] = handledEntry(now, asked.seenUntil)
          continue
        }
        const value = typeof text === 'string' ? text.trim() : ''
        if (value.length === 0 || value.length > MAX_ANSWER) throw new Error(REFUSED_BAD_ANSWER)
        questions[id] = { ...asked, answer: value }
        texts++
      }
      // Ruling P12: an answered item leaves held, so the round finds it as work.
      const next = changePr(s, key, x => ({
        ...x,
        handled,
        held: x.held.filter(id => !ids.has(id)),
        questions,
      }))
      if (texts === 0) return next
      return { ...next, queue: enqueue(next.queue, { at: now, key, kind: 'request' }) }
    })
    deps.changed()
    if (texts === 0) return
    giveTryOnce(key)
    bg(pump())
  }

  // The row ID of the request session of the PR when it is not parked.
  function requestSessionOf(pr: PrState | undefined): string | null {
    if (pr?.request == null) return null
    const row = rowOf(pr.request, deps.rows())
    return row !== undefined && row.state !== 'parked' ? row.sessionId : null
  }

  // Step 15. The first match wins.
  function mine(key: string): MineState {
    const s = store.get()
    const pr = s.prs[key]
    const sessionId = requestSessionOf(pr)
    const out = (claude: ClaudeState, fixing = 0, error: string | null = null): MineState => ({
      claude,
      error,
      fixing,
      sessionId,
    })
    if (pr?.round != null) return out('fixing', Object.keys(pr.round.items ?? {}).length)
    if (s.queue.some(e => e.key === key && e.kind === 'request')) {
      const repo = repoOf(key)
      const clone = cloneOfRepo(repo)
      if (clone === null) return out(isCloning(repo) ? 'cloning' : 'queued')
      return out(isTrusted(clone) || tryOnce.has(clone) ? 'queued' : 'trust-needed')
    }
    if (Object.values(pr?.questions ?? {}).some(q => q.answer === null)) return out('needs-you')
    if (pr?.lastError != null) return out('error', 0, pr.lastError)
    if (deps.minePr(key)?.isCrossRepository === true) return out('fork', 0, REASON_FORK)
    return out('waiting')
  }

  function session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null {
    const s = store.get()
    if (s.prs[key]?.round != null) return 'reviewing'
    if (!s.queue.some(e => e.key === key)) return null
    return ready(key) ? 'queued' : 'trust-needed'
  }

  // The answer of the job of each saved round that this process does not run. A round with no job
  // stays as it is. A round that is the same object as in known keeps the answer of known, so the
  // job answers one time for each round.
  function recoveries(s: ReviewsState, known: ReadonlyMap<string, Plan>): Map<string, Plan> {
    const plans = new Map<string, Plan>()
    for (const [key, pr] of Object.entries(s.prs)) {
      const round = pr.round
      if (round === null || tokens.has(key)) continue
      const job = jobOf(kindOf(round))
      if (job === undefined) continue
      const old = known.get(key)
      const recovery = old?.round === round ? old.recovery : job.recover(contextOf(job), key, round)
      plans.set(key, { job, recovery, round })
    }
    return plans
  }

  // Step 13: recover each saved round that this process does not run. Its job tells what to do.
  // The queue and fail results apply in one save, and only these results save, as in R2. After a
  // failed save, those rounds stay as they are until the next start, and the running rounds still
  // get their tokens.
  async function boot(): Promise<void> {
    const first = recoveries(store.get(), new Map())
    const saves = (r: Recovery): boolean => r !== 'wait' && r !== 'resume'
    if ([...first.values()].some(plan => saves(plan.recovery))) {
      try {
        await store.change(s => {
          let next = s
          for (const [key, { job, recovery, round }] of recoveries(s, first)) {
            if (recovery === 'queue') {
              next = changePr(next, key, p => ({ ...p, round: null }))
              const entry: QueueEntry = { at: round.at, key, kind: job.kind }
              next = { ...next, queue: enqueue(next.queue, entry) }
            } else if (typeof recovery === 'object') {
              next = changePr(next, key, p => ({ ...p, lastError: recovery.fail, round: null }))
            }
          }
          return next
        })
      } catch (error) {
        deps.log(`Bifrost couldn't save the rounds at the start. ${messageOf(error)}`)
      }
    }
    for (const [key, { job, recovery, round }] of recoveries(store.get(), first)) {
      if (saves(recovery)) continue
      const token = ++tokenCount
      tokens.set(key, token)
      if (recovery === 'wait') continue
      resumes.set(key, { job, round, token })
    }
    // A poll can come during the start.
    if (lastPoll !== null) startResumes(lastPoll)
    await readTrust()
    deps.changed()
    await pump()
  }

  // The 5 second timer. The next timer comes after the end of each pass.
  function schedule(): void {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      if (!running) return
      try {
        const rows = deps.rows()
        pass(rows)
        // The registry sends rows only when they change, and an idle session changes nothing.
        idleStops(rows, deps.now())
      } catch (error) {
        deps.log(`The round runner failed: ${messageOf(error)}`)
      }
      if (running) schedule()
    }, PASS_MS)
  }

  function onRowsNow(rows: readonly SessionRow[]): void {
    if (!running) return
    const now = deps.now()
    for (const [key, pr] of Object.entries(store.get().prs)) {
      if (pr.round?.phase !== 'running') continue
      const watch = watchOf(key)
      if (watch.rowsSince === null) watch.rowsSince = now
    }
    pass(rows)
    idleStops(rows, now)
    bindLate(rows)
    removeLate(rows)
    const text = sessionsText()
    if (text !== lastSessions) {
      lastSessions = text
      deps.changed()
    }
    // A session that waits for the user frees its slot.
    if (store.get().queue.length > 0) bg(pump())
  }

  function clonePathOf(repo: string): string | null {
    if (!REPO_KEY.test(repo)) return null
    return cloneOfRepo(repo)
  }

  // A round that removeClones cannot drop while the runner is stopped: its session starts, works
  // or ends now.
  function roundBusy(key: string, round: ActiveRound): boolean {
    if (starting.has(key) || ending.has(key)) return true
    if (round.sessionId === null) return false
    return deps.rows().some(r => r.sessionId === round.sessionId && r.state === 'working')
  }

  return {
    afterPoll(poll) {
      lastPoll = poll
      if (!running) return
      // The repositories with no clone join the clone order. While setUpAt is null, the order is
      // the set-up.
      for (const repo of pollRepos()) {
        if (order.includes(repo) || cloneOfRepo(repo) !== null || recentlyFailed(repo)) continue
        order.push(repo)
      }
      bg(runClones())
      if (needsTrust()) bg(readTrust())
      bg(afterPollJobs(poll))
    },

    answer,

    async autoFixChanged(on) {
      const now = deps.now()
      // On: the comments from before wait for Handle now. Off: a running round goes on. The
      // click of Handle now or Handle Copilot comments goes with its entry, as at cancel.
      await store.change(s => {
        if (on) return { ...s, autoFixConsent: true, fixFrom: now }
        let next: ReviewsState = { ...s, queue: s.queue.filter(e => e.kind !== 'request') }
        for (const entry of s.queue) {
          if (entry.kind !== 'request') continue
          next = changePr(next, entry.key, p => ({
            ...p,
            handleCopilot: false,
            handleOlder: false,
          }))
        }
        return next
      })
      deps.changed()
    },

    busy: () => Object.values(store.get().prs).some(pr => pr.round !== null),

    async cancel(key) {
      const s = store.get()
      const round = s.prs[key]?.round
      if (round != null) throw new Error(refusedFor(round))
      if (!s.queue.some(e => e.key === key)) {
        if (s.prs[key]?.outbox == null) return
        // An error row with posts that Bifrost did not send. The user drops them. The error goes
        // with them, and the items wait for Handle now.
        const now = deps.now()
        await store.change(x => {
          const p = x.prs[key]
          if (p?.round != null) throw new Error(refusedFor(p.round))
          if (p?.outbox == null) return x
          return changePr(x, key, q => ({ ...dropOutbox(q, now), lastError: null }))
        })
        deps.changed()
        return
      }
      await store.change(x => {
        const now = x.prs[key]?.round
        if (now != null) throw new Error(refusedFor(now))
        const request = x.queue.some(e => e.key === key && e.kind === 'request')
        const next = { ...x, queue: x.queue.filter(e => e.key !== key) }
        // The click of Handle now or Handle Copilot comments goes with its entry.
        if (!request) return next
        return changePr(next, key, p => ({ ...p, handleCopilot: false, handleOlder: false }))
      })
      deps.changed()
    },

    clonePathOf,

    handle,

    mine,

    onRows(rows) {
      // The registry calls this. A throw must not reach the registry or its other callbacks.
      try {
        onRowsNow(rows)
      } catch {
        deps.log('The round runner failed on a session update.')
      }
    },

    // While the runner runs, each round is busy. While it is stopped (Watch GitHub off), the
    // rounds with no busy session get dropped, so a saved round cannot block this for ever.
    async removeClones() {
      const rounds = Object.entries(store.get().prs).flatMap(([key, pr]) =>
        pr.round === null ? [] : [{ key, round: pr.round }],
      )
      if (removing || rounds.some(r => running || roundBusy(r.key, r.round))) {
        throw new Error(REFUSED_REVIEWS_BUSY)
      }
      removing = true
      generation += 1
      order.length = 0
      // A dropped round stops at its next step.
      for (const { key } of rounds) {
        tokens.delete(key)
        diffs.delete(key)
        watches.delete(key)
        resumes.delete(key)
      }
      try {
        for (const pr of Object.values(store.get().prs)) {
          for (const { ref } of refsOf(pr)) await removeSession(ref)
        }
        await repos.removeAll()
        const now = deps.now()
        // An outbox whose fix is on GitHub stays, and Try again sends the rest of it.
        const keep = (p: PrState): PrState => {
          const next = dropUnsentOutbox(clearRounds(p), now)
          return next.outbox === null ? next : { ...next, lastError: REASON_REPLIES_WAITING }
        }
        await store.change(s => ({
          ...s,
          prs: Object.fromEntries(Object.entries(s.prs).map(([k, p]) => [k, keep(p)])),
          queue: [],
          repos: {},
          setUpAt: null,
        }))
        trusted = new Set()
        refused.clear()
        startedIn.clear()
        tryOnce.clear()
        failedAt.clear()
        idleStopped.clear()
        deps.changed()
      } finally {
        removing = false
      }
    },

    retry,

    async review(key) {
      if (removing) throw new Error(REFUSED_REVIEWS_BUSY)
      const polled = PR_KEY.test(key) ? deps.toReviewPr(key) : null
      if (polled === null || session(key) !== null) throw new Error(REFUSED_NOT_REVIEWABLE)
      if (polled.ci === 'failing') throw new Error(REFUSED_CI_FAILING)
      const now = deps.now()
      // The mark stays until the round ends. The round uses it to find the draft review of
      // Bifrost (isOwnDraft).
      await store.change(s => {
        if (s.prs[key]?.round != null) throw new Error(REFUSED_NOT_REVIEWABLE)
        return {
          ...changePr(s, key, p => ({ ...p, actedAt: now, lastError: null })),
          queue: enqueue(s.queue, { at: now, key, kind: 'review' }),
        }
      })
      // A click gives one start to a clone that the trust read gives as untrusted.
      const clone = cloneOfRepo(repoOf(key))
      if (clone !== null && !isTrusted(clone)) tryOnce.add(clone)
      deps.changed()
      bg(pump())
    },

    session,

    sessionOf,

    async settled() {
      while (work.size > 0) await Promise.allSettled([...work])
    },

    start() {
      if (running) return
      running = true
      generation += 1
      watches.clear()
      bg(boot())
      schedule()
    },

    stop() {
      running = false
      generation += 1
      order.length = 0
      if (timer) clearTimeout(timer)
      timer = null
      lastPoll = null
    },

    async stopSession(key) {
      const pr = store.get().prs[key]
      if (pr?.round != null) {
        let shortId: string | null = null
        await store.change(s => {
          const round = s.prs[key]?.round
          if (round == null) return s
          shortId = round.shortId
          return changePr(s, key, p => ({
            ...p,
            round: p.round === null ? null : { ...p.round, stoppedByUser: true },
          }))
        })
        deps.changed()
        if (shortId !== null) await deps.sessions.stop(shortId)
        return
      }
      const ref = pr?.review ?? pr?.request ?? null
      if (ref === null) return
      const shortId = ref.shortId ?? rowOf(ref, deps.rows())?.shortId
      if (shortId !== undefined) await deps.sessions.stop(shortId)
    },

    trust() {
      if (lastPoll === null) return []
      const ignore = deps.settings().reviewsIgnore
      // A PR that the user removed in Bifrost counts nowhere (ruling B3).
      const { hidden } = store.get()
      const counts = new Map<string, number>()
      for (const pr of [...lastPoll.toReview, ...lastPoll.mine]) {
        if (isIgnored(pr.owner, pr.repo, ignore) || Object.hasOwn(hidden, pr.key)) continue
        const repo = repoOf(pr.key)
        counts.set(repo, (counts.get(repo) ?? 0) + 1)
      }
      const needs: TrustNeed[] = []
      for (const repo of [...counts.keys()].sort()) {
        const clone = cloneOfRepo(repo)
        if (clone !== null && !isTrusted(clone))
          needs.push({ repo, waiting: counts.get(repo) ?? 0 })
      }
      return needs
    },

    trustChanged(repo) {
      refused.clear()
      // The end of the trust step gives one start, also when the trust read says no.
      const clone = repo === undefined ? null : clonePathOf(repo)
      if (clone !== null) tryOnce.add(clone)
      bg(
        readTrust().then(async () => {
          if (clone !== null && isTrusted(clone)) tryOnce.delete(clone)
          deps.changed()
          await pump()
        }),
      )
    },

    async watchTurnedOn() {
      const now = deps.now()
      await store.change(s => ({ ...s, fixFrom: now }))
    },
  }
}
