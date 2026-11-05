// All text and keys that Bifrost types into a session go through this module (D1, spec 8.4).
// It writes into the open chat PTY of the session, or into a hidden attach that it opens and closes.
// Input goes only to an owned session that runs, through "attach <short id>".
import { ESC, INTERRUPT_STEPS, type InputStep, planText, RED_BOX_BLOCK } from '../../shared/input'
import type { SessionRow, TermSize } from '../../shared/types'
import { canAttach } from '../pty/can-attach'
import { QuietWatch } from './quiet-watch'

// An attach is ready when its output was quiet for this time one time after the open.
export const READY_QUIET_MS = 1500
// A busy session never gets quiet. After this time, Bifrost writes nothing.
export const READY_TIMEOUT_MS = 15_000
// The hidden attach closes this time after the last write.
export const CLOSE_DELAY_MS = 1000
// Two Esc open the rewind menu. So a second Interrupt within this time has no effect.
export const INTERRUPT_GAP_MS = 1500

// The same strict form as the renderer: 8-4-4-4-12 hex digits.
export const CHAT_VIEW = /^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// The view of the chat window of a session. The renderer opens it.
export function chatView(sessionId: string): string {
  return `chat:${sessionId}`
}

// The view of the hidden attach of a session. Only this module opens it.
export function sendView(sessionId: string): string {
  return `send:${sessionId}`
}

export const REASON_NOT_READY = 'The session did not get ready in 15 seconds. Bifrost sent nothing.'
export const REASON_ENDED = 'The attach ended before it was ready. Bifrost sent nothing.'
export const REASON_NO_SIZE =
  'Bifrost cannot read the session size. Open the chat window and send from there.'
export const REASON_AGENT_VIEW =
  'The chat window shows the agent view. Close the window and open it again.'
export const REASON_CHAT_GONE = 'The chat window closed during the send.'
// The hidden attach ended after it was ready and before the last write.
export const REASON_ATTACH_GONE = 'The attach ended during the send.'

const REFUSED_INPUT = 'refused: bad input'
const REFUSED_SESSION = 'refused: the session is not an owned session that runs'
const REFUSED_NO_PID = 'refused: the session has no process ID yet'
const NO_CLAUDE = 'claude not found'

// A short ID goes into the attach arguments. Accept only 8 hex digits.
const SHORT_ID = /^[0-9a-f]{8}$/

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
interface ViewWatch {
  watch: QuietWatch
  ended: boolean
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

export class SessionInput {
  // The last job of each session. The next job starts after it.
  private readonly queues = new Map<string, Promise<void>>()
  private readonly watches = new Map<string, ViewWatch>()
  // The chat views that show the agent view.
  private readonly blocked = new Set<string>()
  // The sessions that have an Interrupt in the queue.
  private readonly interrupting = new Set<string>()
  // The time of the last Esc to each session.
  private readonly lastEsc = new Map<string, number>()

  constructor(private readonly deps: SessionInputDeps) {}

  // Send the text as a message or a slash command. This rejects with the reason of a failure.
  async send(sessionId: unknown, text: unknown): Promise<void> {
    if (typeof sessionId !== 'string' || typeof text !== 'string') throw new Error(REFUSED_INPUT)
    const plan = planText(text)
    if (!plan.ok) throw new Error(plan.reason)
    return this.enqueue(sessionId, () => this.run(sessionId, plan.steps, 'send'))
  }

  // Send one Esc. A red box does not block it.
  async interrupt(sessionId: unknown): Promise<void> {
    if (typeof sessionId !== 'string') throw new Error(REFUSED_INPUT)
    // An Interrupt of this session waits or runs. A second Interrupt has no effect.
    if (this.interrupting.has(sessionId)) return
    this.interrupting.add(sessionId)
    try {
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

  // An attach opened for this view. Start a new ready watch and clear the block.
  opened(viewId: string): void {
    this.watchView(viewId)
  }

  // Each chunk of output of the view feeds its ready watch.
  data(viewId: string): void {
    this.watches.get(viewId)?.watch.data()
  }

  // The attach of the view ended or closed.
  ended(viewId: string): void {
    const w = this.watches.get(viewId)
    if (w) this.drop(viewId, w)
    this.blocked.delete(viewId)
  }

  // The renderer reports the agent view of a chat window.
  setBlocked(viewId: unknown, blocked: unknown): void {
    if (typeof viewId !== 'string' || !CHAT_VIEW.test(viewId)) return
    if (typeof blocked !== 'boolean') return
    if (blocked) this.blocked.add(viewId)
    else this.blocked.delete(viewId)
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

  private watchView(viewId: string): ViewWatch {
    const old = this.watches.get(viewId)
    if (old) this.drop(viewId, old)
    const w: ViewWatch = { ended: false, watch: new QuietWatch(READY_QUIET_MS) }
    this.watches.set(viewId, w)
    this.blocked.delete(viewId)
    return w
  }

  private drop(viewId: string, w: ViewWatch): void {
    w.ended = true
    w.watch.dispose()
    if (this.watches.get(viewId) === w) this.watches.delete(viewId)
  }

  // The row must be an owned session that runs, with a short ID that "claude attach" accepts.
  // For a send, a red box blocks the job, because typed text can answer a prompt by accident.
  private check(sessionId: string, kind: JobKind): SessionRow & { shortId: string } {
    const rows = this.deps.rows()
    const row = rows.find(r => r.sessionId === sessionId)
    const shortId = row?.shortId
    if (!row || shortId === undefined || !SHORT_ID.test(shortId)) {
      throw new Error(REFUSED_SESSION)
    }
    if (!canAttach(rows, ['attach', shortId])) throw new Error(REFUSED_SESSION)
    if (kind === 'send' && row.box === 'red') throw new Error(RED_BOX_BLOCK)
    return { ...row, shortId }
  }

  private async run(sessionId: string, steps: readonly InputStep[], kind: JobKind): Promise<void> {
    this.check(sessionId, kind)
    const pty = await this.deps.pty()
    if (!pty) throw new Error(NO_CLAUDE)
    if (pty.has(chatView(sessionId))) return this.runChat(pty, sessionId, steps, kind)
    return this.runHidden(pty, sessionId, steps, kind)
  }

  // Write into the open chat PTY. Never close it.
  private async runChat(
    pty: InputPty,
    sessionId: string,
    steps: readonly InputStep[],
    kind: JobKind,
  ): Promise<void> {
    const view = chatView(sessionId)
    if (this.blocked.has(view)) throw new Error(REASON_AGENT_VIEW)
    const w = this.watches.get(view)
    if (!w) throw new Error(REASON_NOT_READY)
    if (!(await w.watch.wait(READY_TIMEOUT_MS))) {
      throw new Error(w.ended ? REASON_CHAT_GONE : REASON_NOT_READY)
    }
    await this.writeSteps(pty, sessionId, view, w, steps, kind, REASON_CHAT_GONE)
  }

  // Open a hidden attach at the current session size, write, then close it.
  // An attach sets the session size for all clients (M3). So it must open at the current size.
  private async runHidden(
    pty: InputPty,
    sessionId: string,
    steps: readonly InputStep[],
    kind: JobKind,
  ): Promise<void> {
    const pid = this.check(sessionId, kind).pid
    if (pid === undefined) throw new Error(REFUSED_NO_PID)
    const size = await this.deps.readSize(pid)
    if (!size) throw new Error(REASON_NO_SIZE)
    // A chat window can open during the read. Then use it.
    if (pty.has(chatView(sessionId))) return this.runChat(pty, sessionId, steps, kind)
    // The rows can change during the read. Check them again before the attach.
    const { shortId } = this.check(sessionId, kind)
    const view = sendView(sessionId)
    pty.open(view, ['attach', shortId], { cols: size.cols, cwd: '/', rows: size.rows })
    const w = this.watchView(view)
    try {
      if (!(await w.watch.wait(READY_TIMEOUT_MS))) {
        throw new Error(w.ended ? REASON_ENDED : REASON_NOT_READY)
      }
      await this.writeSteps(pty, sessionId, view, w, steps, kind, REASON_ATTACH_GONE)
      await sleep(CLOSE_DELAY_MS)
    } finally {
      pty.close(view, 'SIGHUP')
      this.drop(view, w)
    }
  }

  // Each step waits, then writes. Just before each write, check the row, the view and the block.
  // A prompt can open during a wait. Then the CR does not go, so it cannot answer the prompt.
  private async writeSteps(
    pty: InputPty,
    sessionId: string,
    view: string,
    w: ViewWatch,
    steps: readonly InputStep[],
    kind: JobKind,
    gone: string,
  ): Promise<void> {
    for (const step of steps) {
      // A timer of 0 ms waits 1 ms in Node. A step with no delay writes at once after the checks.
      if (step.delayMs > 0) await sleep(step.delayMs)
      this.check(sessionId, kind)
      if (w.ended || this.watches.get(view) !== w) throw new Error(gone)
      if (this.blocked.has(view)) throw new Error(REASON_AGENT_VIEW)
      if (kind === 'interrupt' && step.data === ESC) {
        const last = this.lastEsc.get(sessionId)
        if (last !== undefined && Date.now() - last < INTERRUPT_GAP_MS) return
      }
      if (!pty.write(view, step.data)) throw new Error(gone)
      if (kind === 'interrupt' && step.data === ESC) this.lastEsc.set(sessionId, Date.now())
    }
  }
}
