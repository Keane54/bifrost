import { mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
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
})
