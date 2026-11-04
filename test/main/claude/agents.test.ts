import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import { listAgents, parseAgents } from '../../../src/main/claude/agents'

const fixture = readFileSync(join(__dirname, '../../fixtures/agents.json'), 'utf8')

test('parseAgents reads all entries from the fixture', () => {
  const r = parseAgents(fixture)
  expect(r.error).toBeUndefined()
  expect(r.entries).toHaveLength(2)
  expect(r.entries[1]).toMatchObject({
    id: '6df6c51a',
    kind: 'background',
    pid: 26100,
    status: 'busy',
  })
})
test('parseAgents ignores text before the JSON array', () => {
  expect(parseAgents(`Update available: 2.1.400\n${fixture}`).entries).toHaveLength(2)
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
  const data = JSON.parse(fixture)
  delete data[0].sessionId
  expect(parseAgents(JSON.stringify(data)).entries.map(e => e.name)).toEqual(['beta-24'])
})
test('listAgents adds --all only when asked', async () => {
  const run = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: '[]' })
  await listAgents(run)
  await listAgents(run, { all: true })
  expect(run.mock.calls.map(c => c[0])).toEqual([
    ['agents', '--json'],
    ['agents', '--json', '--all'],
  ])
})
test('listAgents returns stderr as the error when the exit code is not 0', async () => {
  const run = vi.fn().mockResolvedValue({ code: 1, stderr: 'boom', stdout: '' })
  expect(await listAgents(run)).toEqual({ entries: [], error: 'boom' })
})
test('parseAgents keeps an entry without pid', () => {
  const r = parseAgents('[{"sessionId":"s1","name":"n","kind":"background","id":"aa"}]')
  expect(r.entries).toHaveLength(1)
  expect(r.entries[0]).toMatchObject({ id: 'aa', sessionId: 's1', status: '' })
  expect(r.entries[0].pid).toBeUndefined()
})
test('parseAgents reads waitingFor', () => {
  const r = parseAgents(
    '[{"sessionId":"s1","pid":5,"status":"waiting","waitingFor":"permission prompt"}]',
  )
  expect(r.entries[0].waitingFor).toBe('permission prompt')
})
test('parseAgents does not copy state', () => {
  const r = parseAgents('[{"sessionId":"s1","pid":5,"status":"idle","state":"done"}]')
  expect('state' in r.entries[0]).toBe(false)
})
