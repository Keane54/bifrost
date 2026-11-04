const PASTE_START = '\x1b[200~'
const PASTE_END = '\x1b[201~'

// Make the text that the send box writes to a PTY. A CR at the end sends the text.
// With bracketed paste, the text goes between the paste markers.
// xterm.js changes each line break in a paste to CR, so this function does the same.
// Without bracketed paste, the text goes as typed. Each line break stays LF.
export function sendBody(text: string, paste: boolean): string {
  if (!paste) return `${text}\r`
  return `${PASTE_START + text.replace(/\r?\n/g, '\r') + PASTE_END}\r`
}

// Enter sends the text. Shift+Enter adds a line break.
// Enter during an input method composition does not send.
export function isSendKey(ev: { key: string; shiftKey: boolean; isComposing: boolean }): boolean {
  return ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing
}
