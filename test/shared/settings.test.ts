import { describe, expect, test } from 'vitest'
import { DEFAULT_DAILY_UPDATE } from '../../src/shared/daily-update'
import { MODEL_VALUES } from '../../src/shared/new-session'
import {
  applyPatch,
  checkFontFamily,
  checkSlashCommand,
  cssFontFamily,
  DEFAULT_SETTINGS,
  defaultProjectApp,
  INTERFACE_SCALE_CHOICES,
  PANEL_TRANSPARENCY_CHOICES,
  POLL_CHOICES,
  parseSettings,
  projectAppChoices,
  REASON_FONT,
  REASON_SLASH_LINE,
  REASON_SLASH_LONG,
  REASON_SLASH_START,
  type Settings,
  shownProjectApp,
  TERMINAL_APP_IDS,
} from '../../src/shared/settings'
import { TERMINAL_ORDER } from '../../src/shared/terminal-order'
import type { ProjectApp } from '../../src/shared/types'

const defaults = (): Settings => parseSettings({ version: 1 })

// Return the reason of a refused patch, or 'ok'.
function reasonOf(current: Settings, patch: unknown): string {
  const result = applyPatch(current, patch)
  return result.ok ? 'ok' : result.reason
}

describe('parseSettings', () => {
  test('parseSettings gives the defaults of spec 12 for bad data', () => {
    for (const bad of [null, undefined, [], 'x', 7, { version: 2 }, { labels: 'space' }]) {
      expect(parseSettings(bad)).toEqual(DEFAULT_SETTINGS)
    }
    expect(DEFAULT_SETTINGS).toEqual({
      accountUsage: false,
      animatedBackground: true,
      autoUpdate: true,
      dailyUpdate: DEFAULT_DAILY_UPDATE,
      escalationMinutes: 10,
      interfaceScale: 100,
      keys: {},
      labels: 'plain',
      notifications: true,
      panelTransparency: 15,
      pollSeconds: 2,
      projectApp: null,
      redBoxSound: true,
      reviewsAutoFix: true,
      reviewsIgnore: [],
      reviewsMaxSessions: 3,
      reviewsPauseMinutes: 60,
      reviewsPollMinutes: 2,
      reviewsRequestModel: '',
      reviewsReviewModel: '',
      reviewsTeamRequests: true,
      reviewsWatch: false,
      rowFlash: true,
      setupDone: false,
      slashCommands: ['/compact', '/clear', '/context'],
      snapDistance: 8,
      startAtLogin: false,
      terminalApp: null,
      terminalFont: { family: 'SF Mono', size: 13 },
      version: 1,
    })
    // The result is a copy. A change to it does not change the defaults.
    const copy = parseSettings(null)
    copy.slashCommands.push('/x')
    copy.terminalFont.size = 20
    expect(DEFAULT_SETTINGS.slashCommands).toEqual(['/compact', '/clear', '/context'])
    expect(DEFAULT_SETTINGS.terminalFont.size).toBe(13)
  })

  test('settings load an old file with no dailyUpdate as DEFAULT_DAILY_UPDATE', () => {
    const loaded = parseSettings({ labels: 'space', version: 1 })
    expect(loaded.dailyUpdate).toEqual(DEFAULT_DAILY_UPDATE)
    loaded.dailyUpdate.days.push(0)
    expect(DEFAULT_DAILY_UPDATE.days).toEqual([1, 2, 3, 4, 5])
  })

  test('a dailyUpdate patch goes through checkDailyUpdate', () => {
    const current = defaults()
    const good = { ...DEFAULT_DAILY_UPDATE, you: 'Sam' }
    const result = applyPatch(current, { dailyUpdate: good })
    expect(result.ok && result.settings.dailyUpdate.you).toBe('Sam')
    expect(reasonOf(current, { dailyUpdate: { ...good, days: [] } })).toBe(
      'refused: bad dailyUpdate',
    )
  })

  test('parseSettings keeps good values and gives the default for each bad value', () => {
    expect(
      parseSettings({
        escalationMinutes: -5,
        labels: 'space',
        notifications: 'yes',
        pollSeconds: 0,
        snapDistance: 8.5,
        terminalFont: { family: 'Menlo', size: 200 },
        version: 1,
      }),
    ).toEqual({
      ...DEFAULT_SETTINGS,
      escalationMinutes: 10,
      labels: 'space',
      notifications: true,
      pollSeconds: 2,
      snapDistance: 8,
      terminalFont: { family: 'Menlo', size: 13 },
    })
  })

  // User decision, 2026-11-06: the background shifts slowly. A setting turns the motion off.
  test('parseSettings keeps a boolean animatedBackground and gives true for a bad value', () => {
    const animated = (value: unknown) =>
      parseSettings({ animatedBackground: value, version: 1 }).animatedBackground
    expect([true, false].map(animated)).toEqual([true, false])
    expect([undefined, null, 'false', 0, 1].map(animated)).toEqual([true, true, true, true, true])
  })

  // Updater design: the switch "Check for updates automatically" is on by default.
  test('parseSettings keeps a boolean autoUpdate and gives true for a bad value', () => {
    const auto = (value: unknown) => parseSettings({ autoUpdate: value, version: 1 }).autoUpdate
    expect([true, false].map(auto)).toEqual([true, false])
    expect([undefined, null, 'false', 0, 1].map(auto)).toEqual([true, true, true, true, true])
  })

  test('parseSettings keeps escalation 0', () => {
    expect(parseSettings({ escalationMinutes: 0, version: 1 }).escalationMinutes).toBe(0)
    expect(parseSettings({ escalationMinutes: 120, version: 1 }).escalationMinutes).toBe(120)
    expect(parseSettings({ escalationMinutes: 121, version: 1 }).escalationMinutes).toBe(10)
    expect(parseSettings({ escalationMinutes: 2.5, version: 1 }).escalationMinutes).toBe(10)
  })

  test('parseSettings ignores unknown keys', () => {
    const parsed = parseSettings({ theme: 'light', version: 1 })
    expect(parsed).not.toHaveProperty('theme')
    expect(parsed).toEqual(DEFAULT_SETTINGS)
  })

  test('parseSettings keeps 12 good slash commands once each', () => {
    const long = `/${'x'.repeat(200)}`
    const good = Array.from({ length: 12 }, (_, i) => `/g${i + 1}`)
    const parsed = parseSettings({
      slashCommands: ['/a', '/a', 'b', '/c\nd', '/ x', long, 7, '  /a  ', ...good],
      version: 1,
    })
    expect(parsed.slashCommands).toEqual(['/a', ...good.slice(0, 11)])
    expect(parseSettings({ slashCommands: [], version: 1 }).slashCommands).toEqual([])
    expect(parseSettings({ slashCommands: '/a', version: 1 }).slashCommands).toEqual([
      '/compact',
      '/clear',
      '/context',
    ])
  })

  test('parseSettings keeps a panel transparency and an interface scale on their steps', () => {
    const transparency = (value: unknown) =>
      parseSettings({ panelTransparency: value, version: 1 }).panelTransparency
    expect([0, 25, 50].map(transparency)).toEqual([0, 25, 50])
    expect([7, 55, -5, 12.5, '20', null].map(transparency)).toEqual([15, 15, 15, 15, 15, 15])
    const scale = (value: unknown) =>
      parseSettings({ interfaceScale: value, version: 1 }).interfaceScale
    expect([80, 120, 150].map(scale)).toEqual([80, 120, 150])
    expect([70, 85, 160, 1.1, '120'].map(scale)).toEqual([100, 100, 100, 100, 100])
  })

  test('parseSettings checks the apps, the choices, the font and the keys', () => {
    const parsed = parseSettings({
      keys: { 'nope:mod': 'Mod+J', 'open:key': 'K' },
      pollSeconds: 10,
      projectApp: 'zed',
      setupDone: true,
      snapDistance: 32,
      terminalApp: 'ghostty',
      terminalFont: { family: 'A"B', size: 20 },
      version: 1,
    })
    expect(parsed).toMatchObject({
      keys: { 'open:key': 'K' },
      pollSeconds: 10,
      projectApp: 'zed',
      setupDone: true,
      snapDistance: 32,
      terminalApp: 'ghostty',
      terminalFont: { family: 'SF Mono', size: 20 },
    })
    for (const poll of POLL_CHOICES) {
      expect(parseSettings({ pollSeconds: poll, version: 1 }).pollSeconds).toBe(poll)
    }
    const bad = parseSettings({
      pollSeconds: 4,
      projectApp: 'notepad',
      snapDistance: 33,
      terminalApp: 'finder',
      terminalFont: 'Menlo',
      version: 1,
    })
    expect(bad).toEqual(DEFAULT_SETTINGS)
  })
})

describe('the checks of a text', () => {
  test('checkSlashCommand trims the text and gives the reason of a bad command', () => {
    expect(checkSlashCommand('  /compact  ')).toEqual({ ok: true, text: '/compact' })
    expect(checkSlashCommand(`/${'x'.repeat(199)}`).ok).toBe(true)
    for (const text of ['x', '/', '/ x', '', '  ']) {
      expect(checkSlashCommand(text)).toEqual({ ok: false, reason: REASON_SLASH_START })
    }
    expect(checkSlashCommand('/a\nb')).toEqual({ ok: false, reason: REASON_SLASH_LINE })
    expect(checkSlashCommand('/a\rb')).toEqual({ ok: false, reason: REASON_SLASH_LINE })
    expect(checkSlashCommand(`/${'x'.repeat(200)}`)).toEqual({
      ok: false,
      reason: REASON_SLASH_LONG,
    })
    expect(REASON_SLASH_START).toBe('Start the command with "/", with no space after it.')
    expect(REASON_SLASH_LINE).toBe('Keep the command on one line.')
    expect(REASON_SLASH_LONG).toBe("That's too long. The limit is 200 characters.")
  })

  test('checkFontFamily refuses quotes and CSS characters', () => {
    expect(checkFontFamily('SF Mono')).toEqual({ family: 'SF Mono', ok: true })
    expect(checkFontFamily('  Menlo  ')).toEqual({ family: 'Menlo', ok: true })
    expect(checkFontFamily('x'.repeat(64)).ok).toBe(true)
    for (const text of [
      'A"B',
      "A'B",
      'A\\B',
      'a;b',
      '{x}',
      '<b>',
      '',
      '   ',
      'x'.repeat(65),
      'a\tb',
      'a\nb',
      'a\u007fb',
    ]) {
      expect(checkFontFamily(text)).toEqual({ ok: false, reason: REASON_FONT })
    }
    expect(REASON_FONT).toBe('Use 1 to 64 characters, without quotes or ; { } < >.')
  })
})

describe('Reviews settings', () => {
  test('applyPatch refuses a bad Reviews value and keeps a good one', () => {
    const current = defaults()
    expect(reasonOf(current, { reviewsMaxSessions: 11 })).toBe('refused: bad reviewsMaxSessions')
    expect(reasonOf(current, { reviewsPauseMinutes: 45 })).toBe('refused: bad reviewsPauseMinutes')
    expect(reasonOf(current, { reviewsPollMinutes: 3 })).toBe('refused: bad reviewsPollMinutes')
    expect(reasonOf(current, { reviewsRequestModel: 'gpt' })).toBe(
      'refused: bad reviewsRequestModel',
    )
    expect(reasonOf(current, { reviewsWatch: 'yes' })).toBe('refused: bad reviewsWatch')
    expect(reasonOf(current, { reviewsMaxSessions: 10, reviewsReviewModel: 'haiku' })).toBe('ok')
  })

  test('reviewsReviewModel accepts each value of MODEL_VALUES and refuses fable', () => {
    const current = defaults()
    for (const value of MODEL_VALUES) {
      expect(reasonOf(current, { reviewsReviewModel: value })).toBe('ok')
      expect(reasonOf(current, { reviewsRequestModel: value })).toBe('ok')
    }
    expect(reasonOf(current, { reviewsReviewModel: 'fable' })).toBe(
      'refused: bad reviewsReviewModel',
    )
  })

  test('parseSettings gives the default for a model that is not a choice', () => {
    expect(parseSettings({ reviewsReviewModel: 'fable', version: 1 }).reviewsReviewModel).toBe('')
    expect(parseSettings({ reviewsRequestModel: 'fable', version: 1 }).reviewsRequestModel).toBe('')
  })

  test('parseSettings gives an empty ignore list for a value that is not a list', () => {
    expect(parseSettings({ reviewsIgnore: 'x', version: 1 }).reviewsIgnore).toEqual([])
  })

  test('the ignore parse trims, lower-cases, drops bad entries and duplicates', () => {
    const parsed = parseSettings({
      reviewsIgnore: [' Acme/API ', 'acme/*', 'acme/api', 'bad'],
      version: 1,
    })
    expect(parsed.reviewsIgnore).toEqual(['acme/api', 'acme/*'])
  })

  test('applyPatch checks the ignore list', () => {
    const current = defaults()
    const result = applyPatch(current, { reviewsIgnore: [' Acme/API ', 'acme/*'] })
    expect(result.ok && result.settings.reviewsIgnore).toEqual(['acme/api', 'acme/*'])
    expect(reasonOf(current, { reviewsIgnore: 'x' })).toBe('refused: bad reviewsIgnore')
    expect(reasonOf(current, { reviewsIgnore: ['bad'] })).toBe('refused: bad reviewsIgnore')
    expect(reasonOf(current, { reviewsIgnore: [5] })).toBe('refused: bad reviewsIgnore')
    expect(reasonOf(current, { reviewsIgnore: ['a/b', 'A/B'] })).toBe('refused: bad reviewsIgnore')
    const many = Array.from({ length: 51 }, (_, i) => `acme/r${i}`)
    expect(reasonOf(current, { reviewsIgnore: many })).toBe('refused: bad reviewsIgnore')
  })
})

describe('applyPatch', () => {
  test('applyPatch refuses an unknown key, a bad value and a key conflict', () => {
    const current = defaults()
    expect(reasonOf(current, { theme: 1 })).toBe('refused: unknown setting theme')
    expect(reasonOf(current, { pollSeconds: 4 })).toBe('refused: bad pollSeconds')
    expect(reasonOf(current, { keys: { 'open:mod': 'Mod+L' } })).toBe(
      'refused: two keys have the same binding',
    )
  })

  test('applyPatch refuses each bad form with its reason', () => {
    const current = defaults()
    for (const bad of [null, [], 'x', 7]) {
      expect(reasonOf(current, bad)).toBe('refused: bad settings')
    }
    expect(reasonOf(current, { version: 1 })).toBe('refused: unknown setting version')
    // The first failure refuses the full patch.
    expect(reasonOf(current, { labels: 'space', theme: 1 })).toBe('refused: unknown setting theme')
    expect(reasonOf(current, { labels: 'fancy' })).toBe('refused: bad labels')
    expect(reasonOf(current, { escalationMinutes: 121 })).toBe('refused: bad escalationMinutes')
    expect(reasonOf(current, { rowFlash: 'yes' })).toBe('refused: bad rowFlash')
    expect(reasonOf(current, { accountUsage: 'yes' })).toBe('refused: bad accountUsage')
    expect(reasonOf(current, { accountUsage: true })).toBe('ok')
    expect(reasonOf(current, { animatedBackground: 'no' })).toBe('refused: bad animatedBackground')
    expect(reasonOf(current, { animatedBackground: false })).toBe('ok')
    expect(reasonOf(current, { autoUpdate: 'off' })).toBe('refused: bad autoUpdate')
    expect(reasonOf(current, { autoUpdate: false })).toBe('ok')
    expect(reasonOf(current, { terminalApp: 'finder' })).toBe('refused: bad terminalApp')
    expect(reasonOf(current, { panelTransparency: 7 })).toBe('refused: bad panelTransparency')
    expect(reasonOf(current, { interfaceScale: 160 })).toBe('refused: bad interfaceScale')
    expect(reasonOf(current, { slashCommands: ['/a', 'b'] })).toBe(REASON_SLASH_START)
    expect(reasonOf(current, { slashCommands: ['/a', '/a\nb'] })).toBe(REASON_SLASH_LINE)
    expect(reasonOf(current, { slashCommands: ['/a', ' /a '] })).toBe('refused: bad slashCommands')
    expect(reasonOf(current, { slashCommands: '/a' })).toBe('refused: bad slashCommands')
    expect(reasonOf(current, { slashCommands: [7] })).toBe('refused: bad slashCommands')
    const thirteen = Array.from({ length: 13 }, (_, i) => `/c${i}`)
    expect(reasonOf(current, { slashCommands: thirteen })).toBe('refused: bad slashCommands')
    expect(reasonOf(current, { slashCommands: thirteen.slice(0, 12) })).toBe('ok')
    expect(reasonOf(current, { terminalFont: { family: 'Menlo', size: 30 } })).toBe(
      'refused: bad terminalFont',
    )
    expect(reasonOf(current, { terminalFont: { family: 'Menlo' } })).toBe(
      'refused: bad terminalFont',
    )
    expect(reasonOf(current, { terminalFont: { family: 'a;b', size: 13 } })).toBe(
      'refused: bad terminalFont',
    )
    expect(reasonOf(current, { terminalFont: { colour: 'red', family: 'Menlo', size: 13 } })).toBe(
      'refused: bad terminalFont',
    )
    for (const keys of [
      'Mod+K',
      { 'nope:mod': 'Mod+K' },
      { constructor: 'Mod+K' },
      JSON.parse('{"__proto__": "Mod+K"}'),
      { 'open:mod': 'Mod+Q' },
      { 'open:hold': 'Mod+O' },
      { 'open:mod': 7 },
      { 'open:mod': 'Mod+Nope' },
    ]) {
      expect(reasonOf(current, { keys })).toBe('refused: bad keys')
    }
  })

  test('applyPatch keeps a conflict of the file and refuses only a new conflict', () => {
    // The file has a conflict: Mod+L opens the session and shows the Event log.
    const current = parseSettings({ keys: { 'open:mod': 'Mod+L' }, version: 1 })
    expect(current.keys).toEqual({ 'open:mod': 'Mod+L' })
    const kept = applyPatch(current, { keys: { 'open:mod': 'Mod+L', 'rename:key': 'F2' } })
    expect(kept).toEqual({
      ok: true,
      settings: { ...current, keys: { 'open:mod': 'Mod+L', 'rename:key': 'F2' } },
    })
    expect(reasonOf(current, { keys: { 'open:mod': 'Mod+L', 'usage-hud:mod': 'Mod+L' } })).toBe(
      'refused: two keys have the same binding',
    )
    // The same two slots with a new shared binding are a new conflict.
    expect(reasonOf(current, { keys: { 'event-log:mod': 'Mod+K', 'open:mod': 'Mod+K' } })).toBe(
      'refused: two keys have the same binding',
    )
    // A hold key and a single key can share a key.
    expect(reasonOf(defaults(), { keys: { 'open:hold': 'K', 'open:key': 'K' } })).toBe('ok')
  })

  test('applyPatch gives the same object when nothing changes', () => {
    const current = defaults()
    for (const patch of [
      {},
      { labels: 'plain', pollSeconds: 2 },
      { slashCommands: ['/compact', '/clear', '/context'] },
      { terminalFont: { family: 'SF Mono', size: 13 } },
      { keys: {} },
    ]) {
      const result = applyPatch(current, patch)
      expect(result.ok && result.settings).toBe(current)
    }
    const custom = parseSettings({ keys: { 'open:key': 'K', 'rename:key': null }, version: 1 })
    // The same keys in the other order.
    const keys = Object.fromEntries([
      ['rename:key', null],
      ['open:key', 'K'],
    ])
    const result = applyPatch(custom, { keys })
    expect(result.ok && result.settings).toBe(custom)
  })

  test('applyPatch changes only the named keys', () => {
    const current = defaults()
    const result = applyPatch(current, {
      escalationMinutes: 0,
      keys: { 'open:key': null, 'open:mod': 'shift+mod+k' },
      labels: 'space',
      slashCommands: ['  /review  '],
    })
    expect(result).toEqual({
      ok: true,
      settings: {
        ...DEFAULT_SETTINGS,
        escalationMinutes: 0,
        keys: { 'open:key': null, 'open:mod': 'Mod+Shift+K' },
        labels: 'space',
        slashCommands: ['/review'],
      },
    })
    expect(result.ok && result.settings).not.toBe(current)
    expect(current).toEqual(DEFAULT_SETTINGS)
  })
})

describe('the other helpers', () => {
  test('cssFontFamily puts the family first with the fallbacks', () => {
    expect(cssFontFamily({ family: 'JetBrains Mono', size: 13 })).toBe(
      '"JetBrains Mono", ui-monospace, Menlo, monospace',
    )
    expect(cssFontFamily(DEFAULT_SETTINGS.terminalFont)).toBe(
      '"SF Mono", ui-monospace, Menlo, monospace',
    )
  })

  const finder: ProjectApp = { id: 'finder', label: 'Finder' }
  const vscode: ProjectApp = { id: 'vscode', label: 'VS Code' }
  const zed: ProjectApp = { id: 'zed', label: 'Zed' }
  const warp: ProjectApp = { id: 'warp', label: 'Warp' }
  const term: ProjectApp = { id: 'terminal', label: 'Terminal' }

  test('defaultProjectApp uses the setting, then VS Code, then Zed, then a terminal app', () => {
    expect(defaultProjectApp([finder, zed], 'vscode')).toBe('zed')
    expect(defaultProjectApp([finder, vscode, zed], 'zed')).toBe('zed')
    expect(defaultProjectApp([finder, vscode, zed], null)).toBe('vscode')
    expect(defaultProjectApp([finder, zed, term], null)).toBe('zed')
    expect(defaultProjectApp([finder, term, warp], null)).toBe('terminal')
    expect(defaultProjectApp([finder, warp, term], 'vscode')).toBe('warp')
    expect(defaultProjectApp([finder, vscode], 'warp')).toBe('vscode')
  })

  test('defaultProjectApp never returns Finder', () => {
    expect(defaultProjectApp([finder], null)).toBeNull()
    expect(defaultProjectApp([finder, zed], 'finder')).toBe('zed')
    expect(defaultProjectApp([finder, vscode, zed], 'finder')).toBe('vscode')
    expect(defaultProjectApp([zed], null)).toBe('zed')
    expect(defaultProjectApp([], 'zed')).toBeNull()
  })

  test('the Settings select has no Finder choice and shows a saved Finder as Automatic', () => {
    expect(projectAppChoices([finder, vscode, zed]).map(a => a.id)).toEqual(['vscode', 'zed'])
    expect(shownProjectApp('finder')).toBeNull()
    expect(shownProjectApp('zed')).toBe('zed')
    expect(shownProjectApp(null)).toBeNull()
  })

  test('a saved projectApp finder still loads', () => {
    expect(parseSettings({ projectApp: 'finder', version: 1 }).projectApp).toBe('finder')
  })

  test('TERMINAL_APP_IDS equals TERMINAL_ORDER', () => {
    expect([...TERMINAL_APP_IDS]).toEqual(TERMINAL_ORDER)
  })
})

describe('the choices of the two step selects (final review Minor 5)', () => {
  test('Panel transparency offers 0 to 50 in steps of 5, and each choice saves', () => {
    expect(PANEL_TRANSPARENCY_CHOICES).toEqual([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
    for (const value of PANEL_TRANSPARENCY_CHOICES) {
      expect(reasonOf(defaults(), { panelTransparency: value })).toBe('ok')
    }
  })

  test('Interface scale offers 80 to 150 in steps of 10, and each choice saves', () => {
    expect(INTERFACE_SCALE_CHOICES).toEqual([80, 90, 100, 110, 120, 130, 140, 150])
    for (const value of INTERFACE_SCALE_CHOICES) {
      expect(reasonOf(defaults(), { interfaceScale: value })).toBe('ok')
    }
  })
})
