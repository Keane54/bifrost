// Text checks of the update files of a release build. verify-release.ts uses them. They have no
// file or process access, so the unit tests can use them.

// The number of spaces before the first character of the line.
function indentOf(line: string): number {
  return line.length - line.trimStart().length
}

// The sha512 of the files entry of the url in latest-mac.yml, or null. An entry starts with the
// line "- url: <url>". Its other lines have more indent than the dash, in any order. So the
// function reads each line of the entry, and stops at the next entry or at a top-level key.
export function feedSha512(feed: string, url: string): string | null {
  const lines = feed.split('\n')
  const start = lines.findIndex(line => line.trim() === `- url: ${url}`)
  if (start < 0) return null
  const dash = indentOf(lines[start] ?? '')
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === '') continue
    if (indentOf(line) <= dash) return null
    const found = /^sha512: (\S+)$/.exec(line.trim())
    if (found) return found[1] ?? null
  }
  return null
}

// True when app-update.yml names the owner and the repo.
export function namesRepo(appUpdate: string, owner: string, repo: string): boolean {
  const lines = appUpdate.split('\n').map(line => line.trim())
  return lines.includes(`owner: ${owner}`) && lines.includes(`repo: ${repo}`)
}
