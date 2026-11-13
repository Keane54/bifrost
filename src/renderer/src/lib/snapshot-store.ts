// A store of the newest snapshot of the main process, with one subscription for all its
// listeners. The Performance panel and the Daily update panel use it.

export interface SnapshotApi<T> {
  // The returned function removes only this listener.
  onUpdate(cb: (snapshot: T) => void): () => void
  snapshot(): Promise<T>
}

export interface SnapshotStore<V> {
  get(): V
  subscribe(listener: () => void): () => void
}

// The first listener starts the subscription and the last listener stops it. The store
// subscribes first and then loads the value. An update that comes before the first answer wins.
// Until the first value, get gives initial.
export function createSnapshotStore<T, I = T>(
  api: () => SnapshotApi<T>,
  initial: I,
): SnapshotStore<T | I> {
  let current: T | I = initial
  const listeners = new Set<() => void>()
  let stop: (() => void) | null = null
  // A new start makes the answers of an old start go stale.
  let generation = 0

  const set = (next: T): void => {
    current = next
    for (const listener of [...listeners]) listener()
  }

  const start = (): void => {
    const gen = ++generation
    let updated = false
    const off = api().onUpdate(next => {
      updated = true
      if (gen === generation) set(next)
    })
    api()
      .snapshot()
      .then(
        first => {
          if (gen === generation && !updated) set(first)
        },
        () => {},
      )
    stop = () => {
      generation++
      off()
    }
  }

  return {
    get: () => current,
    subscribe(listener) {
      listeners.add(listener)
      if (stop === null) start()
      return () => {
        listeners.delete(listener)
        if (listeners.size > 0 || stop === null) return
        stop()
        stop = null
      }
    },
  }
}
