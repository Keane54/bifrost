import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { InstalledApp } from '../../../src/main/actions/project-apps'
import {
  attachCommand,
  attachScript,
  createTerminalLauncher,
  LAUNCH,
  SCRIPT_KEEP_MS,
  type TerminalId,
} from '../../../src/main/actions/terminal-launch'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { SessionRow } from '../../../src/shared/types'

const WARP: InstalledApp = { id: 'warp', label: 'Warp', path: '/Applications/Warp.app' }
const OK: ExecResult = { code: 0, stderr: '', stdout: '' }

const row = (over: Partial<SessionRow>): SessionRow =>
  ({
    cwd: '/p',
    kind: 'owned',
    sessionId: 's1',
    shortId: 'abcd1234',
    state: 'idle',
    ...over,
  }) as SessionRow

function setup(
  rows: SessionRow[],
  opts: {
    apps?: InstalledApp[]
    claude?: string | null
    result?: ExecResult
    launch?: Record<TerminalId, 'command-file' | 'clipboard'>
    terminal?: { name: string; bundle: string }
  } = {},
) {
  const calls: { file: string; args: string[]; opts?: unknown }[] = []
  const written: { file: string; text: string }[] = []
  const removed: string[] = []
  const clip: string[] = []
  const iconCalls: string[] = []
  const launcher = createTerminalLauncher(
    {
      apps: async () => opts.apps ?? [WARP],
      claudePath: async () => (opts.claude === undefined ? '/bin/claude' : opts.claude),
      exec: async (file, args, o) => {
        calls.push({ args, file, opts: o })
        return opts.result ?? OK
      },
      fileIcon: async path => {
        iconCalls.push(path)
        return path === '/Applications/None.app' ? null : `icon:${path}`
      },
      remove: async file => {
        removed.push(file)
      },
      rows: () => rows,
      runDir: '/run',
      terminalOf: () => opts.terminal,
      writeClipboard: t => {
        clip.push(t)
      },
      writeScript: async (file, text) => {
        written.push({ file, text })
      },
    },
    opts.launch,
  )
  return { calls, clip, iconCalls, launcher, removed, written }
}

describe('terminal-launch', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('uses the Task 1 ruling for LAUNCH', () => {
    expect(LAUNCH).toEqual({
      ghostty: 'clipboard',
      iterm2: 'clipboard',
      terminal: 'command-file',
      warp: 'command-file',
    })
    expect(attachCommand('abcd1234')).toBe('claude attach abcd1234')
  })

  it('attachScript runs the claude path with the short ID', () => {
    expect(attachScript("/a b/it's/claude", 'abcd1234')).toBe(
      "#!/bin/sh\nexec '/a b/it'\\''s/claude' attach abcd1234\n",
    )
  })

  it('openInTerminal opens a command file in the terminal app', async () => {
    const { calls, launcher, removed, written } = setup([row({})], {
      launch: {
        ghostty: 'clipboard',
        iterm2: 'clipboard',
        terminal: 'clipboard',
        warp: 'command-file',
      },
    })
    await expect(launcher.openInTerminal('s1')).resolves.toEqual({ notice: null })
    expect(written).toEqual([
      { file: '/run/attach-abcd1234.command', text: attachScript('/bin/claude', 'abcd1234') },
    ])
    expect(calls).toEqual([
      {
        args: ['-a', '/Applications/Warp.app', '/run/attach-abcd1234.command'],
        file: '/usr/bin/open',
        opts: { timeoutMs: 10000 },
      },
    ])
    expect(SCRIPT_KEEP_MS).toBe(30_000)
    await vi.advanceTimersByTimeAsync(29_999)
    expect(removed).toEqual([])
    await vi.advanceTimersByTimeAsync(1)
    expect(removed).toEqual(['/run/attach-abcd1234.command'])
  })

  it('openInTerminal rejects when open fails, and when claude is missing', async () => {
    const failed = setup([row({})], { result: { code: 1, stderr: 'no app', stdout: '' } })
    await expect(failed.launcher.openInTerminal('s1')).rejects.toThrow('no app')
    const none = setup([row({})], { claude: null })
    await expect(none.launcher.openInTerminal('s1')).rejects.toThrow('claude not found')
    expect(none.calls).toEqual([])
  })

  it('openInTerminal copies the attach command for an app without a launch method', async () => {
    const { calls, clip, launcher, written } = setup([row({})], {
      launch: { ...LAUNCH, warp: 'clipboard' },
    })
    const result = await launcher.openInTerminal('s1')
    expect(clip).toEqual(['claude attach abcd1234'])
    expect(calls).toEqual([
      { args: ['-a', '/Applications/Warp.app'], file: '/usr/bin/open', opts: undefined },
    ])
    expect(written).toEqual([])
    expect(result).toEqual({
      notice: 'Copied "claude attach abcd1234". Paste it into Warp to open the session.',
    })
  })

  it('openInTerminal brings the terminal app of an external session to the front', async () => {
    const { calls, launcher } = setup([row({ kind: 'external' })], {
      terminal: { bundle: '/Applications/iTerm.app', name: 'iTerm' },
    })
    await expect(launcher.openInTerminal('s1')).resolves.toEqual({ notice: null })
    expect(calls.map(c => [c.file, c.args])).toEqual([
      ['/usr/bin/open', ['-a', '/Applications/iTerm.app']],
    ])
  })

  it('openInTerminal refuses a parked session, an unknown session, a bad short ID, no terminal app, and an external session without a terminal app', async () => {
    const cases: [string, ReturnType<typeof setup>, unknown][] = [
      ['refused: the session is parked', setup([row({ state: 'parked' })]), 's1'],
      ['refused: unknown session', setup([row({})]), 'nope'],
      ['refused: unknown session', setup([row({})]), 42],
      ['refused: bad session ID', setup([row({ shortId: 'x; rm' })]), 's1'],
      ['refused: bad session ID', setup([row({ shortId: undefined })]), 's1'],
      ['refused: no terminal app is installed', setup([row({})], { apps: [] }), 's1'],
      [
        'refused: the terminal app of the session is not known',
        setup([row({ kind: 'external' })]),
        's1',
      ],
    ]
    for (const [message, s, id] of cases) {
      await expect(s.launcher.openInTerminal(id)).rejects.toThrow(message)
      expect(s.calls).toEqual([])
      expect(s.written).toEqual([])
      expect(s.clip).toEqual([])
    }
  })

  it('terminalIcon gives the icon and asks one time for each bundle', async () => {
    const ext = setup([row({ kind: 'external' })], {
      terminal: { bundle: '/Applications/iTerm.app', name: 'iTerm' },
    })
    expect(await ext.launcher.terminalIcon('s1')).toBe('icon:/Applications/iTerm.app')
    expect(await ext.launcher.terminalIcon('s1')).toBe('icon:/Applications/iTerm.app')
    expect(ext.iconCalls).toEqual(['/Applications/iTerm.app'])

    const none = setup([row({ kind: 'external' })], {
      terminal: { bundle: '/Applications/None.app', name: 'None' },
    })
    expect(await none.launcher.terminalIcon('s1')).toBeNull()
    expect(await none.launcher.terminalIcon('s1')).toBeNull()
    expect(none.iconCalls).toEqual(['/Applications/None.app'])

    const owned = setup([row({})], {
      terminal: { bundle: '/Applications/iTerm.app', name: 'iTerm' },
    })
    expect(await owned.launcher.terminalIcon('s1')).toBeNull()
    expect(await owned.launcher.terminalIcon('zzz')).toBeNull()
    expect(await owned.launcher.terminalIcon(7)).toBeNull()
    expect(owned.iconCalls).toEqual([])
  })
})
