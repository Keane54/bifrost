import { describe, expect, it } from 'vitest'
import { draftParts } from '../../src/shared/daily-markup'

const plain = (text: string) => ({ bold: false, text })
const bold = (text: string) => ({ bold: true, text })

describe('draftParts', () => {
  it('draftParts finds bold parts, keeps lines and leaves a single * as text', () => {
    const draft = '**Daily update**\nI fixed *one* bug and **two** tests.\n\n- 3 * 4 = 12'
    expect(draftParts(draft)).toEqual([
      [bold('Daily update')],
      [plain('I fixed *one* bug and '), bold('two'), plain(' tests.')],
      [],
      [plain('- 3 * 4 = 12')],
    ])
  })

  it('keeps an open or an empty pair as text', () => {
    expect(draftParts('**open and more')).toEqual([[plain('**open and more')]])
    expect(draftParts('a **** b')).toEqual([[plain('a **** b')]])
  })

  it('does not join bold over two lines', () => {
    expect(draftParts('**one\ntwo**')).toEqual([[plain('**one')], [plain('two**')]])
  })

  it('reads a Windows line end', () => {
    expect(draftParts('**a**\r\nb')).toEqual([[bold('a')], [plain('b')]])
  })
})
