// The fake prompt follows the facts that a spike measured in Claude's prompt: one DEL removes the
// last grapheme of the prompt, a DEL on an empty prompt does nothing, and a mark in a later write
// joins the last character. Each write is checked against the rules of the typing engine.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  createTyper,
  DEL,
  MAX_WRITE_DELETES,
  MAX_WRITE_TEXT,
  planEdit,
  type TyperDeps,
  WRITE_GAP_MS,
} from '../../../src/renderer/src/chat/dictation-typing'

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
const split = (text: string): string[] => Array.from(segmenter.segment(text), s => s.segment)
const count = (text: string): number => split(text).length

// 48 graphemes, 55 code points and 62 UTF-16 units, as the mixed sentence of the spike.
const MIXED = 'Fix the café bug ❤\uFE0F 👍🏽 in 中文 🇬🇧 now 👨\u200D👩\u200D👧 ok, all done.'
const FAMILY = '👨\u200D👩\u200D👧'

// The DELs at the start of a write, and the text after them.
function parts(data: string): { deletes: number; text: string } {
  let deletes = 0
  while (data[deletes] === DEL) deletes++
  return { deletes, text: data.slice(deletes) }
}

// The spike asks for 10 ms or more between two writes.
const MIN_GAP_MS = 10

// A chat window with the text of the user in the prompt. A write that breaks a rule throws.
function setup(user = '', lastSent = user) {
  let prompt = user
  const writes: { at: number; data: string }[] = []
  const lastSentSpy = vi.fn(() => lastSent)
  const deps: TyperDeps = {
    after(ms, fn) {
      const timer = setTimeout(fn, ms)
      return () => clearTimeout(timer)
    },
    lastSent: lastSentSpy,
    write(data) {
      const now = Date.now()
      const last = writes.at(-1)
      // The spike found about 0.25 ms of work in Claude for each DEL.
      if (last && now - last.at < MIN_GAP_MS + parts(last.data).deletes / 4) {
        throw new Error('two writes too close')
      }
      writes.push({ at: now, data })
      const { deletes, text } = parts(data)
      if (data === '') throw new Error('an empty write')
      if (text.includes(DEL)) throw new Error('a DEL after the text')
      if (/\p{Cc}/u.test(text)) throw new Error('a control character in the text')
      if (text.length > MAX_WRITE_TEXT && count(text) > 1) throw new Error('too much text')
      if (deletes > MAX_WRITE_DELETES) throw new Error('too many DELs')
      for (let i = 0; i < deletes; i++) prompt = split(prompt).slice(0, -1).join('')
      prompt += text
      if (!prompt.startsWith(user)) throw new Error('the text of the user changed')
    },
  }
  const typer = createTyper(deps)
  return {
    data: () => writes.map(w => w.data),
    dictated: () => prompt.slice(user.length),
    lastSentSpy,
    prompt: () => prompt,
    typer,
    writes,
  }
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('planEdit', () => {
  it('keeps the common start and changes only the end of the last word', () => {
    expect(planEdit('Fix the parcer', 'Fix the parser')).toEqual({ deletes: 3, insert: 'ser' })
  })

  it('adds the end of a longer guess', () => {
    expect(planEdit('Fix the', 'Fix the bug')).toEqual({ deletes: 0, insert: ' bug' })
  })

  it('removes the end of a shorter guess', () => {
    expect(planEdit('Fix the bug now', 'Fix the bug')).toEqual({ deletes: 4, insert: '' })
  })

  it('has nothing to do for the same text, and works from and to an empty text', () => {
    expect(planEdit('Fix it', 'Fix it')).toEqual({ deletes: 0, insert: '' })
    expect(planEdit('', 'Fix it')).toEqual({ deletes: 0, insert: 'Fix it' })
    expect(planEdit('Fix it', '')).toEqual({ deletes: 6, insert: '' })
  })

  it('gives one DEL for each grapheme (the values of the spike)', () => {
    const typed = ['abé', 'ab❤\uFE0F', `ab${FAMILY}`, 'ab🇬🇧', 'abe\u0301', 'ab中']
    for (const text of typed) expect(planEdit(text, 'ab')).toEqual({ deletes: 1, insert: '' })
    expect(planEdit('cafe', 'café')).toEqual({ deletes: 1, insert: 'é' })
  })

  it('types the whole grapheme again when only a mark or a modifier changes', () => {
    expect(planEdit('cafe', 'cafe\u0301')).toEqual({ deletes: 1, insert: 'e\u0301' })
    expect(planEdit('caf\u00e9', 'cafe\u0301')).toEqual({ deletes: 1, insert: 'e\u0301' })
    expect(planEdit('ab👍', 'ab👍🏽')).toEqual({ deletes: 1, insert: '👍🏽' })
  })

  it('needs 48 DELs for a text of 48 graphemes', () => {
    expect([count(MIXED), [...MIXED].length, MIXED.length]).toEqual([48, 55, 62])
    expect(planEdit(MIXED, '')).toEqual({ deletes: 48, insert: '' })
  })

  it('corrects emoji and CJK by whole graphemes', () => {
    expect(planEdit('我想要咖啡 ☕\uFE0F', '我想要茶 🍵')).toEqual({ deletes: 4, insert: '茶 🍵' })
  })
})

describe('createTyper', () => {
  it('types the words as they come and corrects only the changed end', () => {
    const t = setup()
    t.typer.update('', 'Add a')
    vi.advanceTimersByTime(WRITE_GAP_MS)
    t.typer.update('', 'Add a test')
    vi.advanceTimersByTime(WRITE_GAP_MS)
    t.typer.update('', 'Add a text')
    vi.runAllTimers()
    expect(t.data()).toEqual(['Add a', ' test', `${DEL.repeat(2)}xt`])
    expect(t.prompt()).toBe('Add a text')
  })

  it('never deletes final text in an update', () => {
    const t = setup()
    t.typer.update('Fix the bug.', '')
    vi.runAllTimers()
    t.typer.update('Fix the bug.', ' Then ran')
    vi.runAllTimers()
    t.typer.update('Fix the bug. Then run', '')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Fix the bug. Then run')
    const before = t.writes.length
    // A text that removes final words is not used.
    t.typer.update('Fix the', ' bag')
    t.typer.update('', 'Fix')
    vi.runAllTimers()
    expect(t.writes).toHaveLength(before)
    expect(t.prompt()).toBe('Fix the bug. Then run')
    t.typer.update('Fix the bug. Then run', ' the tests')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Fix the bug. Then run the tests')
  })

  it('ends with exactly the final text of the end', () => {
    const cases: { updates: [string, string][]; final: string }[] = [
      // The end adds the last words.
      { final: 'Add a test that checks it.', updates: [['Add a test', ' that']] },
      // The end drops a guessed word.
      { final: 'Add a test that', updates: [['Add a test', ' that um']] },
      // The end changes a final word. The end is the text of the recognizer.
      { final: 'Add a test.', updates: [['Add a tent.', '']] },
      // macOS 13 to 15: no final part until the end.
      {
        final: 'Add a test.',
        updates: [
          ['', 'Add a'],
          ['', 'And a test'],
        ],
      },
    ]
    for (const c of cases) {
      const t = setup('Please ', 'Please ')
      for (const [final, volatile] of c.updates) {
        t.typer.update(final, volatile)
        vi.runAllTimers()
      }
      t.typer.finish(c.final)
      vi.runAllTimers()
      expect(t.prompt()).toBe(`Please ${c.final}`)
    }
  })

  it('types all the final text when no text event came', () => {
    const t = setup()
    t.typer.finish('Add a test.')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Add a test.')
  })

  it('removes only its own text when the final text is empty', () => {
    const t = setup('Keep this', 'Keep this')
    t.typer.update('', 'um')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Keep this um')
    t.typer.finish('')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Keep this')
    expect(t.data().at(-1)).toBe(DEL.repeat(3))
  })

  it('does nothing after finish', () => {
    const t = setup()
    t.typer.finish('Done.')
    vi.runAllTimers()
    t.typer.update('Other', ' words')
    t.typer.finish('Other')
    vi.runAllTimers()
    expect(t.data()).toEqual(['Done.'])
  })

  it('corrects accents, emoji and CJK to exactly the text of the recognizer', () => {
    const t = setup('Note: ', 'Note: ')
    const steps: [string, string][] = [
      ['', 'Le café ❤\uFE0F'],
      ['', 'Le cafe'],
      ['', `Le cafe\u0301 ${FAMILY} 🇬🇧`],
      ['Le cafe\u0301', ' 🇬🇧 中文 한국어'],
      ['Le cafe\u0301 🇬🇧', ' 日本語 👍🏽'],
    ]
    for (const [final, volatile] of steps) {
      t.typer.update(final, volatile)
      vi.runAllTimers()
      expect(t.dictated()).toBe(final + volatile)
    }
    t.typer.finish('Le cafe\u0301 🇬🇧 日本語 👍🏽.')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Note: Le cafe\u0301 🇬🇧 日本語 👍🏽.')
  })

  it('removes the mixed sentence of 48 graphemes with 48 DELs', () => {
    const t = setup('Keep ', 'Keep ')
    t.typer.update('', MIXED)
    vi.runAllTimers()
    t.typer.finish('')
    vi.runAllTimers()
    expect(t.data().at(-1)).toBe(DEL.repeat(48))
    expect(t.prompt()).toBe('Keep ')
  })

  it('corrects the end of a long line that the terminal wraps', () => {
    const t = setup()
    const long = 'word '.repeat(40)
    t.typer.update('', `${long}parcer`)
    vi.runAllTimers()
    t.typer.update('', `${long}parser`)
    vi.runAllTimers()
    expect(t.data().at(-1)).toBe(`${DEL.repeat(3)}ser`)
    expect(t.prompt()).toBe(`${long}parser`)
  })

  it('types a space first unless the last sent text is empty or ends with whitespace', () => {
    const cases: [string, boolean][] = [
      ['Fix', true],
      ['v2', true],
      ['done.', true],
      ['caf\u00e9', true],
      ['cafe\u0301', true],
      ['中', true],
      ['(', true],
      ['Fix ', false],
      ['', false],
      ['\r', false],
      ['\t', false],
      ['❤\uFE0F', true],
      [DEL, true],
    ]
    for (const [lastSent, space] of cases) {
      const t = setup('', lastSent)
      t.typer.update('', 'hello')
      vi.runAllTimers()
      t.typer.update('', 'hello there')
      vi.runAllTimers()
      expect(t.data()).toEqual([space ? ' hello' : 'hello', ' there'])
      expect(t.lastSentSpy).toHaveBeenCalledTimes(1)
    }
  })

  it('reads the last sent text one time, before its own first write', () => {
    // As in the chat window, the last sent text becomes the last write of the typer.
    let lastData = 'Fix'
    const writes: string[] = []
    const typer = createTyper({
      after(ms, fn) {
        const timer = setTimeout(fn, ms)
        return () => clearTimeout(timer)
      },
      lastSent: () => lastData,
      write(data) {
        writes.push(data)
        lastData = data
      },
    })
    // The first write ends with a space. A second read would give no leading space.
    typer.update('', 'the ')
    vi.runAllTimers()
    typer.update('', 'the bug')
    vi.runAllTimers()
    typer.finish('the bug.')
    vi.runAllTimers()
    expect(writes).toEqual([' the ', 'bug', '.'])
  })

  it('types a space before a dictation that starts with /, !, ? or #', () => {
    for (const mark of ['/', '!', '?', '#']) {
      const empty = setup('', '')
      empty.typer.update('', `${mark}help`)
      expect(empty.data()).toEqual([` ${mark}help`])
      const after = setup('Fix', 'Fix')
      after.typer.update('', `${mark}help`)
      expect(after.data()).toEqual([` ${mark}help`])
    }
  })

  it('types no extra space before @, because a space does not stop the file suggestions', () => {
    const empty = setup('', '')
    empty.typer.update('', '@help')
    expect(empty.data()).toEqual(['@help'])
    const after = setup('Fix', 'Fix')
    after.typer.update('', '@help')
    expect(after.data()).toEqual([' @help'])
  })

  it('keeps the space when a correction makes the first word start with /', () => {
    const t = setup('', '')
    t.typer.update('', 'slash help')
    vi.runAllTimers()
    t.typer.update('', '/help')
    vi.runAllTimers()
    expect(t.prompt()).toBe(' /help')
    t.typer.finish('/help me')
    vi.runAllTimers()
    expect(t.prompt()).toBe(' /help me')
  })

  it('types no extra space when the text starts with a space', () => {
    const t = setup('Fix', 'Fix')
    t.typer.update('', ' the bug')
    expect(t.data()).toEqual([' the bug'])
  })

  it('changes line breaks and tabs to spaces and drops other control characters', () => {
    const t = setup()
    t.typer.update('', 'one\ntwo\r\nthree\tfour\rfive')
    vi.runAllTimers()
    expect(t.prompt()).toBe('one two three four five')
    t.typer.finish('ab\x1b[2Jc\x7fd\x08e\x9bf\x00g')
    vi.runAllTimers()
    expect(t.prompt()).toBe('ab[2Jcdefg')
  })

  it('drops format characters, but keeps the joiners of emoji', () => {
    const t = setup()
    t.typer.update('', 'a\u{200B}b\u{FEFF}c\u{AD}d\u{200E}e\u{202E}f')
    vi.runAllTimers()
    expect(t.prompt()).toBe('abcdef')
    t.typer.finish(`ok ${FAMILY}`)
    vi.runAllTimers()
    expect(t.prompt()).toBe(`ok ${FAMILY}`)
    expect(FAMILY).toContain('\u{200D}')
  })

  it('drops marks and joiners at the start, so that they never join the text of the user', () => {
    const t = setup('Fix the ', 'Fix the ')
    t.typer.update('', '\u0301\u200Dbug')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Fix the bug')
    t.typer.finish('')
    vi.runAllTimers()
    expect(t.prompt()).toBe('Fix the ')
  })

  it('splits a long insert at grapheme boundaries into writes of 100 UTF-16 units or less', () => {
    expect(MAX_WRITE_TEXT).toBe(100)
    const words = 'word '.repeat(100)
    const w = setup()
    w.typer.update('', words)
    vi.runAllTimers()
    expect(w.data().map(d => d.length)).toEqual([100, 100, 100, 100, 100])
    expect(w.prompt()).toBe(words)

    const accents = `x${'e\u0301'.repeat(300)}`
    const a = setup()
    a.typer.update('', accents)
    expect(a.data().map(d => d.length)).toEqual([99])
    vi.runAllTimers()
    expect(a.data().map(d => d.length)).toEqual([99, 100, 100, 100, 100, 100, 2])
    expect(a.data().some(d => d.startsWith('\u0301'))).toBe(false)
    expect(a.prompt()).toBe(accents)

    const families = FAMILY.repeat(120)
    const b = setup()
    b.typer.update('', families)
    vi.runAllTimers()
    expect(b.data().map(d => d.length)).toEqual(Array(10).fill(96))
    expect(b.prompt()).toBe(families)
  })

  it('waits the write gap between two writes, and plans each write from the newest text', () => {
    expect(WRITE_GAP_MS).toBeGreaterThanOrEqual(MIN_GAP_MS)
    const t = setup()
    t.typer.update('', 'a')
    t.typer.update('', 'ab')
    t.typer.update('', 'abc')
    expect(t.data()).toEqual(['a'])
    vi.advanceTimersByTime(WRITE_GAP_MS - 1)
    expect(t.data()).toEqual(['a'])
    vi.advanceTimersByTime(1)
    expect(t.data()).toEqual(['a', 'bc'])
    expect(t.writes[1].at - t.writes[0].at).toBe(WRITE_GAP_MS)
  })

  it('sends a long run of DELs in writes of 1000 DELs or less, then the text', () => {
    const t = setup('Keep ', 'Keep ')
    t.typer.update('', 'a'.repeat(1500))
    vi.runAllTimers()
    const before = t.writes.length
    t.typer.finish('b')
    vi.runAllTimers()
    expect(t.data().slice(before).map(parts)).toEqual([
      { deletes: 1000, text: '' },
      { deletes: 500, text: 'b' },
    ])
    expect(t.prompt()).toBe('Keep b')
  })

  it('stops at cancel and keeps what it typed', () => {
    const t = setup()
    t.typer.update('', 'a'.repeat(1000))
    expect(t.writes).toHaveLength(1)
    t.typer.cancel()
    vi.runAllTimers()
    t.typer.update('', 'b')
    t.typer.finish('c')
    vi.runAllTimers()
    expect(t.writes).toHaveLength(1)
    expect(t.prompt()).toBe('a'.repeat(100))
  })

  it('waits the write gap and 1 ms for each 2 DELs after a write with DELs', () => {
    const t = setup('Keep ', 'Keep ')
    t.typer.update('', 'a'.repeat(1500))
    vi.runAllTimers()
    const before = t.writes.length
    t.typer.finish('b')
    expect(t.data().slice(before)).toEqual([DEL.repeat(1000)])
    vi.advanceTimersByTime(WRITE_GAP_MS + 499)
    expect(t.writes).toHaveLength(before + 1)
    vi.advanceTimersByTime(1)
    expect(t.data().slice(before)).toEqual([DEL.repeat(1000), `${DEL.repeat(500)}b`])
  })

  it('keeps live updates fast: the write gap alone after a write with no DELs', () => {
    const t = setup()
    t.typer.update('', 'Fix the parcer')
    t.typer.update('', 'Fix the parser')
    vi.advanceTimersByTime(WRITE_GAP_MS)
    expect(t.data()).toEqual(['Fix the parcer', `${DEL.repeat(3)}ser`])
    // 3 DELs add 2 ms.
    t.typer.update('', 'Fix the parser now')
    vi.advanceTimersByTime(WRITE_GAP_MS + 1)
    expect(t.writes).toHaveLength(2)
    vi.advanceTimersByTime(1)
    expect(t.data().at(-1)).toBe(' now')
    t.typer.update('', 'Fix the parser now and')
    vi.advanceTimersByTime(WRITE_GAP_MS)
    expect(t.data().at(-1)).toBe(' and')
  })

  it('is busy while parts of an edit still wait', () => {
    const t = setup()
    expect(t.typer.busy()).toBe(false)
    t.typer.update('', 'a'.repeat(250))
    expect(t.typer.busy()).toBe(true)
    vi.advanceTimersByTime(WRITE_GAP_MS)
    expect(t.typer.busy()).toBe(true)
    vi.advanceTimersByTime(WRITE_GAP_MS)
    // All parts are written. Only the timer of the gap runs.
    expect(t.writes).toHaveLength(3)
    expect(t.typer.busy()).toBe(false)
    t.typer.update('', 'b')
    expect(t.typer.busy()).toBe(true)
    t.typer.cancel()
    expect(t.typer.busy()).toBe(false)
  })

  it('plans from the typed text for an update or a finish during a DEL split', () => {
    for (const late of ['update', 'finish'] as const) {
      const t = setup('Keep ', 'Keep ')
      t.typer.update('', 'a'.repeat(1500))
      vi.runAllTimers()
      const before = t.writes.length
      t.typer.update('', 'b')
      expect(t.data().slice(before)).toEqual([DEL.repeat(1000)])
      expect(t.typer.busy()).toBe(true)
      const next = `${'a'.repeat(300)}c`
      if (late === 'update') t.typer.update('', next)
      else t.typer.finish(next)
      vi.runAllTimers()
      expect(t.data().slice(before).map(parts)).toEqual([
        { deletes: 1000, text: '' },
        { deletes: 200, text: 'c' },
      ])
      expect(t.prompt()).toBe(`Keep ${next}`)
      expect(t.typer.busy()).toBe(false)
    }
  })

  it('plans from the typed text for an update or a finish during a long insert', () => {
    const shorter = `${'a'.repeat(50)}b`
    const longer = `${'a'.repeat(180)}b`
    const cases: { late: 'update' | 'finish'; next: string; rest: string[] }[] = [
      { late: 'update', next: shorter, rest: [`${DEL.repeat(50)}b`] },
      { late: 'finish', next: shorter, rest: [`${DEL.repeat(50)}b`] },
      { late: 'update', next: longer, rest: [`${'a'.repeat(80)}b`] },
      { late: 'finish', next: longer, rest: [`${'a'.repeat(80)}b`] },
    ]
    for (const c of cases) {
      const t = setup()
      t.typer.update('', 'a'.repeat(250))
      expect(t.data()).toEqual(['a'.repeat(100)])
      if (c.late === 'update') t.typer.update('', c.next)
      else t.typer.finish(c.next)
      vi.runAllTimers()
      expect(t.data()).toEqual(['a'.repeat(100), ...c.rest])
      expect(t.prompt()).toBe(c.next)
    }
  })

  it('writes nothing for an update with no text or no change', () => {
    const t = setup('Fix', 'Fix')
    t.typer.update('', '')
    expect(t.lastSentSpy).not.toHaveBeenCalled()
    t.typer.update('', 'it')
    vi.runAllTimers()
    t.typer.update('', 'it')
    t.typer.update('i', 't')
    vi.runAllTimers()
    expect(t.data()).toEqual([' it'])
  })
})
