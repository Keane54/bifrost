// A test of the write log of the fake gh of the smoke tests. The script runs with sh and a test
// home in a temporary folder. It never calls the real gh.
import { execFile } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

const run = promisify(execFile)
const FAKE_GH = join(import.meta.dirname, '..', 'smoke', 'fake-claude', 'gh')

let home: string

beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-fake-gh-'))
})

afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

// Run the fake gh. An unknown call exits with code 2, which does not matter here.
async function gh(args: string[]): Promise<void> {
  await run('sh', [FAKE_GH, ...args], {
    env: { BIFROST_TEST_HOME: home, PATH: '/usr/bin:/bin' },
  }).catch(() => undefined)
}

async function writes(): Promise<string[]> {
  const text = await readFile(join(home, 'gh-writes.log'), 'utf8').catch(() => '')
  return text === '' ? [] : text.trimEnd().split('\n')
}

const POLL = ['api', 'graphql', '-f', 'query=query Poll {\n  viewer { login }\n}']
const CONTEXT = [
  'api',
  'graphql',
  '-f',
  'query=query ReviewContext($owner: String!) {\n  x\n}',
  '-f',
  'owner=acme',
  '-f',
  'repo=api',
  '-F',
  'number=7',
  '-f',
  'login=me',
  '-F',
  'head=true',
  '-f',
  'after=abc',
]

describe('the write log of the fake gh', () => {
  it(
    'logs no read: the Poll and ReviewContext forms, a ' + 'GET with fields, a plain api call',
    async () => {
      await gh(POLL)
      await gh(CONTEXT)
      await gh(['api', '--method', 'GET', 'repos/acme/api/pulls', '-f', 'per_page=5'])
      await gh(['api', '-X', 'GET', 'repos/acme/api/pulls', '-F', 'per_page=5'])
      await gh(['api', 'repos/acme/api/pulls/7'])
      await gh(['pr', 'view', '--json', 'number,title,url,state'])
      expect(await writes()).toEqual([])
    },
  )

  it('logs a call with fields and no method flag, because gh sends it as POST', async () => {
    const calls = [
      ['api', 'repos/acme/api/pulls/7/reviews', '-f', 'event=APPROVE'],
      ['api', 'repos/acme/api/pulls/7/reviews', '-F', 'line=1'],
      ['api', 'repos/acme/api/pulls/7/reviews', '--field', 'line=1'],
      ['api', 'repos/acme/api/pulls/7/reviews', '--raw-field', 'body=x'],
      ['api', 'repos/acme/api/pulls/7/reviews', '--input', '-'],
      ['api', 'repos/acme/api/pulls/7/reviews', '--input=body.json'],
      // A Poll or ReviewContext query with one more field is not the exact read form.
      [...POLL, '-f', 'event=APPROVE'],
      [...CONTEXT, '-f', 'event=APPROVE'],
    ]
    for (const args of calls) await gh(args)
    expect(await writes()).toHaveLength(calls.length)
  })

  it('logs a mutation in any case and after a space, and a method that is not GET', async () => {
    await gh(['api', 'graphql', '-f', 'query= Mutation AddThread { x }'])
    await gh(['api', 'graphql', '-f', 'query=\nmutation SetBody { x }'])
    await gh(['api', '--method', 'POST', 'repos/acme/api/pulls/7/reviews', '--input', '-'])
    await gh(['api', '-XDELETE', 'repos/acme/api/pulls/7/reviews/1'])
    await gh(['pr', 'merge', '7'])
    expect(await writes()).toEqual([
      'api graphql -f query= Mutation AddThread { x }',
      'api graphql -f query= mutation SetBody { x }',
      'api --method POST repos/acme/api/pulls/7/reviews --input -',
      'api -XDELETE repos/acme/api/pulls/7/reviews/1',
      'pr merge 7',
    ])
  })
})
