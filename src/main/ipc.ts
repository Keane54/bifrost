import { access, mkdir, rm, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import {
  app,
  type BrowserWindow,
  clipboard,
  dialog,
  type IpcMainInvokeEvent,
  ipcMain,
  nativeImage,
  type OpenDialogOptions,
  type WebContents,
} from 'electron'
import { isPriority } from '../shared/priority'
import { DEFAULT_SETTINGS, type Settings } from '../shared/settings'
import type { ClaudeVersion, DisplayMode, LiveStatus, WatchColour } from '../shared/types'
import { CHAT_VIEW } from '../shared/view-id'
import { isWatchColour } from '../shared/watch'
import { createActions } from './actions/actions'
import { appIcon } from './actions/app-icon'
import { dirInfo, isAlive, processName, sendSignal } from './actions/process-info'
import { findProjectApps, findTerminalApps } from './actions/project-apps'
import { createSessionActions } from './actions/session-actions'
import { hasLeftKey, SessionInput } from './actions/session-input'
import { createTerminalLauncher } from './actions/terminal-launch'
import { hasMessages } from './actions/transcript'
import { checkWorktreeHead, createWorktreeActions, trackedChanges } from './actions/worktree-check'
import { type AgentList, listAgents } from './claude/agents'
import { createRunClaude, execFile, type RunClaude, resolveClaudePath } from './claude/cli'
import { checkClaudeVersion, MIN_CLAUDE_VERSION } from './claude/version'
import { loadLoginEnv } from './env/login-env'
import {
  defaultPaths,
  keepOldScripts,
  oldInstallStatus,
  removeOldHookData,
  uninstall,
} from './integration/integration'
import { createSerialRunner } from './integration/serial'
import { createLiveControl, LIVE_MIN_CLAUDE_VERSION, type LiveControl } from './live/live-control'
import { createLiveServer } from './live/live-server'
import { modSourceDir } from './live/mod-folder'
import { createPluginCli } from './live/plugin-cli'
import { checkChatOpen, REFUSED_NOT_CHAT } from './pty/can-attach'
import { nodePtySpawn } from './pty/node-pty-spawn'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'
import { chatSessionOf, readSessionSize, SessionSizeWatcher } from './pty/session-size'
import { readBranch } from './registry/git-branch'
import { SessionRegistry } from './registry/registry'
import { RegistryService, SERVICE_TIMING, type ServiceDeps } from './registry/service'
import { openStore } from './registry/store-file'
import { readProcessTable } from './registry/terminal-app'
import { loginItemPatch, type SettingsEffect, settingsEffects } from './settings/effects'
import { openSettingsStore, type SettingsStore } from './store/settings-store'
import { openUiStore } from './store/ui-store'
import type { ModeController } from './window/display-mode'
import { isDisplayMode } from './window/window-state'

// The terminal sends this after a resize: clear the screen, then draw it again.
const FULL_REDRAW = '\x1b[2J'

let registered = false
let currentWindow: BrowserWindow | null = null
let managerPromise: Promise<PtyManager | null> | null = null
// The main process sets liveManager when managerPromise resolves.
// A PTY cannot exist before this time.
let liveManager: PtyManager | null = null
// All PTYs belong to the page that the current window shows.
const page = new PageScope(() => liveManager?.closeAll())

// The PID of the owned row that a chat view shows, or undefined.
function pidOfView(viewId: string): number | undefined {
  const sessionId = chatSessionOf(viewId)
  if (sessionId === null) return undefined
  return pidOfSession(sessionId)
}

function pidOfSession(sessionId: string): number | undefined {
  const row = liveService?.rows().find(r => r.sessionId === sessionId)
  return row && row.kind === 'owned' && row.state !== 'parked' ? row.pid : undefined
}

// Reads the session size after a redraw. It sends the size to the page when it changes.
const sizeWatcher = new SessionSizeWatcher({
  emit: (viewId, size) => send('pty:size', viewId, size),
  pidOf: pidOfView,
  read: pid => readSessionSize(execFile, pid),
})
// The main process sets liveService and liveRegistry when the store loads.
let liveService: RegistryService | null = null
let liveRegistry: SessionRegistry | null = null
// registerIpc opens the settings store one time (ruling C6). It is null until the store opens.
let settingsStore: SettingsStore | null = null
// index.ts gives the function that builds the app menu again.
let menuRebuild: (() => void) | null = null
let serviceStopped = false
// Live details. registerIpc sets it. stopRegistry stops its server.
let liveControl: LiveControl | null = null

// Return true if the sender is the page of the current window and that page did not end.
// The check compares the webContents IDs, not the objects.
function isLivePage(sender: WebContents, token: number): boolean {
  if (!page.isCurrent(token) || sender.isDestroyed()) return false
  if (currentWindow === null || currentWindow.isDestroyed()) return false
  return sender.id === currentWindow.webContents.id
}

// Run a call only when the sender is the page that the current window shows now.
// Another webContents must not read or change the integration of the user.
function fromPage<T>(e: IpcMainInvokeEvent, fn: () => Promise<T>): Promise<T> {
  if (!isLivePage(e.sender, page.token())) {
    return Promise.reject(new Error('refused: not the Bifrost page'))
  }
  return fn()
}

// The mode controller of the current window. index.ts sets it.
let modeController: ModeController | null = null

export function setModeController(controller: ModeController | null): void {
  modeController = controller
}

// Send an event to the current window. Do nothing if no window is open.
export function send(channel: string, ...args: unknown[]): void {
  if (currentWindow && !currentWindow.isDestroyed())
    currentWindow.webContents.send(channel, ...args)
}

// Set the function that builds the app menu again. A change of a menu key calls it.
export function setMenuRebuild(fn: (() => void) | null): void {
  menuRebuild = fn
}

// The current settings. Before the store opens, this gives the defaults.
export function getSettings(): Settings {
  return settingsStore?.get() ?? DEFAULT_SETTINGS
}

// Zoom the page of the current window (Interface scale, ruling C1).
function setZoom(factor: number): void {
  if (currentWindow && !currentWindow.isDestroyed()) currentWindow.webContents.setZoomFactor(factor)
}

// Apply the Interface scale of the settings. Do nothing before the store opens.
function applyZoom(): void {
  if (settingsStore) setZoom(settingsStore.get().interfaceScale / 100)
}

// Run one effect of a settings change (D2).
function runSettingsEffect(effect: SettingsEffect): void {
  switch (effect.kind) {
    case 'escalation':
      liveRegistry?.setEscalationMs(effect.ms)
      return
    case 'poll':
      liveService?.setActiveInterval(effect.ms)
      return
    case 'login-item':
      // A dev Electron binary must not become a login item (D2).
      if (app.isPackaged) app.setLoginItemSettings({ openAtLogin: effect.on })
      return
    case 'menu':
      menuRebuild?.()
      return
    case 'zoom':
      setZoom(effect.factor)
      return
  }
}

// Open the settings store. In the packaged app, the real login item state wins over the file
// (D2). Then send each change to the window and run its effects.
async function openSettings(file: string): Promise<SettingsStore> {
  const store = await openSettingsStore(file)
  if (app.isPackaged) {
    // A failure here must not stop the start.
    try {
      const patch = loginItemPatch(store.get(), app.getLoginItemSettings().openAtLogin)
      if (patch) await store.update(patch)
    } catch (err) {
      console.error('Bifrost cannot read or save the login item state.', err)
    }
  }
  store.onChange((next, prev) => {
    send('settings:changed', next)
    for (const effect of settingsEffects(prev, next)) {
      // A failed effect must not stop the other effects.
      try {
        runSettingsEffect(effect)
      } catch (err) {
        console.error(`Bifrost cannot apply the ${effect.kind} setting.`, err)
      }
    }
  })
  settingsStore = store
  applyZoom()
  return store
}

// Load the store and start the registry service.
// The service sends each update of the rows to the current window.
// If the store cannot be read, the service runs with an empty store and does not save.
// The escalation time and the poll interval come from the settings.
async function startService(
  run: Promise<RunClaude | null>,
  settingsReady: Promise<SettingsStore>,
): Promise<RegistryService> {
  const [opened, settings] = await Promise.all([
    openStore(join(app.getPath('userData'), 'registry.json')),
    settingsReady,
  ])
  const list = async (all: boolean): Promise<AgentList> => {
    const runClaude = await run
    if (!runClaude) return { entries: [], error: 'claude not found' }
    return listAgents(runClaude, { all })
  }
  const now = (): number => Date.now()
  const deps: ServiceDeps = {
    listActive: () => list(false),
    listAll: () => list(true),
    now,
    readBranch: cwd => readBranch(execFile, cwd),
    readProcessTable: () => readProcessTable(execFile),
    saveStore: store => opened.save(store),
  }
  // Read the settings after the waits. So a change during the waits is in the values.
  const current = settings.get()
  const registry = new SessionRegistry({
    escalationMs: current.escalationMinutes * 60_000,
    store: opened.store,
  })
  const service = new RegistryService(registry, deps, {
    ...SERVICE_TIMING,
    activeMs: current.pollSeconds * 1000,
  })
  service.onUpdate((rows, error) => {
    send('registry:update', rows, error)
  })
  liveRegistry = registry
  liveService = service
  // The app can quit before the store loads. Then do not start the service.
  if (!serviceStopped) service.start()
  return service
}

// Register all IPC handlers one time for the app process.
// Call it before any window loads a page. A second call does nothing.
// The main process finds the claude path one time. The renderer cannot set it.
export function registerIpc(): void {
  if (registered) return
  registered = true

  const claudePath = resolveClaudePath(execFile)
  // Start the login-shell env one time. Every claude run and every PTY uses it.
  // process.execPath runs as Node when ELECTRON_RUN_AS_NODE is 1.
  const loginEnv = loadLoginEnv(execFile, { execPath: process.execPath, fallback: process.env })
  const run = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createRunClaude(execFile, path, env) : null,
  )
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>
  // All text and keys that Bifrost types into a session go through this object (D1).
  // A hidden attach opens at the current size of the session (M3).
  const input = new SessionInput({
    pty: getManager,
    readSize: pid => readSessionSize(execFile, pid),
    rows: () => liveService?.rows() ?? [],
  })
  managerPromise = Promise.all([claudePath, loginEnv]).then(([path, env]) => {
    if (!path) return null
    const m = new PtyManager(nodePtySpawn, path, env)
    m.onData((viewId, chunk) => {
      input.data(viewId)
      // Only the main process uses the hidden send views. Their output stays here.
      if (CHAT_VIEW.test(viewId)) send('pty:data', viewId, chunk)
      // A full redraw follows a resize by any client (M0 question 1). So read the size.
      // A sequence split over two chunks is missed. The next redraw or the open recovers it.
      if (chunk.includes(FULL_REDRAW)) sizeWatcher.poke(viewId)
    })
    // close, closeAll and a replacing open do not run the exit callback. So forget here too.
    m.onClose(viewId => {
      sizeWatcher.forget(viewId)
      input.ended(viewId)
    })
    m.onExit((viewId, exitCode, signal) => {
      sizeWatcher.forget(viewId)
      input.ended(viewId)
      if (CHAT_VIEW.test(viewId)) send('pty:exit', viewId, exitCode, signal)
    })
    liveManager = m
    return m
  })
  const paths = defaultPaths(homedir())
  // The settings store opens one time. Each user gets the same store (ruling C6).
  const settings = openSettings(join(app.getPath('userData'), 'settings.json'))
  const service = startService(run, settings)
  ipcMain.handle('settings:get', e => fromPage(e, async () => (await settings).get()))
  // The store checks each value. It refuses a patch with an unknown key or a bad value.
  ipcMain.handle('settings:set', (e, patch: unknown) =>
    fromPage(e, async () => (await settings).update(patch)),
  )
  ipcMain.handle('system:info', e =>
    fromPage(e, async () => ({ packaged: app.isPackaged, version: app.getVersion() })),
  )
  // The UI store opens one time. The handlers use the same store.
  const uiStore = openUiStore(join(app.getPath('userData'), 'ui-state.json'))
  ipcMain.handle('ui:load', e => fromPage(e, async () => (await uiStore).load()))
  ipcMain.handle('ui:save', (e, data: unknown) =>
    fromPage(e, async () => (await uiStore).save(data)),
  )

  ipcMain.handle('display:get', e =>
    fromPage(e, async (): Promise<DisplayMode> => modeController?.get() ?? 'window'),
  )
  ipcMain.handle('display:set', (e, mode: unknown) =>
    fromPage(e, async () => {
      if (!isDisplayMode(mode)) throw new Error('refused: not a display mode')
      if (!modeController) throw new Error('refused: no window')
      await modeController.set(mode)
    }),
  )

  ipcMain.handle('claude:path', () => claudePath)
  ipcMain.handle('claude:version', async (): Promise<ClaudeVersion> => {
    const runClaude = await run
    if (!runClaude) return { minimum: MIN_CLAUDE_VERSION, ok: false, version: null }
    return checkClaudeVersion(runClaude)
  })
  ipcMain.handle('registry:rows', async () => (await service).rows())
  ipcMain.handle('registry:ack', async (_e, sessionId: unknown) => {
    if (typeof sessionId === 'string') (await service).acknowledge(sessionId)
  })
  ipcMain.handle('registry:set-priority', (e, sessionId: unknown, priority: unknown) =>
    fromPage(e, async () => {
      if (typeof sessionId !== 'string' || (priority !== null && !isPriority(priority))) {
        throw new Error('refused: bad priority')
      }
      if (!(await service).setPriority(sessionId, priority)) {
        throw new Error('refused: unknown session')
      }
    }),
  )
  // Each watchlist handler checks the input. Then the service changes the watchlist.
  const watchHandler = (
    channel: string,
    change: (service: RegistryService, a: string, b: unknown) => boolean,
    valid: (a: unknown, b: unknown) => boolean,
    code: string,
  ): void => {
    ipcMain.handle(channel, (e, a: unknown, b: unknown) =>
      fromPage(e, async () => {
        if (typeof a !== 'string') throw new Error('refused: bad session ID')
        if (!valid(a, b)) throw new Error(code)
        if (!change(await service, a, b)) throw new Error('refused: unknown session')
      }),
    )
  }
  watchHandler(
    'registry:watch-add',
    (s, id, colour) => s.watchAdd(id, colour as WatchColour),
    (_id, colour) => isWatchColour(colour),
    'refused: bad watch colour',
  )
  watchHandler(
    'registry:watch-remove',
    (s, id) => s.watchRemove(id),
    () => true,
    'refused: bad session ID',
  )
  watchHandler(
    'registry:watch-colour',
    (s, id, colour) => s.watchColour(id, colour as WatchColour),
    (_id, colour) => isWatchColour(colour),
    'refused: bad watch colour',
  )
  watchHandler(
    'registry:watch-move',
    (s, id, before) => s.watchMove(id, before as string | null),
    (_id, before) => before === null || typeof before === 'string',
    'refused: bad watch move',
  )
  // The renderer sends IDs only. The main process finds the row, the path and the app.
  const exists = (path: string): Promise<boolean> =>
    access(path).then(
      () => true,
      () => false,
    )
  const actions = createActions({
    apps: () => findProjectApps(homedir(), exists, getSettings().terminalApp),
    exec: execFile,
    rows: () => liveService?.rows() ?? [],
    writeClipboard: text => clipboard.writeText(text),
  })
  ipcMain.handle('actions:apps', e => fromPage(e, () => actions.listApps()))
  // The terminal apps for the Settings select. The list has the IDs and the labels only.
  ipcMain.handle('actions:terminal-apps', e =>
    fromPage(e, async () =>
      (await findTerminalApps(homedir(), exists)).map(({ id, label }) => ({ id, label })),
    ),
  )
  ipcMain.handle('actions:open-project', (e, sessionId: unknown, appId: unknown) =>
    fromPage(e, () => actions.openProject(sessionId, appId)),
  )
  ipcMain.handle('actions:copy-session-id', (e, sessionId: unknown) =>
    fromPage(e, () => actions.copySessionId(sessionId)),
  )
  // Open in terminal. The command files are in <bifrostHome>/run and only the user can use them.
  const runDir = join(paths.bifrostHome, 'run')
  const terminals = createTerminalLauncher({
    apps: () => findProjectApps(homedir(), exists, getSettings().terminalApp),
    claudePath: () => claudePath,
    exec: execFile,
    fileIcon: path =>
      appIcon(path, {
        fileIcon: (file, size) => app.getFileIcon(file, { size }),
        thumbnail: (file, width, height) =>
          nativeImage.createThumbnailFromPath(file, { height, width }),
      }),
    remove: file => rm(file, { force: true }),
    rows: () => liveService?.rows() ?? [],
    runDir,
    terminalOf: id => liveService?.terminalOf(id),
    writeClipboard: text => clipboard.writeText(text),
    writeScript: async (file, text) => {
      await mkdir(runDir, { mode: 0o700, recursive: true })
      await writeFile(file, text, { mode: 0o700 })
    },
  })
  ipcMain.handle('actions:open-in-terminal', (e, sessionId: unknown) =>
    fromPage(e, () => terminals.openInTerminal(sessionId)),
  )
  ipcMain.handle('actions:terminal-icon', (e, sessionId: unknown) =>
    fromPage(e, () => terminals.terminalIcon(sessionId)),
  )
  // The session commands. The renderer sends session IDs and the New session values only.
  // The main process finds the row, the PID and the directory, and makes the claude arguments.
  // SIGTERM goes only to the process of an external session in Take control (D6).
  // process-info refuses a PID that is not an integer above 1, before each kill.
  const kill = (pid: number, signal: string | number): void => {
    process.kill(pid, signal)
  }
  // Take control reads only the start of the transcript of the session (Task 15).
  const projectsDir = join(homedir(), '.claude', 'projects')
  const sessions = createSessionActions({
    checkWorktree: worktree => checkWorktreeHead(worktree, execFile),
    dirInfo: dir => dirInfo(execFile, stat, dir),
    forget: id => liveService?.forget(id),
    hasMessages: id => hasMessages(projectsDir, id),
    isAlive: pid => isAlive(kill, pid),
    markStarted: id => liveService?.markStarted(id),
    markStopped: id => liveService?.markStopped(id),
    processName: pid => processName(execFile, pid),
    rememberWorktree: (id, worktree) => {
      liveService?.rememberWorktree(id, worktree)
    },
    rows: () => liveService?.rows() ?? [],
    run: () => run,
    signal: (pid, signal) => sendSignal(kill, pid, signal),
    trackedChanges: worktree => trackedChanges(worktree, execFile),
    waitForRow: async (match, timeoutMs) => (await service).waitForRow(match, timeoutMs),
  })
  const worktrees = createWorktreeActions({
    exec: execFile,
    rows: () => liveService?.rows() ?? [],
  })
  ipcMain.handle('sessions:delete-check', (e, sessionId: unknown) =>
    fromPage(e, () => worktrees.deleteCheck(sessionId)),
  )
  ipcMain.handle('sessions:open-worktree', (e, sessionId: unknown) =>
    fromPage(e, () => worktrees.openWorktree(sessionId)),
  )
  ipcMain.handle('sessions:create', (e, spec: unknown) => fromPage(e, () => sessions.create(spec)))
  ipcMain.handle('sessions:stop', (e, sessionId: unknown) =>
    fromPage(e, () => sessions.stop(sessionId)),
  )
  // seen is the check that the Delete dialog showed. session-actions checks each value.
  ipcMain.handle('sessions:remove', (e, sessionId: unknown, confirmed: unknown, seen: unknown) =>
    fromPage(e, () => sessions.remove(sessionId, confirmed, seen)),
  )
  ipcMain.handle('sessions:resume', (e, sessionId: unknown) =>
    fromPage(e, () => sessions.resume(sessionId)),
  )
  ipcMain.handle('sessions:resume-all', e => fromPage(e, () => sessions.resumeAll()))
  ipcMain.handle('sessions:take-control', (e, sessionId: unknown, confirmed: unknown) =>
    fromPage(e, () => sessions.takeControl(sessionId, confirmed)),
  )
  ipcMain.handle('sessions:dir-info', (e, dir: unknown) => fromPage(e, () => sessions.dirInfo(dir)))
  // The picker starts at the directory from the renderer when it is absolute, else at home.
  ipcMain.handle('sessions:pick-directory', (e, defaultPath: unknown) =>
    fromPage(e, async () => {
      const options: OpenDialogOptions = {
        defaultPath:
          typeof defaultPath === 'string' && defaultPath.startsWith('/') ? defaultPath : homedir(),
        properties: ['openDirectory', 'createDirectory'],
      }
      const win = currentWindow && !currentWindow.isDestroyed() ? currentWindow : null
      const result = await (win
        ? dialog.showOpenDialog(win, options)
        : dialog.showOpenDialog(options))
      return result.canceled ? null : (result.filePaths[0] ?? null)
    }),
  )
  // Only one Live details action runs at a time. A second call rejects. The start runs first,
  // and an action that comes during the start waits for it.
  const serial = createSerialRunner()
  // Live details. One server listens for the lines of the mod (D9).
  // The four actions use one serial runner. Then the removal of an old hook install and a plugin
  // command never run at the same time.
  const liveServer = createLiveServer({
    now: () => Date.now(),
    onEvent: ev => liveService?.pushLive(ev),
    socketPath: join(paths.bifrostHome, 'live.sock'),
  })
  const live = createLiveControl({
    clearLive: () => liveService?.clearLive(),
    cli: async () => {
      const runClaude = await run
      return runClaude ? createPluginCli(runClaude) : null
    },
    forceListen: process.env.BIFROST_LIVE_LISTEN === '1',
    liveSessions: () => liveService?.liveCount() ?? 0,
    modDir: join(paths.bifrostHome, 'mod'),
    modSource: modSourceDir(app.getAppPath()),
    oldInstall: () => oldInstallStatus(paths),
    removeOldInstall: () => uninstall(paths, new Date()),
    server: liveServer,
    version: async (): Promise<ClaudeVersion> => {
      const runClaude = await run
      if (!runClaude) return { minimum: LIVE_MIN_CLAUDE_VERSION, ok: false, version: null }
      return checkClaudeVersion(runClaude, LIVE_MIN_CLAUDE_VERSION)
    },
  })
  liveControl = live
  // Nothing else cleans the data of the old hooks. Remove it one time at start, before the live
  // control starts. keepOldScripts decides if bin/ stays.
  // A failure never stops the start.
  const cleanOldHookData = async (): Promise<void> => {
    try {
      const old = await oldInstallStatus(paths)
      await removeOldHookData(paths.bifrostHome, keepOldScripts(old))
    } catch (err) {
      console.warn('Live details: the clean-up of old hook data failed.', err)
    }
  }
  // Start after the service loads, so an event finds the service.
  // Do not start when the app quits before the store loads.
  // The start runs first in the serial runner of the four actions. An action that comes before
  // the start ends waits for it. So two copies of the mod folder never run at the same time.
  void serial
    .runFirst(async () => {
      await service
      if (serviceStopped) return
      await cleanOldHookData()
      if (!serviceStopped) await live.start()
    })
    .catch(err => console.warn('Live details: the start failed.', err))
  const liveAction = (channel: string, fn: () => Promise<LiveStatus>): void => {
    ipcMain.handle(channel, e => fromPage(e, () => serial.run(fn)))
  }
  ipcMain.handle('live:status', e => fromPage(e, () => live.status()))
  liveAction('live:install', () => live.install())
  liveAction('live:enable', () => live.enable())
  liveAction('live:disable', () => live.disable())
  liveAction('live:uninstall', () => live.uninstall())
  // The renderer can open, write, resize and close only chat views.
  // Only the main process uses send views (D1).
  const isChatView = (viewId: unknown): viewId is string =>
    typeof viewId === 'string' && CHAT_VIEW.test(viewId)
  ipcMain.handle(
    'pty:open',
    async (
      e,
      viewId: unknown,
      args: string[],
      opts: { cwd: string; cols: number; rows: number },
    ) => {
      if (!isChatView(viewId)) throw new Error(REFUSED_NOT_CHAT)
      // Get the page token before the first wait.
      const token = page.token()
      const manager = await getManager()
      if (!manager) throw new Error('claude not found')
      // Open a PTY only for an attach to an owned session that is not parked.
      // The attach must be for the session of the chat view.
      const first = checkChatOpen((await service).rows(), viewId, args)
      if (!first.ok) throw new Error(first.reason)
      // One attach serves each session. Wait until a hidden send of this session ends (D1).
      await input.idle(first.sessionId)
      // The rows can change during the wait. Check them again.
      const again = checkChatOpen((await service).rows(), viewId, args)
      if (!again.ok) throw new Error(again.reason)
      // The page can end during the waits above. Then no page owns the PTY, so do not open it.
      if (!isLivePage(e.sender, token)) {
        throw new Error('refused: the page that asked for the PTY is gone')
      }
      const pid = manager.open(viewId, args, { ...opts, cwd: resolve(process.cwd(), opts.cwd) })
      input.opened(viewId, args[1])
      sizeWatcher.poke(viewId)
      return pid
    },
  )
  ipcMain.handle('pty:write', async (_e, viewId: unknown, data: unknown) => {
    if (!isChatView(viewId) || typeof data !== 'string') return false
    // The left arrow key can open the agent view. A send to this view then waits (spec 8.5).
    if (hasLeftKey(data)) input.leftKey(viewId)
    const manager = await getManager()
    return manager ? manager.write(viewId, data) : false
  })
  ipcMain.handle('pty:resize', async (_e, viewId: unknown, cols: number, rows: number) => {
    if (!isChatView(viewId)) return
    ;(await getManager())?.resize(viewId, cols, rows)
  })
  ipcMain.handle('pty:close', async (_e, viewId: unknown, signal?: string) => {
    if (!isChatView(viewId)) return
    sizeWatcher.forget(viewId)
    input.ended(viewId)
    ;(await getManager())?.close(viewId, signal)
  })
  // The renderer reports the agent view of a chat window. Then a send to it rejects.
  ipcMain.handle('pty:set-blocked', (e, viewId: unknown, blocked: unknown) =>
    fromPage(e, async () => input.setBlocked(viewId, blocked)),
  )
  // The renderer sends the session ID and the text only. The main process finds the row,
  // checks it and the red box, and writes into the chat PTY or a hidden attach.
  ipcMain.handle('input:send', (e, sessionId: unknown, text: unknown) =>
    fromPage(e, () => input.send(sessionId, text)),
  )
  ipcMain.handle('input:interrupt', (e, sessionId: unknown) =>
    fromPage(e, () => input.interrupt(sessionId)),
  )
  // The size of the session TTY. The row must be owned and have a PID. Bifrost only reads it.
  ipcMain.handle('pty:session-size', (e, sessionId: unknown) =>
    fromPage(e, async () => {
      if (typeof sessionId !== 'string') return null
      await service
      const pid = pidOfSession(sessionId)
      return pid === undefined ? null : readSessionSize(execFile, pid)
    }),
  )
}

// Make a window the target of pty:data, pty:exit and registry:update.
// A reload or a renderer crash does not run the cleanup code of the page.
// The main process must close the PTYs of the old page.
// It closes all PTYs when a new page loads and when the renderer stops.
// When the window closes, close all PTYs and clear the window reference.
export function attachWindow(win: BrowserWindow): void {
  currentWindow = win
  win.webContents.on('did-navigate', () => page.end())
  // Apply the Interface scale to each page that loads.
  win.webContents.on('dom-ready', () => {
    if (currentWindow === win) applyZoom()
  })
  win.webContents.on('render-process-gone', () => page.end())
  win.on('closed', () => {
    if (currentWindow === win) currentWindow = null
    page.end()
  })
}

// Close all PTYs. Call it when the app quits.
export function closeAllPtys(): void {
  page.end()
}

// Stop the registry service and the server of Live details. Call it when the app quits.
export function stopRegistry(): void {
  serviceStopped = true
  liveService?.stop()
  liveControl?.stop()
}
