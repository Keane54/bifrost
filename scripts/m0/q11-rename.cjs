// M0 question 11: check that /rename exists and changes the name in "claude agents --json".
// Usage: q11-rename.cjs <short id of a bifrost-test- session> <new suffix>
// The new name is "bifrost-test-<new suffix>", so the session stays a test session.
// The script attaches, types "/rename <new name>" and Enter, and reads the name
// after 4 seconds. Then it polls for 15 more seconds and records the screen.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports -- CommonJS script for Node. */
const L = require('./lib.cjs')
const { TestPty, log, sleep, writeOut } = L

;(async () => {
  const [id, suffix] = process.argv.slice(2)
  if (!id || !suffix) throw new Error('usage: q11-rename.cjs <short id> <new suffix>')
  const newName = L.TEST_PREFIX + suffix
  const R = { id, newName }
  const P = await TestPty.attach({ id })
  R.nameBefore = P.entry.name
  await P.waitQuiet(1500, 30000)
  const mark = P.mark()
  await P.typeLine(`/rename ${newName}`, 500)
  const t = Date.now()
  await sleep(4000)
  const e4 = (await L.listAgents()).find((x) => x.id === id)
  R.nameAfter4s = e4 && e4.name
  log(`name after 4 s: ${R.nameAfter4s}`)
  R.poll = []
  while (Date.now() - t < 19000 && (!R.poll.length || R.poll[R.poll.length - 1].name !== newName)) {
    const e = (await L.listAgents()).find((x) => x.id === id)
    R.poll.push({ ms: Date.now() - t, name: e && e.name })
    await sleep(1000)
  }
  await P.waitQuiet(1000, 10000, false)
  const lines = await P.screenLines()
  await P.save('q11-rename')
  R.screenTail = lines.filter((l) => l.trim()).slice(-8)
  R.output = L.stripAnsi(P.since(mark)).replace(/\s+/g, ' ').slice(-400)
  P.lock('close')
  P.closeAttach('SIGHUP')
  await Promise.race([P.exited, sleep(5000)])
  R.entryAfter = (await L.listAgents()).find((x) => x.id === id) || null
  if (R.entryAfter && R.entryAfter.name === newName) L.registerStarted(R.entryAfter, 'rename')
  writeOut('q11-result.json', R)
  log('result:', { before: R.nameBefore, after4s: R.nameAfter4s, poll: R.poll, tail: R.screenTail })
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
