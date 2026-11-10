// The parts that the Playwright tests in test/smoke share: the start of Bifrost with a fake
// claude and a test home, and the guard of the real files.
//
// Without BIFROST_SMOKE_APP, a test starts the build in out/ with the Electron of the
// repository. With BIFROST_SMOKE_APP=<path of Bifrost.app>, it starts that packaged app.
//
// No test starts Bifrost under Rosetta. On an Apple Silicon Mac, macOS 26 then shows a notice
// that Bifrost "includes a component that will not work with a future release of macOS"
// (spec 14.1).

import { createHash } from 'node:crypto'
import type { Dirent } from 'node:fs'
import { mkdir, readdir, readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { _electron } from '@playwright/test'

type LaunchOptions = NonNullable<Parameters<typeof _electron.launch>[0]>

const ROOT = join(import.meta.dirname, '..', '..')
const FAKE_DIR = join(import.meta.dirname, 'fake-claude')
// The SHA values come from the real home, and the app gets the real home as HOME.
// BIFROST_TEST_HOME is the test home.
const REAL_HOME = homedir()
const CLAUDE_FILES = [
  join(REAL_HOME, '.claude', 'settings.json'),
  join(REAL_HOME, '.claude', 'plugins', 'installed_plugins.json'),
  join(REAL_HOME, '.claude', 'plugins', 'known_marketplaces.json'),
]
// Claude Code writes the lastUpdated values of this file by itself (M5a check). The compare
// ignores them.
const MARKETPLACES_FILE = 'known_marketplaces.json'
// The folder of the real Bifrost. The guard lists it, but not the socket of a running Bifrost.
const BIFROST_DIR = join(REAL_HOME, '.bifrost')
const SOCKET_NAME = 'live.sock'
// The fixtures give each sample session a folder under this folder. node-pty starts the attach
// in the folder of the session, and it cannot start in a folder that does not exist.
export const SESSION_ROOT = '/tmp/bifrost-smoke'
const SESSION_FOLDERS = ['alpha', 'beta', 'gamma']
// The fake claude writes each call that it does not know to this file in the test home.
export const UNKNOWN_LOG = 'unknown.log'

// Remove each lastUpdated key at each depth, and sort the keys. This is the same rule as
// jq -S 'walk(if type == "object" then del(.lastUpdated) else . end)' in the M5a check.
function withoutLastUpdated(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutLastUpdated)
  if (typeof value !== 'object' || value === null) return value
  const source = value as Record<string, unknown>
  const result: Record<string, unknown> = {}
  for (const key of Object.keys(source).sort()) {
    if (key !== 'lastUpdated') result[key] = withoutLastUpdated(source[key])
  }
  return result
}

function sha256(data: Buffer | string): string {
  return createHash('sha256').update(data).digest('hex')
}

// The SHA-256 of a file, or "missing". For the marketplace file, the hash is of the JSON without
// the lastUpdated values. A marketplace file that is not JSON gets the hash of its bytes.
async function fingerprint(path: string): Promise<string> {
  let bytes: Buffer
  try {
    bytes = await readFile(path)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return 'missing'
    throw err
  }
  let data: Buffer | string = bytes
  if (path.endsWith(MARKETPLACES_FILE)) {
    try {
      data = JSON.stringify(withoutLastUpdated(JSON.parse(bytes.toString('utf8'))))
    } catch {
      // The file is not JSON. Use its bytes.
    }
  }
  return sha256(data)
}

// Each entry of a folder at each depth, by its path in the folder: "dir" for a folder, the size
// and the SHA-256 for a file, and the kind for other entries. The socket of a running Bifrost is
// not in the list (R13). A folder that does not exist gives an empty list.
export async function folderListing(dir: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  let entries: Dirent[]
  try {
    entries = await readdir(dir, { recursive: true, withFileTypes: true })
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return result
    throw err
  }
  for (const entry of entries) {
    if (entry.name === SOCKET_NAME) continue
    const path = join(entry.parentPath, entry.name)
    const key = path.slice(dir.length + 1)
    if (entry.isDirectory()) {
      result[key] = 'dir'
    } else if (entry.isFile()) {
      const bytes = await readFile(path)
      result[key] = `${bytes.length} ${sha256(bytes)}`
    } else {
      result[key] = entry.isSymbolicLink() ? 'link' : 'other'
    }
  }
  return result
}

// The guard values of the real files: the three Claude files and the listing of ~/.bifrost.
export async function realFiles(): Promise<{
  claude: Record<string, string>
  bifrost: Record<string, string>
}> {
  const claude: Record<string, string> = {}
  for (const path of CLAUDE_FILES) claude[path] = await fingerprint(path)
  return { bifrost: await folderListing(BIFROST_DIR), claude }
}

// The text of a file, or '' when the file does not exist.
export async function readText(path: string): Promise<string> {
  try {
    return await readFile(path, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw err
  }
}

// Make the folders of the sample sessions.
export async function makeSessionFolders(): Promise<void> {
  for (const name of SESSION_FOLDERS) await mkdir(join(SESSION_ROOT, name), { recursive: true })
}

// The env of the app. It has only these variables. So no CLAUDE* variable, no
// ELECTRON_RUN_AS_NODE and no BIFROST_LIVE_LISTEN gets to the app. The fake claude is the first
// claude on the PATH.
function launchEnv(testHome: string): Record<string, string> {
  const env: Record<string, string> = {
    BIFROST_TEST_HOME: testHome,
    HOME: REAL_HOME,
    PATH: `${FAKE_DIR}:/usr/bin:/bin:/usr/sbin:/sbin`,
  }
  for (const key of ['USER', 'LANG', 'TMPDIR']) {
    const value = process.env[key]
    if (value !== undefined) env[key] = value
  }
  return env
}

// The last argument is always the user data folder in the test home (Global Constraints).
export async function launchOptions(testHome: string): Promise<LaunchOptions> {
  const userData = `--user-data-dir=${join(testHome, 'user-data')}`
  const base = { cwd: ROOT, env: launchEnv(testHome) }
  const appPath = process.env.BIFROST_SMOKE_APP
  if (appPath === undefined || appPath === '') {
    return { ...base, args: ['out/main/index.js', userData] }
  }
  const bin = join(appPath, 'Contents', 'MacOS', 'Bifrost')
  return { ...base, args: [userData], executablePath: bin }
}
