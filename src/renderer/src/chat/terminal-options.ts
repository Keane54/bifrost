// The options of a chat terminal (spec 8.5). This module is pure.
import type { ITerminalOptions, ITheme } from '@xterm/xterm'
import { cssFontFamily, type TerminalFont } from '../../../shared/settings'

// The tokens in app.css with the colours of the terminal theme, by theme key.
// - background: fully transparent. The frame colour and its blur show through (user decision, 2026-11-06).
// - The slider of the scroll bar: at rest, under the pointer and during a drag (user decision, 2026-11-09).
export const THEME_TOKENS = {
  background: '--color-terminal-bg',
  scrollbarSliderActiveBackground: '--color-terminal-slider-active',
  scrollbarSliderBackground: '--color-terminal-slider',
  scrollbarSliderHoverBackground: '--color-terminal-slider-hover',
} as const satisfies Partial<Record<keyof ITheme, string>>

type ThemeKey = keyof typeof THEME_TOKENS

// The theme colours from the tokens. read gives the value of a CSS property of the document root.
// xterm.js refuses a colour that it cannot read. So a token with no value keeps the default colour.
export function terminalTheme(read: (name: string) => string): ITheme {
  const theme: ITheme = {}
  for (const key of Object.keys(THEME_TOKENS) as ThemeKey[]) {
    const value = read(THEME_TOKENS[key]).trim()
    if (value !== '') theme[key] = value
  }
  return theme
}

// allowTransparency makes the WebGL renderer draw the glyphs on a transparent background. The DOM
// renderer uses the theme background for its viewport. So both renderers show the frame colour,
// also after a WebGL context loss.
// openLink gets each link that the user clicks (user decision, 2026-11-10). Without a link
// handler, xterm.js asks "Do you want to navigate to ...?" and opens a window that Bifrost
// refuses. allowNonHttpProtocols keeps the file links, which xterm.js drops by default.
export function terminalOptions(
  font: TerminalFont,
  theme: ITheme,
  openLink: (uri: string) => void,
): ITerminalOptions {
  return {
    allowTransparency: true,
    fontFamily: cssFontFamily(font),
    fontSize: font.size,
    linkHandler: { activate: (_event, uri) => openLink(uri), allowNonHttpProtocols: true },
    macOptionClickForcesSelection: true,
    scrollback: 5000,
    theme,
  }
}
