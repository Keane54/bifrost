import { contextBridge, type IpcRendererEvent, ipcRenderer } from 'electron'
import type { BifrostApi } from '../shared/api'

// Electron adds this text to the message of an Error from a handler in the main process.
const REMOTE_PREFIX = /^Error invoking remote method '[^']*': (?:\w*Error: )?/

// Call a handler in the main process.
// If the handler fails, reject with an Error that has only the message of the failure.
async function invoke<T>(channel: string, ...args: unknown[]): Promise<T> {
  try {
    return await ipcRenderer.invoke(channel, ...args)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(message.replace(REMOTE_PREFIX, ''))
  }
}

// Subscribe to one channel. The returned function removes only this listener.
function subscribe(channel: string, handler: (...args: never[]) => void): () => void {
  const wrapper = (_event: IpcRendererEvent, ...args: unknown[]): void =>
    handler(...(args as never[]))
  ipcRenderer.on(channel, wrapper)
  return () => {
    ipcRenderer.removeListener(channel, wrapper)
  }
}

const api: BifrostApi = {
  actions: {
    apps: () => invoke('actions:apps'),
    copySessionId: sessionId => invoke('actions:copy-session-id', sessionId),
    openProject: (sessionId, appId) => invoke('actions:open-project', sessionId, appId),
  },
  claudePath: () => invoke('claude:path'),
  claudeVersion: () => invoke('claude:version'),
  display: {
    get: () => invoke('display:get'),
    onChange: cb => subscribe('display:changed', cb),
    set: mode => invoke('display:set', mode),
  },
  input: {
    interrupt: sessionId => invoke('input:interrupt', sessionId),
    send: (sessionId, text) => invoke('input:send', sessionId, text),
  },
  integration: {
    install: () => invoke('integration:install'),
    preview: () => invoke('integration:preview'),
    status: () => invoke('integration:status'),
    uninstall: () => invoke('integration:uninstall'),
  },
  pty: {
    close: (viewId, signal) => invoke('pty:close', viewId, signal),
    onData: cb => subscribe('pty:data', cb),
    onExit: cb => subscribe('pty:exit', cb),
    onSize: cb => subscribe('pty:size', cb),
    open: (viewId, args, opts) => invoke('pty:open', viewId, args, opts),
    resize: (viewId, cols, rows) => invoke('pty:resize', viewId, cols, rows),
    sessionSize: sessionId => invoke('pty:session-size', sessionId),
    setBlocked: (viewId, blocked) => invoke('pty:set-blocked', viewId, blocked),
    write: (viewId, data) => invoke('pty:write', viewId, data),
  },
  registry: {
    acknowledge: sessionId => invoke('registry:ack', sessionId),
    onUpdate: cb => subscribe('registry:update', cb),
    rows: () => invoke('registry:rows'),
    setPriority: (sessionId, priority) => invoke('registry:set-priority', sessionId, priority),
  },
  ui: {
    load: () => invoke('ui:load'),
    save: data => invoke('ui:save', data),
  },
  wm: {
    onClosePanel: cb => subscribe('wm:close-panel', cb),
  },
}

// The renderer gets only window.bifrost. Context isolation is on.
contextBridge.exposeInMainWorld('bifrost', api)
