// File IO for the Claude Code integration.
// This code changes the settings file of the user. It must never lose or corrupt that file.
// Every write goes to a temporary name in the same directory. Then it renames the file.

import { randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, open, readdir, readFile, realpath, rename, rm, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import {
  type ClaudeSettings,
  checkInstall,
  hasBifrostEntry,
  planUninstall,
  type StatusLineSetting,
} from './settings-plan'

// A test can use this hook to change the settings file before the final rename.
export interface InstallHooks {
  beforeSettingsRename?: () => Promise<void>
}

export interface IntegrationPaths {
  claudeSettings: string
  bifrostHome: string
}

export function defaultPaths(home: string): IntegrationPaths {
  return {
    bifrostHome: join(home, '.bifrost'),
    claudeSettings: join(home, '.claude', 'settings.json'),
  }
}

interface Files {
  original: string
  backups: string
}

function filesOf(paths: IntegrationPaths): Files {
  const home = paths.bifrostHome
  return {
    backups: join(home, 'backups'),
    original: join(home, 'statusline-original.json'),
  }
}

function isNotFound(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === 'ENOENT'
}

async function readText(file: string): Promise<string | null> {
  try {
    return await readFile(file, 'utf8')
  } catch (error) {
    if (isNotFound(error)) return null
    throw error
  }
}

async function readBytes(file: string): Promise<Buffer | null> {
  try {
    return await readFile(file)
  } catch (error) {
    if (isNotFound(error)) return null
    throw error
  }
}

// A missing file counts as an empty object.
// Keep the exact bytes: the backup must hold them.
async function readSettings(
  file: string,
): Promise<{ settings: ClaudeSettings; bytes: Buffer | null }> {
  const bytes = await readBytes(file)
  if (bytes === null) return { bytes, settings: {} }
  let parsed: unknown
  try {
    parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes))
  } catch {
    throw new Error(
      `The file ${file} is not valid JSON (or not valid UTF-8). Bifrost did not change it.`,
    )
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Unexpected type in ${file}. Expect a JSON object. Bifrost did not change it.`)
  }
  return { bytes, settings: parsed as ClaudeSettings }
}

// A missing file gives undefined. A file with null gives null.
// A file that is not valid JSON, or has the wrong shape, gives undefined.
async function readSavedOriginal(file: string): Promise<StatusLineSetting | null | undefined> {
  const text = await readText(file)
  if (text === null) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (parsed === null) return null
  if (typeof parsed === 'object' && !Array.isArray(parsed)) {
    if (typeof (parsed as { command?: unknown }).command === 'string') {
      return parsed as StatusLineSetting
    }
  }
  return undefined
}

interface Staged {
  commit(): Promise<void>
  discard(): Promise<void>
}

// Write the data to a new temporary file. Flush it to disk. Do not rename yet.
// The name is unique and the open call fails if the name exists.
async function stage(
  file: string,
  data: string | Buffer,
  mode: number,
  beforeRename?: () => Promise<void>,
): Promise<Staged> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${randomUUID()}.tmp`
  const handle = await open(temporary, 'wx', mode)
  try {
    await handle.writeFile(data)
    await handle.chmod(mode)
    await handle.sync()
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  } finally {
    await handle.close().catch(() => {})
  }
  return {
    commit: async () => {
      try {
        await beforeRename?.()
        await rename(temporary, file)
      } catch (error) {
        await rm(temporary, { force: true })
        throw error
      }
    },
    discard: () => rm(temporary, { force: true }),
  }
}

async function writeAtomic(file: string, data: string | Buffer, mode = 0o600): Promise<void> {
  await (await stage(file, data, mode)).commit()
}

// Stage the settings through the real path, so a symbolic link stays a link.
// Keep the mode of the old file. A new file gets mode 0600.
// Just before the rename, read the old bytes again. If they changed, refuse.
async function stageSettings(
  file: string,
  settings: ClaudeSettings,
  oldBytes: Buffer | null,
  hooks: InstallHooks,
): Promise<Staged> {
  let target = file
  let mode = 0o600
  try {
    target = await realpath(file)
    mode = (await stat(target)).mode & 0o777
  } catch (error) {
    if (!isNotFound(error)) throw error
  }
  return stage(target, `${JSON.stringify(settings, null, 2)}\n`, mode, async () => {
    await hooks.beforeSettingsRename?.()
    const now = await readBytes(target)
    const same = now === null || oldBytes === null ? now === oldBytes : now.equals(oldBytes)
    if (!same) {
      throw new Error(
        `The file ${file} changed while Bifrost worked. Bifrost did not change it. Try again.`,
      )
    }
  })
}

function stamp(now: Date): string {
  return now
    .toISOString()
    .replace(/\.\d+Z$/, 'Z')
    .replace(/[-:]/g, '')
}

// Never overwrite an older backup. Add a number when the name exists.
function backupPathFor(files: Files, now: Date): string {
  const base = join(files.backups, `settings-${stamp(now)}`)
  let candidate = `${base}.json`
  for (let n = 1; existsSync(candidate); n += 1) candidate = `${base}-${n}.json`
  return candidate
}

// The name of a backup that backupPathFor gives: settings-<time>.json or settings-<time>-<n>.json.
const BACKUP_NAME = /^settings-(\d{8}T\d{6}Z)(?:-(\d+))?\.json$/

// Return the path of the newest backup, or null when no backup exists.
// The time in the name gives the order. The number gives the order in the same second.
async function newestBackup(files: Files): Promise<string | null> {
  let names: string[]
  try {
    names = await readdir(files.backups)
  } catch {
    return null
  }
  let best: { name: string; time: string; n: number } | null = null
  for (const name of names) {
    const match = BACKUP_NAME.exec(name)
    if (!match) continue
    const time = match[1]
    const n = match[2] === undefined ? 0 : Number(match[2])
    if (best === null || time > best.time || (time === best.time && n > best.n)) {
      best = { n, name, time }
    }
  }
  return best === null ? null : join(files.backups, best.name)
}

// The statusLine is the wrapper, but statusline-original.json is missing or not valid.
// Bifrost cannot know the command of the user. So it refuses and names the newest backup.
async function missingOriginalError(files: Files): Promise<Error> {
  const backup = (await newestBackup(files)) ?? 'no backup found'
  return new Error(
    `Bifrost cannot find your original statusLine setting. Restore it from the newest backup: ${backup}.`,
  )
}

function isWrapperNow(settings: ClaudeSettings): boolean {
  return checkInstall(settings).statusLineInstalled
}

export async function uninstall(
  paths: IntegrationPaths,
  now: Date,
  hooks: InstallHooks = {},
): Promise<void> {
  const files = filesOf(paths)
  const { settings, bytes } = await readSettings(paths.claudeSettings)
  const saved = await readSavedOriginal(files.original)
  // Without the saved original, the uninstall would delete the statusLine of the user. Write nothing.
  if (isWrapperNow(settings) && saved === undefined) throw await missingOriginalError(files)
  const next = planUninstall(settings, saved ?? null)
  // Keep statusline-original.json.
  if (bytes !== null && JSON.stringify(next) !== JSON.stringify(settings)) {
    const staged = await stageSettings(paths.claudeSettings, next, bytes, hooks)
    try {
      await writeAtomic(backupPathFor(files, now), bytes)
    } catch (error) {
      await staged.discard()
      throw error
    }
    await staged.commit()
  }
}

// Find an old hook install: each entry that uninstall removes. This is a Bifrost hook under any
// event and any matcher, or the Bifrost wrapper.
// A settings file that Bifrost cannot read gives found false and the error.
export async function oldInstallStatus(
  paths: IntegrationPaths,
): Promise<{ found: boolean; error?: string }> {
  try {
    const { settings } = await readSettings(paths.claudeSettings)
    return { found: hasBifrostEntry(settings) }
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error), found: false }
  }
}

// Decide if bin/ stays, from the result of oldInstallStatus. Old hook entries in the settings
// still run bin/. Settings that Bifrost cannot read can also have such entries. So bin/ stays in
// both cases. A wrong value breaks the statusline of a person who still has the wrapper.
export function keepOldScripts(status: { found: boolean; error?: string }): boolean {
  return status.found || status.error !== undefined
}

const OLD_DATA = ['active', 'events', 'sessions']

// Remove the data that the old hooks and the old app wrote: active, events/ and sessions/.
// Nothing else cleans these paths. A missing path is fine.
// bin/ holds the scripts that old hook entries in the settings still run. So remove bin/ only
// when keepScripts is false. Never touch mod/, live.sock, statusline-original.json or backups/.
export async function removeOldHookData(bifrostHome: string, keepScripts: boolean): Promise<void> {
  const names = keepScripts ? OLD_DATA : [...OLD_DATA, 'bin']
  for (const name of names) {
    await rm(join(bifrostHome, name), { force: true, recursive: true })
  }
}
