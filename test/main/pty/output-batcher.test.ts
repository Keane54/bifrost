import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import {
  createOutputBatcher,
  FLUSH_MS,
  MAX_BATCH,
  type OutputBatcher,
  QUIET_MS,
} from '../../../src/main/pty/output-batcher'

let sent: Array<[string, string]>
let b: OutputBatcher

beforeEach(() => {
  vi.useFakeTimers()
  sent = []
  b = createOutputBatcher({ send: (id, data) => sent.push([id, data]) })
})
afterEach(() => vi.useRealTimers())

describe('output batcher', () => {
  test('sends the first chunk after a quiet time at once', () => {
    b.push('chat:a', 'x')
    expect(sent).toEqual([['chat:a', 'x']])
  })

  test('joins the chunks of a burst into one send after FLUSH_MS', () => {
    b.push('chat:a', 'x')
    vi.advanceTimersByTime(1)
    b.push('chat:a', 'y')
    b.push('chat:a', 'z')
    expect(sent).toHaveLength(1)
    vi.advanceTimersByTime(FLUSH_MS)
    expect(sent).toEqual([
      ['chat:a', 'x'],
      ['chat:a', 'yz'],
    ])
  })

  test('sends at once when the waiting text reaches MAX_BATCH', () => {
    b.push('chat:a', 'x')
    vi.advanceTimersByTime(1)
    b.push('chat:a', 'a'.repeat(MAX_BATCH - 1))
    expect(sent).toHaveLength(1)
    b.push('chat:a', 'b')
    expect(sent).toHaveLength(2)
    expect(sent[1][1]).toHaveLength(MAX_BATCH)
    vi.advanceTimersByTime(FLUSH_MS * 4)
    expect(sent).toHaveLength(2)
  })

  test('a key echo after QUIET_MS of no output goes at once', () => {
    b.push('chat:a', 'x')
    vi.advanceTimersByTime(1)
    b.push('chat:a', 'y')
    vi.advanceTimersByTime(QUIET_MS)
    expect(sent).toHaveLength(2)
    b.push('chat:a', 'k')
    expect(sent[2]).toEqual(['chat:a', 'k'])
  })

  test('flush sends the waiting text, and the next chunk after it goes at once', () => {
    b.push('chat:a', 'x')
    vi.advanceTimersByTime(1)
    b.push('chat:a', 'y')
    b.flush('chat:a')
    expect(sent[1]).toEqual(['chat:a', 'y'])
    b.push('chat:a', 'z')
    expect(sent[2]).toEqual(['chat:a', 'z'])
    vi.advanceTimersByTime(FLUSH_MS * 4)
    expect(sent).toHaveLength(3)
  })

  test('flush with nothing waiting sends nothing', () => {
    b.flush('chat:a')
    b.push('chat:a', 'x')
    b.flush('chat:a')
    expect(sent).toHaveLength(1)
  })

  test('keeps the order of each view and keeps the views apart', () => {
    b.push('chat:a', '1')
    b.push('chat:b', '2')
    vi.advanceTimersByTime(1)
    b.push('chat:a', '3')
    b.push('chat:b', '4')
    b.push('chat:a', '5')
    vi.advanceTimersByTime(FLUSH_MS)
    expect(sent).toEqual([
      ['chat:a', '1'],
      ['chat:b', '2'],
      ['chat:a', '35'],
      ['chat:b', '4'],
    ])
  })

  test('keeps multi-byte text whole when chunks join', () => {
    b.push('chat:a', 'x')
    vi.advanceTimersByTime(1)
    b.push('chat:a', 'é\u{1F600}')
    b.push('chat:a', '中')
    vi.advanceTimersByTime(FLUSH_MS)
    expect(sent[1][1]).toBe('é\u{1F600}中')
  })
})
