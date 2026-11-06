// The options of a chat terminal (spec 8.5). This module is pure.
import type { ITerminalOptions } from '@xterm/xterm'
import { cssFontFamily, type TerminalFont } from '../../../shared/settings'

// The token in app.css with the background of a chat terminal. It is fully transparent, so the
// frame colour and its blur show through (user decision, 2026-11-06).
export const TERMINAL_BG_TOKEN = '--color-terminal-bg'

// The value of the token. read gives the value of a CSS property of the document root.
export function terminalBackground(read: (name: string) => string): string {
  return read(TERMINAL_BG_TOKEN).trim()
}

// allowTransparency makes the WebGL renderer draw the glyphs on a transparent background. The DOM
// renderer uses the theme background for its viewport. So both renderers show the frame colour,
// also after a WebGL context loss. An empty background keeps the default theme, because xterm.js
// refuses a colour that it cannot read.
export function terminalOptions(font: TerminalFont, background: string): ITerminalOptions {
  return {
    allowTransparency: true,
    fontFamily: cssFontFamily(font),
    fontSize: font.size,
    macOptionClickForcesSelection: true,
    scrollback: 5000,
    theme: background === '' ? {} : { background },
  }
}
