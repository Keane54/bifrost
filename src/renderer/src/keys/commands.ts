// The command of a key slot for the current state. This module is pure: it reads no DOM.
import type { FocusZone, KeySlot } from '../../../shared/keys'
import { defaultProjectApp } from '../../../shared/settings'
import type { ProjectApp, ProjectAppId, SessionRow } from '../../../shared/types'
import type { ActionId, GlobalActionId, MenuArg } from '../actions/action-model'
import { activeTab, configOf, type OverviewConfig } from '../overview/config'
import { viewRows } from '../overview/rows'
import { type Frame, panelKind, topFrame } from '../wm/state'

export type KeyIntent =
  | { kind: 'none' }
  | { kind: 'action'; action: ActionId; sessionId: string; arg?: MenuArg }
  | { kind: 'global'; action: GlobalActionId }
  | { kind: 'select'; sessionId: string | null }
  | { kind: 'overview-tab'; panelId: string; tabId: string }
  | { kind: 'activate-panel'; panelId: string }
  | { kind: 'focus-overview'; panelId: string | null }
  | { kind: 'open-panel'; panelId: string }
  | { kind: 'close-panel'; panelId: string }
  | { kind: 'load-layout'; index: number }
  | { kind: 'save-layout' }
  | { kind: 'leave-send-box' }

export interface KeyContext {
  frames: Frame[]
  overviews: Record<string, OverviewConfig>
  rows: SessionRow[]
  selectedId: string | null
  apps: ProjectApp[]
  projectApp: ProjectAppId | null
  zone: FocusZone
  // True when another handler took the Esc key, for example a popover or a drag (spec 9.4).
  escapeHandled?: boolean
  // True for a key repeat: the key is held down.
  repeat?: boolean
}

const NONE: KeyIntent = { kind: 'none' }

// The commands that act on one session.
const SESSION_COMMANDS: ReadonlySet<string> = new Set([
  'open',
  'send-message',
  'run-slash',
  'interrupt',
  'rename',
  'show-info',
  'copy-id',
  'open-in-terminal',
  'take-control',
  'resume',
  'stop',
  'delete',
  'set-priority',
  'open-project',
])

// The commands of the hold slots.
const HOLD_COMMANDS: ReadonlySet<string> = new Set([
  'open',
  'send-message',
  'show-info',
  'open-in-terminal',
  'interrupt',
  'set-priority',
])

const PANEL_COMMANDS: ReadonlySet<string> = new Set(['event-log', 'usage-hud', 'settings'])

// The active Overview of the highest frame that is not minimised and shows an Overview.
export function focusedOverview(frames: Frame[]): string | null {
  const shows = frames.filter(frame => !frame.minimised && panelKind(frame.active) === 'overview')
  return topFrame({ frames: shows })?.active ?? null
}

// Step to the next or the previous row. A step past the first or the last row gives null.
export function stepRow(view: SessionRow[], selectedId: string | null, by: -1 | 1): string | null {
  if (view.length === 0) return null
  const index = view.findIndex(row => row.sessionId === selectedId)
  if (index === -1) return (by === 1 ? view[0] : view[view.length - 1]).sessionId
  return view[index + by]?.sessionId ?? null
}

// The ID of the tab after or before the active tab. It wraps.
export function stepTab(config: OverviewConfig, by: -1 | 1): string {
  const count = config.tabs.length
  const index = config.tabs.indexOf(activeTab(config))
  return config.tabs[(index + by + count) % count].id
}

// The panel after or before the active panel of the top frame. It wraps.
export function stepStack(frames: Frame[], by: -1 | 1): string | null {
  const frame = topFrame({ frames })
  if (!frame || frame.panels.length < 2) return null
  const index = frame.panels.indexOf(frame.active)
  const count = frame.panels.length
  return frame.panels[(index + by + count) % count] ?? null
}

// Esc (spec 9.4, the user 2026-11-06). In the send box, Esc leaves the send box. Else it closes
// Settings when Settings is the active panel of the top frame. Else it opens Settings and brings it
// to the front. Esc does nothing when another handler took it, for example a popover or a drag.
// A chat window, a text field, a dialog, a menu and the key recorder keep their own Esc.
// Esc never clears the selection. A key repeat of a held Esc does not toggle Settings again.
function escapeIntent(ctx: KeyContext): KeyIntent {
  if (ctx.zone === 'send-box') return { kind: 'leave-send-box' }
  if (ctx.escapeHandled === true || ctx.repeat === true) return NONE
  if (ctx.zone !== 'other' && ctx.zone !== 'control') return NONE
  return topFrame({ frames: ctx.frames })?.active === 'settings'
    ? { kind: 'close-panel', panelId: 'settings' }
    : { kind: 'open-panel', panelId: 'settings' }
}

// The action of a session command on one session, or none.
function sessionIntent(
  slot: KeySlot,
  sessionId: string,
  ctx: Pick<KeyContext, 'apps' | 'projectApp'>,
): KeyIntent {
  const action = slot.command as ActionId
  if (slot.command === 'set-priority') {
    const arg = slot.arg === undefined || slot.arg === 0 ? null : (slot.arg as 1 | 2 | 3 | 4 | 5)
    return { action, arg, kind: 'action', sessionId }
  }
  if (slot.command === 'open-project') {
    const arg = defaultProjectApp(ctx.apps, ctx.projectApp)
    return arg === null ? NONE : { action, arg, kind: 'action', sessionId }
  }
  return { action, kind: 'action', sessionId }
}

// The rows of the active tab of the focused Overview, and the ID of that Overview.
function focusedView(
  ctx: KeyContext,
): { panelId: string; config: OverviewConfig; view: SessionRow[] } | null {
  const panelId = focusedOverview(ctx.frames)
  if (panelId === null) return null
  const config = configOf(ctx.overviews, panelId)
  return { config, panelId, view: viewRows(ctx.rows, activeTab(config)) }
}

export function planKey(slot: KeySlot, ctx: KeyContext): KeyIntent {
  const { command } = slot
  if (SESSION_COMMANDS.has(command)) {
    const { selectedId } = ctx
    if (selectedId === null || !ctx.rows.some(row => row.sessionId === selectedId)) return NONE
    return sessionIntent(slot, selectedId, ctx)
  }
  if (command === 'new-session' || command === 'resume-all') {
    return { action: command, kind: 'global' }
  }
  if (PANEL_COMMANDS.has(command)) return { kind: 'open-panel', panelId: command }
  switch (command) {
    case 'select-row': {
      const target = focusedView(ctx)?.view[(slot.arg ?? 0) - 1]
      return target ? { kind: 'select', sessionId: target.sessionId } : NONE
    }
    case 'select-prev':
    case 'select-next': {
      const focused = focusedView(ctx)
      if (!focused) return NONE
      const sessionId = stepRow(focused.view, ctx.selectedId, command === 'select-next' ? 1 : -1)
      return sessionId === null ? NONE : { kind: 'select', sessionId }
    }
    case 'focus-overview':
      return { kind: 'focus-overview', panelId: focusedOverview(ctx.frames) }
    case 'next-overview-tab':
    case 'prev-overview-tab': {
      const focused = focusedView(ctx)
      if (!focused) return NONE
      const tabId = stepTab(focused.config, command === 'next-overview-tab' ? 1 : -1)
      return { kind: 'overview-tab', panelId: focused.panelId, tabId }
    }
    case 'next-stack-tab':
    case 'prev-stack-tab': {
      const panelId = stepStack(ctx.frames, command === 'next-stack-tab' ? 1 : -1)
      return panelId === null ? NONE : { kind: 'activate-panel', panelId }
    }
    case 'load-layout':
      return slot.arg === undefined ? NONE : { index: slot.arg - 1, kind: 'load-layout' }
    case 'save-layout':
      return { kind: 'save-layout' }
    case 'escape':
      return escapeIntent(ctx)
    default:
      // close-panel and toggle-fullscreen belong to the menu (D7).
      return NONE
  }
}

// The command of a hold slot on the clicked row.
export function planHold(
  slot: KeySlot,
  sessionId: string,
  ctx: Pick<KeyContext, 'apps' | 'projectApp'>,
): KeyIntent {
  return HOLD_COMMANDS.has(slot.command) ? sessionIntent(slot, sessionId, ctx) : NONE
}
