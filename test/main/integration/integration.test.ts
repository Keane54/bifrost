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
  install,
  integrationStatus,
  previewInstall,
  uninstall,
} from '../../../src/main/integration/integration'
import { runSh } from '../../helpers/run-sh'

const NOW = new Date('2026-11-04T15:30:00Z')

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

test('defaultPaths points at the real locations under the given home', () => {
  expect(defaultPaths('/h')).toEqual({
    bifrostHome: '/h/.bifrost',
    claudeSettings: '/h/.claude/settings.json',
  })
})

test('install without a settings file creates it, the scripts and a null original', async () => {
  const s = await install(paths, NOW)
  expect(s).toMatchObject({ installed: true, missingHooks: [] })
  expect((await stat(join(home, 'bin/bifrost-hook'))).mode & 0o111).not.toBe(0)
  expect(JSON.parse(await readFile(join(home, 'statusline-original.json'), 'utf8'))).toBeNull()
  expect(existsSync(join(home, 'backups'))).toBe(false)
})

test('install makes a backup of the old settings', async () => {
  await writeFile(paths.claudeSettings, '{"model":"x"}')
  await install(paths, NOW)
  expect(await readFile(join(home, 'backups/settings-20261104T153000Z.json'), 'utf8')).toBe(
    '{"model":"x"}',
  )
})

test('install stops on settings that are not valid JSON and changes nothing', async () => {
  await writeFile(paths.claudeSettings, '{ not json')
  await expect(install(paths, NOW)).rejects.toThrow(/not valid JSON/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{ not json')
  expect(existsSync(join(home, 'bin'))).toBe(false)
})

test('uninstall stops on settings that are not valid JSON and changes nothing', async () => {
  await writeFile(paths.claudeSettings, '{ not json')
  await expect(uninstall(paths, NOW)).rejects.toThrow(/not valid JSON/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{ not json')
  expect(existsSync(home)).toBe(false)
})

test('install refuses settings with an unexpected type and changes nothing', async () => {
  await writeFile(paths.claudeSettings, '{ "hooks": "x" }')
  await expect(install(paths, NOW)).rejects.toThrow(/Unexpected/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{ "hooks": "x" }')
  expect(existsSync(home)).toBe(false)
})

test('a second install changes nothing and makes no backup', async () => {
  await writeFile(paths.claudeSettings, '{}')
  await install(paths, NOW)
  await install(paths, new Date('2026-11-04T16:00:00Z'))
  expect(await readdir(join(home, 'backups'))).toHaveLength(1)
})

test('install repairs a deleted script without a backup', async () => {
  await install(paths, NOW)
  await rm(join(home, 'bin/bifrost-hook'))
  expect(await integrationStatus(paths)).toMatchObject({ installed: false, scriptsPresent: false })
  const s = await install(paths, NOW)
  expect(s.installed).toBe(true)
  expect(existsSync(join(home, 'backups'))).toBe(false)
})

test('the installed wrapper runs the original command', async () => {
  await writeFile(
    paths.claudeSettings,
    JSON.stringify({ statusLine: { command: "printf 'ORIG'", type: 'command' } }),
  )
  await install(paths, NOW)
  const script = await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')
  expect((await runSh(script, '{}', home)).stdout).toBe('ORIG')
})

test('a second install keeps the saved original', async () => {
  await writeFile(
    paths.claudeSettings,
    JSON.stringify({ statusLine: { command: "printf 'ORIG'", type: 'command' } }),
  )
  await install(paths, NOW)
  await install(paths, NOW)
  const script = await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')
  expect((await runSh(script, '{}', home)).stdout).toBe('ORIG')
  expect(JSON.parse(await readFile(join(home, 'statusline-original.json'), 'utf8'))).toMatchObject({
    command: "printf 'ORIG'",
  })
})

test('uninstall restores the original statusLine and keeps other keys', async () => {
  const before = { model: 'x', statusLine: { command: "printf 'ORIG'", type: 'command' } }
  await writeFile(paths.claudeSettings, JSON.stringify(before))
  await install(paths, NOW)
  await uninstall(paths, NOW)
  expect(JSON.parse(await readFile(paths.claudeSettings, 'utf8'))).toEqual(before)
})

test('integrationStatus reports a removed hook', async () => {
  await install(paths, NOW)
  const s = JSON.parse(await readFile(paths.claudeSettings, 'utf8'))
  delete s.hooks.Stop
  await writeFile(paths.claudeSettings, JSON.stringify(s))
  expect(await integrationStatus(paths)).toMatchObject({ installed: false, missingHooks: ['Stop'] })
})

test('integrationStatus reports an error for settings that are not valid JSON', async () => {
  await writeFile(paths.claudeSettings, '{ not json')
  const s = await integrationStatus(paths)
  expect(s.installed).toBe(false)
  expect(s.error).toMatch(/not valid JSON/)
})

test('previewInstall writes nothing', async () => {
  await writeFile(paths.claudeSettings, '{}')
  const p = await previewInstall(paths, NOW)
  expect(p.changes.length).toBeGreaterThan(0)
  expect(p.backupPath).toBe(join(home, 'backups/settings-20261104T153000Z.json'))
  expect(existsSync(home)).toBe(false)
})

test('a settings file with bytes that are not valid UTF-8 makes install reject', async () => {
  const bytes = Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xe9, 0x22, 0x7d])
  await writeFile(paths.claudeSettings, bytes)
  await expect(install(paths, NOW)).rejects.toThrow(/not valid (JSON|UTF-8)/)
  expect((await readFile(paths.claudeSettings)).equals(bytes)).toBe(true)
  expect(existsSync(home)).toBe(false)
})

test('a symlinked settings file stays a symlink and the target gets the new content', async () => {
  const target = join(dir, 'real-settings.json')
  await writeFile(target, '{"model":"x"}')
  await symlink(target, paths.claudeSettings)
  await install(paths, NOW)
  expect(await readlink(paths.claudeSettings)).toBe(target)
  expect(JSON.parse(await readFile(target, 'utf8'))).toMatchObject({ model: 'x' })
  expect(JSON.parse(await readFile(target, 'utf8')).hooks).toBeDefined()
})

test('the settings file keeps mode 0600 and the backup has mode 0600', async () => {
  await writeFile(paths.claudeSettings, '{"model":"x"}')
  await chmod(paths.claudeSettings, 0o600)
  await install(paths, NOW)
  expect((await stat(paths.claudeSettings)).mode & 0o777).toBe(0o600)
  const backup = join(home, 'backups/settings-20261104T153000Z.json')
  expect((await stat(backup)).mode & 0o777).toBe(0o600)
  expect((await stat(join(home, 'statusline-original.json'))).mode & 0o777).toBe(0o600)
})

test('the backup holds the exact old bytes', async () => {
  const bytes = Buffer.from('{"a":"b"}\n')
  await writeFile(paths.claudeSettings, bytes)
  await install(paths, NOW)
  const backup = await readFile(join(home, 'backups/settings-20261104T153000Z.json'))
  expect(backup.equals(bytes)).toBe(true)
})

test('two backups in the same second get a number and the first stays', async () => {
  await writeFile(paths.claudeSettings, '{"model":"x"}')
  await install(paths, NOW)
  await uninstall(paths, NOW)
  const first = join(home, 'backups/settings-20261104T153000Z.json')
  expect(await readFile(first, 'utf8')).toBe('{"model":"x"}')
  expect(existsSync(join(home, 'backups/settings-20261104T153000Z-1.json'))).toBe(true)
})

test('install refuses when the settings file changes before the final rename', async () => {
  await writeFile(paths.claudeSettings, '{"model":"x"}')
  await expect(
    install(paths, NOW, {
      beforeSettingsRename: () => writeFile(paths.claudeSettings, '{"model":"y"}'),
    }),
  ).rejects.toThrow(/changed/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('{"model":"y"}')
  expect((await readdir(join(dir, 'claude'))).filter(f => f.endsWith('.tmp'))).toEqual([])
})

const ORIG = { command: "printf 'ORIG'", padding: 0, refreshInterval: 1, type: 'command' }
const MISSING = 'Bifrost cannot find your original statusLine setting.'

async function readJson(file: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(file, 'utf8'))
}

test('install, uninstall, a removed statusLine, install and uninstall give no statusLine', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ model: 'x', statusLine: ORIG }))
  await install(paths, NOW)
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual({ model: 'x', statusLine: ORIG })
  await writeFile(paths.claudeSettings, JSON.stringify({ model: 'x' }))
  await install(paths, NOW)
  expect(await readJson(join(home, 'statusline-original.json'))).toBeNull()
  const script = await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')
  expect((await runSh(script, '{}', home)).stdout).toBe('')
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual({ model: 'x' })
})

test('uninstall refuses with a missing saved original and names the newest backup', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  const backups = join(home, 'backups')
  for (const name of [
    'settings-20261104T153000Z-2.json',
    'settings-20261104T153000Z-10.json',
    'settings-20261103T235959Z-99.json',
    'notes.txt',
  ]) {
    await writeFile(join(backups, name), '{}')
  }
  await rm(join(home, 'statusline-original.json'))
  const before = await readFile(paths.claudeSettings)
  const count = (await readdir(backups)).length
  await expect(uninstall(paths, NOW)).rejects.toThrow(
    `${MISSING} Restore it from the newest backup: ${join(backups, 'settings-20261104T153000Z-10.json')}.`,
  )
  expect((await readFile(paths.claudeSettings)).equals(before)).toBe(true)
  expect(await readdir(backups)).toHaveLength(count)
})

test('uninstall refuses with a saved original that is not valid', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  await writeFile(join(home, 'statusline-original.json'), '{ not json')
  const before = await readFile(paths.claudeSettings)
  await expect(uninstall(paths, NOW)).rejects.toThrow(MISSING)
  expect((await readFile(paths.claudeSettings)).equals(before)).toBe(true)
})

test('the refusal says no backup found when no backup exists', async () => {
  await install(paths, NOW)
  expect(existsSync(join(home, 'backups'))).toBe(false)
  await rm(join(home, 'statusline-original.json'))
  await expect(uninstall(paths, NOW)).rejects.toThrow(
    `${MISSING} Restore it from the newest backup: no backup found.`,
  )
})

test('Repair refuses with a missing saved original and changes nothing', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  await rm(join(home, 'statusline-original.json'))
  // A missing hook needs a Repair.
  const s = await readJson(paths.claudeSettings)
  delete (s.hooks as Record<string, unknown>).Stop
  await writeFile(paths.claudeSettings, JSON.stringify(s))
  const before = await readFile(paths.claudeSettings)
  const script = await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')
  await expect(previewInstall(paths, NOW)).rejects.toThrow(MISSING)
  await expect(install(paths, NOW)).rejects.toThrow(MISSING)
  expect((await readFile(paths.claudeSettings)).equals(before)).toBe(true)
  expect(await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')).toBe(script)
  expect(existsSync(join(home, 'statusline-original.json'))).toBe(false)
  expect(await readdir(join(home, 'backups'))).toHaveLength(1)
})

test('uninstall works with a missing saved original when the statusLine is not the wrapper', async () => {
  const NEW = { command: "printf 'NEW'", type: 'command' }
  await install(paths, NOW)
  await rm(join(home, 'statusline-original.json'))
  const s = await readJson(paths.claudeSettings)
  await writeFile(paths.claudeSettings, JSON.stringify({ ...s, statusLine: NEW }))
  await uninstall(paths, NOW)
  expect(await readJson(paths.claudeSettings)).toEqual({ statusLine: NEW })
})

test('install and uninstall refuse an empty settings file as not valid JSON', async () => {
  await writeFile(paths.claudeSettings, '')
  await expect(install(paths, NOW)).rejects.toThrow(/not valid JSON/)
  await expect(uninstall(paths, NOW)).rejects.toThrow(/not valid JSON/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe('')
  expect(existsSync(home)).toBe(false)
  expect((await integrationStatus(paths)).error).toMatch(/not valid JSON/)
})

test('Repair after the statusline installer replaced the wrapper keeps the new statusLine', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ model: 'x', statusLine: ORIG }))
  await install(paths, NOW)
  // The claude-statusline installer writes its own block over the wrapper.
  const NEW = { command: "printf 'NEW'", refreshInterval: 10, type: 'command' }
  const s = await readJson(paths.claudeSettings)
  await writeFile(paths.claudeSettings, JSON.stringify({ ...s, statusLine: NEW }))
  expect(await integrationStatus(paths)).toMatchObject({
    installed: false,
    statusLineInstalled: false,
  })
  const repaired = await install(paths, new Date('2026-11-04T16:00:00Z'))
  expect(repaired.installed).toBe(true)
  expect(await readJson(join(home, 'statusline-original.json'))).toEqual(NEW)
  expect((await readJson(paths.claudeSettings)).statusLine).toEqual({
    command: '~/.bifrost/bin/bifrost-statusline',
    refreshInterval: 10,
    type: 'command',
  })
  const script = await readFile(join(home, 'bin/bifrost-statusline'), 'utf8')
  expect((await runSh(script, '{}', home)).stdout).toBe('NEW')
  await uninstall(paths, new Date('2026-11-04T16:30:00Z'))
  expect(await readJson(paths.claudeSettings)).toEqual({ model: 'x', statusLine: NEW })
})

test('uninstall refuses when the settings file changes before the final rename', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  const changed = '{"model":"y"}'
  await expect(
    uninstall(paths, NOW, { beforeSettingsRename: () => writeFile(paths.claudeSettings, changed) }),
  ).rejects.toThrow(/changed/)
  expect(await readFile(paths.claudeSettings, 'utf8')).toBe(changed)
  expect((await readdir(join(dir, 'claude'))).filter(f => f.endsWith('.tmp'))).toEqual([])
})

test('an install with old scripts is not installed, and a Repair makes it current', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  expect(await integrationStatus(paths)).toMatchObject({ installed: true, scriptsCurrent: true })
  for (const name of ['bifrost-hook', 'bifrost-statusline']) {
    const file = join(home, 'bin', name)
    const text = await readFile(file, 'utf8')
    await writeFile(file, '#!/bin/sh\n# An older script.\nexit 0\n')
    expect(await integrationStatus(paths)).toMatchObject({
      installed: false,
      scriptsCurrent: false,
      scriptsPresent: true,
    })
    const repaired = await install(paths, new Date('2026-11-04T16:00:00Z'))
    expect(repaired).toMatchObject({ installed: true, scriptsCurrent: true })
    expect(await readFile(file, 'utf8')).toBe(text)
  }
  // The scripts changed, but the settings did not. So no new backup.
  expect(await readdir(join(home, 'backups'))).toHaveLength(1)
})

test('an install with a missing saved original is not installed', async () => {
  await writeFile(paths.claudeSettings, JSON.stringify({ statusLine: ORIG }))
  await install(paths, NOW)
  await rm(join(home, 'statusline-original.json'))
  expect(await integrationStatus(paths)).toMatchObject({ installed: false, scriptsCurrent: false })
})
