import { describe, expect, test } from 'vitest'
import { devDockIcon } from '../../../src/main/window/dock-icon'

describe('devDockIcon', () => {
  test('a dev start on macOS gets the dev icon in the Dock', () => {
    expect(devDockIcon('darwin', false, '/r/icon-dev.png')).toBe('/r/icon-dev.png')
  })

  test('a packaged app keeps the icon of its bundle', () => {
    expect(devDockIcon('darwin', true, '/r/icon.png')).toBeNull()
  })

  test('a packaged app on another platform also gets no icon', () => {
    expect(devDockIcon('win32', true, '/r/icon-dev.png')).toBeNull()
  })

  test('another platform has no Dock', () => {
    expect(devDockIcon('linux', false, '/r/icon.png')).toBeNull()
  })
})
