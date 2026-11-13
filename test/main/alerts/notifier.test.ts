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

// In a test home, Bifrost shows no macOS notification (user decision, 2026-11-13).
describe('the notifications of a test home', () => {
  beforeEach(() => {
    made.length = 0
    vi.resetModules()
    vi.spyOn(console, 'log').mockImplementation(() => {})
    Reflect.deleteProperty(globalThis, 'bifrostNotifications')
  })
  afterEach(() => {
    vi.restoreAllMocks()
    Reflect.deleteProperty(globalThis, 'bifrostNotifications')
  })

  test('a normal start shows each notification and records none', async () => {
    const notifier = await import('../../../src/main/alerts/notifier')
    notifier.showNotification({ body: 'b', sessionId: 's1', title: 't' }, () => {})
    expect(made).toHaveLength(1)
    expect(notifier.recordedNotifications()).toEqual([])
    expect('bifrostNotifications' in globalThis).toBe(false)
  })

  test('a test home records each notification, shows none and logs one line', async () => {
    const notifier = await import('../../../src/main/alerts/notifier')
    notifier.recordNotifications(true)
    const onClick = vi.fn()
    notifier.showNotification(
      { body: 'b', label: 'review requests', sessionId: null, title: 't' },
      onClick,
    )
    notifier.showNotification({ body: 'c', sessionId: 's1', sound: true, title: 'u' }, onClick)
    expect(made).toHaveLength(0)
    expect(onClick).not.toHaveBeenCalled()
    expect(notifier.recordedNotifications()).toEqual([
      { body: 'b', label: 'review requests', sessionId: null, sound: false, title: 't' },
      { body: 'c', label: null, sessionId: 's1', sound: true, title: 'u' },
    ])
    const log = vi.mocked(console.log)
    expect(log).toHaveBeenCalledWith('Bifrost recorded a notification for review requests.')
    expect(log).toHaveBeenCalledWith('Bifrost recorded a notification for s1.')
  })

  test('a smoke test reads the list as globalThis.bifrostNotifications', async () => {
    const notifier = await import('../../../src/main/alerts/notifier')
    notifier.recordNotifications(true)
    notifier.showNotification({ body: 'b', sessionId: null, title: 't' }, () => {})
    expect((globalThis as { bifrostNotifications?: unknown }).bifrostNotifications).toBe(
      notifier.recordedNotifications(),
    )
  })

  test('recordNotifications(false) shows the notifications again', async () => {
    const notifier = await import('../../../src/main/alerts/notifier')
    notifier.recordNotifications(true)
    notifier.recordNotifications(false)
    notifier.showNotification({ body: 'b', sessionId: null, title: 't' }, () => {})
    expect(made).toHaveLength(1)
    expect(notifier.recordedNotifications()).toEqual([])
  })
})
