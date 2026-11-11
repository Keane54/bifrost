// The review runner (design 11 and 12). It makes the clones of the repositories, keeps the queue
// and runs each review round: it gets the worktree and the input files ready, starts a read-only
// review session, waits for the end of the session, checks the result file and writes a pending
// review on GitHub. Only the user submits the review. A failed round never posts, and nothing
// tries a failed round again by itself.

import { lstatSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import {
  PR_KEY,
  prKey,
  REASON_GH_FAILED,
  REPO_KEY,
  repoOf,
  type TrustNeed,
} from '../../shared/reviews'
import type { Settings } from '../../shared/settings'
import type { SessionRow } from '../../shared/types'
import { messageOf } from '../actions/session-actions'
import { type DiffFile, parseDiff } from './diff-lines'
import type { Gh } from './gh'
import { isIgnored } from './model'
import { postPendingReview } from './pending-review'
import type { PollData, PrData } from './pr-data'
import { enqueue, pickNext } from './queue'
import { clonePath, ioPath, isInside } from './repo-paths'
import type { RepoStore } from './repo-store'
import { parseReviewResult, placeComments, readResultFile } from './result-file'
import { REASON_INPUT_FAILED, writeRoundFiles } from './review-input'
import { fetchReviewContext } from './review-query'
import {
  type ReviewSessions,
  reviewPrompt,
  reviewSessionArgs,
  reviewSessionName,
} from './review-session'
import {
  draftNotice,
  REASON_CLOSED_WHILE_POSTING,
  REASON_NO_RESULT,
  REASON_PR_CHANGED,
  REASON_PR_CLOSED,
  REASON_STOPPED,
  REASON_TIMEOUT,
  reasonBadResult,
  reviewedNotice,
  trustNotice,
} from './round-text'
import {
  type ActiveRound,
  type DraftComment,
  emptyPrState,
  MAX_DRAFTS,
  type PrState,
  type QueueEntry,
  type RecommendationMark,
  type ReviewsState,
  type SessionRef,
} from './state'
import type { ReviewsStateStore } from './state-store'
import { trustedDirs } from './trust'
import type { RequestNotice } from './watcher'

export const ROUND_LIMIT_MS = 30 * 60_000
export const IDLE_STOP_MS = 10 * 60_000
export const END_SETTLE_MS = 10_000
export const NO_START_MS = 120_000
export const GONE_GRACE_MS = 60_000
export const CLONE_RETRY_MS = 60 * 60_000
// The runner checks each running round at this interval.
export const PASS_MS = 5_000

export const REFUSED_NOT_REVIEWABLE = 'refused: this pull request cannot get a review now'
export const REFUSED_REVIEWS_BUSY = 'refused: reviews are busy'
export const REFUSED_UNKNOWN_REPO = 'refused: unknown repository'

export type EndCheck = 'wait' | 'ended' | 'gone' | 'timeout'

const isPromptBox = (row: SessionRow): boolean => row.box === 'red' && row.boxReason === 'prompt'

// The end check of a running round. The first rule that matches gives the result.
// rowsSince is the time of the first good registry update after the start of the round, or after
// a restart.
export function roundEnd(o: {
  row: SessionRow | undefined
  seenWorking: boolean
  idleSince: number | null
  startedAt: number
  rowsSince: number
  now: number
  resultExists: boolean
}): EndCheck {
  if (o.now - o.startedAt >= ROUND_LIMIT_MS) return 'timeout'
  if (o.row === undefined) return o.now - o.rowsSince >= GONE_GRACE_MS ? 'gone' : 'wait'
  if (o.row.state === 'working' || isPromptBox(o.row)) return 'wait'
  // Idle, parked or an error box.
  if (o.idleSince === null) return 'wait'
  const idle = o.now - o.idleSince
  if (idle >= END_SETTLE_MS && (o.resultExists || o.seenWorking)) return 'ended'
  return idle >= NO_START_MS ? 'ended' : 'wait'
}

export interface RunnerDeps {
  store: ReviewsStateStore
  settings(): Pick<Settings, 'reviewsMaxSessions' | 'reviewsReviewModel' | 'reviewsIgnore'>
  testHome: boolean
  bifrostHome: string
  skillsDir: string
  claudeJson: string
  repos: RepoStore
  gh: Gh
  sessions: ReviewSessions
  rows(): SessionRow[]
  toReviewPr(key: string): PrData | null
  viewer(): string | null
  now(): number
  // A change that the panel shows. The caller builds the snapshot again.
  changed(): void
  requestPoll(): void
  notify(n: RequestNotice): void
  log(m: string): void
}

export interface ReviewRunner {
  start(): void
  stop(): void
  review(key: string): Promise<void>
  cancel(key: string): Promise<void>
  stopSession(key: string): Promise<void>
  onRows(rows: readonly SessionRow[]): void
  afterPoll(poll: PollData): void
  trustChanged(): void
  removeClones(): Promise<void>
  session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null
  sessionOf(key: string): string | null
  trust(): TrustNeed[]
  busy(): boolean
  clonePathOf(repo: string): string | null
  // Resolves when the background work of the runner ends. Tests use it.
  settled(): Promise<void>
}

interface PrRef {
  owner: string
  repo: string
  number: number
}

// The parts of a PR key (PR_KEY). The poll makes the key with prKey from the same parts.
function prOf(key: string): PrRef {
  const slash = key.indexOf('/')
  const hash = key.lastIndexOf('#')
  return {
    number: Number(key.slice(hash + 1)),
    owner: key.slice(0, slash),
    repo: key.slice(slash + 1, hash),
  }
}

// The two parts of a repository key (owner/repo).
function partsOf(repo: string): { owner: string; name: string } {
  const slash = repo.indexOf('/')
  return { name: repo.slice(slash + 1), owner: repo.slice(0, slash) }
}

function changePr(s: ReviewsState, key: string, fn: (p: PrState) => PrState): ReviewsState {
  return { ...s, prs: { ...s.prs, [key]: fn(s.prs[key] ?? emptyPrState()) } }
}

// The PR state without the fields of the review rounds.
function clearReview(p: PrState): PrState {
  return { ...p, actedAt: null, lastError: null, recommendation: null, review: null, round: null }
}

// The row of a session. A reference with an empty session ID comes from a start that gave no row
// in time. Its row has the name of the reference.
function rowOf(ref: SessionRef, rows: readonly SessionRow[]): SessionRow | undefined {
  if (ref.sessionId !== '') return rows.find(r => r.sessionId === ref.sessionId)
  return rows.find(r => r.kind === 'owned' && r.claudeName === ref.name)
}

// What the runner knows of a running round. It is not saved, so a restart starts it again.
interface RoundWatch {
  seenWorking: boolean
  idleSince: number | null
  rowsSince: number | null
}

type Ended = Exclude<EndCheck, 'wait'>

export function createReviewRunner(deps: RunnerDeps): ReviewRunner {
  const { store, repos } = deps
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
  // The clone order: repository keys, one clone at a time.
  const order: string[] = []
  let cloning = false
  // The time of the last failed clone of each repository.
  const failedAt = new Map<string, number>()
  // One token for each round that this process runs. A step of a round whose token changed
  // stops, and it saves and posts nothing.
  const tokens = new Map<string, number>()
  let tokenCount = 0
  // The diff files of each running round, from writeRoundFiles. The session can change the files
  // in its input folder, so the check of the result uses these.
  const diffs = new Map<string, DiffFile[]>()
  const watches = new Map<string, RoundWatch>()
  // The rounds whose end runs now.
  const ending = new Set<string>()
  // The review sessions that got the idle stop, by row ID.
  const idleStopped = new Set<string>()
  const work = new Set<Promise<unknown>>()
  let pumping = false
  let pumpAgain = false
  let removing = false
  let lastSessions = ''

  // Run a task in the background. A failure goes to the log.
  function bg(task: Promise<unknown>): void {
    const done: Promise<unknown> = task.catch(error => {
      deps.log(`The review runner failed: ${messageOf(error)}`)
    })
    work.add(done)
    void done.finally(() => work.delete(done))
  }

  const alive = (key: string, token: number): boolean => tokens.get(key) === token

  // Forget the memory of a round, when the token is still the token of that round.
  function release(key: string, token: number): void {
    if (!alive(key, token)) return
    tokens.delete(key)
    diffs.delete(key)
    watches.delete(key)
    ending.delete(key)
  }

  function cloneOfRepo(repo: string): string | null {
    const { owner, name } = partsOf(repo)
    try {
      return repos.cloneOf(owner, name)
    } catch {
      return null
    }
  }

  const isTrusted = (clone: string): boolean => trusted.has(clone) && !refused.has(clone)

  // An entry is ready when its clone does not exist yet, or when its clone is trusted.
  function ready(key: string): boolean {
    const clone = cloneOfRepo(repoOf(key))
    return clone === null || isTrusted(clone)
  }

  function recentlyFailed(repo: string): boolean {
    const at = failedAt.get(repo)
    return at !== undefined && deps.now() - at < CLONE_RETRY_MS
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
    let clone: string
    try {
      clone = await repos.ensureClone(owner, name)
    } catch (error) {
      if (!failedAt.has(repo)) deps.log(`The clone of ${repo} failed. ${messageOf(error)}`)
      failedAt.set(repo, deps.now())
      throw error
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

  // Run the clone order, one clone at a time. A clone uses no review slot.
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

  // The running rounds. A round whose session has a red prompt box waits for the user, so it
  // does not count (design 12.4).
  function countRunning(s: ReviewsState): number {
    const rows = deps.rows()
    let count = 0
    for (const pr of Object.values(s.prs)) {
      const round = pr.round
      if (round === null) continue
      const row =
        round.sessionId === null ? undefined : rows.find(r => r.sessionId === round.sessionId)
      if (row !== undefined && isPromptBox(row)) continue
      count++
    }
    return count
  }

  // Start the oldest ready entries while slots are free. One pump runs at a time. A call during a
  // pump makes the pump run one more time.
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
          queue: s.queue,
          ready,
          running: countRunning(s),
        })
        for (const entry of picked) await begin(entry)
      } while (pumpAgain)
    } finally {
      pumping = false
    }
  }

  // Step 3 starts: save the phase preparing and remove the queue entry.
  async function begin(entry: QueueEntry): Promise<void> {
    const { key } = entry
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
    bg(runRound(key, token, entry.at))
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
  async function fail(key: string, token: number, message: string, review?: SessionRef) {
    const saved = await changeRound(key, token, p => ({
      ...p,
      lastError: message,
      round: null,
      ...(review === undefined ? {} : { review }),
    }))
    release(key, token)
    if (saved) deps.changed()
    bg(pump())
  }

  // The entry goes back to the queue with its first time. The row then shows Trust needed.
  async function putBack(key: string, token: number, at: number): Promise<void> {
    const saved = await changeRound(
      key,
      token,
      p => ({ ...p, round: null }),
      s => ({ ...s, queue: enqueue(s.queue, { at, key, kind: 'review' }) }),
    )
    release(key, token)
    if (saved) deps.changed()
    bg(pump())
  }

  // Save the result of a round that worked, and clear the round.
  async function succeed(
    key: string,
    token: number,
    head: string,
    mark: RecommendationMark,
    drafts: DraftComment[],
  ): Promise<boolean> {
    const saved = await changeRound(
      key,
      token,
      p => ({ ...p, lastError: null, lastReviewedCommit: head, recommendation: mark, round: null }),
      s =>
        drafts.length === 0 ? s : { ...s, drafts: [...s.drafts, ...drafts].slice(-MAX_DRAFTS) },
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
      deps.log(`Bifrost couldn't stop the review session ${shortId}. ${messageOf(error)}`)
    }
  }

  // Stop and remove a review session. With no short ID, there is nothing to remove.
  async function removeSession(ref: SessionRef): Promise<void> {
    const row = rowOf(ref, deps.rows())
    const shortId = ref.shortId ?? row?.shortId
    const sessionId = row?.sessionId ?? ref.sessionId
    if (shortId === undefined || sessionId === '') return
    idleStopped.delete(sessionId)
    try {
      await deps.sessions.remove({ name: ref.name, sessionId, shortId })
    } catch (error) {
      deps.log(`Bifrost couldn't remove the review session ${shortId}. ${messageOf(error)}`)
    }
  }

  async function removeWorktree(clone: string, number: number): Promise<void> {
    try {
      await repos.removeWorktree(clone, number)
    } catch (error) {
      deps.log(`Bifrost couldn't remove the worktree of a review. ${messageOf(error)}`)
    }
  }

  // Count the changes of the session in its worktree, then reset and clean it.
  async function clean(clone: string, number: number, head: string | null): Promise<void> {
    if (head === null) return
    try {
      const { changed } = await repos.checkAndClean(clone, number, head)
      if (changed > 0) deps.log(`The review session changed ${changed} files in its worktree.`)
    } catch (error) {
      deps.log(`Bifrost couldn't clean the worktree of a review. ${messageOf(error)}`)
    }
  }

  // The names of the sessions in the registry.
  function namesInUse(): Set<string> {
    const names = new Set<string>()
    for (const row of deps.rows()) {
      names.add(row.name)
      names.add(row.claudeName)
    }
    return names
  }

  // Steps 3 and 4: get the worktree and the input files ready, then start the session.
  async function runRound(key: string, token: number, at: number): Promise<void> {
    const pr = prOf(key)
    let clone: string | null = null
    let prepared = false
    // A round that went (the request went) removes what it made.
    const gone = async (): Promise<void> => {
      if (prepared && clone !== null) await removeWorktree(clone, pr.number)
    }
    try {
      clone = cloneOfRepo(repoOf(key)) ?? (await cloneRepo(repoOf(key)))
      if (!alive(key, token)) return
      const viewer = deps.viewer()
      if (!isTrusted(clone) || viewer === null) return await putBack(key, token, at)
      const first = await fetchReviewContext(deps.gh, pr, viewer)
      if (!alive(key, token)) return
      if (!first.ok) return await fail(key, token, first.message)
      const { context } = first
      if (context.state !== 'OPEN') return await fail(key, token, REASON_PR_CLOSED)
      const fetched = await repos.fetchPr(clone, pr.number, context.baseRef)
      if (!alive(key, token)) return
      if (fetched.head !== context.headSha) return await fail(key, token, REASON_PR_CHANGED)
      const earlier = store.get().prs[key]?.review ?? null
      if (earlier !== null) {
        await removeSession(earlier)
        await changeRound(key, token, p => ({ ...p, review: null }))
      }
      if (!alive(key, token)) return
      const worktree = await repos.prepareWorktree(clone, pr.number, fetched.head)
      prepared = true
      if (!alive(key, token)) return await gone()
      const files = await writeRoundFiles(
        { repos, skillsDir: deps.skillsDir },
        { clone, context, fetched, number: pr.number, viewer },
      )
      if (!alive(key, token)) return await gone()
      if (!files.ok) return await fail(key, token, files.message)
      if (store.get().prs[key]?.round?.stoppedByUser === true) {
        return await fail(key, token, REASON_STOPPED)
      }
      const name = reviewSessionName(pr, namesInUse(), deps.testHome)
      const args = reviewSessionArgs({
        ioDir: ioPath(clone, pr.number),
        model: deps.testHome ? 'haiku' : deps.settings().reviewsReviewModel,
        name,
        pluginDir: deps.skillsDir,
        prompt: reviewPrompt(files.inputFile),
      })
      const started = await deps.sessions.start({ args, cwd: worktree, name })
      if (!alive(key, token)) {
        if (started.ok) {
          await removeSession({ name, sessionId: started.sessionId, shortId: started.shortId })
        }
        return await gone()
      }
      if (!started.ok && started.trust) {
        // A trust error acts as an untrusted clone.
        refused.add(clone)
        return await putBack(key, token, at)
      }
      if (!started.ok) {
        // The session can still run. The name stays, so Bifrost finds its row later.
        await clean(clone, pr.number, fetched.head)
        return await fail(key, token, started.message, { name, sessionId: '' })
      }
      diffs.set(key, files.files)
      watches.set(key, { idleSince: null, rowsSince: null, seenWorking: false })
      const review: SessionRef = { name, sessionId: started.sessionId, shortId: started.shortId }
      const saved = await changeRound(key, token, p => ({
        ...p,
        review,
        round:
          p.round === null
            ? null
            : {
                ...p.round,
                baseSha: fetched.base,
                headSha: fetched.head,
                phase: 'running',
                sessionId: started.sessionId,
                shortId: started.shortId,
              },
      }))
      if (!saved) {
        await removeSession(review)
        return await gone()
      }
      deps.changed()
      // A stop of the user during the start.
      if (store.get().prs[key]?.round?.stoppedByUser === true) await stopQuietly(started.shortId)
    } catch (error) {
      if (alive(key, token)) await fail(key, token, messageOf(error))
      else await gone()
    }
  }

  function watchOf(key: string): RoundWatch {
    let watch = watches.get(key)
    if (watch === undefined) {
      watch = { idleSince: null, rowsSince: null, seenWorking: false }
      watches.set(key, watch)
    }
    return watch
  }

  function resultFile(key: string): string {
    const pr = prOf(key)
    return join(ioPath(clonePath(deps.bifrostHome, pr.owner, pr.repo), pr.number), 'result.json')
  }

  function resultExists(key: string): boolean {
    try {
      lstatSync(resultFile(key))
      return true
    } catch {
      return false
    }
  }

  // Step 5: check the end of each running round.
  function pass(rows: readonly SessionRow[]): void {
    const now = deps.now()
    for (const [key, pr] of Object.entries(store.get().prs)) {
      const round = pr.round
      if (round === null || round.phase !== 'running' || ending.has(key)) continue
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
      const check = roundEnd({
        idleSince: watch.idleSince,
        now,
        resultExists: resultExists(key),
        row,
        rowsSince: watch.rowsSince ?? now,
        // A session that the user stopped has no more work to wait for.
        seenWorking: watch.seenWorking || round.stoppedByUser,
        startedAt: round.startedAt,
      })
      if (check === 'wait') continue
      // The post needs the viewer of a poll. After a restart, the first poll gives it.
      if (check === 'ended' && deps.viewer() === null) continue
      ending.add(key)
      bg(endRound(key, token, check))
    }
  }

  async function endRound(key: string, token: number, check: Ended): Promise<void> {
    const round = store.get().prs[key]?.round
    if (!alive(key, token) || round == null) return
    const pr = prOf(key)
    const clone = clonePath(deps.bifrostHome, pr.owner, pr.repo)
    try {
      if (check === 'timeout' && round.shortId !== null) await stopQuietly(round.shortId)
      // Step 7. The clean comes before the post, so the save of a good round is one step.
      await clean(clone, pr.number, round.headSha)
      if (!alive(key, token)) return
      if (check === 'timeout') return await fail(key, token, REASON_TIMEOUT)
      if (check === 'gone') return await fail(key, token, REASON_STOPPED)
      await finish(key, token, pr, clone)
    } catch (error) {
      if (alive(key, token)) await fail(key, token, messageOf(error))
    }
  }

  // After a restart, make the diff of the round again from the clone, in a folder of Bifrost.
  // Never from the input folder, because the session can change the files there.
  async function rebuildDiff(clone: string, round: ActiveRound): Promise<DiffFile[] | null> {
    if (round.baseSha === undefined || round.headSha === null) return null
    const root = join(deps.bifrostHome, 'reviews')
    let folder: string | null = null
    try {
      await mkdir(root, { mode: 0o700, recursive: true })
      folder = await mkdtemp(join(root, 'diff-'))
      const file = join(folder, 'full.diff')
      await repos.writeDiff(clone, round.baseSha, round.headSha, file, 'merge-base')
      return parseDiff(await readFile(file, 'utf8'))
    } catch (error) {
      deps.log(`Bifrost couldn't make the diff of a review again. ${messageOf(error)}`)
      return null
    } finally {
      if (folder !== null && isInside(root, folder)) {
        await rm(folder, { force: true, recursive: true }).catch(() => undefined)
      }
    }
  }

  // Steps 5 and 6: read and check the result, then post the pending review.
  async function finish(key: string, token: number, pr: PrRef, clone: string): Promise<void> {
    const round = store.get().prs[key]?.round
    if (round == null || round.headSha === null) return await fail(key, token, REASON_NO_RESULT)
    const head = round.headSha
    // The user stopped the review. Nothing goes to GitHub.
    if (round.stoppedByUser) return await fail(key, token, REASON_STOPPED)
    const read = await readResultFile(resultFile(key))
    if (!alive(key, token)) return
    if (!read.ok) {
      const missing = read.reason === 'missing'
      return await fail(key, token, missing ? REASON_NO_RESULT : reasonBadResult(read.reason))
    }
    const files = diffs.get(key) ?? (await rebuildDiff(clone, round))
    if (!alive(key, token)) return
    if (files === null) return await fail(key, token, REASON_INPUT_FAILED)
    const expect = { files, headSha: head, pr: prKey(pr.owner, pr.repo, pr.number) }
    const parsed = parseReviewResult(read.text, expect)
    if (!parsed.ok) return await fail(key, token, reasonBadResult(parsed.reason))
    const { result } = parsed
    const placed = placeComments(result, files)
    const mark = (reviewId: string | null): RecommendationMark => ({
      at: deps.now(),
      headSha: head,
      reviewId,
      value: result.recommendation,
      why: result.why,
    })
    const notice = { number: pr.number, repo: pr.repo }
    if (
      result.recommendation === 'approve' &&
      placed.summary === '' &&
      placed.comments.length === 0
    ) {
      if (await succeed(key, token, head, mark(null), [])) deps.notify(reviewedNotice(notice))
      return
    }
    const posting = await changeRound(key, token, p => ({
      ...p,
      round: p.round === null ? null : { ...p.round, phase: 'posting' },
    }))
    if (!posting) return
    const viewer = deps.viewer()
    if (viewer === null) return await fail(key, token, REASON_GH_FAILED)
    const again = await fetchReviewContext(deps.gh, pr, viewer)
    if (!alive(key, token)) return
    if (!again.ok) return await fail(key, token, again.message)
    if (again.context.state !== 'OPEN') return await fail(key, token, REASON_PR_CLOSED)
    if (store.get().prs[key]?.round?.stoppedByUser === true) {
      return await fail(key, token, REASON_STOPPED)
    }
    // The pending review of the user, if any, comes from this second read. The commit is the
    // reviewed commit, also when the author pushed during the round.
    const outcome = await postPendingReview(deps.gh, {
      comments: placed.comments,
      headSha: head,
      number: pr.number,
      owner: pr.owner,
      pending: again.context.pending,
      repo: pr.repo,
      summary: placed.summary,
    })
    // Any failed post ends the round. The message of an unknown result says that Bifrost cannot
    // tell if GitHub saved the draft. Nothing posts again by itself.
    if (!outcome.ok) return await fail(key, token, outcome.message)
    const at = deps.now()
    const draft = (path: string, line: number, body: string): DraftComment => ({
      at,
      body,
      line,
      path,
      prKey: key,
      reviewId: outcome.reviewId,
    })
    const drafts = placed.comments.map(c => draft(c.path, c.line, c.body))
    if (placed.summary !== '') drafts.push(draft('', 0, placed.summary))
    if (await succeed(key, token, head, mark(outcome.reviewId), drafts)) {
      deps.requestPoll()
      deps.notify(draftNotice(notice, result.recommendation))
    }
  }

  // Step 12: the request of the key went. Stop its round, remove its session, its worktree and
  // its queue entry, and clear its review fields. Nothing posts.
  async function dropKey(key: string): Promise<void> {
    tokens.delete(key)
    diffs.delete(key)
    watches.delete(key)
    ending.delete(key)
    const pr = store.get().prs[key]
    const refs: SessionRef[] = []
    if (pr?.review) refs.push(pr.review)
    const round = pr?.round ?? null
    if (round?.sessionId != null && round.sessionId !== pr?.review?.sessionId) {
      refs.push({
        name: pr?.review?.name ?? '',
        sessionId: round.sessionId,
        ...(round.shortId === null ? {} : { shortId: round.shortId }),
      })
    }
    for (const ref of refs) await removeSession(ref)
    const { number } = prOf(key)
    const clone = cloneOfRepo(repoOf(key))
    if (clone !== null) await removeWorktree(clone, number)
    await store.change(s => {
      tokens.delete(key)
      const p = s.prs[key]
      return {
        ...s,
        prs: p === undefined ? s.prs : { ...s.prs, [key]: clearReview(p) },
        queue: s.queue.filter(e => e.key !== key),
      }
    })
    deps.changed()
  }

  async function dropGone(poll: PollData): Promise<void> {
    const open = new Set(poll.toReview.map(p => p.key))
    const s = store.get()
    const keys = new Set<string>()
    for (const [key, pr] of Object.entries(s.prs)) {
      if (pr.round !== null || pr.review !== null) keys.add(key)
    }
    for (const entry of s.queue) keys.add(entry.key)
    for (const key of keys) if (!open.has(key)) await dropKey(key)
    await pump()
  }

  // Step 11: one stop for a review session with no round that is idle for IDLE_STOP_MS.
  function idleStops(rows: readonly SessionRow[], now: number): void {
    for (const pr of Object.values(store.get().prs)) {
      const ref = pr.review
      if (pr.round !== null || ref === null || ref.sessionId === '') continue
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

  // A start that gave no row in time keeps the name of the session. When its row shows, the
  // reference gets the row, and the session gets one stop when its round is over.
  function bindLate(rows: readonly SessionRow[]): void {
    for (const [key, pr] of Object.entries(store.get().prs)) {
      const ref = pr.review
      if (ref === null || ref.sessionId !== '') continue
      const row = rowOf(ref, rows)
      if (row?.shortId === undefined) continue
      const bound: SessionRef = { name: ref.name, sessionId: row.sessionId, shortId: row.shortId }
      bg(bind(key, bound))
    }
  }

  async function bind(key: string, bound: SessionRef): Promise<void> {
    let done = false
    let stop = false
    await store.change(s => {
      const ref = s.prs[key]?.review
      if (ref?.sessionId !== '' || ref.name !== bound.name) return s
      done = true
      stop = s.prs[key]?.round == null
      return changePr(s, key, p => ({ ...p, review: bound }))
    })
    if (!done) return
    if (stop && bound.shortId !== undefined) await stopQuietly(bound.shortId)
    deps.changed()
  }

  function sessionOf(key: string): string | null {
    const ref = store.get().prs[key]?.review
    if (!ref) return null
    const row = rowOf(ref, deps.rows())
    return row !== undefined && row.state !== 'parked' ? row.sessionId : null
  }

  // A text of the session IDs of the PRs. A change of it is a change on the panel.
  function sessionsText(): string {
    return Object.entries(store.get().prs)
      .filter(([, pr]) => pr.review !== null)
      .map(([key]) => `${key}=${sessionOf(key) ?? ''}`)
      .join('|')
  }

  function session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null {
    const s = store.get()
    if (s.prs[key]?.round != null) return 'reviewing'
    if (!s.queue.some(e => e.key === key)) return null
    return ready(key) ? 'queued' : 'trust-needed'
  }

  // Step 13: recover each saved round that this process does not run.
  async function boot(): Promise<void> {
    const lost = Object.entries(store.get().prs).filter(
      ([key, pr]) => pr.round !== null && pr.round.phase !== 'running' && !tokens.has(key),
    )
    if (lost.length > 0) {
      await store.change(s => {
        let next = s
        for (const [key] of lost) {
          const round = next.prs[key]?.round
          if (round == null || tokens.has(key)) continue
          if (round.phase === 'preparing') {
            next = changePr(next, key, p => ({ ...p, round: null }))
            next = { ...next, queue: enqueue(next.queue, { at: round.at, key, kind: 'review' }) }
          } else if (round.phase === 'posting') {
            next = changePr(next, key, p => ({
              ...p,
              lastError: REASON_CLOSED_WHILE_POSTING,
              round: null,
            }))
          }
        }
        return next
      })
    }
    for (const [key, pr] of Object.entries(store.get().prs)) {
      if (pr.round?.phase === 'running' && !tokens.has(key)) tokens.set(key, ++tokenCount)
    }
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
        pass(deps.rows())
      } catch (error) {
        deps.log(`The review runner failed: ${messageOf(error)}`)
      }
      if (running) schedule()
    }, PASS_MS)
  }

  function clonePathOf(repo: string): string | null {
    if (!REPO_KEY.test(repo)) return null
    return cloneOfRepo(repo)
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
      // Only a complete answer shows that a request went.
      if (!poll.toReviewHasMore && poll.errors.length === 0) bg(dropGone(poll))
      else bg(pump())
    },

    busy: () => Object.values(store.get().prs).some(pr => pr.round !== null),

    async cancel(key) {
      const s = store.get()
      if (s.prs[key]?.round != null) throw new Error(REFUSED_NOT_REVIEWABLE)
      if (!s.queue.some(e => e.key === key)) return
      await store.change(x => {
        if (x.prs[key]?.round != null) throw new Error(REFUSED_NOT_REVIEWABLE)
        return { ...x, queue: x.queue.filter(e => e.key !== key) }
      })
      deps.changed()
    },

    clonePathOf,

    onRows(rows) {
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
      const text = sessionsText()
      if (text !== lastSessions) {
        lastSessions = text
        deps.changed()
      }
      // A session that waits for the user frees its slot.
      if (store.get().queue.length > 0) bg(pump())
    },

    async removeClones() {
      if (removing || Object.values(store.get().prs).some(pr => pr.round !== null)) {
        throw new Error(REFUSED_REVIEWS_BUSY)
      }
      removing = true
      generation += 1
      order.length = 0
      try {
        for (const pr of Object.values(store.get().prs)) {
          if (pr.review !== null) await removeSession(pr.review)
        }
        await repos.removeAll()
        await store.change(s => ({
          ...s,
          prs: Object.fromEntries(Object.entries(s.prs).map(([k, p]) => [k, clearReview(p)])),
          queue: [],
          repos: {},
          setUpAt: null,
        }))
        trusted = new Set()
        refused.clear()
        failedAt.clear()
        idleStopped.clear()
        deps.changed()
      } finally {
        removing = false
      }
    },

    async review(key) {
      if (removing) throw new Error(REFUSED_REVIEWS_BUSY)
      if (!PR_KEY.test(key) || deps.toReviewPr(key) === null || session(key) !== null) {
        throw new Error(REFUSED_NOT_REVIEWABLE)
      }
      const now = deps.now()
      await store.change(s => {
        if (s.prs[key]?.round != null) throw new Error(REFUSED_NOT_REVIEWABLE)
        return {
          ...changePr(s, key, p => ({ ...p, actedAt: now, lastError: null, recommendation: null })),
          queue: enqueue(s.queue, { at: now, key, kind: 'review' }),
        }
      })
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
      const ref = pr?.review ?? null
      if (ref === null) return
      const shortId = ref.shortId ?? rowOf(ref, deps.rows())?.shortId
      if (shortId !== undefined) await deps.sessions.stop(shortId)
    },

    trust() {
      if (lastPoll === null) return []
      const ignore = deps.settings().reviewsIgnore
      const counts = new Map<string, number>()
      for (const pr of [...lastPoll.toReview, ...lastPoll.mine]) {
        if (isIgnored(pr.owner, pr.repo, ignore)) continue
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

    trustChanged() {
      refused.clear()
      bg(
        readTrust().then(async () => {
          deps.changed()
          await pump()
        }),
      )
    },
  }
}
