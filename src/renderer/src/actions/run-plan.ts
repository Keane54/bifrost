// The plan of one action of a row: what the actions provider does for it (spec 9.1, 9.2).
// The plan is pure. The provider runs it.
import type { SessionRow } from '../../../shared/types'
import { type ActionContext, type ActionId, actionStateFor, type MenuArg } from './action-model'
import { type ConfirmText, confirmFor } from './confirm'

// The API call of an action. remove is the call of Delete.
export type ApiCall =
  | 'interrupt'
  | 'stop'
  | 'remove'
  | 'resume'
  | 'take-control'
  | 'open-in-terminal'
  | 'set-priority'
  | 'copy-id'
  | 'open-project'
  | 'watch-add'
  | 'watch-colour'
  | 'watch-remove'

// What the provider does with the chat window after a call that did not fail.
export type After = 'none' | 'open-chat' | 'close-chat' | 'restart-chat'

export type RunPlan =
  | { kind: 'none' }
  | { kind: 'open-chat' }
  | { kind: 'close-chat' }
  | { kind: 'focus-send'; text: '' | '/' }
  | { kind: 'send'; text: string }
  | { kind: 'rename' }
  | { kind: 'call'; call: ApiCall; confirm: ConfirmText | null; after: After }

// A request of a focus-send plan: the send box of the session takes the focus.
export interface FocusRequest {
  sessionId: string
  text: '' | '/'
  // A new number for each request. So the same request twice also focuses the send box.
  n: number
  // The time of the request in ms (Date.now).
  at: number
}

// A send box uses a request only this long after the click. A later selection of the row
// does not use an old request.
export const FOCUS_REQUEST_MS = 1000

export function focusRequestUsable(
  request: FocusRequest | null,
  sessionId: string,
  now: number,
): boolean {
  return request !== null && request.sessionId === sessionId && now - request.at <= FOCUS_REQUEST_MS
}

const NONE: RunPlan = { kind: 'none' }

function call(c: ApiCall, confirm: ConfirmText | null, after: After): RunPlan {
  return { after, call: c, confirm, kind: 'call' }
}

// A slash command from the submenu. The string "/" alone means "Other...".
function slashCommand(arg: MenuArg | undefined): string | null {
  return typeof arg === 'string' && arg.startsWith('/') && arg !== '/' ? arg : null
}

// A disabled action gives none. So a click on it has no effect (spec 9.1).
export function planRun(
  id: ActionId,
  row: SessionRow | undefined,
  ctx: ActionContext,
  arg?: MenuArg,
): RunPlan {
  if (!row || !actionStateFor(id, row, ctx).enabled) return NONE
  switch (id) {
    case 'open':
      return { kind: 'open-chat' }
    case 'close-window':
      return { kind: 'close-chat' }
    case 'send-message':
      return { kind: 'focus-send', text: '' }
    case 'run-slash': {
      const command = slashCommand(arg)
      return command === null ? { kind: 'focus-send', text: '/' } : { kind: 'send', text: command }
    }
    case 'rename':
      return { kind: 'rename' }
    case 'interrupt':
    case 'set-priority':
    case 'copy-id':
    case 'open-project':
    case 'open-in-terminal':
    case 'watch-add':
    case 'watch-colour':
    case 'watch-remove':
      return call(id, null, 'none')
    case 'resume':
      return call('resume', null, 'restart-chat')
    case 'take-control':
      return call('take-control', confirmFor('take-control', row, ctx.labels), 'open-chat')
    case 'stop':
      // A session that does not work gets no confirmation.
      return call('stop', confirmFor('stop', row, ctx.labels), 'none')
    case 'delete':
      // The provider makes the final text after the unmerged-work check (Task 13).
      return call('remove', confirmFor('delete', row, ctx.labels), 'close-chat')
    default:
      // New session and Resume all need no row. Show Info comes in M5.
      return NONE
  }
}
