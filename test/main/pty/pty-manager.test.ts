import { beforeEach, describe, expect, test, vi } from 'vitest'
import { PtyManager, type PtyProcess, type SpawnFn } from '../../../src/main/pty/pty-manager'

class FakePty implements PtyProcess {
  pid = 4242
  written: string[] = []
  write = vi.fn((data: string) => {
    this.written.push(data)
  })
  resize = vi.fn()
  kill = vi.fn()
  private dataCb: (chunk: string) => void = () => {}
  private exitCb: (e: { exitCode: number; signal?: number }) => void = () => {}
  onData(cb: (chunk: string) => void): void {
    this.dataCb = cb
  }
  onExit(cb: (e: { exitCode: number; signal?: number }) => void): void {
    this.exitCb = cb
  }
  emitData(chunk: string): void {
    this.dataCb(chunk)
  }
  emitExit(e: { exitCode: number; signal?: number }): void {
    this.exitCb(e)
  }
}

let fakes: FakePty[]
let spawn: ReturnType<typeof vi.fn<SpawnFn>>
const size = { cwd: '/tmp', cols: 100, rows: 30 }

beforeEach(() => {
  fakes = []
  spawn = vi.fn<SpawnFn>(() => {
    const f = new FakePty()
    fakes.push(f)
    return f
  })
})

describe('PtyManager', () => {
  test('open spawns the file with the args, the size and TERM', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const pid = m.open('v1', ['attach', 'abc'], size)
    expect(pid).toBe(4242)
    expect(spawn).toHaveBeenCalledWith(
      '/bin/claude',
      ['attach', 'abc'],
      expect.objectContaining({
        cwd: '/tmp',
        cols: 100,
        rows: 30,
        env: expect.objectContaining({ TERM: 'xterm-256color', COLORTERM: 'truecolor' })
      })
    )
  })

  test('open gives the PTY the clean child env', () => {
    vi.stubEnv('CLAUDECODE', '1')
    vi.stubEnv('CLAUDE_CODE_ENTRYPOINT', 'cli')
    vi.stubEnv('TERM_PROGRAM', 'WarpTerminal')
    vi.stubEnv('WARP_IS_LOCAL_SHELL_SESSION', '1')
    vi.stubEnv('HOME', '/Users/test')
    try {
      new PtyManager(spawn, '/bin/claude').open('v1', [], size)
      const env = spawn.mock.calls[0][2].env
      expect(env).not.toHaveProperty('CLAUDECODE')
      expect(env).not.toHaveProperty('CLAUDE_CODE_ENTRYPOINT')
      expect(env).not.toHaveProperty('TERM_PROGRAM')
      expect(env).not.toHaveProperty('WARP_IS_LOCAL_SHELL_SESSION')
      expect(env.HOME).toBe('/Users/test')
    } finally {
      vi.unstubAllEnvs()
    }
  })

  test('data from the PTY goes to onData with the view ID', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const cb = vi.fn()
    m.onData(cb)
    m.open('v1', [], size)
    fakes[0].emitData('hi')
    expect(cb).toHaveBeenCalledWith('v1', 'hi')
  })

  test('exit goes to onExit and removes the view', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const cb = vi.fn()
    m.onExit(cb)
    m.open('v1', [], size)
    fakes[0].emitExit({ exitCode: 1 })
    expect(cb).toHaveBeenCalledWith('v1', 1, undefined)
    expect(m.write('v1', 'x')).toBe(false)
  })

  test('open on an existing view ID closes the old PTY first', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    m.open('v1', [], size)
    expect(fakes[0].kill).toHaveBeenCalledWith('SIGHUP')
    expect(fakes).toHaveLength(2)
    expect(m.write('v1', 'x')).toBe(true)
    expect(fakes[1].write).toHaveBeenCalledWith('x')
    expect(fakes[0].write).not.toHaveBeenCalled()
  })

  test('data from the old PTY of a view does not go to onData', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const cb = vi.fn()
    m.onData(cb)
    m.open('v1', [], size)
    m.open('v1', [], size)
    fakes[0].emitData('old')
    expect(cb).not.toHaveBeenCalled()
    fakes[1].emitData('new')
    expect(cb).toHaveBeenCalledWith('v1', 'new')
  })

  test('exit of the old PTY of a view does not remove the new PTY', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const cb = vi.fn()
    m.onExit(cb)
    m.open('v1', [], size)
    m.open('v1', [], size)
    fakes[0].emitExit({ exitCode: 0 })
    expect(cb).not.toHaveBeenCalled()
    expect(m.write('v1', 'x')).toBe(true)
    expect(fakes[1].write).toHaveBeenCalledWith('x')
  })

  test('data and exit after close do not go to the callbacks', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    const dataCb = vi.fn()
    const exitCb = vi.fn()
    m.onData(dataCb)
    m.onExit(exitCb)
    m.open('v1', [], size)
    m.close('v1')
    fakes[0].emitData('late')
    fakes[0].emitExit({ exitCode: 0 })
    expect(dataCb).not.toHaveBeenCalled()
    expect(exitCb).not.toHaveBeenCalled()
  })

  test('closeAll kills each PTY and removes all views', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    m.open('v2', [], size)
    m.open('v3', [], size)
    m.closeAll()
    for (const f of fakes) expect(f.kill).toHaveBeenCalledWith('SIGHUP')
    expect(m.write('v1', 'x')).toBe(false)
    expect(m.write('v2', 'x')).toBe(false)
    expect(m.write('v3', 'x')).toBe(false)
  })

  test('closeAll kills the other PTYs when one kill throws', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    m.open('v2', [], size)
    fakes[0].kill.mockImplementation(() => {
      throw new Error('kill failed')
    })
    expect(() => m.closeAll()).not.toThrow()
    expect(fakes[1].kill).toHaveBeenCalledWith('SIGHUP')
    expect(m.write('v1', 'x')).toBe(false)
    expect(m.write('v2', 'x')).toBe(false)
  })

  test('close with a signal that is not SIGHUP or SIGTERM kills with SIGHUP', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    for (const [i, signal] of ['SIGFOO', 'SIGKILL', '', 9 as unknown as string].entries()) {
      m.open(`v${i}`, [], size)
      m.close(`v${i}`, signal)
      expect(fakes[i].kill).toHaveBeenCalledWith('SIGHUP')
      expect(m.write(`v${i}`, 'x')).toBe(false)
    }
  })

  test('resize ignores a size below 1', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    m.resize('v1', 0, 24)
    expect(fakes[0].resize).not.toHaveBeenCalled()
    m.resize('v1', 80, 24)
    expect(fakes[0].resize).toHaveBeenCalledWith(80, 24)
  })

  test('close kills with SIGHUP by default and with the given signal', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    m.close('v1')
    expect(fakes[0].kill).toHaveBeenCalledWith('SIGHUP')
    expect(m.write('v1', 'x')).toBe(false)
    m.open('v2', [], size)
    m.close('v2', 'SIGTERM')
    expect(fakes[1].kill).toHaveBeenCalledWith('SIGTERM')
  })

  test('write to an unknown view returns false', () => {
    expect(new PtyManager(spawn, '/bin/claude').write('nope', 'x')).toBe(false)
  })

  test('write to an open view sends the data and returns true', () => {
    const m = new PtyManager(spawn, '/bin/claude')
    m.open('v1', [], size)
    expect(m.write('v1', 'x')).toBe(true)
    expect(fakes[0].write).toHaveBeenCalledWith('x')
  })
})
