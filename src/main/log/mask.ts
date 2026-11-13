// Hide a token in a text before the text goes to a log or to the user.

// The known forms of a token. One list serves the Event log, the updater and the hand-over.
const TOKEN_PATTERNS: readonly RegExp[] = [
  /gh[opsu]_[A-Za-z0-9]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /sk-ant-[A-Za-z0-9_-]{20,}/g,
  /AKIA[0-9A-Z]{16}/g,
  /xox[abpr]-[A-Za-z0-9-]{10,}/g,
]

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// Replace the known token and any token-like text with the replacement (*** by default).
export function maskToken(text: string, token: string | null, replacement = '***'): string {
  let out = text
  if (token) out = out.replace(new RegExp(escapeRegExp(token), 'g'), () => replacement)
  return TOKEN_PATTERNS.reduce((result, pattern) => result.replace(pattern, () => replacement), out)
}
