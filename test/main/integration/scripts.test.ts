import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { HOOK_SCRIPT, statuslineScript } from '../../../src/main/integration/scripts'

const UUID = '1db8945b-137c-4d57-aaf4-01435209b6e7'

let dir: string
let home: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-scripts-'))
  home = join(dir, 'home')
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

async function runSh(
  text: string,
  stdin: string,
  bifrostHome: string,
): Promise<{ code: number | null; stdout: string }> {
  const file = join(dir, 'script.sh')
  await writeFile(file, text)
  return runFile(file, stdin, bifrostHome)
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

test('the hook writes stdin to one event file and prints nothing', async () => {
  const r = await runSh(HOOK_SCRIPT, '{"a":1}', home)
  expect(r).toMatchObject({ code: 0, stdout: '' })
  const files = await readdir(join(home, 'events'))
  expect(files).toHaveLength(1)
  expect(files[0]).toMatch(/^\d+-\d+\.json$/)
  expect(await readFile(join(home, 'events', files[0]), 'utf8')).toBe('{"a":1}')
})

test('the hook exits 0 and prints nothing when it cannot write', async () => {
  expect(await runSh(HOOK_SCRIPT, '{}', '/dev/null/x')).toMatchObject({ code: 0, stdout: '' })
})

// Claude Code runs the hook after every tool call.
// Each process start can cost 20 to 40 ms on a loaded Mac.
// So the hook starts at most one other program (mv), plus mkdir when it must.
// This test gives the hook a PATH with only mv and mkdir.
// If the hook starts cat or date, the test fails.
test('the hook works with only mv and mkdir on the PATH', async () => {
  const bin = join(dir, 'bin')
  await mkdir(bin)
  await symlink('/bin/mv', join(bin, 'mv'))
  await symlink('/bin/mkdir', join(bin, 'mkdir'))
  const file = join(dir, 'hook.sh')
  await writeFile(file, HOOK_SCRIPT)
  for (const input of ['{"a":1,\n"b":"x\\y"}\n\n{"c":2}\n', '{"a":1}\n{"b":2}']) {
    const target = join(dir, `home-${input.length}`)
    const r = await runFile(file, input, target, { PATH: bin }, '/bin/sh')
    expect(r).toMatchObject({ code: 0, stdout: '' })
    const files = await readdir(join(target, 'events'))
    expect(files).toHaveLength(1)
    expect(files[0]).toMatch(/^\d+-\d+\.json$/)
    expect(await readFile(join(target, 'events', files[0]), 'utf8')).toBe(input)
  }
})

test('the wrapper writes status.json and prints the original output', async () => {
  const input = `{"session_id":"${UUID}","model":{"display_name":"Haiku"}}`
  const r = await runSh(statuslineScript("printf 'LINE'"), input, home)
  expect(r.stdout).toBe('LINE')
  expect(await readFile(join(home, 'sessions', UUID, 'status.json'), 'utf8')).toBe(input)
})

test('the wrapper refuses a session_id that is not a UUID', async () => {
  const r = await runSh(statuslineScript("printf 'LINE'"), '{"session_id":"../../x"}', home)
  expect(r.stdout).toBe('LINE')
  expect(existsSync(join(home, 'sessions'))).toBe(false)
})

test('the wrapper gives the original command the same stdin', async () => {
  const input = `{"session_id":"${UUID}"}`
  expect((await runSh(statuslineScript('cat'), input, home)).stdout).toBe(input)
})

test('the wrapper keeps single quotes in the original command', async () => {
  expect((await runSh(statuslineScript(`printf '%s' "it's"`), '{}', home)).stdout).toBe("it's")
})

test('the wrapper prints nothing without an original command', async () => {
  expect(await runSh(statuslineScript(null), '{}', home)).toMatchObject({ code: 0, stdout: '' })
})
