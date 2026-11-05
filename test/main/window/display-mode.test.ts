import { expect, test, vi } from 'vitest'
import { createModeController, type ModeWindow } from '../../../src/main/window/display-mode'
import type { DisplayMode } from '../../../src/shared/types'

type Event = 'enter-full-screen' | 'leave-full-screen'

// A fake window. It records each call and changes its flags at once.
// The events fire only when the test calls fire().
function fakeWindow(): ModeWindow & { calls: string[]; fire(event: Event): void } {
  let full = false
  let simple = false
  const calls: string[] = []
  const listeners: Record<Event, Array<() => void>> = {
    'enter-full-screen': [],
    'leave-full-screen': [],
  }
  return {
    calls,
    fire(event) {
      const run = listeners[event].splice(0)
      for (const cb of run) cb()
    },
    isFullScreen: () => full,
    isSimpleFullScreen: () => simple,
    once(event, cb) {
      listeners[event].push(cb)
    },
    setFullScreen(on) {
      calls.push(`full:${on}`)
      full = on
    },
    setSimpleFullScreen(on) {
      calls.push(`simple:${on}`)
      simple = on
    },
  }
}

// Let the queued promise steps run.
const tick = (): Promise<void> => new Promise(resolve => setImmediate(resolve))

test('get reads the mode from the window', () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  expect(controller.get()).toBe('window')
  win.setSimpleFullScreen(true)
  expect(controller.get()).toBe('borderless')
  win.setFullScreen(true)
  expect(controller.get()).toBe('fullscreen')
})

test('set to the current mode does nothing', async () => {
  const win = fakeWindow()
  const onChange = vi.fn()
  const controller = createModeController(win, onChange)
  await controller.set('window')
  expect(win.calls).toEqual([])
  expect(onChange).not.toHaveBeenCalled()
})

test('window to borderless calls setSimpleFullScreen(true)', async () => {
  const win = fakeWindow()
  const onChange = vi.fn()
  const controller = createModeController(win, onChange)
  await controller.set('borderless')
  expect(win.calls).toEqual(['simple:true'])
  expect(onChange).toHaveBeenCalledExactlyOnceWith('borderless')
})

test('window to fullscreen waits for enter-full-screen', async () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  let done = false
  const p = controller.set('fullscreen').then(() => {
    done = true
  })
  await tick()
  expect(win.calls).toEqual(['full:true'])
  expect(done).toBe(false)
  win.fire('enter-full-screen')
  await p
  expect(done).toBe(true)
})

test('borderless to fullscreen leaves borderless first', async () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  await controller.set('borderless')
  win.calls.length = 0
  const p = controller.set('fullscreen')
  await tick()
  expect(win.calls).toEqual(['simple:false', 'full:true'])
  win.fire('enter-full-screen')
  await p
})

test('fullscreen to borderless waits for leave-full-screen, then sets borderless', async () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  const enter = controller.set('fullscreen')
  await tick()
  win.fire('enter-full-screen')
  await enter
  win.calls.length = 0
  const p = controller.set('borderless')
  await tick()
  expect(win.calls).toEqual(['full:false'])
  win.fire('leave-full-screen')
  await p
  expect(win.calls).toEqual(['full:false', 'simple:true'])
  expect(controller.get()).toBe('borderless')
})

test('a leave that never comes ends after waitMs', async () => {
  vi.useFakeTimers()
  try {
    const win = fakeWindow()
    win.setFullScreen(true)
    const controller = createModeController(win, () => {}, 3000)
    let done = false
    const p = controller.set('window').then(() => {
      done = true
    })
    await vi.advanceTimersByTimeAsync(2999)
    expect(done).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await p
    expect(done).toBe(true)
  } finally {
    vi.useRealTimers()
  }
})

test('two set calls run one after the other', async () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  const first = controller.set('fullscreen')
  const second = controller.set('borderless')
  await tick()
  // The second call has not started, because the first call waits for the event.
  expect(win.calls).toEqual(['full:true'])
  win.fire('enter-full-screen')
  await tick()
  expect(win.calls).toEqual(['full:true', 'full:false'])
  win.fire('leave-full-screen')
  await Promise.all([first, second])
  expect(win.calls).toEqual(['full:true', 'full:false', 'simple:true'])
})

test('toggleFullscreen goes back to the mode before fullscreen', async () => {
  const win = fakeWindow()
  const controller = createModeController(win, () => {})
  await controller.set('borderless')
  const enter = controller.toggleFullscreen()
  await tick()
  win.fire('enter-full-screen')
  await enter
  expect(controller.get()).toBe('fullscreen')
  const leave = controller.toggleFullscreen()
  await tick()
  win.fire('leave-full-screen')
  await leave
  expect(controller.get()).toBe('borderless')
})

test('toggleFullscreen goes to window when the mode before is unknown', async () => {
  const win = fakeWindow()
  win.setFullScreen(true)
  const controller = createModeController(win, () => {})
  const leave = controller.toggleFullscreen()
  await tick()
  win.fire('leave-full-screen')
  await leave
  expect(controller.get()).toBe('window')
})

test('sync calls onChange only for a new mode', () => {
  const win = fakeWindow()
  const seen: DisplayMode[] = []
  const controller = createModeController(win, mode => seen.push(mode))
  controller.sync()
  expect(seen).toEqual([])
  win.setFullScreen(true)
  controller.sync()
  controller.sync()
  expect(seen).toEqual(['fullscreen'])
  win.setFullScreen(false)
  controller.sync()
  expect(seen).toEqual(['fullscreen', 'window'])
})
