// The secret filter of Heimdall (Modules design 8.3). Each value that Heimdall gives to a module,
// and each input and result of a module job of a module, goes through it. It is wider than
// maskToken: it first applies maskToken, and then the formats below.

import { maskToken } from '../log/mask'

const MASK = '***'

// The first or the last line of a private key block: "-----BEGIN RSA PRIVATE KEY-----".
function keyLine(word: 'BEGIN' | 'END'): string {
  return `-----${word} [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----`
}

// The known formats of a secret. maskToken knows some of them too.
const SECRET_PATTERNS: readonly RegExp[] = [
  // A private key block, also a block with no end line (a cut text).
  new RegExp(`${keyLine('BEGIN')}[\\s\\S]*?(?:${keyLine('END')}|$)`, 'g'),
  // A JSON web token: header.payload.signature. The header starts with eyJ ('{"' in base64).
  /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g,
  /gh[oprsu]_[A-Za-z0-9]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /sk-ant-[A-Za-z0-9_-]{20,}/g,
  /(?:AKIA|ASIA)[0-9A-Z]{16}/g,
  /xox[abpre]-[A-Za-z0-9-]{10,}/g,
  /xapp-[A-Za-z0-9-]{10,}/g,
  /[rs]k_live_[A-Za-z0-9]{16,}/g,
  /AIza[0-9A-Za-z_-]{35}/g,
  /npm_[A-Za-z0-9]{30,}/g,
]

// The value of a Bearer header. The word "Bearer" stays, so the text keeps its sense.
const BEARER = /\b(Bearer\s+)[A-Za-z0-9._~+/-]{16,}=*/gi

// Replace each known secret in the text with ***.
export function filterSecrets(text: string): string {
  const out = maskToken(text, null, MASK).replace(BEARER, (_all, word: string) => `${word}${MASK}`)
  return SECRET_PATTERNS.reduce((result, pattern) => result.replace(pattern, () => MASK), out)
}

// A JSON copy of the value with each string filtered, also each object key. A value that JSON
// cannot hold gives null. Each object of the copy is a new plain object, so a "__proto__" key
// stays an own key and does not change a prototype. A value that is not JSON (a cycle or a
// BigInt) or that is nested too deep for JSON throws.
export function filterSecretValue(value: unknown): unknown {
  const text = JSON.stringify(value)
  if (text === undefined) return null
  return JSON.parse(text, (_key, item: unknown) => {
    if (typeof item === 'string') return filterSecrets(item)
    if (item === null || typeof item !== 'object' || Array.isArray(item)) return item
    return Object.fromEntries(Object.entries(item).map(([k, v]) => [filterSecrets(k), v]))
  })
}
