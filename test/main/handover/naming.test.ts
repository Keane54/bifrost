import { describe, expect, test } from 'vitest'
import { handOverName, noteFileName } from '../../../src/main/handover/naming'
import { MAX_NAME } from '../../../src/shared/new-session'

describe('handOverName', () => {
  test('a name without a number gets (2)', () => {
    expect(handOverName('fix login', [])).toBe('fix login (2)')
  })

  test('a name with a number gets the next free number (Review Focus 4)', () => {
    expect(handOverName('fix login (2)', ['fix login (3)'])).toBe('fix login (4)')
    expect(handOverName('x (2)', ['x (3)'])).toBe('x (4)')
    expect(handOverName('x (9)', [])).toBe('x (10)')
  })

  test('each taken name is skipped', () => {
    expect(handOverName('fix login', ['fix login (2)', 'fix login (3)', 'fix login'])).toBe(
      'fix login (4)',
    )
  })

  test('a number that is not at the end in the form " (n)" is part of the name', () => {
    expect(handOverName('v(2)', [])).toBe('v(2) (2)')
    expect(handOverName('x (2) y', [])).toBe('x (2) y (2)')
  })

  test('a long name is cut so that the result has 64 characters or less', () => {
    const long = 'a'.repeat(MAX_NAME)
    const name = handOverName(long, [])
    expect(name.length).toBeLessThanOrEqual(MAX_NAME)
    expect(name.endsWith(' (2)')).toBe(true)
    expect(name).toBe(`${'a'.repeat(MAX_NAME - 4)} (2)`)
    // The second hand-over of the cut name gives (3), with the same base.
    expect(handOverName(name, [])).toBe(`${'a'.repeat(MAX_NAME - 4)} (3)`)
    expect(handOverName(`${'a'.repeat(MAX_NAME - 4)} (9)`, [])).toBe(
      `${'a'.repeat(MAX_NAME - 5)} (10)`,
    )
  })

  test('a cut never ends the base with a space or half a character', () => {
    const spaced = `${'a'.repeat(MAX_NAME - 5)} bcdef`
    expect(handOverName(spaced, [])).toBe(`${'a'.repeat(MAX_NAME - 5)} (2)`)
    // An emoji is two UTF-16 code units. The cut does not split it.
    const emoji = `${'a'.repeat(MAX_NAME - 5)}\u{1F600}xyz`
    expect(handOverName(emoji, [])).toBe(`${'a'.repeat(MAX_NAME - 5)} (2)`)
  })
})

describe('noteFileName', () => {
  const at = new Date(2026, 10, 10, 9, 5, 7)

  test('each run of other characters becomes one "-"', () => {
    expect(noteFileName('fix/login: v2', at)).toBe('fix-login-v2-20261110-090507.md')
    expect(noteFileName('a_b.c-d', at)).toBe('a_b.c-d-20261110-090507.md')
  })

  test('an empty name gives "session"', () => {
    expect(noteFileName('', at)).toBe('session-20261110-090507.md')
    expect(noteFileName(' /:* ', at)).toBe('session-20261110-090507.md')
  })

  test('the name has no "-" at the ends', () => {
    expect(noteFileName('--fix login (2)--', at)).toBe('fix-login-2-20261110-090507.md')
  })

  test('the name part has 64 characters or less', () => {
    expect(noteFileName('a'.repeat(100), at)).toBe(`${'a'.repeat(64)}-20261110-090507.md`)
    // The cut does not leave a "-" at the end.
    expect(noteFileName(`${'a'.repeat(63)} b`, at)).toBe(`${'a'.repeat(63)}-20261110-090507.md`)
  })

  test('the time is the local time with two digits for each part', () => {
    expect(noteFileName('x', new Date(2027, 0, 2, 23, 59, 0))).toBe('x-20270102-235900.md')
  })
})
