import { describe, expect, it } from 'vitest'
import {
  CHECK_DELAY_MS,
  CHECK_INTERVAL_MS,
  classifyError,
  locationProblem,
  maskToken,
} from '../../../src/main/updates/rules'

const TOKEN = 'gho_abcdefghijklmnopqrstuvwxyz0123'

describe('check times', () => {
  it('uses 10 seconds and 60 minutes', () => {
    expect(CHECK_DELAY_MS).toBe(10_000)
    expect(CHECK_INTERVAL_MS).toBe(3_600_000)
  })
})

describe('maskToken', () => {
  it('masks the known token', () => {
    expect(maskToken('x gho_abc123 y', 'gho_abc123')).toBe('x *** y')
  })
  it('masks token and Bearer forms with the pattern when the token is null', () => {
    expect(maskToken(`token ${TOKEN} end`, null)).toBe('token *** end')
    expect(maskToken(`Bearer ${TOKEN}`, null)).toBe('Bearer ***')
    expect(maskToken(`a ghp_${'A'.repeat(25)} b`, null)).toBe('a *** b')
  })
  it('masks only the pattern for an empty token', () => {
    expect(maskToken(`keep this ${TOKEN}`, '')).toBe('keep this ***')
    expect(maskToken('nothing here', '')).toBe('nothing here')
  })
  it('masks every occurrence', () => {
    expect(maskToken('gho_abc gho_abc', 'gho_abc')).toBe('*** ***')
  })
})

describe('classifyError', () => {
  it('gives offline when the machine is offline', () => {
    expect(classifyError(new Error('anything'), 'check', false)).toEqual({ kind: 'offline' })
  })
  it('gives offline for network error messages', () => {
    for (const m of [
      'getaddrinfo ENOTFOUND api.github.com',
      'read ECONNRESET',
      'connect ETIMEDOUT',
      'net::ERR_INTERNET_DISCONNECTED',
    ]) {
      expect(classifyError(new Error(m), 'download', true)).toEqual({ kind: 'offline' })
    }
  })
  it('gives github for 401, 403 and 404 in the check phase, because the releases are public', () => {
    for (const code of [401, 403, 404]) {
      expect(classifyError(new Error(`HttpError: ${code}\nbody`), 'check', true)).toEqual({
        cause: 'github',
        detail: `HttpError: ${code}`,
        kind: 'failed',
      })
    }
  })
  it('gives the cause of the phase for a 404 outside the check phase', () => {
    expect(classifyError(new Error('HttpError: 404'), 'download', true)).toMatchObject({
      cause: 'download',
    })
  })
  it('maps checksum and signature errors by phase', () => {
    expect(classifyError(new Error('sha512 checksum mismatch'), 'download', true)).toMatchObject({
      cause: 'download',
    })
    expect(
      classifyError(new Error('code signature did not pass validation'), 'install', true),
    ).toMatchObject({
      cause: 'install',
    })
  })
  it('maps anything else by phase', () => {
    expect(classifyError(new Error('odd'), 'check', true)).toMatchObject({ cause: 'github' })
    expect(classifyError(new Error('odd'), 'download', true)).toMatchObject({ cause: 'download' })
    expect(classifyError(new Error('odd'), 'install', true)).toMatchObject({ cause: 'install' })
  })
  it('keeps the first line, at most 200 characters', () => {
    const r = classifyError(new Error(`${'a'.repeat(300)}\nsecond`), 'check', true)
    expect(r.kind === 'failed' && r.detail).toBe('a'.repeat(200))
    const s = classifyError('plain text\nmore', 'check', true)
    expect(s.kind === 'failed' && s.detail).toBe('plain text')
  })
  it('handles non-error values', () => {
    expect(classifyError(undefined, 'check', true)).toMatchObject({
      cause: 'github',
      detail: '',
      kind: 'failed',
    })
  })
})

describe('locationProblem', () => {
  it('is true for a disk image, a translocated app and a read-only folder', () => {
    expect(locationProblem('/Volumes/Bifrost/Bifrost.app', true)).toBe(true)
    expect(locationProblem('/private/var/folders/x/AppTranslocation/y/d/Bifrost.app', true)).toBe(
      true,
    )
    expect(locationProblem('/Applications/Bifrost.app', false)).toBe(true)
  })
  it('is false for a normal install', () => {
    expect(locationProblem('/Applications/Bifrost.app', true)).toBe(false)
    expect(locationProblem('/Users/dev-user/Applications/Bifrost.app', true)).toBe(false)
  })
})
