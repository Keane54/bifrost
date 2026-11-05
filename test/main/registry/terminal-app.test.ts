import { expect, test, vi } from 'vitest'
import type { ExecFn } from '../../../src/main/claude/cli'
import {
  type ProcessTable,
  parseProcessTable,
  readProcessTable,
  terminalAppOf,
} from '../../../src/main/registry/terminal-app'

const warp = [
  '63362   931 claude',
  '  931   866 -zsh',
  '  866     1 /Applications/Warp.app/Contents/MacOS/stable',
].join('\n')

test('parseProcessTable reads the PID, the parent PID and a command with spaces', () => {
  const table = parseProcessTable(
    '  10   1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron\nbad line\n11 10 zsh\n',
  )
  expect(table.size).toBe(2)
  expect(table.get(10)).toEqual({
    comm: '/Applications/Visual Studio Code.app/Contents/MacOS/Electron',
    ppid: 1,
  })
  expect(table.get(11)).toEqual({ comm: 'zsh', ppid: 10 })
})

test('terminalAppOf finds Warp from the M0 chain', () => {
  expect(terminalAppOf(parseProcessTable(warp), 63362)).toEqual({
    bundle: '/Applications/Warp.app',
    name: 'Warp',
  })
})

test('terminalAppOf takes the outermost app of a helper path', () => {
  const table = parseProcessTable(
    '5 1 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper',
  )
  expect(terminalAppOf(table, 5)).toEqual({
    bundle: '/Applications/Visual Studio Code.app',
    name: 'Visual Studio Code',
  })
})

test('terminalAppOf gives null without an app, for an unknown PID and for a loop', () => {
  const none = parseProcessTable('5 4 claude\n4 1 -zsh')
  expect(terminalAppOf(none, 5)).toBeNull()
  expect(terminalAppOf(none, 99)).toBeNull()
  const loop: ProcessTable = new Map([
    [2, { comm: 'a', ppid: 3 }],
    [3, { comm: 'b', ppid: 2 }],
  ])
  expect(terminalAppOf(loop, 2)).toBeNull()
})

test('readProcessTable runs /bin/ps -axo pid=,ppid=,comm=', async () => {
  const exec = vi.fn<ExecFn>(async () => ({ code: 0, stderr: '', stdout: warp }))
  const table = await readProcessTable(exec)
  expect(exec.mock.calls[0].slice(0, 2)).toEqual(['/bin/ps', ['-axo', 'pid=,ppid=,comm=']])
  expect(exec.mock.calls[0][2]).toEqual({ timeoutMs: 5000 })
  expect(table?.size).toBe(3)
  const failed = vi.fn<ExecFn>(async () => ({ code: 1, stderr: '', stdout: '' }))
  expect(await readProcessTable(failed)).toBeNull()
})
