import { describe, expect, it, vi } from 'vitest'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import { createGh, GH_MAX_BUFFER, GH_TIMEOUT_MS, ghFailure } from '../../../src/main/reviews/gh'
import { REASON_GH_OVERFLOW, REASON_GH_TIMEOUT } from '../../../src/shared/reviews'

const res = (extra: Partial<ExecResult>): ExecResult => ({
  code: 1,
  stderr: '',
  stdout: '',
  ...extra,
})

describe('createGh', () => {
  it('runs the bare name gh with the env, the timeout and the buffer', async () => {
    const exec = vi.fn<ExecFn>(async () => res({ code: 0, stdout: 'x' }))
    const env = { PATH: '/bin' }
    const gh = createGh({ env: async () => env, exec })
    const out = await gh.run(['api', 'user'])
    expect(out.stdout).toBe('x')
    expect(exec).toHaveBeenCalledWith('gh', ['api', 'user'], {
      env,
      maxBuffer: 16777216,
      timeoutMs: 30000,
    })
    expect(GH_TIMEOUT_MS).toBe(30_000)
    expect(GH_MAX_BUFFER).toBe(16 * 1024 * 1024)
  })

  it('passes a folder and a shorter timeout when given', async () => {
    const exec = vi.fn<ExecFn>(async () => res({ code: 0 }))
    const gh = createGh({ env: async () => ({}), exec })
    await gh.run(['pr', 'view'], { cwd: '/w', timeoutMs: 5000 })
    expect(exec).toHaveBeenCalledWith('gh', ['pr', 'view'], {
      cwd: '/w',
      env: {},
      maxBuffer: GH_MAX_BUFFER,
      timeoutMs: 5000,
    })
  })

  it('passes input to exec when given', async () => {
    const exec = vi.fn<ExecFn>(async () => res({ code: 0 }))
    const gh = createGh({ env: async () => ({}), exec })
    await gh.run(['api', '--input', '-'], { input: '{}' })
    expect(exec).toHaveBeenCalledWith('gh', ['api', '--input', '-'], {
      env: {},
      input: '{}',
      maxBuffer: GH_MAX_BUFFER,
      timeoutMs: GH_TIMEOUT_MS,
    })
  })
})

describe('ghFailure', () => {
  it('gives null for code 0', () => {
    expect(ghFailure(res({ code: 0 }))).toBeNull()
  })

  it('maps ENOENT to no-gh', () => {
    const f = ghFailure(res({ stderr: 'spawn gh ENOENT' }))
    expect(f?.availability).toBe('no-gh')
    expect(f?.message).toBe(
      "GitHub CLI (gh) isn't installed. Install it with Homebrew (brew install gh), log in with " +
        'gh auth login, then click Refresh.',
    )
  })

  it('maps exit code 4 to logged-out', () => {
    expect(ghFailure(res({ code: 4 }))?.availability).toBe('logged-out')
  })

  it('maps a gh auth login hint to logged-out', () => {
    const f = ghFailure(
      res({ stderr: 'To get started with GitHub CLI, please run:  gh auth login' }),
    )
    expect(f?.availability).toBe('logged-out')
  })

  it('maps a timeout to error with the timeout text', () => {
    expect(ghFailure(res({ timedOut: true }))).toEqual({
      availability: 'error',
      message: REASON_GH_TIMEOUT,
    })
  })

  it('cuts the first stderr line at 200 characters', () => {
    const f = ghFailure(res({ stderr: `${'a'.repeat(300)}\nsecond` }))
    expect(f?.availability).toBe('error')
    expect(f?.message).toBe('a'.repeat(200))
    expect(f?.detail).toBe('a'.repeat(200))
  })
})

describe('ghFailure overflow', () => {
  it('gives its own reason when Node stopped gh at the buffer limit', () => {
    const f = ghFailure(res({ overflow: true, stderr: 'stdout maxBuffer length exceeded' }))
    expect(f).toEqual({ availability: 'error', message: REASON_GH_OVERFLOW })
  })
})
