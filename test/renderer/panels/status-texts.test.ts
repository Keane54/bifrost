import { describe, expect, it } from 'vitest'
import { statusTexts } from '../../../src/renderer/src/panels/status-texts'

const NONE = { error: null, notice: null, sendFailed: false, sendLine: null }

describe('statusTexts', () => {
  it('gives no line and no kind when no text exists', () => {
    expect(statusTexts(NONE)).toEqual({ kind: null, lines: [] })
  })

  it('gives the info kind for a notice', () => {
    expect(statusTexts({ ...NONE, notice: 'Done.' })).toEqual({ kind: 'info', lines: ['Done.'] })
  })

  it('gives the info kind for a send line that is not a failure', () => {
    expect(statusTexts({ ...NONE, sendLine: 'Sending...' })).toEqual({
      kind: 'info',
      lines: ['Sending...'],
    })
  })

  it('gives the error kind for an actions error', () => {
    expect(statusTexts({ ...NONE, error: 'Bad.' }).kind).toBe('error')
  })

  it('gives the error kind for a failed send', () => {
    expect(statusTexts({ ...NONE, sendFailed: true, sendLine: 'No send.' })).toEqual({
      kind: 'error',
      lines: ['No send.'],
    })
  })

  it('orders the error, then the notice, then the send line', () => {
    expect(statusTexts({ error: 'E', notice: 'N', sendFailed: false, sendLine: 'S' })).toEqual({
      kind: 'error',
      lines: ['E', 'N', 'S'],
    })
  })

  it('ignores empty texts', () => {
    expect(statusTexts({ ...NONE, error: '', notice: '' })).toEqual({ kind: null, lines: [] })
  })
})
