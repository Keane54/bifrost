import { describe, expect, test } from 'vitest'
import type { ExecResult, RunClaude } from '../../../src/main/claude/cli'
import { checkCliResult, createPluginCli } from '../../../src/main/live/plugin-cli'

type Call = { args: string[]; opts?: { timeoutMs?: number } }

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
    await expect(fake({ code: 1, stderr: 'boom' }).cli.plugin()).rejects.toThrow(
      'claude plugin list failed: boom',
    )
    await expect(fake({ code: 3 }).cli.plugin()).rejects.toThrow('claude plugin list failed: 3')
    await expect(fake({ stdout: 'no json here' }).cli.plugin()).rejects.toThrow(
      'claude plugin list failed',
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
  ])('each command uses the exact arguments: %s', async (_name, call, args) => {
    const { calls, cli } = fake({ stdout: '{"outcome":"ok"}' })
    await call(cli)
    expect(calls).toEqual([{ args, opts: { timeoutMs: 30000 } }])
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
  test('falls back to stderr, then to the exit code', () => {
    expect(() => checkCliResult({ code: 1, stderr: 'oops\n', stdout: 'text' })).toThrow('oops')
    expect(() => checkCliResult({ code: 2, stderr: '', stdout: '' })).toThrow(
      'claude exited with code 2',
    )
  })
})
