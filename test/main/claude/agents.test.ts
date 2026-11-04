import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import { listAgents, parseAgents } from '../../../src/main/claude/agents'

const fixture = readFileSync(join(__dirname, '../../fixtures/agents.json'), 'utf8')

test('parseAgents reads all entries from the fixture', () => {
  const r = parseAgents(fixture)
  expect(r.error).toBeUndefined()
  expect(r.entries).toHaveLength(2)
  expect(r.entries[1]).toMatchObject({ pid: 26100, kind: 'background', status: 'busy', id: '6df6c51a' })
})
test('parseAgents ignores text before the JSON array', () => {
  expect(parseAgents('Update available: 2.1.400\n' + fixture).entries).toHaveLength(2)
})
test('parseAgents returns an error for empty output', () => {
  expect(parseAgents('')).toEqual({ entries: [], error: 'empty output' })
})
test('parseAgents returns an error for text that is not JSON', () => {
  const r = parseAgents('not json')
  expect(r.entries).toEqual([])
  expect(r.error).toMatch(/parse/)
})
test('parseAgents skips an entry without sessionId and keeps the others', () => {
  const data = JSON.parse(fixture); delete data[0].sessionId
  expect(parseAgents(JSON.stringify(data)).entries.map(e => e.name)).toEqual(['beta-24'])
})
test('listAgents adds --all only when asked', async () => {
  const run = vi.fn().mockResolvedValue({ code: 0, stdout: '[]', stderr: '' })
  await listAgents(run); await listAgents(run, { all: true })
  expect(run.mock.calls.map(c => c[0])).toEqual([['agents', '--json'], ['agents', '--json', '--all']])
})
test('listAgents returns stderr as the error when the exit code is not 0', async () => {
  const run = vi.fn().mockResolvedValue({ code: 1, stdout: '', stderr: 'boom' })
  expect(await listAgents(run)).toEqual({ entries: [], error: 'boom' })
})
