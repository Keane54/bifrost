import { describe, expect, it } from 'vitest'
import { confirmFor } from '../../../src/renderer/src/actions/confirm'
import type { WorktreeCheck } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

describe('confirm texts', () => {
  const aliased = row({
    claudeName: 'claude-a1',
    name: 'my-alias',
    sessionId: 'a',
    terminalApp: 'Warp',
  })
  const NAMED = 'my-alias (Claude Code name: claude-a1)'

  it('Stop, Delete and Take control name both names when a local name exists', () => {
    expect(confirmFor('stop', aliased, 'plain')?.body).toBe(
      `${NAMED} is working right now. Stop it anyway? The current turn will end.`,
    )
    const del = confirmFor('delete', aliased, 'plain')
    expect(del?.body).toBe(
      `Delete ${NAMED}? This removes the session from Claude Code and Bifrost.`,
    )
    expect(del?.title).toBe(`Delete ${NAMED}`)
    expect(confirmFor('take-control', aliased, 'plain')?.body).toBe(
      `This closes the session ${NAMED} in Warp and moves it into Bifrost.`,
    )
  })
  it('Stop asks only for a working session', () => {
    expect(confirmFor('stop', row({ sessionId: 'a', state: 'idle' }), 'plain')).toBeNull()
    expect(confirmFor('stop', row({ name: 'fix-a', sessionId: 'a' }), 'plain')).toEqual({
      body: 'fix-a is working right now. Stop it anyway? The current turn will end.',
      confirm: 'Stop session',
      title: 'Stop session',
    })
  })

  it('Delete always asks', () => {
    for (const state of ['idle', 'working', 'parked'] as const) {
      expect(confirmFor('delete', row({ sessionId: 'a', state }), 'plain')).not.toBeNull()
    }
  })

  it('Delete gives the plain text', () => {
    expect(confirmFor('delete', row({ name: 'fix-a', sessionId: 'a' }), 'plain')?.body).toBe(
      'Delete fix-a? This removes the session from Claude Code and Bifrost.',
    )
  })

  const WT = '/r/.claude/worktrees/fix-a'
  const check = (over: Partial<WorktreeCheck>): WorktreeCheck => ({
    branch: 'worktree-fix-a',
    changedFiles: 0,
    unmergedCommits: 0,
    worktree: WT,
    ...over,
  })
  const del = (c: WorktreeCheck | null | undefined) =>
    confirmFor('delete', row({ cwd: WT, name: 'fix-a', sessionId: 'a' }), 'plain', c)
  // The sentence for changed files (Task 17 bug 2). claude rm keeps such a worktree.
  const KEEPS =
    'Claude Code keeps a worktree with changes that are not committed, so commit or discard them first.'

  it('Delete without unmerged work gives the plain text', () => {
    const text = del(check({}))
    expect(text?.body).toBe('Delete fix-a? This removes the session from Claude Code and Bifrost.')
    expect(text?.confirmAgain).toBeUndefined()
    expect(text?.openFolder).toBeUndefined()
    expect(del(check({ changedFiles: 4, worktree: null }))?.confirmAgain).toBeUndefined()
  })

  it('Delete with unmerged work gives the counts and asks again', () => {
    expect(del(check({ changedFiles: 3, unmergedCommits: 2 }))).toEqual({
      body: `This session has 2 commits that are not merged and 3 changed files on worktree-fix-a. ${KEEPS} Are you sure you want to delete this?`,
      confirm: 'Delete session',
      confirmAgain: 'Delete anyway',
      openFolder: WT,
      title: 'Delete fix-a',
    })
  })

  it('the Delete title names the session for each check result', () => {
    for (const c of [undefined, null, check({}), check({ unmergedCommits: 1 })]) {
      expect(del(c)?.title).toBe('Delete fix-a')
      expect(del(c)?.confirm).toBe('Delete session')
    }
    const r = row({ cwd: WT, name: 'bifrost-a1b2', sessionId: 'a' })
    expect(confirmFor('delete', r, 'plain')?.title).toBe('Delete bifrost-a1b2')
    expect(confirmFor('delete', r, 'space')?.title).toBe('Self-destruct bifrost-a1b2')
    expect(confirmFor('delete', r, 'space', null)?.title).toBe('Self-destruct bifrost-a1b2')
  })

  it('Delete uses the singular and leaves out a zero part', () => {
    expect(del(check({ unmergedCommits: 1 }))?.body).toBe(
      'This session has 1 commit that is not merged on worktree-fix-a. Are you sure you want to delete this?',
    )
    expect(del(check({ changedFiles: 1, unmergedCommits: 1 }))?.body).toBe(
      `This session has 1 commit that is not merged and 1 changed file on worktree-fix-a. ${KEEPS} Are you sure you want to delete this?`,
    )
    expect(del(check({ changedFiles: 1 }))?.body).toBe(
      `This session has 1 changed file on worktree-fix-a. ${KEEPS} Are you sure you want to delete this?`,
    )
    expect(del(check({ branch: null, unmergedCommits: 1 }))?.body).toBe(
      'This session has 1 commit that is not merged in its worktree. Are you sure you want to delete this?',
    )
  })

  it('Delete names the kept worktree only when the check shows changed files', () => {
    expect(del(check({ changedFiles: 75, unmergedCommits: 1 }))?.body).toBe(
      `This session has 1 commit that is not merged and 75 changed files on worktree-fix-a. ${KEEPS} Are you sure you want to delete this?`,
    )
    for (const c of [check({ unmergedCommits: 3 }), check({}), null, undefined]) {
      expect(del(c)?.body).not.toContain(KEEPS)
    }
  })

  it('Delete after a failed check says so and asks again', () => {
    const text = del(null)
    expect(text?.body).toBe(
      'Bifrost could not check this session for unmerged work. Are you sure you want to delete this?',
    )
    expect(text?.confirmAgain).toBe('Delete anyway')
    expect(text?.openFolder).toBe(WT)
    const plainRow = row({ cwd: '/p', sessionId: 'a' })
    expect(confirmFor('delete', plainRow, 'plain', null)?.openFolder).toBeUndefined()
  })

  it('a failed check uses the stored worktree of a stopped session', () => {
    // A stopped session reports its start folder and the branch of that folder.
    const stopped = row({
      branch: 'main',
      cwd: '/r',
      sessionId: 'a',
      state: 'parked',
      worktree: WT,
    })
    expect(confirmFor('delete', stopped, 'plain', null)?.openFolder).toBe(WT)
  })

  it('the Delete text does not say that the conversation goes (final review M6)', () => {
    // claude rm keeps the transcript file. So the text names only Claude Code and Bifrost.
    for (const c of [undefined, check({})]) {
      expect(del(c)?.body).not.toContain('conversation')
    }
  })

  it('Take control names the terminal app', () => {
    const base = { kind: 'external', sessionId: 'a' } as const
    expect(confirmFor('take-control', row({ ...base, terminalApp: 'Warp' }), 'plain')?.body).toBe(
      'This closes the session in Warp and moves it into Bifrost.',
    )
    expect(confirmFor('take-control', row(base), 'plain')?.body).toBe(
      'This closes the session in its terminal and moves it into Bifrost.',
    )
  })

  it('the dialog bodies use the verbs of the label set (spec 9.1)', () => {
    const r = row({ cwd: WT, name: 'fix-a', sessionId: 'a' })
    expect(confirmFor('stop', r, 'space')?.body).toBe(
      'fix-a is working right now. Power it down anyway? The current turn will end.',
    )
    expect(confirmFor('delete', r, 'space')?.body).toBe(
      'Self-destruct fix-a? This removes the session from Claude Code and Bifrost.',
    )
    expect(confirmFor('delete', r, 'space', check({}))?.body).toBe(
      'Self-destruct fix-a? This removes the session from Claude Code and Bifrost.',
    )
    const unmerged = confirmFor('delete', r, 'space', check({ unmergedCommits: 1 }))
    expect(unmerged?.body).toBe(
      'This session has 1 commit that is not merged on worktree-fix-a. Are you sure you want to self-destruct this?',
    )
    expect(unmerged?.confirmAgain).toBe('Self-destruct anyway')
    const failed = confirmFor('delete', r, 'space', null)
    expect(failed?.body).toBe(
      'Bifrost could not check this session for unmerged work. Are you sure you want to self-destruct this?',
    )
    expect(failed?.confirmAgain).toBe('Self-destruct anyway')
  })

  it('Delete in a shared folder says that Bifrost keeps it (spec 8 of the skills design)', () => {
    const keeps = 'Another session still uses this folder, so Bifrost keeps it.'
    const later =
      'It goes from the list now, and Bifrost removes it from Claude Code when you delete ' +
      'the last session in this folder.'
    const shared = (labels: 'plain' | 'space', c?: WorktreeCheck | null) =>
      confirmFor('delete', aliased, labels, c, true)
    expect(shared('plain')).toEqual({
      body: `${keeps} Delete ${NAMED}? ${later}`,
      confirm: 'Delete session',
      title: `Delete ${NAMED}`,
    })
    expect(shared('space')).toEqual({
      body: `${keeps} Self-destruct ${NAMED}? ${later}`,
      confirm: 'Self-destruct',
      title: `Self-destruct ${NAMED}`,
    })
    // No check result gives a second click or Open folder.
    for (const c of [null, check({ changedFiles: 2, unmergedCommits: 1 })]) {
      expect(shared('plain', c)?.confirmAgain).toBeUndefined()
      expect(shared('plain', c)?.openFolder).toBeUndefined()
    }
    // shared false gives the text of today.
    expect(confirmFor('delete', aliased, 'plain', undefined, false)).toEqual(
      confirmFor('delete', aliased, 'plain'),
    )
  })

  it('the confirm labels use the label set', () => {
    const r = row({ sessionId: 'a' })
    expect(confirmFor('stop', r, 'space')?.confirm).toBe('Power down')
    expect(confirmFor('stop', r, 'space')?.title).toBe('Power down')
    expect(confirmFor('delete', r, 'space')?.confirm).toBe('Self-destruct')
    expect(confirmFor('delete', r, 'space')?.title).toBe('Self-destruct a')
  })
})
