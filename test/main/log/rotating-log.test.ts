import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import {
  createRotatingLog,
  ROTATING_LOG_MAX_BYTES,
  type RotatingLogDeps,
} from '../../../src/main/log/rotating-log'

const DIR = '/logs'
const NOW = Date.UTC(2026, 10, 10, 12, 0, 0)

function fakeDeps(size: number | 'missing' = 'missing'): RotatingLogDeps {
  return {
    appendFile: vi.fn(async () => {}),
    mkdir: vi.fn(async () => {}),
    now: () => NOW,
    rename: vi.fn(async () => {}),
    stat: vi.fn(async () => {
      if (size === 'missing') throw new Error('ENOENT')
      return { size }
    }),
  }
}

describe('rotating log', () => {
  it('puts the file with the given name in the folder', () => {
    expect(createRotatingLog(DIR, 'health.log', fakeDeps()).path).toBe(join(DIR, 'health.log'))
  })

  it('writes a line with the ISO time in front', async () => {
    const deps = fakeDeps()
    await createRotatingLog(DIR, 'health.log', deps).line('crash gpu: killed')
    expect(deps.appendFile).toHaveBeenCalledWith(
      join(DIR, 'health.log'),
      '2026-11-10T12:00:00.000Z crash gpu: killed\n',
    )
  })

  it('rolls a full file over to <name>.old.log', async () => {
    const deps = fakeDeps(ROTATING_LOG_MAX_BYTES)
    await createRotatingLog(DIR, 'health.log', deps).line('x')
    expect(deps.rename).toHaveBeenCalledWith(join(DIR, 'health.log'), join(DIR, 'health.old.log'))
  })

  it('resolves on a write error and logs it once', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const deps = fakeDeps()
    deps.appendFile = vi.fn(async () => {
      throw new Error('disk full')
    })
    const log = createRotatingLog(DIR, 'health.log', deps)
    await expect(log.line('a')).resolves.toBeUndefined()
    await expect(log.line('b')).resolves.toBeUndefined()
    expect(spy).toHaveBeenCalledTimes(1)
    expect(String(spy.mock.calls[0][0])).toContain('health.log')
    spy.mockRestore()
  })
})
