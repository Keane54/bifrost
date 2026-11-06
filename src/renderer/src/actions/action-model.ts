// The action model: which action is enabled for which row, and why not.

import { promptBlocks } from '../../../shared/input'
import { PRIORITIES } from '../../../shared/priority'
import type { LabelSet } from '../../../shared/settings'
import { TERMINAL_ORDER } from '../../../shared/terminal-order'
import type {
  Priority,
  ProjectApp,
  ProjectAppId,
  SessionRow,
  WatchColour,
} from '../../../shared/types'
import { WATCH_COLOURS } from '../../../shared/watch'
import {
  REASON_EXTERNAL,
  REASON_GONE,
  REASON_NO_APPS,
  REASON_NO_CWD,
  REASON_NO_PID,
  REASON_NO_PROCESS,
  REASON_NO_TERMINAL,
  REASON_NO_WINDOW,
  REASON_NOT_WATCHED,
  REASON_NOTHING_TO_RESUME,
  REASON_ONLY_EXTERNAL,
  REASON_ONLY_PARKED,
  REASON_PARKED,
  REASON_RED_BOX,
  REASON_RESUME_ALL_RUNS,
  REASON_RUNNING,
  REASON_TAKE_BUSY,
  REASON_TAKE_PROMPT,
  REASON_TERMINAL_UNKNOWN,
  REASON_WAIT_ID,
  REASON_WATCHED,
} from './reasons'

export type ActionId =
  | 'new-session'
  | 'open'
  | 'send-message'
  | 'run-slash'
  | 'interrupt'
  | 'rename'
  | 'set-priority'
  | 'resume'
  | 'resume-all'
  | 'show-info'
  | 'copy-id'
  | 'open-project'
  | 'open-in-terminal'
  | 'take-control'
  | 'close-window'
  | 'stop'
  | 'delete'
  | 'watch-add'
  | 'watch-colour'
  | 'watch-remove'

export type RowClass = 'owned' | 'external' | 'parked'

// A parked row is its own class. Any other row has the class of its kind.
export function rowClass(row: SessionRow): RowClass {
  return row.state === 'parked' ? 'parked' : row.kind
}

// The settings module owns the type. Other renderer modules import it from here.
export type { LabelSet }

export interface ActionDef {
  id: ActionId
  plain: string
  space: string
  for: RowClass[] | 'all'
}

const def = (
  id: ActionId,
  plain: string,
  space: string,
  forClasses: RowClass[] | 'all',
): ActionDef => ({ for: forClasses, id, plain, space })

export const ACTIONS: Record<ActionId, ActionDef> = {
  'close-window': def('close-window', 'Close window', 'Disengage', 'all'),
  'copy-id': def('copy-id', 'Copy session ID', 'Copy transponder ID', 'all'),
  delete: def('delete', 'Delete session', 'Self-destruct', ['owned', 'parked']),
  interrupt: def('interrupt', 'Interrupt', 'Full stop', ['owned']),
  'new-session': def('new-session', 'New session', 'Launch', 'all'),
  open: def('open', 'Open', 'Warp to', ['owned']),
  'open-in-terminal': def('open-in-terminal', 'Open in terminal', 'Jump to terminal', [
    'owned',
    'external',
  ]),
  'open-project': def('open-project', 'Open project', 'Open cargo hold', 'all'),
  rename: def('rename', 'Rename', 'Set callsign', 'all'),
  resume: def('resume', 'Resume', 'Reactivate', ['parked']),
  'resume-all': def('resume-all', 'Resume all', 'Reactivate all', 'all'),
  'run-slash': def('run-slash', 'Run slash command', 'Activate module', ['owned']),
  'send-message': def('send-message', 'Send message', 'Hail', ['owned']),
  'set-priority': def('set-priority', 'Set priority', 'Set threat level', 'all'),
  'show-info': def('show-info', 'Show Info', 'Scan', 'all'),
  stop: def('stop', 'Stop session', 'Power down', ['owned']),
  'take-control': def('take-control', 'Take control', 'Commandeer', ['external']),
  'watch-add': def('watch-add', 'Add to watchlist', 'Track', 'all'),
  'watch-colour': def('watch-colour', 'Change colour', 'Change colour', 'all'),
  'watch-remove': def('watch-remove', 'Remove from watchlist', 'Stop tracking', 'all'),
}

export interface ActionContext {
  chatOpen: boolean
  apps: ProjectApp[]
  labels: LabelSet
  // True while another action runs on the session.
  running: boolean
  slashFavourites: string[]
  slashRecent: string[]
}

export interface ActionState {
  enabled: boolean
  reason: string | null
}

const off = (reason: string): ActionState => ({ enabled: false, reason })

const RUNNING_BLOCKED: ReadonlySet<ActionId> = new Set(['stop', 'delete', 'resume', 'take-control'])
const RED_BOX_BLOCKED: ReadonlySet<ActionId> = new Set(['send-message', 'run-slash'])
const NEEDS_SHORT_ID: ReadonlySet<ActionId> = new Set([
  'send-message',
  'run-slash',
  'interrupt',
  'stop',
])

// Check the rules in order. The first rule that matches gives the reason.
export function actionStateFor(
  id: ActionId,
  row: SessionRow | undefined,
  ctx: ActionContext,
): ActionState {
  if (!row) return off(REASON_GONE)
  const def = ACTIONS[id]
  const cls = rowClass(row)
  if (id === 'watch-add' && row.watch) return off(REASON_WATCHED)
  if ((id === 'watch-colour' || id === 'watch-remove') && !row.watch) return off(REASON_NOT_WATCHED)
  if (id === 'stop' && cls === 'parked') return off(REASON_NO_PROCESS)
  if (def.for !== 'all' && !def.for.includes(cls)) {
    if (def.for.length === 1 && def.for[0] === 'external') return off(REASON_ONLY_EXTERNAL)
    if (def.for.length === 1 && def.for[0] === 'parked') return off(REASON_ONLY_PARKED)
    return off(cls === 'external' ? REASON_EXTERNAL : REASON_PARKED)
  }
  if (id === 'close-window' && !ctx.chatOpen) return off(REASON_NO_WINDOW)
  if (id === 'open-project') {
    if (!row.cwd.startsWith('/')) return off(REASON_NO_CWD)
    if (ctx.apps.length === 0) return off(REASON_NO_APPS)
  }
  if (RUNNING_BLOCKED.has(id) && ctx.running) return off(REASON_RUNNING)
  // The main process uses the same rule (spec 8.4). Take control keeps its own rule below.
  if (RED_BOX_BLOCKED.has(id) && promptBlocks(row)) return off(REASON_RED_BOX)
  if (NEEDS_SHORT_ID.has(id) && !row.shortId) return off(REASON_WAIT_ID)
  if (id === 'open-in-terminal' && cls === 'owned' && !row.shortId) return off(REASON_WAIT_ID)
  if (id === 'take-control') {
    if (row.state === 'working') return off(REASON_TAKE_BUSY)
    if (row.box === 'red') return off(REASON_TAKE_PROMPT)
    if (row.pid === undefined) return off(REASON_NO_PID)
    if (!row.cwd.startsWith('/')) return off(REASON_NO_CWD)
  }
  if (id === 'resume' && !row.cwd.startsWith('/')) return off(REASON_NO_CWD)
  if (id === 'open-in-terminal') {
    if (cls === 'owned' && !ctx.apps.some(app => TERMINAL_ORDER.includes(app.id))) {
      return off(REASON_NO_TERMINAL)
    }
    if (cls === 'external' && !row.terminalApp) return off(REASON_TERMINAL_UNKNOWN)
  }
  return { enabled: true, reason: null }
}

// Actions that ask for more input show three full stops after the label.
const ELLIPSIS_ACTIONS: ReadonlySet<ActionId> = new Set([
  'send-message',
  'rename',
  'stop',
  'delete',
])

export function actionLabel(id: ActionId, labels: LabelSet): string {
  const text = ACTIONS[id][labels]
  return ELLIPSIS_ACTIONS.has(id) ? `${text}...` : text
}

// The tooltip of a button or a menu entry. It has no three full stops.
// A disabled action also gives the reason on a second line.
export function buttonTip(id: ActionId, state: ActionState, labels: LabelSet): string {
  const label = ACTIONS[id][labels]
  return state.enabled || state.reason === null ? label : `${label}\n${state.reason}`
}

// A slash command is a string that starts with "/". The string "/" means "Other...".
export type MenuArg = Priority | null | ProjectAppId | WatchColour | `/${string}`

export interface SubItem {
  key: string
  label: string
  arg: MenuArg
  checked?: boolean
  separatorBefore?: boolean
}

export type MenuEntry =
  | { type: 'item'; action: ActionId; label: string; state: ActionState }
  | { type: 'submenu'; action: ActionId; label: string; state: ActionState; items: SubItem[] }
  | { type: 'separator' }

// The actions of the Selected Item panel (spec 8.4 item 2).
export const SELECTED_ITEM_ACTIONS: ActionId[] = [
  'open',
  'send-message',
  'run-slash',
  'interrupt',
  'show-info',
  'open-in-terminal',
  'stop',
]

// The number of recent slash commands in the submenu.
export const SLASH_MENU_RECENT = 5

// The key of the checked item of a submenu, or undefined. Set priority and the colour items
// of the watchlist use it for their check mark.
export function checkedKey(items: readonly SubItem[]): string | undefined {
  return items.find(item => item.checked)?.key
}

// The label of a colour in the colour menu: "dark-red" gives "Dark red".
function colourLabel(colour: WatchColour): string {
  const words = colour.replace('-', ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}

function subItems(id: ActionId, row: SessionRow, ctx: ActionContext): SubItem[] {
  if (id === 'set-priority') {
    return [
      ...PRIORITIES.map(p => ({
        arg: p as MenuArg,
        checked: row.priority === p,
        key: String(p),
        label: String(p),
      })),
      { arg: null, checked: row.priority === undefined, key: 'none', label: 'None' },
    ]
  }
  if (id === 'watch-add' || id === 'watch-colour') {
    return WATCH_COLOURS.map(colour => ({
      arg: colour as MenuArg,
      checked: row.watch?.colour === colour,
      key: colour,
      label: colourLabel(colour),
    }))
  }
  if (id === 'open-project') {
    return ctx.apps.map(app => ({ arg: app.id, key: app.id, label: app.label }))
  }
  if (id === 'run-slash') {
    const favourites = ctx.slashFavourites
    const recent = ctx.slashRecent.filter(c => !favourites.includes(c)).slice(0, SLASH_MENU_RECENT)
    return [
      ...favourites.map(c => ({ arg: c as MenuArg, key: `fav:${c}`, label: c })),
      ...recent.map((c, i) => ({
        arg: c as MenuArg,
        key: `recent:${c}`,
        label: c,
        ...(i === 0 ? { separatorBefore: true } : {}),
      })),
      { arg: '/', key: 'other', label: 'Other...', separatorBefore: true },
    ]
  }
  return []
}

const SUBMENU_ACTIONS: ReadonlySet<ActionId> = new Set([
  'run-slash',
  'set-priority',
  'open-project',
  'watch-add',
  'watch-colour',
])

// Give the right-click menu of spec 9.5 in order.
export function rowMenu(row: SessionRow, ctx: ActionContext): MenuEntry[] {
  const entry = (id: ActionId): MenuEntry => {
    const base = {
      action: id,
      label: actionLabel(id, ctx.labels),
      state: actionStateFor(id, row, ctx),
    }
    return SUBMENU_ACTIONS.has(id)
      ? { ...base, items: subItems(id, row, ctx), type: 'submenu' }
      : { ...base, type: 'item' }
  }
  const sep: MenuEntry = { type: 'separator' }
  const cls = rowClass(row)
  return [
    entry('open'),
    entry('send-message'),
    entry('run-slash'),
    entry('interrupt'),
    sep,
    entry('set-priority'),
    ...(row.watch ? [entry('watch-colour'), entry('watch-remove')] : [entry('watch-add')]),
    entry('rename'),
    entry('show-info'),
    entry('copy-id'),
    entry('open-project'),
    entry('open-in-terminal'),
    sep,
    ...(cls === 'external' ? [entry('take-control')] : []),
    ...(cls === 'parked' ? [entry('resume')] : []),
    ...(ctx.chatOpen ? [entry('close-window')] : []),
    entry('stop'),
    entry('delete'),
  ]
}

export type GlobalActionId = 'new-session' | 'resume-all'

export interface GlobalContext {
  // The number of parked rows that Resume all resumes.
  resumable: number
  resumeAllRunning: boolean
  labels: LabelSet
}

// The state of an action that needs no row.
export function globalActionState(id: GlobalActionId, ctx: GlobalContext): ActionState {
  if (id === 'new-session') return { enabled: true, reason: null }
  if (ctx.resumeAllRunning) return off(REASON_RESUME_ALL_RUNS)
  if (ctx.resumable === 0) return off(REASON_NOTHING_TO_RESUME)
  return { enabled: true, reason: null }
}
