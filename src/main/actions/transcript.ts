// Read the transcript of a session.
// Take control checks that a session has a user message first (Task 15). Claude Code cannot
// resume a session without one (Task 10 bug 3). The Hand over button finds the transcript and
// reads the lines after a baseline (spec 8).
// Claude Code writes the transcript to <home>/.claude/projects/<project>/<session id>.jsonl.
// This module only reads.
import { open, readdir, stat } from 'node:fs/promises'
import { join, resolve, sep } from 'node:path'
import type { SessionRow } from '../../shared/types'
import { UUID_PATTERN } from '../../shared/uuid'

// hasMessages reads at most this part of a transcript.
export const TRANSCRIPT_READ_BYTES = 256 * 1024
// readTail reads at most this part of a transcript after the baseline.
export const TRANSCRIPT_TAIL_MAX = 4 * 1024 * 1024

const REASON_TAIL_LONG = 'The reply is too long to read.'
const REASON_SHORTER = 'The transcript got shorter while Bifrost read it.'
const REASON_BAD_OFFSET = "The place to read from in the transcript isn't valid."
const NEWLINE = 0x0a

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

// True when the path is a regular file. A read error gives false.
async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile()
  } catch {
    return false
  }
}

// The transcriptPath of the row as an absolute path, when it names the file of the ID inside
// projectsDir. Else undefined. A path with ".." that goes out of projectsDir is not used.
function ownTranscript(
  projectsDir: string,
  path: string | undefined,
  fileName: string,
): string | undefined {
  if (path === undefined || !path.endsWith(`/${fileName}`)) return undefined
  const full = resolve(path)
  return full.startsWith(resolve(projectsDir) + sep) ? full : undefined
}

// The transcript of the conversation that the row shows now. The ID is currentId, else
// sessionId, and it must be a UUID. The transcriptPath of the row comes first, when it names
// the file of that ID inside projectsDir. Else the first project folder with the file counts.
// No file gives null.
export async function findTranscript(
  projectsDir: string,
  row: Pick<SessionRow, 'sessionId' | 'currentId' | 'transcriptPath'>,
): Promise<string | null> {
  const id = row.currentId ?? row.sessionId
  if (!UUID.test(id)) return null
  const fileName = `${id}.jsonl`
  const own = ownTranscript(projectsDir, row.transcriptPath, fileName)
  if (own !== undefined && (await isFile(own))) return own
  let projects: string[]
  try {
    projects = await readdir(projectsDir)
  } catch {
    return null
  }
  for (const project of projects.sort()) {
    const file = join(projectsDir, project, fileName)
    if (await isFile(file)) return file
  }
  return null
}

// Read the full lines of a file from offset to the end (Review Focus 1).
// Claude Code can write the file while Bifrost reads it. When the byte before offset is not a
// line break, offset is inside a line. Then this function removes the text up to the first line
// break. A last line without a line break is not complete, so this function removes it too.
// A later read gets that line in full. Neither case is an error.
// More than maxBytes after offset rejects. An offset after the end of the file rejects.
export async function readTail(
  file: string,
  offset: number,
  maxBytes: number = TRANSCRIPT_TAIL_MAX,
): Promise<string> {
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error(REASON_BAD_OFFSET)
  const handle = await open(file, 'r')
  try {
    const { size } = await handle.stat()
    if (offset > size) throw new Error(REASON_SHORTER)
    if (size - offset > maxBytes) throw new Error(REASON_TAIL_LONG)
    // Read one byte more before offset, to know if offset is at the start of a line.
    const from = offset === 0 ? 0 : offset - 1
    const buffer = Buffer.alloc(size - from)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, from)
    const bytes = buffer.subarray(0, bytesRead)
    let start = offset - from
    if (offset > 0 && bytes[0] !== NEWLINE) {
      const first = bytes.indexOf(NEWLINE, start)
      if (first === -1) return ''
      start = first + 1
    }
    const end = bytes.lastIndexOf(NEWLINE)
    if (end < start) return ''
    return bytes.subarray(start, end + 1).toString('utf8')
  } finally {
    await handle.close()
  }
}
