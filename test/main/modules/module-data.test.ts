import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  createModuleDataStore,
  type DataStoreIo,
  fileIo,
  MODULE_STORAGE_BYTES,
  WRITE_GAP_MS,
} from '../../../src/main/modules/module-data'
import { moduleDataFile } from '../../../src/main/modules/module-state'

let home = ''

beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-module-data-'))
})

afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

// The file io of the real store, with a record of the time of each async write.
function countingIo(): { io: DataStoreIo; writes: number[] } {
  const writes: number[] = []
  return {
    io: {
      ...fileIo,
      write: async (file, text) => {
        writes.push(Date.now())
        await fileIo.write(file, text)
      },
    },
    writes,
  }
}

const json = (value: unknown): string => JSON.stringify(value)

describe('createModuleDataStore', () => {
  it('gives null for a missing key, a missing file and a file that is not an object', async () => {
    await expect(createModuleDataStore(home).get('demo', 'a')).resolves.toBe(null)
    const file = moduleDataFile(home, 'demo')
    await fileIo.write(file, '[1, 2]')
    await expect(createModuleDataStore(home).get('demo', '0')).resolves.toBe(null)
    await fileIo.write(file, 'not json')
    await expect(createModuleDataStore(home).get('demo', 'a')).resolves.toBe(null)
  })

  it('reads the saved file one time and keeps the object in memory', async () => {
    const file = moduleDataFile(home, 'demo')
    await fileIo.write(file, '{"a":1,"b":{"c":[2]}}')
    let reads = 0
    const store = createModuleDataStore(home, {
      io: {
        ...fileIo,
        read: f => {
          reads += 1
          return fileIo.read(f)
        },
      },
    })
    await expect(store.get('demo', 'a')).resolves.toBe(1)
    await expect(store.get('demo', 'b')).resolves.toEqual({ c: [2] })
    await expect(store.get('demo', 'gone')).resolves.toBe(null)
    expect(reads).toBe(1)
  })

  it('writes compact JSON with private modes', async () => {
    const store = createModuleDataStore(home)
    await store.set('demo', 'a', json(1))
    await store.set('demo', 'b', json('two'))
    await store.flush()
    const file = moduleDataFile(home, 'demo')
    expect(await readFile(file, 'utf8')).toBe('{"a":1,"b":"two"}')
    expect((await stat(file)).mode & 0o777).toBe(0o600)
    expect((await stat(join(home, 'modules-data'))).mode & 0o777).toBe(0o700)
  })

  it('removes a key that gets null', async () => {
    const store = createModuleDataStore(home)
    await store.set('demo', 'a', json(1))
    await store.set('demo', 'a', null)
    await store.flush()
    expect(await readFile(moduleDataFile(home, 'demo'), 'utf8')).toBe('{}')
  })

  it('counts the bytes of the compact JSON exactly', async () => {
    const store = createModuleDataStore(home)
    await store.set('demo', 'a', json('é 🙂 "quoted"'))
    await store.set('demo', '__proto__', json({ x: [1, null] }))
    await store.set('demo', 'b', json(2))
    await store.set('demo', 'a', json('shorter'))
    await store.set('demo', 'b', null)
    await store.flush()
    const text = await readFile(moduleDataFile(home, 'demo'), 'utf8')
    expect(await store.size('demo')).toBe(Buffer.byteLength(text))
    expect(Object.hasOwn(JSON.parse(text), '__proto__')).toBe(true)
  })

  it('accepts data of exactly 1 MB and refuses one byte more', async () => {
    const store = createModuleDataStore(home)
    expect(MODULE_STORAGE_BYTES).toBe(1024 * 1024)
    // {"a":"xxx..."} has 8 bytes around the x characters.
    const fill = 'x'.repeat(MODULE_STORAGE_BYTES - 8)
    await expect(store.set('demo', 'b', json(`${fill}x`))).resolves.toBe(false)
    await expect(store.set('demo', 'a', json(fill))).resolves.toBe(true)
    await expect(store.size('demo')).resolves.toBe(MODULE_STORAGE_BYTES)
    await expect(store.set('demo', 'b', json(0))).resolves.toBe(false)
    await expect(store.get('demo', 'b')).resolves.toBe(null)
    // A removal always works.
    await expect(store.set('demo', 'a', null)).resolves.toBe(true)
    await store.flush()
  })

  it('keeps each set cheap and writes at most once a second under a flood', async () => {
    const { io, writes } = countingIo()
    const store = createModuleDataStore(home, { io })
    expect(WRITE_GAP_MS).toBe(1000)
    const big = json('x'.repeat(250 * 1024))
    for (const key of ['a', 'b', 'c', 'd']) {
      await expect(store.set('demo', key, big)).resolves.toBe(true)
    }
    const started = performance.now()
    let sets = 0
    while (performance.now() - started < 2500) {
      await store.set('demo', 'n', json(sets))
      sets += 1
      // Let the write timer run.
      if (sets % 100 === 0) await new Promise(r => setTimeout(r, 0))
    }
    const elapsed = performance.now() - started
    const during = writes.length
    await store.flush()
    // A set that wrote or measured the whole 1 MB object would take milliseconds.
    expect(elapsed / sets).toBeLessThan(0.2)
    expect(during).toBeLessThanOrEqual(4)
    for (let i = 1; i < during; i++) {
      expect((writes[i] as number) - (writes[i - 1] as number)).toBeGreaterThanOrEqual(990)
    }
    const saved = JSON.parse(await readFile(moduleDataFile(home, 'demo'), 'utf8'))
    expect(saved.n).toBe(sets - 1)
  })

  it('keeps two sets that run at the same time, also before the first read ends', async () => {
    const store = createModuleDataStore(home)
    await Promise.all([
      store.set('demo', 'a', json(1)),
      store.set('demo', 'b', json(2)),
      store.set('demo', 'c', json(3)),
    ])
    await store.flush()
    expect(JSON.parse(await readFile(moduleDataFile(home, 'demo'), 'utf8'))).toEqual({
      a: 1,
      b: 2,
      c: 3,
    })
  })

  it('writes all changes at once with flushSync, for the quit', async () => {
    const { io, writes } = countingIo()
    const store = createModuleDataStore(home, { io })
    // Read both files first, so the two sets below run with no wait between them.
    await store.get('demo', 'a')
    await store.get('other', 'b')
    await store.set('demo', 'a', json(1))
    await store.set('other', 'b', json(2))
    store.flushSync()
    expect(await readFile(moduleDataFile(home, 'demo'), 'utf8')).toBe('{"a":1}')
    expect(await readFile(moduleDataFile(home, 'other'), 'utf8')).toBe('{"b":2}')
    // No change is left, so no async write follows.
    await new Promise(r => setTimeout(r, 50))
    expect(writes).toEqual([])
  })

  it('forgets a dropped module and writes nothing for it after the drop', async () => {
    const { io, writes } = countingIo()
    const store = createModuleDataStore(home, { io })
    await store.set('demo', 'a', json(1))
    await store.flush()
    await store.set('demo', 'b', json(2))
    await store.drop('demo')
    await rm(moduleDataFile(home, 'demo'))
    await new Promise(r => setTimeout(r, WRITE_GAP_MS + 100))
    await store.flush()
    expect(writes).toHaveLength(1)
    await expect(readFile(moduleDataFile(home, 'demo'), 'utf8')).rejects.toThrow('ENOENT')
    // A new install starts empty.
    await expect(store.get('demo', 'a')).resolves.toBe(null)
  })

  it('rejects when the file cannot be read, and reads again on the next call', async () => {
    let fail = true
    const store = createModuleDataStore(home, {
      io: {
        ...fileIo,
        read: async f => {
          if (fail) throw new Error('EACCES')
          return fileIo.read(f)
        },
      },
    })
    await expect(store.get('demo', 'a')).rejects.toThrow('EACCES')
    fail = false
    await expect(store.get('demo', 'a')).resolves.toBe(null)
  })

  it('runs the writes of one module one at a time, also with a flush in a slow write', async () => {
    const texts: string[] = []
    const ends: (() => void)[] = []
    let running = 0
    let most = 0
    const store = createModuleDataStore(home, {
      io: {
        ...fileIo,
        write: (_file, text) => {
          texts.push(text)
          running += 1
          most = Math.max(most, running)
          return new Promise<void>(resolve =>
            ends.push(() => {
              running -= 1
              resolve()
            }),
          )
        },
      },
    })
    const until = async (check: () => boolean) => {
      for (let i = 0; i < 200 && !check(); i++) await new Promise(r => setTimeout(r, 1))
      expect(check()).toBe(true)
    }
    await store.set('demo', 'a', json(1))
    await until(() => ends.length === 1)
    await store.set('demo', 'a', json(2))
    const first = store.flush('demo')
    const second = store.flush()
    await new Promise(r => setTimeout(r, 5))
    expect(running).toBe(1)
    ends[0]?.()
    await until(() => ends.length === 2)
    // A set during the slow second write. The planned write must wait for the end of it.
    await store.set('demo', 'a', json(3))
    await new Promise(r => setTimeout(r, WRITE_GAP_MS + 200))
    expect(running).toBe(1)
    const third = store.flush('demo')
    await new Promise(r => setTimeout(r, 5))
    expect(running).toBe(1)
    ends[1]?.()
    await until(() => ends.length === 3)
    ends[2]?.()
    await Promise.all([first, second, third])
    await new Promise(r => setTimeout(r, WRITE_GAP_MS + 100))
    expect(most).toBe(1)
    expect(texts).toEqual(['{"a":1}', '{"a":2}', '{"a":3}'])
  })

  it('keeps the write gap with a monotonic clock when the wall clock jumps back', async () => {
    const { io, writes } = countingIo()
    const store = createModuleDataStore(home, { io })
    await store.set('demo', 'a', json(1))
    await new Promise(r => setTimeout(r, 50))
    expect(writes).toHaveLength(1)
    // The wall clock goes back one hour. The next write must still come after about 1 s.
    const back = Date.now() - 3_600_000
    const spy = vi.spyOn(Date, 'now').mockReturnValue(back)
    try {
      await store.set('demo', 'a', json(2))
      await new Promise(r => setTimeout(r, WRITE_GAP_MS + 200))
    } finally {
      spy.mockRestore()
    }
    expect(writes).toHaveLength(2)
    await store.flush()
  })
})
