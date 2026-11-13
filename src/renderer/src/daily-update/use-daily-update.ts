// The app-wide state of the Daily update panel. One store holds the newest snapshot from the
// main process. The side bar and the panel read it, so the app has one subscription. A second
// store holds the chosen tab, so the route of a reminder can choose a tab.
import type { Dispatch } from 'react'
import { useSyncExternalStore } from 'react'
import type { BifrostApi } from '../../../shared/api'
import type { DailySnapshot } from '../../../shared/daily-state'
import { createSnapshotStore, type SnapshotStore } from '../lib/snapshot-store'
import type { WmAction } from '../wm/state'

// The panel ID of the Daily update panel.
export const DAILY_PANEL = 'daily-update'

type DailyApi = Pick<BifrostApi['dailyUpdate'], 'onUpdate' | 'snapshot'>

// The value is null until the first snapshot comes.
export function createDailyStore(api: () => DailyApi): SnapshotStore<DailySnapshot | null> {
  return createSnapshotStore<DailySnapshot, null>(api, null)
}

const store = createDailyStore(() => window.bifrost.dailyUpdate)

// The newest snapshot, for the panel. null until the first snapshot comes.
export function useDailyUpdate(): DailySnapshot | null {
  return useSyncExternalStore(store.subscribe, store.get)
}

export function dailyMarker(snapshot: DailySnapshot | null): boolean {
  return snapshot?.marker === true
}

// The marker only, for the side bar. A new snapshot with the same marker does not render the
// side bar.
export function useDailyMarker(): boolean {
  return useSyncExternalStore(store.subscribe, () => dailyMarker(store.get()))
}

// The area ID of the chosen tab. null lets the panel choose the first area that is not sent.
let chosenTab: string | null = null
const tabListeners = new Set<() => void>()

export function getDailyTab(): string | null {
  return chosenTab
}

export function setDailyTab(id: string | null): void {
  if (id === chosenTab) return
  chosenTab = id
  for (const listener of [...tabListeners]) listener()
}

export function subscribeDailyTab(listener: () => void): () => void {
  tabListeners.add(listener)
  return () => {
    tabListeners.delete(listener)
  }
}

export function useDailyTab(): string | null {
  return useSyncExternalStore(subscribeDailyTab, getDailyTab)
}

// A click on a reminder: choose the tab of the area and open the panel.
export function openDaily(areaId: string | null, dispatch: Dispatch<WmAction>): void {
  setDailyTab(areaId)
  dispatch({ panelId: DAILY_PANEL, type: 'open' })
}
