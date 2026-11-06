import { describe, expect, it } from 'vitest'
import { PendingOpen } from '../../../src/main/alerts/pending-open'

describe('PendingOpen', () => {
  it('a click while no page is loaded waits for the next load, one time', () => {
    const pending = new PendingOpen()
    expect(pending.click('S1')).toBeNull()
    expect(pending.load()).toBe('S1')
    // A second load, for example a reload, does not open the session again.
    pending.unload()
    expect(pending.load()).toBeNull()
  })

  it('a click with a loaded page gives the session at once', () => {
    const pending = new PendingOpen()
    pending.load()
    expect(pending.click('S1')).toBe('S1')
    pending.unload()
    expect(pending.load()).toBeNull()
  })

  it('a click while a page loads again waits for that load', () => {
    const pending = new PendingOpen()
    pending.load()
    pending.unload()
    expect(pending.click('S1')).toBeNull()
    expect(pending.load()).toBe('S1')
  })

  it('the last click before a load wins', () => {
    const pending = new PendingOpen()
    pending.click('S1')
    pending.click('S2')
    expect(pending.load()).toBe('S2')
  })
})
