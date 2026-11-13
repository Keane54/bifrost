// All text and keys that Bifrost types into a session go through this module (D1, spec 8.4).
// It writes into the open chat PTY of the session, or into a hidden attach that it opens and closes.
// Input goes only to an owned session that runs, through "attach <short id>".
import {
  ESC,
  INTERRUPT_STEPS,
  type InputStep,
  planText,
  promptBlocks,
  RED_BOX_BLOCK,
} from '../../shared/input'
import type { SessionRow, TermSize } from '../../shared/types'
import { CHAT_VIEW } from '../../shared/view-id'
import { canAttach } from '../pty/can-attach'
import { SHORT_ID } from './claude-output'
import { QuietWatch } from './quiet-watch'

export { CHAT_VIEW }

// An attach is ready when its output was quiet for this time one time after the open.
export const READY_QUIET_MS = 1500
// A busy session never gets quiet. After this time, Bifrost writes nothing.
export const READY_TIMEOUT_MS = 15_000
// The hidden attach closes this time after the last write.
export const CLOSE_DELAY_MS = 1000
// Two Esc open the rewind menu. So a second Interrupt within this time has no effect.
export const INTERRUPT_GAP_MS = 1500
// An Interrupt needs only a connected attach. A working session shows a spinner, so its output
// never gets quiet. The Esc goes this time after the first output of the attach.
export const INTERRUPT_CONNECT_MS = 300
// After an Esc, the next write to the session waits this time.
// Else the session can read the Esc and the next bytes as one key.
export const ESC_GAP_MS = 200
// The left arrow key on an empty prompt opens the agent view. The renderer finds the agent view
// some time later. A send to that chat window waits this time after a left arrow key.
export const LEFT_KEY_WAIT_MS = 2000

// The view of the chat window of a session. The renderer opens it.
export function chatView(sessionId: string): string {
  return `chat:${sessionId}`
}

// The view of the hidden attach of a session. Only this module opens it.
export function sendView(sessionId: string): string {
  return `send:${sessionId}`
}

// True when the data from the renderer has the left arrow key (normal or application mode).
export function hasLeftKey(data: string): boolean {
  return data.includes('\x1b[D') || data.includes('\x1bOD')
}

export const REASON_NOT_READY = 'The session did not get ready in 15 seconds. Bifrost sent nothing.'
export const REASON_ENDED =
  'The connection to the session ended before it was ready. Bifrost sent nothing.'
export const REASON_NO_SIZE =
  'Bifrost cannot read the session size. Open the chat window and send from there.'
export const REASON_AGENT_VIEW =
  'The chat window shows the agent view. Close the window and open it again.'
export const REASON_CHAT_GONE = 'The chat window closed during the send.'
// The hidden attach ended after it was ready and before the last write.
export const REASON_ATTACH_GONE = 'The connection to the session ended during the send.'
// The row has a new short ID, but the chat window still shows the attach of the old short ID.
export const REASON_OLD_ATTACH =
  'The chat window shows an old connection to the session. Close the window and open it again.'

const REFUSED_INPUT = 'refused: bad input'
const REFUSED_SESSION = 'refused: the session is not an owned session that runs'
const REFUSED_NO_PID = 'refused: the session has no process ID yet'
export const REFUSED_CANCELLED = 'refused: the send was cancelled by Interrupt'
const NO_CLAUDE = 'claude not found'

// The gaps use a clock that only goes forward. A change of the wall clock has no effect.
function now(): number {
  return performance.now()
}

// The part of PtyManager that this module uses.
export interface InputPty {
  has(viewId: string): boolean
  open(viewId: string, args: string[], opts: { cwd: string; cols: number; rows: number }): number
  write(viewId: string, data: string): boolean
  close(viewId: string, signal?: string): void
}

export interface SessionInputDeps {
  rows(): SessionRow[]
  // The PTY manager, or null when Bifrost cannot find claude.
  pty(): Promise<InputPty | null>
  // The current size of the session TTY, or null when Bifrost cannot read it.
  readSize(pid: number): Promise<TermSize | null>
}

type JobKind = 'send' | 'interrupt'

// The ready watch of one open attach. ended is true after the attach ended.
// shortId is the short ID of the attach. firstAt is the time of the first output.
interface ViewWatch {
  watch: QuietWatch
  ended: boolean
  shortId: string
  firstAt?: number
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

// A send that has not written yet. An Interrupt of its session cancels it, so the Esc does not
// wait for the ready time of the send (final review M4, spec 8.4). The first write commits the
// send. After that, a cancel has no effect, so the text never stays in the prompt without CR.
class SendTicket {
  cancelled = false
  private committed = false
  private wake: () => void = () => {}
  // Resolves when an Interrupt cancels the send.
  readonly whenCancelled = new Promise<void>(resolve => {
    this.wake = resolve
  })

  cancel(): void {
    if (this.committed || this.cancelled) return
    this.cancelled = true
    this.wake()
  }

  // Call this just before the first write, with no wait between the call and the write.
  commit(): void {
    this.stopIfCancelled()
    this.committed = true
  }

  stopIfCancelled(): void {
    if (this.cancelled) throw new Error(REFUSED_CANCELLED)
  }
}

// Wait for p. A cancel of the send ends the wait first, and then the send rejects.
async function orCancel<T>(p: Promise<T>, ticket: SendTicket | undefined): Promise<T> {
  if (ticket === undefined) return p
  ticket.stopIfCancelled()
  const result = await Promise.race([p, ticket.whenCancelled])
  ticket.stopIfCancelled()
  return result as T
}

export class SessionInput {
  // The last job of each session. The next job starts after it.
  private readonly queues = new Map<string, Promise<void>>()
  private readonly watches = new Map<string, ViewWatch>()
  // The chat views that show the agent view.
  private readonly blocked = new Set<string>()
  // The time of the last left arrow key to each chat view.
  private readonly leftKeyAt = new Map<string, number>()
  // The sessions that have an Interrupt in the queue.
  private readonly interrupting = new Set<string>()
  // The sends of each session that have not written yet. An Interrupt cancels them.
  private readonly waitingSends = new Map<string, Set<SendTicket>>()
  // The time of the last Esc to each session.
  private readonly lastEsc = new Map<string, number>()

  constructor(private readonly deps: SessionInputDeps) {}

  // Send the text as a message or a slash command. This rejects with the reason of a failure.
  async send(sessionId: unknown, text: unknown): Promise<void> {
    if (typeof sessionId !== 'string' || typeof text !== 'string') throw new Error(REFUSED_INPUT)
    const plan = planText(text)
    if (!plan.ok) throw new Error(plan.reason)
    const ticket = new SendTicket()
    const waiting = this.waitingSends.get(sessionId) ?? new Set<SendTicket>()
    waiting.add(ticket)
    this.waitingSends.set(sessionId, waiting)
    try {
      return await this.enqueue(sessionId, () => this.run(sessionId, plan.steps, 'send', ticket))
    } finally {
      waiting.delete(ticket)
      if (waiting.size === 0 && this.waitingSends.get(sessionId) === waiting) {
        this.waitingSends.delete(sessionId)
      }
    }
  }

  // Send one Esc. A red box does not block it.
  // The Interrupt first cancels each send of this session that has not written yet. The queue
  // then runs the Interrupt after the cancelled sends end. So one attach at a time stays open.
  async interrupt(sessionId: unknown): Promise<void> {
    if (typeof sessionId !== 'string') throw new Error(REFUSED_INPUT)
    // An Interrupt of this session waits or runs. A second Interrupt has no effect.
    if (this.interrupting.has(sessionId)) return
    this.interrupting.add(sessionId)
    try {
      for (const ticket of this.waitingSends.get(sessionId) ?? []) ticket.cancel()
      await this.enqueue(sessionId, () => this.run(sessionId, INTERRUPT_STEPS, 'interrupt'))
    } finally {
      this.interrupting.delete(sessionId)
    }
  }

  // Resolve when the queue of the session is empty.
  async idle(sessionId: string): Promise<void> {
    let tail = this.queues.get(sessionId)
    while (tail) {
      await tail
      tail = this.queues.get(sessionId)
    }
  }

  // An attach to the short ID opened for this view. Start a new ready watch and clear the block.
  opened(viewId: string, shortId: string): void {
    this.watchView(viewId, shortId)
  }

  // Each chunk of output of the view feeds its ready watch.
  data(viewId: string): void {
    const w = this.watches.get(viewId)
    if (!w) return
    if (w.firstAt === undefined) w.firstAt = now()
    w.watch.data()
  }

  // The attach of the view ended or closed.
  ended(viewId: string): void {
    const w = this.watches.get(viewId)
    if (w) this.drop(viewId, w)
    this.blocked.delete(viewId)
    this.leftKeyAt.delete(viewId)
  }

  // The renderer reports the agent view of a chat window.
  setBlocked(viewId: unknown, blocked: unknown): void {
    if (typeof viewId !== 'string' || !CHAT_VIEW.test(viewId)) return
    if (typeof blocked !== 'boolean') return
    if (blocked) this.blocked.add(viewId)
    else this.blocked.delete(viewId)
  }

  // The renderer wrote the left arrow key to a chat view.
  leftKey(viewId: string): void {
    if (CHAT_VIEW.test(viewId)) this.leftKeyAt.set(viewId, now())
  }

  // Run a job after the last job of the session. A failed job does not stop the next job.
  private enqueue(sessionId: string, job: () => Promise<void>): Promise<void> {
    const last = this.queues.get(sessionId) ?? Promise.resolve()
    const run = last.then(job)
    const tail = run.then(
      () => {},
      () => {},
    )
    this.queues.set(sessionId, tail)
    void tail.then(() => {
      if (this.queues.get(sessionId) === tail) this.queues.delete(sessionId)
    })
    return run
  }

  private watchView(viewId: string, shortId: string): ViewWatch {
    const old = this.watches.get(viewId)
    if (old) this.drop(viewId, old)
    const w: ViewWatch = { ended: false, shortId, watch: new QuietWatch(READY_QUIET_MS) }
    this.watches.set(viewId, w)
    this.blocked.delete(viewId)
    this.leftKeyAt.delete(viewId)
    return w
  }

  private drop(viewId: string, w: ViewWatch): void {
    w.ended = true
    w.watch.dispose()
    if (this.watches.get(viewId) === w) this.watches.delete(viewId)
  }

  // The row must be an owned session that runs, with a short ID that "claude attach" accepts.
  // For a send, a prompt box blocks the job, because typed text can answer a prompt by accident.
  private check(sessionId: string, kind: JobKind): SessionRow & { shortId: string } {
    const rows = this.deps.rows()
    const row = rows.find(r => r.sessionId === sessionId)
    const shortId = row?.shortId
    if (!row || shortId === undefined || !SHORT_ID.test(shortId)) {
      throw new Error(REFUSED_SESSION)
    }
    if (!canAttach(rows, ['attach', shortId])) throw new Error(REFUSED_SESSION)
    if (kind === 'send' && promptBlocks(row)) throw new Error(RED_BOX_BLOCK)
    return { ...row, shortId }
  }

  // ticket is the ticket of a send. An Interrupt has no ticket.
  private async run(
    sessionId: string,
    steps: readonly InputStep[],
    kind: JobKind,
    ticket?: SendTicket,
  ): Promise<void> {
    this.check(sessionId, kind)
    const pty = await orCancel(this.deps.pty(), ticket)
    if (!pty) throw new Error(NO_CLAUDE)
    if (pty.has(chatView(sessionId))) return this.runChat(pty, sessionId, steps, kind, ticket)
    return this.runHidden(pty, sessionId, steps, kind, ticket)
  }

  // A send waits until the output of the attach was quiet for 1.5 s. An Interrupt can cancel
  // the send during the wait. An Interrupt waits until INTERRUPT_CONNECT_MS after the first
  // output.
  private async ready(w: ViewWatch, kind: JobKind, ticket?: SendTicket): Promise<boolean> {
    if (kind === 'send') return orCancel(w.watch.wait(READY_TIMEOUT_MS), ticket)
    if (!(await w.watch.waitOutput(READY_TIMEOUT_MS))) return false
    const rest = (w.firstAt ?? now()) + INTERRUPT_CONNECT_MS - now()
    if (rest > 0) await sleep(rest)
    return !w.ended
  }

  // Write into the open chat PTY. Never close it.
  private async runChat(
    pty: InputPty,
    sessionId: string,
    steps: readonly InputStep[],
    kind: JobKind,
    ticket?: SendTicket,
  ): Promise<void> {
    const view = chatView(sessionId)
    if (this.blocked.has(view)) throw new Error(REASON_AGENT_VIEW)
    // The PTY can close between the close of its watch and the close in the manager.
    const w = this.watches.get(view)
    if (!w) throw new Error(REASON_CHAT_GONE)
    if (!(await this.ready(w, kind, ticket))) {
      throw new Error(w.ended ? REASON_CHAT_GONE : REASON_NOT_READY)
    }
    await this.writeSteps(pty, sessionId, view, w, steps, kind, REASON_CHAT_GONE, ticket)
  }

  // Open a hidden attach at the current session size, write, then close it.
  // An attach sets the session size for all clients (M3). So it must open at the current size.
  // A cancelled send closes its attach at once. Then the Interrupt opens its own attach.
  private async runHidden(
    pty: InputPty,
    sessionId: string,
    steps: readonly InputStep[],
    kind: JobKind,
    ticket?: SendTicket,
  ): Promise<void> {
    const pid = this.check(sessionId, kind).pid
    if (pid === undefined) throw new Error(REFUSED_NO_PID)
    const size = await orCancel(this.deps.readSize(pid), ticket)
    if (!size) throw new Error(REASON_NO_SIZE)
    // A chat window can open during the read. Then use it.
    if (pty.has(chatView(sessionId))) return this.runChat(pty, sessionId, steps, kind, ticket)
    // The rows can change during the read. Check them again before the attach.
    const { shortId } = this.check(sessionId, kind)
    const view = sendView(sessionId)
    pty.open(view, ['attach', shortId], { cols: size.cols, cwd: '/', rows: size.rows })
    const w = this.watchView(view, shortId)
    try {
      if (!(await this.ready(w, kind, ticket))) {
        throw new Error(w.ended ? REASON_ENDED : REASON_NOT_READY)
      }
      await this.writeSteps(pty, sessionId, view, w, steps, kind, REASON_ATTACH_GONE, ticket)
      await sleep(CLOSE_DELAY_MS)
    } finally {
      pty.close(view, 'SIGHUP')
      this.drop(view, w)
    }
  }

  // The time that the next write to the session must wait: the Esc gap, and for a send
  // the wait after a left arrow key. A value of 0 or less means no wait.
  private gapRest(sessionId: string, view: string, kind: JobKind): number {
    const t = now()
    const esc = (this.lastEsc.get(sessionId) ?? Number.NEGATIVE_INFINITY) + ESC_GAP_MS - t
    if (kind !== 'send') return esc
    const left = (this.leftKeyAt.get(view) ?? Number.NEGATIVE_INFINITY) + LEFT_KEY_WAIT_MS - t
    return Math.max(esc, left)
  }

  // Wait for the gaps. A new left arrow key during the wait starts the wait again.
  // After READY_TIMEOUT_MS of waits, the job stops. An Interrupt can cancel a send that waits.
  private async waitGaps(
    sessionId: string,
    view: string,
    kind: JobKind,
    ticket?: SendTicket,
  ): Promise<void> {
    const limit = now() + READY_TIMEOUT_MS
    for (let rest = this.gapRest(sessionId, view, kind); rest > 0; ) {
      if (now() + rest > limit) throw new Error(REASON_NOT_READY)
      await orCancel(sleep(rest), ticket)
      rest = this.gapRest(sessionId, view, kind)
    }
  }

  // Each step waits, then writes. Just before each write, check the row, the attach and the block.
  // A prompt can open during a wait. Then the CR does not go, so it cannot answer the prompt.
  // The first write commits a send. An Interrupt cannot cancel it after that.
  private async writeSteps(
    pty: InputPty,
    sessionId: string,
    view: string,
    w: ViewWatch,
    steps: readonly InputStep[],
    kind: JobKind,
    gone: string,
    ticket?: SendTicket,
  ): Promise<void> {
    for (const step of steps) {
      // A timer of 0 ms waits 1 ms in Node. A step with no delay writes at once after the checks.
      if (step.delayMs > 0) await sleep(step.delayMs)
      const esc = kind === 'interrupt' && step.data === ESC
      if (esc) {
        const last = this.lastEsc.get(sessionId)
        if (last !== undefined && now() - last < INTERRUPT_GAP_MS) return
      }
      await this.waitGaps(sessionId, view, kind, ticket)
      const row = this.check(sessionId, kind)
      if (w.ended || this.watches.get(view) !== w) throw new Error(gone)
      // The attach must be for the short ID of the row now.
      if (w.shortId !== row.shortId) throw new Error(REASON_OLD_ATTACH)
      if (this.blocked.has(view)) throw new Error(REASON_AGENT_VIEW)
      // No wait comes between the commit and the write.
      ticket?.commit()
      if (!pty.write(view, step.data)) throw new Error(gone)
      if (esc) this.lastEsc.set(sessionId, now())
    }
  }
}
