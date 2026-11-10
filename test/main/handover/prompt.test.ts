import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'
import {
  continuePrompt,
  handOverPrompt,
  handOverRulesPath,
  NOTE_END,
  NOTE_START,
  requestLine,
} from '../../../src/main/handover/prompt'
import { cleanText, MAX_TEXT } from '../../../src/shared/input'
import { isClaudeCommand } from '../../../src/shared/new-session'

// The repository root. In the dev app, the app path is this folder.
const ROOT = fileURLToPath(new URL('../../../', import.meta.url))
// The real rules file of the bifrost-hand-over skill.
const RULES = readFileSync(handOverRulesPath(ROOT), 'utf8')

describe('handOverRulesPath', () => {
  test('the path is in the skills folder of the app', () => {
    expect(handOverRulesPath('/A/Bifrost.app/Contents/Resources/app.asar')).toBe(
      '/A/Bifrost.app/Contents/Resources/app.asar.unpacked/resources/bifrost-skills/skills/' +
        'bifrost-hand-over/hand-over-rules.md',
    )
  })
})

describe('handOverPrompt', () => {
  const prompt = handOverPrompt(RULES, 'ab12cd34')
  const lines = prompt.split('\n')

  test('the first line is the request line', () => {
    expect(requestLine('ab12cd34')).toBe('Bifrost hand-over request ab12cd34')
    expect(lines[0]).toBe(requestLine('ab12cd34'))
  })

  test('the prompt holds the rules text unchanged', () => {
    expect(RULES.length).toBeGreaterThan(1000)
    expect(prompt).toContain(RULES)
  })

  test('the prompt tells Claude to change nothing', () => {
    expect(prompt).toContain('Use no tool')
  })

  test('each marker is on a line of its own, after the rules', () => {
    expect(lines.filter(line => line === NOTE_START)).toHaveLength(1)
    expect(lines.filter(line => line === NOTE_END)).toHaveLength(1)
    expect(lines.indexOf(NOTE_START)).toBeLessThan(lines.indexOf(NOTE_END))
    expect(prompt.indexOf(RULES)).toBeLessThan(prompt.indexOf(NOTE_START))
  })

  test('the prompt passes the checks of the send box unchanged', () => {
    expect(prompt.length).toBeLessThanOrEqual(MAX_TEXT)
    expect(cleanText(prompt)).toBe(prompt)
    expect(prompt.startsWith('/')).toBe(false)
  })
})

describe('continuePrompt', () => {
  const note = '# Hand-over: fix login\n\n## Goal and scope\nfix the login'
  const path = '/Users/x/.bifrost/handovers/fix-login-20261110-090507.md'
  const prompt = continuePrompt(note, path)

  test('the prompt holds the note and the path of the note file', () => {
    expect(prompt).toContain(note)
    expect(prompt).toContain(path)
    expect(prompt.endsWith(note)).toBe(true)
  })

  test('the prompt is a valid first prompt', () => {
    expect(isClaudeCommand(prompt)).toBe(false)
    expect(prompt.trimStart().startsWith('-')).toBe(false)
  })
})
