import { describe, expect, it, vi } from 'vitest'
import {
  type LinkDeps,
  linkTarget,
  MAX_LINK_LENGTH,
  openLink,
} from '../../../src/main/pty/open-link'

const HOST = 'devbox.local'

describe('linkTarget', () => {
  it('gives a web target for http and https links', () => {
    expect(linkTarget('https://github.com/a/b/pull/1', HOST)).toEqual({
      kind: 'web',
      url: 'https://github.com/a/b/pull/1',
    })
    expect(linkTarget('http://localhost:5173/', HOST)).toEqual({
      kind: 'web',
      url: 'http://localhost:5173/',
    })
  })

  it('gives a file target for a file link with no host, localhost or the own host', () => {
    expect(linkTarget('file:///Users/dev-user/repo/src/a.ts', HOST)).toEqual({
      kind: 'file',
      path: '/Users/dev-user/repo/src/a.ts',
    })
    expect(linkTarget('file://localhost/tmp/a.txt', HOST)).toEqual({
      kind: 'file',
      path: '/tmp/a.txt',
    })
    expect(linkTarget('file://DEVBOX.local/tmp/a.txt', HOST)).toEqual({
      kind: 'file',
      path: '/tmp/a.txt',
    })
  })

  it('decodes the path and ignores a query or a fragment', () => {
    expect(linkTarget('file:///tmp/my%20notes.md#L12', HOST)).toEqual({
      kind: 'file',
      path: '/tmp/my notes.md',
    })
  })

  it('refuses a file link of another host', () => {
    expect(linkTarget('file://other-mac/tmp/a.txt', HOST)).toBeNull()
  })

  it('refuses other protocols, bad URLs, non-strings and very long links', () => {
    for (const uri of [
      'javascript:alert(1)',
      'mailto:a@b.c',
      'vscode://file/tmp/a.ts',
      'ftp://example.com/a',
      'not a url',
      '',
      42,
      null,
      `https://example.com/${'a'.repeat(MAX_LINK_LENGTH)}`,
    ]) {
      expect(linkTarget(uri, HOST)).toBeNull()
    }
  })
})

function deps(entries: Record<string, { dir: boolean; mode: number }> = {}): LinkDeps & {
  calls: string[]
} {
  const calls: string[] = []
  return {
    calls,
    hostname: () => HOST,
    openExternal: vi.fn(async (url: string) => {
      calls.push(`external ${url}`)
    }),
    openPath: vi.fn(async (path: string) => {
      calls.push(`open ${path}`)
      return ''
    }),
    showItemInFolder: vi.fn((path: string) => {
      calls.push(`reveal ${path}`)
    }),
    stat: vi.fn(async (path: string) => {
      const entry = entries[path]
      if (!entry) throw Object.assign(new Error('missing'), { code: 'ENOENT' })
      return { isDirectory: () => entry.dir, mode: entry.mode }
    }),
  }
}

describe('openLink', () => {
  it('opens a web link in the default browser', async () => {
    const d = deps()
    await openLink('https://example.com/a', d)
    expect(d.calls).toEqual(['external https://example.com/a'])
  })

  it('opens a plain file and a folder with their default app', async () => {
    const d = deps({ '/r/a.ts': { dir: false, mode: 0o644 }, '/r/src': { dir: true, mode: 0o755 } })
    await openLink('file:///r/a.ts', d)
    await openLink('file:///r/src', d)
    expect(d.calls).toEqual(['open /r/a.ts', 'open /r/src'])
  })

  it('shows an app, an executable or a script in Finder and does not run it', async () => {
    const d = deps({
      '/A/Tool.app': { dir: true, mode: 0o755 },
      '/r/go.command': { dir: false, mode: 0o644 },
      '/r/run': { dir: false, mode: 0o755 },
      '/r/x.sh': { dir: false, mode: 0o644 },
      '/r/y.py': { dir: false, mode: 0o644 },
    })
    for (const path of ['/A/Tool.app', '/r/run', '/r/go.command', '/r/x.sh', '/r/y.py']) {
      await openLink(`file://${path}`, d)
    }
    expect(d.calls).toEqual([
      'reveal /A/Tool.app',
      'reveal /r/run',
      'reveal /r/go.command',
      'reveal /r/x.sh',
      'reveal /r/y.py',
    ])
  })

  it('does nothing for a missing file or a refused link', async () => {
    const d = deps()
    await openLink('file:///r/missing.ts', d)
    await openLink('javascript:alert(1)', d)
    expect(d.calls).toEqual([])
  })
})
