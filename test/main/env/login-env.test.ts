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
  const log = vi.fn()
  expect(await loadLoginEnv(exec, { execPath: '/E', fallback: { PATH: '/fb' }, log })).toEqual({
    PATH: '/fb',
  })
  expect(log).toHaveBeenCalledTimes(1)
  expect(log.mock.calls[0][0]).toMatch(/login shell failed \(exit code 1\)\. Time: \d+ ms\.$/)
})

test('loadLoginEnv logs a timeout of the shell', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stderr: '', stdout: '', timedOut: true })
  const log = vi.fn()
  await loadLoginEnv(exec, { execPath: '/E', fallback: { PATH: '/fb' }, log })
  expect(log).toHaveBeenCalledTimes(1)
  expect(log.mock.calls[0][0]).toMatch(/\(timeout after 5000 ms\)\. Time: \d+ ms\.$/)
})

test('loadLoginEnv logs output that does not parse', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'banner only' })
  const log = vi.fn()
  await loadLoginEnv(exec, { execPath: '/E', fallback: { PATH: '/fb' }, log })
  expect(log).toHaveBeenCalledTimes(1)
  expect(log.mock.calls[0][0]).toMatch(/\(the output did not parse\)\. Time: \d+ ms\.$/)
})

test('loadLoginEnv logs nothing when the shell gives a good env', async () => {
  const exec = vi.fn().mockResolvedValue({
    code: 0,
    stderr: '',
    stdout: `${ENV_MARKER}{"PATH":"/login"}${ENV_MARKER}`,
  })
  const log = vi.fn()
  expect(await loadLoginEnv(exec, { execPath: '/E', fallback: {}, log })).toEqual({
    PATH: '/login',
  })
  expect(log).not.toHaveBeenCalled()
})

test('parseLoginEnvOutput returns null for a value that is not a string or for no PATH', () => {
  for (const json of ['{"PATH":1}', '{}', '{"HOME":"/h"}']) {
    expect(parseLoginEnvOutput(`${ENV_MARKER}${json}${ENV_MARKER}`)).toBeNull()
  }
})

test('loadLoginEnv falls back when the shell output has no markers', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'banner only' })
  expect(
    await loadLoginEnv(exec, {
      execPath: '/E',
      fallback: { A: undefined, PATH: '/fb' },
      log: () => {},
    }),
  ).toEqual({ PATH: '/fb' })
})
