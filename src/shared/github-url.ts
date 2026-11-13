// The check for the link of a reviewer comment. The main process uses it twice: when it saves a
// question, and before it opens the link in the browser.

// The longest link that Bifrost saves or opens, in characters.
export const MAX_COMMENT_URL = 500

// The URL when it is a safe link to github.com. Else null. A safe link has the protocol https:,
// the host github.com exactly, no user name, no password and no port.
export function githubCommentUrl(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_COMMENT_URL) return null
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return null
  }
  const safe =
    url.protocol === 'https:' &&
    url.hostname === 'github.com' &&
    url.username === '' &&
    url.password === '' &&
    url.port === ''
  // The parsed href has no tab or line break.
  return safe ? url.href : null
}
