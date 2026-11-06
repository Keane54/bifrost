import { describe, expect, test } from 'vitest'
import { devDockIcon } from '../../../src/main/window/dock-icon'

describe('devDockIcon', () => {
  test('a dev start on macOS gets the Bifrost icon in the Dock', () => {
    expect(devDockIcon('darwin', false, '/r/icon.png')).toBe('/r/icon.png')
  })

  test('a packaged app keeps the icon of its bundle', () => {
    expect(devDockIcon('darwin', true, '/r/icon.png')).toBeNull()
  })

  test('another platform has no Dock', () => {
    expect(devDockIcon('linux', false, '/r/icon.png')).toBeNull()
  })
})
