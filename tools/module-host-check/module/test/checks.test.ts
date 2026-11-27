// Tests the two lines the module logs as it starts. The check app reads them from the host to prove
// a module finds no way out: no network or process globals, and no dynamic import.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { IMPORT_PROBE, logGlobals, logImportCheck, start } from '../src/checks.ts'

test('theGlobalsLineHoldsTheTypeOfEachGlobal', t => {
  const log = t.mock.method(console, 'log', () => {})
  logGlobals()

  assert.equal(log.mock.callCount(), 1)
  const [line] = log.mock.calls[0].arguments as [string]
  assert.ok(line.startsWith('globals '), line)
  const globals = JSON.parse(line.slice('globals '.length))
  assert.deepEqual(Object.keys(globals), [
    'fetch',
    'XMLHttpRequest',
    'WebSocket',
    'Worker',
    'require',
    'process',
  ])
  // Node has some of these, so the line must show what's really there.
  assert.equal(globals.fetch, typeof fetch)
  assert.equal(globals.process, typeof process)
})

// Node can load a data: URL, so here the check has to say so. A check that always said rejected
// would prove nothing in the host.
test('theImportCheckAllowsAWorkingLoader', async t => {
  const log = t.mock.method(console, 'log', () => {})
  await logImportCheck()

  assert.deepEqual(
    log.mock.calls.map(call => call.arguments),
    [['import allowed']],
  )
})

test('theImportCheckCountsAThrowAsRejected', async t => {
  const log = t.mock.method(console, 'log', () => {})
  const specifiers: string[] = []
  await logImportCheck(specifier => {
    specifiers.push(specifier)
    throw new TypeError('No module loader provided')
  })
  await logImportCheck(() => Promise.reject(new TypeError('Module loading is off')))
  await logImportCheck(() => Promise.reject('not an error'))
  await logImportCheck(() => Promise.resolve({}))

  assert.deepEqual(specifiers, [IMPORT_PROBE])
  assert.deepEqual(
    log.mock.calls.map(call => call.arguments),
    [
      ['import rejected: No module loader provided'],
      ['import rejected: Module loading is off'],
      ['import rejected: not an error'],
      ['import allowed'],
    ],
  )
})

test('theFirstRenderDoesNotWaitForTheImportCheck', async t => {
  const lines: string[] = []
  t.mock.method(console, 'log', (line: string) => lines.push(line))
  // An import that never settles stands in for a host whose loader hangs.
  start(() => lines.push('render'), () => new Promise(() => {}))
  await new Promise(resolve => setTimeout(resolve, 20))

  assert.equal(lines.length, 2, JSON.stringify(lines))
  assert.ok(lines[0].startsWith('globals '), lines[0])
  assert.equal(lines[1], 'render')
})
