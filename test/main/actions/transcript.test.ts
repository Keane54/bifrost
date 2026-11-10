import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import {
  findTranscript,
  hasMessages,
  readTail,
  TRANSCRIPT_READ_BYTES,
  TRANSCRIPT_TAIL_MAX,
} from '../../../src/main/actions/transcript'

const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
const USER = '{"type":"user","message":{"role":"user","content":"Reply with OK."}}\n'
const OTHER = '{"type":"file-history-snapshot","messageId":"m1"}\n'

// A temporary projects folder. The tests never read the real ~/.claude.
let projects: string

beforeEach(async () => {
  projects = await mkdtemp(join(tmpdir(), 'bifrost-transcript-'))
})

afterEach(async () => {
  await chmod(projects, 0o700).catch(() => {})
  await rm(projects, { force: true, recursive: true })
})

async function transcript(project: string, text: string): Promise<string> {
  await mkdir(join(projects, project), { recursive: true })
  const file = join(projects, project, `${S}.jsonl`)
  await writeFile(file, text)
  return file
}

describe('hasMessages', () => {
  test('a transcript with a user message gives true', async () => {
    await mkdir(join(projects, '-Users-x-other'))
    await transcript('-Users-x-p', OTHER + USER)
    expect(await hasMessages(projects, S)).toBe(true)
  })

  test('no transcript, or a transcript without a user message, gives false', async () => {
    expect(await hasMessages(projects, S)).toBe(false)
    expect(await hasMessages(join(projects, 'missing'), S)).toBe(false)
    await transcript('-Users-x-p', OTHER)
    expect(await hasMessages(projects, S)).toBe(false)
    // A transcript of another session does not count.
    await writeFile(join(projects, '-Users-x-p', 'other.jsonl'), USER)
    expect(await hasMessages(projects, S)).toBe(false)
  })

  test('a file in the projects folder is not a project', async () => {
    await writeFile(join(projects, 'notes.txt'), USER)
    expect(await hasMessages(projects, S)).toBe(false)
  })

  test('only the first 256 KB count', async () => {
    expect(TRANSCRIPT_READ_BYTES).toBe(256 * 1024)
    // The user line starts at the first byte after the limit.
    await transcript('-Users-x-p', `${'x'.repeat(TRANSCRIPT_READ_BYTES - 1)}\n${USER}`)
    expect(await hasMessages(projects, S)).toBe(false)
    // The text '{"type":"user"' ends at the last byte of the limit.
    const head = '{"type":"user"'
    await transcript('-Users-x-p', `${'x'.repeat(TRANSCRIPT_READ_BYTES - head.length)}${USER}`)
    expect(await hasMessages(projects, S)).toBe(true)
  })

  test('a read error counts as a session with messages', async () => {
    // The transcript name is a folder, so the read fails.
    await mkdir(join(projects, '-Users-x-p', `${S}.jsonl`), { recursive: true })
    expect(await hasMessages(projects, S)).toBe(true)
  })

  test('a projects folder that Bifrost cannot read counts as a session with messages', async () => {
    await transcript('-Users-x-p', OTHER)
    await chmod(projects, 0o000)
    expect(await hasMessages(projects, S)).toBe(true)
  })

  test('a session ID that is not a UUID gives false and reads nothing', async () => {
    await transcript('-Users-x-p', USER)
    for (const id of ['', '../x', `${S}/../${S}`, 'abc']) {
      expect(await hasMessages(projects, id)).toBe(false)
    }
  })
})

describe('readTail (Review Focus 1)', () => {
  const TEXT = 'line1\nline2\nline3\nhalf'

  test('the limit is 4 MB', () => {
    expect(TRANSCRIPT_TAIL_MAX).toBe(4 * 1024 * 1024)
  })

  test('an offset at the start of a line keeps that line, and a half last line goes', async () => {
    const file = await transcript('-Users-x-p', TEXT)
    expect(await readTail(file, 0)).toBe('line1\nline2\nline3\n')
    expect(await readTail(file, 6)).toBe('line2\nline3\n')
  })

  test('an offset inside a line drops the rest of that line', async () => {
    const file = await transcript('-Users-x-p', TEXT)
    expect(await readTail(file, 2)).toBe('line2\nline3\n')
    // The byte at the offset is the line break of the cut line.
    expect(await readTail(file, 5)).toBe('line2\nline3\n')
  })

  test('no full line gives an empty text', async () => {
    const file = await transcript('-Users-x-p', TEXT)
    expect(await readTail(file, 18)).toBe('')
    expect(await readTail(file, TEXT.length)).toBe('')
    expect(await readTail(file, 20)).toBe('')
  })

  test('an offset inside a character of a cut line gives clean text', async () => {
    // "é" is two bytes. Offset 1 is between them.
    const file = await transcript('-Users-x-p', 'éé\n{"a":"é"}\n')
    expect(await readTail(file, 1)).toBe('{"a":"é"}\n')
  })

  test('more than maxBytes after the offset rejects', async () => {
    const file = await transcript('-Users-x-p', TEXT)
    // 22 bytes from offset 0.
    await expect(readTail(file, 0, 21)).rejects.toThrow('The reply is too long to read.')
    expect(await readTail(file, 0, 22)).toBe('line1\nline2\nline3\n')
    expect(await readTail(file, 6, 16)).toBe('line2\nline3\n')
  })

  test('an offset after the end of the file rejects', async () => {
    const file = await transcript('-Users-x-p', TEXT)
    await expect(readTail(file, TEXT.length + 1)).rejects.toThrow()
    await expect(readTail(file, -1)).rejects.toThrow()
  })
})

describe('findTranscript', () => {
  const S2 = '0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d'

  test('a transcriptPath that names the session file is used', async () => {
    await transcript('-Users-x-a', USER)
    const own = await transcript('-Users-x-b', USER)
    expect(await findTranscript(projects, { sessionId: S, transcriptPath: own })).toBe(own)
  })

  test('without a matching transcriptPath, the projects folder is searched', async () => {
    const file = await transcript('-Users-x-p', USER)
    await mkdir(join(projects, '-Users-x-other'))
    await writeFile(join(projects, 'notes.txt'), USER)
    expect(await findTranscript(projects, { sessionId: S })).toBe(file)
    // A path of another session, or a path that is not a file, is not used.
    const other = join(projects, '-Users-x-other', `${S2}.jsonl`)
    await writeFile(other, USER)
    expect(await findTranscript(projects, { sessionId: S, transcriptPath: other })).toBe(file)
    const missing = join(projects, '-Users-x-gone', `${S}.jsonl`)
    expect(await findTranscript(projects, { sessionId: S, transcriptPath: missing })).toBe(file)
    const notJsonl = join(projects, `x${S}.jsonl`)
    await writeFile(notJsonl, USER)
    expect(await findTranscript(projects, { sessionId: S, transcriptPath: notJsonl })).toBe(file)
  })

  test('a folder with the transcript name is not a transcript', async () => {
    const folder = join(projects, '-Users-x-a', `${S}.jsonl`)
    await mkdir(folder, { recursive: true })
    expect(await findTranscript(projects, { sessionId: S, transcriptPath: folder })).toBeNull()
  })

  test('the current ID comes before the session ID', async () => {
    await transcript('-Users-x-p', USER)
    await mkdir(join(projects, '-Users-x-q'))
    const current = join(projects, '-Users-x-q', `${S2}.jsonl`)
    await writeFile(current, USER)
    expect(await findTranscript(projects, { currentId: S2, sessionId: S })).toBe(current)
  })

  test('no transcript gives null', async () => {
    expect(await findTranscript(projects, { sessionId: S })).toBeNull()
    expect(await findTranscript(join(projects, 'missing'), { sessionId: S })).toBeNull()
  })

  test('an ID that is not a UUID gives null', async () => {
    const file = await transcript('-Users-x-p', USER)
    for (const id of ['', '../x', `${S}/../${S}`, 'abc']) {
      expect(await findTranscript(projects, { sessionId: id, transcriptPath: file })).toBeNull()
      expect(await findTranscript(projects, { currentId: id, sessionId: S })).toBeNull()
    }
  })
})
