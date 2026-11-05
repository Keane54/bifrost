import { describe, expect, it } from 'vitest'
import {
  AGENT_CHECK_MAX_MS,
  AGENT_CHECK_QUIET_MS,
  type AgentGuard,
  afterRestart,
  agentCheckDelay,
  agentStep,
  isAgentView,
  joinWrapped,
  MAX_REATTACH,
  REATTACH_WINDOW_MS,
  reattachDecision,
  recentAttaches,
  stepBlocks,
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

  // A paste of two lines: the counts line on the prompt line, the footer on the next line.
  it('is false for a two-line paste in a prompt box', () => {
    const box = ['hello', '╭───────╮', `│ > ${COUNTS} │`, `│   ${FOOTER} │`, '╰───────╯']
    expect(isAgentView([...box, '  ? for shortcuts'])).toBe(false)
    expect(isAgentView(box)).toBe(false)
  })

  it('is false for a two-line paste in a prompt with rules', () => {
    const rules = ['hello', '─────────', `> ${COUNTS}`, `  ${FOOTER}`, '─────────']
    expect(isAgentView([...rules, '  ? for shortcuts'])).toBe(false)
    expect(isAgentView(rules)).toBe(false)
  })

  it('is false when an empty line of the prompt box comes after the footer', () => {
    const lines = [COUNTS, '╭───────╮', `│ ${FOOTER} │`, '│       │', '╰───────╯']
    expect(isAgentView(lines)).toBe(false)
  })

  it('is false for a paste with the footer first and the counts line next', () => {
    const lines = ['╭───────╮', `│ > ${FOOTER} │`, `│   ${COUNTS} │`, '╰───────╯']
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

// The rows of a terminal with the given width for one line of text. The last row has spaces.
function wrap(text: string, width: number): { text: string; wrapped: boolean }[] {
  const rows: { text: string; wrapped: boolean }[] = []
  for (let at = 0; at < text.length; at += width) {
    rows.push({ text: text.slice(at, at + width).padEnd(width), wrapped: at > 0 })
  }
  return rows
}

describe('joinWrapped', () => {
  it('joins the wrapped rows of a narrow terminal and keeps the space at a wrap', () => {
    // At 18 columns, the first footer row is "enter to return · ". It ends with a space.
    const rows = [
      ...wrap(COUNTS, 18),
      ...wrap(FOOTER, 18),
      { text: ' '.repeat(18), wrapped: false },
    ]
    expect(rows[3]?.text).toBe('enter to return · ')
    const lines = joinWrapped(rows)
    expect(lines).toEqual([COUNTS, FOOTER, ''])
    expect(isAgentView(lines)).toBe(true)
  })

  it('keeps a wrapped first row as a line', () => {
    expect(joinWrapped([{ text: 'tail  ', wrapped: true }])).toEqual(['tail'])
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

describe('recentAttaches', () => {
  it('drops the attaches that are 60 seconds old or older', () => {
    expect(recentAttaches([39_999, 40_000, 40_001, 99_000], 100_000)).toEqual([40_001, 99_000])
    expect(recentAttaches([], 100_000)).toEqual([])
  })
})

// The times of the checks for chunks at these times. A chunk restarts the timer of the check.
function checkTimes(chunks: number[]): number[] {
  const checks: number[] = []
  let first: number | null = null
  let due: number | null = null
  for (const at of chunks) {
    if (due !== null && due <= at) {
      checks.push(due)
      first = null
    }
    if (first === null) first = at
    due = at + agentCheckDelay(first, at)
  }
  if (due !== null) checks.push(due)
  return checks
}

describe('agentCheckDelay', () => {
  it('waits for 250 ms of quiet, but never more than 1000 ms after the first chunk', () => {
    expect(AGENT_CHECK_QUIET_MS).toBe(250)
    expect(AGENT_CHECK_MAX_MS).toBe(1000)
    expect(agentCheckDelay(0, 0)).toBe(250)
    expect(agentCheckDelay(0, 900)).toBe(100)
    expect(agentCheckDelay(0, 1000)).toBe(0)
    expect(agentCheckDelay(0, 1500)).toBe(0)
  })

  it('checks 250 ms after the last chunk of a short burst', () => {
    expect(checkTimes([0, 100, 200])).toEqual([450])
  })

  it('checks each 1000 ms during continuous output', () => {
    const chunks = Array.from({ length: 30 }, (_, i) => i * 100)
    expect(checkTimes(chunks)).toEqual([1000, 2000, 3000])
  })
})

describe('the agent view guard', () => {
  const fresh: AgentGuard = { gaveUp: false, waiting: false }
  const screen = (over: Partial<Parameters<typeof agentStep>[1]> = {}) => ({
    agentView: true,
    history: [] as number[],
    now: 100_000,
    targetOk: true,
    ...over,
  })
  const full = (now: number) => Array.from({ length: MAX_REATTACH }, (_, i) => now - 1000 * (i + 1))

  it('an agent view blocks the input and attaches again', () => {
    expect(agentStep(fresh, screen())).toBe('reattach')
    expect(stepBlocks('reattach')).toBe(true)
  })

  it('an agent view with a row that cannot attach blocks the input and waits', () => {
    expect(agentStep(fresh, screen({ targetOk: false }))).toBe('wait')
    expect(stepBlocks('wait')).toBe(true)
  })

  it('gives up after the attach limit and keeps the input blocked', () => {
    expect(agentStep(fresh, screen({ history: full(100_000) }))).toBe('give-up')
    expect(stepBlocks('give-up')).toBe(true)
  })

  it('frees the input when the agent view closes during the wait', () => {
    expect(agentStep({ gaveUp: false, waiting: true }, screen({ agentView: false }))).toBe('free')
    expect(stepBlocks('free')).toBe(false)
    expect(agentStep(fresh, screen({ agentView: false }))).toBe('none')
    expect(stepBlocks('none')).toBe(false)
  })

  it('a window that gave up checks nothing', () => {
    expect(agentStep({ gaveUp: true, waiting: false }, screen())).toBe('none')
  })

  it('a restart after a give-up blocks the input again when the agent view shows', () => {
    const after = afterRestart({ gaveUp: true, waiting: false })
    expect(after).toEqual(fresh)
    expect(stepBlocks(agentStep(after, screen()))).toBe(true)
    // The shared attach history still limits the reattaches after the restart.
    expect(agentStep(after, screen({ history: full(100_000) }))).toBe('give-up')
  })
})
