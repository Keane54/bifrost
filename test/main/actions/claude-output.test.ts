import { describe, expect, test } from 'vitest'
import {
  failure,
  isTrustError,
  parseShortId,
  SHORT_ID,
  trustMessage,
} from '../../../src/main/actions/claude-output'

// The dash (U+2014) of the resume output. Biome writes a \u escape as the character itself.
const DASH = String.fromCharCode(0x2014)

describe('claude output', () => {
  test('parseShortId reads the start and the resume output', () => {
    expect(parseShortId('backgrounded · 4cb23c30 · bifrost-test-main')).toBe('4cb23c30')
    expect(parseShortId(`backgrounded · 57ffb4ce (idle ${DASH} send a prompt to start)`)).toBe(
      '57ffb4ce',
    )
    expect(parseShortId('Starting\nbackgrounded · 0a1b2c3d\nhint')).toBe('0a1b2c3d')
    expect(parseShortId('started 4cb23c30')).toBeNull()
    expect(parseShortId('backgrounded · 4CB23C30')).toBeNull()
    expect(parseShortId('backgrounded · 4cb23c30ff')).toBeNull()
    expect(parseShortId('backgrounded . 4cb23c30')).toBeNull()
    expect(parseShortId('')).toBeNull()
  })

  test('SHORT_ID accepts only 8 lower case hex digits', () => {
    expect(SHORT_ID.test('4cb23c30')).toBe(true)
    expect(SHORT_ID.test('4cb23c3')).toBe(false)
    expect(SHORT_ID.test('4cb23c30 ')).toBe(false)
    expect(SHORT_ID.test('-4cb23c3')).toBe(false)
  })

  test('isTrustError finds the M0 trust text', () => {
    expect(
      isTrustError(
        'Workspace not trusted. Run `claude` in /x once and accept the trust prompt, then retry.',
      ),
    ).toBe(true)
    expect(isTrustError('Starting background service…')).toBe(false)
  })

  test('trustMessage tells the user to accept the trust prompt one time', () => {
    expect(trustMessage('/p')).toBe(
      "Claude Code doesn't trust this folder yet. Run claude in /p once, accept the trust prompt, then try again.",
    )
  })

  test('failure gives the stderr, else the stdout, else the code', () => {
    expect(failure({ code: 1, stderr: ' bad \n', stdout: 'out' }, 'claude stop')).toBe('bad')
    expect(failure({ code: 1, stderr: ' \n', stdout: ' out ' }, 'claude stop')).toBe('out')
    expect(failure({ code: 2, stderr: '', stdout: '' }, 'claude stop')).toBe(
      'claude stop failed with code 2',
    )
    expect(failure({ code: 1, stderr: 'e'.repeat(400), stdout: '' }, 'x')).toBe('e'.repeat(300))
  })

  test('failure does not give only the start banner of the background service', () => {
    const banner = 'Starting background service…'
    expect(failure({ code: 1, stderr: `${banner}\n`, stdout: 'real error' }, 'claude --bg')).toBe(
      'real error',
    )
    expect(failure({ code: 1, stderr: `${banner}\nboom\n`, stdout: 'x' }, 'claude --bg')).toBe(
      'boom',
    )
    expect(failure({ code: 4, stderr: banner, stdout: '' }, 'claude --bg')).toBe(
      'claude --bg failed with code 4',
    )
  })
})
