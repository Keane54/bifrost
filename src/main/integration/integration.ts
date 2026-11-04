// File IO for the Claude Code integration.
// This code changes the settings file of the user. It must never lose or corrupt that file.
// Every write goes to a temporary name in the same directory. Then it renames the file.

import { existsSync } from 'node:fs'
import { chmod, mkdir, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { InstallPreview, IntegrationStatus } from '../../shared/types'
import { HOOK_SCRIPT, statuslineScript } from './scripts'
import {
  type ClaudeSettings,
  checkInstall,
  planInstall,
  planUninstall,
  type StatusLineSetting,
} from './settings-plan'

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
  hook: string
  statusline: string
  original: string
  backups: string
}

function filesOf(paths: IntegrationPaths): Files {
  const home = paths.bifrostHome
  return {
    backups: join(home, 'backups'),
    hook: join(home, 'bin', 'bifrost-hook'),
    original: join(home, 'statusline-original.json'),
    statusline: join(home, 'bin', 'bifrost-statusline'),
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

// A missing file counts as an empty object.
async function readSettings(
  file: string,
): Promise<{ settings: ClaudeSettings; text: string | null }> {
  const text = await readText(file)
  if (text === null) return { settings: {}, text }
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new Error(`The file ${file} is not valid JSON. Bifrost did not change it.`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Unexpected type in ${file}. Expect a JSON object. Bifrost did not change it.`)
  }
  return { settings: parsed as ClaudeSettings, text }
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

async function writeAtomic(file: string, data: string, mode?: number): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`
  try {
    await writeFile(temporary, data, mode === undefined ? undefined : { mode })
    if (mode !== undefined) await chmod(temporary, mode)
    await rename(temporary, file)
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
}

// Write the settings through the real path, so a symbolic link stays a link.
// Keep the mode of the old file.
async function writeSettings(file: string, settings: ClaudeSettings): Promise<void> {
  let target = file
  let mode: number | undefined
  try {
    target = await realpath(file)
    mode = (await stat(target)).mode & 0o777
  } catch (error) {
    if (!isNotFound(error)) throw error
  }
  await writeAtomic(target, `${JSON.stringify(settings, null, 2)}\n`, mode)
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

function scriptTexts(original: StatusLineSetting | null): { hook: string; statusline: string } {
  return { hook: HOOK_SCRIPT, statusline: statuslineScript(original?.command ?? null) }
}

async function scriptsCurrent(files: Files, original: StatusLineSetting | null): Promise<boolean> {
  const texts = scriptTexts(original)
  return (
    (await readText(files.hook)) === texts.hook &&
    (await readText(files.statusline)) === texts.statusline
  )
}

function isWrapperNow(settings: ClaudeSettings): boolean {
  return checkInstall(settings).statusLineInstalled
}

export async function previewInstall(paths: IntegrationPaths, now: Date): Promise<InstallPreview> {
  const files = filesOf(paths)
  const { settings, text } = await readSettings(paths.claudeSettings)
  const plan = planInstall(settings, await readSavedOriginal(files.original))
  const changes = plan.changes.length > 0
  return {
    backupPath: text !== null && changes ? backupPathFor(files, now) : null,
    changes: plan.changes,
    originalCommand: plan.original?.command ?? null,
  }
}

export async function install(paths: IntegrationPaths, now: Date): Promise<IntegrationStatus> {
  const files = filesOf(paths)
  const { settings, text } = await readSettings(paths.claudeSettings)
  const saved = await readSavedOriginal(files.original)
  // This call can throw. Then nothing is written.
  const plan = planInstall(settings, saved)

  const settingsChange = plan.changes.length > 0
  if (settingsChange || !(await scriptsCurrent(files, plan.original))) {
    if (text !== null && settingsChange) {
      await writeAtomic(backupPathFor(files, now), text)
    }
    const texts = scriptTexts(plan.original)
    await writeAtomic(files.hook, texts.hook, 0o755)
    await writeAtomic(files.statusline, texts.statusline, 0o755)
    if (!isWrapperNow(settings)) {
      await writeAtomic(files.original, `${JSON.stringify(plan.original)}\n`)
    }
    if (settingsChange) await writeSettings(paths.claudeSettings, plan.next)
  }
  return integrationStatus(paths)
}

export async function uninstall(paths: IntegrationPaths, now: Date): Promise<IntegrationStatus> {
  const files = filesOf(paths)
  const { settings, text } = await readSettings(paths.claudeSettings)
  const saved = await readSavedOriginal(files.original)
  const next = planUninstall(settings, saved ?? null)
  // Keep statusline-original.json. A later install overwrites it when it must.
  if (text !== null && JSON.stringify(next) !== JSON.stringify(settings)) {
    await writeAtomic(backupPathFor(files, now), text)
    await writeSettings(paths.claudeSettings, next)
  }
  return integrationStatus(paths)
}

export async function integrationStatus(paths: IntegrationPaths): Promise<IntegrationStatus> {
  const files = filesOf(paths)
  const scriptsPresent = existsSync(files.hook) && existsSync(files.statusline)
  try {
    const { settings } = await readSettings(paths.claudeSettings)
    const check = checkInstall(settings)
    return {
      installed: check.missingHooks.length === 0 && check.statusLineInstalled && scriptsPresent,
      missingHooks: check.missingHooks,
      scriptsPresent,
      statusLineInstalled: check.statusLineInstalled,
    }
  } catch (error) {
    return {
      error: error instanceof Error ? error.message : String(error),
      installed: false,
      missingHooks: [],
      scriptsPresent,
      statusLineInstalled: false,
    }
  }
}
