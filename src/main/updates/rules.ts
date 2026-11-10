// Pure rules for the updater. This file has no Electron import.
import type { UpdateCause } from '../../shared/updates'

export const CHECK_DELAY_MS = 10_000
export const CHECK_INTERVAL_MS = 60 * 60_000

const TOKEN_PATTERN = /gh[opsu]_[A-Za-z0-9]{20,}/g
const DETAIL_MAX = 200

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// Replace the known token and any token-like text with ***.
export function maskToken(text: string, token: string | null): string {
  let out = text
  if (token) out = out.replace(new RegExp(escapeRegExp(token), 'g'), '***')
  return out.replace(TOKEN_PATTERN, '***')
}

export type ErrorClass =
  | { kind: 'offline' }
  | { kind: 'failed'; cause: UpdateCause; detail: string }

const OFFLINE = /ENOTFOUND|ECONNRESET|ETIMEDOUT|ERR_INTERNET_DISCONNECTED/
const NO_ACCESS = /\b(401|403|404)\b/
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
  if (phase === 'check' && NO_ACCESS.test(message))
    return { cause: 'no-access', detail, kind: 'failed' }
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
