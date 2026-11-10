// The release summary script. It prints the summary of the Release workflow for the release notes.
// The summary is required (user decision, 2026-11-10).
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { releaseSummary, SUMMARY_MAX } from '../../scripts/release/summary'

const SCRIPT = join(__dirname, '../../scripts/release/summary.ts')
const EMPTY = 'The release summary is empty. Type a short summary of the release.'

// Run the script with node, with RELEASE_SUMMARY set to the value, or not set for undefined.
function runScript(value: string | undefined): { status: number | null; out: string; err: string } {
  const env: Record<string, string> = { PATH: process.env.PATH ?? '' }
  if (value !== undefined) env.RELEASE_SUMMARY = value
  const result = spawnSync(process.execPath, [SCRIPT], { encoding: 'utf8', env })
  return { err: result.stderr, out: result.stdout, status: result.status }
}

describe('releaseSummary', () => {
  it('refuses no value, an empty value and white space only', () => {
    expect(releaseSummary(undefined)).toEqual({ message: EMPTY, ok: false })
    expect(releaseSummary('')).toEqual({ message: EMPTY, ok: false })
    expect(releaseSummary('  \n\t ')).toEqual({ message: EMPTY, ok: false })
  })

  it('gives the trimmed summary and a blank line', () => {
    expect(releaseSummary('  Bifrost now warns you.  \n')).toEqual({
      ok: true,
      text: 'Bifrost now warns you.\n\n',
    })
  })

  it('accepts a summary of 600 characters', () => {
    const text = 'a'.repeat(SUMMARY_MAX)
    expect(SUMMARY_MAX).toBe(600)
    expect(releaseSummary(` ${text} `)).toEqual({ ok: true, text: `${text}\n\n` })
  })

  it('counts each character one time, also one that takes two UTF-16 units', () => {
    const text = '🙂'.repeat(SUMMARY_MAX)
    expect(releaseSummary(text)).toEqual({ ok: true, text: `${text}\n\n` })
  })

  it('refuses a summary of more than 600 characters with a clear message', () => {
    expect(releaseSummary('a'.repeat(SUMMARY_MAX + 1))).toEqual({
      message: 'The release summary has 601 characters. The limit is 600. Write a shorter summary.',
      ok: false,
    })
  })
})

describe('the summary script', () => {
  it('prints the summary and a blank line', () => {
    expect(runScript('  A short summary.  ')).toEqual({
      err: '',
      out: 'A short summary.\n\n',
      status: 0,
    })
  })

  it('fails with the message and prints nothing when the summary is missing or empty', () => {
    for (const value of [undefined, '', '   ']) {
      const result = runScript(value)
      expect(result.status).toBe(1)
      expect(result.out).toBe('')
      expect(result.err).toContain(EMPTY)
    }
  })

  it('fails with the message for a summary that is too long', () => {
    const result = runScript('b'.repeat(SUMMARY_MAX + 5))
    expect(result.status).toBe(1)
    expect(result.out).toBe('')
    expect(result.err).toContain('The release summary has 605 characters. The limit is 600.')
  })
})
