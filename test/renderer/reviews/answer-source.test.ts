import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const dir = join(__dirname, '../../../src/renderer/src/reviews')
const PANEL = readFileSync(join(dir, 'AnswerPanel.tsx'), 'utf8')
const KEY = readFileSync(join(dir, 'answer-key.ts'), 'utf8')

describe('AnswerPanel source', () => {
  it('sends the answers with reviews.answer, and null for a checked question', () => {
    expect(PANEL).toContain('reviews.answer(row.key, list)')
    expect(PANEL).toMatch(/text: [a-z.]*checked[a-z.]* \? null/i)
  })

  it('limits the text box to MAX_ANSWER', () => {
    expect(PANEL).toContain('maxLength={MAX_ANSWER}')
  })

  it('has the four texts', () => {
    expect(PANEL).toContain('Nothing to answer right now.')
    expect(PANEL).toContain(
      "Claude couldn't decide these on its own. Tell it what you'd like, or handle a comment yourself.",
    )
    expect(PANEL).toContain("placeholder='Type your answer'")
    expect(PANEL).toContain("I'll handle this one myself")
    expect(PANEL).toContain('Send to Claude')
  })

  it('shows the last error of the row and a refusal in friendly text', () => {
    expect(PANEL).toContain('row.lastError')
    expect(PANEL).toContain('friendlyError(')
  })

  it('closes the panel after a send and on Cancel', () => {
    expect(PANEL).toMatch(/panelId: 'answer', type: 'close'/)
    expect(PANEL).toContain('Cancel')
  })

  it('builds each className with cx() and keeps the key in a store', () => {
    expect(PANEL).not.toMatch(/className=\{`/)
    expect(KEY).toContain('export function setAnswerKey')
    expect(KEY).toContain('export function useAnswerKey')
  })

  it('disables Send above MAX_ANSWERS and says why', () => {
    expect(PANEL).toContain('MAX_ANSWERS')
    expect(PANEL).toMatch(/const tooMany = row\.questions\.length > MAX_ANSWERS/)
    expect(PANEL).toMatch(/!tooMany &&/)
    expect(PANEL).toContain('Bifrost can send only a limited number of answers at a time')
  })

  it('trims the text of an answer in Send', () => {
    expect(PANEL).toContain("(answers[q.id] ?? '').trim()")
    expect(PANEL).toMatch(/text: checked \? null : \(answers\[q\.id\] \?\? ''\)\.trim\(\)/)
  })

  it('resets the answers and the checks when the key changes', () => {
    expect(PANEL).toMatch(/setAnswers\(\{\}\)[\s\S]{0,60}setChecks\(\{\}\)[\s\S]{0,80}\[key\]/)
  })

  it('shows the quote of the reviewer above the question, as plain text', () => {
    expect(PANEL).toContain('q.body')
    expect(PANEL).toContain('{q.body}')
    expect(PANEL).toContain('whitespace-pre-wrap')
    expect(PANEL).toContain('break-words')
    expect(PANEL).toContain('View on GitHub')
    expect(PANEL).toContain('the PR')
    expect(PANEL).not.toContain('dangerouslySetInnerHTML')
    expect(PANEL).not.toMatch(/<a\b/)
    expect(PANEL).not.toMatch(/href=/)
  })

  it('shows the quote only when the question has a body, and the link only with a URL', () => {
    expect(PANEL).toMatch(/q\.body !== undefined/)
    expect(PANEL).toMatch(/q\.url !== undefined/)
  })

  it('picks the header from the saved kind and shows a quote only for a non-empty body', () => {
    expect(PANEL).not.toContain('startsWith')
    expect(PANEL).toMatch(/q\.kind === 'comment'/)
    expect(PANEL).toMatch(/q\.body\.trim\(\) !== ''/)
  })

  it('opens the comment with the PR key and the item ID, never a URL', () => {
    expect(PANEL).toContain('reviews.openComment(row.key, itemId)')
  })
})
