// The smoke test of spec 15 (D23). It starts Bifrost with a fake claude and a test home. It checks
// the setup dialog, the sample sessions, the Parked tab and one chat window. It also checks that
// the real Claude files did not change.
//
// Without BIFROST_SMOKE_APP, the test starts the build in out/ with the Electron of the
// repository. With BIFROST_SMOKE_APP=<path of Bifrost.app>, it starts that packaged app.
// BIFROST_SMOKE_ARCH=x86_64 also starts the packaged app under Rosetta.

import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron, type ElectronApplication, expect, type Locator, test } from '@playwright/test'

type LaunchOptions = NonNullable<Parameters<typeof _electron.launch>[0]>

const ROOT = join(import.meta.dirname, '..', '..')
const FAKE_DIR = join(import.meta.dirname, 'fake-claude')
// R14: the SHA values come from the real home, and the app gets the real home as HOME.
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
// The fixtures give each sample session a folder under this folder. node-pty starts the attach
// in the folder of the session, and it cannot start in a folder that does not exist.
const SESSION_ROOT = '/tmp/bifrost-smoke'
const SESSION_FOLDERS = ['alpha', 'beta', 'gamma']

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
  return createHash('sha256').update(data).digest('hex')
}

async function claudeFingerprints(): Promise<Record<string, string>> {
  const result: Record<string, string> = {}
  for (const path of CLAUDE_FILES) result[path] = await fingerprint(path)
  return result
}

// The text of a file, or '' when the file does not exist.
async function readText(path: string): Promise<string> {
  try {
    return await readFile(path, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw err
  }
}

// Make the folders of the sample sessions. Return true when this run made the root folder.
// Then only this run removes it.
async function makeSessionFolders(): Promise<boolean> {
  const made = !existsSync(SESSION_ROOT)
  for (const name of SESSION_FOLDERS) await mkdir(join(SESSION_ROOT, name), { recursive: true })
  return made
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

// Playwright puts its own flags before the args. "/usr/bin/arch --inspect=0 ..." then fails. So
// a small sh file starts the app under Rosetta and gives it all flags.
async function rosettaStarter(testHome: string, bin: string): Promise<string> {
  const path = join(testHome, 'start-x86_64.sh')
  const quoted = `'${bin.replaceAll("'", "'\\''")}'`
  await writeFile(path, `#!/bin/sh\nexec /usr/bin/arch -x86_64 ${quoted} "$@"\n`, { mode: 0o755 })
  return path
}

// The last argument is always the user data folder in the test home (Global Constraints).
async function launchOptions(testHome: string): Promise<LaunchOptions> {
  const userData = `--user-data-dir=${join(testHome, 'user-data')}`
  const base = { cwd: ROOT, env: launchEnv(testHome) }
  const appPath = process.env.BIFROST_SMOKE_APP
  if (appPath === undefined || appPath === '') {
    return { ...base, args: ['out/main/index.js', userData] }
  }
  const bin = join(appPath, 'Contents', 'MacOS', 'Bifrost')
  if (process.env.BIFROST_SMOKE_ARCH === 'x86_64') {
    return { ...base, args: [userData], executablePath: await rosettaStarter(testHome, bin) }
  }
  return { ...base, args: [userData], executablePath: bin }
}

test('Bifrost starts with a fake claude and shows the sample sessions', async () => {
  // Step 1: record the real Claude files, and make the test home.
  const before = await claudeFingerprints()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-smoke-'))
  const appOutput: string[] = []
  let madeSessionRoot = false
  let app: ElectronApplication | null = null
  let tracing = false
  try {
    madeSessionRoot = await makeSessionFolders()

    // Step 2: start the app.
    app = await _electron.launch(await launchOptions(testHome))
    app.process().stdout?.on('data', chunk => appOutput.push(String(chunk)))
    app.process().stderr?.on('data', chunk => appOutput.push(String(chunk)))
    await app.context().tracing.start({ screenshots: true, snapshots: true })
    tracing = true
    const page = await app.firstWindow()

    // Step 3: the fake claude lists no Bifrost plugin, so the setup dialog shows.
    const setup = page.locator('[data-setup-dialog]')
    await expect(setup).toContainText('Set up Bifrost', { timeout: 15_000 })
    await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
    await expect(setup).toBeHidden()

    // Step 4: the All tab shows the two active sessions, but not the parked session.
    const overview = page.locator('[data-overview-id]').first()
    const row = (name: string): Locator =>
      overview.locator('tr[data-session-id]', { hasText: name })
    await expect(row('smoke-alpha')).toBeVisible({ timeout: 15_000 })
    await expect(row('smoke-beta')).toBeVisible()
    await expect(row('smoke-gamma')).toHaveCount(0)

    // Step 5: the Parked tab shows the parked session. It comes from the first --all poll.
    await overview.getByRole('tab', { exact: true, name: 'Parked' }).click()
    await expect(row('smoke-gamma')).toBeVisible({ timeout: 15_000 })
    await overview.getByRole('tab', { exact: true, name: 'All' }).click()
    await expect(row('smoke-alpha')).toBeVisible()
    await expect(row('smoke-gamma')).toHaveCount(0)

    // Step 6: a double-click opens a chat window. Its attach runs the fake claude through
    // node-pty and spawn-helper. WebGL draws the terminal text, so the DOM has no text to read
    // (R7). The fake claude writes the attach line to a file in the test home.
    await row('smoke-alpha').dblclick()
    await expect
      .poll(() => readText(join(testHome, 'attach.log')), { timeout: 10_000 })
      .toContain('FAKE ATTACH 5a0e0001')

    // Step 7: quit the app.
    tracing = false
    await app.context().tracing.stop()
    await app.close()
    app = null

    // Step 8: the Skip choice is in the test home. The real Claude files did not change.
    // Live details is not installed, so no live server made a socket.
    const settings = JSON.parse(
      await readFile(join(testHome, 'user-data', 'settings.json'), 'utf8'),
    )
    expect(settings.setupDone).toBe(true)
    expect(await claudeFingerprints()).toEqual(before)
    expect(existsSync(join(testHome, '.bifrost', 'live.sock'))).toBe(false)
  } catch (err) {
    // Keep the trace and the output of the app in test-results/ for the person who reads the
    // failure.
    if (app !== null && tracing) {
      await app
        .context()
        .tracing.stop({ path: test.info().outputPath('trace.zip') })
        .catch(() => {})
    }
    await test.info().attach('app-output.txt', {
      body: appOutput.join(''),
      contentType: 'text/plain',
    })
    throw err
  } finally {
    if (app !== null) await app.close().catch(() => {})
    await rm(testHome, { force: true, recursive: true })
    if (madeSessionRoot) await rm(SESSION_ROOT, { force: true, recursive: true })
  }
})
