import { MODEL_VALUES, type ModelChoice } from './new-session'
import { isPlainObject } from './plain-object'

export type PermissionId =
  | 'notify'
  | 'read-sessions'
  | 'read-usage'
  | 'read-service-status'
  | 'claude-jobs'
  | 'claude-jobs-auto'
  | 'discuss'

export const PERMISSION_IDS: readonly PermissionId[] = Object.freeze([
  'notify',
  'read-sessions',
  'read-usage',
  'read-service-status',
  'claude-jobs',
  'claude-jobs-auto',
  'discuss',
])

// Phase 2 ids. The parser knows them and refuses them.
export const PHASE2_PERMISSION_IDS: readonly string[] = Object.freeze([
  'slack-read',
  'github-read',
  'mcp',
  'web-read',
  'event-log',
  'act-slack',
  'act-github',
  'background',
])

// The names of lucide icons that a panel can use.
export const MODULE_ICONS = Object.freeze([
  'activity',
  'bell',
  'book-open',
  'bot',
  'calendar',
  'chart-bar',
  'clock',
  'file-text',
  'gauge',
  'inbox',
  'layout-dashboard',
  'list-checks',
  'message-square',
  'notebook',
  'sparkles',
  'star',
  'terminal',
  'timer',
  'wrench',
  'zap',
] as const)

export type ModuleIcon = (typeof MODULE_ICONS)[number]

export interface ModulePermission {
  id: PermissionId
  reason: string
}

export interface ModulePanel {
  id: string
  title: string
  icon: ModuleIcon
  entry: string
}

export interface ModuleManifest {
  id: string
  name: string
  version: string
  description: string
  minBifrost: string
  panels: ModulePanel[]
  permissions: ModulePermission[]
  suggests: { model: ModelChoice | null; dailyCap: number | null }
}

export type ManifestResult = { ok: true; manifest: ModuleManifest } | { ok: false; reason: string }

const NEWER_VERSION = 'This module needs a newer version of Bifrost.'
const HIDDEN_TEXT = 'A text in the manifest has hidden or control characters.'
// The characters that a manifest text must not hold: controls (Cc, also new lines and tabs),
// format characters (Cf: zero-width and bidi controls, marks, the byte order mark, tags), the
// whole tag block and the line and paragraph separators. Bifrost shows these texts in its own
// windows, and such a character could hide or change the text that the user reads. The
// combining grapheme joiner and the Hangul fillers also show as nothing, so a name with only
// them looks empty at the approval. The variation selectors stay allowed for emoji.
// U+034F is a combining character, so it is an alternative outside the class.
const HIDDEN_CHARACTER =
  /[\p{Cc}\p{Cf}\u115F\u1160\u2028\u2029\u3164\uFFA0\u{E0000}-\u{E007F}]|\u034F/u
// The id of a module. The module protocol uses it as the host.
export const MODULE_ID_PATTERN = /^[a-z][a-z0-9-]{1,39}$/
const PANEL_ID_PATTERN = /^[a-z][a-z0-9-]{0,29}$/
const VERSION_PATTERN = /^\d{1,6}\.\d{1,6}\.\d{1,6}$/
const MAX_PANELS = 8
const MAX_NAME = 40
const MAX_DESCRIPTION = 200
const MAX_REASON = 200
const MAX_TITLE = 40

function fail(reason: string): { ok: false; reason: string } {
  return { ok: false, reason }
}

function onlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every(key => keys.includes(key))
}

function isText(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= max
}

// The parser checks this before the length of a text, so such a text gets the hidden reason.
function hasHidden(value: unknown): boolean {
  return typeof value === 'string' && HIDDEN_CHARACTER.test(value)
}

// A panel entry is a relative path under panels/ that ends in .html.
// No segment is empty or starts with a dot.
export function isPanelEntry(entry: string): boolean {
  if (!entry.startsWith('panels/') || !entry.endsWith('.html')) return false
  if (entry.includes('\\') || entry.includes('\0')) return false
  const segments = entry.split('/')
  if (segments.some(s => s === '' || s.startsWith('.'))) return false
  return segments[segments.length - 1] !== '.html'
}

function parsePanel(value: unknown): ModulePanel | string {
  if (!isPlainObject(value)) return 'A panel must be an object.'
  if (!onlyKeys(value, ['id', 'title', 'icon', 'entry'])) return 'A panel has an unknown key.'
  const { entry, icon, id, title } = value
  if (typeof id !== 'string' || !PANEL_ID_PATTERN.test(id)) return 'A panel id is not valid.'
  if (hasHidden(title)) return HIDDEN_TEXT
  if (!isText(title, MAX_TITLE)) return 'A panel title is not valid.'
  if (typeof icon !== 'string' || !(MODULE_ICONS as readonly string[]).includes(icon)) {
    return 'A panel icon is not known.'
  }
  if (typeof entry !== 'string' || !isPanelEntry(entry)) return 'A panel entry is not valid.'
  return { entry, icon: icon as ModuleIcon, id, title }
}

function parsePermission(value: unknown): ModulePermission | string {
  if (!isPlainObject(value)) return 'A permission must be an object.'
  if (!onlyKeys(value, ['id', 'reason'])) return 'A permission has an unknown key.'
  const { id, reason } = value
  if (typeof id !== 'string') return 'A permission id is not valid.'
  if (PHASE2_PERMISSION_IDS.includes(id)) return NEWER_VERSION
  if (!(PERMISSION_IDS as readonly string[]).includes(id)) return 'A permission id is not known.'
  if (hasHidden(reason)) return HIDDEN_TEXT
  if (!isText(reason, MAX_REASON)) return 'A permission needs a reason of 1 to 200 characters.'
  return { id: id as PermissionId, reason }
}

function parseSuggests(value: unknown): ModuleManifest['suggests'] | string {
  if (value === undefined) return { dailyCap: null, model: null }
  if (!isPlainObject(value)) return 'The suggests field must be an object.'
  if (!onlyKeys(value, ['model', 'dailyCap'])) return 'The suggests field has an unknown key.'
  const model = value.model ?? null
  const dailyCap = value.dailyCap ?? null
  if (
    model !== null &&
    (typeof model !== 'string' || !MODEL_VALUES.includes(model as ModelChoice))
  ) {
    return 'The suggested model is not known.'
  }
  if (dailyCap !== null) {
    if (
      typeof dailyCap !== 'number' ||
      !Number.isInteger(dailyCap) ||
      dailyCap < 1 ||
      dailyCap > 500
    ) {
      return 'The suggested daily cap must be a whole number from 1 to 500.'
    }
  }
  return { dailyCap, model: model as ModelChoice | null }
}

export function parseManifest(data: unknown): ManifestResult {
  if (!isPlainObject(data)) return fail('The manifest must be an object.')
  const keys = [
    'id',
    'name',
    'version',
    'description',
    'minBifrost',
    'panels',
    'permissions',
    'suggests',
  ]
  if (!onlyKeys(data, keys)) return fail('The manifest has an unknown key.')
  const { description, id, minBifrost, name, panels, permissions, version } = data
  if (typeof id !== 'string' || !MODULE_ID_PATTERN.test(id)) {
    return fail('The module id is not valid.')
  }
  if (hasHidden(name) || hasHidden(description)) return fail(HIDDEN_TEXT)
  if (!isText(name, MAX_NAME)) return fail('The name must have 1 to 40 characters.')
  if (typeof version !== 'string' || !VERSION_PATTERN.test(version)) {
    return fail('The version must look like 1.2.3.')
  }
  if (!isText(description, MAX_DESCRIPTION)) {
    return fail('The description must have 1 to 200 characters.')
  }
  if (typeof minBifrost !== 'string' || !VERSION_PATTERN.test(minBifrost)) {
    return fail('The minBifrost field must look like 1.2.3.')
  }
  if (!Array.isArray(panels) || panels.length < 1 || panels.length > MAX_PANELS) {
    return fail('A module needs 1 to 8 panels.')
  }
  const panelList: ModulePanel[] = []
  for (const raw of panels) {
    const panel = parsePanel(raw)
    if (typeof panel === 'string') return fail(panel)
    if (panelList.some(p => p.id === panel.id)) return fail('Two panels have the same id.')
    panelList.push(panel)
  }
  const rawPermissions = permissions === undefined ? [] : permissions
  if (!Array.isArray(rawPermissions)) return fail('The permissions field must be a list.')
  const permissionList: ModulePermission[] = []
  for (const raw of rawPermissions) {
    const permission = parsePermission(raw)
    if (typeof permission === 'string') return fail(permission)
    if (permissionList.some(p => p.id === permission.id)) {
      return fail('A permission is listed twice.')
    }
    permissionList.push(permission)
  }
  const suggests = parseSuggests(data.suggests)
  if (typeof suggests === 'string') return fail(suggests)
  return {
    manifest: {
      description,
      id,
      minBifrost,
      name,
      panels: panelList,
      permissions: permissionList,
      suggests,
      version,
    },
    ok: true,
  }
}

// Phase 1 refuses every Phase 2 id, so the tier is always standard.
export function moduleTier(m: ModuleManifest): 'standard' | 'permissive' {
  return m.permissions.some(p => PHASE2_PERMISSION_IDS.includes(p.id)) ? 'permissive' : 'standard'
}

export function permissionDiff(
  old: ModuleManifest,
  next: ModuleManifest,
): { added: ModulePermission[]; removed: PermissionId[] } {
  const before = new Set(old.permissions.map(p => p.id))
  const after = new Set(next.permissions.map(p => p.id))
  return {
    added: next.permissions.filter(p => !before.has(p.id)),
    removed: old.permissions.map(p => p.id).filter(id => !after.has(id)),
  }
}
