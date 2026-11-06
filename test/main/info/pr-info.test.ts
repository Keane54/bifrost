import { describe, expect, it } from 'vitest'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import {
  createPrLookup,
  GH_ARGS,
  GH_TIMEOUT_MS,
  PR_CACHE_MS,
  parsePrView,
} from '../../../src/main/info/pr-info'

const OK_JSON = '{"number":12,"title":"Fix","url":"https://github.com/o/r/pull/12","state":"OPEN"}'
const ok = (stdout = OK_JSON): ExecResult => ({ code: 0, stderr: '', stdout })
const fail = (stderr: string, extra: Partial<ExecResult> = {}): ExecResult => ({
  code: 1,
  stderr,
  stdout: '',
  ...extra,
})

describe('parsePrView', () => {
  it('parsePrView reads a PR', () => {
    expect(parsePrView(ok())).toEqual({
      kind: 'pr',
      number: 12,
      state: 'OPEN',
      title: 'Fix',
      url: 'https://github.com/o/r/pull/12',
    })
  })

  it('parsePrView gives none for no pull requests, and the reasons for a missing gh, a timeout and other errors', () => {
    expect(parsePrView(fail('no pull requests found for branch "fix-a"'))).toEqual({ kind: 'none' })
    expect(parsePrView(fail('No Pull Requests Found for branch x'))).toEqual({ kind: 'none' })
    expect(parsePrView(fail('spawn gh ENOENT'))).toEqual({
      kind: 'unavailable',
      reason: "GitHub CLI (gh) isn't installed.",
    })
    expect(parsePrView(fail('', { timedOut: true }))).toEqual({
      kind: 'unavailable',
      reason: "GitHub CLI (gh) didn't answer within 10 seconds.",
    })
    expect(parsePrView(fail('  HTTP 401: bad token\nsecond line  '))).toEqual({
      kind: 'unavailable',
      reason: 'HTTP 401: bad token',
    })
    expect(parsePrView(fail('x'.repeat(300)))).toEqual({
      kind: 'unavailable',
      reason: 'x'.repeat(200),
    })
    expect(parsePrView(fail('  \n'))).toEqual({
      kind: 'unavailable',
      reason: "GitHub CLI (gh) couldn't check for a PR.",
    })
  })

  it('parsePrView refuses a URL that does not start with https://', () => {
    for (const url of ['http://github.com/o/r/pull/12', 'javascript:alert(1)', 12]) {
      const result = parsePrView(
        ok(JSON.stringify({ number: 12, state: 'OPEN', title: 'Fix', url })),
      )
      expect(result.kind).toBe('unavailable')
    }
  })

  it('parsePrView refuses a number that is not whole, a missing title and bad JSON', () => {
    for (const text of [
      '{"number":1.5,"title":"a","url":"https://x/y","state":"OPEN"}',
      '{"number":1,"url":"https://x/y","state":"OPEN"}',
      '{"number":1,"title":"a","url":"https://x/y"}',
      'not json',
      'null',
    ]) {
      expect(parsePrView(ok(text)).kind).toBe('unavailable')
    }
  })
})

function setup() {
  const calls: Parameters<ExecFn>[] = []
  let result: ExecResult = ok()
  let pending: Array<() => void> = []
  let gate = false
  const exec: ExecFn = async (...args) => {
    calls.push(args)
    if (gate) await new Promise<void>(resolve => pending.push(resolve))
    return result
  }
  let time = 1_000_000
  const env = { HOME: '/h', PATH: '/usr/bin' }
  const exists = (dir: string): boolean => dir !== '/gone'
  const lookup = createPrLookup({ env: async () => env, exec, exists, now: () => time })
  return {
    calls,
    env,
    lookup,
    release: () => {
      for (const resolve of pending) resolve()
      pending = []
    },
    setGate: (on: boolean) => {
      gate = on
    },
    setResult: (r: ExecResult) => {
      result = r
    },
    setTime: (t: number) => {
      time = t
    },
  }
}

describe('createPrLookup', () => {
  it('constants hold the values of the plan', () => {
    expect(PR_CACHE_MS).toBe(300_000)
    expect(GH_TIMEOUT_MS).toBe(10_000)
    expect(GH_ARGS).toEqual(['pr', 'view', '--json', 'number,title,url,state'])
  })

  it('lookup runs gh pr view in the cwd with the env', async () => {
    const t = setup()
    const result = await t.lookup.lookup('/p', 'fix-a')
    expect(result.kind).toBe('pr')
    expect(t.calls).toEqual([
      [
        'gh',
        ['pr', 'view', '--json', 'number,title,url,state'],
        { cwd: '/p', env: t.env, timeoutMs: 10000 },
      ],
    ])
  })

  it('lookup without a branch or with a relative cwd runs nothing', async () => {
    const t = setup()
    expect(await t.lookup.lookup('/p', undefined)).toEqual({ kind: 'none' })
    expect(await t.lookup.lookup('p', 'fix-a')).toEqual({ kind: 'none' })
    expect(await t.lookup.lookup('', 'fix-a')).toEqual({ kind: 'none' })
    expect(t.calls).toEqual([])
  })

  it('lookup gives a friendly reason for a folder that is gone and runs nothing', async () => {
    const t = setup()
    expect(await t.lookup.lookup('/gone', 'fix-a')).toEqual({
      kind: 'unavailable',
      reason: "The session folder isn't there any more.",
    })
    expect(t.calls).toEqual([])
  })

  it('lookup keeps a result 5 minutes', async () => {
    const t = setup()
    await t.lookup.lookup('/p', 'fix-a')
    t.setTime(1_000_000 + 299_999)
    await t.lookup.lookup('/p', 'fix-a')
    expect(t.calls).toHaveLength(1)
    t.setTime(1_000_000 + 300_000)
    await t.lookup.lookup('/p', 'fix-a')
    expect(t.calls).toHaveLength(2)
  })

  it('the cache key is the cwd and the branch', async () => {
    const t = setup()
    await t.lookup.lookup('/p', 'fix-a')
    await t.lookup.lookup('/p', 'fix-b')
    await t.lookup.lookup('/q', 'fix-a')
    expect(t.calls).toHaveLength(3)
  })

  it('two lookups at the same time run gh one time', async () => {
    const t = setup()
    t.setGate(true)
    const a = t.lookup.lookup('/p', 'fix-a')
    const b = t.lookup.lookup('/p', 'fix-a')
    // Let the env promise settle so that exec starts.
    await new Promise(resolve => setTimeout(resolve, 0))
    t.release()
    expect(await a).toEqual(await b)
    expect(t.calls).toHaveLength(1)
  })

  it('url gives the cached URL of a PR, else null', async () => {
    const t = setup()
    expect(t.lookup.url('/p', 'fix-a')).toBeNull()
    await t.lookup.lookup('/p', 'fix-a')
    expect(t.lookup.url('/p', 'fix-a')).toBe('https://github.com/o/r/pull/12')
    expect(t.lookup.url('/p', 'fix-b')).toBeNull()
    t.setResult(fail('no pull requests found'))
    t.setTime(1_000_000 + 300_000)
    await t.lookup.lookup('/p', 'fix-a')
    expect(t.lookup.url('/p', 'fix-a')).toBeNull()
  })
})
