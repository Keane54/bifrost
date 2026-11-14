// The app-wide rows of the modules (plan Task 6). One store holds the newest snapshot from the
// main process, so the app has one subscription. The side bar, the panel titles and the module
// panels read it.
import { useSyncExternalStore } from 'react'
import type { BifrostApi } from '../../../shared/api'
import type { ModulesSnapshot } from '../../../shared/modules'

type ModulesApi = Pick<BifrostApi['modules'], 'onUpdate' | 'snapshot'>

export const EMPTY_MODULES: ModulesSnapshot = Object.freeze({ modules: [] })

export interface ModulesStore {
  get(): ModulesSnapshot
  // True after the first answer or the first push.
  loaded(): boolean
  subscribe(listener: () => void): () => void
}

// A store with one subscription to the main process for all its listeners. The first listener
// starts the subscription and the last listener stops it. The store subscribes first and then
// loads the value. A push that comes before the first answer wins.
export function createModulesStore(api: ModulesApi): ModulesStore {
  let current = EMPTY_MODULES
  let isLoaded = false
  const listeners = new Set<() => void>()
  let stop: (() => void) | null = null
  // A new start makes the answers of an old start go stale.
  let generation = 0

  const set = (next: ModulesSnapshot): void => {
    current = next
    isLoaded = true
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
    loaded: () => isLoaded,
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

const store = createModulesStore({
  onUpdate: cb => window.bifrost.modules.onUpdate(cb),
  snapshot: () => window.bifrost.modules.snapshot(),
})

// The newest rows of the modules.
export function useModules(): ModulesSnapshot {
  return useSyncExternalStore(store.subscribe, store.get)
}

// True after the first rows came. Before that, a module panel shows no notice.
export function useModulesLoaded(): boolean {
  return useSyncExternalStore(store.subscribe, store.loaded)
}
