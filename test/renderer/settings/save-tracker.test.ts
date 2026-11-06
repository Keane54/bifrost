import { describe, expect, it } from 'vitest'
import { SaveTracker } from '../../../src/renderer/src/settings/save-tracker'

// A promise and the functions that settle it.
function deferred<T>(): {
  promise: Promise<T>
  resolve(value: T): void
  reject(err: unknown): void
} {
  let resolve: (value: T) => void = () => {}
  let reject: (err: unknown) => void = () => {}
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, reject, resolve }
}

// True when the promise has settled after the queued tasks ran.
async function settled(promise: Promise<unknown>): Promise<boolean> {
  let done = false
  void promise.then(
    () => {
      done = true
    },
    () => {
      done = true
    },
  )
  await new Promise(resolve => setTimeout(resolve, 0))
  return done
}

describe('SaveTracker', () => {
  it('settles at once with true when no save runs', async () => {
    expect(await new SaveTracker().settle()).toBe(true)
  })

  it('waits for a save that runs, and gives true when it worked', async () => {
    const tracker = new SaveTracker()
    const save = deferred<boolean>()
    tracker.track(save.promise)
    const result = tracker.settle()
    expect(await settled(result)).toBe(false)
    save.resolve(true)
    expect(await result).toBe(true)
  })

  it('gives false for a save that failed, and forgets the failure after the settle', async () => {
    const tracker = new SaveTracker()
    tracker.track(Promise.resolve(false))
    expect(await tracker.settle()).toBe(false)
    expect(await tracker.settle()).toBe(true)
  })

  it('gives false for a save that rejects', async () => {
    const tracker = new SaveTracker()
    tracker.track(Promise.reject(new Error('disk full')))
    expect(await tracker.settle()).toBe(false)
  })

  it('remembers a failure that ended before the settle', async () => {
    const tracker = new SaveTracker()
    tracker.track(Promise.resolve(false))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(await tracker.settle()).toBe(false)
  })

  it('also waits for a save that starts while it waits', async () => {
    const tracker = new SaveTracker()
    const first = deferred<boolean>()
    const second = deferred<boolean>()
    tracker.track(first.promise)
    const result = tracker.settle()
    tracker.track(second.promise)
    first.resolve(true)
    expect(await settled(result)).toBe(false)
    second.resolve(false)
    expect(await result).toBe(false)
  })

  it('saves each draft at the settle, and a draft with no text adds no save', async () => {
    const tracker = new SaveTracker()
    const calls: string[] = []
    tracker.addDraft(() => {
      calls.push('empty')
      return null
    })
    tracker.addDraft(() => {
      calls.push('slash')
      return Promise.resolve(false)
    })
    expect(await tracker.settle()).toBe(false)
    expect(calls).toEqual(['empty', 'slash'])
  })

  it('stops a draft after its remove function runs', async () => {
    const tracker = new SaveTracker()
    const remove = tracker.addDraft(() => Promise.resolve(false))
    remove()
    expect(await tracker.settle()).toBe(true)
  })

  it('reset forgets a failure, for example when the section changes', async () => {
    const tracker = new SaveTracker()
    tracker.track(Promise.resolve(false))
    await new Promise(resolve => setTimeout(resolve, 0))
    tracker.reset()
    expect(await tracker.settle()).toBe(true)
  })

  it('a reset does not forget a save that still runs', async () => {
    const tracker = new SaveTracker()
    const save = deferred<boolean>()
    tracker.track(save.promise)
    tracker.reset()
    const result = tracker.settle()
    save.reject(new Error('refused'))
    expect(await result).toBe(false)
  })
})
