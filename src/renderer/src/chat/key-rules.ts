// The key rules of a chat terminal (spec 8.5). This module is pure.
// xterm.js sends a carriage return for Enter and also for Shift+Enter. So Claude Code submits on
// both. Claude Code reads Escape and a carriage return as a new line. Its terminal setup gives
// Shift+Enter the same text in VS Code (user decision, 2026-11-10).
export const NEW_LINE = '\x1b\r'

export interface KeyEventLike {
  type: string
  key: string
  shiftKey: boolean
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
}

// The text to send in place of the text of xterm.js, or null when xterm.js handles the key.
// An empty text means that xterm.js must not handle the event and that nothing goes to the PTY.
// This applies to the keypress and the keyup of Shift+Enter: only the keydown sends the text.
export function keyOverride(event: KeyEventLike): string | null {
  const shiftEnter =
    event.key === 'Enter' && event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey
  if (!shiftEnter) return null
  return event.type === 'keydown' ? NEW_LINE : ''
}
