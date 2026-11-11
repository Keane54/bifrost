// A source test of the live check script. The script runs by hand only, with a real claude, so
// this test reads it as text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const code = readFileSync(
  join(import.meta.dirname, '..', '..', 'scripts', 'reviews', 'check-review-skill.ts'),
  'utf8',
)

describe('the live check script', () => {
  it('lists the stopped sessions too, with agents --json --all', () => {
    expect(code).toContain("['agents', '--json', '--all']")
    expect(code).not.toContain("claude(['agents', '--json'], ")
  })

  it('waits for the end of the session after claude stop and before claude rm', () => {
    const stop = code.indexOf("claude(['stop', id]")
    const wait = code.indexOf('await waitForStop(id)')
    const rm = code.indexOf("claude(['rm', id]")
    expect(stop).toBeGreaterThan(-1)
    expect(wait).toBeGreaterThan(stop)
    expect(rm).toBeGreaterThan(wait)
    expect(code).toMatch(/const STOP_WAIT_MS = \d/)
  })
})
