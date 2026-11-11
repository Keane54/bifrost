// The run of the Hand over button (spec 8, steps 1 to 5).
// Bifrost sends the request prompt to the old session, waits for the end of the turn, reads the
// note from the transcript, saves the note and starts the new session. If a step fails, the old
// session stays as it is and no new session starts. A note that exists stays on disk.
// The session actions run this inside the lock of the old session. They check the row first.
import type { HandOverResult, SessionRow } from '../../shared/types'
import { handOverArgs } from '../actions/session-actions'
import { handOverName } from './naming'
import { continuePrompt, handOverPrompt } from './prompt'
import { maskSecrets, type ReplyState, readReply } from './reply'

// The time limit of the wait for the note (spec 8, step 2).
export const HANDOVER_TIMEOUT_MS = 300_000
// The time between two reads of the transcript during the wait.
export const HANDOVER_POLL_MS = 1000

const TEXT_NO_RULES = "Bifrost can't read its hand-over rules, so nothing changed."
const TEXT_NO_TRANSCRIPT = "Bifrost can't find the transcript of this session, so nothing changed."
const TEXT_TIMEOUT =
  "The session didn't finish the hand-over note within 5 minutes, " +
  "so Bifrost didn't start a new session."
const TEXT_STOPPED = 'The session stopped before it finished the hand-over note.'

function readFailed(reason: string): string {
  return `Bifrost couldn't read the hand-over note, so it didn't start a new session. (${reason})`
}

function saveFailed(message: string): string {
  return `Bifrost couldn't save the hand-over note, so it didn't start a new session. ${message}`
}

function startFailed(notePath: string, message: string): string {
  return `The note is saved at ${notePath}, but the new session didn't start. ${message}`
}

export interface HandOverDeps {
  rows(): SessionRow[]
  // Type the text into the session (SessionInput.send). Rejects with the reason of a failure.
  send(sessionId: string, text: string): Promise<void>
  // The text of the hand-over rules file.
  rules(): Promise<string>
  // The path of the transcript of the row, or null when no file exists.
  transcript(row: SessionRow): Promise<string | null>
  // The size of the file in bytes.
  size(file: string): Promise<number>
  // The full lines of the file after the offset (readTail in transcript.ts).
  readTail(file: string, offset: number): Promise<string>
  // Write the note to a new file and resolve with its path.
  writeNote(sessionName: string, note: string, at: Date): Promise<string>
  requestId(): string
  now(): number
  sleep(ms: number): Promise<void>
}

// Start a session with the claude arguments in the folder. Resolves with its row.
export type StartSession = (args: string[], cwd: string) => Promise<SessionRow>
export type HandOverRun = (row: SessionRow, start: StartSession) => Promise<HandOverResult>

type Done = Extract<ReplyState, { kind: 'done' }>

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// True for an error of the file system, for example ENOENT or EACCES. Such an error has a code.
function isFileError(error: unknown): boolean {
  return typeof (error as { code?: unknown } | null)?.code === 'string'
}

export function createHandOver(deps: HandOverDeps): HandOverRun {
  // The transcript and its size before the send. The reply reader reads only after the size.
  // So an older note in the transcript never counts (Review Focus 2).
  // A failed read is the same as no transcript.
  const baselineOf = async (row: SessionRow): Promise<{ file: string; baseline: number }> => {
    const file = await deps.transcript(row).catch(() => null)
    const baseline = file === null ? null : await deps.size(file).catch(() => null)
    if (file === null || baseline === null) throw new Error(TEXT_NO_TRANSCRIPT)
    return { baseline, file }
  }

  // Wait for the note. The wait ends when the turn ended with the note and the session is idle.
  // A failed reply stops at once, for example a new message from the user (Review Focus 3).
  // readReply also fails on such a message after the first turn end, so the wait reads again
  // until the session is idle.
  const waitForNote = async (
    row: SessionRow,
    file: string,
    baseline: number,
    id: string,
  ): Promise<Done> => {
    const startedAt = deps.now()
    for (;;) {
      await deps.sleep(HANDOVER_POLL_MS)
      const current = deps.rows().find(r => r.sessionId === row.sessionId)
      if (current === undefined || current.state === 'parked') throw new Error(TEXT_STOPPED)
      let tail: string
      try {
        tail = await deps.readTail(file, baseline)
      } catch (error) {
        // The message of a file error holds the transcript path, so the user does not see it.
        // The send is done, so for Bifrost the session stopped. The checks of readTail itself,
        // for example a reply that is too long, keep their reason.
        if (isFileError(error)) throw new Error(TEXT_STOPPED)
        throw new Error(readFailed(messageOf(error)))
      }
      const reply = readReply(tail, id)
      if (reply.kind === 'failed') throw new Error(readFailed(reply.reason))
      if (reply.kind === 'done' && current.status === 'idle') return reply
      if (deps.now() - startedAt >= HANDOVER_TIMEOUT_MS) throw new Error(TEXT_TIMEOUT)
    }
  }

  return async (row, start) => {
    let rules: string
    try {
      rules = await deps.rules()
    } catch {
      throw new Error(TEXT_NO_RULES)
    }
    if (rules.trim() === '') throw new Error(TEXT_NO_RULES)
    const { baseline, file } = await baselineOf(row)
    const id = deps.requestId()
    // Step 1. A rejection keeps its message, for example the text of a prompt box.
    await deps.send(row.sessionId, handOverPrompt(rules, id))
    // Step 2 and 3.
    const done = await waitForNote(row, file, baseline, id)
    // Step 4. A command argument cannot hold a NUL character. Bifrost removes each NUL before
    // the mask, so a NUL inside a token cannot hide the token from the mask.
    const note = maskSecrets(done.note.replaceAll('\0', ''))
    let notePath: string
    try {
      notePath = await deps.writeNote(row.name, note, new Date(deps.now()))
    } catch (error) {
      throw new Error(saveFailed(messageOf(error)))
    }
    // Step 5. The new name skips each name of all rows. The checks of the new prompt come after
    // the save, so a refused prompt keeps the note.
    try {
      const taken = deps.rows().flatMap(r => [r.name, r.claudeName])
      const name = handOverName(row.name, taken)
      const args = handOverArgs({
        model: done.model,
        name,
        permissionMode: done.permissionMode ?? row.permissionMode ?? null,
        prompt: continuePrompt(note, notePath),
      })
      const started = await start(args, row.cwd)
      return { name, notePath, sessionId: started.sessionId }
    } catch (error) {
      throw new Error(startFailed(notePath, messageOf(error)))
    }
  }
}
