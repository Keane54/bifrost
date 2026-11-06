import { describe, expect, it } from 'vitest'
import { frameBlur } from '../../../src/renderer/src/wm/frame-style'

describe('frameBlur', () => {
  // the user, 2026-11-06: a very light blur behind a chat window, as in EVE.
  it('gives a chat window the light blur of 8 px', () => {
    expect(frameBlur('chat:5a0e0001-0000-4000-8000-000000000001')).toBe('backdrop-blur-sm')
  })

  it('keeps the blur of the other panels', () => {
    for (const panelId of ['overview:1', 'settings', 'selected-item', 'service-status']) {
      expect(frameBlur(panelId), panelId).toBe('backdrop-blur-md')
    }
  })
})
