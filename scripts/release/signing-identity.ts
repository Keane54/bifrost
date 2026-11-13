// This script finds the signing identity in the keychain of the Release workflow.
// The workflow pipes the output of "security find-identity -v -p codesigning" to this script.
// The script finds exactly one "Developer ID Application: <name> (<TEAMID>)" identity. It writes
// APPLE_SIGNING_IDENTITY (the name, with no "Developer ID Application:") and APPLE_TEAM_ID to the
// file in GITHUB_ENV. Both values are public, because every released app shows them in its code
// signature. So the repo and the secrets hold no signing name (user decision, 2026-11-13).
import { appendFileSync, readFileSync } from 'node:fs'

const PREFIX = 'Developer ID Application: '
// A line of the output: the number, the 40 hex characters of the hash, and the quoted name.
const IDENTITY_LINE = /^\s*\d+\)\s+[0-9A-Fa-f]{40}\s+"(.*)"\s*$/
const TEAM_ID = /^[A-Z0-9]{10}$/
const NAME_WITH_TEAM = /^(.*) \(([^()]*)\)$/

export type SigningResult =
  | { ok: true; identity: string; teamId: string }
  | { ok: false; message: string }

// The identity and the team ID from the output of "security find-identity". An identity that is
// not Developer ID Application is ignored. Zero or many Developer ID identities give an error.
export function parseSigningIdentity(text: string): SigningResult {
  const names: string[] = []
  for (const line of text.split(/\r?\n/)) {
    const name = IDENTITY_LINE.exec(line)?.[1]
    if (name?.startsWith(PREFIX)) names.push(name.slice(PREFIX.length))
  }
  if (names.length === 0) {
    return {
      message:
        'No Developer ID Application identity is in the keychain. ' +
        'Check that the CSC_LINK secret holds a Developer ID Application certificate with its ' +
        'private key. See RELEASING.md.',
      ok: false,
    }
  }
  if (names.length > 1) {
    return {
      message:
        `The keychain holds ${names.length} Developer ID Application identities. ` +
        'The CSC_LINK secret must hold exactly one. See RELEASING.md.',
      ok: false,
    }
  }
  const name = names[0] ?? ''
  const teamId = NAME_WITH_TEAM.exec(name)?.[2] ?? ''
  if (!TEAM_ID.test(teamId)) {
    return {
      message:
        'The name of the Developer ID Application identity must end with the team ID in ' +
        'brackets. The team ID is 10 upper-case letters and digits.',
      ok: false,
    }
  }
  return { identity: name, ok: true, teamId }
}

if (import.meta.main) {
  const result = parseSigningIdentity(readFileSync(0, 'utf8'))
  const envFile = process.env.GITHUB_ENV
  if (!result.ok) {
    console.error(result.message)
    process.exitCode = 1
  } else if (envFile === undefined || envFile === '') {
    console.error('GITHUB_ENV is not set.')
    process.exitCode = 1
  } else {
    appendFileSync(
      envFile,
      `APPLE_SIGNING_IDENTITY=${result.identity}\nAPPLE_TEAM_ID=${result.teamId}\n`,
    )
  }
}
