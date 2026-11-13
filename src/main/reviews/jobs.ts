// The jobs of the runner (design 11 and 12). The runner core in rounds.ts keeps the clones, the
// trust, the queue, the slots, the end check and the sessions. A job holds the steps of one kind
// of round: the review job reviews the PR of another person, and the request job fixes and
// answers the comments on a PR of the user. The core picks the job of a queue entry by its kind,
// and the job of a round by the kind of the round.

import { join } from 'node:path'
import type { SessionRow } from '../../shared/types'
import type { DiffFile } from './diff-lines'
import type { PollData } from './pr-data'
import { clonePath, ioPath } from './repo-paths'
import type { RunnerDeps } from './rounds'
import {
  type ActiveRound,
  emptyPrState,
  type JobKind,
  type PrState,
  type ReviewsState,
  type SessionRef,
} from './state'
import type { ReviewsStateStore } from './state-store'

// blocked: the session shows a permission prompt or a question.
export type EndCheck = 'wait' | 'ended' | 'gone' | 'timeout' | 'blocked'

export type Ended = Exclude<EndCheck, 'wait'>

// What the core does with a saved round that this process does not run, at the start:
// - queue: the entry goes back to the queue with its first time.
// - wait: the end check of the round goes on.
// - resume: the job goes on with the round (Job.resume).
// - fail: the round clears, and the PR gets the reason as its error.
export type Recovery = 'queue' | 'wait' | 'resume' | { fail: string }

// A failed read of GitHub. message is the text of the row. detail is the raw text of gh or
// GitHub, for the Event log only.
export type ReadFailure = { message: string; detail?: string }

// The core functions that a job uses. A token identifies one round of this process. A step of a
// round whose token changed stops, and it saves and posts nothing.
export interface JobContext {
  readonly deps: RunnerDeps
  readonly store: ReviewsStateStore
  // The diff files of each running round, by PR key. The release of the round deletes its entry.
  readonly diffs: Map<string, DiffFile[]>
  alive(key: string, token: number): boolean
  // The generation of the runner now. Each start, stop and remove of the clones changes it.
  generation(): number
  // True when the runner stopped, or started again, after the generation gen.
  stopped(gen: number): boolean
  // Change the PR state of a round that is still alive. Give false when the round went.
  changeRound(
    key: string,
    token: number,
    fn: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<boolean>
  // Clear the round and save the message as the error. fn changes more fields of the PR state,
  // and more changes the state, in the same save.
  fail(
    key: string,
    token: number,
    message: string,
    fn?: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<void>
  // As fail, for a failed read of the pull request. The row gets the message. The raw detail
  // of gh or GitHub goes only to the Event log.
  failRead(
    key: string,
    token: number,
    read: ReadFailure,
    fn?: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<void>
  // Clear the round and the error, after fn and more. Give false when the round went.
  succeed(
    key: string,
    token: number,
    fn: (p: PrState) => PrState,
    more?: (s: ReviewsState) => ReviewsState,
  ): Promise<boolean>
  // The entry goes back to the queue with its first time, with the kind of this job.
  putBack(key: string, token: number, at: number): Promise<void>
  // Forget the memory of a round, when the token is still the token of that round.
  release(key: string, token: number): void
  // Forget the memory of the round of the key, whatever its token. A step of it then stops.
  forget(key: string): void
  cloneRepo(repo: string): Promise<string>
  cloneOfRepo(repo: string): string | null
  isTrusted(clone: string): boolean
  // True when the clone had one start that the trust read does not allow. The start goes.
  takeTryOnce(clone: string): boolean
  // A session started in the clone, so Claude Code trusts the clone.
  trustedByStart(clone: string): void
  // claude refused a start in the clone for trust.
  refusedTrust(clone: string): void
  removeSession(ref: SessionRef): Promise<void>
  removeWorktree(clone: string, number: number): Promise<void>
  // Count the changes of the session in its worktree, then reset and clean it.
  clean(clone: string, number: number, head: string | null): Promise<void>
  stopQuietly(shortId: string): Promise<void>
  // The names of the sessions in the registry, and the names of the late sessions.
  namesInUse(): Set<string>
  // A session that can still show. When its row shows, the core removes the session.
  addLate(name: string): void
  // While on, the session start of the round runs, so removeClones cannot drop the round.
  markStarting(key: string, on: boolean): void
  // The end check of the round starts with no memory of the rows.
  watchRound(key: string): void
  // True while the clone order holds the repository, or while its clone runs.
  isCloning(repo: string): boolean
  pump(): Promise<void>
}

export interface Job {
  kind: JobKind
  // The field of the PR state that holds the session of this job.
  ref: 'review' | 'request'
  // Get the round ready and start its session. The round is in the phase preparing.
  run(ctx: JobContext, key: string, token: number, at: number): Promise<void>
  // The end check of a running round gave a result.
  end(ctx: JobContext, key: string, token: number, check: Ended): Promise<void>
  // At the start, for a saved round with no token. The core asks before it saves, and asks again
  // in the save when the round changed. So it must not change anything.
  recover(ctx: JobContext, key: string, round: ActiveRound): Recovery
  // Go on with a saved round: after a restart when recover gave resume, or at Try again of a
  // request round with an outbox. The core starts it only after a poll that gives the viewer and
  // lists the PR as open.
  resume(ctx: JobContext, key: string, token: number, round: ActiveRound): Promise<void>
  // The open keys of the job in the poll. Null when the poll does not show all of them.
  openKeys(poll: PollData): ReadonlySet<string> | null
  // The PR of the key is not open for this job any more. Stop and remove all of its work.
  drop(ctx: JobContext, key: string): Promise<void>
  // After the drops of each poll, and before the pump.
  afterPoll?(ctx: JobContext, poll: PollData): Promise<void>
}

export interface PrRef {
  owner: string
  repo: string
  number: number
}

// The parts of a PR key (PR_KEY). The poll makes the key with prKey from the same parts.
export function prOf(key: string): PrRef {
  const slash = key.indexOf('/')
  const hash = key.lastIndexOf('#')
  return {
    number: Number(key.slice(hash + 1)),
    owner: key.slice(0, slash),
    repo: key.slice(slash + 1, hash),
  }
}

// The two parts of a repository key (owner/repo).
export function partsOf(repo: string): { owner: string; name: string } {
  const slash = repo.indexOf('/')
  return { name: repo.slice(slash + 1), owner: repo.slice(0, slash) }
}

// The job of a round. A file from R2 has no kind: that is a review round.
export const kindOf = (round: ActiveRound): JobKind => round.kind ?? 'review'

export function changePr(s: ReviewsState, key: string, fn: (p: PrState) => PrState): ReviewsState {
  return { ...s, prs: { ...s.prs, [key]: fn(s.prs[key] ?? emptyPrState()) } }
}

// The row of a session. A reference with an empty session ID comes from a start that gave no row
// in time. Its row has the name of the reference.
export function rowOf(ref: SessionRef, rows: readonly SessionRow[]): SessionRow | undefined {
  if (ref.sessionId !== '') return rows.find(r => r.sessionId === ref.sessionId)
  return rows.find(r => r.kind === 'owned' && r.claudeName === ref.name)
}

// The result file of the round of a PR, in its input folder.
export function resultFileOf(bifrostHome: string, key: string): string {
  const pr = prOf(key)
  return join(ioPath(clonePath(bifrostHome, pr.owner, pr.repo), pr.number), 'result.json')
}
