// All chat terminals of the app, their lifecycle, and the React context (spec 8.5, D7).
// The open chat panels decide which terminals exist. A React mount or unmount does not start
// or end an attach. So a stack, a tab change, a minimise or a tear-out keeps the attach.
import { createContext, useContext, useEffect, useLayoutEffect, useState } from 'react'
import type { BifrostApi } from '../../../shared/api'
import type { TerminalFont } from '../../../shared/settings'
import { DEFAULT_SETTINGS } from '../../../shared/settings'
import type { SessionRow } from '../../../shared/types'
import { useRegistry } from '../data/registry'
import { useSettings } from '../settings/settings-context'
import { useWmState } from '../wm/context'
import { recentAttaches } from './agent-view'
import { type AttachHistory, ChatTerminal } from './chat-terminal'
import {
  type ChatView,
  chatSessionId,
  chatViews,
  gainedFocus,
  HIDDEN_VIEW,
  MAX_WEBGL,
  openChatIds,
  webglPlan,
} from './views'

interface ChatTerminalsDeps {
  pty: BifrostApi['pty']
}

export class ChatTerminals {
  // A terminal element stays here when no panel shows it. xterm.js keeps its layout here.
  private readonly parking: HTMLDivElement
  private readonly deps: ChatTerminalsDeps
  private readonly terminals = new Map<string, ChatTerminal>()
  private readonly histories = new Map<string, AttachHistory>()
  private readonly listeners = new Set<() => void>()
  private views = new Map<string, ChatView>()
  private font: TerminalFont = DEFAULT_SETTINGS.terminalFont
  private unsubscribe: Array<() => void> = []
  private mounted = false
  private disposed = false

  constructor(deps: ChatTerminalsDeps) {
    this.deps = deps
    this.parking = document.createElement('div')
    this.parking.dataset.chatParking = 'true'
    Object.assign(this.parking.style, {
      height: '0',
      left: '0',
      overflow: 'hidden',
      pointerEvents: 'none',
      position: 'fixed',
      top: '0',
      visibility: 'hidden',
      width: '0',
    })
  }

  // Put the parking element in the app root. Send each PTY chunk and exit to its terminal.
  mount(root: HTMLElement): void {
    if (this.mounted || this.disposed) return
    this.mounted = true
    root.append(this.parking)
    const { pty } = this.deps
    this.unsubscribe = [
      pty.onData((viewId, chunk) => this.terminalOf(viewId)?.write(chunk)),
      pty.onExit((viewId, exitCode) => this.terminalOf(viewId)?.exited(exitCode)),
      pty.onSize((viewId, size) => this.terminalOf(viewId)?.setSessionSize(size)),
    ]
  }

  // Make a terminal for each new open chat, and end the terminal of each closed chat.
  // Then give each terminal its view, its row and its WebGL state.
  sync(openIds: string[], rows: SessionRow[], loaded: boolean, views: Map<string, ChatView>): void {
    if (!this.mounted || this.disposed) return
    let changed = false
    for (const [id, terminal] of this.terminals) {
      if (openIds.includes(id)) continue
      this.terminals.delete(id)
      terminal.dispose()
      changed = true
    }
    for (const id of openIds) {
      if (this.terminals.has(id)) continue
      const terminal: ChatTerminal = new ChatTerminal(id, {
        font: this.font,
        history: this.historyOf(id),
        parking: this.parking,
        pty: this.deps.pty,
        // A newer window of the session uses the same view ID.
        replaced: () => {
          const current = this.terminals.get(id)
          return current !== undefined && current !== terminal
        },
      })
      this.terminals.set(id, terminal)
      changed = true
    }
    const gained = new Set(gainedFocus(this.views, views))
    this.views = views
    const byId = new Map(rows.map(row => [row.sessionId, row]))
    for (const id of openIds) {
      const terminal = this.terminals.get(id)
      if (!terminal) continue
      // The view comes first. So the first attach knows if the window shows.
      terminal.setView(views.get(id) ?? HIDDEN_VIEW, gained.has(id))
      terminal.setRow(byId.get(id), loaded)
    }
    this.planWebgl(openIds, views)
    this.pruneHistories(openIds)
    if (changed) for (const listener of this.listeners) listener()
  }

  // Use a new terminal font in each open terminal and in each new one.
  setFont(font: TerminalFont): void {
    if (this.disposed) return
    this.font = font
    for (const terminal of this.terminals.values()) terminal.setFont(font)
  }

  get(sessionId: string): ChatTerminal | undefined {
    return this.terminals.get(sessionId)
  }

  // For useSyncExternalStore. The listeners run when a terminal starts or ends.
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    for (const off of this.unsubscribe) off()
    this.unsubscribe = []
    for (const terminal of this.terminals.values()) terminal.dispose()
    this.terminals.clear()
    this.parking.remove()
  }

  private terminalOf(viewId: string): ChatTerminal | undefined {
    const id = chatSessionId(viewId)
    return id === null ? undefined : this.terminals.get(id)
  }

  private historyOf(sessionId: string): AttachHistory {
    let history = this.histories.get(sessionId)
    if (!history) {
      history = { times: [] }
      this.histories.set(sessionId, history)
    }
    return history
  }

  // Keep only the attaches of the last 60 seconds. Remove an empty history of a closed chat.
  private pruneHistories(openIds: string[]): void {
    const now = Date.now()
    for (const [id, history] of this.histories) {
      history.times = recentAttaches(history.times, now)
      if (history.times.length === 0 && !openIds.includes(id)) this.histories.delete(id)
    }
  }

  // Visible windows use WebGL, to a maximum of 12. The focused window gets it first.
  private planWebgl(openIds: string[], views: Map<string, ChatView>): void {
    const visible: string[] = []
    const loaded: string[] = []
    let focused: string | null = null
    for (const id of openIds) {
      const terminal = this.terminals.get(id)
      if (!terminal) continue
      const view = views.get(id) ?? HIDDEN_VIEW
      if (terminal.hasWebgl) loaded.push(id)
      if (!view.visible || terminal.webglFailed) continue
      visible.push(id)
      if (view.focused) focused = id
    }
    const plan = webglPlan(visible, loaded, MAX_WEBGL, focused)
    for (const id of plan.release) this.terminals.get(id)?.setWebgl(false)
    for (const id of plan.load) this.terminals.get(id)?.setWebgl(true)
  }
}

const ChatsContext = createContext<ChatTerminals | null>(null)

// One ChatTerminals for the app. It must be inside the registry and window manager providers.
export function ChatsProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const { frames } = useWmState()
  const { loaded, rows } = useRegistry()
  const { settings } = useSettings()
  const [chats] = useState(() => new ChatTerminals({ pty: window.bifrost.pty }))

  useLayoutEffect(() => {
    chats.mount(document.getElementById('root') ?? document.body)
    return () => chats.dispose()
  }, [chats])

  // The terminal font follows the setting. A new terminal also gets it.
  useLayoutEffect(() => {
    chats.setFont(settings.terminalFont)
  }, [chats, settings.terminalFont])

  // The lifecycle keys on the open chat panels, not on the React mounts (Review Focus 1).
  useEffect(() => {
    chats.sync(openChatIds(frames), rows, loaded, chatViews({ frames }))
  }, [chats, frames, rows, loaded])

  return <ChatsContext value={chats}>{children}</ChatsContext>
}

export function useChats(): ChatTerminals {
  const value = useContext(ChatsContext)
  if (!value) throw new Error('useChats needs a ChatsProvider.')
  return value
}
