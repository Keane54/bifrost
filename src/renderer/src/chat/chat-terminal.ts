// One chat window terminal: an xterm.js terminal and its attach to one session (spec 8.5).
// The object lives outside React. A React mount only shows its element in a panel.
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import type { BifrostApi } from '../../../shared/api'
import { cssFontFamily, DEFAULT_SETTINGS, type TerminalFont } from '../../../shared/settings'
import type { SessionRow, TermSize } from '../../../shared/types'
import { CHAT_ATTR } from '../keys/focus-zone'
import { cx } from '../lib/cx'
import { errorMessage } from '../lib/error-message'
import {
  type AgentGuard,
  afterRestart,
  agentCheckDelay,
  agentStep,
  isAgentView,
  joinWrapped,
  recentAttaches,
  type ScreenRow,
  stepBlocks,
} from './agent-view'
import {
  BUMP_GAP_MS,
  decideSize,
  fitScale,
  openSize,
  type Px,
  RESIZE_DEBOUNCE_MS,
} from './size-rule'
import { type AttachTarget, attachTarget, type ChatView, chatPanelId, HIDDEN_VIEW } from './views'
import { addedContexts, releaseWebgl, type WebglContext } from './webgl-release'

const GIVE_UP_TEXT =
  'The agent view opened 3 times in 60 seconds. Close this window and open it again.'

// The times of the attaches after an agent view, for one session.
// The owner keeps it after the window closes. So a new window of the session has the same limit.
export interface AttachHistory {
  times: number[]
}

export interface ChatTerminalDeps {
  pty: BifrostApi['pty']
  // The element that keeps the terminal when no panel shows it.
  parking: HTMLElement
  // The terminal font of the settings at the time of the open. Default: the settings default.
  font?: TerminalFont
  history: AttachHistory
  // True when a newer terminal uses the view ID of this terminal.
  replaced(): boolean
}

function sameView(a: ChatView, b: ChatView): boolean {
  return a.focused === b.focused && a.visible === b.visible
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
  // The WebGL contexts of the loaded addon. A release loses them at once.
  private webglContexts: WebglContext[] = []
  private webglBroken = false

  private target: AttachTarget = attachTarget(undefined, false)
  private view: ChatView = HIDDEN_VIEW
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
  // The number of the current attach. A late write result of an old attach has no effect.
  private attachCount = 0
  private opening = false
  private ended = false
  private inputBlocked = false
  private gaveUp = false
  // True when the agent view shows and the reattach waits for a row that can attach.
  private agentWaiting = false
  private disposed = false

  private resizeTimer: number | undefined
  private pendingResize: TermSize | null = null
  private pendingBump: TermSize | null = null
  private bumpTimer: number | undefined
  private checkTimer: number | undefined
  // The time of the first chunk after the last agent view check, or null.
  private uncheckedSince: number | null = null
  private focusFrame = 0

  constructor(sessionId: string, deps: ChatTerminalDeps) {
    this.sessionId = sessionId
    this.viewId = chatPanelId(sessionId)
    this.deps = deps

    this.element = document.createElement('div')
    this.element.className = cx('relative h-full w-full overflow-hidden')
    // The focus zone of the keys finds a chat window by this attribute (spec 9.3). A focus in the
    // window selects the session in the value.
    this.element.setAttribute(CHAT_ATTR, sessionId)
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

    const font = deps.font ?? DEFAULT_SETTINGS.terminalFont
    this.term = new Terminal({
      fontFamily: cssFontFamily(font),
      fontSize: font.size,
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
    // The agent view waits for the row. Now the row can attach, so check the screen again.
    if (this.agentWaiting && this.target.ok) this.checkAgentView()
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
      this.unloadWebgl()
      return
    }
    if (this.webgl || this.webglBroken) return
    let addon: WebglAddon | null = null
    try {
      addon = new WebglAddon()
      const loaded = addon
      loaded.onContextLoss(() => {
        this.webglBroken = true
        if (this.webgl === loaded) this.unloadWebgl()
        else loaded.dispose()
      })
      const before = this.canvases()
      this.term.loadAddon(loaded)
      this.webgl = loaded
      this.webglContexts = addedContexts(before, this.canvases())
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

  // Lose the WebGL context at once, then dispose the addon. The DOM renderer takes its place.
  private unloadWebgl(): void {
    const addon = this.webgl
    if (!addon) return
    const contexts = this.webglContexts
    this.webgl = null
    this.webglContexts = []
    releaseWebgl(contexts, () => addon.dispose())
  }

  private canvases(): HTMLCanvasElement[] {
    return Array.from(this.host.querySelectorAll('canvas'))
  }

  write(chunk: string): void {
    // Without an attach, a chunk comes from an old PTY of this view. Ignore it.
    if (this.disposed || !this.attached) return
    this.term.write(chunk)
    const now = Date.now()
    if (this.uncheckedSince === null) this.uncheckedSince = now
    window.clearTimeout(this.checkTimer)
    const delay = agentCheckDelay(this.uncheckedSince, now)
    this.checkTimer = window.setTimeout(() => this.checkAgentView(), delay)
  }

  exited(code: number): void {
    // Without an attach, the exit is for an old PTY of this view, for example during a reattach.
    if (this.disposed || !this.attached) return
    this.end(`[process ended: code ${code}]`)
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
    const contexts = this.webglContexts
    this.webgl = null
    this.webglContexts = []
    // The terminal dispose also disposes the addons. So the WebGL context is lost before it.
    releaseWebgl(contexts, () => this.term.dispose())
    this.element.remove()
  }

  // Attach again after a Resume. A terminal that did not end does nothing.
  // The attach follows the rule of setRow: it waits for a row that can attach.
  // The agent view guard starts again. Without this, a window that gave up before the end
  // would never stop the input again, and keys could go into the agent view (spec 8.5).
  restart(): void {
    if (this.disposed || !this.ended) return
    const guard = afterRestart(this.agentGuard())
    this.gaveUp = guard.gaveUp
    this.agentWaiting = guard.waiting
    this.ended = false
    this.term.reset()
    this.maybeAttach()
    this.showNote()
  }

  private agentGuard(): AgentGuard {
    return { gaveUp: this.gaveUp, waiting: this.agentWaiting }
  }

  // Block or free the keys of the window. The main process also refuses a send to the session
  // while the window shows the agent view (D1).
  private setInputBlocked(blocked: boolean): void {
    if (this.inputBlocked === blocked) return
    this.inputBlocked = blocked
    this.deps.pty.setBlocked(this.viewId, blocked).catch(err => {
      console.warn('Bifrost cannot report the agent view of a chat window.', this.viewId, err)
    })
  }

  private input(data: string): void {
    if (!this.attached || this.inputBlocked) return
    const attach = this.attachCount
    // The main process gives false when the view has no PTY. Then the attach is gone.
    this.deps.pty.write(this.viewId, data).then(
      written => {
        if (!written) this.inputFailed(attach)
      },
      (err: unknown) => {
        console.warn('Bifrost cannot write to the attach of a chat window.', this.viewId, err)
        this.inputFailed(attach)
      },
    )
  }

  // The attach is gone, but no exit came. The terminal ends, as after an exit.
  private inputFailed(attach: number): void {
    if (this.disposed || !this.attached || attach !== this.attachCount) return
    this.end('[input failed: the attach ended]')
    // A write can fail while the attach still runs. Close it, so that no hidden attach stays.
    this.deps.pty.close(this.viewId).catch(err => {
      console.warn('Bifrost cannot close the attach of a chat window.', this.viewId, err)
    })
  }

  // Mark the terminal as ended and write one line. It does not attach again by itself.
  private end(line: string): void {
    this.attached = false
    this.ended = true
    this.agentWaiting = false
    this.stopTimers()
    this.term.write(`\r\n${line}\r\n`)
    this.showNote()
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
          // The window closed during the open. Close the new PTY, but not the PTY of a newer
          // window of the session. The open of that window closed this PTY already.
          if (!this.deps.replaced()) {
            this.deps.pty.close(this.viewId).catch(err => {
              console.warn('Bifrost cannot close the attach of a chat window.', this.viewId, err)
            })
          }
          return
        }
        this.attached = true
        this.attachCount += 1
        // A reattach after the agent view blocked the input. The new attach unblocks it.
        this.setInputBlocked(false)
        this.showNote()
        // The panel can change during the open. A send waits for the attach.
        this.updateSize()
      },
      (err: unknown) => {
        this.opening = false
        if (this.disposed) return
        // No new try. Close the window and open it again. This stops an error loop.
        this.end(`[open failed: ${errorMessage(err)}]`)
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

  // Use a new terminal font (Settings). The cells change, so run the size step again.
  setFont(font: TerminalFont): void {
    if (this.disposed) return
    const family = cssFontFamily(font)
    if (this.term.options.fontFamily === family && this.term.options.fontSize === font.size) return
    this.term.options.fontFamily = family
    this.term.options.fontSize = font.size
    this.updateSize()
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
    // A failed resize does not end the attach. The next resize can work.
    this.deps.pty.resize(this.viewId, size.cols, size.rows).catch(err => {
      console.warn('Bifrost cannot resize the attach of a chat window.', this.viewId, err)
    })
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
      // A menu or a dialog, for example the right-click menu of a tab, keeps the keyboard focus.
      if (document.activeElement?.closest('[role="menu"], [role="dialog"]')) {
        this.wantFocus = false
        return
      }
      this.term.focus()
      if (this.term.textarea === document.activeElement) this.wantFocus = false
    })
  }

  // Read the screen. The agent view lists the sessions of all projects (spec 8.5, D10).
  private checkAgentView(): void {
    window.clearTimeout(this.checkTimer)
    this.checkTimer = undefined
    this.uncheckedSince = null
    if (this.disposed || !this.attached) return
    const guard = this.agentGuard()
    const history = this.deps.history
    const now = Date.now()
    const target = this.target
    // A window that gave up reads no screen.
    const agentView = !guard.gaveUp && isAgentView(joinWrapped(this.screenRows()))
    const step = agentStep(guard, { agentView, history: history.times, now, targetOk: target.ok })
    if (step === 'none') return
    if (step === 'free') {
      // The agent view closed while the reattach waited for the row. Input starts again.
      this.agentWaiting = false
      this.setInputBlocked(false)
      this.showNote()
      return
    }
    // Input stops at once.
    this.setInputBlocked(stepBlocks(step))
    history.times = recentAttaches(history.times, now)
    if (step === 'give-up') {
      this.gaveUp = true
      this.agentWaiting = false
      this.showNote()
      return
    }
    // The row cannot attach now. Input stays blocked, and the note gives the reason.
    // The next update of a row that can attach checks the screen again.
    // The step is wait only when the target is not ok. The second test tells TypeScript so.
    if (step === 'wait' || !target.ok) {
      this.agentWaiting = true
      this.showNote()
      return
    }
    this.agentWaiting = false
    history.times.push(now)
    this.attached = false
    this.term.reset()
    // The PTY manager closes the old PTY of this view before it opens the new PTY.
    this.open(target, this.termSize())
  }

  // The rows of the screen, without a trim. joinWrapped trims each line.
  // The screen starts at baseY. The viewport starts higher when the user scrolls back (D10).
  private screenRows(): ScreenRow[] {
    const buffer = this.term.buffer.active
    const rows: ScreenRow[] = []
    for (let y = buffer.baseY; y < buffer.baseY + this.term.rows; y++) {
      const line = buffer.getLine(y)
      if (line) rows.push({ text: line.translateToString(false), wrapped: line.isWrapped })
    }
    return rows
  }

  private showNote(): void {
    let text: string | null = null
    const waiting = this.agentWaiting || (!this.attached && !this.opening)
    if (this.gaveUp) text = GIVE_UP_TEXT
    else if (waiting && !this.target.ok) text = this.target.reason
    this.note.textContent = text ?? ''
    this.note.hidden = text === null
  }

  private stopTimers(): void {
    window.clearTimeout(this.checkTimer)
    window.clearTimeout(this.resizeTimer)
    window.clearTimeout(this.bumpTimer)
    this.checkTimer = undefined
    this.uncheckedSince = null
    this.resizeTimer = undefined
    this.bumpTimer = undefined
    this.pendingResize = null
    this.pendingBump = null
  }
}
