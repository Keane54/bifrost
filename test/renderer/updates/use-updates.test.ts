// The app-wide Updates store.
import { describe, expect, it, vi } from 'vitest'
import { createUpdatesStore, updateButtonOf } from '../../../src/renderer/src/updates/use-updates'
import { EMPTY_UPDATES, type UpdatesSnapshot } from '../../../src/shared/updates'

const READY: UpdatesSnapshot = {
  available: true,
  lastCheckAt: 5,
  state: { kind: 'ready', version: '1.2.0' },
  version: '1.1.0',
}
const CHECKING: UpdatesSnapshot = { ...READY, state: { kind: 'checking' } }

function fakeApi() {
  let push: ((s: UpdatesSnapshot) => void) | null = null
  let answer: ((s: UpdatesSnapshot) => void) | null = null
  let fail: ((e: Error) => void) | null = null
  const off = vi.fn()
  const api = {
    check: vi.fn(),
    onUpdate: vi.fn((cb: (s: UpdatesSnapshot) => void) => {
      push = cb
      return off
    }),
    restart: vi.fn(),
    showLog: vi.fn(),
    snapshot: vi.fn(
      () =>
        new Promise<UpdatesSnapshot>((resolve, reject) => {
          answer = resolve
          fail = reject
        }),
    ),
  }
  return {
    answer: (s: UpdatesSnapshot) => answer?.(s),
    api,
    fail: (e: Error) => fail?.(e),
    off,
    push: (s: UpdatesSnapshot) => push?.(s),
  }
}

const tick = (): Promise<void> => new Promise(resolve => setTimeout(resolve, 0))

describe('createUpdatesStore', () => {
  it('starts with the empty snapshot and does not subscribe before a listener', () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    expect(store.get()).toBe(EMPTY_UPDATES)
    expect(fake.api.onUpdate).not.toHaveBeenCalled()
  })

  it('subscribes once for many listeners and loads one snapshot', async () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    const a = vi.fn()
    const b = vi.fn()
    store.subscribe(a)
    store.subscribe(b)
    expect(fake.api.onUpdate).toHaveBeenCalledTimes(1)
    expect(fake.api.snapshot).toHaveBeenCalledTimes(1)
    fake.answer(READY)
    await tick()
    expect(store.get()).toBe(READY)
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
  })

  it('lets a push that comes before the first answer win', async () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    store.subscribe(() => {})
    fake.push(CHECKING)
    fake.answer(READY)
    await tick()
    expect(store.get()).toBe(CHECKING)
  })

  it('keeps the empty snapshot when the first load fails', async () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    store.subscribe(() => {})
    fake.fail(new Error('no'))
    await tick()
    expect(store.get()).toBe(EMPTY_UPDATES)
  })

  it('stops the subscription after the last listener leaves', () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    const stopA = store.subscribe(() => {})
    const stopB = store.subscribe(() => {})
    stopA()
    expect(fake.off).not.toHaveBeenCalled()
    stopB()
    expect(fake.off).toHaveBeenCalledTimes(1)
  })
})

describe('loaded flag', () => {
  it('turns true after the first answer', async () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    store.subscribe(() => {})
    expect(store.loaded()).toBe(false)
    fake.answer(READY)
    await tick()
    expect(store.loaded()).toBe(true)
  })

  it('turns true after the first push', () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    store.subscribe(() => {})
    fake.push(CHECKING)
    expect(store.loaded()).toBe(true)
  })

  it('stays false when the first load fails', async () => {
    const fake = fakeApi()
    const store = createUpdatesStore(fake.api)
    store.subscribe(() => {})
    fake.fail(new Error('no'))
    await tick()
    expect(store.loaded()).toBe(false)
  })
})

describe('updateButtonOf', () => {
  it('gives the ready version', () => {
    expect(updateButtonOf(READY)).toEqual({ kind: 'ready', version: '1.2.0' })
  })

  it('gives failed for a failed state', () => {
    const failed: UpdatesSnapshot = {
      ...READY,
      state: { at: 1, cause: 'install', kind: 'failed', message: 'Text.' },
    }
    expect(updateButtonOf(failed)).toEqual({ kind: 'failed' })
  })

  it('gives null for the other states and for a build without updates', () => {
    expect(updateButtonOf(EMPTY_UPDATES)).toBeNull()
    expect(updateButtonOf({ ...READY, state: { kind: 'idle' } })).toBeNull()
    expect(updateButtonOf(CHECKING)).toBeNull()
    expect(
      updateButtonOf({ ...READY, state: { kind: 'downloading', percent: 3, version: '1.2.0' } }),
    ).toBeNull()
    expect(updateButtonOf({ ...READY, state: { kind: 'off' } })).toBeNull()
    expect(updateButtonOf({ ...READY, available: false })).toBeNull()
  })
})
