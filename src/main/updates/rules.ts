// Pure rules for the updater. This file has no Electron import.
import { dirname } from 'node:path'
import type { UpdateCause } from '../../shared/updates'
import { maskToken } from '../log/mask'

export { maskToken }

export const CHECK_DELAY_MS = 10_000
export const CHECK_INTERVAL_MS = 60 * 60_000

const DETAIL_MAX = 200

export type ErrorClass =
  | { kind: 'offline' }
  | { kind: 'failed'; cause: UpdateCause; detail: string }

const OFFLINE = /ENOTFOUND|ECONNRESET|ETIMEDOUT|ERR_INTERNET_DISCONNECTED/
const BAD_PACKAGE = /checksum|signature/i

function messageOf(err: unknown): string {
  if (err instanceof Error) return err.message
  if (typeof err === 'string') return err
  return ''
}

export function classifyError(
  err: unknown,
  phase: 'check' | 'download' | 'install',
  online: boolean,
): ErrorClass {
  const message = messageOf(err)
  if (!online || OFFLINE.test(message)) return { kind: 'offline' }
  const detail = message.split('\n')[0].slice(0, DETAIL_MAX)
  if (BAD_PACKAGE.test(message) && phase !== 'check')
    return { cause: phase, detail, kind: 'failed' }
  return { cause: phase === 'check' ? 'github' : phase, detail, kind: 'failed' }
}

// True when the app sits where it cannot update itself.
export function locationProblem(appPath: string, canWrite: boolean): boolean {
  if (appPath.startsWith('/Volumes/')) return true
  if (appPath.includes('/AppTranslocation/')) return true
  return !canWrite
}

// The .app folder that holds the executable: the nearest folder above it with a name that ends in
// .app. With no such folder, the result is the path itself.
export function appBundlePath(exe: string): string {
  for (let dir = dirname(exe); dir !== dirname(dir); dir = dirname(dir)) {
    if (dir.endsWith('.app')) return dir
  }
  return exe
}
