// Source checks of the Live details wiring in ipc.ts. ipc.ts imports Electron, so a unit test
// cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const source = readFileSync(join(__dirname, '../../../src/main/ipc.ts'), 'utf8')

// The text with each run of white space as one space.
const flat = (text: string): string => text.replace(/\s+/g, ' ')

describe('the live:status handler', () => {
  it('waits for the start of Live details, but does not take the lock of the actions', () => {
    const text = flat(source)
    expect(text.split("ipcMain.handle('live:status'")).toHaveLength(2)
    expect(text).toContain(
      "ipcMain.handle('live:status', e => fromPage(e, () => " +
        'serial.afterFirst(() => live.status())))',
    )
  })

  it('runs the start in runFirst of the same serial runner', () => {
    expect(flat(source)).toContain('void serial .runFirst(async () => {')
  })
})
