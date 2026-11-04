import { resolve } from 'path'
import { BrowserWindow, ipcMain } from 'electron'
import { createRunClaude, execFile, resolveClaudePath } from './claude/cli'
import { listAgents } from './claude/agents'
import { PtyManager } from './pty/pty-manager'
import { nodePtySpawn } from './pty/node-pty-spawn'

const CHANNELS = [
  'claude:path',
  'agents:list',
  'pty:open',
  'pty:write',
  'pty:resize',
  'pty:close'
] as const

// Register the IPC handlers for one window.
// The main process finds the claude path one time. The renderer cannot set it.
export async function registerIpc(win: BrowserWindow): Promise<void> {
  const claudePath = await resolveClaudePath(execFile)
  const manager = claudePath ? new PtyManager(nodePtySpawn, claudePath) : null
  const run = claudePath ? createRunClaude(execFile, claudePath) : null

  const send = (channel: string, ...args: unknown[]): void => {
    if (!win.isDestroyed()) win.webContents.send(channel, ...args)
  }
  manager?.onData((viewId, chunk) => send('pty:data', viewId, chunk))
  manager?.onExit((viewId, exitCode, signal) => send('pty:exit', viewId, exitCode, signal))

  ipcMain.handle('claude:path', () => claudePath)
  ipcMain.handle('agents:list', async (_e, all?: boolean) => {
    if (!run) return { entries: [], error: 'claude not found' }
    return listAgents(run, { all: all === true })
  })
  ipcMain.handle(
    'pty:open',
    (_e, viewId: string, args: string[], opts: { cwd: string; cols: number; rows: number }) => {
      if (!manager) throw new Error('claude not found')
      return manager.open(viewId, args, { ...opts, cwd: resolve(process.cwd(), opts.cwd) })
    }
  )
  ipcMain.handle('pty:write', (_e, viewId: string, data: string) => {
    return manager ? manager.write(viewId, data) : false
  })
  ipcMain.handle('pty:resize', (_e, viewId: string, cols: number, rows: number) => {
    manager?.resize(viewId, cols, rows)
  })
  ipcMain.handle('pty:close', (_e, viewId: string, signal?: string) => {
    manager?.close(viewId, signal)
  })

  // When the window closes, close all PTYs and remove the handlers.
  win.on('closed', () => {
    manager?.closeAll()
    for (const channel of CHANNELS) ipcMain.removeHandler(channel)
  })
}
