import { describe, expect, it } from 'vitest'
import { whatsNewRule } from '../../../src/main/release-notes/rules'

describe('whatsNewRule', () => {
  it('opens nothing for a fresh install, and stores the version', () => {
    expect(whatsNewRule({ current: '0.5.0', lastSeen: null, setupDone: false })).toEqual({
      open: null,
      store: true,
    })
  })

  it('opens the current version for an existing user with no last seen version', () => {
    expect(whatsNewRule({ current: '0.5.0', lastSeen: null, setupDone: true })).toEqual({
      open: { since: null, version: '0.5.0' },
      store: true,
    })
  })

  it('opens the versions after the last seen version, and stores the version', () => {
    expect(whatsNewRule({ current: '0.5.1', lastSeen: '0.4.0', setupDone: true })).toEqual({
      open: { since: '0.4.0', version: '0.5.1' },
      store: true,
    })
    // An update opens What's new also before the setup is done.
    expect(whatsNewRule({ current: '0.10.0', lastSeen: '0.9.0', setupDone: false })).toEqual({
      open: { since: '0.9.0', version: '0.10.0' },
      store: true,
    })
  })

  it('opens nothing and stores nothing for the same or a higher last seen version', () => {
    for (const lastSeen of ['0.5.0', '0.5.1', '1.0.0']) {
      expect(whatsNewRule({ current: '0.5.0', lastSeen, setupDone: true }), lastSeen).toEqual({
        open: null,
        store: false,
      })
    }
  })

  it('takes a last seen version that is not a version as no last seen version', () => {
    expect(whatsNewRule({ current: '0.5.0', lastSeen: 'garbage', setupDone: true })).toEqual({
      open: { since: null, version: '0.5.0' },
      store: true,
    })
  })

  it('opens nothing and stores nothing when the current version is not a version', () => {
    expect(whatsNewRule({ current: 'dev', lastSeen: '0.4.0', setupDone: true })).toEqual({
      open: null,
      store: false,
    })
  })
})
