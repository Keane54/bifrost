// The signing identity script. It reads the output of "security find-identity" and finds the
// Developer ID identity and the team ID. The fixtures use made-up values.
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseSigningIdentity } from '../../scripts/release/signing-identity'

const SCRIPT = join(__dirname, '../../scripts/release/signing-identity.ts')
const HASH_A = 'A'.repeat(40)
const HASH_B = 'B'.repeat(40)
const DEV = '"Developer ID Application: Example Corp Ltd (ABCDE12345)"'
const OTHER_DEV = '"Developer ID Application: Other Corp Ltd (ZYXWV98765)"'

function output(...lines: string[]): string {
  const body = lines.map((line, i) => `  ${i + 1}) ${line}`).join('\n')
  const count = lines.length
  return `${body}\n     ${count} valid identities found\n`
}

describe('parseSigningIdentity', () => {
  it('reads one Developer ID identity', () => {
    const result = parseSigningIdentity(output(`${HASH_A} ${DEV}`))
    expect(result).toEqual({
      identity: 'Example Corp Ltd (ABCDE12345)',
      ok: true,
      teamId: 'ABCDE12345',
    })
  })

  it('fails when there is no identity', () => {
    const result = parseSigningIdentity('     0 valid identities found\n')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.message).toContain('No Developer ID Application identity')
  })

  it('fails when there are two Developer ID identities', () => {
    const result = parseSigningIdentity(output(`${HASH_A} ${DEV}`, `${HASH_B} ${OTHER_DEV}`))
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.message).toContain('2 Developer ID Application identities')
  })

  it('ignores an identity that is not Developer ID', () => {
    const apple = `${HASH_B} "Apple Development: Example Corp Ltd (QRSTU54321)"`
    const result = parseSigningIdentity(output(apple, `${HASH_A} ${DEV}`))
    expect(result).toEqual({
      identity: 'Example Corp Ltd (ABCDE12345)',
      ok: true,
      teamId: 'ABCDE12345',
    })
  })

  it('fails when only a non-Developer-ID identity is there', () => {
    const apple = `${HASH_B} "Apple Development: Example Corp Ltd (QRSTU54321)"`
    expect(parseSigningIdentity(output(apple)).ok).toBe(false)
  })

  it('fails when the team ID has a bad format', () => {
    for (const bad of ['abcde12345', 'ABCDE1234', 'ABCDE123456', 'ABCDE-2345']) {
      const line = `${HASH_A} "Developer ID Application: Example Corp Ltd (${bad})"`
      const result = parseSigningIdentity(output(line))
      expect(result.ok).toBe(false)
      if (!result.ok) expect(result.message).toContain('team ID')
    }
  })

  it('fails when the name has no team ID', () => {
    const line = `${HASH_A} "Developer ID Application: Example Corp Ltd"`
    expect(parseSigningIdentity(output(line)).ok).toBe(false)
  })
})

describe('the script', () => {
  function run(input: string, envFile: string) {
    return spawnSync(process.execPath, [SCRIPT], {
      encoding: 'utf8',
      env: { GITHUB_ENV: envFile, PATH: process.env.PATH ?? '' },
      input,
    })
  }

  it('writes the two values to GITHUB_ENV', () => {
    const file = join(mkdtempSync(join(tmpdir(), 'sign-')), 'env')
    writeFileSync(file, '')
    const result = run(output(`${HASH_A} ${DEV}`), file)
    expect(result.status).toBe(0)
    expect(readFileSync(file, 'utf8')).toBe(
      'APPLE_SIGNING_IDENTITY=Example Corp Ltd (ABCDE12345)\nAPPLE_TEAM_ID=ABCDE12345\n',
    )
  })

  it('exits with 1 and writes nothing on an error', () => {
    const file = join(mkdtempSync(join(tmpdir(), 'sign-')), 'env')
    writeFileSync(file, '')
    const result = run('     0 valid identities found\n', file)
    expect(result.status).toBe(1)
    expect(result.stderr).toContain('No Developer ID Application identity')
    expect(readFileSync(file, 'utf8')).toBe('')
  })
})
