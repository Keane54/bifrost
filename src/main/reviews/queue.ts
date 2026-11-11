// The queue of review rounds. Pure functions, no I/O.

import { MAX_QUEUE, type QueueEntry } from './state'

const sameJob = (a: QueueEntry, b: QueueEntry): boolean => a.key === b.key && a.kind === b.kind

// Add the entry. The queue keeps one entry for each key and kind, with the earliest time. The
// entries stay in the order of their time. The cap keeps the oldest entries, because the oldest
// entry runs first.
export function enqueue(queue: readonly QueueEntry[], entry: QueueEntry): QueueEntry[] {
  const known = queue.find(e => sameJob(e, entry))
  const kept = known === undefined ? [...queue] : queue.filter(e => !sameJob(e, entry))
  const at = known === undefined ? entry.at : Math.min(known.at, entry.at)
  // The sort is stable, so entries with the same time keep their order.
  const next = [...kept, { ...entry, at }].sort((a, b) => a.at - b.at)
  return next.length > MAX_QUEUE ? next.slice(0, MAX_QUEUE) : next
}

// The oldest ready entries, up to the free slots (max - running). An entry that is not ready
// keeps its place and blocks nothing.
export function pickNext(o: {
  queue: readonly QueueEntry[]
  running: number
  max: number
  ready(key: string): boolean
}): QueueEntry[] {
  const free = Math.max(0, o.max - o.running)
  const picked: QueueEntry[] = []
  if (free === 0) return picked
  for (const entry of [...o.queue].sort((a, b) => a.at - b.at)) {
    if (!o.ready(entry.key)) continue
    picked.push(entry)
    if (picked.length >= free) break
  }
  return picked
}
