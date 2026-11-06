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

  it('clear forgets all keys', () => {
    const gate = new HoldGate()
    gate.down('O', true)
    gate.clear()
    expect(gate.isDown('O')).toBe(false)
    expect(gate.click()).toBeNull()
    expect(gate.up('O')).toBe(false)
  })
})
