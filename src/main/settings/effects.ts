// The changes that the main process makes when a setting changes (D2).
import { effectiveKeys, KEY_SLOTS } from '../../shared/keys'
import type { Settings, SettingsPatch } from '../../shared/settings'

export type SettingsEffect =
  | { kind: 'escalation'; ms: number }
  | { kind: 'poll'; ms: number }
  | { kind: 'login-item'; on: boolean }
  | { kind: 'menu' }
  | { kind: 'zoom'; factor: number }
  | { kind: 'account-usage'; on: boolean }
  | { kind: 'reviews'; on: boolean }
  | { kind: 'reviews-view' }
  | { kind: 'reviews-poll' }
  | { kind: 'updates'; on: boolean }

// The slots of the menu accelerators (D7).
const MENU_SLOTS = KEY_SLOTS.filter(slot => slot.menu).map(slot => slot.id)

// Return true when the effective binding of a menu slot changed.
function menuKeysChanged(prev: Settings, next: Settings): boolean {
  if (prev.keys === next.keys) return false
  const before = effectiveKeys(prev.keys)
  const after = effectiveKeys(next.keys)
  return MENU_SLOTS.some(id => before[id] !== after[id])
}

// Return true when two lists have the same items in the same order.
function sameList(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((item, index) => item === b[index])
}

// Return the effects of a change, in this order: escalation, poll, login item, menu, zoom,
// account usage, reviews, reviews view, reviews poll, updates.
// A change of the terminal app needs no effect here. The main process finds the apps at each
// call and keeps no cache.
export function settingsEffects(prev: Settings, next: Settings): SettingsEffect[] {
  const effects: SettingsEffect[] = []
  if (prev.escalationMinutes !== next.escalationMinutes) {
    effects.push({ kind: 'escalation', ms: next.escalationMinutes * 60_000 })
  }
  if (prev.pollSeconds !== next.pollSeconds) {
    effects.push({ kind: 'poll', ms: next.pollSeconds * 1000 })
  }
  if (prev.startAtLogin !== next.startAtLogin) {
    effects.push({ kind: 'login-item', on: next.startAtLogin })
  }
  if (menuKeysChanged(prev, next)) effects.push({ kind: 'menu' })
  if (prev.interfaceScale !== next.interfaceScale) {
    effects.push({ factor: next.interfaceScale / 100, kind: 'zoom' })
  }
  if (prev.accountUsage !== next.accountUsage) {
    effects.push({ kind: 'account-usage', on: next.accountUsage })
  }
  if (prev.reviewsWatch !== next.reviewsWatch) {
    effects.push({ kind: 'reviews', on: next.reviewsWatch })
  }
  if (
    prev.reviewsTeamRequests !== next.reviewsTeamRequests ||
    !sameList(prev.reviewsIgnore, next.reviewsIgnore)
  ) {
    effects.push({ kind: 'reviews-view' })
  }
  // The watcher sets its next poll again from the new interval.
  if (prev.reviewsPollMinutes !== next.reviewsPollMinutes) effects.push({ kind: 'reviews-poll' })
  if (prev.autoUpdate !== next.autoUpdate) effects.push({ kind: 'updates', on: next.autoUpdate })
  return effects
}

// At the start, the real login item state wins over the file (D2).
// Return the patch that sets the file to the real state, or null when they agree.
export function loginItemPatch(settings: Settings, realOn: boolean): SettingsPatch | null {
  return settings.startAtLogin === realOn ? null : { startAtLogin: realOn }
}
