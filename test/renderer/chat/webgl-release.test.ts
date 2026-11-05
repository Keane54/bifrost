import { describe, expect, it, vi } from 'vitest'
import {
  addedContexts,
  type ContextCanvas,
  releaseWebgl,
  type WebglContext,
} from '../../../src/renderer/src/chat/webgl-release'

// A WebGL context that records the calls in log. lost gives the state at the start.
function context(log: string[], name: string, lost = false, extension = true): WebglContext {
  let isLost = lost
  return {
    getExtension: () =>
      extension
        ? {
            loseContext: () => {
              log.push(`lose ${name}`)
              isLost = true
            },
          }
        : null,
    isContextLost: () => isLost,
  }
}

// A canvas that gives gl for a WebGL 2 context. It records each getContext call in log.
function canvas(log: string[], name: string, gl: WebglContext | null): ContextCanvas {
  return {
    getContext: () => {
      log.push(`ask ${name}`)
      return gl
    },
  }
}

describe('addedContexts', () => {
  it('gives the WebGL context of each canvas that the load added', () => {
    const log: string[] = []
    const gl = context(log, 'gl')
    const old = canvas(log, 'old', null)
    const webgl = canvas(log, 'webgl', gl)
    const flat = canvas(log, '2d', null)
    expect(addedContexts([old], [old, webgl, flat])).toEqual([gl])
  })

  it('does not ask a canvas that was there before the load for a context', () => {
    // getContext on a canvas with no context starts a new WebGL context.
    const log: string[] = []
    const old = canvas(log, 'old', context(log, 'other'))
    addedContexts([old], [old, canvas(log, 'webgl', context(log, 'gl'))])
    expect(log).toEqual(['ask webgl'])
  })
})

describe('releaseWebgl', () => {
  it('loses each live context before the dispose', () => {
    const log: string[] = []
    releaseWebgl([context(log, 'a'), context(log, 'b')], () => log.push('dispose'))
    expect(log).toEqual(['lose a', 'lose b', 'dispose'])
  })

  it('does not lose a context that is lost already', () => {
    const log: string[] = []
    releaseWebgl([context(log, 'a', true)], () => log.push('dispose'))
    expect(log).toEqual(['dispose'])
  })

  it('disposes without the lose extension and without a context', () => {
    const log: string[] = []
    releaseWebgl([context(log, 'a', false, false)], () => log.push('dispose'))
    releaseWebgl([], () => log.push('dispose'))
    expect(log).toEqual(['dispose', 'dispose'])
  })

  it('loses the next context and disposes when a lose fails', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const log: string[] = []
    const bad: WebglContext = {
      getExtension: () => ({
        loseContext: () => {
          throw new Error('lost')
        },
      }),
      isContextLost: () => false,
    }
    releaseWebgl([bad, context(log, 'b')], () => log.push('dispose'))
    expect(log).toEqual(['lose b', 'dispose'])
    expect(warn).toHaveBeenCalledOnce()
    warn.mockRestore()
  })
})
