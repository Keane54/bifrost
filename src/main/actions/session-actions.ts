// The session commands: New session, Stop, Delete, Resume, Resume all and Take control (spec 9.1).
// The renderer sends session IDs and the New session values only. This module finds the row,
// checks it and makes the claude arguments. It never trusts a PID or a path from the renderer.
// Each command waits for the registry entry. Exit code 0 is not proof of a start (spec 8.9).
import {
  checkNewSessionSpec,
  type DirInfo,
  isClaudeCommand,
  type NewSessionSpec,
  PERMISSION_MODES,
  REASON_DIR_MISSING,
  REASON_NO_GIT,
  REASON_PROMPT_FLAG,
  REASON_PROMPT_IS_COMMAND,
  worktreeName,
} from '../../shared/new-session'
import type { ResumeAllResult, SeenCounts, SessionRow, WorktreeCheck } from '../../shared/types'
import { worktreeOf } from '../../shared/worktree'
import type { ExecResult, RunClaude } from '../claude/cli'
import { UUID_PATTERN } from '../integration/scripts'
import {
  failure,
  isTrustError,
  parseKept,
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
// The time limit of each claude command.
export const RUN_TIMEOUT_MS = 60_000
// After Take control, the resumed session must still run this time after its process showed.
// A resume can fail just after the start of its process (Task 10 bug 3).
export const RESUME_SETTLE_MS = 3000

// Each new session gets a statusLine command that prints nothing (controller ruling, O4).
// So the chat window does not show the statusline of the user. A resume keeps the setting.
// This is one argument. No shell reads it.
export const NO_STATUSLINE_SETTINGS = '{"statusLine":{"type":"command","command":"true"}}'

const UUID = new RegExp(UUID_PATTERN)

export const NO_CLAUDE = 'claude not found'
export const REFUSED_UNKNOWN = 'refused: unknown session'
const REFUSED_BAD_ID = 'refused: bad session ID'
const REFUSED_LOCKED = 'refused: an action on this session runs'
const REFUSED_RESUME_ALL = 'refused: Resume all runs'
const REFUSED_NOT_CONFIRMED = 'refused: Delete needs a confirmation'
const REFUSED_TAKE_NOT_CONFIRMED = 'refused: Take control needs a confirmation'
const REFUSED_NO_SHORT_ID = 'refused: the session runs and has no short ID'
const REFUSED_BAD_PID = 'refused: bad process ID'
const REFUSED_STOP = 'refused: only an owned session that runs'
export const REFUSED_DELETE_EXTERNAL = 'refused: Bifrost does not delete an external session'
const REFUSED_NOT_PARKED = 'refused: the session is not parked'
const REFUSED_NOT_EXTERNAL = 'refused: only an external session'
const REFUSED_WORKING = 'refused: the session is working'
const REFUSED_PROMPT = 'refused: the session has an open prompt'
const REFUSED_NOT_IDLE = 'refused: the session is not idle'
const REFUSED_NO_PID = 'refused: the session has no process ID'
const REFUSED_CHANGED = 'refused: the session process changed'
const REFUSED_BAD_SEEN = 'refused: bad input'
const REFUSED_KEPT = 'refused: claude rm kept the worktree'
const REFUSED_WORKTREE_CHANGED = 'refused: the worktree changed after the check'
const REFUSED_NO_MESSAGES = 'refused: the session has no messages yet'
const REASON_NO_SHORT_ID = 'claude --bg did not give a session ID.'
const REASON_CREATING = 'A new session is already starting. Please wait.'
const REASON_NO_CWD = "Bifrost doesn't know the project folder of this session."
const REASON_NOT_RESUMED = 'The session did not start again in 30 seconds.'
const REASON_NOT_ENDED =
  'The session process did not end in 5 seconds. Bifrost did not start a copy of the session.'
const REASON_RESUME_FAILED = 'Claude Code could not resume this session.'

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
  // The unmerged-work check of a worktree root (worktree-check.ts). null means a git failure.
  checkWorktree(worktree: string): Promise<WorktreeCheck | null>
  // True when the transcript of the session has a user message. A read error gives true.
  hasMessages(sessionId: string): Promise<boolean>
}

export interface SessionActions {
  create(spec: unknown): Promise<{ sessionId: string }>
  stop(sessionId: unknown): Promise<void>
  // confirmed must be true. The renderer sets it only after the user accepts the confirmation.
  // seen is the unmerged-work check that the dialog showed, or null when the check failed or
  // did not run.
  remove(sessionId: unknown, confirmed: unknown, seen?: unknown): Promise<void>
  resume(sessionId: unknown): Promise<void>
  resumeAll(): Promise<ResumeAllResult>
  // confirmed must be true, as for remove. Take control ends a terminal process.
  takeControl(sessionId: unknown, confirmed: unknown): Promise<{ sessionId: string }>
  dirInfo(dir: unknown): Promise<DirInfo>
}

// The arguments of "claude --bg" for the New session values.
// The prompt is last, because "--worktree" takes an optional value.
// The permission mode must be in the list. So Bifrost never passes bypassPermissions.
// The prompt cannot start with "-" or be only a command name, so it cannot change the command.
// checkNewSessionSpec refuses these values first. These checks stop a caller that skips it.
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

function messageOf(error: unknown): string {
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

// The session ID goes into an argument, so it must be a UUID.
function checkSessionId(row: SessionRow): void {
  if (!UUID.test(row.sessionId)) throw new Error(REFUSED_BAD_ID)
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

// The check counts from the renderer. null and a missing value mean that no check was shown.
// Each count must be an integer of 0 or more.
function seenOf(seen: unknown): SeenCounts | null {
  if (seen === null || seen === undefined) return null
  if (typeof seen !== 'object') throw new Error(REFUSED_BAD_SEEN)
  const { changedFiles, unmergedCommits } = seen as Record<string, unknown>
  const isCount = (n: unknown): n is number => Number.isSafeInteger(n) && (n as number) >= 0
  if (!isCount(changedFiles) || !isCount(unmergedCommits)) throw new Error(REFUSED_BAD_SEEN)
  return { changedFiles, unmergedCommits }
}

// The failure text of a Take control whose resumed session did not stay. claude logs gives the
// cause, and Bifrost does not run it.
function resumeFailed(row: SessionRow | undefined): string {
  const shortId = row?.shortId
  if (shortId === undefined || !SHORT_ID.test(shortId)) return REASON_RESUME_FAILED
  return `${REASON_RESUME_FAILED} Run claude logs ${shortId} to see the cause.`
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

  const claude = async (): Promise<RunClaude> => {
    const run = await deps.run()
    if (!run) throw new Error(NO_CLAUDE)
    return run
  }

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
    if (result.code !== 0) throw new Error(failure(result, what))
  }

  // Run a claude command that starts a session in cwd. A trust error gives the instruction.
  const start = async (
    run: RunClaude,
    args: string[],
    cwd: string,
    what: string,
  ): Promise<ExecResult> => {
    const result = await run(args, { cwd, timeoutMs: RUN_TIMEOUT_MS })
    if (isTrustError(result.stdout) || isTrustError(result.stderr)) {
      throw new Error(trustMessage(cwd))
    }
    if (result.code !== 0) throw new Error(failure(result, what))
    return result
  }

  const checkProjectDir = async (cwd: string): Promise<void> => {
    if (cwd === '') throw new Error(REASON_NO_CWD)
    if (!cwd.startsWith('/') || (await deps.dirInfo(cwd)).kind !== 'dir') {
      throw new Error(`The folder ${cwd} doesn't exist.`)
    }
  }

  // Run claude rm. It keeps a worktree that has commits on no remote, and prints the value
  // that discards them (M4 controller check). Bifrost discards only when the Delete dialog
  // showed a check of the worktree, and a new check after the stop finds no more commits and
  // no more changed files. The discard value comes only from parseKept.
  const removeSession = async (
    run: RunClaude,
    row: SessionRow,
    shortId: string,
    seen: SeenCounts | null,
  ): Promise<void> => {
    const result = await run(['rm', shortId], { timeoutMs: RUN_TIMEOUT_MS })
    if (result.code === 0) return
    const kept = parseKept(result.stdout)
    if (kept === null) throw new Error(failure(result, 'claude rm'))
    const worktree = worktreeOf(row)
    if (seen === null || worktree === null) throw new Error(REFUSED_KEPT)
    const now = await deps.checkWorktree(worktree)
    const more =
      now === null ||
      now.worktree === null ||
      now.unmergedCommits > seen.unmergedCommits ||
      now.changedFiles > seen.changedFiles
    if (more) throw new Error(REFUSED_WORKTREE_CHANGED)
    const discard = await run(['rm', shortId, '--discard-unpushed', kept.discard], {
      timeoutMs: RUN_TIMEOUT_MS,
    })
    if (discard.code === 0) return
    // A second refusal means that the worktree changed after the first claude rm.
    if (parseKept(discard.stdout) !== null) throw new Error(REFUSED_WORKTREE_CHANGED)
    throw new Error(failure(discard, 'claude rm'))
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
  const startResume = async (run: RunClaude, row: SessionRow): Promise<void> => {
    if (row.state !== 'parked') throw new Error(REFUSED_NOT_PARKED)
    checkSessionId(row)
    await checkProjectDir(row.cwd)
    await start(run, ['--bg', '--resume', row.sessionId], row.cwd, 'claude --bg --resume')
  }

  // Check isAlive each END_POLL_MS for up to END_WAIT_MS. Return true when the process ended.
  const waitForEnd = async (pid: number): Promise<boolean> => {
    for (let waited = 0; ; waited += END_POLL_MS) {
      if (!deps.isAlive(pid)) return true
      if (waited >= END_WAIT_MS) return false
      await sleep(END_POLL_MS)
    }
  }

  // Check the New session values, run "claude --bg" and wait for the entry of the session.
  const startNew = async (input: unknown): Promise<{ sessionId: string }> => {
    const checked = checkNewSessionSpec(input)
    if (!checked.ok) throw new Error(checked.reason)
    const spec = checked.spec
    const dir = await deps.dirInfo(spec.cwd)
    if (dir.kind !== 'dir') throw new Error(REASON_DIR_MISSING)
    if (spec.worktree && !dir.git) throw new Error(REASON_NO_GIT)
    const run = await claude()
    const result = await start(run, newSessionArgs(spec), spec.cwd, 'claude --bg')
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

    // Delete runs claude stop for a session that runs, then claude rm, then forgets the session.
    // A parked row without a short ID is only removed from Bifrost (D5). Bifrost refuses a
    // session that runs and has no short ID. Bifrost cannot stop it, and the next sample
    // shows it again. removeSession gives the rules for a worktree that claude rm keeps.
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
        if (row.shortId !== undefined) {
          const shortId = shortIdOf(row)
          const run = await claude()
          if (row.state !== 'parked') await command(run, ['stop', shortId], 'claude stop')
          await removeSession(run, row, shortId, counts)
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
    async takeControl(sessionId, confirmed) {
      if (confirmed !== true) throw new Error(REFUSED_TAKE_NOT_CONFIRMED)
      return locked(sessionId, async row => {
        checkTakeControl(row)
        checkSessionId(row)
        const pid = row.pid
        if (pid === undefined) throw new Error(REFUSED_NO_PID)
        // The PID 0 or -1 signals a group of processes. The PID 1 is launchd.
        if (!isSafePid(pid)) throw new Error(REFUSED_BAD_PID)
        const cwd = row.cwd
        await checkProjectDir(cwd)
        if (!(await deps.hasMessages(row.sessionId))) throw new Error(REFUSED_NO_MESSAGES)
        // Find claude before the signal. Without claude, Bifrost cannot resume the session.
        const run = await claude()
        if (!isClaudeProcess(await deps.processName(pid))) {
          throw new Error(`refused: process ${pid} is not a claude process`)
        }
        // The rows can change during the reads above. The PID must still be the process of
        // this session, and of no other row. The rules of the action must still apply.
        const rows = deps.rows()
        const now = rows.find(r => r.sessionId === row.sessionId)
        const other = rows.some(r => r.pid === pid && r.sessionId !== row.sessionId)
        if (!now || now.pid !== pid || other) {
          throw new Error(REFUSED_CHANGED)
        }
        checkTakeControl(now)
        try {
          deps.signal(pid, 'SIGTERM')
        } catch (error) {
          throw new Error(`Bifrost could not send SIGTERM to process ${pid}: ${messageOf(error)}`)
        }
        if (!(await waitForEnd(pid))) throw new Error(REASON_NOT_ENDED)
        // A started session parks when it ends. So a failed resume leaves a parked row (D6).
        deps.markStarted(row.sessionId)
        await start(run, ['--bg', '--resume', row.sessionId], cwd, 'claude --bg --resume')
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
