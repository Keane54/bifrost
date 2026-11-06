import { describe, expect, it } from 'vitest'
import { REASON_GONE } from '../../../src/renderer/src/actions/reasons'
import {
  formatDuration,
  formatTokens,
  formatWhen,
  type InfoSection,
  infoSections,
  prFailure,
  showInfoPanelId,
  showInfoSessionId,
} from '../../../src/renderer/src/info/show-info'
import type { PrInfo } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

const UTC = 'UTC'
const ID = '0f8fad5b-d9cb-469f-a165-70867728950e'
const NOW = Date.UTC(2026, 10, 5, 12, 0)

function item(sections: InfoSection[], title: string, label: string): string | undefined {
  return sections.find(s => s.title === title)?.items.find(i => i.label === label)?.value
}

const full = row({
  branch: 'fix-a',
  claudeVersion: '2.1.318',
  contextPercent: 42.4,
  contextWindowSize: 200_000,
  costUsd: 1.234,
  cwd: '/Users/o/Developer/app',
  effort: 'high',
  kind: 'external',
  model: 'claude-sonnet-5-5',
  name: 'fix-a',
  permissionMode: 'plan',
  pid: 4242,
  rateLimits: {
    fiveHour: { resetsAt: Date.UTC(2026, 10, 5, 14, 3), usedPercent: 61.6 },
    sevenDay: { resetsAt: Date.UTC(2026, 10, 7, 9, 7), usedPercent: 12 },
  },
  sessionId: ID,
  shortId: 'abcd1234',
  startedAt: Date.UTC(2026, 10, 5, 9, 7),
  state: 'idle',
  terminalApp: 'Warp',
  transcriptPath: '/Users/o/.claude/projects/app/t.jsonl',
})

describe('panel IDs', () => {
  it('showInfoPanelId and showInfoSessionId convert both ways', () => {
    expect(showInfoPanelId(ID)).toBe(`show-info:${ID}`)
    expect(showInfoSessionId(`show-info:${ID}`)).toBe(ID)
    expect(showInfoSessionId('show-info:')).toBeNull()
    expect(showInfoSessionId('chat:abc')).toBeNull()
    expect(showInfoSessionId('settings')).toBeNull()
  })
})

describe('infoSections', () => {
  it('gives the Claude Code name after the name when a local name is set', () => {
    const sections = infoSections({ ...full, claudeName: 'fix-a', name: 'Work' }, NOW, null, UTC)
    expect(sections[0].items.map(i => i.label).slice(0, 3)).toEqual([
      'Name',
      'Claude Code name',
      'Session ID',
    ])
    expect(item(sections, 'Session', 'Name')).toBe('Work')
    expect(item(sections, 'Session', 'Claude Code name')).toBe('fix-a')
  })

  // Ruling of 2026-11-06: Session ID is the ID that claude --resume needs.
  const NEW = '1db82d17-d5fd-4e53-a042-7dd67ea654d8'
  const JOB = '2f493bf0-1598-4b3b-b419-8acb9cb11bcb'

  it('gives the current ID of an interactive row after a /clear as its session ID', () => {
    const sections = infoSections({ ...full, currentId: NEW }, NOW, null, UTC)
    expect(sections[0].items.map(i => i.label)).toEqual([
      'Name',
      'Session ID',
      'Short ID',
      'Kind',
      'PID',
    ])
    expect(item(sections, 'Session', 'Session ID')).toBe(NEW)
  })

  it('gives the resume ID of a background row, then its current conversation', () => {
    const job = { ...full, currentId: NEW, kind: 'owned' as const, resumeId: JOB }
    const sections = infoSections(job, NOW, null, UTC)
    expect(sections[0].items.map(i => i.label).slice(0, 3)).toEqual([
      'Name',
      'Session ID',
      'Current conversation',
    ])
    expect(item(sections, 'Session', 'Session ID')).toBe(JOB)
    expect(item(sections, 'Session', 'Current conversation')).toBe(NEW)
    expect(sections[0].items.find(i => i.label === 'Current conversation')?.mono).toBe(true)
    // A background row with no /clear shows one ID only.
    const plain = infoSections({ ...full, kind: 'owned', resumeId: ID }, NOW, null, UTC)
    expect(plain[0].items.map(i => i.label)).not.toContain('Current conversation')
  })

  it('shows - as the session ID of a background row whose resume ID is not known yet', () => {
    const job = { ...full, currentId: NEW, kind: 'owned' as const }
    const sections = infoSections(job, NOW, null, UTC)
    expect(item(sections, 'Session', 'Session ID')).toBe('-')
    expect(item(sections, 'Session', 'Current conversation')).toBe(NEW)
  })

  it('infoSections gives the values of spec 8.6 in order', () => {
    const sections = infoSections(full, NOW, null, UTC)
    expect(sections.map(s => [s.title, s.items.map(i => i.label)])).toEqual([
      ['Session', ['Name', 'Session ID', 'Short ID', 'Kind', 'PID']],
      ['Files', ['Project folder', 'Transcript']],
      ['Git', ['Branch', 'PR', 'Worktree']],
      ['Model', ['Model', 'Effort', 'Permission mode']],
      ['Time', ['Started', 'Duration']],
      ['Cost and context', ['Cost', 'Context window', 'Context use']],
      ['Limits and version', ['5-hour limit', '7-day limit', 'Claude Code version']],
    ])
    expect(item(sections, 'Session', 'Name')).toBe('fix-a')
    expect(item(sections, 'Session', 'Session ID')).toBe(ID)
    expect(item(sections, 'Session', 'Short ID')).toBe('abcd1234')
    expect(item(sections, 'Session', 'Kind')).toBe('External (Warp)')
    expect(item(sections, 'Session', 'PID')).toBe('4242')
    expect(item(sections, 'Files', 'Project folder')).toBe('/Users/o/Developer/app')
    expect(item(sections, 'Files', 'Transcript')).toBe('/Users/o/.claude/projects/app/t.jsonl')
    expect(item(sections, 'Git', 'Branch')).toBe('fix-a')
    expect(item(sections, 'Model', 'Model')).toBe('claude-sonnet-5-5')
    expect(item(sections, 'Model', 'Effort')).toBe('high')
    expect(item(sections, 'Model', 'Permission mode')).toBe('plan')
    expect(item(sections, 'Time', 'Started')).toBe('09:07')
    expect(item(sections, 'Time', 'Duration')).toBe('2 h 53 min')
    expect(item(sections, 'Cost and context', 'Cost')).toBe('$1.23')
    expect(item(sections, 'Cost and context', 'Context window')).toBe('200k tokens')
    expect(item(sections, 'Cost and context', 'Context use')).toBe('42%')
    expect(item(sections, 'Limits and version', '5-hour limit')).toBe('62%, resets 14:03')
    expect(item(sections, 'Limits and version', '7-day limit')).toBe('12%, resets Sat 7 Nov 09:07')
    expect(item(sections, 'Limits and version', 'Claude Code version')).toBe('2.1.318')
  })

  it('infoSections marks the mono values', () => {
    const sections = infoSections(full, NOW, null, UTC)
    const mono = sections.flatMap(s => s.items.filter(i => i.mono).map(i => i.label))
    expect(mono).toEqual(['Session ID', 'Short ID', 'Project folder', 'Transcript'])
  })

  it('infoSections shows Owned for an owned row', () => {
    const owned = row({ kind: 'owned', sessionId: 'o', state: 'idle' })
    expect(item(infoSections(owned, NOW, null, UTC), 'Session', 'Kind')).toBe('Owned')
    const ext = row({ kind: 'external', sessionId: 'e', state: 'idle' })
    expect(item(infoSections(ext, NOW, null, UTC), 'Session', 'Kind')).toBe('External')
  })

  it('infoSections gives - for missing values and Parked for a parked row', () => {
    const bare = row({ cwd: '', name: 'b', sessionId: 'b', startedAt: 0, state: 'parked' })
    const sections = infoSections(bare, NOW, null, UTC)
    const dashes = [
      ['Session', 'Short ID'],
      ['Session', 'PID'],
      ['Files', 'Project folder'],
      ['Files', 'Transcript'],
      ['Git', 'Branch'],
      ['Model', 'Model'],
      ['Model', 'Effort'],
      ['Model', 'Permission mode'],
      ['Time', 'Started'],
      ['Cost and context', 'Cost'],
      ['Cost and context', 'Context window'],
      ['Cost and context', 'Context use'],
      ['Limits and version', '5-hour limit'],
      ['Limits and version', '7-day limit'],
      ['Limits and version', 'Claude Code version'],
    ] as const
    for (const [title, label] of dashes) expect(item(sections, title, label), label).toBe('-')
    expect(item(sections, 'Time', 'Duration')).toBe('Parked')
  })

  it('infoSections gives - for the duration when startedAt is 0 and the row is not parked', () => {
    const r = row({ sessionId: 'x', startedAt: 0, state: 'idle' })
    expect(item(infoSections(r, NOW, null, UTC), 'Time', 'Duration')).toBe('-')
  })

  it('infoSections shows one window when the plan has one', () => {
    const r = row({
      rateLimits: { sevenDay: { resetsAt: Date.UTC(2026, 10, 5, 13, 0), usedPercent: 5 } },
      sessionId: 'x',
    })
    const sections = infoSections(r, NOW, null, UTC)
    expect(item(sections, 'Limits and version', '5-hour limit')).toBe('-')
    expect(item(sections, 'Limits and version', '7-day limit')).toBe('5%, resets 13:00')
  })

  it('a limit whose reset time passed shows - and the reset time, as the Usage HUD (item 8)', () => {
    const r = row({
      rateLimits: {
        fiveHour: { resetsAt: Date.UTC(2026, 10, 5, 9, 7), usedPercent: 93 },
        sevenDay: { resetsAt: Date.UTC(2026, 10, 3, 2, 0), usedPercent: 40 },
      },
      sessionId: 'x',
    })
    const sections = infoSections(r, NOW, null, UTC)
    expect(item(sections, 'Limits and version', '5-hour limit')).toBe('-, reset at 09:07')
    expect(item(sections, 'Limits and version', '7-day limit')).toBe('-, reset at Tue 3 Nov 02:00')
    const atNow = row({
      rateLimits: { fiveHour: { resetsAt: NOW, usedPercent: 93 } },
      sessionId: 'x',
    })
    expect(item(infoSections(atNow, NOW, null, UTC), 'Limits and version', '5-hour limit')).toBe(
      '-, reset at 12:00',
    )
  })

  it('a limit with a usedPercent that is not a finite number shows -', () => {
    const r = row({
      rateLimits: { fiveHour: { resetsAt: Date.UTC(2026, 10, 5, 14, 3), usedPercent: Number.NaN } },
      sessionId: 'x',
    })
    const sections = infoSections(r, NOW, null, UTC)
    expect(item(sections, 'Limits and version', '5-hour limit')).toBe('-, resets 14:03')
  })

  it('a limit that resets in under 1 minute still shows its use', () => {
    const r = row({
      rateLimits: { fiveHour: { resetsAt: NOW + 30_000, usedPercent: 97 } },
      sessionId: 'x',
    })
    const sections = infoSections(r, NOW, null, UTC)
    expect(item(sections, 'Limits and version', '5-hour limit')).toBe('97%, resets 12:00')
  })

  it('infoSections shows the worktree path of a worktree row', () => {
    const wt = row({
      branch: 'worktree-fix-a',
      cwd: '/r/.claude/worktrees/fix-a/src',
      sessionId: 'w',
    })
    expect(item(infoSections(wt, NOW, null, UTC), 'Git', 'Worktree')).toBe(
      '/r/.claude/worktrees/fix-a',
    )
    const stopped = row({
      cwd: '/r',
      sessionId: 's',
      state: 'parked',
      worktree: '/r/.claude/worktrees/fix-a',
    })
    expect(item(infoSections(stopped, NOW, null, UTC), 'Git', 'Worktree')).toBe(
      '/r/.claude/worktrees/fix-a',
    )
    const plain = row({ cwd: '/r', sessionId: 'p' })
    expect(item(infoSections(plain, NOW, null, UTC), 'Git', 'Worktree')).toBe('None')
  })

  it('infoSections shows the PR states', () => {
    const pr = (value: PrInfo | null) => item(infoSections(full, NOW, value, UTC), 'Git', 'PR')
    expect(
      pr({
        kind: 'pr',
        number: 12,
        state: 'OPEN',
        title: 'Fix',
        url: 'https://github.com/o/r/pull/12',
      }),
    ).toBe('#12 Fix (open)')
    expect(pr({ kind: 'none' })).toBe('None')
    expect(pr({ kind: 'unavailable', reason: "GitHub CLI (gh) isn't installed." })).toBe(
      "GitHub CLI (gh) isn't installed.",
    )
    expect(pr(null)).toBe('Loading...')
  })
})

describe('formats', () => {
  it('formatDuration, formatTokens and formatWhen give the texts', () => {
    expect(formatDuration(59_000)).toBe('less than 1 min')
    expect(formatDuration(3_720_000)).toBe('1 h 02 min')
    expect(formatTokens(1_000_000)).toBe('1M')
    expect(formatTokens(200_000)).toBe('200k')
    expect(formatTokens(1_500_000)).toBe('1.5M')
    expect(formatTokens(1_000)).toBe('1k')
    expect(formatTokens(999)).toBe('999')
    expect(formatWhen(Date.UTC(2026, 10, 5, 9, 7), NOW, UTC)).toBe('09:07')
    expect(formatWhen(Date.UTC(2026, 10, 4, 14, 3), NOW, UTC)).toBe('Wed 4 Nov 14:03')
  })

  it('formatWhen compares the day in the time zone', () => {
    // 23:30 UTC on 4 Nov is already 5 Nov in Tokyo.
    const ms = Date.UTC(2026, 10, 4, 23, 30)
    expect(formatWhen(ms, NOW, 'Asia/Tokyo')).toBe('08:30')
    expect(formatWhen(ms, NOW, UTC)).toBe('Wed 4 Nov 23:30')
  })
})

describe('prFailure (final wave item 10)', () => {
  it('a refusal of the main process gives the friendly text, not the code', () => {
    expect(prFailure('refused: unknown session')).toEqual({
      kind: 'unavailable',
      reason: REASON_GONE,
    })
    expect(prFailure('refused: bad session ID').reason).not.toContain('refused:')
  })

  it('another message stays as it is', () => {
    expect(prFailure('gh broke')).toEqual({ kind: 'unavailable', reason: 'gh broke' })
  })
})
