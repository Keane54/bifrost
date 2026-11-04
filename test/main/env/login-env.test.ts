import { expect, test, vi } from 'vitest'
import { ENV_MARKER, loadLoginEnv, parseLoginEnvOutput } from '../../../src/main/env/login-env'

test('parseLoginEnvOutput reads only the text between the markers', () => {
  const out = `banner text\n${ENV_MARKER}{"PATH":"/a","HOME":"/h"}${ENV_MARKER}\nmore`
  expect(parseLoginEnvOutput(out)).toEqual({ HOME: '/h', PATH: '/a' })
})

test('parseLoginEnvOutput returns null without markers or with bad JSON', () => {
  expect(parseLoginEnvOutput('{"PATH":"/a"}')).toBeNull()
  expect(parseLoginEnvOutput(`${ENV_MARKER}{bad${ENV_MARKER}`)).toBeNull()
})

test('loadLoginEnv runs an interactive login shell with a small env', async () => {
  const exec = vi.fn().mockResolvedValue({
    code: 0,
    stderr: '',
    stdout: `${ENV_MARKER}{"PATH":"/login","BIFROST_NODE":"/E","ELECTRON_RUN_AS_NODE":"1"}${ENV_MARKER}`,
  })
  const env = await loadLoginEnv(exec, {
    execPath: '/E',
    fallback: { CLAUDECODE: '1', HOME: '/h', PATH: '/fb', USER: 'u' },
    shell: '/bin/zsh',
  })
  expect(env).toEqual({ PATH: '/login' })
  const [file, args, opts] = exec.mock.calls[0]
  expect(file).toBe('/bin/zsh')
  expect(args[0]).toBe('-lic')
  expect(opts.timeoutMs).toBe(5000)
  expect(opts.env).toEqual({ BIFROST_NODE: '/E', ELECTRON_RUN_AS_NODE: '1', HOME: '/h', USER: 'u' })
})

test('loadLoginEnv falls back to its own env when the shell fails', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stderr: 'x', stdout: '' })
  expect(await loadLoginEnv(exec, { execPath: '/E', fallback: { PATH: '/fb' } })).toEqual({
    PATH: '/fb',
  })
})
