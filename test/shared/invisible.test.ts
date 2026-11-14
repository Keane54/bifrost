// The removal of invisible characters (plan Task 10, Modules design 8.4). Heimdall removes them
// from the card texts that it copies and from the text that the user pastes into the prompt box.
import { describe, expect, it } from 'vitest'
import { stripInvisible } from '../../src/shared/invisible'

// The list of the plan, as ranges of code points.
const LISTED: readonly [number, number][] = [
  [0x00ad, 0x00ad],
  [0x034f, 0x034f],
  [0x115f, 0x115f],
  [0x1160, 0x1160],
  [0x180e, 0x180e],
  [0x200b, 0x200f],
  [0x202a, 0x202e],
  [0x2060, 0x2064],
  [0x2066, 0x2069],
  [0x3164, 0x3164],
  [0xfe00, 0xfe0f],
  [0xfeff, 0xfeff],
  [0xe0000, 0xe007f],
]

function listed(): number[] {
  const out: number[] = []
  for (const [from, to] of LISTED) for (let c = from; c <= to; c += 1) out.push(c)
  return out
}

const hex = (c: number): string => `U+${c.toString(16).toUpperCase().padStart(4, '0')}`

describe('stripInvisible', () => {
  it('removes each character of the list', () => {
    const all = listed()
    expect(all).toHaveLength(1 + 1 + 1 + 1 + 1 + 5 + 5 + 5 + 4 + 1 + 16 + 1 + 128)
    for (const c of all) {
      const ch = String.fromCodePoint(c)
      expect(stripInvisible(`a${ch}b`), hex(c)).toBe('ab')
      expect(stripInvisible(`${ch}${ch}`), hex(c)).toBe('')
    }
    expect(stripInvisible(all.map(c => String.fromCodePoint(c)).join(''))).toBe('')
  })

  it('keeps normal text, tabs and new lines', () => {
    const text = 'Plan the week.\n\n- Item one\n\tItem two\r\nÄpfel, café, 日本語, 한국어'
    expect(stripInvisible(text)).toBe(text)
  })

  it('keeps the characters next to the ranges', () => {
    for (const c of [0x00ac, 0x200a, 0x2010, 0x202f, 0x3163, 0xfe10, 0xfefe]) {
      const ch = String.fromCodePoint(c)
      expect(stripInvisible(`a${ch}b`), hex(c)).toBe(`a${ch}b`)
    }
  })

  it('keeps an emoji with no variation selector, and removes the selector of one with it', () => {
    expect(stripInvisible('Done 😀 👍🏽 🎉')).toBe('Done 😀 👍🏽 🎉')
    expect(stripInvisible('I ❤\uFE0F it')).toBe('I ❤ it')
  })

  it('removes U+061C, U+FFA0 and the variation selectors 17 to 256 (ruling P11)', () => {
    for (const c of [0x061c, 0xffa0, 0xe0100, 0xe0150, 0xe01ef]) {
      const ch = String.fromCodePoint(c)
      expect(stripInvisible(`a${ch}b`), hex(c)).toBe('ab')
    }
    // These selectors can hide a whole text after one emoji.
    const hidden = Array.from({ length: 240 }, (_, i) => String.fromCodePoint(0xe0100 + i))
    expect(stripInvisible(`Hi 😀${hidden.join('')}!`)).toBe('Hi 😀!')
  })

  it('removes every default ignorable code point', () => {
    const ignorable = /\p{Default_Ignorable_Code_Point}/u
    const all: string[] = []
    for (let c = 0; c <= 0x10ffff; c += 1) {
      if (c >= 0xd800 && c <= 0xdfff) continue
      const ch = String.fromCodePoint(c)
      if (ignorable.test(ch)) all.push(ch)
    }
    expect(all.length).toBeGreaterThan(4000)
    expect(stripInvisible(all.join(''))).toBe('')
  })

  it('still keeps new lines, tabs and plain emoji', () => {
    const text = 'Line one\nLine two\tend 😀 👍🏽 🎉'
    expect(stripInvisible(text)).toBe(text)
  })

  it('removes direction controls, zero-width characters and tag characters in text', () => {
    expect(stripInvisible('safe\u202Etxt.exe')).toBe('safetxt.exe')
    expect(stripInvisible('ign\u200Bore\u2060 this')).toBe('ignore this')
    const tags = [...'run me'].map(ch => String.fromCodePoint(0xe0000 + ch.charCodeAt(0))).join('')
    expect(stripInvisible(`Hello${tags}.`)).toBe('Hello.')
  })
})
