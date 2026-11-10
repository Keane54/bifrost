// The app-wide state of the updater. One store holds the newest snapshot from the main process,
// so the app has one subscription. Settings reads the whole snapshot. The side bar reads only
// the state of its button.
import { useMemo, useSyncExternalStore } from 'react'
import type { BifrostApi } from '../../../shared/api'
import { EMPTY_UPDATES, type UpdatesSnapshot } from '../../../shared/updates'

type UpdatesApi = Pick<BifrostApi['updates'], 'onUpdate' | 'snapshot'>

export interface UpdatesStore {
  get(): UpdatesSnapshot
  // True after the first answer or the first push.
  loaded(): boolean
  subscribe(listener: () => void): () => void
}

// A store with one subscription to the main process for all its listeners. The first listener
// starts the subscription and the last listener stops it. The store subscribes first and then
// loads the value. A push that comes before the first answer wins.
export function createUpdatesStore(api: UpdatesApi): UpdatesStore {
  let current = EMPTY_UPDATES
  let isLoaded = false
  const listeners = new Set<() => void>()
  let stop: (() => void) | null = null
  // A new start makes the answers of an old start go stale.
  let generation = 0

  const set = (next: UpdatesSnapshot): void => {
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

const store = createUpdatesStore({
  onUpdate: cb => window.bifrost.updates.onUpdate(cb),
  snapshot: () => window.bifrost.updates.snapshot(),
})

// The newest snapshot, for Settings.
export function useUpdates(): UpdatesSnapshot {
  return useSyncExternalStore(store.subscribe, store.get)
}

// The loaded flag, for Settings.
export function useUpdatesLoaded(): boolean {
  return useSyncExternalStore(store.subscribe, store.loaded)
}

export type UpdateButtonState = { kind: 'ready'; version: string } | { kind: 'failed' } | null

// The state of the side bar button. Only the ready and failed states show a button.
export function updateButtonOf(snapshot: UpdatesSnapshot): UpdateButtonState {
  if (!snapshot.available) return null
  if (snapshot.state.kind === 'ready') return { kind: 'ready', version: snapshot.state.version }
  if (snapshot.state.kind === 'failed') return { kind: 'failed' }
  return null
}

// The key is a string, so React compares it by value. The hook gives a new object only when the
// button changes. The side bar is memo, so it does not draw again for a download percent.
function buttonKey(snapshot: UpdatesSnapshot): string {
  const button = updateButtonOf(snapshot)
  if (button === null) return ''
  return button.kind === 'ready' ? `ready:${button.version}` : 'failed'
}

export function useUpdateButton(): UpdateButtonState {
  const key = useSyncExternalStore(store.subscribe, () => buttonKey(store.get()))
  return useMemo(() => {
    if (key === '') return null
    return key === 'failed'
      ? { kind: 'failed' }
      : { kind: 'ready', version: key.slice('ready:'.length) }
  }, [key])
}
