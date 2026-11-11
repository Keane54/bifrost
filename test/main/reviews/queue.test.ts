import { describe, expect, it } from 'vitest'
import { enqueue, pickNext } from '../../../src/main/reviews/queue'
import { MAX_QUEUE, type QueueEntry } from '../../../src/main/reviews/state'

const entry = (key: string, at: number): QueueEntry => ({ at, key, kind: 'review' })

describe('enqueue', () => {
  it('enqueue keeps one entry for each key', () => {
    const one = enqueue([], entry('acme/web#1', 5))
    expect(one).toEqual([entry('acme/web#1', 5)])
    // A second entry for the key keeps the earliest time.
    expect(enqueue(one, entry('acme/web#1', 9))).toEqual([entry('acme/web#1', 5)])
    expect(enqueue(one, entry('acme/web#1', 2))).toEqual([entry('acme/web#1', 2)])
    // Other keys stay in the order of their time.
    const two = enqueue(one, entry('acme/web#2', 3))
    expect(two.map(e => e.key)).toEqual(['acme/web#2', 'acme/web#1'])
    // The function does not change its input.
    expect(one).toEqual([entry('acme/web#1', 5)])
  })

  it('keeps the oldest entries up to the cap', () => {
    let queue: QueueEntry[] = []
    for (let i = 1; i <= MAX_QUEUE; i++) queue = enqueue(queue, entry(`acme/web#${i}`, i))
    const full = enqueue(queue, entry('acme/web#999', MAX_QUEUE + 1))
    expect(full).toHaveLength(MAX_QUEUE)
    expect(full.some(e => e.key === 'acme/web#999')).toBe(false)
    const older = enqueue(queue, entry('acme/web#998', 0))
    expect(older).toHaveLength(MAX_QUEUE)
    expect(older[0]?.key).toBe('acme/web#998')
  })
})

describe('pickNext', () => {
  const queue = [entry('a/a#1', 1), entry('a/a#2', 2), entry('a/a#3', 3), entry('a/a#4', 4)]

  it('pickNext gives the oldest ready entries up to the free slots', () => {
    const all = () => true
    expect(pickNext({ max: 3, queue, ready: all, running: 1 }).map(e => e.key)).toEqual([
      'a/a#1',
      'a/a#2',
    ])
    expect(pickNext({ max: 3, queue, ready: all, running: 3 })).toEqual([])
    expect(pickNext({ max: 3, queue, ready: all, running: 5 })).toEqual([])
    // The order of the input does not matter.
    const mixed = [queue[2], queue[0], queue[1]] as QueueEntry[]
    expect(pickNext({ max: 1, queue: mixed, ready: all, running: 0 })[0]?.key).toBe('a/a#1')
  })

  it('an entry that is not ready blocks nothing', () => {
    const ready = (key: string) => key !== 'a/a#1' && key !== 'a/a#3'
    expect(pickNext({ max: 2, queue, ready, running: 0 }).map(e => e.key)).toEqual([
      'a/a#2',
      'a/a#4',
    ])
  })
})
