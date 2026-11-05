// One chat window terminal: an xterm.js terminal and its attach to one session (spec 8.5).
// The object lives outside React. A React mount only shows its element in a panel.
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import type { BifrostApi } from '../../../shared/api'
import type { SessionRow, TermSize } from '../../../shared/types'
import { cx } from '../lib/cx'
import {
  isAgentView,
  joinWrapped,
  reattachDecision,
  recentAttaches,
  type ScreenRow,
} from './agent-view'
import {
  BUMP_GAP_MS,
  decideSize,
  fitScale,
  openSize,
  type Px,
  RESIZE_DEBOUNCE_MS,
} from './size-rule'
import { type AttachTarget, attachTarget, type ChatView, chatPanelId } from './views'

// Bifrost reads the screen for the agent view this time after the last chunk.
const AGENT_CHECK_MS = 250

const GIVE_UP_TEXT =
  'The agent view opened 3 times in 60 seconds. Close this window and open it again.'

// The times of the attaches after an agent view, for one session.
// The owner keeps it after the window closes. So a new window of the session has the same limit.
export interface AttachHistory {
  times: number[]
}

export interface ChatTerminalDeps {
  pty: BifrostApi['pty']
  acknowledge(sessionId: string): void
  // The element that keeps the terminal when no panel shows it.
  parking: HTMLElement
  history: AttachHistory
}

const HIDDEN: ChatView = { focused: false, visible: false }

function sameView(a: ChatView, b: ChatView): boolean {
  return a.focused === b.focused && a.visible === b.visible
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

export class ChatTerminal {
  readonly sessionId: string
  readonly viewId: string
  // The element that a panel shows. It holds the terminal and the overlays.
  readonly element: HTMLDivElement
  private readonly deps: ChatTerminalDeps
  private readonly term: Terminal
  private readonly fit = new FitAddon()
  // The parent of the xterm.js element. The zoom applies to it, not to the overlays.
  private readonly host: HTMLDivElement
  // A transparent overlay. It stops the pointer on a zoomed terminal that is not focused (D8).
  private readonly blocker: HTMLDivElement
  // The text overlay: the reason that the window cannot attach, or the agent view limit.
  private readonly note: HTMLDivElement
  private readonly screenObserver: ResizeObserver
  private screen: HTMLElement | null = null
  private webgl: WebglAddon | null = null
  private webglBroken = false

  private target: AttachTarget = attachTarget(undefined, false)
  private view: ChatView = HIDDEN
  private panel: Px | null = null
  private session: TermSize | null = null
  // True from a focus gain until a size decision with a known fit.
  private focusGained = false
  // True from a focus gain until the terminal has the keyboard focus.
  private wantFocus = false
  private lastSent: TermSize | null = null
  private lastSentAt: number | null = null
  // True after the first read of the session size. An unfocused window reads it before it opens.
  private sizeAsked = false

  private attached = false
  private opening = false
  private ended = false
  private inputBlocked = false
  private gaveUp = false
  private disposed = false

  private resizeTimer: number | undefined
  private pendingResize: TermSize | null = null
  private pendingBump: TermSize | null = null
  private bumpTimer: number | undefined
  private checkTimer: number | undefined
  private focusFrame = 0

  constructor(sessionId: string, deps: ChatTerminalDeps) {
    this.sessionId = sessionId
    this.viewId = chatPanelId(sessionId)
    this.deps = deps

    this.element = document.createElement('div')
    this.element.className = cx('relative h-full w-full overflow-hidden')
    this.host = document.createElement('div')
    this.host.className = cx('relative z-0 h-full w-full')
    this.host.style.transformOrigin = '0 0'
    this.blocker = document.createElement('div')
    this.blocker.className = cx('absolute inset-0 z-10')
    this.blocker.hidden = true
    this.note = document.createElement('div')
    this.note.className = cx(
      'absolute inset-0 z-10 flex items-center justify-center bg-bg/80 p-4 text-center text-[13px] text-text-dim',
    )
    this.element.append(this.host, this.blocker, this.note)
    // xterm.js measures its cells when it opens. So the element must be in the page first.
    deps.parking.append(this.element)

    this.term = new Terminal({
      fontFamily: '"SF Mono", ui-monospace, Menlo, monospace',
      fontSize: 13,
      macOptionClickForcesSelection: true,
      scrollback: 5000,
    })
    this.term.loadAddon(this.fit)
    this.term.open(this.host)
    // The keys and the xterm.js replies go to the PTY.
    this.term.onData(data => this.input(data))
    // xterm.js changes the screen size later when the terminal is not on the screen.
    // So the zoom follows the screen element.
    this.screen = this.host.querySelector<HTMLElement>('.xterm-screen')
    this.screenObserver = new ResizeObserver(() => this.applyScale())
    if (this.screen) this.screenObserver.observe(this.screen)
    this.showNote()
  }

  // True when the WebGL renderer is loaded.
  get hasWebgl(): boolean {
    return this.webgl !== null
  }

  // True after a WebGL failure or a context loss. The terminal then keeps the DOM renderer.
  get webglFailed(): boolean {
    return this.webglBroken
  }

  // Each registry update calls this. A waiting window attaches when its row can attach.
  setRow(row: SessionRow | undefined, loaded: boolean): void {
    if (this.disposed) return
    this.target = attachTarget(row, loaded)
    this.maybeAttach()
    this.showNote()
  }

  setView(view: ChatView, focusGained: boolean): void {
    if (this.disposed) return
    if (sameView(view, this.view) && !focusGained) return
    const lost = this.view.focused && !view.focused
    this.view = view
    if (focusGained) {
      this.focusGained = true
      this.wantFocus = true
      // A focus stops the flash of the box of the session (spec 7, rule 2).
      this.deps.acknowledge(this.sessionId)
    }
    if (!view.focused) {
      this.focusGained = false
      this.wantFocus = false
    }
    if (lost && this.term.textarea === document.activeElement) this.term.blur()
    this.updateSize()
    this.maybeAttach()
    this.takeFocus()
  }

  // The size of the panel that shows the terminal, or null when no panel shows it.
  setPanel(panel: Px | null): void {
    if (this.disposed) return
    this.panel = panel
    this.updateSize()
    this.maybeAttach()
    this.takeFocus()
  }

  // The size of the session, or null when it is not known. Task 11 gives this size.
  setSessionSize(size: TermSize | null): void {
    if (this.disposed) return
    this.session = size
    this.updateSize()
  }

  setWebgl(on: boolean): void {
    if (this.disposed) return
    if (!on) {
      this.webgl?.dispose()
      this.webgl = null
      return
    }
    if (this.webgl || this.webglBroken) return
    let addon: WebglAddon | null = null
    try {
      addon = new WebglAddon()
      const loaded = addon
      loaded.onContextLoss(() => {
        this.webglBroken = true
        loaded.dispose()
        if (this.webgl === loaded) this.webgl = null
      })
      this.term.loadAddon(loaded)
      this.webgl = loaded
    } catch (err) {
      // WebGL failed. xterm.js keeps the DOM renderer.
      this.webglBroken = true
      console.warn('Bifrost cannot use WebGL for a chat window.', err)
      try {
        addon?.dispose()
      } catch {
        // The addon did not start. Nothing is left to release.
      }
    }
  }

  write(chunk: string): void {
    // Without an attach, a chunk comes from an old PTY of this view. Ignore it.
    if (this.disposed || !this.attached) return
    this.term.write(chunk)
    window.clearTimeout(this.checkTimer)
    this.checkTimer = window.setTimeout(() => this.checkAgentView(), AGENT_CHECK_MS)
  }

  exited(code: number): void {
    // Without an attach, the exit is for an old PTY of this view, for example during a reattach.
    if (this.disposed || !this.attached) return
    this.attached = false
    this.ended = true
    this.stopTimers()
    this.term.write(`\r\n[process ended: code ${code}]\r\n`)
    this.showNote()
  }

  // Move the element back to the parking element. A panel calls this when it no longer shows it.
  park(): void {
    if (this.disposed || this.element.parentElement === this.deps.parking) return
    this.deps.parking.append(this.element)
  }

  // End the attach process (SIGHUP, spec 8.5), then the terminal. The session continues.
  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    this.stopTimers()
    cancelAnimationFrame(this.focusFrame)
    this.deps.pty.close(this.viewId).catch(err => {
      console.error('Bifrost cannot close the attach of a chat window.', err)
    })
    this.screenObserver.disconnect()
    this.webgl = null
    // This also disposes the addons.
    this.term.dispose()
    this.element.remove()
  }

  private input(data: string): void {
    if (!this.attached || this.inputBlocked) return
    // A failed write has no effect. The main process returns false for a closed PTY.
    this.deps.pty.write(this.viewId, data).catch(() => {})
  }

  private maybeAttach(): void {
    if (this.disposed || this.attached || this.opening || this.ended) return
    const target = this.target
    if (!target.ok) return
    // A visible window waits for the size of its panel. So the attach gets the correct size.
    if (this.view.visible && !this.panel) return
    // An unfocused window opens with the session size. So it reads the size first.
    if (!this.view.focused && !this.session && !this.sizeAsked) {
      this.readSessionSize()
      return
    }
    const fit = this.currentFit()
    // The attach sends the fit of a focused window. So the focus gain needs no other send.
    if (fit) this.focusGained = false
    this.open(target, openSize({ fit, focused: this.view.focused, session: this.session }))
  }

  // Read the session size one time before the first open. A failed read gives no size.
  private readSessionSize(): void {
    this.sizeAsked = true
    this.opening = true
    this.deps.pty.sessionSize(this.sessionId).then(
      size => this.afterSizeRead(size),
      () => this.afterSizeRead(null),
    )
  }

  private afterSizeRead(size: TermSize | null): void {
    this.opening = false
    if (this.disposed) return
    // A size event can arrive during the read. It is newer.
    if (size && !this.session) this.session = size
    this.maybeAttach()
  }

  // Open the attach PTY. An attach also sets the size of the session (M3 Task 1).
  private open(target: { shortId: string; cwd: string }, size: TermSize): void {
    this.opening = true
    this.resizeLocal(size)
    this.lastSent = size
    this.lastSentAt = Date.now()
    const opts = { cols: size.cols, cwd: target.cwd, rows: size.rows }
    this.deps.pty.open(this.viewId, ['attach', target.shortId], opts).then(
      () => {
        this.opening = false
        if (this.disposed) {
          // The window closed during the open. Close the new PTY.
          this.deps.pty.close(this.viewId).catch(() => {})
          return
        }
        this.attached = true
        // A reattach after the agent view blocked the input. The new attach unblocks it.
        this.inputBlocked = false
        this.showNote()
        // The panel can change during the open. A send waits for the attach.
        this.updateSize()
      },
      (err: unknown) => {
        this.opening = false
        if (this.disposed) return
        // No new try. Close the window and open it again. This stops an error loop.
        this.ended = true
        this.term.write(`\r\n[open failed: ${message(err)}]\r\n`)
        this.showNote()
      },
    )
  }

  // The size that fits the panel, or null when no panel shows the terminal.
  private currentFit(): TermSize | null {
    if (!this.view.visible || !this.panel) return null
    const dims = this.fit.proposeDimensions()
    if (!dims || !Number.isFinite(dims.cols) || !Number.isFinite(dims.rows)) return null
    if (dims.cols < 1 || dims.rows < 1) return null
    return { cols: dims.cols, rows: dims.rows }
  }

  private termSize(): TermSize {
    return { cols: this.term.cols, rows: this.term.rows }
  }

  private resizeLocal(size: TermSize): void {
    if (size.cols !== this.term.cols || size.rows !== this.term.rows) {
      this.term.resize(size.cols, size.rows)
    }
  }

  // Apply the size rule (spec 8.5) after a change of the view, the panel or the session size.
  private updateSize(): void {
    if (this.disposed) return
    const now = Date.now()
    const fit = this.currentFit()
    const decision = decideSize({
      fit,
      focused: this.view.focused,
      focusGained: this.focusGained,
      lastSent: this.lastSent,
      lastSentAt: this.lastSentAt,
      now,
      session: this.session,
      term: this.termSize(),
    })
    // Only a known fit can go to the session. So a focus gain waits for a fit.
    if (fit) this.focusGained = false
    this.resizeLocal(decision.term)
    // Before the attach, the open sends the size.
    if (decision.send && this.attached) {
      this.lastSent = decision.send
      this.lastSentAt = now
      this.sendLater(decision.send, decision.bump ?? null)
    }
    this.applyScale()
  }

  // Each resize causes a full redraw. So only the last size of a burst goes to the PTY.
  // A bump goes first. It gives the SIGWINCH that the same size does not give.
  private sendLater(size: TermSize, bump: TermSize | null): void {
    this.pendingResize = size
    this.pendingBump = bump ?? this.pendingBump
    window.clearTimeout(this.resizeTimer)
    this.resizeTimer = window.setTimeout(() => {
      this.resizeTimer = undefined
      const next = this.pendingResize
      const first = this.pendingBump
      this.pendingResize = null
      this.pendingBump = null
      if (!next || this.disposed || !this.attached) return
      if (!first) {
        this.sendResize(next)
        return
      }
      this.sendResize(first)
      this.bumpTimer = window.setTimeout(() => {
        this.bumpTimer = undefined
        if (!this.disposed && this.attached) this.sendResize(next)
      }, BUMP_GAP_MS)
    }, RESIZE_DEBOUNCE_MS)
  }

  private sendResize(size: TermSize): void {
    this.lastSentAt = Date.now()
    this.deps.pty.resize(this.viewId, size.cols, size.rows).catch(() => {})
  }

  // Zoom the terminal to fit its panel (D8: never above 1).
  private applyScale(): void {
    if (this.disposed) return
    const screen = this.screen
    const scale = screen
      ? fitScale({ h: screen.offsetHeight, w: screen.offsetWidth }, this.panel)
      : 1
    this.host.style.transform = scale < 1 ? `scale(${scale})` : ''
    // xterm.js gives wrong mouse cells under a zoom. So the first click only focuses (D8).
    this.blocker.hidden = this.view.focused || scale >= 1
  }

  // Give the keyboard focus to the terminal after a focus gain.
  // The wait of one frame lets the pointer down of the frame end first.
  private takeFocus(): void {
    if (!this.wantFocus || this.focusFrame !== 0) return
    this.focusFrame = requestAnimationFrame(() => {
      this.focusFrame = 0
      if (this.disposed || !this.wantFocus || !this.view.focused || !this.panel) return
      this.term.focus()
      if (this.term.textarea === document.activeElement) this.wantFocus = false
    })
  }

  // Read the screen. The agent view lists the sessions of all projects (spec 8.5, D10).
  private checkAgentView(): void {
    this.checkTimer = undefined
    if (this.disposed || !this.attached || this.gaveUp) return
    if (!isAgentView(joinWrapped(this.screenRows()))) return
    // Input stops at once.
    this.inputBlocked = true
    const history = this.deps.history
    const now = Date.now()
    history.times = recentAttaches(history.times, now)
    if (reattachDecision(history.times, now) === 'give-up') {
      this.gaveUp = true
      this.showNote()
      return
    }
    // The row cannot attach now. Input stays blocked until the next check.
    const target = this.target
    if (!target.ok) return
    history.times.push(now)
    this.attached = false
    this.term.reset()
    // The PTY manager closes the old PTY of this view before it opens the new PTY.
    this.open(target, this.termSize())
  }

  // The rows of the visible screen, without a trim. joinWrapped trims each line.
  private screenRows(): ScreenRow[] {
    const buffer = this.term.buffer.active
    const rows: ScreenRow[] = []
    for (let y = buffer.viewportY; y < buffer.viewportY + this.term.rows; y++) {
      const line = buffer.getLine(y)
      if (line) rows.push({ text: line.translateToString(false), wrapped: line.isWrapped })
    }
    return rows
  }

  private showNote(): void {
    let text: string | null = null
    if (this.gaveUp) text = GIVE_UP_TEXT
    else if (!this.attached && !this.opening && !this.target.ok) text = this.target.reason
    this.note.textContent = text ?? ''
    this.note.hidden = text === null
  }

  private stopTimers(): void {
    window.clearTimeout(this.checkTimer)
    window.clearTimeout(this.resizeTimer)
    window.clearTimeout(this.bumpTimer)
    this.checkTimer = undefined
    this.resizeTimer = undefined
    this.bumpTimer = undefined
    this.pendingResize = null
    this.pendingBump = null
  }
}
