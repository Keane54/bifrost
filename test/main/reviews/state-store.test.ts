import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { EMPTY_STATE } from '../../../src/main/reviews/state'
import { openReviewsStateStore, reviewsStateFile } from '../../../src/main/reviews/state-store'

let home: string
beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-reviews-state-'))
})
afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

describe('reviewsStateFile', () => {
  it('gives the path in the reviews folder', () => {
    expect(reviewsStateFile('/h')).toBe('/h/reviews/state.json')
  })
})

describe('openReviewsStateStore', () => {
  it('starts empty when there is no file', async () => {
    const store = await openReviewsStateStore(reviewsStateFile(home))
    expect(store.get()).toEqual(EMPTY_STATE)
  })

  it('writes the file and makes the folder with mode 0700', async () => {
    const file = reviewsStateFile(home)
    const store = await openReviewsStateStore(file)
    await store.change(s => ({ ...s, turnedOnAt: 42 }))
    expect(JSON.parse(await readFile(file, 'utf8')).turnedOnAt).toBe(42)
    expect((await stat(join(home, 'reviews'))).mode & 0o777).toBe(0o700)
    const again = await openReviewsStateStore(file)
    expect(again.get().turnedOnAt).toBe(42)
  })

  it('runs two change calls in order', async () => {
    const store = await openReviewsStateStore(reviewsStateFile(home))
    const first = store.change(s => ({ ...s, baseline: [...s.baseline, 'a'] }))
    const second = store.change(s => ({ ...s, baseline: [...s.baseline, 'b'] }))
    await Promise.all([first, second])
    expect(store.get().baseline).toEqual(['a', 'b'])
  })

  it('keeps going after a change function throws', async () => {
    const store = await openReviewsStateStore(reviewsStateFile(home))
    await expect(
      store.change(() => {
        throw new Error('boom')
      }),
    ).rejects.toThrow('boom')
    await store.change(s => ({ ...s, turnedOnAt: 1 }))
    expect(store.get().turnedOnAt).toBe(1)
  })

  it('does not save after a read error', async () => {
    const file = reviewsStateFile(home)
    await mkdir(file, { recursive: true })
    const logs: string[] = []
    const store = await openReviewsStateStore(file, m => logs.push(m))
    expect(store.get()).toEqual(EMPTY_STATE)
    expect(logs).toHaveLength(1)
    await store.change(s => ({ ...s, turnedOnAt: 7 }))
    expect(store.get().turnedOnAt).toBe(7)
    expect((await stat(file)).isDirectory()).toBe(true)
  })

  it('the health log gets each write, and nothing when the store does not save', async () => {
    const save = vi.fn()
    const store = await openReviewsStateStore(reviewsStateFile(home), () => {}, { save })
    // A file in place of the reviews folder makes the write fail.
    await writeFile(join(home, 'reviews'), 'x')
    await expect(store.change(s => ({ ...s, turnedOnAt: 1 }))).rejects.toThrow()
    await rm(join(home, 'reviews'))
    await store.change(s => ({ ...s, turnedOnAt: 2 }))
    // A change function that throws writes nothing.
    await expect(
      store.change(() => {
        throw new Error('boom')
      }),
    ).rejects.toThrow('boom')
    expect(save.mock.calls).toEqual([
      ['reviews-state', false],
      ['reviews-state', true],
    ])
    // A store that cannot read its file does not save. So it reports nothing.
    const blocked = join(home, 'blocked.json')
    await mkdir(blocked)
    const other = vi.fn()
    const off = await openReviewsStateStore(blocked, () => {}, { save: other })
    await off.change(s => ({ ...s, turnedOnAt: 3 }))
    expect(other).not.toHaveBeenCalled()
  })
})
