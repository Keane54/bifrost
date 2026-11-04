import { resolve } from 'path'
import { BrowserWindow, ipcMain } from 'electron'
import { createRunClaude, execFile, resolveClaudePath } from './claude/cli'
import { listAgents } from './claude/agents'
import { canOpenPty, canRunClaude, canSignal } from './claude/guard'
import { PtyManager } from './pty/pty-manager'
import { nodePtySpawn } from './pty/node-pty-spawn'

const ALLOWED_SIGNALS = ['SIGTERM', 'SIGHUP', 'SIGINT']

let registered = false
let currentWindow: BrowserWindow | null = null
let managerPromise: Promise<PtyManager | null> | null = null

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
  managerPromise = claudePath.then((path) => {
    if (!path) return null
    const manager = new PtyManager(nodePtySpawn, path)
    manager.onData((viewId, chunk) => send('pty:data', viewId, chunk))
    manager.onExit((viewId, exitCode, signal) => send('pty:exit', viewId, exitCode, signal))
    return manager
  })
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>

  ipcMain.handle('claude:path', () => claudePath)
  ipcMain.handle('agents:list', async (_e, all?: boolean) => {
    const path = await claudePath
    if (!path) return { entries: [], error: 'claude not found' }
    return listAgents(createRunClaude(execFile, path), { all: all === true })
  })
  ipcMain.handle('claude:run', async (_e, args: string[], cwd: string) => {
    const path = await claudePath
    if (!path) return { code: 127, stdout: '', stderr: 'claude not found' }
    // Run only a background start of a test session. Never stop or remove a session.
    if (!canRunClaude(args)) return { code: 126, stdout: '', stderr: 'not a test session' }
    // A relative cwd starts at the working directory of the app, as in pty:open.
    return createRunClaude(execFile, path)(args, { cwd: resolve(process.cwd(), cwd) })
  })
  // Send a signal only to a test session. Any other signal or PID gives false.
  ipcMain.handle('proc:signal', async (_e, pid: number, signal: string) => {
    if (!ALLOWED_SIGNALS.includes(signal)) return false
    const path = await claudePath
    if (!path) return false
    const list = await listAgents(createRunClaude(execFile, path))
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
      _e,
      viewId: string,
      args: string[],
      opts: { cwd: string; cols: number; rows: number }
    ) => {
      const manager = await getManager()
      if (!manager) throw new Error('claude not found')
      // Open a PTY only for a test session. Read the session list for an attach.
      const path = await claudePath
      const entries =
        args[0] === 'attach' && path
          ? (await listAgents(createRunClaude(execFile, path))).entries
          : []
      if (!canOpenPty(entries, args)) throw new Error('not a test session')
      return manager.open(viewId, args, { ...opts, cwd: resolve(process.cwd(), opts.cwd) })
    }
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
// When the window closes, close all PTYs and clear the window reference.
export function attachWindow(win: BrowserWindow): void {
  currentWindow = win
  win.on('closed', () => {
    if (currentWindow === win) currentWindow = null
    void managerPromise?.then((manager) => manager?.closeAll())
  })
}
