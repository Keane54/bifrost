// A source test of the review wiring in ipc.ts. It reads the file as text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, test } from 'vitest'

const code = readFileSync(join(__dirname, '../../../src/main/ipc.ts'), 'utf8')

// The text of one ipcMain.handle call, from its channel to the next handle call.
function handler(channel: string): string {
  const start = code.indexOf(`ipcMain.handle('${channel}'`)
  expect(start, channel).toBeGreaterThan(-1)
  const next = code.indexOf('ipcMain.handle(', start + 10)
  return code.slice(start, next === -1 ? undefined : next)
}

const NEW_CHANNELS = [
  'reviews:review',
  'reviews:cancel',
  'reviews:stop-session',
  'reviews:trust-open',
  'reviews:trust-write',
  'reviews:trust-resize',
  'reviews:trust-close',
  'reviews:remove-clones',
]

describe('the review wiring in ipc.ts', () => {
  test.each(NEW_CHANNELS)('%s goes through fromPage', channel => {
    expect(handler(channel)).toMatch(/fromPage\(/)
  })

  test.each(['reviews:review', 'reviews:cancel', 'reviews:stop-session'])(
    '%s checks the PR key',
    channel => {
      expect(handler(channel)).toMatch(/checkPrKey\(/)
    },
  )

  test('reviews:trust-open checks the repository key', () => {
    expect(handler('reviews:trust-open')).toMatch(/REPO_KEY\.test\(/)
    expect(handler('reviews:trust-open')).toMatch(/REFUSED_UNKNOWN_REPO/)
  })

  test('only remove-clones works while Watch GitHub is off', () => {
    for (const channel of NEW_CHANNELS.filter(c => c !== 'reviews:remove-clones')) {
      expect(handler(channel), channel).toMatch(/whileOn\(/)
    }
    expect(handler('reviews:remove-clones')).not.toMatch(/whileOn\(/)
  })

  test('the trust output goes to the page and the runner is never settled', () => {
    expect(code).toMatch(/send\('reviews:trust-data'/)
    expect(code).toMatch(/send\('reviews:trust-end'/)
    expect(code).not.toMatch(/\.settled\(/)
  })

  test('stopRegistry stops the runner and closes the trust window', () => {
    const stop = code.slice(code.indexOf('export function stopRegistry'))
    expect(stop).toMatch(/reviewRunner\?\.stop\(\)/)
    expect(stop).toMatch(/trustWindow\?\.close\(\)/)
  })
})
