import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { writeJsonAtomic } from '../../../src/main/store/json-file'
import { NO_PERIODS } from '../../../src/main/usage-alerts/rules'
import {
  openUsageAlertStore,
  parseNotified,
  usageAlertsFile,
} from '../../../src/main/usage-alerts/state-store'

// Spy on writeJsonAtomic. The spy calls the real function.
vi.mock(import('../../../src/main/store/json-file'), async original => {
  const real = await original()
  return { ...real, writeJsonAtomic: vi.fn(real.writeJsonAtomic) }
})

const FIVE = Date.parse('2026-11-10T14:05:00Z')
const SEVEN = Date.parse('2026-11-13T13:00:00Z')

let dir: string
let file: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-usage-alerts-'))
  file = join(dir, 'usage-alerts.json')
  vi.mocked(writeJsonAtomic).mockClear()
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

describe('usageAlertsFile', () => {
  it('gives usage-alerts.json in the data folder', () => {
    expect(usageAlertsFile('/tmp/user-data')).toBe('/tmp/user-data/usage-alerts.json')
  })
})

describe('parseNotified', () => {
  it('keeps each finite number and gives null for each other value', () => {
    expect(parseNotified({ fiveHour: FIVE, sevenDay: SEVEN })).toEqual({
      fiveHour: FIVE,
      sevenDay: SEVEN,
    })
    expect(parseNotified({ fiveHour: '1', sevenDay: SEVEN, x: 1 })).toEqual({
      fiveHour: null,
      sevenDay: SEVEN,
    })
    expect(parseNotified({ fiveHour: null, sevenDay: Number.NaN })).toEqual(NO_PERIODS)
    for (const bad of [null, undefined, 7, 'x', [FIVE], {}]) {
      expect(parseNotified(bad)).toEqual(NO_PERIODS)
    }
  })
})

describe('openUsageAlertStore', () => {
  it('gives no notified period when there is no file', async () => {
    const store = await openUsageAlertStore(file)
    expect(store.get()).toEqual({ fiveHour: null, sevenDay: null })
  })

  it('writes the periods with writeJsonAtomic, and a new store reads them', async () => {
    const store = await openUsageAlertStore(file)
    const saved = { fiveHour: FIVE, sevenDay: null }
    await store.set(saved)
    expect(store.get()).toEqual(saved)
    expect(writeJsonAtomic).toHaveBeenCalledWith(file, saved)
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual(saved)
    expect((await stat(file)).mode & 0o777).toBe(0o600)
    expect(await readdir(dir)).toEqual(['usage-alerts.json'])
    const again = await openUsageAlertStore(file)
    expect(again.get()).toEqual(saved)
  })

  it('sets the value in memory at once, and the last set wins on disk', async () => {
    const store = await openUsageAlertStore(file)
    const first = store.set({ fiveHour: FIVE, sevenDay: null })
    expect(store.get()).toEqual({ fiveHour: FIVE, sevenDay: null })
    const second = store.set({ fiveHour: FIVE, sevenDay: SEVEN })
    await Promise.all([first, second])
    const again = await openUsageAlertStore(file)
    expect(again.get()).toEqual({ fiveHour: FIVE, sevenDay: SEVEN })
  })

  it('gives no notified period for a bad file and does not throw', async () => {
    await writeFile(file, '{ not json')
    const logs: string[] = []
    const store = await openUsageAlertStore(file, m => logs.push(m))
    expect(store.get()).toEqual(NO_PERIODS)
    expect(logs).toEqual([])
    // A later set writes a good file over the bad file.
    await store.set({ fiveHour: FIVE, sevenDay: null })
    expect(JSON.parse(await readFile(file, 'utf8')).fiveHour).toBe(FIVE)
  })

  it('does not save after a read error, and set does not reject', async () => {
    await mkdir(file)
    const logs: string[] = []
    const store = await openUsageAlertStore(file, m => logs.push(m))
    expect(store.get()).toEqual(NO_PERIODS)
    expect(logs).toHaveLength(1)
    await store.set({ fiveHour: FIVE, sevenDay: null })
    expect(store.get().fiveHour).toBe(FIVE)
    expect((await stat(file)).isDirectory()).toBe(true)
    expect(writeJsonAtomic).not.toHaveBeenCalled()
  })

  it('logs a failed write, keeps the value in memory, and does not reject', async () => {
    const blocked = join(dir, 'blocked')
    // A file in place of the folder makes the write fail.
    await writeFile(blocked, 'x')
    const logs: Array<[string, unknown]> = []
    const store = await openUsageAlertStore(join(blocked, 'usage-alerts.json'), (m, e) =>
      logs.push([m, e]),
    )
    await store.set({ fiveHour: null, sevenDay: SEVEN })
    expect(store.get().sevenDay).toBe(SEVEN)
    expect(logs).toHaveLength(1)
    expect(logs[0]?.[1]).toBeInstanceOf(Error)
  })
})
