// The extra usage flag of ~/.claude.json, for the usage notification. Bifrost reads the file only
// when a notification is about to show and the account values do not give the flag. It never
// writes the file and never logs its content, because the file holds account data.
import { readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { extraUsageOfClaudeJson } from './rules'

// Bifrost skips a file above this size.
export const MAX_CLAUDE_JSON_BYTES = 20 * 1024 * 1024

// The file in the home folder. Bifrost gives the same home folder as for ~/.claude, so a test home
// uses its own file.
export function claudeJsonFile(home: string): string {
  return join(home, '.claude.json')
}

// True only when the file has oauthAccount.hasExtraUsageEnabled true. A missing file, a file that
// is not a regular file, a file above 20 MB and a file that is not valid JSON give false. The
// function never rejects. An error goes nowhere, because its text can hold a part of the file.
export async function readExtraUsageFlag(file: string): Promise<boolean> {
  try {
    const info = await stat(file)
    if (!info.isFile() || info.size > MAX_CLAUDE_JSON_BYTES) return false
    const bytes = await readFile(file)
    // The file can get larger after the stat.
    if (bytes.length > MAX_CLAUDE_JSON_BYTES) return false
    return extraUsageOfClaudeJson(JSON.parse(bytes.toString('utf8')))
  } catch {
    return false
  }
}
