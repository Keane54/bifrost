// The IPC handlers of dictation (dictation design). ipc.ts registers them with ipcMain.handle and
// its fromPage check. A chat window warms the speech helper when it gets the focus. The page can
// start and stop dictation only for a chat view. A start also needs the terminal of that chat,
// because the typed text goes to it. Before a start, the page reads the vim mode of Claude
// (ruling D7). A notice of a denied permission opens one of two panes of System Settings. The
// page sends only the name of the pane, and this module has the two addresses.
import type { IpcMainInvokeEvent } from 'electron'
import type { DictationViewEvent, PrivacyPane } from '../../shared/dictation-protocol'
import { CHAT_VIEW } from '../../shared/view-id'
import { REFUSED_NOT_CHAT } from '../pty/can-attach'
import { type DictationService, REFUSED_NO_TERMINAL } from './dictation-service'

type Listener = (e: IpcMainInvokeEvent, ...args: unknown[]) => Promise<unknown>

// A pane name that is not in the list.
export const REFUSED_PANE = 'refused: not a System Settings pane of dictation'

// The panes of System Settings for the microphone and for Speech Recognition (dictation design 7).
const PANE_URLS: Readonly<Record<PrivacyPane, string>> = {
  microphone: 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
  'speech-recognition':
    'x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition',
}

// The address of a pane, or null for a value that is not a pane name of the list.
function paneUrl(value: unknown): string | null {
  if (value === 'microphone' || value === 'speech-recognition') return PANE_URLS[value]
  return null
}

export interface DictationIpcDeps {
  // ipcMain.handle.
  handle(channel: string, listener: Listener): void
  // Run fn only for the page of the current window.
  fromPage<T>(e: IpcMainInvokeEvent, fn: () => Promise<T>): Promise<T>
  // True when the chat view has an open terminal.
  hasTerminal(viewId: string): boolean
  service(): DictationService | null
  // True when the settings of Claude turn vim mode on (vim-mode.ts).
  vimMode(): Promise<boolean>
  // shell.openExternal. It gets only an address of PANE_URLS.
  openExternal(url: string): Promise<void>
}

const isChatView = (value: unknown): value is string =>
  typeof value === 'string' && CHAT_VIEW.test(value)

export function registerDictationIpc(deps: DictationIpcDeps): void {
  deps.handle('dictation:warm', e =>
    deps.fromPage(e, async () => {
      deps.service()?.warm()
    }),
  )
  deps.handle('dictation:start', (e, viewId) =>
    deps.fromPage(e, async () => {
      if (!isChatView(viewId)) throw new Error(REFUSED_NOT_CHAT)
      if (!deps.hasTerminal(viewId)) throw new Error(REFUSED_NO_TERMINAL)
      deps.service()?.start(viewId)
    }),
  )
  deps.handle('dictation:vim-mode', e => deps.fromPage(e, () => deps.vimMode()))
  deps.handle('dictation:open-settings', (e, pane) =>
    deps.fromPage(e, async () => {
      const url = paneUrl(pane)
      if (url === null) throw new Error(REFUSED_PANE)
      await deps.openExternal(url)
    }),
  )
  // A stop needs no terminal. The chat can close during a dictation.
  deps.handle('dictation:stop', (e, viewId) =>
    deps.fromPage(e, async () => {
      if (!isChatView(viewId)) throw new Error(REFUSED_NOT_CHAT)
      deps.service()?.stop(viewId)
    }),
  )
}

// The send of the dictation service. An event goes only to a chat view that has a terminal. So no
// event goes to a chat window that closed.
export function chatEventSender(
  hasTerminal: (viewId: string) => boolean,
  send: (channel: string, ...args: unknown[]) => void,
): (viewId: string, event: DictationViewEvent) => void {
  return (viewId, event) => {
    if (hasTerminal(viewId)) send('dictation:event', viewId, event)
  }
}
