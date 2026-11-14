// The storage of the modules (Modules design 8.2): one JSON object for each module, in
// <bifrostHome>/modules-data/<id>.json. The folder has the mode 0700 and each file 0600.
//
// The store reads a file one time and then keeps the object in memory. It keeps the JSON text and
// the byte count of each key, so a set never handles the whole object. It writes compact JSON, at
// most one time a second for each module. Many sets in that second give one write.

import { chmodSync, mkdirSync } from 'node:fs'
import { chmod, mkdir, readFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { isPlainObject } from '../../shared/plain-object'
import { writeTextAtomic, writeTextAtomicSync } from '../store/json-file'
import { moduleDataFile } from './module-state'

// The most UTF-8 bytes of the compact JSON of the storage of one module.
export const MODULE_STORAGE_BYTES = 1024 * 1024
// The shortest time between two writes of the file of one module.
export const WRITE_GAP_MS = 1000

// The file operations of the store. Tests give their own.
export interface DataStoreIo {
  // The text of the file, or null when the file does not exist.
  read(file: string): Promise<string | null>
  write(file: string, text: string): Promise<void>
  writeSync(file: string, text: string): void
}

export const fileIo: DataStoreIo = {
  read: async file => {
    try {
      return await readFile(file, 'utf8')
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
      throw error
    }
  },
  write: async (file, text) => {
    const folder = dirname(file)
    await mkdir(folder, { mode: 0o700, recursive: true })
    await chmod(folder, 0o700)
    await writeTextAtomic(file, text)
  },
  writeSync: (file, text) => {
    const folder = dirname(file)
    mkdirSync(folder, { mode: 0o700, recursive: true })
    chmodSync(folder, 0o700)
    writeTextAtomicSync(file, text)
  },
}

export interface ModuleDataStore {
  // The value of the key, or null.
  get(moduleId: string, key: string): Promise<unknown>
  // Set the JSON text of the key, or remove the key with null. This gives false, and changes
  // nothing, when the object would become larger than MODULE_STORAGE_BYTES.
  set(moduleId: string, key: string, text: string | null): Promise<boolean>
  // The UTF-8 bytes of the compact JSON of the object of the module.
  size(moduleId: string): Promise<number>
  // Write the changes of one module, or of all modules, now.
  flush(moduleId?: string): Promise<void>
  // Write all changes now, with no wait. For the quit of the app.
  flushSync(): void
  // Forget the module and its waiting write, and wait for a write that runs. Call it before the
  // data file of a removed module goes.
  drop(moduleId: string): Promise<void>
}

export interface ModuleDataOptions {
  io?: DataStoreIo
  log?: (message: string) => void
}

interface Item {
  text: string
  bytes: number
}

interface ModuleData {
  items: Map<string, Item>
  // The sum of the bytes of the items.
  sum: number
  dirty: boolean
}

// The bytes of one key and its value in the compact JSON: "key":value
function itemBytes(key: string, text: string): number {
  return Buffer.byteLength(JSON.stringify(key)) + 1 + Buffer.byteLength(text)
}

// The bytes of the compact JSON of the object: the braces, the items and the commas.
function totalBytes(sum: number, count: number): number {
  return 2 + sum + Math.max(0, count - 1)
}

function textOf(data: ModuleData): string {
  const parts: string[] = []
  for (const [key, item] of data.items) parts.push(`${JSON.stringify(key)}:${item.text}`)
  return `{${parts.join(',')}}`
}

function parseData(text: string | null): ModuleData {
  const data: ModuleData = { dirty: false, items: new Map(), sum: 0 }
  if (text === null) return data
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return data
  }
  if (!isPlainObject(parsed)) return data
  for (const [key, value] of Object.entries(parsed)) {
    const json = JSON.stringify(value)
    if (json === undefined) continue
    const bytes = itemBytes(key, json)
    data.items.set(key, { bytes, text: json })
    data.sum += bytes
  }
  return data
}

export function createModuleDataStore(
  bifrostHome: string,
  options: ModuleDataOptions = {},
): ModuleDataStore {
  const io = options.io ?? fileIo
  // A monotonic clock for the write gap. A change of the wall clock does not move it.
  const clock = (): number => performance.now()
  const log = options.log ?? ((message: string) => console.error(message))
  const loads = new Map<string, Promise<ModuleData>>()
  const loaded = new Map<string, ModuleData>()
  const timers = new Map<string, NodeJS.Timeout>()
  const writing = new Map<string, Promise<void>>()
  const lastWrite = new Map<string, number>()

  const fileOf = (moduleId: string): string => moduleDataFile(bifrostHome, moduleId)

  // Read the file one time. Calls that come during the read wait for the same read, so their
  // changes apply in the order of the calls. A failed read is not kept, so the next call reads
  // again.
  function load(moduleId: string): Promise<ModuleData> {
    let pending = loads.get(moduleId)
    if (pending === undefined) {
      pending = io.read(fileOf(moduleId)).then(text => {
        const data = parseData(text)
        // A drop during the read wins: the result is not kept.
        if (loads.get(moduleId) === pending) loaded.set(moduleId, data)
        return data
      })
      loads.set(moduleId, pending)
      pending.catch(() => {
        if (loads.get(moduleId) === pending) loads.delete(moduleId)
      })
    }
    return pending
  }

  function cancelTimer(moduleId: string): void {
    const timer = timers.get(moduleId)
    if (timer !== undefined) clearTimeout(timer)
    timers.delete(moduleId)
  }

  // Write the object when it changed. The write runs in the background. Only one write of a
  // module runs at a time: while one runs, this starts nothing, and the end of that write plans
  // the next one.
  function writeNow(moduleId: string): Promise<void> {
    const running = writing.get(moduleId)
    if (running !== undefined) return running
    const data = loaded.get(moduleId)
    if (data === undefined || !data.dirty) return Promise.resolve()
    data.dirty = false
    lastWrite.set(moduleId, clock())
    let failed = false
    const run = io
      .write(fileOf(moduleId), textOf(data))
      .catch(error => {
        failed = true
        data.dirty = true
        log(`Bifrost cannot save the storage of the module ${moduleId}. ${error}`)
      })
      .finally(() => {
        if (writing.get(moduleId) === run) writing.delete(moduleId)
        // A set during the write waits for the next place. A failed write waits for the next
        // set or flush, so a broken disk gives no loop of writes.
        if (!failed && data.dirty && loaded.get(moduleId) === data) schedule(moduleId)
      })
    writing.set(moduleId, run)
    return run
  }

  // Plan one write, at least WRITE_GAP_MS after the start of the last write.
  function schedule(moduleId: string): void {
    if (timers.has(moduleId) || writing.has(moduleId)) return
    const last = lastWrite.get(moduleId)
    const wait = last === undefined ? 0 : Math.max(0, last + WRITE_GAP_MS - clock())
    const timer = setTimeout(() => {
      timers.delete(moduleId)
      void writeNow(moduleId)
    }, wait)
    timer.unref?.()
    timers.set(moduleId, timer)
  }

  // Wait for the write that runs. Then write one time if changes are left. The end of a write can
  // plan a new one, so cancel the plan again after each wait.
  async function flushOne(moduleId: string): Promise<void> {
    for (;;) {
      cancelTimer(moduleId)
      const running = writing.get(moduleId)
      if (running === undefined) break
      await running
    }
    await writeNow(moduleId)
  }

  return {
    async drop(moduleId) {
      cancelTimer(moduleId)
      loads.delete(moduleId)
      loaded.delete(moduleId)
      lastWrite.delete(moduleId)
      await writing.get(moduleId)
    },
    async flush(moduleId) {
      const ids = moduleId === undefined ? [...loaded.keys()] : [moduleId]
      await Promise.all(ids.map(flushOne))
    },
    flushSync() {
      for (const [moduleId, data] of loaded) {
        // A write that runs may not end before the app quits, so write its module again.
        if (!data.dirty && !writing.has(moduleId)) continue
        cancelTimer(moduleId)
        try {
          io.writeSync(fileOf(moduleId), textOf(data))
          data.dirty = false
        } catch (error) {
          log(`Bifrost cannot save the storage of the module ${moduleId}. ${error}`)
        }
      }
    },
    async get(moduleId, key) {
      const item = (await load(moduleId)).items.get(key)
      return item === undefined ? null : JSON.parse(item.text)
    },
    async set(moduleId, key, text) {
      const data = await load(moduleId)
      const old = data.items.get(key)
      if (text === null) {
        if (old === undefined) return true
        data.items.delete(key)
        data.sum -= old.bytes
      } else {
        const bytes = itemBytes(key, text)
        const sum = data.sum - (old?.bytes ?? 0) + bytes
        const count = data.items.size + (old === undefined ? 1 : 0)
        if (totalBytes(sum, count) > MODULE_STORAGE_BYTES) return false
        data.items.set(key, { bytes, text })
        data.sum = sum
      }
      data.dirty = true
      schedule(moduleId)
      return true
    },
    async size(moduleId) {
      const data = await load(moduleId)
      return totalBytes(data.sum, data.items.size)
    },
  }
}
