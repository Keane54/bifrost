import { describe, expect, it } from 'vitest'
import {
  CHAT_ATTR,
  focusZone,
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
