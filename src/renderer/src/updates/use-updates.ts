// The app-wide state of the updater. One store holds the newest snapshot from the main process,
// so the app has one subscription. Settings reads the whole snapshot.
import { useSyncExternalStore } from 'react'
import type { BifrostApi } from '../../../shared/api'
import { EMPTY_UPDATES, type UpdatesSnapshot } from '../../../shared/updates'

type UpdatesApi = Pick<BifrostApi['updates'], 'onUpdate' | 'snapshot'>

export interface UpdatesStore {
  get(): UpdatesSnapshot
  subscribe(listener: () => void): () => void
}

// A store with one subscription to the main process for all its listeners. The first listener
// starts the subscription and the last listener stops it. The store subscribes first and then
// loads the value. A push that comes before the first answer wins.
export function createUpdatesStore(api: UpdatesApi): UpdatesStore {
  let current = EMPTY_UPDATES
  const listeners = new Set<() => void>()
  let stop: (() => void) | null = null
  // A new start makes the answers of an old start go stale.
  let generation = 0

  const set = (next: UpdatesSnapshot): void => {
    current = next
    for (const listener of [...listeners]) listener()
  }

  const start = (): void => {
    const gen = ++generation
    let pushed = false
    const off = api.onUpdate(next => {
      pushed = true
      if (gen === generation) set(next)
    })
    api.snapshot().then(
      first => {
        if (gen === generation && !pushed) set(first)
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

const store = createUpdatesStore({
  onUpdate: cb => window.bifrost.updates.onUpdate(cb),
  snapshot: () => window.bifrost.updates.snapshot(),
})

// The newest snapshot, for Settings.
export function useUpdates(): UpdatesSnapshot {
  return useSyncExternalStore(store.subscribe, store.get)
}
