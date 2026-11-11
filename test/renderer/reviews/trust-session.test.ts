import { describe, expect, it } from 'vitest'
import { clampSide, startTrustSession } from '../../../src/renderer/src/reviews/trust-session'

function fake(trustResult: Promise<void> = Promise.resolve()) {
  const calls: string[] = []
  let data: (c: string) => void = () => {}
  let end: (e: { repo: string; trusted: boolean }) => void = () => {}
  const api = {
    onTrustData: (cb: (c: string) => void) => {
      calls.push('subscribe-data')
      data = cb
      return () => calls.push('off-data')
    },
    onTrustEnd: (cb: (e: { repo: string; trusted: boolean }) => void) => {
      calls.push('subscribe-end')
      end = cb
      return () => calls.push('off-end')
    },
    trust: (repo: string) => {
      calls.push(`trust ${repo}`)
      return trustResult
    },
    trustClose: () => {
      calls.push('close')
      return Promise.resolve()
    },
    trustResize: (c: number, r: number) => {
      calls.push(`resize ${c}x${r}`)
      return Promise.resolve()
    },
  }
  return { api, calls, emitData: (c: string) => data(c), emitEnd: (e: never) => end(e) }
}

const flush = () => new Promise(r => setTimeout(r, 0))

describe('clampSide', () => {
  it('keeps the size from 2 to 500 as an integer', () => {
    expect(clampSide(0)).toBe(2)
    expect(clampSide(1)).toBe(2)
    expect(clampSide(80.7)).toBe(80)
    expect(clampSide(900)).toBe(500)
    expect(clampSide(Number.NaN)).toBe(2)
  })
})

describe('startTrustSession', () => {
  it('subscribes before trust, and sends the size after trust resolves', async () => {
    const f = fake()
    startTrustSession({
      api: f.api,
      getSize: () => ({ cols: 90, rows: 20 }),
      onData: () => {},
      onEnd: () => {},
      onError: () => {},
      repo: 'a/b',
    })
    expect(f.calls).toEqual(['subscribe-data', 'subscribe-end', 'trust a/b'])
    await flush()
    expect(f.calls.at(-1)).toBe('resize 90x20')
  })

  it('reports a failure and sends no size', async () => {
    const f = fake(Promise.reject(new Error('no')))
    const errors: string[] = []
    startTrustSession({
      api: f.api,
      getSize: () => ({ cols: 90, rows: 20 }),
      onData: () => {},
      onEnd: () => {},
      onError: e => errors.push(String(e)),
      repo: 'a/b',
    })
    await flush()
    expect(errors).toHaveLength(1)
    expect(f.calls.some(c => c.startsWith('resize'))).toBe(false)
  })

  it('ignores the end of another repository, and closes its own session once', () => {
    const f = fake()
    const ends: boolean[] = []
    const close = startTrustSession({
      api: f.api,
      getSize: () => ({ cols: 90, rows: 20 }),
      onData: () => {},
      onEnd: t => ends.push(t),
      onError: () => {},
      repo: 'a/b',
    })
    f.emitEnd({ repo: 'c/d', trusted: true } as never)
    f.emitEnd({ repo: 'a/b', trusted: false } as never)
    expect(ends).toEqual([false])
    close()
    close()
    expect(f.calls.filter(c => c === 'close')).toHaveLength(1)
  })

  it('does not send the size after the session closed', async () => {
    const f = fake()
    const close = startTrustSession({
      api: f.api,
      getSize: () => ({ cols: 90, rows: 20 }),
      onData: () => {},
      onEnd: () => {},
      onError: () => {},
      repo: 'a/b',
    })
    close()
    await flush()
    expect(f.calls.some(c => c.startsWith('resize'))).toBe(false)
  })
})
