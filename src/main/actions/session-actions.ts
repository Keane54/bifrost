// The session commands: New session, Stop, Delete, Resume, Resume all, Take control (spec 9.1)
// and Hand over (spec 8 of the skills design).
// The renderer sends session IDs and the New session values only. This module finds the row,
// checks it and makes the claude arguments. It never trusts a PID or a path from the renderer.
// Each command waits for the registry entry. Exit code 0 is not proof of a start (spec 8.9).
import { MAX_TEXT, promptBlocks } from '../../shared/input'
import {
  checkNewSessionSpec,
  type DirInfo,
  isClaudeCommand,
  MAX_NAME,
  type NewSessionSpec,
  PERMISSION_MODES,
  REASON_DIR_MISSING,
  REASON_NO_GIT,
  REASON_PROMPT_FLAG,
  REASON_PROMPT_IS_COMMAND,
  worktreeName,
} from '../../shared/new-session'
import { continueIdOf, currentIdOf, REFUSED_NO_RESUME_ID } from '../../shared/session-ids'
import type {
  DeferredDelete,
  HandOverResult,
  ResumeAllResult,
  SeenCounts,
  SessionRow,
  WorktreeCheck,
} from '../../shared/types'
import { UUID_PATTERN } from '../../shared/uuid'
import { folderSharer, worktreeOf, worktreeRoot } from '../../shared/worktree'
import type { ExecResult, RunClaude } from '../claude/cli'
// A type-only import. hand-over.ts imports handOverArgs from this module, so a value import here
// would make an import cycle.
import type { HandOverRun } from '../handover/hand-over'
import {
  claudeFailure,
  isTrustError,
  type KeptChanges,
  parseKept,
  parseKeptChanges,
  parseShortId,
  SHORT_ID,
  trustMessage,
} from './claude-output'
import { isSafePid } from './process-info'

// The time that Bifrost waits for the entry of a started session.
export const START_TIMEOUT_MS = 30_000
// Take control waits this time for the end of the session process (spec 9.2).
export const END_WAIT_MS = 5000
export const END_POLL_MS = 100
// Delete waits this time for the end of the process after claude stop. claude rm refuses a
// worktree while the process runs (Task 19 bug 1).
export const DELETE_END_WAIT_MS = 15_000
// The time limit of each claude command.
export const RUN_TIMEOUT_MS = 60_000
// The time limit of claude rm. A discard can delete a large worktree, for example one with
// node_modules. A SIGKILL at the limit leaves the worktree half deleted (Task 17 bug 1). So
// claude rm gets SIGTERM at the limit, and never SIGKILL.
export const RM_TIMEOUT_MS = 600_000
// Node waits for the end of the process after the SIGTERM. Bifrost waits this time more. Then the
// Delete fails and frees the lock. The process can still end later. The next poll shows the
// result (controller ruling, Task 18 fix round 1).
export const RM_GRACE_MS = 30_000
const RM_OPTS = { killSignal: 'SIGTERM', timeoutMs: RM_TIMEOUT_MS } as const
// After Take control, the resumed session must still run this time after its process showed.
// A resume can fail just after the start of its process (Task 10 bug 3).
export const RESUME_SETTLE_MS = 3000

// A new session gets a statusLine command that prints nothing (controller ruling, O4). So the
// chat window does not show the statusline of the user. A resume keeps the setting.
// This is one argument. No shell reads it.
export const NO_STATUSLINE_SETTINGS = '{"statusLine":{"type":"command","command":"true"}}'

const UUID = new RegExp(UUID_PATTERN)

export const NO_CLAUDE = 'claude not found'
export const REFUSED_UNKNOWN = 'refused: unknown session'
export const REFUSED_BAD_ID = 'refused: bad session ID'
const REFUSED_LOCKED = 'refused: an action on this session runs'
const REFUSED_RESUME_ALL = 'refused: Resume all runs'
const REFUSED_NOT_CONFIRMED = 'refused: Delete needs a confirmation'
const REFUSED_TAKE_NOT_CONFIRMED = 'refused: Take control needs a confirmation'
const REFUSED_NO_SHORT_ID = 'refused: the session runs and has no short ID'
const REFUSED_BAD_PID = 'refused: bad process ID'
const REFUSED_STOP = 'refused: only an owned session that runs'
export const REFUSED_DELETE_EXTERNAL = 'refused: Bifrost does not delete an external session'
const REFUSED_NOT_PARKED = 'refused: the session is not parked'
// A review session of a PR ran one round. Its next round is a new session.
export const REFUSED_PR_RESUME = 'refused: a review session cannot be resumed'
const REFUSED_NOT_EXTERNAL = 'refused: only an external session'
const REFUSED_WORKING = 'refused: the session is working'
const REFUSED_PROMPT = 'refused: the session has an open prompt'
const REFUSED_NOT_IDLE = 'refused: the session is not idle'
const REFUSED_NO_PID = 'refused: the session has no process ID'
const REFUSED_CHANGED = 'refused: the session process changed'
const REFUSED_BAD_SEEN = 'refused: bad input'
const REFUSED_KEPT = 'refused: claude rm kept the worktree'
const REFUSED_UNCOMMITTED = 'refused: the worktree has uncommitted changes'
const REFUSED_RM_SLOW = 'refused: claude rm took too long'
const REFUSED_WORKTREE_CHANGED = 'refused: the worktree changed after the check'
const REFUSED_NOT_STOPPED = 'refused: the session did not stop'
const REFUSED_NO_MESSAGES = 'refused: the session has no messages yet'
const REASON_NO_SHORT_ID = 'claude --bg did not give a session ID.'
const REASON_CREATING = 'A new session is already starting. Please wait.'
const REASON_NO_CWD = "Bifrost doesn't know the project folder of this session."
const REASON_NOT_RESUMED = 'The session did not start again in 30 seconds.'
const REASON_NOT_ENDED =
  'The session process did not end in 5 seconds. Bifrost did not start a copy of the session.'
const REASON_RESUME_FAILED = 'Claude Code could not resume this session.'
// The text of a failed SIGTERM. It holds no Node error (final review M5).
const REASON_SIGNAL_FAILED = "Bifrost couldn't stop the terminal session. Try again."

// The service rejects waitForRow with this message at the timeout.
const TIMEOUT = 'timeout'

export interface SessionActionDeps {
  rows(): SessionRow[]
  // The claude runner, or null when Bifrost cannot find claude.
  run(): Promise<RunClaude | null>
  // Resolve with the first row that matches. Reject with "timeout" after timeoutMs.
  waitForRow(match: (row: SessionRow) => boolean, timeoutMs: number): Promise<SessionRow>
  markStarted(sessionId: string): void
  markStopped(sessionId: string): void
  forget(sessionId: string): void
  signal(pid: number, signal: 'SIGTERM'): void
  isAlive(pid: number): boolean
  // The executable path of the process, or null when ps cannot read it.
  processName(pid: number): Promise<string | null>
  dirInfo(dir: string): Promise<DirInfo>
  // The unmerged-work check and the HEAD commit of a worktree root (checkWorktreeHead in
  // worktree-check.ts). null means a git failure.
  checkWorktree(worktree: string): Promise<(WorktreeCheck & { head: string }) | null>
  // The count of the changed files that git tracks in a worktree root (trackedChanges in
  // worktree-check.ts). Untracked files do not count. null means a git failure.
  trackedChanges(worktree: string): Promise<number | null>
  // Move the priority and the watchlist entry of the old session to the new session.
  carryOver(fromId: string, toId: string): void
  // Store the worktree root that claude rm names, for a row whose worktree Bifrost does not know.
  rememberWorktree(sessionId: string, worktree: string): void
  // The deferred deletes of Delete (spec 8 of the skills design). defer forgets the row and keeps
  // the entry. deferredIn gives the entries of a worktree root in the order of the defers.
  // dropDeferred removes an entry after a good claude rm. undefer removes an entry, so the session
  // shows again as a parked row.
  defer(entry: DeferredDelete): void
  deferredIn(worktree: string): DeferredDelete[]
  dropDeferred(sessionId: string): void
  undefer(sessionId: string): void
  // True when the transcript of the session has a user message. A read error gives true.
  hasMessages(sessionId: string): Promise<boolean>
  // The hand-over run (createHandOver in hand-over.ts). It gets the checked row and the start of
  // the new session.
  handOver: HandOverRun
}

export interface SessionActions {
  create(spec: unknown): Promise<{ sessionId: string }>
  stop(sessionId: unknown): Promise<void>
  // confirmed must be true. The renderer sets it only after the user accepts the confirmation.
  // seen is the unmerged-work check that the dialog showed, with the worktree of that check, or
  // null when the check failed, found no worktree or did not run.
  remove(sessionId: unknown, confirmed: unknown, seen?: unknown): Promise<void>
  resume(sessionId: unknown): Promise<void>
  resumeAll(): Promise<ResumeAllResult>
  // confirmed must be true, as for remove. Take control ends a terminal process.
  takeControl(sessionId: unknown, confirmed: unknown): Promise<{ sessionId: string }>
  // Move an owned session that runs to a new session with a hand-over note (spec 8).
  handOver(sessionId: unknown): Promise<HandOverResult>
  dirInfo(dir: unknown): Promise<DirInfo>
}

type ResumeRow = Pick<SessionRow, 'currentId' | 'kind' | 'resumeId' | 'sessionId'>

// The fields of a row that claude rm needs. A deferred delete gives them without a row.
type RmRow = Pick<SessionRow, 'cwd' | 'sessionId' | 'worktree'>

// The session ID that Resume and Resume all pass (spec 9.1): the ID that claude --resume needs.
// An owned row uses the resume ID of the registry: the original session ID of the job. A resume
// by the ID after a /clear starts a second job (test of 2026-11-06). So Bifrost refuses when it
// does not know the resume ID yet.
// An external row uses its current ID, as Take control does.
function resumeIdOf(row: ResumeRow): string {
  const id = continueIdOf(row)
  if (id === undefined) throw new Error(REFUSED_NO_RESUME_ID)
  return id
}

// The arguments of "claude --bg --resume" for Resume and Resume all.
// An owned row adds no flag. A resume with a new flag on a stopped background session starts a
// copy with a new session ID. A background session keeps its saved options, so a session that
// Bifrost started keeps the hidden statusline.
// An external row is parked only after a failed Take control. Its last entry was in the
// foreground, so it has no saved options. It gets the Take control arguments, which hide the
// statusline and keep the same session ID.
export function resumeArgs(row: ResumeRow): string[] {
  const id = resumeIdOf(row)
  if (row.kind === 'external') return takeControlArgs(id)
  return ['--bg', '--resume', id]
}

// The arguments of "claude --bg --resume" for Take control (D13).
// Take control only starts from an external session, which runs in the foreground. A foreground
// session has no saved options, so the resume keeps the same session ID and the override works.
export function takeControlArgs(sessionId: string): string[] {
  return ['--bg', '--settings', NO_STATUSLINE_SETTINGS, '--resume', sessionId]
}

// The arguments of "claude --bg" for the New session values.
// The prompt is last, because "--worktree" takes an optional value.
// The permission mode must be in the list. So Bifrost never passes bypassPermissions.
// The prompt cannot start with "-" or be only a command name, so it cannot change the command.
// checkNewSessionSpec refuses these values first. These checks stop a caller that skips it.
// A new session always gets the statusline override (D13).
export function newSessionArgs(spec: NewSessionSpec): string[] {
  if (spec.permissionMode !== '' && !PERMISSION_MODES.includes(spec.permissionMode)) {
    throw new Error('refused: unknown permission mode')
  }
  if (spec.prompt.trimStart().startsWith('-')) throw new Error(REASON_PROMPT_FLAG)
  if (isClaudeCommand(spec.prompt)) throw new Error(REASON_PROMPT_IS_COMMAND)
  const args = ['--bg', '--settings', NO_STATUSLINE_SETTINGS]
  if (spec.worktree) args.push('--worktree', worktreeName(spec.name))
  if (spec.model !== '') args.push('--model', spec.model)
  if (spec.permissionMode !== '') args.push('--permission-mode', spec.permissionMode)
  args.push('--name', spec.name)
  if (spec.prompt !== '') args.push(spec.prompt)
  return args
}

// A model name from the transcript, for example "opus" or "claude-opus-5-5[1m]".
const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._[\]-]{0,99}$/
// The reason of a hand-over prompt that is too long. The prompt holds the note.
const REASON_NOTE_TOO_LONG = 'The note is too long to start a new session with it.'

// The arguments of "claude --bg" for the new session of a hand-over (spec 8, step 5).
// The model and the mode come from the transcript of the old session. So the model must have the
// form of a model name, and only a mode in the list gives the flag. The default mode and
// bypassPermissions give no flag. The name and the prompt get the checks of newSessionArgs.
// The prompt also gets the length limit of the New session prompt (checkNewSessionSpec), with a
// reason about the note.
// The new session uses the folder of the old session. So it gets no --worktree, and no
// --plugin-dir or --resume.
export function handOverArgs(opts: {
  name: string
  model: string
  permissionMode: string | null
  prompt: string
}): string[] {
  if (!MODEL_NAME.test(opts.model)) throw new Error('refused: unknown model')
  const name = opts.name
  const badName =
    name.trim() === '' ||
    name.length > MAX_NAME ||
    /[\r\n]/.test(name) ||
    name.trimStart().startsWith('-')
  if (badName) throw new Error('refused: bad name')
  if (opts.prompt.length > MAX_TEXT) throw new Error(REASON_NOTE_TOO_LONG)
  if (opts.prompt.trimStart().startsWith('-')) throw new Error(REASON_PROMPT_FLAG)
  if (isClaudeCommand(opts.prompt)) throw new Error(REASON_PROMPT_IS_COMMAND)
  const mode = opts.permissionMode
  const modeArgs =
    mode !== null && PERMISSION_MODES.includes(mode) ? ['--permission-mode', mode] : []
  return [
    '--bg',
    '--settings',
    NO_STATUSLINE_SETTINGS,
    '--model',
    opts.model,
    ...modeArgs,
    '--name',
    name,
    opts.prompt,
  ]
}

// The claude runner, or an error when Bifrost cannot find claude.
export async function resolveClaude(deps: Pick<SessionActionDeps, 'run'>): Promise<RunClaude> {
  const run = await deps.run()
  if (!run) throw new Error(NO_CLAUDE)
  return run
}

// A trust error of claude. The message is the instruction for the user.
export class TrustNeededError extends Error {}

// Run a claude command that starts a session in cwd. A trust error gives TrustNeededError.
export async function startRun(
  run: RunClaude,
  args: string[],
  cwd: string,
  what: string,
): Promise<ExecResult> {
  const result = await run(args, { cwd, timeoutMs: RUN_TIMEOUT_MS })
  if (isTrustError(result.stdout) || isTrustError(result.stderr)) {
    throw new TrustNeededError(trustMessage(cwd))
  }
  if (result.code !== 0) throw new Error(claudeFailure(result, what))
  return result
}

// Run "claude --bg" with the arguments in cwd, wait for the entry of the new session and mark
// it as started. New session, Hand over and the review session use this.
export async function startBackground(
  deps: Pick<SessionActionDeps, 'waitForRow' | 'markStarted'>,
  run: RunClaude,
  args: string[],
  cwd: string,
): Promise<{ row: SessionRow; shortId: string }> {
  const result = await startRun(run, args, cwd, 'claude --bg')
  const id = parseShortId(result.stdout)
  if (id === null) throw new Error(REASON_NO_SHORT_ID)
  let row: SessionRow
  try {
    row = await deps.waitForRow(
      r => r.shortId === id && r.kind === 'owned' && r.state !== 'parked' && r.pid !== undefined,
      START_TIMEOUT_MS,
    )
  } catch (error) {
    if (messageOf(error) !== TIMEOUT) throw error
    throw new Error(
      `The session ${id} did not start in 30 seconds. Run claude logs ${id} to see the cause.`,
    )
  }
  deps.markStarted(row.sessionId)
  return { row, shortId: id }
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

// The match for the owned entry of a session that runs again.
function runsOwned(sessionId: string): (row: SessionRow) => boolean {
  return r =>
    r.sessionId === sessionId && r.kind === 'owned' && r.state !== 'parked' && r.pid !== undefined
}

// The short ID of the row. It goes into an argument, so it must match SHORT_ID.
function shortIdOf(row: SessionRow): string {
  if (row.shortId === undefined || !SHORT_ID.test(row.shortId)) throw new Error(REFUSED_BAD_ID)
  return row.shortId
}

// A session ID goes into an argument, so it must be a UUID.
function checkSessionId(id: string): void {
  if (!UUID.test(id)) throw new Error(REFUSED_BAD_ID)
}

// Take control is available only for an external session that is idle or has a yellow box.
// A busy session would stop its work. A red box would lose the open prompt (spec 9.2).
function checkTakeControl(row: SessionRow): void {
  if (row.kind !== 'external' || row.state === 'parked') throw new Error(REFUSED_NOT_EXTERNAL)
  if (row.state === 'working') throw new Error(REFUSED_WORKING)
  if (row.box === 'red') throw new Error(REFUSED_PROMPT)
  const yellow = row.state === 'needs-you' && row.box === 'yellow'
  if (row.state !== 'idle' && !yellow) throw new Error(REFUSED_NOT_IDLE)
}

// The check counts from the renderer. null and a missing value mean that the dialog showed no
// check.
// Each count must be an integer of 0 or more. The worktree of the check must be a string. The
// Delete compares it with the worktree of the row (final review M2).
function seenOf(seen: unknown): SeenCounts | null {
  if (seen === null || seen === undefined) return null
  if (typeof seen !== 'object') throw new Error(REFUSED_BAD_SEEN)
  const { changedFiles, unmergedCommits, worktree } = seen as Record<string, unknown>
  const isCount = (n: unknown): n is number => Number.isSafeInteger(n) && (n as number) >= 0
  if (!isCount(changedFiles) || !isCount(unmergedCommits)) throw new Error(REFUSED_BAD_SEEN)
  if (typeof worktree !== 'string') throw new Error(REFUSED_BAD_SEEN)
  return { changedFiles, unmergedCommits, worktree }
}

// The failure text of a Take control whose resumed session did not stay. claude logs gives the
// cause, and Bifrost does not run it.
function resumeFailed(row: SessionRow | undefined): string {
  const shortId = row?.shortId
  if (shortId === undefined || !SHORT_ID.test(shortId)) return REASON_RESUME_FAILED
  return `${REASON_RESUME_FAILED} Run claude logs ${shortId} to see the cause.`
}

// Remove one "/" at the end of a path.
function withoutSlash(path: string): string {
  return path.endsWith('/') ? path.slice(0, -1) : path
}

// True when the last part of the process path is "claude" (D6).
function isClaudeProcess(name: string | null): boolean {
  return name !== null && name.trim().split('/').pop() === 'claude'
}

export function createSessionActions(deps: SessionActionDeps): SessionActions {
  // The sessions that have a running action. One action at a time runs for each session (D3).
  const busy = new Set<string>()
  let resumingAll = false
  // True while a New session start runs. A double click must not start two sessions.
  let creating = false

  const claude = (): Promise<RunClaude> => resolveClaude(deps)

  // Run fn with the lock of the session. fn gets the current row of the session.
  // The lock check and the lock are in the same synchronous step, so two calls cannot both run.
  const locked = async <T>(sessionId: unknown, fn: (row: SessionRow) => Promise<T>): Promise<T> => {
    if (typeof sessionId !== 'string') throw new Error(REFUSED_UNKNOWN)
    if (busy.has(sessionId)) throw new Error(REFUSED_LOCKED)
    busy.add(sessionId)
    try {
      const row = deps.rows().find(r => r.sessionId === sessionId)
      if (!row) throw new Error(REFUSED_UNKNOWN)
      return await fn(row)
    } finally {
      busy.delete(sessionId)
    }
  }

  // Run a claude command that does not start a session.
  const command = async (run: RunClaude, args: string[], what: string): Promise<void> => {
    const result = await run(args, { timeoutMs: RUN_TIMEOUT_MS })
    if (result.code !== 0) throw new Error(claudeFailure(result, what))
  }

  const checkProjectDir = async (cwd: string): Promise<void> => {
    if (cwd === '') throw new Error(REASON_NO_CWD)
    if (!cwd.startsWith('/') || (await deps.dirInfo(cwd)).kind !== 'dir') {
      throw new Error(`The folder ${cwd} doesn't exist.`)
    }
  }

  // Run claude rm. A timeout gives REFUSED_RM_SLOW, because the output after SIGTERM is not
  // complete. A claude rm that has not ended RM_GRACE_MS after the SIGTERM also gives
  // REFUSED_RM_SLOW. Bifrost then does not use its result.
  const rm = async (run: RunClaude, args: string[]): Promise<ExecResult> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const limit = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(REFUSED_RM_SLOW)), RM_TIMEOUT_MS + RM_GRACE_MS)
    })
    try {
      const result = await Promise.race([run(args, RM_OPTS), limit])
      if (result.timedOut === true) throw new Error(REFUSED_RM_SLOW)
      return result
    } finally {
      clearTimeout(timer)
    }
  }

  // Store the worktree that a kept line names, for a row whose worktree Bifrost does not know.
  // The next Delete can then check this worktree and offer Open worktree. The kept line must
  // name the short ID of the row and a worktree root.
  const rememberKept = (row: RmRow, shortId: string, kept: KeptChanges): void => {
    if (worktreeOf(row) !== null) return
    const keptPath = withoutSlash(kept.worktree)
    const root = worktreeRoot(keptPath)?.worktree
    if (kept.shortId === shortId && root === keptPath) deps.rememberWorktree(row.sessionId, root)
  }

  // Run claude rm. It keeps a worktree that has commits on no remote, and prints the value
  // that discards them (M4 controller check). Bifrost discards only when all of these apply:
  // - The Delete dialog showed a check of the worktree.
  // - The kept text names the short ID of the row and the worktree that Bifrost checks.
  // - A new check after the stop finds no more commits and no more changed files.
  // - The HEAD commit of the worktree is the commit in the discard value.
  // The discard value comes only from parseKept.
  // claude rm also keeps a worktree with changes that are not committed, and gives no discard
  // value (Task 17 bug 2). Claude Code has no command that deletes such a worktree. So Bifrost
  // never tries a discard for it, also when the text has a discard value.
  const removeSession = async (
    run: RunClaude,
    row: RmRow,
    shortId: string,
    seen: SeenCounts | null,
  ): Promise<void> => {
    const result = await rm(run, ['rm', shortId])
    if (result.code === 0) return
    const changes = parseKeptChanges(result.stdout)
    if (changes !== null) {
      rememberKept(row, shortId, changes)
      throw new Error(REFUSED_UNCOMMITTED)
    }
    const kept = parseKept(result.stdout)
    if (kept === null) throw new Error(claudeFailure(result, 'claude rm'))
    const keptPath = withoutSlash(kept.worktree)
    const worktree = worktreeOf(row)
    if (worktree === null) {
      rememberKept(row, shortId, kept)
      throw new Error(REFUSED_KEPT)
    }
    if (seen === null) throw new Error(REFUSED_KEPT)
    if (kept.shortId !== shortId || keptPath !== withoutSlash(worktree)) {
      throw new Error(REFUSED_WORKTREE_CHANGED)
    }
    const now = await deps.checkWorktree(worktree)
    const changed =
      now === null ||
      now.worktree === null ||
      now.unmergedCommits > seen.unmergedCommits ||
      now.changedFiles > seen.changedFiles ||
      now.head !== kept.discard.split('@')[0]
    if (changed) throw new Error(REFUSED_WORKTREE_CHANGED)
    const discard = await rm(run, ['rm', shortId, '--discard-unpushed', kept.discard])
    if (discard.code === 0) return
    // A second refusal means that the worktree changed after the first claude rm.
    if (parseKeptChanges(discard.stdout) !== null) throw new Error(REFUSED_UNCOMMITTED)
    if (parseKept(discard.stdout) !== null) throw new Error(REFUSED_WORKTREE_CHANGED)
    throw new Error(claudeFailure(discard, 'claude rm'))
  }

  // Stop a session that runs, and wait for the end of its process. claude rm refuses a worktree
  // while the process runs (Task 19 bug 1).
  const stopForDelete = async (run: RunClaude, row: SessionRow, shortId: string): Promise<void> => {
    await command(run, ['stop', shortId], 'claude stop')
    if (row.pid !== undefined && !(await waitForEnd(row.pid, DELETE_END_WAIT_MS))) {
      throw new Error(REFUSED_NOT_STOPPED)
    }
  }

  // Run claude rm for each deferred delete of the worktree, in the order of the defers (spec 8 of
  // the skills design). The Delete of the last session there calls this after its own claude rm.
  // Each run gets the check of the last Delete dialog, so the discard rules of removeSession
  // apply. A good run drops the entry. A failed run undefers that entry and each later entry, so
  // these sessions show again as parked rows. Then the last session goes, because its claude rm
  // worked, and the Delete rejects with the error of the failed run.
  const removeDeferred = async (
    run: RunClaude,
    row: SessionRow,
    worktree: string,
    seen: SeenCounts | null,
  ): Promise<void> => {
    const entries = deps.deferredIn(worktree)
    for (const [i, entry] of entries.entries()) {
      try {
        // The short ID goes into an argument, so it must match SHORT_ID.
        if (!SHORT_ID.test(entry.shortId)) throw new Error(REFUSED_BAD_ID)
        const deferred = {
          cwd: entry.worktree,
          sessionId: entry.sessionId,
          worktree: entry.worktree,
        }
        await removeSession(run, deferred, entry.shortId, seen)
      } catch (error) {
        for (const later of entries.slice(i)) deps.undefer(later.sessionId)
        deps.forget(row.sessionId)
        throw error
      }
      deps.dropDeferred(entry.sessionId)
    }
  }

  // claude rm refuses a worktree with changes that git tracks and that are not committed. So the
  // Delete of a running worktree session checks first, and does not stop the session for no
  // result (final review M3). Untracked files alone do not block, and a failed check does not
  // block. Then claude rm decides, and it never deletes changes that are not committed.
  const checkBeforeStop = async (row: SessionRow): Promise<void> => {
    const worktree = worktreeOf(row)
    if (worktree === null) return
    const tracked = await deps.trackedChanges(worktree)
    if (tracked !== null && tracked > 0) throw new Error(REFUSED_UNCOMMITTED)
  }

  // Wait for the owned entry of a session that Bifrost resumed.
  const waitResumed = async (sessionId: string): Promise<void> => {
    try {
      await deps.waitForRow(runsOwned(sessionId), START_TIMEOUT_MS)
    } catch (error) {
      throw messageOf(error) === TIMEOUT ? new Error(REASON_NOT_RESUMED) : error
    }
  }

  // Check a parked row and run "claude --bg --resume" in its directory.
  // Bifrost never resumes a session that runs, because that starts a copy (spec 4).
  // The woken job keeps its short ID, so its entry goes to the same row ID (spec 6.1).
  const startResume = async (run: RunClaude, row: SessionRow): Promise<void> => {
    if (row.state !== 'parked') throw new Error(REFUSED_NOT_PARKED)
    if (row.prSession) throw new Error(REFUSED_PR_RESUME)
    checkSessionId(resumeIdOf(row))
    await checkProjectDir(row.cwd)
    await startRun(run, resumeArgs(row), row.cwd, 'claude --bg --resume')
  }

  // Check isAlive each END_POLL_MS for up to limitMs. Return true when the process ended.
  const waitForEnd = async (pid: number, limitMs = END_WAIT_MS): Promise<boolean> => {
    for (let waited = 0; ; waited += END_POLL_MS) {
      if (!deps.isAlive(pid)) return true
      if (waited >= limitMs) return false
      await sleep(END_POLL_MS)
    }
  }

  // New session and Hand over use this. See startBackground.
  const startAndWait = (run: RunClaude, args: string[], cwd: string): Promise<SessionRow> =>
    startBackground(deps, run, args, cwd).then(r => r.row)

  // Check the New session values, run "claude --bg" and wait for the entry of the session.
  const startNew = async (input: unknown): Promise<{ sessionId: string }> => {
    const checked = checkNewSessionSpec(input)
    if (!checked.ok) throw new Error(checked.reason)
    const spec = checked.spec
    const dir = await deps.dirInfo(spec.cwd)
    if (dir.kind !== 'dir') throw new Error(REASON_DIR_MISSING)
    if (spec.worktree && !dir.git) throw new Error(REASON_NO_GIT)
    const run = await claude()
    const row = await startAndWait(run, newSessionArgs(spec), spec.cwd)
    return { sessionId: row.sessionId }
  }

  return {
    async create(input) {
      if (creating) throw new Error(REASON_CREATING)
      creating = true
      try {
        return await startNew(input)
      } finally {
        creating = false
      }
    },

    async dirInfo(dir) {
      if (typeof dir !== 'string' || !dir.startsWith('/')) return { git: false, kind: 'missing' }
      return deps.dirInfo(dir)
    },

    // Hand over (spec 8). Only an owned session that runs, waits for input and has no prompt box.
    // The run holds the lock of the old session until the new session started or a step failed.
    // So no other action runs on the old session during the wait for the note.
    async handOver(sessionId) {
      return locked(sessionId, async row => {
        if (row.kind !== 'owned' || row.state === 'parked') throw new Error(REFUSED_STOP)
        // The send goes through "attach <short id>".
        if (row.shortId === undefined) throw new Error(REFUSED_NO_SHORT_ID)
        shortIdOf(row)
        if (row.state === 'working') throw new Error(REFUSED_WORKING)
        if (promptBlocks(row)) throw new Error(REFUSED_PROMPT)
        await checkProjectDir(row.cwd)
        const run = await claude()
        const result = await deps.handOver(row, (args, cwd) => startAndWait(run, args, cwd))
        deps.carryOver(row.sessionId, result.sessionId)
        return result
      })
    },

    // Delete runs claude stop for a session that runs, then claude rm, then forgets the session.
    // A parked row without a short ID is only removed from Bifrost (D5). Bifrost refuses a
    // session that runs and has no short ID. Bifrost cannot stop it, and the next sample
    // shows it again. removeSession gives the rules for a worktree that claude rm keeps.
    // The check that the dialog showed must be for the worktree of the row now (final review
    // M2). Else the dialog did not show the work that a discard removes.
    // claude rm can remove a clean worktree of a stopped session while another session uses it.
    // So Delete never removes a folder that another row uses (spec 8 of the skills design). For
    // such a row with a short ID, Delete stops the session if it runs, and then defers the
    // claude rm. No claude rm runs now, so no check runs before the stop, and the check counts
    // are not used. The Delete of the last session in the worktree runs claude rm for each
    // deferred delete there. A row without a short ID gets no claude rm, so this rule does not
    // apply to it.
    async remove(sessionId, confirmed, seen) {
      if (confirmed !== true) throw new Error(REFUSED_NOT_CONFIRMED)
      const counts = seenOf(seen)
      return locked(sessionId, async row => {
        if (row.kind === 'external' && row.state !== 'parked') {
          throw new Error(REFUSED_DELETE_EXTERNAL)
        }
        if (row.shortId === undefined && row.state !== 'parked') {
          throw new Error(REFUSED_NO_SHORT_ID)
        }
        const worktree = worktreeOf(row)
        const shared = worktree !== null && folderSharer(row, deps.rows()) !== undefined
        if (row.shortId !== undefined && shared) {
          const shortId = shortIdOf(row)
          if (row.state !== 'parked') await stopForDelete(await claude(), row, shortId)
          deps.defer({ sessionId: row.sessionId, shortId, worktree })
          return
        }
        if (counts !== null && counts.worktree !== worktree) {
          throw new Error(REFUSED_WORKTREE_CHANGED)
        }
        if (row.shortId !== undefined) {
          const shortId = shortIdOf(row)
          const run = await claude()
          if (row.state !== 'parked') {
            await checkBeforeStop(row)
            await stopForDelete(run, row, shortId)
          }
          await removeSession(run, row, shortId, counts)
          if (worktree !== null) await removeDeferred(run, row, worktree, counts)
        }
        deps.forget(row.sessionId)
      })
    },

    async resume(sessionId) {
      return locked(sessionId, async row => {
        if (row.state !== 'parked') throw new Error(REFUSED_NOT_PARKED)
        const run = await claude()
        await startResume(run, row)
        await waitResumed(row.sessionId)
        deps.markStarted(row.sessionId)
      })
    },

    // Resume the parked rows of the last run, one after the other. Then wait for all entries.
    // Resume all holds the lock of each session that it resumes until the end.
    async resumeAll() {
      if (resumingAll) throw new Error(REFUSED_RESUME_ALL)
      const candidates = deps.rows().filter(r => r.state === 'parked' && r.resumable === true)
      if (candidates.length === 0) return { failed: [], resumed: 0 }
      resumingAll = true
      const failed: ResumeAllResult['failed'] = []
      const held: SessionRow[] = []
      for (const row of candidates) {
        if (busy.has(row.sessionId)) failed.push({ error: REFUSED_LOCKED, name: row.name })
        else {
          busy.add(row.sessionId)
          held.push(row)
        }
      }
      try {
        const run = await claude()
        const started: SessionRow[] = []
        for (const row of held) {
          try {
            // An earlier resume can take some seconds. Use the current row.
            const current = deps.rows().find(r => r.sessionId === row.sessionId)
            if (!current) throw new Error(REFUSED_UNKNOWN)
            await startResume(run, current)
            started.push(row)
          } catch (error) {
            failed.push({ error: messageOf(error), name: row.name })
          }
        }
        // Mark each session as started when its entry shows.
        const waits = await Promise.allSettled(
          started.map(async row => {
            await waitResumed(row.sessionId)
            deps.markStarted(row.sessionId)
          }),
        )
        let resumed = 0
        waits.forEach((wait, i) => {
          if (wait.status === 'fulfilled') resumed++
          else failed.push({ error: messageOf(wait.reason), name: started[i].name })
        })
        return { failed, resumed }
      } finally {
        for (const row of held) busy.delete(row.sessionId)
        resumingAll = false
      }
    },

    async stop(sessionId) {
      return locked(sessionId, async row => {
        if (row.kind !== 'owned' || row.state === 'parked') throw new Error(REFUSED_STOP)
        const shortId = shortIdOf(row)
        const run = await claude()
        await command(run, ['stop', shortId], 'claude stop')
        deps.markStopped(row.sessionId)
      })
    },

    // Spec 9.2. SIGTERM goes only to the process of this external session, after the claude
    // name check (D6). If the process does not end in 5 seconds, Bifrost starts no copy.
    // The renderer sets confirmed only after the user accepts the confirmation of spec 9.2.
    // Claude Code cannot resume a session that has no user message (Task 10 bug 3). So Bifrost
    // sends no signal to such a session.
    // Take control resumes the current ID: the conversation after any /clear. The new job of
    // that ID goes to the same row ID (spec 6.1), so the wait uses the row ID.
    async takeControl(sessionId, confirmed) {
      if (confirmed !== true) throw new Error(REFUSED_TAKE_NOT_CONFIRMED)
      return locked(sessionId, async row => {
        checkTakeControl(row)
        const current = currentIdOf(row)
        checkSessionId(current)
        const pid = row.pid
        if (pid === undefined) throw new Error(REFUSED_NO_PID)
        // The PID 0 or -1 signals a group of processes. The PID 1 is launchd.
        if (!isSafePid(pid)) throw new Error(REFUSED_BAD_PID)
        const cwd = row.cwd
        await checkProjectDir(cwd)
        if (!(await deps.hasMessages(current))) throw new Error(REFUSED_NO_MESSAGES)
        // Find claude before the signal. Without claude, Bifrost cannot resume the session.
        const run = await claude()
        if (!isClaudeProcess(await deps.processName(pid))) {
          throw new Error(`refused: process ${pid} is not a claude process`)
        }
        // The rows can change during the reads above. The PID must still be the process of
        // this session, and of no other row. The rules of the action must still apply. A /clear
        // in that time changes the current ID, so the resume would take the old conversation.
        const rows = deps.rows()
        const now = rows.find(r => r.sessionId === row.sessionId)
        const other = rows.some(r => r.pid === pid && r.sessionId !== row.sessionId)
        if (!now || now.pid !== pid || other || currentIdOf(now) !== current) {
          throw new Error(REFUSED_CHANGED)
        }
        checkTakeControl(now)
        try {
          deps.signal(pid, 'SIGTERM')
        } catch {
          throw new Error(REASON_SIGNAL_FAILED)
        }
        if (!(await waitForEnd(pid))) throw new Error(REASON_NOT_ENDED)
        // A started session parks when it ends. So a failed resume leaves a parked row (D6).
        deps.markStarted(row.sessionId)
        await startRun(run, takeControlArgs(current), cwd, 'claude --bg --resume')
        await waitResumed(row.sessionId)
        // The resumed session must still run after RESUME_SETTLE_MS. Else it ended or parked
        // before it ran.
        await sleep(RESUME_SETTLE_MS)
        const resumed = deps.rows().find(r => r.sessionId === row.sessionId)
        const newPid = resumed && runsOwned(row.sessionId)(resumed) ? resumed.pid : undefined
        if (newPid === undefined || !deps.isAlive(newPid)) throw new Error(resumeFailed(resumed))
        return { sessionId: row.sessionId }
      })
    },
  }
}
