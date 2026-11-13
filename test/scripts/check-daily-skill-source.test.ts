// A source test of the live check of bifrost-daily-update. The script runs by hand only, with a
// real claude, so this test reads it as text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const code = readFileSync(
  join(import.meta.dirname, '..', '..', 'scripts', 'daily-update', 'check-daily-skill.ts'),
  'utf8',
)

describe('the live check of bifrost-daily-update', () => {
  it('uses the run args, the result checks and the Haiku model of the product', () => {
    for (const text of ['runArgs(', 'denyList(', 'allowedNow(', 'parseInitEvent(']) {
      expect(code).toContain(text)
    }
    expect(code).toContain('extractResult(')
    expect(code).toContain('checkDailyResult(')
    expect(code).toContain("const MODEL = 'haiku'")
  })

  it('adds the fake board with --mcp-config and never with --strict-mcp-config', () => {
    expect(code).toContain("'--mcp-config'")
    expect(code).not.toContain('--strict-mcp-config')
  })

  it('fails when the fake board logged a call of the write tool', () => {
    expect(code).toContain("'work_items_update'")
    expect(code).toMatch(/process\.exitCode = 1/)
  })
})
