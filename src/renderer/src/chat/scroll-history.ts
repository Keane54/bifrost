// The scroll bar of a chat terminal (spec 8.5). This module is pure.
// xterm.js 6 shows its vertical scroll bar only while the pointer is on the terminal, and for a
// short time after a scroll. Bifrost shows it at all times while the user can scroll back.
import type { IBuffer } from '@xterm/xterm'

// The attribute on the element of a chat window while its terminal has lines above the screen.
// A rule in app.css then shows the vertical scroll bar.
export const HISTORY_ATTR = 'data-terminal-history'

// True when the active buffer has lines above the screen. The user scrolls back in the normal
// buffer (D10). The alternate buffer has no scrollback.
export function hasHistory(buffer: Pick<IBuffer, 'baseY' | 'type'>): boolean {
  return buffer.type === 'normal' && buffer.baseY > 0
}
