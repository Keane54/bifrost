import { describe, expect, it } from 'vitest'
import { errorMessage } from '../../../src/renderer/src/lib/error-message'

describe('errorMessage', () => {
  it('gives the message of an Error and the text of another value', () => {
    expect(errorMessage(new Error('refused: no window'))).toBe('refused: no window')
    expect(errorMessage('gone')).toBe('gone')
    expect(errorMessage(42)).toBe('42')
  })
})
