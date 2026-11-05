import { describe, expect, test } from 'vitest'
import {
  claudeFailure,
  failure,
  isTrustError,
  parseKept,
  parseKeptChanges,
  parseShortId,
  SHORT_ID,
  trustMessage,
} from '../../../src/main/actions/claude-output'
import {
  CHANGES_SHORT_ID,
  CHANGES_STDOUT,
  CHANGES_WORKTREE,
  KEPT_DISCARD,
  KEPT_SHORT_ID,
  KEPT_STDOUT,
  KEPT_WORKTREE,
} from '../../fixtures/claude-rm'

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

  test('claudeFailure puts the lead sentence before a raw text of claude (final review M5)', () => {
    const lead = 'Claude Code reported a problem:'
    expect(claudeFailure({ code: 1, stderr: ' bad \n', stdout: 'out' }, 'claude stop')).toBe(
      `${lead} bad`,
    )
    expect(claudeFailure({ code: 1, stderr: ' \n', stdout: ' out ' }, 'claude rm')).toBe(
      `${lead} out`,
    )
    // The raw text keeps its limit. The lead sentence comes in addition.
    expect(claudeFailure({ code: 1, stderr: 'e'.repeat(400), stdout: '' }, 'x')).toBe(
      `${lead} ${'e'.repeat(300)}`,
    )
  })

  test('claudeFailure gives no lead sentence for a text that Bifrost or Node made', () => {
    expect(claudeFailure({ code: 2, stderr: '', stdout: '' }, 'claude stop')).toBe(
      'claude stop failed with code 2',
    )
    const banner = 'Starting background service…'
    expect(claudeFailure({ code: 4, stderr: banner, stdout: '' }, 'claude --bg')).toBe(
      'claude --bg failed with code 4',
    )
    // The app gives a friendly text for the Node text (errors.ts).
    const node = 'Command failed: /Users/x/.local/bin/claude stop abcd1234'
    expect(claudeFailure({ code: 1, stderr: node, stdout: '' }, 'claude stop')).toBe(node)
  })

  test('failure gives the raw text of a command that is not claude', () => {
    expect(failure({ code: 1, stderr: 'LSOpen failed', stdout: '' }, 'open')).toBe('LSOpen failed')
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

  test('parseKept gives the discard value, the short ID and the worktree of the real output', () => {
    expect(parseKept(KEPT_STDOUT)).toEqual({
      discard: KEPT_DISCARD,
      shortId: KEPT_SHORT_ID,
      worktree: KEPT_WORKTREE,
    })
  })

  test('parseKept gives null when the kept line does not give the short ID and the worktree', () => {
    const [kept, ...rest] = KEPT_STDOUT.split('\n')
    const OPEN = String.fromCharCode(0x201c)
    const CLOSE = String.fromCharCode(0x201d)
    const withKept = (line: string) => [line, ...rest].join('\n')
    for (const line of [
      `kept ${KEPT_SHORT_ID}`,
      kept.replace(KEPT_SHORT_ID, KEPT_SHORT_ID.toUpperCase()),
      kept.replace(KEPT_SHORT_ID, KEPT_SHORT_ID.slice(1)),
      kept.replace(KEPT_SHORT_ID, `${KEPT_SHORT_ID}0`),
      kept.replace(DASH, '-'),
      kept.replace(OPEN, '"').replace(CLOSE, '"'),
      kept.replace(KEPT_WORKTREE, ''),
      kept.replace(CLOSE, ''),
      `${kept} and more`,
      kept.replace('its worktree is still at', 'its worktree is at'),
    ]) {
      expect(parseKept(withKept(line))).toBeNull()
    }
    // Two kept lines give no value.
    expect(parseKept(withKept(`${kept}\n${kept}`))).toBeNull()
  })

  test('parseKept gives null for a changed value', () => {
    const [commit, token] = KEPT_DISCARD.split('@')
    for (const value of [
      `${commit.slice(1)}@${token}`,
      `${commit}a@${token}`,
      `${commit}@${token.slice(1)}`,
      `${commit}@${token}0`,
      `${commit.toUpperCase()}@${token}`,
      `${commit}${token}`,
      `${commit}@${token}@${token}`,
      `${commit}@${token};`,
      `${commit}@${token}.`,
      `${commit}@${token}$(id)`,
      `-${commit}@${token}`,
      `${commit.slice(0, 39)}g@${token}`,
    ]) {
      expect(parseKept(KEPT_STDOUT.replace(KEPT_DISCARD, value))).toBeNull()
    }
    // Two different values give no value.
    const other = `${'0'.repeat(40)}@${'1'.repeat(32)}`
    expect(parseKept(`${KEPT_STDOUT}--discard-unpushed ${other}\n`)).toBeNull()
  })

  test('parseKept gives null for other text', () => {
    const discardLine = `claude rm abd71478 --discard-unpushed ${KEPT_DISCARD}`
    for (const text of [
      '',
      'removed abd71478',
      discardLine,
      // The kept line must be at the start of a line.
      `  kept abd71478\n${discardLine}`,
      `not kept abd71478\n${discardLine}`,
      'kept abd71478\nno discard flag here',
      `kept abd71478\n--discard-unpushed\n${KEPT_DISCARD}`,
      `kept abd71478\n--discard-unpushed=${KEPT_DISCARD}`,
    ]) {
      expect(parseKept(text)).toBeNull()
    }
  })

  test('parseKeptChanges gives the short ID and the worktree of the real output', () => {
    expect(parseKeptChanges(CHANGES_STDOUT)).toEqual({
      shortId: CHANGES_SHORT_ID,
      worktree: CHANGES_WORKTREE,
    })
    // The output has no discard value.
    expect(parseKept(CHANGES_STDOUT)).toBeNull()
  })

  test('parseKeptChanges gives null without the kept line or the changes text', () => {
    const [kept, ...rest] = CHANGES_STDOUT.split('\n')
    const OPEN = String.fromCharCode(0x201c)
    const CLOSE = String.fromCharCode(0x201d)
    const withKept = (line: string) => [line, ...rest].join('\n')
    for (const line of [
      `kept ${CHANGES_SHORT_ID}`,
      kept.replace(CHANGES_SHORT_ID, CHANGES_SHORT_ID.toUpperCase()),
      kept.replace(CHANGES_SHORT_ID, CHANGES_SHORT_ID.slice(1)),
      kept.replace(DASH, '-'),
      kept.replace(OPEN, '"').replace(CLOSE, '"'),
      kept.replace(CHANGES_WORKTREE, ''),
      `${kept} and more`,
      `  ${kept}`,
    ]) {
      expect(parseKeptChanges(withKept(line))).toBeNull()
    }
    // The kept line must be the first line, and only one kept line is valid.
    expect(parseKeptChanges(`removed 27b87cbf\n${CHANGES_STDOUT}`)).toBeNull()
    expect(parseKeptChanges(withKept(`${kept}\n${kept}`))).toBeNull()
    // The kept text of a worktree with commits on no remote is not the changes text.
    expect(parseKeptChanges(KEPT_STDOUT)).toBeNull()
    expect(parseKeptChanges(kept)).toBeNull()
    expect(parseKeptChanges(CHANGES_STDOUT.replace('uncommitted changes', 'changes'))).toBeNull()
    expect(parseKeptChanges('')).toBeNull()
    expect(parseKeptChanges('The worktree has uncommitted changes')).toBeNull()
  })
})
