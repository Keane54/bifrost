import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  CACHE_MS,
  createReleaseNotesSource,
  FETCH_TIMEOUT_MS,
  fileFetch,
  MAX_BODY_BYTES,
  RELEASES_API,
  RELEASES_PAGE,
} from '../../../src/main/release-notes/source'

const entry = (tag: string): Record<string, unknown> => ({
  body: 'Summary.\n\n### Features\n\n* **a:** add b ([abc1234](u))\n',
  draft: false,
  html_url: `https://github.com/Keane54/bifrost/releases/tag/${tag}`,
  prerelease: false,
  published_at: '2026-11-10T18:10:26Z',
  tag_name: tag,
})

const ANSWER = [entry('v0.5.0'), entry('v0.4.0')]

function jsonResponse(data: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(data), { status: 200, ...init })
}

type FetchFn = (url: string, init: RequestInit) => Promise<Response>

function setup(fetch: FetchFn) {
  let now = 1_000_000
  const log = vi.fn()
  const fetchSpy = vi.fn(fetch)
  const source = createReleaseNotesSource({ fetch: fetchSpy, log, now: () => now })
  return {
    advance: (ms: number) => {
      now += ms
    },
    fetchSpy,
    log,
    source,
  }
}

describe('the constants', () => {
  it('reads 10 releases of the repo of the updater, with a 10 s timeout and a 2 MB limit', () => {
    expect(RELEASES_API).toBe('https://api.github.com/repos/Keane54/bifrost/releases?per_page=10')
    expect(RELEASES_PAGE).toBe('https://github.com/Keane54/bifrost/releases')
    expect(FETCH_TIMEOUT_MS).toBe(10_000)
    expect(MAX_BODY_BYTES).toBe(2_000_000)
    expect(CACHE_MS).toBe(10 * 60_000)
  })
})

describe('createReleaseNotesSource', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('asks GitHub with no token, the two headers, no redirect and a timeout of 10 s', async () => {
    const timeout = vi.spyOn(AbortSignal, 'timeout')
    const { fetchSpy, source } = setup(async () => jsonResponse(ANSWER))
    const result = await source.list()
    expect(result.ok && result.releases.map(r => r.version)).toEqual(['0.5.0', '0.4.0'])
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const [url, init] = fetchSpy.mock.calls[0] ?? []
    expect(url).toBe(RELEASES_API)
    expect(init?.headers).toEqual({
      Accept: 'application/vnd.github+json',
      'User-Agent': 'Bifrost',
    })
    expect(init?.redirect).toBe('error')
    expect(init?.credentials).toBe('omit')
    expect(timeout).toHaveBeenCalledTimes(1)
    expect(timeout).toHaveBeenCalledWith(10_000)
    expect(init?.signal).toBe(timeout.mock.results[0]?.value)
    expect(JSON.stringify(init)).not.toMatch(/authorization|token/i)
  })

  it('keeps the last good answer for 10 minutes', async () => {
    const { advance, fetchSpy, source } = setup(async () => jsonResponse(ANSWER))
    await source.list()
    advance(CACHE_MS - 1)
    await source.list()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    advance(1)
    await source.list()
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it('shares one request between two calls at the same time', async () => {
    const { fetchSpy, source } = setup(async () => jsonResponse(ANSWER))
    const [a, b] = await Promise.all([source.list(), source.list()])
    expect(a).toEqual(b)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('gives an error and keeps nothing for a bad answer, and never rejects', async () => {
    const bad: Array<() => Promise<Response>> = [
      async () => jsonResponse({ message: 'Not Found' }, { status: 404 }),
      async () => jsonResponse({ message: 'rate limit' }, { status: 403 }),
      async () => new Response('{not json', { status: 200 }),
      async () => jsonResponse({ releases: [] }),
      async () => {
        throw new Error('net::ERR_INTERNET_DISCONNECTED')
      },
      async () => {
        throw new TypeError('redirect mode is set to error')
      },
    ]
    for (const fetch of bad) {
      const { fetchSpy, log, source } = setup(fetch)
      await expect(source.list()).resolves.toEqual({ ok: false })
      expect(log).toHaveBeenCalledTimes(1)
      // Nothing was kept, so the next open asks again.
      await source.list()
      expect(fetchSpy).toHaveBeenCalledTimes(2)
    }
  })

  it('refuses an answer over 2 MB by its length, before the read', async () => {
    const big = new Response('[]', {
      headers: { 'content-length': String(MAX_BODY_BYTES + 1) },
      status: 200,
    })
    const { source } = setup(async () => big)
    await expect(source.list()).resolves.toEqual({ ok: false })
  })

  it('stops the read of an answer that gets past 2 MB with no length', async () => {
    const chunk = new Uint8Array(512 * 1024).fill(32)
    let sent = 0
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        sent += chunk.byteLength
        controller.enqueue(chunk)
        if (sent > 4 * MAX_BODY_BYTES) controller.close()
      },
    })
    const { source } = setup(async () => new Response(stream, { status: 200 }))
    await expect(source.list()).resolves.toEqual({ ok: false })
    expect(sent).toBeLessThan(2 * MAX_BODY_BYTES)
  })

  it('gives the good answer within 10 minutes, and an error for a failure after that', async () => {
    let fail = false
    const { advance, fetchSpy, source } = setup(async () => {
      if (fail) throw new Error('offline')
      return jsonResponse(ANSWER)
    })
    const first = await source.list()
    fail = true
    advance(CACHE_MS / 2)
    expect(await source.list()).toEqual(first)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    // After the 10 minutes, the source asks again. The failure gives the error state.
    advance(CACHE_MS / 2)
    expect(await source.list()).toEqual({ ok: false })
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })
})

describe('urlOf', () => {
  it('gives the Releases page for null', () => {
    const { source } = setup(async () => jsonResponse(ANSWER))
    expect(source.urlOf(null)).toBe(RELEASES_PAGE)
  })

  it('gives the GitHub page of a release of the last good answer', async () => {
    const { advance, source } = setup(async () => jsonResponse(ANSWER))
    await source.list()
    expect(source.urlOf('0.4.0')).toBe('https://github.com/Keane54/bifrost/releases/tag/v0.4.0')
    // The page can show the list after the 10 minutes. The link still works.
    advance(CACHE_MS * 3)
    expect(source.urlOf('0.5.0')).toBe('https://github.com/Keane54/bifrost/releases/tag/v0.5.0')
  })

  it('refuses a version that is not in the last good answer, and each other value', async () => {
    const { source } = setup(async () => jsonResponse(ANSWER))
    expect(() => source.urlOf('0.4.0')).toThrow('refused: unknown release')
    await source.list()
    for (const bad of ['0.9.0', 'https://example.com', 7, undefined, {}, '']) {
      expect(() => source.urlOf(bad)).toThrow('refused: unknown release')
    }
  })
})

describe('fileFetch', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'bifrost-file-fetch-'))
  })
  afterEach(async () => {
    await rm(dir, { force: true, recursive: true })
  })

  it('answers each request with the text of the file', async () => {
    const file = join(dir, 'github-releases.json')
    await writeFile(file, JSON.stringify(ANSWER))
    const res = await fileFetch(file)(RELEASES_API, {})
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual(ANSWER)
  })

  it('answers 404 when the file does not exist', async () => {
    const res = await fileFetch(join(dir, 'missing.json'))(RELEASES_API, {})
    expect(res.status).toBe(404)
  })

  it('works with the source', async () => {
    const file = join(dir, 'github-releases.json')
    await writeFile(file, JSON.stringify(ANSWER))
    const source = createReleaseNotesSource({ fetch: fileFetch(file), log: () => {}, now: () => 0 })
    const result = await source.list()
    expect(result.ok && result.releases[0]?.summary).toBe('Summary.')
  })
})
