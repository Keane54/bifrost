import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { HISTORY_ATTR, hasHistory } from '../../../src/renderer/src/chat/scroll-history'
import { CHAT_ATTR } from '../../../src/renderer/src/keys/focus-zone'

// The repository has no DOM test. So the CSS and wiring checks read the source text.
const SRC = join(__dirname, '../../../src/renderer/src')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')
const TERMINAL = readFileSync(join(SRC, 'chat/chat-terminal.ts'), 'utf8')

// The selector of the rule that shows the vertical scroll bar of xterm.js.
const SELECTOR = `[${CHAT_ATTR}][${HISTORY_ATTR}] .xterm .xterm-scrollable-element > .scrollbar.vertical`

// The declarations of the rule, without its comments.
function scrollBarRule(): string {
  const at = CSS.indexOf(`${SELECTOR} {`)
  if (at === -1) throw new Error('No scroll bar rule')
  return CSS.slice(at, CSS.indexOf('}', at))
}

describe('hasHistory', () => {
  it('is false while the normal buffer has no lines above the screen', () => {
    expect(hasHistory({ baseY: 0, type: 'normal' })).toBe(false)
  })

  it('is true when the normal buffer has lines above the screen', () => {
    expect(hasHistory({ baseY: 1, type: 'normal' })).toBe(true)
    expect(hasHistory({ baseY: 4970, type: 'normal' })).toBe(true)
  })

  // The alternate buffer has no scrollback (spec 8.5, D10).
  it('is false for the alternate buffer', () => {
    expect(hasHistory({ baseY: 0, type: 'alternate' })).toBe(false)
  })
})

describe('the scroll bar rule', () => {
  it('uses a data attribute of its own', () => {
    expect(HISTORY_ATTR).toBe('data-terminal-history')
  })

  // xterm.js 6 shows the scroll bar only near the pointer. Its class "invisible" also matches the
  // Tailwind utility .invisible, which sets visibility: hidden. So the rule sets all three.
  it('shows the vertical scroll bar and lets the slider take the pointer', () => {
    const rule = scrollBarRule()
    expect(rule).toContain('opacity: 1;')
    expect(rule).toContain('visibility: visible;')
    expect(rule).toContain('pointer-events: auto;')
  })

  // The rules of xterm.css are outside a layer, and a rule in a layer always loses to them.
  it('is outside a layer, after the last layer block', () => {
    const at = CSS.indexOf(`${SELECTOR} {`)
    const lastLayer = CSS.lastIndexOf('@layer')
    const layerEnd = CSS.indexOf('\n}\n', lastLayer)
    expect(at).toBeGreaterThan(layerEnd)
  })
})

describe('the history attribute of a chat terminal', () => {
  it('follows each parsed write, each resize and each change of the buffer', () => {
    expect(TERMINAL).toContain('this.term.onWriteParsed(() => this.showHistory())')
    expect(TERMINAL).toContain('this.term.onResize(() => this.showHistory())')
    expect(TERMINAL).toContain('this.term.buffer.onBufferChange(() => this.showHistory())')
    expect(TERMINAL).toContain('toggleAttribute(HISTORY_ATTR, hasHistory(this.term.buffer.active))')
  })

  // A reset clears the buffer and fires none of the events above.
  it('follows each reset', () => {
    const resets = TERMINAL.split('this.term.reset()').length - 1
    const followed = TERMINAL.match(/this\.term\.reset\(\)\n\s*this\.showHistory\(\)/g) ?? []
    expect(resets).toBeGreaterThan(0)
    expect(followed).toHaveLength(resets)
  })
})
