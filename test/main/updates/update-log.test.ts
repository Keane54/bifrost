import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import {
  createUpdateLog,
  LOG_MAX_BYTES,
  LOG_NAME,
  type UpdateLogDeps,
} from '../../../src/main/updates/update-log'

const DIR = '/logs'
const NOW = Date.UTC(2026, 10, 10, 12, 0, 0)

function fakeDeps(size: number | 'missing' = 'missing'): UpdateLogDeps {
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

describe('update log', () => {
  it('names the file in the folder', () => {
    expect(LOG_NAME).toBe('updater.log')
    expect(createUpdateLog(DIR, fakeDeps()).path).toBe(join(DIR, LOG_NAME))
  })

  it('writes a line with the ISO time in front', async () => {
    const deps = fakeDeps()
    await createUpdateLog(DIR, deps).line('check started')
    expect(deps.mkdir).toHaveBeenCalledWith(DIR, { recursive: true })
    expect(deps.appendFile).toHaveBeenCalledWith(
      join(DIR, LOG_NAME),
      '2026-11-10T12:00:00.000Z check started\n',
    )
    expect(deps.rename).not.toHaveBeenCalled()
  })

  it('rolls a full file over to updater.old.log before the next line', async () => {
    const deps = fakeDeps(LOG_MAX_BYTES)
    await createUpdateLog(DIR, deps).line('x')
    expect(deps.rename).toHaveBeenCalledWith(join(DIR, LOG_NAME), join(DIR, 'updater.old.log'))
    const order = [
      vi.mocked(deps.rename).mock.invocationCallOrder[0],
      vi.mocked(deps.appendFile).mock.invocationCallOrder[0],
    ]
    expect(order[0]).toBeLessThan(order[1])
  })

  it('does not roll a file below the limit', async () => {
    const deps = fakeDeps(LOG_MAX_BYTES - 1)
    await createUpdateLog(DIR, deps).line('x')
    expect(deps.rename).not.toHaveBeenCalled()
  })

  it('keeps the order of two quick calls', async () => {
    const written: string[] = []
    const deps = fakeDeps()
    deps.appendFile = vi.fn(async (_p: string, text: string) => {
      if (text.endsWith('first\n')) await new Promise(r => setTimeout(r, 10))
      written.push(text)
    })
    const log = createUpdateLog(DIR, deps)
    await Promise.all([log.line('first'), log.line('second')])
    expect(written.map(t => t.split(' ')[1])).toEqual(['first\n', 'second\n'])
  })

  it('resolves on a write error and logs it once', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const deps = fakeDeps()
    deps.appendFile = vi.fn(async () => {
      throw new Error('disk full')
    })
    const log = createUpdateLog(DIR, deps)
    await expect(log.line('a')).resolves.toBeUndefined()
    await expect(log.line('b')).resolves.toBeUndefined()
    expect(spy).toHaveBeenCalledTimes(1)
    spy.mockRestore()
  })
})
