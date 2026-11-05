import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { hasMessages, TRANSCRIPT_READ_BYTES } from '../../../src/main/actions/transcript'

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
