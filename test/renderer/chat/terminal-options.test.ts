import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  THEME_TOKENS,
  terminalOptions,
  terminalTheme,
} from '../../../src/renderer/src/chat/terminal-options'

const CSS = readFileSync(join(__dirname, '../../../src/renderer/src/styles/app.css'), 'utf8')
const FONT = { family: 'SF Mono', size: 13 }
// The values of the tokens, as getComputedStyle gives them.
const CLEAR = '#00000000'
const SLIDER = '#ffffff66'
const SLIDER_HOVER = '#ffffff99'
const SLIDER_ACTIVE = '#ffffffcc'
const VALUES: Record<string, string> = {
  '--color-terminal-bg': CLEAR,
  '--color-terminal-slider': SLIDER,
  '--color-terminal-slider-active': SLIDER_ACTIVE,
  '--color-terminal-slider-hover': SLIDER_HOVER,
}

describe('terminalOptions', () => {
  // the user, 2026-11-06: the frame colour and its blur show through the chat terminal.
  it('gives a transparent background that the WebGL renderer also draws', () => {
    const options = terminalOptions(FONT, { background: CLEAR })
    expect(options.allowTransparency).toBe(true)
    expect(options.theme).toEqual({ background: CLEAR })
  })

  it('keeps the font, the option-click selection and the scrollback', () => {
    expect(terminalOptions(FONT, { background: CLEAR })).toMatchObject({
      fontFamily: '"SF Mono", ui-monospace, Menlo, monospace',
      fontSize: 13,
      macOptionClickForcesSelection: true,
      scrollback: 5000,
    })
  })

  // the user, 2026-11-09: the scroll bar of a chat window is clearly visible.
  it('gives the slider colours of the tokens to xterm.js', () => {
    const theme = terminalOptions(
      FONT,
      terminalTheme(name => VALUES[name] ?? ''),
    ).theme
    expect(theme).toEqual({
      background: CLEAR,
      scrollbarSliderActiveBackground: SLIDER_ACTIVE,
      scrollbarSliderBackground: SLIDER,
      scrollbarSliderHoverBackground: SLIDER_HOVER,
    })
  })
})

describe('terminalTheme', () => {
  it('reads each token and trims the value', () => {
    const theme = terminalTheme(name => `  ${VALUES[name] ?? 'x'} `)
    expect(theme.background).toBe(CLEAR)
    expect(theme.scrollbarSliderBackground).toBe(SLIDER)
  })

  it('without a token value, keeps the default colour, because xterm.js refuses an empty colour', () => {
    expect(terminalTheme(() => '')).toEqual({})
    const noHover = terminalTheme(name => (name === '--color-terminal-slider-hover' ? '' : 'red'))
    expect(noHover).not.toHaveProperty('scrollbarSliderHoverBackground')
    expect(noHover.scrollbarSliderBackground).toBe('red')
  })

  it('reads the background and the three slider colours from the terminal tokens', () => {
    expect(THEME_TOKENS).toEqual({
      background: '--color-terminal-bg',
      scrollbarSliderActiveBackground: '--color-terminal-slider-active',
      scrollbarSliderBackground: '--color-terminal-slider',
      scrollbarSliderHoverBackground: '--color-terminal-slider-hover',
    })
  })

  it('reads only tokens that app.css defines', () => {
    const missing = Object.values(THEME_TOKENS).filter(token => !CSS.includes(`${token}:`))
    expect(missing).toEqual([])
  })
})
