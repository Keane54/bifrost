// The settings of spec 12. The main process keeps them in settings.json in userData (D1).
// This module imports no library, so the main process and the renderer use it.
import {
  type CustomKeys,
  canonicalBinding,
  checkBinding,
  effectiveKeys,
  keyConflicts,
  parseCustomKeys,
  slotById,
} from './keys'
import { isPlainObject } from './plain-object'
import type { ProjectApp, ProjectAppId } from './types'

// The plain or the space labels of menus, buttons, tooltips and dialogs (spec 9.1).
export type LabelSet = 'plain' | 'space'

// The terminal apps, in the order of the default rule. TERMINAL_ORDER has the same order.
export const TERMINAL_APP_IDS = ['warp', 'ghostty', 'iterm2', 'terminal'] as const
export type TerminalAppId = (typeof TERMINAL_APP_IDS)[number]

export interface TerminalFont {
  family: string
  size: number
}

export interface Settings {
  version: 1
  labels: LabelSet
  // null means the first installed app of TERMINAL_APP_IDS (D14).
  terminalApp: TerminalAppId | null
  // null means VS Code, else Zed, else the first terminal app. finder is still a valid saved
  // value, so an old file loads. It acts as null.
  projectApp: ProjectAppId | null
  // 0 stops the escalation.
  escalationMinutes: number
  rowFlash: boolean
  notifications: boolean
  redBoxSound: boolean
  startAtLogin: boolean
  pollSeconds: number
  snapDistance: number
  // The percent of the panel background that is transparent. 0 is solid.
  panelTransparency: number
  // The zoom of the page in percent.
  interfaceScale: number
  slashCommands: string[]
  terminalFont: TerminalFont
  // Only the changed key slots (D3).
  keys: CustomKeys
  setupDone: boolean
}

export type SettingsPatch = Partial<Omit<Settings, 'version'>>
type SettingKey = keyof SettingsPatch

export const POLL_CHOICES: readonly number[] = [1, 2, 3, 5, 10]
export const MAX_ESCALATION_MINUTES = 120
export const MAX_SNAP = 32
export const PANEL_TRANSPARENCY_MAX = 50
export const PANEL_TRANSPARENCY_STEP = 5
export const INTERFACE_SCALE_MIN = 80
export const INTERFACE_SCALE_MAX = 150
export const INTERFACE_SCALE_STEP = 10
// The values from min to max in steps of step.
function stepValues(min: number, max: number, step: number): readonly number[] {
  return Array.from({ length: Math.floor((max - min) / step) + 1 }, (_, i) => min + i * step)
}
// The choices of the Panel transparency and Interface scale selects (final review Minor 5).
export const PANEL_TRANSPARENCY_CHOICES = stepValues(
  0,
  PANEL_TRANSPARENCY_MAX,
  PANEL_TRANSPARENCY_STEP,
)
export const INTERFACE_SCALE_CHOICES = stepValues(
  INTERFACE_SCALE_MIN,
  INTERFACE_SCALE_MAX,
  INTERFACE_SCALE_STEP,
)
export const FONT_SIZE_MIN = 9
export const FONT_SIZE_MAX = 24
export const MAX_SLASH_COMMANDS = 12
export const MAX_SLASH_LENGTH = 200
export const MAX_FONT_FAMILY = 64

// The defaults of spec 12.
export const DEFAULT_SETTINGS: Readonly<Settings> = {
  escalationMinutes: 10,
  interfaceScale: 100,
  keys: {},
  labels: 'plain',
  notifications: true,
  panelTransparency: 15,
  pollSeconds: 2,
  projectApp: null,
  redBoxSound: true,
  rowFlash: true,
  setupDone: false,
  slashCommands: ['/compact', '/clear', '/context'],
  snapDistance: 8,
  startAtLogin: false,
  terminalApp: null,
  terminalFont: { family: 'SF Mono', size: 13 },
  version: 1,
}

export const REASON_SLASH_START = 'Start the command with "/", with no space after it.'
export const REASON_SLASH_LINE = 'Keep the command on one line.'
export const REASON_SLASH_LONG = `That's too long. The limit is ${MAX_SLASH_LENGTH} characters.`
export const REASON_FONT = `Use 1 to ${MAX_FONT_FAMILY} characters, without quotes or ; { } < >.`

const REFUSED_SETTINGS = 'refused: bad settings'
const REFUSED_SLASH = 'refused: bad slashCommands'
const REFUSED_KEYS = 'refused: bad keys'
const REFUSED_KEY_CONFLICT = 'refused: two keys have the same binding'

type Check = (value: unknown) => boolean

const isBoolean: Check = value => typeof value === 'boolean'

// A whole number from min to max. With a step, the value is min plus a multiple of the step.
function onStep(min: number, max: number, step = 1): Check {
  return value =>
    typeof value === 'number' &&
    Number.isInteger(value) &&
    value >= min &&
    value <= max &&
    (value - min) % step === 0
}

function oneOf(list: readonly unknown[]): Check {
  return value => list.includes(value)
}

function nullOr(check: Check): Check {
  return value => value === null || check(value)
}

// All project app IDs. The type makes sure that the list is complete.
const PROJECT_APP_IDS: Readonly<Record<ProjectAppId, true>> = {
  finder: true,
  ghostty: true,
  iterm2: true,
  terminal: true,
  vscode: true,
  warp: true,
  zed: true,
}

const isProjectAppId: Check = value =>
  typeof value === 'string' && Object.hasOwn(PROJECT_APP_IDS, value)

const isFontSize = onStep(FONT_SIZE_MIN, FONT_SIZE_MAX)

// The settings with one value and one check.
type SimpleKey = Exclude<SettingKey, 'keys' | 'slashCommands' | 'terminalFont'>

const SIMPLE_CHECKS: Readonly<Record<SimpleKey, Check>> = {
  escalationMinutes: onStep(0, MAX_ESCALATION_MINUTES),
  interfaceScale: onStep(INTERFACE_SCALE_MIN, INTERFACE_SCALE_MAX, INTERFACE_SCALE_STEP),
  labels: oneOf(['plain', 'space']),
  notifications: isBoolean,
  panelTransparency: onStep(0, PANEL_TRANSPARENCY_MAX, PANEL_TRANSPARENCY_STEP),
  pollSeconds: oneOf(POLL_CHOICES),
  projectApp: nullOr(isProjectAppId),
  redBoxSound: isBoolean,
  rowFlash: isBoolean,
  setupDone: isBoolean,
  snapDistance: onStep(0, MAX_SNAP),
  startAtLogin: isBoolean,
  terminalApp: nullOr(oneOf(TERMINAL_APP_IDS)),
}

const SIMPLE_KEYS = Object.keys(SIMPLE_CHECKS) as SimpleKey[]

// The keys that a patch can have: all keys of Settings except version.
const PATCH_KEYS: ReadonlySet<string> = new Set(
  Object.keys(DEFAULT_SETTINGS).filter(key => key !== 'version'),
)

// Return true when the text is the name of a setting that a patch can change.
export function isSettingKey(key: string): boolean {
  return PATCH_KEYS.has(key)
}

// Check a slash command. The result has the trimmed text, or the reason for the user.
export function checkSlashCommand(
  text: string,
): { ok: true; text: string } | { ok: false; reason: string } {
  const command = typeof text === 'string' ? text.trim() : ''
  if (!/^\/\S/.test(command)) return { ok: false, reason: REASON_SLASH_START }
  if (/[\r\n]/.test(command)) return { ok: false, reason: REASON_SLASH_LINE }
  if (command.length > MAX_SLASH_LENGTH) return { ok: false, reason: REASON_SLASH_LONG }
  return { ok: true, text: command }
}

// Return true when the text has a control character (C0, DEL or C1).
function hasControl(text: string): boolean {
  for (const char of text) {
    const code = char.codePointAt(0) ?? 0
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) return true
  }
  return false
}

// These characters could end the CSS font name, so the family cannot have them.
const FONT_FORBIDDEN = /["'\\;{}<>]/

// Check the family of the terminal font. The result has the trimmed family, or the reason.
export function checkFontFamily(
  text: string,
): { ok: true; family: string } | { ok: false; reason: string } {
  const family = typeof text === 'string' ? text.trim() : ''
  const bad =
    family.length === 0 ||
    family.length > MAX_FONT_FAMILY ||
    FONT_FORBIDDEN.test(family) ||
    hasControl(family)
  return bad ? { ok: false, reason: REASON_FONT } : { family, ok: true }
}

// Return a new copy of the defaults. A change to the copy does not change DEFAULT_SETTINGS.
function defaultSettings(): Settings {
  return {
    ...DEFAULT_SETTINGS,
    keys: {},
    slashCommands: [...DEFAULT_SETTINGS.slashCommands],
    terminalFont: { ...DEFAULT_SETTINGS.terminalFont },
  }
}

// Return the value of an own property, or undefined.
function own(data: Record<string, unknown>, key: string): unknown {
  return Object.hasOwn(data, key) ? data[key] : undefined
}

// Keep the good commands of a stored list, each one time, and only the first 12.
// Return null when the value is not an array.
function parseSlashCommands(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null
  const list: string[] = []
  for (const item of value) {
    if (list.length >= MAX_SLASH_COMMANDS) break
    if (typeof item !== 'string') continue
    const check = checkSlashCommand(item)
    if (check.ok && !list.includes(check.text)) list.push(check.text)
  }
  return list
}

// Read the stored terminal font. Each part that is bad gets its default alone.
function parseFont(value: unknown): TerminalFont {
  const font = { ...DEFAULT_SETTINGS.terminalFont }
  if (!isPlainObject(value)) return font
  const family = own(value, 'family')
  const check = typeof family === 'string' ? checkFontFamily(family) : null
  if (check?.ok) font.family = check.family
  const size = own(value, 'size')
  if (isFontSize(size)) font.size = size as number
  return font
}

// Read the settings from stored data. A bad field gets its default. The other fields stay.
// Data that is not a plain object, or a version that is not 1, gives the defaults.
export function parseSettings(data: unknown): Settings {
  const settings = defaultSettings()
  if (!isPlainObject(data) || own(data, 'version') !== 1) return settings
  const target = settings as unknown as Record<string, unknown>
  for (const key of SIMPLE_KEYS) {
    const value = own(data, key)
    if (SIMPLE_CHECKS[key](value)) target[key] = value
  }
  settings.slashCommands = parseSlashCommands(own(data, 'slashCommands')) ?? settings.slashCommands
  settings.terminalFont = parseFont(own(data, 'terminalFont'))
  settings.keys = parseCustomKeys(own(data, 'keys'))
  return settings
}

type FieldResult = { ok: true; value: unknown } | { ok: false; reason: string }

function refuse(reason: string): { ok: false; reason: string } {
  return { ok: false, reason }
}

// A patch gives the full list. A bad command gives its reason for the user.
function checkSlashList(value: unknown): FieldResult {
  if (!Array.isArray(value) || value.length > MAX_SLASH_COMMANDS) return refuse(REFUSED_SLASH)
  const list: string[] = []
  for (const item of value) {
    if (typeof item !== 'string') return refuse(REFUSED_SLASH)
    const check = checkSlashCommand(item)
    if (!check.ok) return refuse(check.reason)
    if (list.includes(check.text)) return refuse(REFUSED_SLASH)
    list.push(check.text)
  }
  return { ok: true, value: list }
}

// A patch gives the family and the size, and nothing more. Return null for a bad font.
function checkFont(value: unknown): FieldResult | null {
  if (!isPlainObject(value) || Object.keys(value).length !== 2) return null
  const family = own(value, 'family')
  const check = typeof family === 'string' ? checkFontFamily(family) : null
  const size = own(value, 'size')
  if (!check?.ok || !isFontSize(size)) return null
  return { ok: true, value: { family: check.family, size } }
}

// Each conflict of the keys as one text: the two slot IDs and the binding that they share.
function conflictsOf(custom: CustomKeys): string[] {
  const keys = effectiveKeys(custom)
  return keyConflicts(keys).map(([a, b]) => `${a} ${b} ${canonicalBinding(keys[a] ?? '')}`)
}

// A patch gives the full set of changed slots. Each slot must exist, and each binding must have
// a good form. A conflict that the current keys have can stay (ruling C7). A new conflict
// refuses the patch.
function checkKeys(value: unknown, current: CustomKeys): FieldResult {
  if (!isPlainObject(value)) return refuse(REFUSED_KEYS)
  const keys: CustomKeys = {}
  for (const [slotId, binding] of Object.entries(value)) {
    if (!slotById(slotId)) return refuse(REFUSED_KEYS)
    if (binding === null) {
      keys[slotId] = null
      continue
    }
    // An empty key map checks only the form of the binding. The conflict check comes after.
    const check = typeof binding === 'string' ? checkBinding(slotId, binding, {}) : null
    if (!check?.ok) return refuse(REFUSED_KEYS)
    keys[slotId] = check.binding
  }
  const before = new Set(conflictsOf(current))
  if (conflictsOf(keys).some(conflict => !before.has(conflict))) {
    return refuse(REFUSED_KEY_CONFLICT)
  }
  return { ok: true, value: keys }
}

function checkField(key: SettingKey, value: unknown, current: Settings): FieldResult {
  if (key === 'slashCommands') return checkSlashList(value)
  if (key === 'terminalFont') return checkFont(value) ?? refuse(`refused: bad ${key}`)
  if (key === 'keys') return checkKeys(value, current.keys)
  return SIMPLE_CHECKS[key](value) ? { ok: true, value } : refuse(`refused: bad ${key}`)
}

// Compare two values of JSON data. The order of object keys does not count.
function sameValue(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((item, index) => sameValue(item, b[index]))
  }
  if (isPlainObject(a) && isPlainObject(b)) {
    const keys = Object.keys(a)
    if (keys.length !== Object.keys(b).length) return false
    return keys.every(key => Object.hasOwn(b, key) && sameValue(a[key], b[key]))
  }
  return false
}

// Apply a patch from the renderer. The check is strict: the first failure refuses the full
// patch. A patch that changes no value gives the same object.
export function applyPatch(
  current: Settings,
  patch: unknown,
): { ok: true; settings: Settings } | { ok: false; reason: string } {
  if (!isPlainObject(patch)) return refuse(REFUSED_SETTINGS)
  const changes: Record<string, unknown> = {}
  for (const key of Object.keys(patch)) {
    if (!PATCH_KEYS.has(key)) return refuse(`refused: unknown setting ${key}`)
    const settingKey = key as SettingKey
    const field = checkField(settingKey, patch[key], current)
    if (!field.ok) return field
    if (!sameValue(field.value, current[settingKey])) changes[key] = field.value
  }
  if (Object.keys(changes).length === 0) return { ok: true, settings: current }
  return { ok: true, settings: { ...current, ...changes } as Settings }
}

// The CSS font-family value of the terminal font, with the fallbacks.
export function cssFontFamily(font: TerminalFont): string {
  return `"${font.family}", ui-monospace, Menlo, monospace`
}

// The default app for "Open project" never is Finder. The order is: the setting when it is
// installed (and not Finder), then VS Code, then Zed, then the first terminal app of the list.
export function defaultProjectApp(
  apps: ProjectApp[],
  setting: ProjectAppId | null,
): ProjectAppId | null {
  for (const id of [setting, 'vscode', 'zed'] as const) {
    if (id !== null && id !== 'finder' && apps.some(app => app.id === id)) return id
  }
  const terminal = apps.find(app => (TERMINAL_APP_IDS as readonly string[]).includes(app.id))
  return terminal ? terminal.id : null
}

// The apps that the Settings select lists for the default. Finder is not a choice.
export function projectAppChoices(apps: ProjectApp[]): ProjectApp[] {
  return apps.filter(app => app.id !== 'finder')
}

// The value that the Settings select shows. A saved Finder acts as Automatic.
export function shownProjectApp(setting: ProjectAppId | null): ProjectAppId | null {
  return setting === 'finder' ? null : setting
}
