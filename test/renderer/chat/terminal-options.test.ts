import { describe, expect, it } from 'vitest'
import {
  TERMINAL_BG_TOKEN,
  terminalBackground,
  terminalOptions,
} from '../../../src/renderer/src/chat/terminal-options'

const FONT = { family: 'SF Mono', size: 13 }
// A value of the token, as getComputedStyle gives it.
const CLEAR = '#00000000'

describe('terminalOptions', () => {
  // the user, 2026-11-06: the frame colour and its blur show through the chat terminal.
  it('gives a transparent background that the WebGL renderer also draws', () => {
    const options = terminalOptions(FONT, CLEAR)
    expect(options.allowTransparency).toBe(true)
    expect(options.theme).toEqual({ background: CLEAR })
  })

  it('keeps the font, the option-click selection and the scrollback', () => {
    expect(terminalOptions(FONT, CLEAR)).toMatchObject({
      fontFamily: '"SF Mono", ui-monospace, Menlo, monospace',
      fontSize: 13,
      macOptionClickForcesSelection: true,
      scrollback: 5000,
    })
  })

  it('without a token value, keeps the default theme, because xterm.js refuses an empty colour', () => {
    expect(terminalOptions(FONT, '').theme).toEqual({})
  })
})

describe('terminalBackground', () => {
  it('reads the token and trims the value', () => {
    const read = (name: string): string => (name === TERMINAL_BG_TOKEN ? `  ${CLEAR} ` : 'x')
    expect(terminalBackground(read)).toBe(CLEAR)
    expect(TERMINAL_BG_TOKEN).toBe('--color-terminal-bg')
  })
})
