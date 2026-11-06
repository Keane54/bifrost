import { existsSync } from 'node:fs'
import {
  chmod,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import {
  defaultPaths,
  type IntegrationPaths,
  oldInstallStatus,
  removeOldHookData,
  uninstall,
} from '../../../src/main/integration/integration'
import {
  type ClaudeSettings,
  HOOK_COMMAND,
  hasBifrostEntry,
  planUninstall,
  STATUSLINE_COMMAND,
} from '../../../src/main/integration/settings-plan'
import { oldInstalled } from '../../helpers/old-install'

const NOW = new Date('2026-11-04T15:30:00Z')
const ORIG = { command: "printf 'ORIG'", padding: 0, refreshInterval: 1, type: 'command' }
const MISSING = 'Bifrost cannot find your original statusLine setting.'

let dir: string
let home: string
let paths: IntegrationPaths

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-integration-'))
  home = join(dir, 'bifrost-home')
  paths = { bifrostHome: home, claudeSettings: join(dir, 'claude', 'settings.json') }
  await mkdir(join(dir, 'claude'))
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

async function readJson(file: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(file, 'utf8'))
}

// Make the state of an old M1 install: the hooks and the wrapper in the settings, and the saved
// original statusLine. original undefined writes no saved file.
async function seedOldInstall(
  base: ClaudeSettings,
  original: Record<string, unknown> | null | undefined,
): Promise<void> {
  await writeFile(paths.claudeSettings, JSON.stringify(oldInstalled(base)))
  if (original !== undefined) {
    await mkdir(home, { recursive: true })
    await writeFile(join(home, 'statusline-original.json'), `${JSON.stringify(original)}\n`)
  }
}

test('defaultPaths points at the real locations under the given home', () => {
  expect(defaultPaths('/h')).toEqual({
    bifrostHome: '/h/.bifrost',
    claudeSettings: '/h/.claude/settings.json',
  })
})

test('uninstall stops on settings that are not valid JSON and changes nothing', async () => {
  await writeFile(paths.claudeSettings, '{ not json')
  await expect(uninstall(paths, NOW)).rejects.toThrow(/not valid JSON/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{ not json')
  expect(existsSync(home)).toBe(false)
})

test('uninstall refuses a settings file with bytes that are not valid UTF-8', async () => {
  const bytes = Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xe9, 0x22, 0x7d])
  await writeFile(paths.claudeSettings, bytes)
  await expect(uninstall(paths, NOW)).rejects.toThrow(/not valid (JSON|UTF-8)/)
  expect((await readFile(paths.claudeSettings)).equals(bytes)).toBe(true)
  expect(existsSync(home)).toBe(false)
})

test('uninstall restores the original statusLine and keeps other keys', async () => {
  const before = { model: 'x', statusLine: ORIG }
  await seedOldInstall(before, ORIG)
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual(before)
  // The saved original stays.
  expect(await readJson(join(home, 'statusline-original.json'))).toEqual(ORIG)
})

test('uninstall removes the wrapper when the user had no statusLine', async () => {
  await seedOldInstall({ model: 'x' }, null)
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual({ model: 'x' })
})

test('uninstall makes one backup with the exact old bytes and mode 0600', async () => {
  await seedOldInstall({ model: 'x' }, null)
  const bytes = await readFile(paths.claudeSettings)
  await uninstall(paths, NOW)
  const backup = join(home, 'backups/settings-20261104T153000Z.json')
  expect((await readFile(backup)).equals(bytes)).toBe(true)
  expect((await stat(backup)).mode & 0o777).toBe(0o600)
  expect(await readdir(join(home, 'backups'))).toHaveLength(1)
})

test('uninstall makes no backup when the settings have no Bifrost entry', async () => {
  await writeFile(paths.claudeSettings, '{"model":"x"}')
  await uninstall(paths, NOW)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{"model":"x"}')
  expect(existsSync(join(home, 'backups'))).toBe(false)
})

test('a symlinked settings file stays a symlink and the target gets the new content', async () => {
  const target = join(dir, 'real-settings.json')
  await writeFile(target, JSON.stringify(oldInstalled({ model: 'x' })))
  await mkdir(home, { recursive: true })
  await writeFile(join(home, 'statusline-original.json'), 'null')
  await symlink(target, paths.claudeSettings)
  await uninstall(paths, NOW)
  expect(await readlink(paths.claudeSettings)).toBe(target)
  expect(await readJson(target)).toEqual({ model: 'x' })
})

test('the settings file keeps its mode after uninstall', async () => {
  await seedOldInstall({ model: 'x' }, null)
  await chmod(paths.claudeSettings, 0o640)
  await uninstall(paths, NOW)
  expect((await stat(paths.claudeSettings)).mode & 0o777).toBe(0o640)
})

test('two backups in the same second get a number and the first stays', async () => {
  await seedOldInstall({ model: 'x' }, null)
  const first = join(home, 'backups/settings-20261104T153000Z.json')
  await uninstall(paths, NOW)
  const firstBytes = await readFile(first, 'utf8')
  await writeFile(paths.claudeSettings, JSON.stringify(oldInstalled({ model: 'y' })))
  await uninstall(paths, NOW)
  expect(await readFile(first, 'utf8')).toBe(firstBytes)
  expect(existsSync(join(home, 'backups/settings-20261104T153000Z-1.json'))).toBe(true)
})

test('uninstall refuses with a missing saved original and names the newest backup', async () => {
  await seedOldInstall({ statusLine: ORIG }, undefined)
  const backups = join(home, 'backups')
  await mkdir(backups, { recursive: true })
  for (const name of [
    'settings-20261104T153000Z-2.json',
    'settings-20261104T153000Z-10.json',
    'settings-20261103T235959Z-99.json',
    'notes.txt',
  ]) {
    await writeFile(join(backups, name), '{}')
  }
  const before = await readFile(paths.claudeSettings)
  const count = (await readdir(backups)).length
  await expect(uninstall(paths, NOW)).rejects.toThrow(
    `${MISSING} Restore it from the newest backup: ${join(backups, 'settings-20261104T153000Z-10.json')}.`,
  )
  expect((await readFile(paths.claudeSettings)).equals(before)).toBe(true)
  expect(await readdir(backups)).toHaveLength(count)
})

test('uninstall refuses with a saved original that is not valid', async () => {
  await seedOldInstall({ statusLine: ORIG }, undefined)
  await mkdir(home, { recursive: true })
  await writeFile(join(home, 'statusline-original.json'), '{ not json')
  const before = await readFile(paths.claudeSettings)
  await expect(uninstall(paths, NOW)).rejects.toThrow(MISSING)
  expect((await readFile(paths.claudeSettings)).equals(before)).toBe(true)
})

test('the refusal says no backup found when no backup exists', async () => {
  await seedOldInstall({}, undefined)
  await expect(uninstall(paths, NOW)).rejects.toThrow(
    `${MISSING} Restore it from the newest backup: no backup found.`,
  )
  expect(existsSync(join(home, 'backups'))).toBe(false)
})

test('uninstall works with a missing saved original when the statusLine is not the wrapper', async () => {
  const NEW = { command: "printf 'NEW'", type: 'command' }
  await seedOldInstall({}, undefined)
  const s = await readJson(paths.claudeSettings)
  await writeFile(paths.claudeSettings, JSON.stringify({ ...s, statusLine: NEW }))
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual({ statusLine: NEW })
})

test('uninstall refuses an empty settings file as not valid JSON', async () => {
  await writeFile(paths.claudeSettings, '')
  await expect(uninstall(paths, NOW)).rejects.toThrow(/not valid JSON/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('')
  expect(existsSync(home)).toBe(false)
})

test('uninstall refuses when the settings file changes before the final rename', async () => {
  await seedOldInstall({ statusLine: ORIG }, ORIG)
  const changed = '{"model":"y"}'
  await expect(
    uninstall(paths, NOW, { beforeSettingsRename: () => writeFile(paths.claudeSettings, changed) }),
  ).rejects.toThrow(/changed/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe(changed)
  expect((await readdir(join(dir, 'claude'))).filter(f => f.endsWith('.tmp'))).toEqual([])
})

test('oldInstallStatus finds a Bifrost hook or the wrapper', async () => {
  const hook = { hooks: [{ command: HOOK_COMMAND, type: 'command' }] }
  await writeFile(paths.claudeSettings, JSON.stringify({ hooks: { Stop: [hook] } }))
  expect(await oldInstallStatus(paths)).toEqual({ found: true })
  await writeFile(
    paths.claudeSettings,
    JSON.stringify({ statusLine: { command: STATUSLINE_COMMAND, type: 'command' } }),
  )
  expect(await oldInstallStatus(paths)).toEqual({ found: true })
})

test('oldInstallStatus gives found false with no Bifrost entry', async () => {
  expect(await oldInstallStatus(paths)).toEqual({ found: false })
  await writeFile(
    paths.claudeSettings,
    JSON.stringify({
      hooks: { Stop: [{ hooks: [{ command: 'my-hook', type: 'command' }] }] },
      statusLine: { command: 'my-statusline', type: 'command' },
    }),
  )
  expect(await oldInstallStatus(paths)).toEqual({ found: false })
})

test('oldInstallStatus gives the error for a settings file that is not valid JSON', async () => {
  await writeFile(paths.claudeSettings, '{ not json')
  const s = await oldInstallStatus(paths)
  expect(s.found).toBe(false)
  expect(s.error).toMatch(/not valid JSON/)
})

test('oldInstallStatus finds a Bifrost hook under any event and matcher', async () => {
  const entry = { hooks: [{ command: HOOK_COMMAND, type: 'command' }], matcher: 'Bash' }
  await writeFile(paths.claudeSettings, JSON.stringify({ hooks: { PreToolUse: [entry] } }))
  expect(await oldInstallStatus(paths)).toEqual({ found: true })
})

test('hasBifrostEntry is true exactly when planUninstall changes the settings', () => {
  const hook = { command: HOOK_COMMAND, type: 'command' }
  const mine = { command: 'mine', type: 'command' }
  const cases: ClaudeSettings[] = [
    {},
    { hooks: {} },
    { hooks: 'x' },
    { hooks: { Stop: 'x' } },
    { hooks: { Stop: [{ hooks: [mine] }] } },
    { hooks: { Stop: [{ hooks: [hook] }] } },
    { hooks: { PreToolUse: [{ hooks: [hook], matcher: 'Bash' }] } },
    { hooks: { Custom: [{ hooks: [mine, hook] }] } },
    { statusLine: { command: 'mine', type: 'command' } },
    { statusLine: { command: STATUSLINE_COMMAND, type: 'command' } },
  ]
  for (const settings of cases) {
    const changes = JSON.stringify(planUninstall(settings, null)) !== JSON.stringify(settings)
    expect(hasBifrostEntry(settings)).toBe(changes)
  }
})

// Old hook data: the files that the M1 hooks and the app wrote under the Bifrost home.
async function seedHookData(): Promise<void> {
  await mkdir(join(home, 'events'), { recursive: true })
  await mkdir(join(home, 'sessions'), { recursive: true })
  await mkdir(join(home, 'bin'), { recursive: true })
  await mkdir(join(home, 'mod'), { recursive: true })
  await mkdir(join(home, 'backups'), { recursive: true })
  await writeFile(join(home, 'active'), '')
  await writeFile(join(home, 'events', '1-2.json'), '{}')
  await writeFile(join(home, 'sessions', 's.json'), '{}')
  await writeFile(join(home, 'bin', 'bifrost-hook'), '#!/bin/sh\n')
  await writeFile(join(home, 'mod', 'keep.txt'), 'x')
  await writeFile(join(home, 'live.sock'), 'x')
  await writeFile(join(home, 'statusline-original.json'), 'null')
  await writeFile(join(home, 'backups', 'settings-1.json'), '{}')
}

const KEPT = ['mod/keep.txt', 'live.sock', 'statusline-original.json', 'backups/settings-1.json']

test('removeOldHookData removes active, events and sessions and keeps the other files', async () => {
  await seedHookData()
  await removeOldHookData(home, true)
  for (const gone of ['active', 'events', 'sessions'])
    expect(existsSync(join(home, gone))).toBe(false)
  for (const kept of KEPT) expect(existsSync(join(home, kept)), kept).toBe(true)
})

test('removeOldHookData keeps bin with keepScripts true and removes it with false', async () => {
  await seedHookData()
  await removeOldHookData(home, true)
  expect(existsSync(join(home, 'bin', 'bifrost-hook'))).toBe(true)
  await removeOldHookData(home, false)
  expect(existsSync(join(home, 'bin'))).toBe(false)
  for (const kept of KEPT) expect(existsSync(join(home, kept)), kept).toBe(true)
})

test('removeOldHookData accepts a home with nothing in it', async () => {
  await expect(removeOldHookData(home, false)).resolves.toBeUndefined()
  await mkdir(home)
  await expect(removeOldHookData(home, false)).resolves.toBeUndefined()
})
