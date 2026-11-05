// Which chat windows are open, visible and focused. Also the WebGL plan and the attach target.
import type { SessionRow } from '../../../shared/types'
import {
  REASON_EXTERNAL,
  REASON_GONE,
  REASON_PARKED,
  REASON_WAIT_ID,
  REASON_WAIT_LIST,
} from '../actions/reasons'
import { type Frame, topFrame, type WmState } from '../wm/state'

const PREFIX = 'chat:'

export function chatPanelId(sessionId: string): string {
  return `${PREFIX}${sessionId}`
}

export function chatSessionId(panelId: string): string | null {
  return panelId.startsWith(PREFIX) && panelId.length > PREFIX.length
    ? panelId.slice(PREFIX.length)
    : null
}

// The session IDs of all chat panels, also in back tabs and in minimised frames.
export function openChatIds(frames: Frame[]): string[] {
  const ids: string[] = []
  for (const frame of frames) {
    for (const panel of frame.panels) {
      const id = chatSessionId(panel)
      if (id !== null && !ids.includes(id)) ids.push(id)
    }
  }
  return ids
}

export interface ChatView {
  visible: boolean
  focused: boolean
}

export function chatViews(state: Pick<WmState, 'frames'>): Map<string, ChatView> {
  const top = topFrame(state)
  const views = new Map<string, ChatView>()
  for (const frame of state.frames) {
    for (const panel of frame.panels) {
      const id = chatSessionId(panel)
      if (id === null) continue
      const visible = !frame.minimised && frame.active === panel
      views.set(id, { focused: visible && frame === top, visible })
    }
  }
  return views
}

export const MAX_WEBGL = 12

// The focused window gets WebGL first. When the limit cuts, it takes the place of
// the last window that would load, or else of the last loaded window.
export function webglPlan(
  visible: string[],
  loaded: string[],
  max = MAX_WEBGL,
  focused: string | null = null,
): { load: string[]; release: string[] } {
  const release = loaded.filter(id => !visible.includes(id))
  const kept = loaded.filter(id => visible.includes(id))
  const load: string[] = []
  for (const id of visible) {
    if (kept.length + load.length >= max) break
    if (!loaded.includes(id) && !load.includes(id)) load.push(id)
  }
  if (focused !== null && visible.includes(focused) && !loaded.includes(focused)) {
    if (!load.includes(focused) && kept.length + load.length >= max) {
      if (load.length > 0) {
        load.pop()
      } else {
        const out = [...kept].reverse().find(id => id !== focused)
        if (out !== undefined) release.push(out)
      }
      load.unshift(focused)
    }
  }
  return { load, release }
}

export type AttachTarget =
  | { ok: true; shortId: string; cwd: string }
  | { ok: false; reason: string }

export function attachTarget(row: SessionRow | undefined, loaded: boolean): AttachTarget {
  if (!loaded) return { ok: false, reason: REASON_WAIT_LIST }
  if (!row) return { ok: false, reason: REASON_GONE }
  if (row.kind === 'external') return { ok: false, reason: REASON_EXTERNAL }
  if (row.state === 'parked') return { ok: false, reason: REASON_PARKED }
  if (!row.shortId) return { ok: false, reason: REASON_WAIT_ID }
  return { cwd: row.cwd || '/', ok: true, shortId: row.shortId }
}
