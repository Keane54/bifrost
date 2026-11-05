// The action model: which action is enabled for which row, and why not.

import { PRIORITIES } from '../../../shared/priority'
import type { Priority, ProjectApp, ProjectAppId, SessionRow } from '../../../shared/types'
import {
  comesIn,
  REASON_EXTERNAL,
  REASON_GONE,
  REASON_NO_APPS,
  REASON_NO_CWD,
  REASON_NO_WINDOW,
  REASON_ONLY_EXTERNAL,
  REASON_ONLY_PARKED,
  REASON_PARKED,
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

export type RowClass = 'owned' | 'external' | 'parked'

// A parked row is its own class. Any other row has the class of its kind.
export function rowClass(row: SessionRow): RowClass {
  return row.state === 'parked' ? 'parked' : row.kind
}

export type LabelSet = 'plain' | 'space'

export interface ActionDef {
  id: ActionId
  plain: string
  space: string
  // The milestone that makes the action work.
  milestone: 3 | 4 | 5
  for: RowClass[] | 'all'
}

const def = (
  id: ActionId,
  plain: string,
  space: string,
  forClasses: RowClass[] | 'all',
  milestone: 3 | 4 | 5,
): ActionDef => ({ for: forClasses, id, milestone, plain, space })

export const ACTIONS: Record<ActionId, ActionDef> = {
  'close-window': def('close-window', 'Close window', 'Disengage', 'all', 3),
  'copy-id': def('copy-id', 'Copy session ID', 'Copy transponder ID', 'all', 3),
  delete: def('delete', 'Delete session', 'Self-destruct', ['owned', 'parked'], 4),
  interrupt: def('interrupt', 'Interrupt', 'Full stop', ['owned'], 4),
  'new-session': def('new-session', 'New session', 'Launch', 'all', 4),
  open: def('open', 'Open', 'Warp to', ['owned'], 3),
  'open-in-terminal': def(
    'open-in-terminal',
    'Open in terminal',
    'Jump to terminal',
    ['owned', 'external'],
    4,
  ),
  'open-project': def('open-project', 'Open project', 'Open cargo hold', 'all', 3),
  rename: def('rename', 'Rename', 'Set callsign', ['owned'], 4),
  resume: def('resume', 'Resume', 'Reactivate', ['parked'], 4),
  'resume-all': def('resume-all', 'Resume all', 'Reactivate all', 'all', 4),
  'run-slash': def('run-slash', 'Run slash command', 'Activate module', ['owned'], 4),
  'send-message': def('send-message', 'Send message', 'Hail', ['owned'], 4),
  'set-priority': def('set-priority', 'Set priority', 'Set threat level', 'all', 3),
  'show-info': def('show-info', 'Show Info', 'Scan', 'all', 5),
  stop: def('stop', 'Stop session', 'Power down', ['owned'], 4),
  'take-control': def('take-control', 'Take control', 'Commandeer', ['external'], 4),
}

export interface ActionContext {
  chatOpen: boolean
  apps: ProjectApp[]
  labels: LabelSet
}

export interface ActionState {
  enabled: boolean
  reason: string | null
}

const off = (reason: string): ActionState => ({ enabled: false, reason })

// Check the rules in order. The first rule that matches gives the reason.
export function actionStateFor(
  id: ActionId,
  row: SessionRow | undefined,
  ctx: ActionContext,
): ActionState {
  if (!row) return off(REASON_GONE)
  const def = ACTIONS[id]
  const cls = rowClass(row)
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
  if (def.milestone === 4 || def.milestone === 5) return off(comesIn(def.milestone))
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

export type MenuArg = Priority | null | ProjectAppId

export interface SubItem {
  key: string
  label: string
  arg: MenuArg
  checked?: boolean
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
  if (id === 'open-project') {
    return ctx.apps.map(app => ({ arg: app.id, key: app.id, label: app.label }))
  }
  // The favourites of run-slash come in M4.
  return []
}

const SUBMENU_ACTIONS: ReadonlySet<ActionId> = new Set([
  'run-slash',
  'set-priority',
  'open-project',
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
