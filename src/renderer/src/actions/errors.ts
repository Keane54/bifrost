// The text that the user reads for an error of the main process.
// The main process refuses with a "refused: ..." code. The app shows plain, friendly text.
import { isSettingKey } from '../../../shared/settings'
import {
  REASON_GONE,
  REASON_NO_CWD,
  REASON_NO_PID,
  REASON_NO_TERMINAL,
  REASON_ONLY_EXTERNAL,
  REASON_PARKED,
  REASON_RESUME_ALL_RUNS,
  REASON_TERMINAL_UNKNOWN,
  REASON_WAIT_ID,
} from './reasons'

const PREFIX = 'refused: '
const NOT_CLAUDE = /^refused: process (\d+) is not a claude process$/
const ONLY_RUNNING = 'This only works for a Bifrost session that is running.'
// Node gives this text when a signal ended a command, for example at the timeout.
const COMMAND_FAILED = 'Command failed:'
const LIST_COMMAND = 'agents --json'
const LIST_FAILED = "Bifrost couldn't read the session list. It tries again in a moment."
const COMMAND_FAILED_TEXT = 'A Claude Code command failed. Try again in a moment.'
// applyPatch makes these two codes from the name of the setting.
const BAD_SETTING = 'refused: bad '
const UNKNOWN_SETTING = 'refused: unknown setting '
const SETTING_TEXT = "That setting isn't valid."

// One entry for each "refused: ..." literal in src/main and src/shared. A test checks this.
// The map also gives the text when Bifrost cannot find claude (final review M5).
export const FRIENDLY_ERRORS: Readonly<Record<string, string>> = {
  'claude not found':
    "Bifrost can't find Claude Code. Check that the claude command works in a terminal.",
  'refused: an action on this session runs':
    'Another action is still running on this session. Try again in a moment.',
  'refused: another session uses this folder':
    'Another session is still using this folder. ' +
    'Stop that session first, then delete this one.',
  'refused: Bifrost does not delete an external session':
    "Bifrost can't delete a session that runs in another terminal.",
  'refused: bad chat panel': "Bifrost couldn't read the list of chat windows.",
  'refused: bad input': "Bifrost couldn't read that request.",
  'refused: bad keys': "One of those keys isn't valid.",
  'refused: bad name': "That name isn't valid.",
  'refused: bad new session data': "Some of the New session values aren't valid.",
  'refused: bad priority': "That priority isn't valid.",
  'refused: bad process ID': "The process ID of this session isn't valid.",
  'refused: bad repository name': "That repository name isn't valid.",
  'refused: bad reviewsIgnore': "That list of repositories to ignore isn't valid.",
  'refused: bad session ID': "That session ID isn't valid.",
  'refused: bad settings': "Bifrost couldn't read those settings.",
  'refused: bad slashCommands': "That list of slash commands isn't valid.",
  'refused: bad watch colour': "That isn't a colour for the watchlist.",
  'refused: bad watch move': "Bifrost couldn't move that session in the watchlist.",
  'refused: claude rm kept the worktree':
    'Claude Code kept this session, because its worktree has commits that exist on no remote. Open the worktree to check them, then delete again.',
  'refused: claude rm took too long':
    'Claude Code took too long to delete this session. Check the worktree, then delete again.',
  'refused: Delete needs a confirmation': 'Delete needs your confirmation first.',
  'refused: no terminal app is installed': REASON_NO_TERMINAL,
  'refused: no window': "The Bifrost window isn't ready.",
  'refused: not a chat view': "That isn't a chat window.",
  'refused: not a display mode': "That isn't a display mode.",
  'refused: not an attach to an owned session that is not parked':
    'A chat window can only attach to a Bifrost session that is running.',
  'refused: not the Bifrost page': "That request didn't come from the Bifrost window.",
  'refused: only an external session': REASON_ONLY_EXTERNAL,
  'refused: only an owned session that runs': ONLY_RUNNING,
  'refused: Resume all runs': REASON_RESUME_ALL_RUNS,
  'refused: reviews are off': 'Turn on Watch GitHub in Settings first.',
  'refused: Take control needs a confirmation': 'Take control needs your confirmation first.',
  'refused: the attach is not for the session of the chat view':
    "That connection doesn't match the session of this chat window.",
  'refused: the ID that resumes this session is not known yet':
    "Bifrost doesn't know which ID resumes this session yet. Try again in 30 seconds.",
  'refused: the page that asked for the PTY is gone':
    'The window that asked for the terminal has closed.',
  'refused: the project directory is not known': REASON_NO_CWD,
  'refused: the send was cancelled by Interrupt':
    'Interrupt cancelled this message before it was sent.',
  'refused: the session did not stop':
    "The session didn't stop in time. Try Delete again in a moment.",
  'refused: the session has an open prompt':
    'This session is waiting on a prompt. Answer it in the chat window first.',
  'refused: the session has no messages yet':
    "This session has no messages yet, so there's nothing to take over. Send a message in its terminal first.",
  'refused: the session has no process ID': "Bifrost doesn't know the process ID of this session.",
  'refused: the session has no process ID yet': REASON_NO_PID,
  'refused: the session has no worktree': "This session doesn't have a worktree.",
  'refused: the session is not an owned session that runs': ONLY_RUNNING,
  'refused: the session is not idle':
    'Take control only works while the session is idle or has just finished.',
  'refused: the session is not parked': "This session isn't parked, so there's nothing to resume.",
  'refused: the session is parked': REASON_PARKED,
  'refused: the session is working':
    'This session is working right now. Try again when it has finished.',
  'refused: the session process changed':
    'The process of this session changed, so Bifrost left it alone.',
  'refused: the session runs and has no short ID': REASON_WAIT_ID,
  'refused: the terminal app of the session is not known': REASON_TERMINAL_UNKNOWN,
  'refused: the UI state is too large': 'The window layout is too large to save.',
  'refused: the UI state must be an object': "Bifrost couldn't save the window layout.",
  'refused: the worktree changed after the check':
    'The worktree changed after the check. Check it again, then delete.',
  'refused: the worktree has uncommitted changes':
    "This worktree has changes that aren't committed, so Claude Code won't delete it. Open the worktree, commit or discard them, then delete again.",
  'refused: the worktree option is off': "The worktree option isn't available.",
  'refused: two keys have the same binding': "Two actions can't share the same key.",
  'refused: unknown app': "Bifrost doesn't know that app.",
  'refused: unknown model': "Bifrost doesn't know that model.",
  'refused: unknown permission mode': "Bifrost doesn't know that permission mode.",
  'refused: unknown pull request': "That pull request isn't in the list any more.",
  'refused: unknown release': "That release isn't in the list of release notes.",
  'refused: unknown service': "Bifrost doesn't know that service.",
  'refused: unknown session': REASON_GONE,
}

// Return true for the code of a bad value or an unknown key in a settings patch.
function isSettingRefusal(message: string): boolean {
  if (message.startsWith(UNKNOWN_SETTING)) return true
  return message.startsWith(BAD_SETTING) && isSettingKey(message.slice(BAD_SETTING.length))
}

// The friendly text of a message. A code that is not in the map loses its prefix and gets a
// capital first letter. The code of a bad or unknown setting gives one text.
// A "Command failed:" text of Node gives a friendly text, with a special
// text for the session list (Task 17 bug 4). Any other message stays as it is.
export function friendlyError(message: string): string {
  const known = FRIENDLY_ERRORS[message]
  if (known !== undefined) return known
  if (isSettingRefusal(message)) return SETTING_TEXT
  const pid = NOT_CLAUDE.exec(message)?.[1]
  if (pid !== undefined) return `Process ${pid} isn't a Claude process, so Bifrost left it alone.`
  if (message.startsWith(COMMAND_FAILED)) {
    return message.includes(LIST_COMMAND) ? LIST_FAILED : COMMAND_FAILED_TEXT
  }
  if (!message.startsWith(PREFIX)) return message
  const rest = message.slice(PREFIX.length)
  return rest.charAt(0).toUpperCase() + rest.slice(1)
}

// The text of a failed hand-over. The message can end with a raw code or a "Command failed:"
// text after the lead text. The lead text stays. The code gets its friendly text. The command
// text gets the generic text, because it holds raw arguments. Other messages use friendlyError.
export function handOverFailure(message: string): string {
  const failedAt = message.indexOf(COMMAND_FAILED)
  if (failedAt > 0) return `${message.slice(0, failedAt).trimEnd()} ${COMMAND_FAILED_TEXT}`
  const at = message.indexOf(PREFIX)
  if (at <= 0) return friendlyError(message)
  const lead = message.slice(0, at).trimEnd()
  return `${lead} ${friendlyError(message.slice(at).trim())}`
}
