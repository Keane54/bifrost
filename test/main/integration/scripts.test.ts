import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { HOOK_SCRIPT, statuslineScript } from '../../../src/main/integration/scripts'
import { runSh } from '../../helpers/run-sh'

const UUID = '1db8945b-137c-4d57-aaf4-01435209b6e7'
const OTHER_UUID = '00000000-1111-2222-3333-444444444444'

let dir: string
let home: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-scripts-'))
  home = join(dir, 'home')
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

// Make the file that tells the scripts that Bifrost runs.
async function activate(target: string): Promise<void> {
  await mkdir(target, { recursive: true })
  await writeFile(join(target, 'active'), '')
}

function runFile(
  file: string,
  stdin: string,
  bifrostHome: string,
  extraEnv: NodeJS.ProcessEnv = {},
  shell = 'sh',
): Promise<{ code: number | null; stdout: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(shell, [file], {
      env: { ...process.env, BIFROST_HOME: bifrostHome, ...extraEnv },
    })
    let stdout = ''
    child.stdout.on('data', chunk => {
      stdout += chunk
    })
    child.on('error', reject)
    child.on('close', code => resolve({ code, stdout }))
    child.stdin.on('error', () => {})
    child.stdin.end(stdin)
  })
}

// Make a bin directory with symbolic links to the given programs only.
async function binWith(...programs: string[]): Promise<string> {
  const bin = join(dir, 'bin')
  await mkdir(bin)
  for (const program of programs) await symlink(`/bin/${program}`, join(bin, program))
  return bin
}

test('the hook writes stdin to one event file and prints nothing', async () => {
  await activate(home)
  const r = await runSh(HOOK_SCRIPT, '{"a":1}', home)
  expect(r).toMatchObject({ code: 0, stdout: '' })
  const files = await readdir(join(home, 'events'))
  expect(files).toHaveLength(1)
  expect(files[0]).toMatch(/^\d+-\d+\.json$/)
  expect(await readFile(join(home, 'events', files[0]), 'utf8')).toBe('{"a":1}')
})

test('the hook exits 0 and prints nothing when it cannot write', async () => {
  await activate(home)
  // A file in the place of the events directory stops mkdir and the write.
  await writeFile(join(home, 'events'), 'x')
  expect(await runSh(HOOK_SCRIPT, '{}', home)).toMatchObject({ code: 0, stdout: '' })
  expect(await readFile(join(home, 'events'), 'utf8')).toBe('x')
})

// Claude Code runs the hook at each hook event.
// Each process start can cost 20 to 40 ms on a loaded Mac.
// So the hook starts only cat, plus mkdir when the events directory is missing.
// This test gives the hook a PATH with only cat and mkdir.
// If the hook starts mv or date, the test fails.
test('the hook works with only cat and mkdir on the PATH', async () => {
  const bin = await binWith('cat', 'mkdir')
  const file = join(dir, 'hook.sh')
  await writeFile(file, HOOK_SCRIPT)
  for (const input of ['{"a":1,\n"b":"x\\y"}\n\n{"c":2}\n', '{"a":1}\n{"b":2}']) {
    const target = join(dir, `home-${input.length}`)
    await activate(target)
    const r = await runFile(file, input, target, { PATH: bin }, '/bin/sh')
    expect(r).toMatchObject({ code: 0, stdout: '' })
    const files = await readdir(join(target, 'events'))
    expect(files).toHaveLength(1)
    expect(files[0]).toMatch(/^\d+-\d+\.json$/)
    expect(await readFile(join(target, 'events', files[0]), 'utf8')).toBe(input)
  }
})

test('the hook does nothing when Bifrost is not running', async () => {
  await mkdir(home)
  const r = await runSh(HOOK_SCRIPT, '{"hook_event_name":"Stop"}\n', home)
  expect(r).toMatchObject({ code: 0, stdout: '' })
  expect(existsSync(join(home, 'events'))).toBe(false)
})

// A tool event can carry a large tool input and output.
// The cost of the hook must not grow with the size of its input.
// The limit is wide, because a process start can take 40 ms on a loaded Mac.
test('the hook writes 1 MB of input in less than 1 s', async () => {
  await activate(home)
  const line = `${'x'.repeat(99)}\n`
  const input = `{"tool_response":"${line.repeat(10_486)}"}`
  expect(input.length).toBeGreaterThan(1_048_576)
  const start = performance.now()
  const r = await runSh(HOOK_SCRIPT, input, home)
  const ms = performance.now() - start
  expect(r).toMatchObject({ code: 0, stdout: '' })
  expect(ms).toBeLessThan(1000)
  const files = await readdir(join(home, 'events'))
  expect(files).toHaveLength(1)
  const bytes = await readFile(join(home, 'events', files[0]))
  expect(bytes.equals(Buffer.from(input))).toBe(true)
})

test('the hook makes its file with mode 0600', async () => {
  await activate(home)
  await runSh(HOOK_SCRIPT, '{"a":1}', home)
  const events = join(home, 'events')
  expect((await stat(events)).mode & 0o777).toBe(0o700)
  const files = await readdir(events)
  expect((await stat(join(events, files[0]))).mode & 0o777).toBe(0o600)
})

test('the wrapper writes status.json and prints the original output', async () => {
  await activate(home)
  const input = `{"session_id":"${UUID}","model":{"display_name":"Haiku"}}`
  const r = await runSh(statuslineScript("printf 'LINE'"), input, home)
  expect(r.stdout).toBe('LINE')
  expect(await readFile(join(home, 'sessions', UUID, 'status.json'), 'utf8')).toBe(input)
})

test('the wrapper refuses a session_id that is not a UUID', async () => {
  await activate(home)
  const r = await runSh(statuslineScript("printf 'LINE'"), '{"session_id":"../../x"}', home)
  expect(r.stdout).toBe('LINE')
  expect(existsSync(join(home, 'sessions'))).toBe(false)
})

test('the wrapper gives the original command the same stdin', async () => {
  await activate(home)
  const input = `{"session_id":"${UUID}"}`
  expect((await runSh(statuslineScript('cat'), input, home)).stdout).toBe(input)
})

test('the wrapper keeps single quotes in the original command', async () => {
  await activate(home)
  expect((await runSh(statuslineScript(`printf '%s' "it's"`), '{}', home)).stdout).toBe("it's")
})

test('the wrapper prints nothing without an original command', async () => {
  await activate(home)
  expect(await runSh(statuslineScript(null), '{}', home)).toMatchObject({ code: 0, stdout: '' })
})

// Claude Code runs the wrapper for each session again and again.
// So the wrapper starts only cat and mv, plus mkdir for a new session.
// This test gives the wrapper a PATH with only cat, mv and mkdir.
// If the wrapper starts grep, sed, tr, cp or mktemp, the test fails.
test('the wrapper works with only cat, mv and mkdir on the PATH', async () => {
  const bin = await binWith('cat', 'mv', 'mkdir')
  const file = join(dir, 'wrapper.sh')
  await writeFile(file, statuslineScript("printf 'LINE'"))
  const inputs = [`{"session_id":"${UUID}"}\n`, `{"a":1,\n"session_id": "${UUID}"}`]
  for (const input of inputs) {
    const target = join(dir, `home-${input.length}`)
    await activate(target)
    const r = await runFile(file, input, target, { PATH: bin }, '/bin/sh')
    expect(r).toEqual({ code: 0, stdout: 'LINE' })
    const sdir = join(target, 'sessions', UUID)
    expect(await readdir(sdir)).toEqual(['status.json'])
    const bytes = await readFile(join(sdir, 'status.json'))
    expect(bytes.equals(Buffer.from(input))).toBe(true)
  }
})

test('the wrapper skips the original command for a quiet session', async () => {
  await activate(home)
  await mkdir(join(home, 'sessions', UUID), { recursive: true })
  await writeFile(join(home, 'sessions', UUID, 'quiet'), '')
  const input = `{"session_id":"${UUID}","cost":1}`
  const r = await runSh(statuslineScript("printf 'LINE'"), input, home)
  expect(r).toEqual({ code: 0, stdout: '' })
  expect(await readFile(join(home, 'sessions', UUID, 'status.json'), 'utf8')).toBe(input)
})

test('the wrapper takes the first session_id key', async () => {
  await activate(home)
  const input = `{"session_id":"${UUID}","x":{"session_id":"${OTHER_UUID}"}}`
  const r = await runSh(statuslineScript("printf 'LINE'"), input, home)
  expect(r.stdout).toBe('LINE')
  expect(await readdir(join(home, 'sessions'))).toEqual([UUID])
  expect(await readFile(join(home, 'sessions', UUID, 'status.json'), 'utf8')).toBe(input)
})

test('the wrapper refuses a session_id with extra text', async () => {
  await activate(home)
  const withG = `g${UUID.slice(1)}`
  for (const value of [`${UUID}x`, `x${UUID}`, withG]) {
    const r = await runSh(statuslineScript("printf 'LINE'"), `{"session_id":"${value}"}`, home)
    expect(r).toEqual({ code: 0, stdout: 'LINE' })
    expect(existsSync(join(home, 'sessions'))).toBe(false)
  }
})

test('the wrapper only runs the original command when Bifrost is not running', async () => {
  await mkdir(home)
  const input = `{"session_id":"${UUID}"}\n\n`
  expect(await runSh(statuslineScript("printf 'LINE'"), input, home)).toEqual({
    code: 0,
    stdout: 'LINE',
  })
  expect(await runSh(statuslineScript('cat'), input, home)).toEqual({ code: 0, stdout: input })
  expect(await runSh(statuslineScript(null), input, home)).toEqual({ code: 0, stdout: '' })
  expect(existsSync(join(home, 'sessions'))).toBe(false)
})

test('the wrapper makes status.json with mode 0600', async () => {
  await activate(home)
  await runSh(statuslineScript(null), `{"session_id":"${UUID}"}`, home)
  expect((await stat(join(home, 'sessions'))).mode & 0o777).toBe(0o700)
  expect((await stat(join(home, 'sessions', UUID))).mode & 0o777).toBe(0o700)
  expect((await stat(join(home, 'sessions', UUID, 'status.json'))).mode & 0o777).toBe(0o600)
})

// Run the wrapper with fd 0 closed. A shell closes fd 0, then runs the file.
function runWithClosedStdin(
  file: string,
  bifrostHome: string,
): Promise<{ code: number | null; stdout: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn('sh', ['-c', 'exec 0<&-; exec bash "$0"', file], {
      env: { ...process.env, BIFROST_HOME: bifrostHome },
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 5000,
    })
    let stdout = ''
    child.stdout.on('data', chunk => {
      stdout += chunk
    })
    child.on('error', reject)
    child.on('close', code => resolve({ code, stdout }))
  })
}

test('the wrapper does not block when fd 0 is closed', async () => {
  const file = join(dir, 'wrapper.sh')
  await writeFile(file, statuslineScript("printf 'LINE'"))
  await activate(home)
  expect(await runWithClosedStdin(file, home)).toEqual({ code: 0, stdout: 'LINE' })
  const idle = join(dir, 'idle-home')
  await mkdir(idle)
  expect(await runWithClosedStdin(file, idle)).toEqual({ code: 0, stdout: 'LINE' })
}, 15_000)
