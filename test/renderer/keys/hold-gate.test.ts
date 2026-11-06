import { describe, expect, it } from 'vitest'
import { HoldGate } from '../../../src/renderer/src/keys/hold-gate'

describe('HoldGate', () => {
  it('a hold key and a click give the key, and the keyup then gives false', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    expect(gate.click()).toBe('O')
    expect(gate.up('O')).toBe(false)
  })

  it('a key without a click gives true at the keyup', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    expect(gate.isDown('O')).toBe(true)
    expect(gate.up('O')).toBe(true)
    expect(gate.isDown('O')).toBe(false)
  })

  it('a keyup of a key that is not down gives false', () => {
    expect(new HoldGate().up('O')).toBe(false)
  })

  it('key repeat does not reset a used key', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.click()
    gate.down('O', true)
    expect(gate.up('O')).toBe(false)
  })

  it('two clicks with one key both give the key', () => {
    const gate = new HoldGate()
    gate.down('3', true)
    expect(gate.click()).toBe('3')
    expect(gate.click()).toBe('3')
  })

  it('two held keys give no hold click', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.down('M', true)
    expect(gate.click()).toBeNull()
    expect(gate.up('O')).toBe(true)
    expect(gate.up('M')).toBe(true)
  })

  it('no key gives no hold click', () => {
    expect(new HoldGate().click()).toBeNull()
  })

  it('a key that went down in a chat window or a text box is not a hold key', () => {
    const gate = new HoldGate()
    gate.down('O', false)
    expect(gate.click()).toBeNull()
    expect(gate.up('O')).toBe(false)
  })

  it('an inactive key does not count as a second key', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.down('M', false)
    expect(gate.click()).toBe('O')
  })

  it('holding is true while one active key is down, also after a click', () => {
    const gate = new HoldGate()
    expect(gate.holding()).toBe(false)
    gate.down('O', true)
    expect(gate.holding()).toBe(true)
    gate.click()
    expect(gate.holding()).toBe(true)
    gate.up('O')
    expect(gate.holding()).toBe(false)
  })

  it('holding is false for an inactive key and for two active keys', () => {
    const gate = new HoldGate()
    gate.down('O', false)
    expect(gate.holding()).toBe(false)
    gate.down('M', true)
    expect(gate.holding()).toBe(true)
    gate.down('X', true)
    expect(gate.holding()).toBe(false)
  })

  it('a quick hold click: down, press on the row, keyup, then click acts on that row', () => {
    // Final review Important 2: the keyup comes before the mouse-up. The keyup must not act on
    // the selected row, and the click must act on the pressed row.
    const gate = new HoldGate()
    gate.down('X', true)
    expect(gate.press('C')).toBe('X')
    expect(gate.up('X')).toBe(false)
    expect(gate.release('C')).toBe('X')
  })

  it('a press with no hold key gives a plain click', () => {
    const gate = new HoldGate()
    expect(gate.press('C')).toBeNull()
    expect(gate.release('C')).toBeNull()
    gate.down('O', false)
    expect(gate.press('C')).toBeNull()
    expect(gate.release('C')).toBeNull()
  })

  it('a claim serves one click of the pressed row only', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.press('C')
    expect(gate.release('D')).toBeNull()
    gate.press('C')
    expect(gate.release('C')).toBe('O')
    expect(gate.release('C')).toBeNull()
  })

  it('a new press removes the claim of an old press', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.press('C')
    gate.up('O')
    expect(gate.press('D')).toBeNull()
    expect(gate.release('C')).toBeNull()
    expect(gate.release('D')).toBeNull()
  })

  it('clear removes the claim', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.press('C')
    gate.clear()
    expect(gate.release('C')).toBeNull()
  })

  it('clear forgets all keys', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.clear()
    expect(gate.isDown('O')).toBe(false)
    expect(gate.click()).toBeNull()
    expect(gate.up('O')).toBe(false)
  })
})
