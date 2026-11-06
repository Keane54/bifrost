import { EventEmitter } from 'node:events'
import { describe, expect, it, vi } from 'vitest'
import { createKeyRecording, resetOnPageEnd } from '../../../src/main/settings/key-recording'

describe('createKeyRecording', () => {
  it('set changes the state and builds the menu again only on a change', () => {
    const rebuild = vi.fn()
    const recording = createKeyRecording(rebuild)
    expect(recording.get()).toBe(false)
    recording.set(true)
    expect(recording.get()).toBe(true)
    expect(rebuild).toHaveBeenCalledOnce()
    recording.set(true)
    expect(rebuild).toHaveBeenCalledOnce()
    recording.set(false)
    expect(recording.get()).toBe(false)
    expect(rebuild).toHaveBeenCalledTimes(2)
  })

  it('set refuses a value that is not a boolean (the settings:recording handler)', () => {
    const rebuild = vi.fn()
    const recording = createKeyRecording(rebuild)
    for (const value of ['true', 1, null, undefined, {}]) {
      expect(() => recording.set(value)).toThrow('refused: bad input')
    }
    expect(recording.get()).toBe(false)
    expect(rebuild).not.toHaveBeenCalled()
  })

  it('reset ends a recording and does nothing without one', () => {
    const rebuild = vi.fn()
    const recording = createKeyRecording(rebuild)
    recording.reset()
    expect(rebuild).not.toHaveBeenCalled()
    recording.set(true)
    recording.reset()
    expect(recording.get()).toBe(false)
    expect(rebuild).toHaveBeenCalledTimes(2)
  })
})

describe('resetOnPageEnd', () => {
  it('a new page, a gone render process and a closed window end the recording', () => {
    const webContents = new EventEmitter()
    const win = Object.assign(new EventEmitter(), { webContents })
    const recording = createKeyRecording(() => {})
    resetOnPageEnd(win, recording)
    const ends: Array<[EventEmitter, string]> = [
      [webContents, 'did-navigate'],
      [webContents, 'render-process-gone'],
      [win, 'closed'],
    ]
    for (const [target, event] of ends) {
      recording.set(true)
      target.emit(event)
      expect(recording.get(), event).toBe(false)
    }
  })

  it('other page events do not end the recording', () => {
    const webContents = new EventEmitter()
    const win = Object.assign(new EventEmitter(), { webContents })
    const recording = createKeyRecording(() => {})
    resetOnPageEnd(win, recording)
    recording.set(true)
    webContents.emit('did-finish-load')
    webContents.emit('dom-ready')
    expect(recording.get()).toBe(true)
  })
})
