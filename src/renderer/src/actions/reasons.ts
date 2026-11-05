// The texts that tell the user why an action is disabled.
export const REASON_EXTERNAL = 'An external session shows its status only.'
export const REASON_PARKED = 'The session is parked. Resume it first.'
export const REASON_ONLY_EXTERNAL = 'Only for an external session.'
export const REASON_ONLY_PARKED = 'Only for a parked session.'
export const REASON_GONE = 'The session is not in the list.'
export const REASON_NO_WINDOW = 'The chat window is not open.'
export const REASON_NO_CWD = 'The project directory is not known.'
export const REASON_NO_APPS = 'No app is available.'
export const REASON_LAST_TAB = 'An Overview needs one tab.'
export const REASON_MAX_TABS = 'An Overview has a maximum of 12 tabs.'
export const REASON_WAIT_LIST = 'Waiting for the session list.'
export const REASON_WAIT_ID = 'Waiting for the session ID.'

// The reason of an action that a later milestone adds.
export function comesIn(m: 4 | 5): string {
  return `Comes in M${m}`
}
