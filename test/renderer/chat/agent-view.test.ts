import { describe, expect, it } from 'vitest'
import {
  isAgentView,
  MAX_REATTACH,
  REATTACH_WINDOW_MS,
  reattachDecision,
} from '../../../src/renderer/src/chat/agent-view'

const COUNTS = '0 awaiting input · 0 working · 6 completed'
const FOOTER =
  'enter to return · space to reply · hold space to speak · ctrl+x to delete · ? for shortcuts'
const PROMPT = ['╭───────╮', '│ >     │', '╰───────╯', '  ? for shortcuts']

describe('isAgentView', () => {
  it('is true for the M0 agent view screen', () => {
    const lines = [COUNTS, '', '  session one', '  session two', FOOTER, '', '', '']
    expect(isAgentView(lines)).toBe(true)
  })

  it('is false for a normal prompt screen', () => {
    expect(isAgentView(['hello', ...PROMPT])).toBe(false)
  })

  it('is false when the footer text is above the last 3 non-empty lines', () => {
    const lines = ['> show the screen', COUNTS, FOOTER, 'I quoted it.', ...PROMPT]
    expect(isAgentView(lines)).toBe(false)
  })

  it('is false when the footer is pasted into the prompt line', () => {
    const lines = [COUNTS, '', '╭───────╮', `│ > ${FOOTER} │`, '╰───────╯', '  ? for shortcuts']
    expect(isAgentView(lines)).toBe(false)
  })

  it('is true when box characters frame the footer line', () => {
    expect(isAgentView([COUNTS, `│ ${FOOTER} │`])).toBe(true)
  })

  it('looks at the last 3 non-empty lines only', () => {
    expect(isAgentView([COUNTS, FOOTER, 'a', '', 'b', ''])).toBe(true)
    expect(isAgentView([COUNTS, FOOTER, 'a', 'b', 'c'])).toBe(false)
  })

  it('needs both the footer and the counts line', () => {
    expect(isAgentView(['session', FOOTER])).toBe(false)
    expect(isAgentView([COUNTS, 'session', '? for shortcuts'])).toBe(false)
  })
})

describe('reattachDecision', () => {
  it('allows 3 reattaches in 60 seconds, then gives up', () => {
    expect(MAX_REATTACH).toBe(3)
    expect(reattachDecision([], 100_000)).toBe('reattach')
    expect(reattachDecision([99_000, 99_500], 100_000)).toBe('reattach')
    expect(reattachDecision([98_000, 99_000, 99_500], 100_000)).toBe('give-up')
  })

  it('forgets reattaches older than 60 seconds', () => {
    expect(REATTACH_WINDOW_MS).toBe(60_000)
    expect(reattachDecision([30_000, 99_000, 99_500], 100_000)).toBe('reattach')
    expect(reattachDecision([40_000, 99_000, 99_500], 100_000)).toBe('reattach')
    expect(reattachDecision([39_000, 99_000, 99_500], 100_000)).toBe('reattach')
    expect(reattachDecision([40_001, 99_000, 99_500], 100_000)).toBe('give-up')
  })
})
