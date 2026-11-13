import { describe, expect, it } from 'vitest'
import { PANEL_ICONS } from '../../../src/renderer/src/wm/panel-icons'
import { DEFAULT_SIZES } from '../../../src/renderer/src/wm/state'

describe('panel icons', () => {
  it('has one icon for each panel kind', () => {
    expect(Object.keys(PANEL_ICONS).sort()).toEqual(Object.keys(DEFAULT_SIZES).sort())
  })
})
