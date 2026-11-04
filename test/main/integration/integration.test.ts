import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
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
