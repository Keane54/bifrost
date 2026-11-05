// Check that a session has a user message in its transcript, before Take control (Task 15).
// Claude Code cannot resume a session without one (Task 10 bug 3).
// Claude Code writes the transcript to <home>/.claude/projects/<project>/<session id>.jsonl.
// This module only reads.
import { open, readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { UUID_PATTERN } from '../integration/scripts'

// Bifrost reads at most this part of a transcript.
export const TRANSCRIPT_READ_BYTES = 256 * 1024

// The text of a user line in a transcript.
const USER_MESSAGE = '"type":"user"'

const UUID = new RegExp(UUID_PATTERN)

function codeOf(error: unknown): string | undefined {
  return (error as NodeJS.ErrnoException).code
}

// Read the start of a file, up to max bytes.
async function readStart(file: string, max: number): Promise<string> {
  const handle = await open(file, 'r')
  try {
    const buffer = Buffer.alloc(max)
    const { bytesRead } = await handle.read(buffer, 0, max, 0)
    return buffer.subarray(0, bytesRead).toString('utf8')
  } finally {
    await handle.close()
  }
}

// True when a transcript of the session in a folder of projectsDir has a user message in its
// first TRANSCRIPT_READ_BYTES. No transcript gives false. A read error gives true, so this check
// never blocks a session that has messages. A session ID that is not a UUID gives false, and
// no path is made from it.
export async function hasMessages(projectsDir: string, sessionId: string): Promise<boolean> {
  if (!UUID.test(sessionId)) return false
  let projects: string[]
  try {
    projects = await readdir(projectsDir)
  } catch (error) {
    return codeOf(error) !== 'ENOENT'
  }
  for (const project of projects) {
    const file = join(projectsDir, project, `${sessionId}.jsonl`)
    let text: string
    try {
      text = await readStart(file, TRANSCRIPT_READ_BYTES)
    } catch (error) {
      // No transcript in this project, or the name is a file and not a folder.
      const code = codeOf(error)
      if (code === 'ENOENT' || code === 'ENOTDIR') continue
      return true
    }
    if (text.includes(USER_MESSAGE)) return true
  }
  return false
}
