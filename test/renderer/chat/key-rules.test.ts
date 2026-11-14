// Shift+Enter gives a new line in a chat terminal, not a submit (spec 8.5).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { keyOverride, NEW_LINE } from '../../../src/renderer/src/chat/key-rules'

function key(
  over: Partial<{
    type: string
    key: string
    shiftKey: boolean
    altKey: boolean
    ctrlKey: boolean
    metaKey: boolean
  }>,
) {
  return {
    altKey: false,
    ctrlKey: false,
    key: 'Enter',
    metaKey: false,
    shiftKey: false,
    type: 'keydown',
    ...over,
  }
}

describe('keyOverride', () => {
  it('sends Escape and a carriage return for Shift+Enter', () => {
    expect(NEW_LINE).toBe('\x1b\r')
    expect(keyOverride(key({ shiftKey: true }))).toBe(NEW_LINE)
  })

  it('stops the keypress and the keyup of Shift+Enter and sends nothing for them', () => {
    expect(keyOverride(key({ shiftKey: true, type: 'keypress' }))).toBe('')
    expect(keyOverride(key({ shiftKey: true, type: 'keyup' }))).toBe('')
  })

  it('leaves Enter, other modifiers and other keys to xterm.js', () => {
    expect(keyOverride(key({}))).toBeNull()
    expect(keyOverride(key({ altKey: true, shiftKey: true }))).toBeNull()
    expect(keyOverride(key({ ctrlKey: true, shiftKey: true }))).toBeNull()
    expect(keyOverride(key({ metaKey: true, shiftKey: true }))).toBeNull()
    expect(keyOverride(key({ key: 'a', shiftKey: true }))).toBeNull()
  })
})

describe('the chat terminal uses the key rule', () => {
  const source = readFileSync(
    join(__dirname, '../../../src/renderer/src/chat/chat-terminal.ts'),
    'utf8',
  )

  // The chat input (dictation-keys.ts) runs the rule. Its tests check the input of Shift+Enter.
  const chatInput = readFileSync(
    join(__dirname, '../../../src/renderer/src/chat/dictation-keys.ts'),
    'utf8',
  )

  it('sends the override through the normal input and stops xterm.js for the key', () => {
    expect(source).toMatch(/attachCustomKeyEventHandler\(event => this\.chatInput\.key\(event\)\)/)
    expect(source).toMatch(/input: text => this\.dictation\.input\(text\)/)
    expect(chatInput).toMatch(/keyOverride\(event\)/)
    expect(chatInput).toMatch(/event\.preventDefault\(\)/)
  })
})
