import { describe, expect, test } from 'vitest'
import { loginItemPatch, settingsEffects } from '../../../src/main/settings/effects'
import { DEFAULT_SETTINGS, parseSettings, type Settings } from '../../../src/shared/settings'

const base = (): Settings => parseSettings({ version: 1 })

describe('settingsEffects', () => {
  test('settingsEffects gives one effect for each changed setting, in order', () => {
    const prev = base()
    const next = { ...prev, escalationMinutes: 0, pollSeconds: 5, startAtLogin: true }
    expect(settingsEffects(prev, next)).toEqual([
      { kind: 'escalation', ms: 0 },
      { kind: 'poll', ms: 5000 },
      { kind: 'login-item', on: true },
    ])
    const all = {
      ...next,
      escalationMinutes: 30,
      interfaceScale: 120,
      keys: { 'toggle-fullscreen:mod': null },
    }
    expect(settingsEffects(prev, all)).toEqual([
      { kind: 'escalation', ms: 1_800_000 },
      { kind: 'poll', ms: 5000 },
      { kind: 'login-item', on: true },
      { kind: 'menu' },
      { factor: 1.2, kind: 'zoom' },
    ])
  })

  test('settingsEffects gives an account-usage effect when the setting changes', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, accountUsage: true })).toEqual([
      { kind: 'account-usage', on: true },
    ])
    expect(settingsEffects({ ...prev, accountUsage: true }, prev)).toEqual([
      { kind: 'account-usage', on: false },
    ])
    expect(settingsEffects(prev, { ...prev, accountUsage: false })).toEqual([])
  })

  test('settingsEffects gives an updates effect when Check for updates automatically changes', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, autoUpdate: false })).toEqual([
      { kind: 'updates', on: false },
    ])
    expect(settingsEffects({ ...prev, autoUpdate: false }, prev)).toEqual([
      { kind: 'updates', on: true },
    ])
    expect(settingsEffects(prev, { ...prev, autoUpdate: true })).toEqual([])
  })

  test('the Reviews settings give the Reviews effects', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, reviewsWatch: true })).toEqual([
      { kind: 'reviews', on: true },
    ])
    expect(settingsEffects({ ...prev, reviewsWatch: true }, prev)).toEqual([
      { kind: 'reviews', on: false },
    ])
    expect(settingsEffects(prev, { ...prev, reviewsIgnore: ['acme/*'] })).toEqual([
      { kind: 'reviews-view' },
    ])
    expect(settingsEffects(prev, { ...prev, reviewsTeamRequests: false })).toEqual([
      { kind: 'reviews-view' },
    ])
    expect(settingsEffects(prev, { ...prev, reviewsPollMinutes: 5 })).toEqual([
      { kind: 'reviews-poll' },
    ])
    expect(
      settingsEffects(prev, { ...prev, reviewsIgnore: ['acme/*'], reviewsPollMinutes: 10 }),
    ).toEqual([{ kind: 'reviews-view' }, { kind: 'reviews-poll' }])
    expect(settingsEffects(prev, { ...prev, reviewsMaxSessions: 5 })).toEqual([])
  })

  test('a key change gives a menu effect only for a menu slot', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, keys: { 'open:mod': 'Mod+K' } })).toEqual([])
    expect(settingsEffects(prev, { ...prev, keys: { 'close-panel:mod': 'Mod+Shift+W' } })).toEqual([
      { kind: 'menu' },
    ])
    // A change to the default binding does not change the effective binding.
    expect(settingsEffects(prev, { ...prev, keys: { 'close-panel:mod': 'Mod+W' } })).toEqual([])
  })

  test('a terminal app change gives no effect', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, terminalApp: 'warp' })).toEqual([])
    const others: Settings = {
      ...prev,
      animatedBackground: false,
      labels: 'space',
      notifications: false,
      panelTransparency: 30,
      projectApp: 'zed',
      redBoxSound: false,
      rowFlash: false,
      setupDone: true,
      slashCommands: [],
      snapDistance: 0,
      terminalApp: 'ghostty',
      terminalFont: { family: 'Menlo', size: 16 },
    }
    expect(settingsEffects(prev, others)).toEqual([])
    expect(settingsEffects(prev, prev)).toEqual([])
  })

  test('an interface scale change gives a zoom effect', () => {
    const prev = base()
    expect(settingsEffects(prev, { ...prev, interfaceScale: 80 })).toEqual([
      { factor: 0.8, kind: 'zoom' },
    ])
  })
})

describe('loginItemPatch', () => {
  test('loginItemPatch gives the real state when it differs', () => {
    const off = { ...DEFAULT_SETTINGS, startAtLogin: false }
    const on = { ...DEFAULT_SETTINGS, startAtLogin: true }
    expect(loginItemPatch(off, true)).toEqual({ startAtLogin: true })
    expect(loginItemPatch(on, false)).toEqual({ startAtLogin: false })
    expect(loginItemPatch(off, false)).toBeNull()
    expect(loginItemPatch(on, true)).toBeNull()
  })
})
