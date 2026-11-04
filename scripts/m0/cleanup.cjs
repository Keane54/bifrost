// Stop and remove the background test sessions that these scripts started.
// Usage: cleanup.cjs [--dry-run]
// The script reads the list of started sessions in M0_OUT/started.jsonl.
// It acts only on an entry of "claude agents --json --all" whose name starts
// with "bifrost-test-" and whose id or sessionId is in that list.
// assertTestTarget checks each entry again, and it refuses bifrost-test-idle.
// At the end the script prints every bifrost-test- entry that is left.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports -- CommonJS script for Node. */
const L = require('./lib.cjs')
const { log, writeOut } = L

;(async () => {
  const dry = process.argv.includes('--dry-run')
  const started = L.readStarted()
  const ids = new Set(started.map((s) => s.id).filter(Boolean))
  const sids = new Set(started.map((s) => s.sessionId).filter(Boolean))
  const R = { dry, actions: [] }
  const all = await L.listAgents({ all: true })
  const active = await L.listAgents()
  const targets = all.filter(
    (e) =>
      e.id &&
      String(e.name).startsWith(L.TEST_PREFIX) &&
      e.name !== 'bifrost-test-idle' &&
      (ids.has(e.id) || sids.has(e.sessionId))
  )
  for (const e of targets) {
    const a = { id: e.id, name: e.name, state: e.state, status: e.status }
    const isActive = active.some((x) => x.id === e.id && typeof x.pid === 'number')
    try {
      if (isActive && !dry) {
        const s = await L.stopTest(e.id)
        a.stop = { code: s.code, stdout: s.stdout.trim(), stderr: s.stderr.trim() }
      }
      if (!dry) {
        const r = await L.rmTest(e.id)
        a.rm = { code: r.code, stdout: r.stdout.trim(), stderr: r.stderr.trim() }
      }
    } catch (err) {
      a.error = err.message
    }
    R.actions.push(a)
    log('cleanup:', a)
  }
  const after = await L.listAgents({ all: true })
  R.leftAll = after.filter((e) => String(e.name).startsWith(L.TEST_PREFIX))
  const afterActive = await L.listAgents()
  R.leftActive = afterActive.filter((e) => String(e.name).startsWith(L.TEST_PREFIX))
  log('bifrost-test- entries left (--all):', R.leftAll)
  log('bifrost-test- entries left (active):', R.leftActive)
  writeOut(dry ? 'cleanup-dry.json' : 'cleanup.json', R)
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
