import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import {
  app,
  type BrowserWindow,
  clipboard,
  type IpcMainInvokeEvent,
  ipcMain,
  type WebContents,
} from 'electron'
import { isPriority } from '../shared/priority'
import type { ClaudeVersion, DisplayMode } from '../shared/types'
import { CHAT_VIEW } from '../shared/view-id'
import { createActions } from './actions/actions'
import { findProjectApps } from './actions/project-apps'
import { hasLeftKey, SessionInput } from './actions/session-input'
import { type AgentList, listAgents } from './claude/agents'
import { createRunClaude, execFile, type RunClaude, resolveClaudePath } from './claude/cli'
import { checkClaudeVersion, MIN_CLAUDE_VERSION } from './claude/version'
import { loadLoginEnv } from './env/login-env'
import { type ActiveMarker, createActiveMarker } from './integration/active-marker'
import {
  defaultPaths,
  type IntegrationPaths,
  install,
  integrationStatus,
  previewInstall,
  uninstall,
} from './integration/integration'
import { createQuietMarker } from './integration/quiet-marker'
import { createSerialRunner } from './integration/serial'
import { checkChatOpen, REFUSED_NOT_CHAT } from './pty/can-attach'
import { nodePtySpawn } from './pty/node-pty-spawn'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'
import { chatSessionOf, readSessionSize, SessionSizeWatcher } from './pty/session-size'
import { cleanEventDir, drainEventDir } from './registry/event-dir'
import { readBranch } from './registry/git-branch'
import { PENDING_EVENT_MS, SessionRegistry } from './registry/registry'
import { RegistryService, type ServiceDeps } from './registry/service'
import { cleanStatusTemps, readStatusFiles, STATUS_TEMP_MAX_AGE_MS } from './registry/status-file'
import { openStore } from './registry/store-file'
import { openUiStore } from './store/ui-store'
import type { ModeController } from './window/display-mode'
import { isDisplayMode } from './window/window-state'

// A yellow box changes to red after 10 minutes.
const ESCALATION_MS = 600_000

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
// The main process sets liveService when the store loads.
let liveService: RegistryService | null = null
let serviceStopped = false
// The marker file that tells the scripts that Bifrost runs.
let activeMarker: ActiveMarker | null = null

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

// Delete old files from the time when Bifrost did not run. Then make the marker file.
// After this step, the scripts write event files and status files.
// An error here does not stop the service. The rows then come from claude agents only.
async function startScripts(paths: IntegrationPaths): Promise<void> {
  const now = Date.now()
  await cleanEventDir(join(paths.bifrostHome, 'events'), now, PENDING_EVENT_MS)
  await cleanStatusTemps(join(paths.bifrostHome, 'sessions'), now, STATUS_TEMP_MAX_AGE_MS)
  if (serviceStopped) return
  const marker = createActiveMarker(paths.bifrostHome)
  activeMarker = marker
  try {
    await marker.create()
  } catch (error) {
    console.warn('Bifrost could not make the active marker file:', error)
  }
  // The app can quit while create runs. Then delete the marker again.
  if (serviceStopped) marker.remove()
}

// Delete old files in the Bifrost directory and make the marker file.
// Then load the store and start the registry service.
// The service sends each update of the rows to the current window.
// If the store cannot be read, the service runs with an empty store and does not save.
async function startService(
  run: Promise<RunClaude | null>,
  paths: IntegrationPaths,
): Promise<RegistryService> {
  await startScripts(paths)
  const opened = await openStore(join(app.getPath('userData'), 'registry.json'))
  const list = async (all: boolean): Promise<AgentList> => {
    const runClaude = await run
    if (!runClaude) return { entries: [], error: 'claude not found' }
    return listAgents(runClaude, { all })
  }
  const now = (): number => Date.now()
  const sessionsDir = join(paths.bifrostHome, 'sessions')
  const deps: ServiceDeps = {
    drainEvents: () => drainEventDir(join(paths.bifrostHome, 'events'), now()),
    listActive: () => list(false),
    listAll: () => list(true),
    now,
    readBranch: cwd => readBranch(execFile, cwd),
    readStatus: () => readStatusFiles(sessionsDir),
    saveStore: store => opened.save(store),
  }
  const service = new RegistryService(
    new SessionRegistry({ escalationMs: ESCALATION_MS, store: opened.store }),
    deps,
  )
  // Owned sessions get the quiet file, so the wrapper does not run the original command for them.
  // mark never rejects. Do not wait for it.
  const quiet = createQuietMarker(sessionsDir)
  service.onUpdate((rows, error) => {
    send('registry:update', rows, error)
    void quiet.mark(rows)
  })
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
  const service = startService(run, paths)
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
  // The renderer sends IDs only. The main process finds the row, the path and the app.
  const exists = (path: string): Promise<boolean> =>
    access(path).then(
      () => true,
      () => false,
    )
  const actions = createActions({
    apps: () => findProjectApps(homedir(), exists),
    exec: execFile,
    rows: () => liveService?.rows() ?? [],
    writeClipboard: text => clipboard.writeText(text),
  })
  ipcMain.handle('actions:apps', e => fromPage(e, () => actions.listApps()))
  ipcMain.handle('actions:open-project', (e, sessionId: unknown, appId: unknown) =>
    fromPage(e, () => actions.openProject(sessionId, appId)),
  )
  ipcMain.handle('actions:copy-session-id', (e, sessionId: unknown) =>
    fromPage(e, () => actions.copySessionId(sessionId)),
  )
  // Only one of preview, install and uninstall runs at a time. A second call rejects.
  // These three handlers also reject for a settings file that is not valid.
  // The renderer gets the message of the Error as the rejection.
  const integration = createSerialRunner()
  ipcMain.handle('integration:status', e => fromPage(e, () => integrationStatus(paths)))
  ipcMain.handle('integration:preview', e =>
    fromPage(e, () => integration.run(() => previewInstall(paths, new Date()))),
  )
  ipcMain.handle('integration:install', e =>
    fromPage(e, () => integration.run(() => install(paths, new Date()))),
  )
  ipcMain.handle('integration:uninstall', e =>
    fromPage(e, () => integration.run(() => uninstall(paths, new Date()))),
  )
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

// Stop the registry service and delete the marker file. Call it when the app quits.
// Then the scripts stop their work, and no files collect while Bifrost is closed.
export function stopRegistry(): void {
  serviceStopped = true
  liveService?.stop()
  activeMarker?.remove()
}
