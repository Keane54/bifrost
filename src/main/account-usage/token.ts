// Read the access token of the Claude Code login from the macOS Keychain (spec 8.8).
// SECURITY: this module never logs, stores or returns the Keychain text. It returns the access
// token only, and only in memory. It never reads the refresh token.
import type { ExecFn } from '../claude/cli'

export const SECURITY_PATH = '/usr/bin/security'
export const KEYCHAIN_SERVICE = 'Claude Code-credentials'
// Fixed arguments. -w prints the secret text, and the reader keeps it in memory only.
export const KEYCHAIN_ARGS: readonly string[] = [
  'find-generic-password',
  '-s',
  KEYCHAIN_SERVICE,
  '-w',
]
export const KEYCHAIN_TIMEOUT_MS = 10_000
export const EXPIRY_MARGIN_MS = 60_000

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// Return the access token, or null for "no token". Null covers: a failed command, bad JSON, a
// missing field, and a token that has expired. This function never throws and never writes to
// the console, so no error text can hold the Keychain data.
export async function readAccessToken(exec: ExecFn, now: number): Promise<string | null> {
  try {
    const result = await exec(SECURITY_PATH, [...KEYCHAIN_ARGS], { timeoutMs: KEYCHAIN_TIMEOUT_MS })
    if (result.code !== 0 || result.timedOut) return null
    const data: unknown = JSON.parse(result.stdout)
    if (!isRecord(data) || !isRecord(data.claudeAiOauth)) return null
    const { accessToken, expiresAt } = data.claudeAiOauth
    if (typeof accessToken !== 'string' || accessToken === '') return null
    // A token with no expiry time is another shape. A token that ends within the margin could
    // expire during the request, so it counts as expired.
    if (typeof expiresAt !== 'number' || !Number.isFinite(expiresAt)) return null
    if (expiresAt <= now + EXPIRY_MARGIN_MS) return null
    return accessToken
  } catch {
    return null
  }
}
