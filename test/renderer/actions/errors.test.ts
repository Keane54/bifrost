import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  FRIENDLY_ERRORS,
  friendlyError,
  handOverFailure,
} from '../../../src/renderer/src/actions/errors'

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

  it('gives the exact texts of the Delete and Take control refusals of Task 15', () => {
    expect(friendlyError('refused: claude rm kept the worktree')).toBe(
      'Claude Code kept this session, because its worktree has commits that exist on no remote. Open the worktree to check them, then delete again.',
    )
    expect(friendlyError('refused: the worktree changed after the check')).toBe(
      'The worktree changed after the check. Check it again, then delete.',
    )
    expect(friendlyError('refused: the session has no messages yet')).toBe(
      "This session has no messages yet, so there's nothing to take over. Send a message in its terminal first.",
    )
  })

  it('gives the exact texts of the Delete refusals of Task 18', () => {
    expect(friendlyError('refused: claude rm took too long')).toBe(
      'Claude Code took too long to delete this session. Check the worktree, then delete again.',
    )
    expect(friendlyError('refused: the worktree has uncommitted changes')).toBe(
      "This worktree has changes that aren't committed, so Claude Code won't delete it. Open the worktree, commit or discard them, then delete again.",
    )
  })

  it('gives the exact text of the Delete block of a folder in use (spec 8)', () => {
    expect(friendlyError('refused: another session uses this folder')).toBe(
      'Another session is still using this folder. Stop that session first, then delete this one.',
    )
  })

  it('gives the friendly texts of the final review fixes', () => {
    expect(friendlyError('refused: the send was cancelled by Interrupt')).toBe(
      'Interrupt cancelled this message before it was sent.',
    )
    expect(friendlyError('claude not found')).toBe(
      "Bifrost can't find Claude Code. Check that the claude command works in a terminal.",
    )
  })

  it('gives a friendly text for a failed read of the session list', () => {
    // Node gives this text when the timeout ended claude agents (Task 17 bug 4).
    for (const text of [
      'Command failed: /Users/x/.local/bin/claude agents --json',
      'Command failed: /Users/x/.local/bin/claude agents --json --all',
      'Command failed: /Users/x/.local/bin/claude agents --json\nsome stderr',
    ]) {
      expect(friendlyError(text)).toBe(
        "Bifrost couldn't read the session list. It tries again in a moment.",
      )
    }
  })

  it('gives a friendly text for another failed command', () => {
    for (const text of [
      'Command failed: /Users/x/.local/bin/claude rm 27b87cbf --discard-unpushed a@b',
      'Command failed: /Users/x/.local/bin/claude stop abcd1234',
    ]) {
      expect(friendlyError(text)).toBe('A Claude Code command failed. Try again in a moment.')
    }
    // Only a text that starts with the Node text changes.
    expect(friendlyError('claude agents --json: Command failed: x')).toBe(
      'claude agents --json: Command failed: x',
    )
  })

  it('friendlyError gives one text for a bad or unknown setting', () => {
    for (const code of [
      'refused: bad pollSeconds',
      'refused: bad terminalFont',
      'refused: unknown setting theme',
      'refused: unknown setting version',
    ]) {
      expect(friendlyError(code)).toBe("That setting isn't valid.")
    }
    // A code that does not name a setting keeps the general rule.
    expect(friendlyError('refused: bad colour')).toBe('Bad colour')
  })

  it('gives the exact texts of the settings refusals', () => {
    expect(friendlyError('refused: bad settings')).toBe("Bifrost couldn't read those settings.")
    expect(friendlyError('refused: bad slashCommands')).toBe(
      "That list of slash commands isn't valid.",
    )
    expect(friendlyError('refused: bad keys')).toBe("One of those keys isn't valid.")
    expect(friendlyError('refused: two keys have the same binding')).toBe(
      "Two actions can't share the same key.",
    )
  })

  // The error line wraps to more lines (Task 15). So a text can have two sentences.
  it('has short texts with no refusal code and no em dash', () => {
    for (const text of Object.values(FRIENDLY_ERRORS)) {
      expect(text.startsWith('refused')).toBe(false)
      expect(text).not.toContain(EM_DASH)
      expect(text.length).toBeLessThanOrEqual(150)
    }
  })
})

describe('handOverFailure', () => {
  const lead = "The note is saved at /a/b.md, but the new session didn't start."

  it('adds the friendly text of a code after the lead text', () => {
    expect(handOverFailure(`${lead} refused: unknown model`)).toBe(
      `${lead} Bifrost doesn't know that model.`,
    )
  })

  it('uses the generic fallback for an unknown code', () => {
    expect(handOverFailure(`${lead} refused: something odd`)).toBe(`${lead} Something odd`)
  })

  it('keeps the friendlyError path for a message that is only a code', () => {
    expect(handOverFailure('refused: unknown model')).toBe(friendlyError('refused: unknown model'))
  })

  it('keeps a message without a code as it is', () => {
    expect(handOverFailure(lead)).toBe(lead)
  })
})
