import { EventEmitter } from 'node:events'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'

// A fake Notification. The test makes it emit failed when macOS refuses the notification.
const made: FakeNotification[] = []
class FakeNotification extends EventEmitter {
  static isSupported(): boolean {
    return true
  }
  constructor(readonly options: { silent?: boolean }) {
    super()
    made.push(this)
  }
  show(): void {}
}
vi.mock('electron', () => ({ Notification: FakeNotification }))

const { showNotification } = await import('../../../src/main/alerts/notifier')

describe('showNotification', () => {
  beforeEach(() => {
    made.length = 0
    vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.spyOn(console, 'log').mockImplementation(() => {})
  })
  afterEach(() => vi.restoreAllMocks())

  test('a refused notification calls onFailed', () => {
    const onFailed = vi.fn()
    showNotification({ body: 'b', sessionId: 's1', title: 't' }, () => {}, onFailed)
    made[0]?.emit('failed', {}, 'denied')
    expect(onFailed).toHaveBeenCalledTimes(1)
  })

  test('a shown notification does not call onFailed', () => {
    const onFailed = vi.fn()
    showNotification({ body: 'b', sessionId: 's1', title: 't' }, () => {}, onFailed)
    made[0]?.emit('show')
    expect(onFailed).not.toHaveBeenCalled()
  })

  test('the log line of a shown notification names its label', () => {
    const log = vi.mocked(console.log)
    showNotification({ body: 'b', label: 'review requests', sessionId: null, title: 't' }, () => {})
    made[0]?.emit('show')
    expect(log).toHaveBeenCalledWith('Bifrost showed a notification for review requests.')
    showNotification({ body: 'b', sessionId: 's1', title: 't' }, () => {})
    made[1]?.emit('show')
    expect(log).toHaveBeenCalledWith('Bifrost showed a notification for s1.')
    showNotification({ body: 'b', sessionId: null, title: 't' }, () => {})
    made[2]?.emit('show')
    expect(log).toHaveBeenCalledWith('Bifrost showed a notification for a summary.')
  })

  test('a notification is silent by default', () => {
    showNotification({ body: 'b', sessionId: null, title: 't' }, () => {})
    showNotification({ body: 'b', sessionId: null, sound: false, title: 't' }, () => {})
    expect(made.map(note => note.options.silent)).toEqual([true, true])
  })

  test('a notification with sound is not silent', () => {
    showNotification({ body: 'b', sessionId: null, sound: true, title: 't' }, () => {})
    expect(made[0]?.options.silent).toBe(false)
  })

  test('a refused notification works with no onFailed', () => {
    showNotification({ body: 'b', sessionId: null, title: 't' }, () => {})
    expect(() => made[0]?.emit('failed', {}, 'denied')).not.toThrow()
  })

  test('a refused notification logs one line for each run of the app', async () => {
    vi.resetModules()
    const { showNotification: show } = await import('../../../src/main/alerts/notifier')
    const onFailed = vi.fn()
    show({ body: 'b', sessionId: null, title: 't' }, () => {}, onFailed)
    show({ body: 'b', sessionId: null, title: 't' }, () => {}, onFailed)
    made.at(-2)?.emit('failed', {}, 'denied')
    made.at(-1)?.emit('failed', {}, 'denied')
    expect(onFailed).toHaveBeenCalledTimes(2)
    expect(vi.mocked(console.error)).toHaveBeenCalledTimes(1)
  })
})
