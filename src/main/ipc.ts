import { resolve } from 'node:path'
import { type BrowserWindow, ipcMain, type WebContents } from 'electron'
import { listAgents } from './claude/agents'
import { createRunClaude, execFile, resolveClaudePath } from './claude/cli'
import { canOpenPty, canRunClaude, canSignal } from './claude/guard'
import { loadLoginEnv } from './env/login-env'
import { nodePtySpawn } from './pty/node-pty-spawn'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'

const ALLOWED_SIGNALS = ['SIGTERM', 'SIGHUP', 'SIGINT']

let registered = false
let currentWindow: BrowserWindow | null = null
let managerPromise: Promise<PtyManager | null> | null = null
// The main process sets liveManager when managerPromise resolves.
// A PTY cannot exist before this time.
let liveManager: PtyManager | null = null
// All PTYs belong to the page that the current window shows.
const page = new PageScope(() => liveManager?.closeAll())

// Return true if the sender is the page of the current window and that page did not end.
// The check compares the webContents IDs, not the objects.
function isLivePage(sender: WebContents, token: number): boolean {
  if (!page.isCurrent(token) || sender.isDestroyed()) return false
  if (currentWindow === null || currentWindow.isDestroyed()) return false
  return sender.id === currentWindow.webContents.id
}

// Send an event to the current window. Do nothing if no window is open.
function send(channel: string, ...args: unknown[]): void {
  if (currentWindow && !currentWindow.isDestroyed())
    currentWindow.webContents.send(channel, ...args)
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
  managerPromise = Promise.all([claudePath, loginEnv]).then(([path, env]) => {
    if (!path) return null
    const m = new PtyManager(nodePtySpawn, path, env)
    m.onData((viewId, chunk) => send('pty:data', viewId, chunk))
    m.onExit((viewId, exitCode, signal) => send('pty:exit', viewId, exitCode, signal))
    liveManager = m
    return m
  })
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>

  ipcMain.handle('claude:path', () => claudePath)
  ipcMain.handle('agents:list', async (_e, all?: boolean) => {
    const path = await claudePath
    if (!path) return { entries: [], error: 'claude not found' }
    return listAgents(createRunClaude(execFile, path, await loginEnv), { all: all === true })
  })
  ipcMain.handle('claude:run', async (_e, args: string[], cwd: string) => {
    const path = await claudePath
    if (!path) return { code: 127, stderr: 'claude not found', stdout: '' }
    // Run only a background start of a test session. Never stop or remove a session.
    if (!canRunClaude(args)) {
      return { code: 126, stderr: 'refused: not an allowed start of a test session', stdout: '' }
    }
    // A relative cwd starts at the working directory of the app, as in pty:open.
    const run = createRunClaude(execFile, path, await loginEnv)
    return run(args, { cwd: resolve(process.cwd(), cwd) })
  })
  // Send a signal only to a test session. Any other signal or PID gives false.
  ipcMain.handle('proc:signal', async (_e, pid: number, signal: string) => {
    if (!ALLOWED_SIGNALS.includes(signal)) return false
    const path = await claudePath
    if (!path) return false
    const list = await listAgents(createRunClaude(execFile, path, await loginEnv))
    if (!canSignal(list.entries, pid)) return false
    try {
      process.kill(pid, signal as NodeJS.Signals)
      return true
    } catch {
      return false
    }
  })
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
      // Open a PTY only for a test session. Read the session list for an attach.
      const path = await claudePath
      const entries =
        args[0] === 'attach' && path
          ? (await listAgents(createRunClaude(execFile, path, await loginEnv))).entries
          : []
      if (!canOpenPty(entries, args)) {
        throw new Error('refused: not an allowed attach or start of a test session')
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

// Make a window the target of pty:data and pty:exit.
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
