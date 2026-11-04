import { contextBridge, type IpcRendererEvent, ipcRenderer } from 'electron'
import type { BifrostApi } from '../shared/api'

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
  agents: { list: all => ipcRenderer.invoke('agents:list', all) },
  claude: { run: (args, cwd) => ipcRenderer.invoke('claude:run', args, cwd) },
  claudePath: () => ipcRenderer.invoke('claude:path'),
  proc: { signal: (pid, signal) => ipcRenderer.invoke('proc:signal', pid, signal) },
  pty: {
    close: (viewId, signal) => ipcRenderer.invoke('pty:close', viewId, signal),
    onData: cb => subscribe('pty:data', cb),
    onExit: cb => subscribe('pty:exit', cb),
    open: (viewId, args, opts) => ipcRenderer.invoke('pty:open', viewId, args, opts),
    resize: (viewId, cols, rows) => ipcRenderer.invoke('pty:resize', viewId, cols, rows),
    write: (viewId, data) => ipcRenderer.invoke('pty:write', viewId, data),
  },
}

// The renderer gets only window.bifrost. Context isolation is on.
contextBridge.exposeInMainWorld('bifrost', api)
