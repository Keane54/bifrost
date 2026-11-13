import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { dailyStateFile, openDailyStateStore } from '../../../src/main/daily-update/state-store'
import { EMPTY_DAILY_STATE } from '../../../src/shared/daily-state'

let home: string
beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-daily-state-'))
})
afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

describe('openDailyStateStore', () => {
  it('gives the path in the daily-update folder', () => {
    expect(dailyStateFile('/h')).toBe('/h/daily-update/state.json')
  })

  it('a missing file loads empty', async () => {
    const store = await openDailyStateStore(dailyStateFile(home))
    expect(store.get()).toEqual(EMPTY_DAILY_STATE)
  })

  it('a change survives a reload', async () => {
    const file = dailyStateFile(home)
    const store = await openDailyStateStore(file)
    await store.change(s => ({ ...s, lastSent: { a: 7 } }))
    const again = await openDailyStateStore(file)
    expect(again.get().lastSent).toEqual({ a: 7 })
  })

  it('runs two changes in order', async () => {
    const store = await openDailyStateStore(dailyStateFile(home))
    const one = store.change(s => ({ ...s, lastSent: { ...s.lastSent, a: 1 } }))
    const two = store.change(s => ({ ...s, lastSent: { ...s.lastSent, b: 2 } }))
    await Promise.all([one, two])
    expect(store.get().lastSent).toEqual({ a: 1, b: 2 })
  })

  it('a file that cannot be read is not written over', async () => {
    const file = dailyStateFile(home)
    await mkdir(file, { recursive: true })
    const logs: string[] = []
    const store = await openDailyStateStore(file, m => logs.push(m))
    expect(logs).toHaveLength(1)
    await store.change(s => ({ ...s, lastSent: { a: 1 } }))
    expect(store.get().lastSent).toEqual({ a: 1 })
    await expect(readFile(file, 'utf8')).rejects.toThrow()
  })
})
