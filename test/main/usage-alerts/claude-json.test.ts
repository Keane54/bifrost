import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  claudeJsonFile,
  MAX_CLAUDE_JSON_BYTES,
  readExtraUsageFlag,
} from '../../../src/main/usage-alerts/claude-json'

// A temporary folder. A test never reads the real ~/.claude.json.
let dir: string
let file: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-claude-json-'))
  file = join(dir, '.claude.json')
})
afterEach(async () => {
  vi.restoreAllMocks()
  await rm(dir, { force: true, recursive: true })
})

const ON = JSON.stringify({ oauthAccount: { hasExtraUsageEnabled: true } })

describe('claudeJsonFile', () => {
  it('gives .claude.json in the home folder', () => {
    expect(claudeJsonFile('/tmp/test-home')).toBe('/tmp/test-home/.claude.json')
  })
})

describe('readExtraUsageFlag', () => {
  it('gives true only for oauthAccount.hasExtraUsageEnabled true', async () => {
    await writeFile(file, ON)
    expect(await readExtraUsageFlag(file)).toBe(true)
    await writeFile(file, JSON.stringify({ oauthAccount: { hasExtraUsageEnabled: false } }))
    expect(await readExtraUsageFlag(file)).toBe(false)
    await writeFile(file, JSON.stringify({ oauthAccount: {} }))
    expect(await readExtraUsageFlag(file)).toBe(false)
  })

  it('gives false for a missing file, a folder and bad JSON', async () => {
    expect(await readExtraUsageFlag(file)).toBe(false)
    await mkdir(file)
    expect(await readExtraUsageFlag(file)).toBe(false)
    await rm(file, { recursive: true })
    await writeFile(file, '{ "oauthAccount": { "hasExtraUsageEnabled": true ')
    expect(await readExtraUsageFlag(file)).toBe(false)
  })

  it('skips a file above 20 MB', async () => {
    expect(MAX_CLAUDE_JSON_BYTES).toBe(20 * 1024 * 1024)
    // JSON.parse accepts white space after the value. So the size alone decides.
    await writeFile(file, ON.padEnd(MAX_CLAUDE_JSON_BYTES, ' '))
    expect(await readExtraUsageFlag(file)).toBe(true)
    await writeFile(file, ON.padEnd(MAX_CLAUDE_JSON_BYTES + 1, ' '))
    expect(await readExtraUsageFlag(file)).toBe(false)
  })

  it('never writes the file and never logs its content', async () => {
    const logs = [
      vi.spyOn(console, 'log'),
      vi.spyOn(console, 'error'),
      vi.spyOn(console, 'warn'),
      vi.spyOn(console, 'info'),
    ]
    const secret = '{ "oauthAccount": { "emailAddress": "secret-value" '
    await writeFile(file, secret)
    const before = await stat(file)
    expect(await readExtraUsageFlag(file)).toBe(false)
    await writeFile(file, ON)
    const good = await stat(file)
    expect(await readExtraUsageFlag(file)).toBe(true)
    expect(await readFile(file, 'utf8')).toBe(ON)
    expect((await stat(file)).mtimeMs).toBe(good.mtimeMs)
    expect(before.mode).toBe(good.mode)
    for (const spy of logs) expect(spy).not.toHaveBeenCalled()
  })
})
