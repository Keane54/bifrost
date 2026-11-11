import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  createTrustWindow,
  TRUST_POLL_MS,
  TRUST_SIZE,
  TRUST_VIEW,
  trustedDirs,
  trustedIn,
} from '../../../src/main/reviews/trust'
import { MAX_CLAUDE_JSON_BYTES } from '../../../src/main/usage-alerts/claude-json'

let dir: string
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'bifrost-trust-')))
})
afterEach(async () => {
  vi.useRealTimers()
  await rm(dir, { force: true, recursive: true })
})

const flag = (v: unknown) => ({ projects: { '/a/b': { hasTrustDialogAccepted: v } } })

describe('trustedIn', () => {
  it('handles an exact key, a parent key, a false flag and no projects field', () => {
    expect(trustedIn(flag(true), '/a/b')).toBe(true)
    expect(trustedIn(flag(true), '/a/b/c/d')).toBe(true)
    expect(trustedIn(flag(true), '/a/bc')).toBe(false)
    expect(trustedIn(flag(false), '/a/b')).toBe(false)
    expect(trustedIn(flag('true'), '/a/b')).toBe(false)
    expect(trustedIn({}, '/a/b')).toBe(false)
    expect(trustedIn(null, '/a/b')).toBe(false)
    expect(trustedIn({ projects: 5 }, '/a/b')).toBe(false)
  })
})

describe('trustedDirs', () => {
  it('gives an empty set for a missing file, a file over the cap and bad JSON', async () => {
    const d = join(dir, 'x')
    await mkdir(d)
    expect((await trustedDirs(join(dir, 'none.json'), [d])).size).toBe(0)
    const big = join(dir, 'big.json')
    await writeFile(big, ' '.repeat(MAX_CLAUDE_JSON_BYTES + 1))
    expect((await trustedDirs(big, [d])).size).toBe(0)
    const bad = join(dir, 'bad.json')
    await writeFile(bad, '{nope')
    expect((await trustedDirs(bad, [d])).size).toBe(0)
  })

  it('gives the dirs that are trusted, as given', async () => {
    const a = join(dir, 'a')
    const b = join(dir, 'b')
    await mkdir(a)
    await mkdir(b)
    const file = join(dir, 'c.json')
    await writeFile(file, JSON.stringify({ projects: { [a]: { hasTrustDialogAccepted: true } } }))
    const set = await trustedDirs(file, [a, b, join(dir, 'missing')])
    expect([...set]).toEqual([a])
  })
})

describe('trustedDirs with a link in the path', () => {
  it('matches the key as given and the key as the real path', async () => {
    const real = join(dir, 'real')
    await mkdir(real)
    const link = join(dir, 'link')
    await symlink(real, link)
    const asLink = join(link, 'sub')
    await mkdir(join(real, 'sub'))
    const byLink = join(dir, 'k1.json')
    await writeFile(
      byLink,
      JSON.stringify({ projects: { [link]: { hasTrustDialogAccepted: true } } }),
    )
    expect([...(await trustedDirs(byLink, [asLink]))]).toEqual([asLink])
    const byReal = join(dir, 'k2.json')
    await writeFile(
      byReal,
      JSON.stringify({ projects: { [real]: { hasTrustDialogAccepted: true } } }),
    )
    expect([...(await trustedDirs(byReal, [asLink]))]).toEqual([asLink])
  })
})

function fakePty() {
  return {
    close: vi.fn(),
    open: vi.fn(() => 1),
    resize: vi.fn(),
    write: vi.fn(() => true),
  }
}

describe('createTrustWindow', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  it('opens claude with no arguments in the clone and closes on trust', async () => {
    const pty = fakePty()
    let trusted = false
    const isTrusted = vi.fn(async () => trusted)
    const onEnd = vi.fn()
    const w = createTrustWindow({ isTrusted, onEnd, pty: async () => pty })
    await w.open('o/r', '/clone')
    expect(pty.open).toHaveBeenCalledWith(TRUST_VIEW, [], { cwd: '/clone', ...TRUST_SIZE })
    expect(w.current()).toBe('o/r')
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS)
    expect(isTrusted).toHaveBeenCalledTimes(1)
    expect(onEnd).not.toHaveBeenCalled()
    trusted = true
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS)
    expect(pty.close).toHaveBeenCalledWith(TRUST_VIEW)
    expect(onEnd).toHaveBeenCalledWith({ repo: 'o/r', trusted: true })
    expect(w.current()).toBeNull()
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS * 3)
    expect(isTrusted).toHaveBeenCalledTimes(2)
    w.exited()
    expect(onEnd).toHaveBeenCalledTimes(1)
  })

  it('does not overlap two checks', async () => {
    const pty = fakePty()
    let release: (v: boolean) => void = () => {}
    const isTrusted = vi.fn(() => new Promise<boolean>(r => (release = r)))
    const w = createTrustWindow({ isTrusted, onEnd: vi.fn(), pty: async () => pty })
    await w.open('o/r', '/clone')
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS * 5)
    expect(isTrusted).toHaveBeenCalledTimes(1)
    release(false)
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS)
    expect(isTrusted).toHaveBeenCalledTimes(2)
    w.close()
  })

  it('ends with trusted false on an exit before the trust', async () => {
    const pty = fakePty()
    const onEnd = vi.fn()
    const w = createTrustWindow({ isTrusted: async () => false, onEnd, pty: async () => pty })
    await w.open('o/r', '/clone')
    w.exited()
    expect(onEnd).toHaveBeenCalledWith({ repo: 'o/r', trusted: false })
    expect(w.current()).toBeNull()
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS * 3)
    expect(onEnd).toHaveBeenCalledTimes(1)
  })

  it('closes the first window on a second open, with no onEnd', async () => {
    const pty = fakePty()
    const onEnd = vi.fn()
    const w = createTrustWindow({ isTrusted: async () => false, onEnd, pty: async () => pty })
    await w.open('o/one', '/c1')
    await w.open('o/two', '/c2')
    expect(pty.close).toHaveBeenCalledWith(TRUST_VIEW)
    expect(pty.open).toHaveBeenCalledTimes(2)
    expect(w.current()).toBe('o/two')
    expect(onEnd).not.toHaveBeenCalled()
    w.close()
    expect(w.current()).toBeNull()
    expect(onEnd).not.toHaveBeenCalled()
  })

  it('passes write and resize to the PTY only while a window is open', async () => {
    const pty = fakePty()
    const w = createTrustWindow({
      isTrusted: async () => false,
      onEnd: vi.fn(),
      pty: async () => pty,
    })
    w.write('x')
    expect(pty.write).not.toHaveBeenCalled()
    await w.open('o/r', '/clone')
    w.write('y')
    w.resize(80, 24)
    expect(pty.write).toHaveBeenCalledWith(TRUST_VIEW, 'y')
    expect(pty.resize).toHaveBeenCalledWith(TRUST_VIEW, 80, 24)
    w.close()
  })

  it('ignores a slow check that ends after a close or a second open', async () => {
    const pty = fakePty()
    const resolvers: Array<(v: boolean) => void> = []
    const isTrusted = vi.fn(() => new Promise<boolean>(r => resolvers.push(r)))
    const onEnd = vi.fn()
    const w = createTrustWindow({ isTrusted, onEnd, pty: async () => pty })
    await w.open('o/one', '/c1')
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS)
    w.close()
    resolvers[0](true)
    await vi.advanceTimersByTimeAsync(0)
    expect(onEnd).not.toHaveBeenCalled()
    await w.open('o/one', '/c1')
    await vi.advanceTimersByTimeAsync(TRUST_POLL_MS)
    await w.open('o/two', '/c2')
    resolvers[1](true)
    await vi.advanceTimersByTimeAsync(0)
    expect(onEnd).not.toHaveBeenCalled()
    expect(w.current()).toBe('o/two')
    w.close()
  })
})
