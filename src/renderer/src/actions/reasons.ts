// The texts that tell the user why an action is disabled.
import { RED_BOX_BLOCK } from '../../../shared/input'

export const REASON_EXTERNAL =
  'This session runs in another terminal, so Bifrost can only show its status.'
export const REASON_PARKED = 'This session is parked. Resume it first.'
export const REASON_ONLY_EXTERNAL = 'This only works for a session that runs in another terminal.'
export const REASON_ONLY_PARKED = 'This only works for a parked session.'
export const REASON_GONE = "This session isn't in the list any more."
export const REASON_NO_WINDOW = "The chat window isn't open."
export const REASON_NO_CWD = "Bifrost doesn't know the project folder of this session."
export const REASON_NO_APPS = 'No app is available to open this.'
export const REASON_LAST_TAB = 'The Overview needs at least one tab.'
export const REASON_MAX_TABS = 'The Overview can have up to 12 tabs.'
export const REASON_KIND_COLUMN = 'The kind column always stays first and on.'
export const REASON_DEFAULT_TAB = 'This tab already has the default columns and filter.'
export const REASON_WAIT_LIST = 'Waiting for the session list.'
export const REASON_WAIT_ID = 'Waiting for the session ID.'
export const REASON_PR_SESSION = 'A review session has no hand-over.'
export const REASON_PR_RESUME =
  "A review session can't be resumed. Click Review in the Reviews panel to start a new one."
// Compact is disabled while the session works on a reply (user decision, 2026-11-10).
export const REASON_WAIT_IDLE = 'Wait until the session is idle.'

export const REASON_RED_BOX = RED_BOX_BLOCK
export const REASON_TAKE_BUSY =
  'This session is working right now. Taking control would stop that work.'
export const REASON_TAKE_PROMPT =
  'This session is waiting on a prompt. Taking control would cancel it.'
export const REASON_NO_PID = "Bifrost doesn't know the process ID of this session yet."
export const REASON_RUNNING = 'Another action is still running on this session.'
export const REASON_NO_PROCESS = "This session is parked, so there's nothing to stop."
export const REASON_NO_TERMINAL = 'No supported terminal app is installed.'
export const REASON_TERMINAL_UNKNOWN =
  "Bifrost doesn't know which terminal app this session runs in."
export const REASON_NOTHING_TO_RESUME =
  'None of the parked sessions were active when Bifrost last closed.'
export const REASON_RESUME_ALL_RUNS = 'Resume all is already running.'

export const REASON_WATCHED = 'This session is already on the watchlist.'
export const REASON_NOT_WATCHED = "This session isn't on the watchlist."
