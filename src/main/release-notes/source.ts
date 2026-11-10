// The release notes source. It reads the GitHub releases of Bifrost only when a release notes view
// opens, and keeps the last good answer in memory for CACHE_MS. The releases are in a public repo,
// so the request has no token. This file has no Electron import. ipc.ts gives it net.fetch, or
// fileFetch in a test home.
import { readFile } from 'node:fs/promises'
import type { Release, ReleaseNotesResult } from '../../shared/release-notes'
import { cappedText, type FetchFn } from '../service-status/statuspage'
import { UPDATE_OWNER, UPDATE_REPO } from '../updates/updater'
import { MAX_RELEASES, parseReleases, RELEASE_URL_PREFIX } from './parse'

const REPO_PATH = `${UPDATE_OWNER}/${UPDATE_REPO}`
const API_BASE = 'https://api.github.com/repos'
export const RELEASES_API = `${API_BASE}/${REPO_PATH}/releases?per_page=${MAX_RELEASES}`
export const RELEASES_PAGE = `https://github.com/${REPO_PATH}/releases`
export const FETCH_TIMEOUT_MS = 10_000
// Bifrost reads at most this many bytes of one answer. Ten release bodies have a few tens of kB.
export const MAX_BODY_BYTES = 2_000_000
export const CACHE_MS = 10 * 60_000

const TOO_LARGE = 'The answer of GitHub is too large.'
export const REFUSED_UNKNOWN_RELEASE = 'refused: unknown release'

export interface ReleaseNotesDeps {
  fetch: FetchFn
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  // One line for each failed load. The line has no request data.
  log(message: string): void
}

export interface ReleaseNotesSource {
  // The parsed releases, or an error. This never rejects.
  list(): Promise<ReleaseNotesResult>
  // The GitHub page to open: the Releases page for null, else the page of a release of the last
  // good answer. Each other value throws REFUSED_UNKNOWN_RELEASE. So the page never gives a URL.
  urlOf(version: unknown): string
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// Ask GitHub one time. A bad answer rejects.
async function request(fetch: FetchFn): Promise<Release[]> {
  const res = await fetch(RELEASES_API, {
    credentials: 'omit',
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'Bifrost' },
    redirect: 'error',
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  })
  if (!res.ok) {
    await res.body?.cancel().catch(() => {})
    throw new Error(`GitHub answered ${res.status}.`)
  }
  const releases = parseReleases(JSON.parse(await cappedText(res, MAX_BODY_BYTES, TOO_LARGE)))
  if (releases === null) throw new Error('The answer of GitHub is not a list of releases.')
  return releases
}

export function createReleaseNotesSource(deps: ReleaseNotesDeps): ReleaseNotesSource {
  // The last good answer and its time. It stays after CACHE_MS for urlOf.
  let last: { at: number; releases: Release[] } | null = null
  let running: Promise<ReleaseNotesResult> | null = null

  async function load(): Promise<ReleaseNotesResult> {
    try {
      const releases = await request(deps.fetch)
      last = { at: deps.now(), releases }
      return { ok: true, releases }
    } catch (err) {
      deps.log(`Bifrost cannot load the release notes. ${messageOf(err).split('\n')[0]}`)
      return { ok: false }
    }
  }

  return {
    list() {
      if (last !== null && deps.now() - last.at < CACHE_MS) {
        return Promise.resolve({ ok: true, releases: last.releases })
      }
      // Two views that open at the same time share one request.
      running ??= load().finally(() => {
        running = null
      })
      return running
    },
    urlOf(version) {
      if (version === null) return RELEASES_PAGE
      const found =
        typeof version === 'string' ? last?.releases.find(r => r.version === version) : undefined
      if (found === undefined || !found.url.startsWith(RELEASE_URL_PREFIX)) {
        throw new Error(REFUSED_UNKNOWN_RELEASE)
      }
      return found.url
    },
  }
}

// The fetch of a test home. It answers each request with the text of the file, or with 404 when
// the file does not exist. So a smoke test gives the releases, and no test calls GitHub.
export function fileFetch(file: string): FetchFn {
  return async () => {
    try {
      return new Response(await readFile(file, 'utf8'), {
        headers: { 'content-type': 'application/json' },
        status: 200,
      })
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      return new Response('Not Found', { status: 404 })
    }
  }
}
