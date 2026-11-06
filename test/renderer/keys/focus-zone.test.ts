import { describe, expect, it } from 'vitest'
import {
  CHAT_ATTR,
  type FocusElement,
  focusChange,
  focusZone,
  KEY_RECORDER_ATTR,
  SEND_BOX_ATTR,
  type ZoneElement,
} from '../../../src/renderer/src/keys/focus-zone'

// A fake element. `inside` lists the attributes or roles that the element has or inherits.
function fake(tagName: string, inside: string[] = [], type?: string): ZoneElement {
  return {
    closest: selector => (inside.some(item => selector.includes(item)) ? {} : null),
    tagName,
    type,
  }
}

describe('focusZone', () => {
  it('finds modal before chat', () => {
    expect(focusZone(fake('TEXTAREA', ['role="dialog"', CHAT_ATTR]))).toBe('modal')
    expect(focusZone(fake('DIV', ['role="menu"']))).toBe('modal')
  })

  it('gives chat for the xterm.js text area', () => {
    expect(focusZone(fake('TEXTAREA', [CHAT_ATTR]))).toBe('chat')
  })

  it('maps the key recorder to modal', () => {
    expect(focusZone(fake('BUTTON', ['data-key-recorder']))).toBe('modal')
  })

  it('gives send-box, text, control and other', () => {
    expect(focusZone(fake('TEXTAREA', [SEND_BOX_ATTR]))).toBe('send-box')
    expect(focusZone(fake('INPUT', [], 'text'))).toBe('text')
    expect(focusZone(fake('INPUT'))).toBe('text')
    expect(focusZone(fake('TEXTAREA'))).toBe('text')
    expect(focusZone(fake('SELECT'))).toBe('text')
    expect(focusZone({ ...fake('DIV'), isContentEditable: true })).toBe('text')
    expect(focusZone(fake('INPUT', [], 'checkbox'))).toBe('control')
    expect(focusZone(fake('BUTTON'))).toBe('control')
    expect(focusZone(fake('A'))).toBe('control')
    expect(focusZone(fake('SUMMARY'))).toBe('control')
    expect(focusZone(fake('DIV', ['role="tab"']))).toBe('control')
    expect(focusZone(fake('DIV'))).toBe('other')
    expect(focusZone(null)).toBe('other')
  })
})

// A fake element for focusChange. closest matches only the exact selector of one attribute.
function inside(tagName: string, attr: string, value: string): FocusElement {
  return {
    closest: selector =>
      selector === `[${attr}]` ? { getAttribute: name => (name === attr ? value : null) } : null,
    tagName,
  }
}

describe('focusChange', () => {
  const rows = [{ sessionId: 'S1' }, { sessionId: 'S2' }]

  it('a focus in a chat window selects its session (final review Important 1)', () => {
    expect(focusChange(inside('TEXTAREA', CHAT_ATTR, 'S1'), 'S2', rows)).toEqual({
      clearGate: false,
      select: 'S1',
    })
    expect(focusChange(inside('TEXTAREA', CHAT_ATTR, 'S1'), null, rows)).toEqual({
      clearGate: false,
      select: 'S1',
    })
  })

  it('a focus in the chat window of the selected session or of an unknown session selects nothing', () => {
    expect(focusChange(inside('TEXTAREA', CHAT_ATTR, 'S1'), 'S1', rows).select).toBeNull()
    expect(focusChange(inside('TEXTAREA', CHAT_ATTR, 'S9'), 'S2', rows).select).toBeNull()
    expect(focusChange(inside('TEXTAREA', CHAT_ATTR, ''), 'S2', rows).select).toBeNull()
  })

  it('a focus outside a chat window selects nothing', () => {
    expect(focusChange(inside('TEXTAREA', SEND_BOX_ATTR, 'true'), 'S2', rows)).toEqual({
      clearGate: false,
      select: null,
    })
    expect(focusChange(null, 'S2', rows)).toEqual({ clearGate: false, select: null })
  })

  it('a focus on the key recorder clears the hold gate (final review Minor 4)', () => {
    expect(focusChange(inside('BUTTON', KEY_RECORDER_ATTR, 'true'), 'S2', rows)).toEqual({
      clearGate: true,
      select: null,
    })
  })
})
