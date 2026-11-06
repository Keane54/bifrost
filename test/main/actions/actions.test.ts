import { describe, expect, it } from 'vitest'
import { createActions } from '../../../src/main/actions/actions'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { SessionRow } from '../../../src/shared/types'

const row = (over: Partial<SessionRow>): SessionRow =>
  ({ cwd: '/Users/u/p q', sessionId: 'abc-123-full-uuid', ...over }) as SessionRow

function setup(rows: SessionRow[], result: ExecResult = { code: 0, stderr: '', stdout: '' }) {
  const calls: { file: string; args: string[] }[] = []
  const clip: string[] = []
  const actions = createActions({
    apps: async () => [
      { id: 'finder', label: 'Finder', path: '/System/Library/CoreServices/Finder.app' },
      { id: 'zed', label: 'Zed', path: '/Applications/Zed.app' },
    ],
    exec: async (file, args) => {
      calls.push({ args, file })
      return result
    },
    rows: () => rows,
    writeClipboard: t => {
      clip.push(t)
    },
  })
  return { actions, calls, clip }
}

describe('actions', () => {
  it('openProject runs /usr/bin/open -a <app path> <cwd>', async () => {
    const { actions, calls } = setup([row({})])
    await actions.openProject('abc-123-full-uuid', 'zed')
    expect(calls).toEqual([
      { args: ['-a', '/Applications/Zed.app', '/Users/u/p q'], file: '/usr/bin/open' },
    ])
  })

  it('openProject refuses an unknown session, an empty or relative cwd, and an unknown app', async () => {
    const { actions, calls } = setup([
      row({}),
      row({ cwd: '', sessionId: 'empty' }),
      row({ cwd: 'rel/p', sessionId: 'rel' }),
    ])
    await expect(actions.openProject('nope', 'zed')).rejects.toThrow('refused: unknown session')
    await expect(actions.openProject('empty', 'zed')).rejects.toThrow(
      'refused: the project directory is not known',
    )
    await expect(actions.openProject('rel', 'zed')).rejects.toThrow(
      'refused: the project directory is not known',
    )
    await expect(actions.openProject('abc-123-full-uuid', 'warp')).rejects.toThrow(
      'refused: unknown app',
    )
    await expect(actions.openProject('abc-123-full-uuid', 42)).rejects.toThrow(
      'refused: unknown app',
    )
    expect(calls).toEqual([])
  })

  it('openProject rejects with the stderr of a failed open', async () => {
    const failed = setup([row({})], { code: 1, stderr: ' no such app\n', stdout: '' })
    await expect(failed.actions.openProject('abc-123-full-uuid', 'zed')).rejects.toThrow(
      'no such app',
    )
    const silent = setup([row({})], { code: 1, stderr: '', stdout: '' })
    await expect(silent.actions.openProject('abc-123-full-uuid', 'zed')).rejects.toThrow(
      'open failed',
    )
  })

  it('copySessionId writes the full session ID and refuses an unknown session', async () => {
    const { actions, clip } = setup([row({})])
    await actions.copySessionId('abc-123-full-uuid')
    expect(clip).toEqual(['abc-123-full-uuid'])
    await expect(actions.copySessionId('nope')).rejects.toThrow('refused: unknown session')
    expect(clip).toHaveLength(1)
  })

  // Ruling of 2026-11-06: the copy is the ID that claude --resume needs.
  it('copySessionId writes the resume ID of a background row', async () => {
    const { actions, clip } = setup([
      row({ currentId: 'new-full-uuid', kind: 'owned', resumeId: 'job-full-uuid' }),
    ])
    await actions.copySessionId('abc-123-full-uuid')
    expect(clip).toEqual(['job-full-uuid'])
  })

  it('copySessionId writes the current ID of an interactive row', async () => {
    const { actions, clip } = setup([row({ currentId: 'new-full-uuid', kind: 'external' })])
    await actions.copySessionId('abc-123-full-uuid')
    expect(clip).toEqual(['new-full-uuid'])
  })

  it('copySessionId refuses a background row whose resume ID is not known yet', async () => {
    const { actions, clip } = setup([row({ currentId: 'new-full-uuid', kind: 'owned' })])
    await expect(actions.copySessionId('abc-123-full-uuid')).rejects.toThrow(
      'refused: the ID that resumes this session is not known yet',
    )
    expect(clip).toEqual([])
  })

  it('listApps gives the IDs and labels only', async () => {
    const { actions } = setup([])
    const apps = await actions.listApps()
    expect(apps).toEqual([
      { id: 'finder', label: 'Finder' },
      { id: 'zed', label: 'Zed' },
    ])
    for (const a of apps) expect(a).not.toHaveProperty('path')
  })
})
