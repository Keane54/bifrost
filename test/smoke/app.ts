// The parts that the Playwright tests in test/smoke share: the start of Bifrost with a fake
// claude and a test home, and the check that the test app uses only the test home.
//
// Without BIFROST_SMOKE_APP, a test starts the build in out/ with the Electron of the
// repository. The start uses the main field of package.json, so the app path is the repository.
// The app name and the version now come from package.json. With
// BIFROST_SMOKE_APP=<path of Bifrost.app>, a test starts that packaged app.
//
// No test starts Bifrost under Rosetta. On an Apple Silicon Mac, macOS 26 then shows a notice
// that Bifrost "includes a component that will not work with a future release of macOS"
// (spec 14.1).

import { mkdir, readFile, realpath, rm } from 'node:fs/promises'
import { isAbsolute, join, relative } from 'node:path'
import { type _electron, type ElectronApplication, expect, type Page } from '@playwright/test'

type LaunchOptions = NonNullable<Parameters<typeof _electron.launch>[0]>

const ROOT = join(import.meta.dirname, '..', '..')
const FAKE_DIR = join(import.meta.dirname, 'fake-claude')
// The fixtures give each sample session a folder under this folder. node-pty starts the attach
// in the folder of the session, and it cannot start in a folder that does not exist.
export const SESSION_ROOT = '/tmp/bifrost-smoke'
const SESSION_FOLDERS = ['alpha', 'beta', 'gamma']
// The fake claude writes each call that it does not know to this file in the test home.
export const UNKNOWN_LOG = 'unknown.log'

// The paths that the test app uses. The main process gives them. A path that the app did not
// record is null.
interface AppPaths {
  bifrostHome: string | null
  claudeJson: string | null
  claudeSettings: string | null
  logs: string
  userData: string
}

// True when path is in one of the folders dirs, after the resolve of "." and "..".
function isInside(path: string | null, dirs: string[]): boolean {
  if (path === null) return false
  return dirs.some(dir => {
    const rel = relative(dir, path)
    return rel !== '' && !rel.startsWith('..') && !isAbsolute(rel)
  })
}

// Check in the main process of the test app that the home folder is the test home, and that the
// user files of Bifrost and Claude, the userData folder and the logs folder are in the test home.
// The app then cannot get to the real ~/.claude, ~/.claude.json, ~/.bifrost or ~/Library/Logs. A
// Bifrost of the user that runs at the same time does not change the result.
export async function expectTestHomeOnly(
  app: ElectronApplication,
  testHome: string,
): Promise<void> {
  const { home, paths } = await app.evaluate(({ app: electronApp }) => {
    const recorded = (globalThis as { bifrostTestPaths?: Record<string, string> }).bifrostTestPaths
    const paths: AppPaths = {
      bifrostHome: recorded?.bifrostHome ?? null,
      claudeJson: recorded?.claudeJson ?? null,
      claudeSettings: recorded?.claudeSettings ?? null,
      logs: electronApp.getPath('logs'),
      userData: electronApp.getPath('userData'),
    }
    return { home: process.getBuiltinModule('node:os').homedir(), paths }
  })
  expect(home).toBe(testHome)
  // Electron can give a path with each symbolic link resolved, for example /private/var in place
  // of /var. So the real path of the test home is also correct.
  const homes = [testHome, await realpath(testHome)]
  for (const [key, path] of Object.entries(paths)) {
    expect(isInside(path, homes), `${key}: ${path}`).toBe(true)
  }
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
//
// HOME is the test home (user decision, 2026-11-13). The app and its child processes then read
// and write only in the test home. No ZDOTDIR, XDG_* or CLAUDE_CONFIG_DIR variable gets to the
// app, so these tools also use HOME.
//
// The app shows no window and no Dock icon, and it never takes the focus (user decision,
// 2026-11-13). To see the window when you debug a test, set BIFROST_SMOKE_HEADED=1.
function launchEnv(testHome: string): Record<string, string> {
  const env: Record<string, string> = {
    BIFROST_TEST_HOME: testHome,
    HOME: testHome,
    PATH: `${FAKE_DIR}:/usr/bin:/bin:/usr/sbin:/sbin`,
  }
  if (process.env.BIFROST_SMOKE_HEADED !== '1') env.BIFROST_TEST_HEADLESS = '1'
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
    return { ...base, args: ['.', userData] }
  }
  const bin = join(appPath, 'Contents', 'MacOS', 'Bifrost')
  return { ...base, args: [userData], executablePath: bin }
}

// Pass the setup dialog with Skip in the Live step and in the skills step.
export async function skipSetup(page: Page): Promise<void> {
  const setup = page.locator('[data-setup-dialog]')
  await expect(setup).toContainText('Set up Bifrost', { timeout: 15_000 })
  await expect(setup).toHaveAttribute('data-setup-dialog', 'ask')
  await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
  await expect(setup).toHaveAttribute('data-setup-dialog', 'skills')
  await setup.getByRole('button', { exact: true, name: 'Skip' }).click()
  await expect(setup).toBeHidden()
}

// Remove the test home. A child process of the app (a git or gh process, or the fake claude) can
// still write in the folder when the app has quit. The remove then fails with ENOTEMPTY. So the
// remove tries again until the folder is gone. The remove never hides the last error.
export async function removeTestHome(testHome: string): Promise<void> {
  const end = Date.now() + 20_000
  for (;;) {
    try {
      await rm(testHome, { force: true, maxRetries: 5, recursive: true, retryDelay: 200 })
      return
    } catch (err) {
      if (Date.now() >= end) throw err
      await new Promise(resolve => setTimeout(resolve, 250))
    }
  }
}
