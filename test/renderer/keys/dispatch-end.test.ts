import { describe, expect, it } from 'vitest'
import { atDispatchEnd } from '../../../src/renderer/src/keys/dispatch-end'

// The window of the page is the last target of a key event in the bubble phase. A plain
// EventTarget stands for it here.
function setup(): { win: EventTarget; event: Event; calls: boolean[]; timers: (() => void)[] } {
  return {
    calls: [],
    event: new Event('keydown', { cancelable: true }),
    timers: [],
    win: new EventTarget(),
  }
}

describe('atDispatchEnd', () => {
  it('runs at the end of the dispatch with handled false when no handler took the key', () => {
    const { calls, event, timers, win } = setup()
    atDispatchEnd(
      event,
      win,
      handled => calls.push(handled),
      fn => timers.push(fn),
    )
    expect(calls).toEqual([])
    win.dispatchEvent(event)
    expect(calls).toEqual([false])
  })

  it('gives handled true when an earlier handler called preventDefault, as a popover does', () => {
    const { calls, event, timers, win } = setup()
    win.addEventListener('keydown', ev => ev.preventDefault())
    atDispatchEnd(
      event,
      win,
      handled => calls.push(handled),
      fn => timers.push(fn),
    )
    win.dispatchEvent(event)
    expect(calls).toEqual([true])
  })

  it('never runs when a handler stopped the event before the window', () => {
    const { calls, event, timers, win } = setup()
    atDispatchEnd(
      event,
      win,
      handled => calls.push(handled),
      fn => timers.push(fn),
    )
    // The event did not get to the window. The timer removes the listener.
    for (const timer of timers) timer()
    win.dispatchEvent(event)
    expect(calls).toEqual([])
  })

  it('ignores another event of the same type, and runs one time only', () => {
    const { calls, event, timers, win } = setup()
    atDispatchEnd(
      event,
      win,
      handled => calls.push(handled),
      fn => timers.push(fn),
    )
    win.dispatchEvent(new Event('keydown', { cancelable: true }))
    expect(calls).toEqual([])
    win.dispatchEvent(event)
    win.dispatchEvent(event)
    expect(calls).toEqual([false])
  })
})
