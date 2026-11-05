import { describe, expect, test } from 'vitest'
import {
  CR,
  cleanText,
  ESC,
  INTERRUPT_STEPS,
  isSendKey,
  MAX_RENAME,
  MAX_TEXT,
  PASTE_END,
  PASTE_START,
  planText,
  promptBlocks,
  REASON_EMPTY,
  REASON_NAME_LONG,
  REASON_NO_NAME,
  REASON_SLASH_LINES,
  REASON_TOO_LONG,
  RED_BOX_BLOCK,
  renameText,
  SLASH_FORM,
} from '../../src/shared/input'

// The paste body of a plan, or null for a plan that is not a paste.
function pasteBody(text: string): string | null {
  const plan = planText(text)
  if (!plan.ok) return null
  const first = plan.steps[0].data
  if (!first.startsWith(PASTE_START) || !first.endsWith(PASTE_END)) return null
  return first.slice(PASTE_START.length, first.length - PASTE_END.length)
}

describe('the input values', () => {
  test('the markers, the keys and the texts have the values of the spec', () => {
    expect(PASTE_START).toBe('\x1b[200~')
    expect(PASTE_END).toBe('\x1b[201~')
    expect(CR).toBe('\r')
    expect(ESC).toBe('\x1b')
    expect(MAX_TEXT).toBe(20_000)
    expect(MAX_RENAME).toBe(64)
    expect(RED_BOX_BLOCK).toBe('Answer the prompt in the chat window first.')
    expect(INTERRUPT_STEPS).toEqual([{ data: '\x1b', delayMs: 0 }])
  })

  test('the slash form is the paste form of the M4 Task 1 ruling', () => {
    expect(SLASH_FORM).toBe('paste')
  })
})

describe('planText', () => {
  test('planText sends a bracketed paste, then CR after 300 ms', () => {
    expect(planText('Reply with OK')).toEqual({
      ok: true,
      slash: false,
      steps: [
        { data: '\x1b[200~Reply with OK\x1b[201~', delayMs: 0 },
        { data: '\r', delayMs: 300 },
      ],
    })
  })

  test('planText changes each line break in a paste to CR', () => {
    expect(pasteBody('a\nb\r\nc\rd')).toBe('a\rb\rc\rd')
  })

  test('planText removes escape and control characters', () => {
    expect(pasteBody('a\x1b[201~b\x03c\x7fd\u009be\tf')).toBe('a[201~bcde\tf')
  })

  test('planText refuses empty text and never gives a CR alone', () => {
    for (const text of ['', ' \n\t ', '\x1b\x03']) {
      expect(planText(text)).toEqual({ ok: false, reason: 'Type a message first.' })
    }
    expect(REASON_EMPTY).toBe('Type a message first.')
  })

  test('planText trims the text', () => {
    expect(pasteBody('  hi  \n')).toBe('hi')
  })

  test('planText refuses text over 20,000 characters', () => {
    expect(planText('a'.repeat(20_000)).ok).toBe(true)
    expect(planText('a'.repeat(20_001))).toEqual({ ok: false, reason: REASON_TOO_LONG })
    // The limit applies to the text as the user typed it, before the clean-up and the trim.
    expect(planText(`${'a'.repeat(20_000)} `)).toEqual({ ok: false, reason: REASON_TOO_LONG })
    expect(planText(' '.repeat(20_001))).toEqual({ ok: false, reason: REASON_TOO_LONG })
    expect(REASON_TOO_LONG).toBe('The text is too long. The maximum is 20,000 characters.')
  })

  test('planText sends a slash command in the typed form', () => {
    expect(planText('/compact', 'typed')).toEqual({
      ok: true,
      slash: true,
      steps: [
        { data: '/compact', delayMs: 0 },
        { data: '\r', delayMs: 500 },
      ],
    })
    expect(planText('/compact', 'paste')).toEqual({
      ok: true,
      slash: true,
      steps: [
        { data: '\x1b[200~/compact\x1b[201~', delayMs: 0 },
        { data: '\r', delayMs: 300 },
      ],
    })
  })

  test('planText refuses a slash command with a line break', () => {
    for (const form of ['paste', 'typed'] as const) {
      expect(planText('/compact\nnow', form)).toEqual({ ok: false, reason: REASON_SLASH_LINES })
    }
    expect(REASON_SLASH_LINES).toBe('A slash command has one line.')
  })

  test('each plan puts the CR step after a step with text', () => {
    for (const text of ['x', '/x', ' y\n', 'a\x1bb']) {
      for (const form of ['paste', 'typed'] as const) {
        const plan = planText(text, form)
        if (!plan.ok) throw new Error(`no plan for ${JSON.stringify(text)}`)
        expect(plan.steps).toHaveLength(2)
        expect(plan.steps[0].data).not.toBe(CR)
        expect(plan.steps[0].data.length).toBeGreaterThan(0)
        expect(plan.steps[1].data).toBe(CR)
      }
    }
  })
})

describe('cleanText', () => {
  test('cleanText keeps tab and LF and changes CRLF and CR to LF', () => {
    expect(cleanText('a\tb\nc\r\nd\re')).toBe('a\tb\nc\nd\ne')
  })

  test('cleanText removes C0 and C1 control characters and DEL', () => {
    const removed = [
      ...Array.from({ length: 9 }, (_, i) => i),
      ...Array.from({ length: 0x20 - 0x0b }, (_, i) => 0x0b + i).filter(c => c !== 0x0d),
      ...Array.from({ length: 0xa0 - 0x7f }, (_, i) => 0x7f + i),
    ]
    for (const code of removed) {
      expect(cleanText(`a${String.fromCharCode(code)}b`)).toBe('ab')
    }
    // A no-break space (U+00A0) and a dash (U+2014) are not control characters. They stay.
    const kept = `a${String.fromCharCode(0xa0)}b${String.fromCharCode(0x2014)}c`
    expect(cleanText(kept)).toBe(kept)
  })
})

describe('renameText', () => {
  test('renameText gives /rename and the name', () => {
    expect(renameText(' new\n name ')).toEqual({ ok: true, text: '/rename new name' })
    expect(renameText('a\x1b[201~b')).toEqual({ ok: true, text: '/rename a[201~b' })
    expect(renameText('x'.repeat(64))).toEqual({ ok: true, text: `/rename ${'x'.repeat(64)}` })
  })

  test('renameText refuses an empty name and a name over 64 characters', () => {
    expect(renameText(' \n\t\x1b ')).toEqual({ ok: false, reason: REASON_NO_NAME })
    expect(renameText('x'.repeat(65))).toEqual({ ok: false, reason: REASON_NAME_LONG })
    // The 64 character limit applies after the clean-up, so runs of spaces count as one.
    expect(renameText(`a${' '.repeat(100)}b`)).toEqual({ ok: true, text: '/rename a b' })
    expect(renameText(' '.repeat(20_001))).toEqual({ ok: false, reason: REASON_NAME_LONG })
    expect(REASON_NO_NAME).toBe('Type a name first.')
    expect(REASON_NAME_LONG).toBe('The name is too long. The maximum is 64 characters.')
  })
})

describe('promptBlocks', () => {
  test('promptBlocks is true only for a red box of a prompt or of no known cause', () => {
    expect(promptBlocks({ box: 'red', boxReason: 'prompt' })).toBe(true)
    expect(promptBlocks({ box: 'red' })).toBe(true)
    expect(promptBlocks({ box: 'red', boxReason: 'escalated' })).toBe(false)
    expect(promptBlocks({ box: 'red', boxReason: 'error' })).toBe(false)
    expect(promptBlocks({ box: 'yellow' })).toBe(false)
    expect(promptBlocks({ box: 'none' })).toBe(false)
  })
})

test('isSendKey: Enter sends, Shift+Enter and composition do not', () => {
  expect(isSendKey({ isComposing: false, key: 'Enter', shiftKey: false })).toBe(true)
  expect(isSendKey({ isComposing: false, key: 'Enter', shiftKey: true })).toBe(false)
  expect(isSendKey({ isComposing: true, key: 'Enter', shiftKey: false })).toBe(false)
  expect(isSendKey({ isComposing: false, key: 'a', shiftKey: false })).toBe(false)
})
