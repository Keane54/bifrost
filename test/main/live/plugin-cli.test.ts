import { afterEach, describe, expect, test, vi } from 'vitest'
import type { ExecResult, KillSignal, RunClaude } from '../../../src/main/claude/cli'
import {
  checkCliResult,
  createPluginCli,
  PLUGIN_GRACE_MS,
  PLUGIN_TIMEOUT_MS,
  TIMEOUT_MESSAGE,
} from '../../../src/main/live/plugin-cli'

type Call = { args: string[]; opts?: { timeoutMs?: number; killSignal?: KillSignal } }

afterEach(() => {
  vi.useRealTimers()
})

function fake(result: Partial<ExecResult> = {}) {
  const calls: Call[] = []
  const run: RunClaude = async (args, opts) => {
    calls.push({ args, opts })
    return { code: 0, stderr: '', stdout: '', ...result }
  }
  return { calls, cli: createPluginCli(run) }
}

const PLUGIN_LIST =
  '[{"id":"bifrost-live@bifrost-local","version":"1.0.0","scope":"user","enabled":true,"installPath":"","readFromFolder":"/h/.bifrost/mod"}]'

describe('plugin list', () => {
  test('plugin runs plugin list --json and finds the Bifrost plugin', async () => {
    const { calls, cli } = fake({ stdout: PLUGIN_LIST })
    expect(await cli.plugin()).toEqual({ enabled: true, errors: [], folder: '/h/.bifrost/mod' })
    expect(calls).toEqual([{ args: ['plugin', 'list', '--json'], opts: { timeoutMs: 30000 } }])
  })
  test('plugin gives null when the list has no Bifrost plugin', async () => {
    expect(await fake({ stdout: '[]' }).cli.plugin()).toBeNull()
    expect(await fake({ stdout: '[{"id":"x@y","enabled":true}]' }).cli.plugin()).toBeNull()
  })
  test('plugin rejects for exit 1 or output that is not JSON', async () => {
    const text = "Bifrost couldn't read the plugin list from Claude Code:"
    await expect(fake({ code: 1, stderr: 'boom' }).cli.plugin()).rejects.toThrow(
      new Error(`${text} boom`),
    )
    await expect(fake({ code: 3 }).cli.plugin()).rejects.toThrow(
      new Error(`${text} it exited with code 3`),
    )
    await expect(fake({ stdout: 'no json here' }).cli.plugin()).rejects.toThrow(
      new Error(`${text} it gave no list`),
    )
  })
  test('marketplace names the marketplace list when it fails', async () => {
    await expect(fake({ code: 1, stderr: 'boom' }).cli.marketplace()).rejects.toThrow(
      new Error("Bifrost couldn't read the marketplace list from Claude Code: boom"),
    )
  })
  test('plugin skips text before the array', async () => {
    const r = await fake({ stdout: `Update available\n${PLUGIN_LIST}` }).cli.plugin()
    expect(r?.enabled).toBe(true)
  })
  test('marketplace finds bifrost-local with its path', async () => {
    const { calls, cli } = fake({
      stdout: '[{"name":"bifrost-local","source":"directory","path":"/h/.bifrost/mod"}]',
    })
    expect(await cli.marketplace()).toEqual({ path: '/h/.bifrost/mod', source: 'directory' })
    expect(calls[0].args).toEqual(['plugin', 'marketplace', 'list', '--json'])
  })
})

describe('commands', () => {
  const ID = 'bifrost-live@bifrost-local'
  test.each([
    [
      'addMarketplace',
      (c: ReturnType<typeof fake>['cli']) => c.addMarketplace('/h/.bifrost/mod'),
      ['plugin', 'marketplace', 'add', '/h/.bifrost/mod', '--scope', 'user', '--json'],
    ],
    [
      'install',
      (c: ReturnType<typeof fake>['cli']) => c.install(),
      ['plugin', 'install', ID, '--scope', 'user', '--json'],
    ],
    [
      'enable',
      (c: ReturnType<typeof fake>['cli']) => c.enable(),
      ['plugin', 'enable', ID, '--scope', 'user', '--json'],
    ],
    [
      'disable',
      (c: ReturnType<typeof fake>['cli']) => c.disable(),
      ['plugin', 'disable', ID, '--scope', 'user', '--json'],
    ],
    [
      'uninstall',
      (c: ReturnType<typeof fake>['cli']) => c.uninstall(),
      ['plugin', 'uninstall', ID, '--scope', 'user', '--json'],
    ],
    [
      'removeMarketplace',
      (c: ReturnType<typeof fake>['cli']) => c.removeMarketplace(),
      ['plugin', 'marketplace', 'remove', 'bifrost-local', '--scope', 'user', '--json'],
    ],
  ])(
    'each command uses the exact arguments and SIGTERM at the timeout: %s',
    async (_name, call, args) => {
      const { calls, cli } = fake({ stdout: '{"outcome":"ok"}' })
      await call(cli)
      expect(calls).toEqual([{ args, opts: { killSignal: 'SIGTERM', timeoutMs: 30000 } }])
    },
  )
  test('the timeout text is plain and names the time', () => {
    expect(TIMEOUT_MESSAGE).toBe("Claude Code didn't finish in 30 seconds.")
  })
  test('a command or a list that the timeout stopped rejects with the timeout text', async () => {
    const { cli } = fake({ code: 143, stdout: '{"outcome":"ok"}', timedOut: true })
    await expect(cli.install()).rejects.toThrow(TIMEOUT_MESSAGE)
    await expect(cli.plugin()).rejects.toThrow(TIMEOUT_MESSAGE)
    await expect(cli.marketplace()).rejects.toThrow(TIMEOUT_MESSAGE)
  })
  test('a command that does not end after the SIGTERM rejects after the grace time', async () => {
    vi.useFakeTimers()
    const run: RunClaude = () => new Promise<ExecResult>(() => {})
    const cli = createPluginCli(run)
    const done = cli.disable()
    let failed: unknown
    done.catch(err => {
      failed = err
    })
    await vi.advanceTimersByTimeAsync(PLUGIN_TIMEOUT_MS + PLUGIN_GRACE_MS - 1)
    expect(failed).toBeUndefined()
    await vi.advanceTimersByTimeAsync(1)
    expect(failed).toEqual(new Error(TIMEOUT_MESSAGE))
  })
  test('enable and disable pass for already_in_goal_state', async () => {
    const line =
      '{"command":"enable","outcome":"failed","message":"Plugin \\"bifrost-live\\" is already enabled","failureCode":"already_in_goal_state","alreadyInGoalState":true}'
    const { cli } = fake({ code: 1, stdout: line })
    await expect(cli.enable()).resolves.toBeUndefined()
    await expect(cli.disable()).resolves.toBeUndefined()
  })
  test('a failed result rejects with its message', async () => {
    const { cli } = fake({
      code: 1,
      stdout: '{"command":"install","outcome":"failed","message":"Plugin not found"}',
    })
    await expect(cli.install()).rejects.toThrow('Plugin not found')
  })
  test('addMarketplace refuses a relative path and a line break', async () => {
    const { calls, cli } = fake()
    await expect(cli.addMarketplace('mod')).rejects.toThrow()
    await expect(cli.addMarketplace('/h/a\nb')).rejects.toThrow()
    expect(calls).toEqual([])
  })
})

describe('checkCliResult', () => {
  const ok = { code: 0, stderr: '', stdout: '' }
  test('reads only the last line', () => {
    expect(() =>
      checkCliResult({ ...ok, stdout: 'Run this command now?\n{"outcome":"ok"}\n\n' }),
    ).not.toThrow()
    expect(() =>
      checkCliResult({
        ...ok,
        code: 1,
        stdout: '{"outcome":"ok"}\n{"outcome":"failed","message":"bad"}\n',
      }),
    ).toThrow('bad')
  })
  test.each(['42', 'null', '[]', '{"command":"install"}'])(
    'exit 0 with the unusable last line %s rejects',
    line => {
      expect(() => checkCliResult({ ...ok, stdout: line })).toThrow('Claude Code gave no result.')
    },
  )
  test('a non-object last line rejects at a non-zero exit with the exit code', () => {
    expect(() => checkCliResult({ code: 4, stderr: '', stdout: '42' })).toThrow(
      'claude exited with code 4',
    )
  })
  test('falls back to stderr, then to the exit code', () => {
    expect(() => checkCliResult({ code: 1, stderr: 'oops\n', stdout: 'text' })).toThrow('oops')
    expect(() => checkCliResult({ code: 2, stderr: '', stdout: '' })).toThrow(
      'claude exited with code 2',
    )
    expect(() => checkCliResult(ok)).toThrow('Claude Code gave no result.')
  })
})

describe('the skills IDs', () => {
  const ids = { marketplace: 'bifrost-skills', plugin: 'bifrost@bifrost-skills' }
  function skillsFake(stdout = '') {
    const calls: Call[] = []
    const run: RunClaude = async (args, opts) => {
      calls.push({ args, opts })
      return { code: 0, stderr: '', stdout }
    }
    return { calls, cli: createPluginCli(run, ids) }
  }
  test('install runs the plugin install command with the skills plugin ID', async () => {
    const { calls, cli } = skillsFake('{"outcome":"ok"}')
    await cli.install()
    expect(calls[0].args).toEqual([
      'plugin',
      'install',
      'bifrost@bifrost-skills',
      '--scope',
      'user',
      '--json',
    ])
  })
  test('marketplace finds bifrost-skills and not bifrost-local', async () => {
    const list =
      '[{"name":"bifrost-local","source":"directory","path":"/a"},' +
      '{"name":"bifrost-skills","source":"directory","path":"/b"}]'
    expect(await skillsFake(list).cli.marketplace()).toEqual({ path: '/b', source: 'directory' })
  })
  test('plugin finds the skills plugin and not the Live details plugin', async () => {
    const list =
      '[{"id":"bifrost-live@bifrost-local","enabled":true},{"id":"bifrost@bifrost-skills"}]'
    expect(await skillsFake(list).cli.plugin()).toEqual({ enabled: false, errors: [] })
  })
  test('removeMarketplace removes bifrost-skills', async () => {
    const { calls, cli } = skillsFake('{"outcome":"ok"}')
    await cli.removeMarketplace()
    expect(calls[0].args).toEqual([
      'plugin',
      'marketplace',
      'remove',
      'bifrost-skills',
      '--scope',
      'user',
      '--json',
    ])
  })
})
