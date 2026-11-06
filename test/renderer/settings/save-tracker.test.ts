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

// Two rows of the Settings panel. A row is any object that stays the same for the row.
const SNAP = { row: 'Snap distance' }
const FONT = { row: 'Terminal font' }

describe('SaveTracker', () => {
  it('settles at once with true when no save runs', async () => {
    expect(await new SaveTracker().settle()).toBe(true)
  })

  it('waits for a save that runs, and gives true when it worked', async () => {
    const tracker = new SaveTracker()
    const save = deferred<boolean>()
    tracker.track(SNAP, save.promise)
    const result = tracker.settle()
    expect(await settled(result)).toBe(false)
    save.resolve(true)
    expect(await result).toBe(true)
  })

  it('gives false while a row has a failed save, also at the next settle', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.resolve(false))
    expect(await tracker.settle()).toBe(false)
    expect(await tracker.settle()).toBe(false)
  })

  it('gives false for a save that rejects', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.reject(new Error('disk full')))
    expect(await tracker.settle()).toBe(false)
  })

  // Review Important 1: the user corrects the value, and the row error goes away.
  it('a good save of the same row clears its failure', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.resolve(false))
    expect(await tracker.settle()).toBe(false)
    tracker.track(SNAP, Promise.resolve(true))
    expect(await tracker.settle()).toBe(true)
  })

  it('forget clears the failure of a row: its error closed, or the row unmounted', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.resolve(false))
    await new Promise(resolve => setTimeout(resolve, 0))
    tracker.forget(SNAP)
    expect(await tracker.settle()).toBe(true)
  })

  it('a good save of another row does not clear the failure', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.resolve(false))
    tracker.track(FONT, Promise.resolve(true))
    expect(await tracker.settle()).toBe(false)
  })

  it('the last save that a row started gives its state, in any order of the results', async () => {
    const tracker = new SaveTracker()
    const first = deferred<boolean>()
    const second = deferred<boolean>()
    tracker.track(SNAP, first.promise)
    tracker.track(SNAP, second.promise)
    second.resolve(true)
    first.resolve(false)
    expect(await tracker.settle()).toBe(true)
  })

  it('also waits for a save that starts while it waits', async () => {
    const tracker = new SaveTracker()
    const first = deferred<boolean>()
    const second = deferred<boolean>()
    tracker.track(SNAP, first.promise)
    const result = tracker.settle()
    tracker.track(FONT, second.promise)
    first.resolve(true)
    expect(await settled(result)).toBe(false)
    second.resolve(false)
    expect(await result).toBe(false)
  })

  it('a forget does not stop a save that still runs', async () => {
    const tracker = new SaveTracker()
    const save = deferred<boolean>()
    tracker.track(SNAP, save.promise)
    tracker.forget(SNAP)
    const result = tracker.settle()
    save.reject(new Error('refused'))
    expect(await result).toBe(false)
  })

  // A row that unmounts while its save runs can never close its error. So its result is ignored.
  it('remove clears a row and ignores its saves that still run', async () => {
    const tracker = new SaveTracker()
    tracker.track(SNAP, Promise.resolve(false))
    const save = deferred<boolean>()
    tracker.track(FONT, save.promise)
    await new Promise(resolve => setTimeout(resolve, 0))
    tracker.remove(SNAP)
    tracker.remove(FONT)
    const result = tracker.settle()
    expect(await settled(result)).toBe(false)
    save.resolve(false)
    expect(await result).toBe(true)
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

  it('a refused draft stops the next settle only while it still has text', async () => {
    const tracker = new SaveTracker()
    let text = '/bad command'
    tracker.addDraft(() => (text === '' ? null : Promise.resolve(false)))
    expect(await tracker.settle()).toBe(false)
    text = ''
    expect(await tracker.settle()).toBe(true)
  })

  it('stops a draft after its remove function runs', async () => {
    const tracker = new SaveTracker()
    const remove = tracker.addDraft(() => Promise.resolve(false))
    remove()
    expect(await tracker.settle()).toBe(true)
  })
})
