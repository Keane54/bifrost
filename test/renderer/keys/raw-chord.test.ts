import { describe, expect, it } from 'vitest'
import { gateChange, releasedHoldKey, toRawChord } from '../../../src/renderer/src/keys/raw-chord'

describe('toRawChord', () => {
  it('toRawChord gives the key and the true modifiers', () => {
    expect(toRawChord('Mod+Shift+M')).toStrictEqual({ key: 'M', mod: true, shift: true })
    expect(toRawChord('Escape')).toStrictEqual({ key: 'Escape' })
    expect(toRawChord('Mod+Control+1')).toStrictEqual({ ctrl: true, key: '1', mod: true })
    expect(toRawChord('Mod+Alt+S')).toStrictEqual({ alt: true, key: 'S', mod: true })
    expect(toRawChord('bad')).toBeNull()
  })

  it('toRawChord reads the binding in its standard form', () => {
    expect(toRawChord('shift+tab')).toStrictEqual({ key: 'Tab', shift: true })
    expect(toRawChord('Cmd+/')).toStrictEqual({ key: '/', mod: true })
    expect(toRawChord('')).toBeNull()
  })
})

describe('releasedHoldKey', () => {
  const hold = new Set(['O', '1'])

  it('gives the hold key of a keyup with a modifier', () => {
    // Shift is down at the keyup of O. The key text is upper case.
    expect(releasedHoldKey({ code: 'KeyO', key: 'O', shiftKey: true }, hold)).toBe('O')
    // Shift is down at the keyup of 1. The key text is "!", so the code gives the key.
    expect(releasedHoldKey({ code: 'Digit1', key: '!', shiftKey: true }, hold)).toBe('1')
    expect(releasedHoldKey({ code: 'KeyO', key: 'o', metaKey: true }, hold)).toBe('O')
    expect(releasedHoldKey({ altKey: true, code: 'KeyO', key: 'ø' }, hold)).toBe('O')
    expect(releasedHoldKey({ code: 'KeyO', ctrlKey: true, key: 'o' }, hold)).toBe('O')
  })

  it('gives null for a keyup without a modifier or for a key that is not a hold key', () => {
    // The hotkey registration of the plain key takes this keyup.
    expect(releasedHoldKey({ code: 'KeyO', key: 'o' }, hold)).toBeNull()
    expect(releasedHoldKey({ code: 'KeyP', key: 'P', shiftKey: true }, hold)).toBeNull()
    expect(releasedHoldKey({ code: 'Digit2', key: '@', shiftKey: true }, hold)).toBeNull()
  })
})

describe('gateChange', () => {
  const hold = new Set(['O', 'X'])

  it('a Meta keydown or keyup gives clear', () => {
    // macOS sends no keyup for a key that goes up while Cmd is down. So Cmd clears the gate.
    expect(gateChange('keydown', { code: 'MetaLeft', key: 'Meta', metaKey: true }, hold)).toEqual({
      kind: 'clear',
    })
    expect(gateChange('keyup', { code: 'MetaLeft', key: 'Meta' }, hold)).toEqual({ kind: 'clear' })
    expect(gateChange('keydown', { code: 'MetaRight', key: 'Meta', metaKey: true }, hold)).toEqual({
      kind: 'clear',
    })
  })

  it('a keyup of a hold key with a modifier gives up, and other keys give null', () => {
    expect(gateChange('keyup', { code: 'KeyX', key: 'X', shiftKey: true }, hold)).toEqual({
      key: 'X',
      kind: 'up',
    })
    // The hotkey of the hold key takes the plain keyup and keydown.
    expect(gateChange('keyup', { code: 'KeyX', key: 'x' }, hold)).toBeNull()
    expect(gateChange('keydown', { code: 'KeyX', key: 'x' }, hold)).toBeNull()
    expect(
      gateChange('keydown', { code: 'ShiftLeft', key: 'Shift', shiftKey: true }, hold),
    ).toBeNull()
    expect(gateChange('keyup', { code: 'ShiftLeft', key: 'Shift' }, hold)).toBeNull()
    expect(gateChange('keydown', { code: 'KeyW', key: 'w', metaKey: true }, hold)).toBeNull()
  })
})
