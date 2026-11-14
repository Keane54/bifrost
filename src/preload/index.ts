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
  claudeVersion: () => invoke('claude:version'),
  dailyUpdate: {
    copy: areaId => invoke('daily-update:copy', areaId),
    editDraft: (areaId, text) => invoke('daily-update:edit-draft', areaId, text),
    inventory: () => invoke('daily-update:inventory'),
    keepMine: areaId => invoke('daily-update:keep-mine', areaId),
    markSent: areaId => invoke('daily-update:mark-sent', areaId),
    onOpen: cb => subscribe('daily-update:open', cb),
    onUpdate: cb => subscribe('daily-update:update', cb),
    openItem: (areaId, itemId) => invoke('daily-update:open-item', areaId, itemId),
    redo: areaId => invoke('daily-update:redo', areaId),
    refresh: trigger => invoke('daily-update:refresh', trigger),
    setSkipped: skipped => invoke('daily-update:set-skipped', skipped),
    snapshot: () => invoke('daily-update:snapshot'),
    undoSent: areaId => invoke('daily-update:undo-sent', areaId),
    usePending: areaId => invoke('daily-update:use-pending', areaId),
  },
  dictation: {
    onEvent: cb => subscribe('dictation:event', cb),
    openSettings: pane => invoke('dictation:open-settings', pane),
    start: viewId => invoke('dictation:start', viewId),
    stop: viewId => invoke('dictation:stop', viewId),
    vimMode: () => invoke('dictation:vim-mode'),
    warm: () => invoke('dictation:warm'),
  },
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
  modules: {
    approve: requestId => invoke('modules:approve', requestId),
    call: (moduleId, name, args) => invoke('modules:call', moduleId, name, args),
    checkUpdates: () => invoke('modules:check-updates'),
    decline: requestId => invoke('modules:decline', requestId),
    discussCancel: requestId => invoke('modules:discuss-cancel', requestId),
    discussCopy: (requestId, cardIndex) => invoke('modules:discuss-copy', requestId, cardIndex),
    discussStart: (requestId, input) => invoke('modules:discuss-start', requestId, input),
    grant: (id, permission) => invoke('modules:grant', id, permission),
    installDev: () => invoke('modules:install-dev'),
    installFolder: () => invoke('modules:install-folder'),
    installGit: url => invoke('modules:install-git', url),
    onDiscuss: cb => subscribe('modules:discuss', cb),
    onEvent: cb => subscribe('modules:event', cb),
    onUpdate: cb => subscribe('modules:changed', cb),
    refresh: moduleId => invoke('modules:refresh', moduleId),
    remove: id => invoke('modules:remove', id),
    reviewUpdate: id => invoke('modules:review-update', id),
    revoke: (id, permission) => invoke('modules:revoke', id, permission),
    setCap: (id, cap) => invoke('modules:set-cap', id, cap),
    setEnabled: (id, on) => invoke('modules:set-enabled', id, on),
    setModel: (id, model) => invoke('modules:set-model', id, model),
    snapshot: () => invoke('modules:snapshot'),
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
  releaseNotes: {
    list: () => invoke('release-notes:list'),
    open: version => invoke('release-notes:open', version),
    whatsNew: () => invoke('release-notes:whats-new'),
  },
  reviews: {
    answer: (key, answers) => invoke('reviews:answer', key, answers),
    approve: key => invoke('reviews:approve', key),
    approveInstead: key => invoke('reviews:draft-approve', key),
    cancel: key => invoke('reviews:cancel', key),
    discardDraft: key => invoke('reviews:draft-discard', key),
    draft: key => invoke('reviews:draft', key),
    endPause: key => invoke('reviews:end-pause', key),
    handle: (key, what) => invoke('reviews:handle', key, what),
    onOpen: cb => subscribe('reviews:open', cb),
    onTrustData: cb => subscribe('reviews:trust-data', cb),
    onTrustEnd: cb => subscribe('reviews:trust-end', cb),
    onUpdate: cb => subscribe('reviews:update', cb),
    openComment: (key, itemId) => invoke('reviews:open-comment', key, itemId),
    openPr: key => invoke('reviews:open-pr', key),
    pause: key => invoke('reviews:pause', key),
    refresh: () => invoke('reviews:refresh'),
    remove: key => invoke('reviews:remove', key),
    removeClones: () => invoke('reviews:remove-clones'),
    retry: key => invoke('reviews:retry', key),
    review: key => invoke('reviews:review', key),
    sendDraft: (key, edits) => invoke('reviews:draft-send', key, edits),
    snapshot: () => invoke('reviews:snapshot'),
    stopSession: key => invoke('reviews:stop-session', key),
    trust: repo => invoke('reviews:trust-open', repo),
    trustClose: () => invoke('reviews:trust-close'),
    trustResize: (cols, rows) => invoke('reviews:trust-resize', cols, rows),
    trustWrite: data => invoke('reviews:trust-write', data),
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
    handOver: sessionId => invoke('sessions:hand-over', sessionId),
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
  skills: {
    disable: () => invoke('skills:disable'),
    enable: () => invoke('skills:enable'),
    install: () => invoke('skills:install'),
    status: () => invoke('skills:status'),
    uninstall: () => invoke('skills:uninstall'),
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
  window: {
    setVisible: visible => invoke('window:visible', visible),
  },
  wm: {
    onClosePanel: cb => subscribe('wm:close-panel', cb),
  },
}

// The renderer gets only window.bifrost. Context isolation is on.
contextBridge.exposeInMainWorld('bifrost', api)
