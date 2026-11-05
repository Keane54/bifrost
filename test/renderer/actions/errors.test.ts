import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { FRIENDLY_ERRORS, friendlyError } from '../../../src/renderer/src/actions/errors'

const ROOT = join(__dirname, '../../../src')
// The em dash, written as a code. The source holds no em dash character.
const EM_DASH = String.fromCharCode(0x2014)

function tsFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return tsFiles(path)
    return entry.name.endsWith('.ts') ? [path] : []
  })
}

// Each 'refused: ...' literal in the main process and the shared code.
function refusedCodes(): string[] {
  const codes = new Set<string>()
  for (const file of [...tsFiles(join(ROOT, 'main')), ...tsFiles(join(ROOT, 'shared'))]) {
    for (const match of readFileSync(file, 'utf8').matchAll(/'(refused: [^']+)'/g)) {
      codes.add(match[1] as string)
    }
  }
  return [...codes].sort()
}

describe('friendly errors', () => {
  it('finds the refusal codes in the source', () => {
    expect(refusedCodes().length).toBeGreaterThan(20)
    expect(refusedCodes()).toContain('refused: the session has an open prompt')
  })

  it('has a friendly text for each refusal code of the main process', () => {
    const missing = refusedCodes().filter(code => !(code in FRIENDLY_ERRORS))
    expect(missing).toEqual([])
  })

  it('gives the exact friendly text of two codes', () => {
    expect(friendlyError('refused: the session has an open prompt')).toBe(
      'This session is waiting on a prompt. Answer it in the chat window first.',
    )
    expect(friendlyError('refused: an action on this session runs')).toBe(
      'Another action is still running on this session. Try again in a moment.',
    )
  })

  it('removes the prefix of an unknown code and starts it with a capital letter', () => {
    expect(friendlyError('refused: a new code')).toBe('A new code')
  })

  it('gives a friendly text for a process that is not claude', () => {
    expect(friendlyError('refused: process 4242 is not a claude process')).toBe(
      "Process 4242 isn't a Claude process, so Bifrost left it alone.",
    )
  })

  it('keeps any other message as it is', () => {
    expect(friendlyError('Answer the prompt in the chat window first.')).toBe(
      'Answer the prompt in the chat window first.',
    )
    expect(friendlyError('claude stop failed: exit 1')).toBe('claude stop failed: exit 1')
  })

  it('has short texts with no refusal code and no em dash', () => {
    for (const text of Object.values(FRIENDLY_ERRORS)) {
      expect(text.startsWith('refused')).toBe(false)
      expect(text).not.toContain(EM_DASH)
      expect(text.length).toBeLessThanOrEqual(100)
    }
  })
})
