import type { SessionRow } from '../../shared/types'
import { CHAT_VIEW } from '../../shared/view-id'

// Decide if the main process may open a PTY with these args.
// Allowed: "attach <short id>" for one owned session that is not parked. Nothing else.
// The renderer sends the args, so check the type of each value.
export function canAttach(rows: SessionRow[], args: string[]): boolean {
  if (!Array.isArray(args) || args.length !== 2 || args[0] !== 'attach') return false
  const target = args[1]
  if (typeof target !== 'string' || target === '') return false
  const matches = rows.filter(row => row.shortId === target)
  return matches.length === 1 && matches[0].kind === 'owned' && matches[0].state !== 'parked'
}

export const REFUSED_NOT_CHAT = 'refused: not a chat view'
export const REFUSED_NOT_ATTACH = 'refused: not an attach to an owned session that is not parked'
export const REFUSED_OTHER_SESSION = 'refused: the attach is not for the session of the chat view'

export type ChatOpen = { ok: true; sessionId: string; cwd: string } | { ok: false; reason: string }

// Decide if the renderer may open this chat view with these args (D1).
// The renderer can open only chat views. Only the main process opens send views.
// The attach must be for the session of the view, so input to the view reaches that session.
export function checkChatOpen(rows: SessionRow[], viewId: unknown, args: string[]): ChatOpen {
  if (typeof viewId !== 'string' || !CHAT_VIEW.test(viewId)) {
    return { ok: false, reason: REFUSED_NOT_CHAT }
  }
  const sessionId = viewId.slice('chat:'.length)
  if (!canAttach(rows, args)) return { ok: false, reason: REFUSED_NOT_ATTACH }
  const row = rows.find(r => r.sessionId === sessionId)
  if (row?.shortId !== args[1]) return { ok: false, reason: REFUSED_OTHER_SESSION }
  // The folder comes from the row. The page never sends a path.
  return { cwd: row.cwd || '/', ok: true, sessionId }
}
