import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import {
  app,
  type BrowserWindow,
  type IpcMainInvokeEvent,
  ipcMain,
  type WebContents,
} from 'electron'
import type { ClaudeVersion } from '../shared/types'
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
import { canAttach } from './pty/can-attach'
import { nodePtySpawn } from './pty/node-pty-spawn'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'
import { cleanEventDir, drainEventDir } from './registry/event-dir'
import { readBranch } from './registry/git-branch'
import { PENDING_EVENT_MS, SessionRegistry } from './registry/registry'
import { RegistryService, type ServiceDeps } from './registry/service'
import { cleanStatusTemps, readStatusFiles, STATUS_TEMP_MAX_AGE_MS } from './registry/status-file'
import { openStore } from './registry/store-file'
import { openUiStore } from './store/ui-store'

// A yellow box changes to red after 10 minutes.
const ESCALATION_MS = 600_000

let registered = false
let currentWindow: BrowserWindow | null = null
let managerPromise: Promise<PtyManager | null> | null = null
// The main process sets liveManager when managerPromise resolves.
// A PTY cannot exist before this time.
let liveManager: PtyManager | null = null
// All PTYs belong to the page that the current window shows.
const page = new PageScope(() => liveManager?.closeAll())
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

// Send an event to the current window. Do nothing if no window is open.
function send(channel: string, ...args: unknown[]): void {
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
  managerPromise = Promise.all([claudePath, loginEnv]).then(([path, env]) => {
    if (!path) return null
    const m = new PtyManager(nodePtySpawn, path, env)
    m.onData((viewId, chunk) => send('pty:data', viewId, chunk))
    m.onExit((viewId, exitCode, signal) => send('pty:exit', viewId, exitCode, signal))
    liveManager = m
    return m
  })
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>
  const paths = defaultPaths(homedir())
  const service = startService(run, paths)
  // The UI store opens one time. The handlers use the same store.
  const uiStore = openUiStore(join(app.getPath('userData'), 'ui-state.json'))
  ipcMain.handle('ui:load', e => fromPage(e, async () => (await uiStore).load()))
  ipcMain.handle('ui:save', (e, data: unknown) =>
    fromPage(e, async () => (await uiStore).save(data)),
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
  ipcMain.handle(
    'pty:open',
    async (
      e,
      viewId: string,
      args: string[],
      opts: { cwd: string; cols: number; rows: number },
    ) => {
      // Get the page token before the first wait.
      const token = page.token()
      const manager = await getManager()
      if (!manager) throw new Error('claude not found')
      // Open a PTY only for an attach to an owned session that is not parked.
      if (!canAttach((await service).rows(), args)) {
        throw new Error('refused: not an attach to an owned session that is not parked')
      }
      // The page can end during the waits above. Then no page owns the PTY, so do not open it.
      if (!isLivePage(e.sender, token)) {
        throw new Error('refused: the page that asked for the PTY is gone')
      }
      return manager.open(viewId, args, { ...opts, cwd: resolve(process.cwd(), opts.cwd) })
    },
  )
  ipcMain.handle('pty:write', async (_e, viewId: string, data: string) => {
    const manager = await getManager()
    return manager ? manager.write(viewId, data) : false
  })
  ipcMain.handle('pty:resize', async (_e, viewId: string, cols: number, rows: number) => {
    ;(await getManager())?.resize(viewId, cols, rows)
  })
  ipcMain.handle('pty:close', async (_e, viewId: string, signal?: string) => {
    ;(await getManager())?.close(viewId, signal)
  })
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
