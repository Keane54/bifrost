import { expect, test } from 'vitest'
import { isSendKey, sendBody } from '../../../src/renderer/src/terminal/bracketed-paste'

test('sendBody with bracketed paste puts the lines between the markers, with CR line breaks', () => {
  expect(sendBody('line one\nline two', true)).toBe('\x1b[200~line one\rline two\x1b[201~\r')
  expect(sendBody('a\r\nb\nc', true)).toBe('\x1b[200~a\rb\rc\x1b[201~\r')
})

test('sendBody without bracketed paste sends the text as typed and then CR', () => {
  expect(sendBody('hello', false)).toBe('hello\r')
  expect(sendBody('a\nb', false)).toBe('a\nb\r')
})

test('isSendKey: Enter sends, Shift+Enter and composition do not', () => {
  expect(isSendKey({ isComposing: false, key: 'Enter', shiftKey: false })).toBe(true)
  expect(isSendKey({ isComposing: false, key: 'Enter', shiftKey: true })).toBe(false)
  expect(isSendKey({ isComposing: true, key: 'Enter', shiftKey: false })).toBe(false)
  expect(isSendKey({ isComposing: false, key: 'a', shiftKey: false })).toBe(false)
})
