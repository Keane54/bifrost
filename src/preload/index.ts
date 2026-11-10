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
    openInTerminal: sessionId => invoke('actions:open-in-terminal', sessionId),
    openProject: (sessionId, appId) => invoke('actions:open-project', sessionId, appId),
    terminalApps: () => invoke('actions:terminal-apps'),
    terminalIcon: sessionId => invoke('actions:terminal-icon', sessionId),
  },
  alerts: {
    onOpen: cb => subscribe('alerts:open', cb),
  },
  claudePath: () => invoke('claude:path'),
  claudeVersion: () => invoke('claude:version'),
  display: {
    get: () => invoke('display:get'),
    onChange: cb => subscribe('display:changed', cb),
    set: mode => invoke('display:set', mode),
  },
  events: {
    list: () => invoke('events:list'),
    onAppend: cb => subscribe('events:append', cb),
  },
  info: {
    openPr: sessionId => invoke('info:open-pr', sessionId),
    pr: sessionId => invoke('info:pr', sessionId),
  },
  input: {
    interrupt: sessionId => invoke('input:interrupt', sessionId),
    send: (sessionId, text) => invoke('input:send', sessionId, text),
  },
  live: {
    disable: () => invoke('live:disable'),
    enable: () => invoke('live:enable'),
    install: () => invoke('live:install'),
    status: () => invoke('live:status'),
    uninstall: () => invoke('live:uninstall'),
  },
  performance: {
    clear: () => invoke('performance:clear'),
    fps: value => invoke('performance:fps', value),
    onUpdate: cb => subscribe('performance:update', cb),
    snapshot: () => invoke('performance:snapshot'),
    view: v => invoke('performance:view', v),
  },
  pty: {
    close: (viewId, signal) => invoke('pty:close', viewId, signal),
    onData: cb => subscribe('pty:data', cb),
    onExit: cb => subscribe('pty:exit', cb),
    onSize: cb => subscribe('pty:size', cb),
    open: (viewId, args, opts) => invoke('pty:open', viewId, args, opts),
    openLink: uri => invoke('pty:open-link', uri),
    resize: (viewId, cols, rows) => invoke('pty:resize', viewId, cols, rows),
    sessionSize: sessionId => invoke('pty:session-size', sessionId),
    setBlocked: (viewId, blocked) => invoke('pty:set-blocked', viewId, blocked),
    write: (viewId, data) => invoke('pty:write', viewId, data),
  },
  registry: {
    onUpdate: cb => subscribe('registry:update', cb),
    rows: () => invoke('registry:rows'),
    setAlias: (sessionId, name) => invoke('registry:set-alias', sessionId, name),
    setPriority: (sessionId, priority) => invoke('registry:set-priority', sessionId, priority),
    watch: {
      add: (sessionId, colour) => invoke('registry:watch-add', sessionId, colour),
      colour: (sessionId, colour) => invoke('registry:watch-colour', sessionId, colour),
      move: (sessionId, beforeSessionId) =>
        invoke('registry:watch-move', sessionId, beforeSessionId),
      remove: sessionId => invoke('registry:watch-remove', sessionId),
    },
  },
  reviews: {
    endPause: key => invoke('reviews:end-pause', key),
    onOpen: cb => subscribe('reviews:open', cb),
    onUpdate: cb => subscribe('reviews:update', cb),
    openPr: key => invoke('reviews:open-pr', key),
    pause: key => invoke('reviews:pause', key),
    refresh: () => invoke('reviews:refresh'),
    snapshot: () => invoke('reviews:snapshot'),
  },
  service: {
    onUpdate: cb => subscribe('service:update', cb),
    openPage: id => invoke('service:open-page', id),
    status: () => invoke('service:status'),
  },
  sessions: {
    create: spec => invoke('sessions:create', spec),
    deleteCheck: sessionId => invoke('sessions:delete-check', sessionId),
    dirInfo: dir => invoke('sessions:dir-info', dir),
    openWorktree: sessionId => invoke('sessions:open-worktree', sessionId),
    pickDirectory: defaultPath => invoke('sessions:pick-directory', defaultPath),
    remove: (sessionId, confirmed, seen) => invoke('sessions:remove', sessionId, confirmed, seen),
    resume: sessionId => invoke('sessions:resume', sessionId),
    resumeAll: () => invoke('sessions:resume-all'),
    stop: sessionId => invoke('sessions:stop', sessionId),
    takeControl: (sessionId, confirmed) => invoke('sessions:take-control', sessionId, confirmed),
  },
  settings: {
    get: () => invoke('settings:get'),
    onChange: cb => subscribe('settings:changed', cb),
    recording: on => invoke('settings:recording', on),
    set: patch => invoke('settings:set', patch),
  },
  system: {
    info: () => invoke('system:info'),
  },
  ui: {
    load: () => invoke('ui:load'),
    save: data => invoke('ui:save', data),
  },
  updates: {
    check: () => invoke('updates:check'),
    onUpdate: cb => subscribe('updates:update', cb),
    restart: () => invoke('updates:restart'),
    showLog: () => invoke('updates:show-log'),
    snapshot: () => invoke('updates:snapshot'),
  },
  usage: {
    get: () => invoke('usage:get'),
    getAccount: () => invoke('usage:account-get'),
    hudOpened: () => invoke('usage:hud-opened'),
    onAccountUpdate: cb => subscribe('usage:account-update', cb),
    onOpen: cb => subscribe('usage:open', cb),
    onUpdate: cb => subscribe('usage:update', cb),
  },
  wm: {
    onClosePanel: cb => subscribe('wm:close-panel', cb),
  },
}

// The renderer gets only window.bifrost. Context isolation is on.
contextBridge.exposeInMainWorld('bifrost', api)
