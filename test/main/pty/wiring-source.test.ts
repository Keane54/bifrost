import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'

const read = (path: string): string => readFileSync(path, 'utf8')
const ipc = read('src/main/ipc.ts')

// The text from the handler of a channel to the next handler.
function block(channel: string): string {
  const start = ipc.search(new RegExp(`ipcMain\\.handle\\(\\s*'${channel}'`))
  expect(start, channel).toBeGreaterThanOrEqual(0)
  const next = ipc.indexOf('ipcMain.handle(', start + 10)
  return ipc.slice(start, next === -1 ? undefined : next)
}

describe('PTY IPC wiring', () => {
  test.each([
    'pty:open',
    'pty:write',
    'pty:resize',
    'pty:close',
    'claude:version',
    'registry:rows',
  ])('%s goes through fromPage', channel => {
    expect(block(channel)).toContain('fromPage(')
  })

  test('pty:open takes no path from the page', () => {
    const open = block('pty:open')
    expect(open).not.toContain('opts.cwd')
    expect(open).toContain('again.cwd')
    expect(open).toContain('isTerminalSize')
  })

  test('the exit and the close flush the batch first', () => {
    const onExit = ipc.slice(ipc.indexOf('m.onExit('))
    const exitBlock = onExit.slice(0, onExit.indexOf('liveManager = m'))
    expect(exitBlock).toContain('batcher.flush(viewId)')
    expect(exitBlock.indexOf('batcher.flush(viewId)')).toBeLessThan(
      exitBlock.indexOf("send('pty:exit'"),
    )
    const onClose = ipc.slice(ipc.indexOf('m.onClose('), ipc.indexOf('m.onExit('))
    expect(onClose).toContain('batcher.flush(viewId)')
  })

  test('pty:resize checks the sizes', () => {
    expect(block('pty:resize')).toContain('isTerminalSize')
  })

  test('the claude:path channel is gone', () => {
    for (const file of ['src/main/ipc.ts', 'src/preload/index.ts', 'src/shared/api.ts']) {
      expect(read(file), file).not.toContain('claude:path')
    }
    expect(read('src/preload/index.ts')).not.toContain('claudePath')
    expect(read('src/shared/api.ts')).not.toContain('claudePath')
  })

  test('the pty.open options of the api have no cwd', () => {
    const api = read('src/shared/api.ts')
    const match = /open\(viewId: string, args: string\[\], opts: \{([^}]*)\}/.exec(api)
    expect(match).not.toBeNull()
    expect(match?.[1]).not.toContain('cwd')
  })
})
