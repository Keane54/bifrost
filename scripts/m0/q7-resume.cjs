// M0 question 7: resume an ended interactive test session in the background.
// Usage: q7-resume.cjs <sessionId>
// The sessionId must belong to a test session that these scripts started.
// The script runs "claude --bg --resume <sessionId>" in .m0-sandbox.
// It records the stdout and the new entry: id, sessionId, kind and name.
// Then it attaches, asks "Which word did I ask you to remember?" and reads the reply.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports -- CommonJS script for Node. */
const L = require('./lib.cjs')
const { TestPty, log, sleep, writeOut } = L

;(async () => {
  const sessionId = process.argv[2]
  if (!sessionId) throw new Error('usage: q7-resume.cjs <sessionId>')
  const R = { sessionId }
  // A second resume of a running session starts a copy. So use an active entry if one exists.
  const active = (await L.listAgents()).filter((e) => e.sessionId === sessionId)
  let r
  if (active.length === 1 && active[0].name.startsWith(L.TEST_PREFIX)) {
    r = { id: active[0].id, note: 'already resumed by an earlier run; no new resume' }
    R.resume = r
  } else {
    r = await L.resumeBg(sessionId)
    R.resume = { code: r.code, stdout: r.stdout, stderr: r.stderr, id: r.id, ms: r.ms }
  }
  log('resume:', R.resume)
  if (!r.id) throw new Error('no short id in the resume output')
  const w = await L.watchEntry(
    { id: r.id },
    (e) => typeof e.pid === 'number' && e.status !== 'busy',
    { timeout: 60000, interval: 400 }
  )
  R.entry = w.entry
  R.trace = w.trace.map((t) => ({ ms: t.ms, sig: t.sig }))
  R.sameSessionId = !!w.entry && w.entry.sessionId === sessionId
  log('entry:', w.entry, 'same sessionId:', R.sameSessionId)
  if (w.entry && w.entry.name.startsWith(L.TEST_PREFIX)) L.registerStarted(w.entry, 'resumeBg')

  const P = await TestPty.attach({ id: r.id })
  await P.waitQuiet(1500, 30000)
  await P.typeLine('Which word did I ask you to remember?')
  R.turn = await L.waitTurn({ id: r.id }, { timeout: 90000 })
  await P.waitQuiet(1500, 15000, false)
  const screen = await P.screenText()
  await P.save(`q7-${r.id}`)
  R.screenHasFalconReply = /⏺[^\n]*FALCON/i.test(screen)
  const tr = L.transcriptMessages(sessionId)
  R.transcript = tr && {
    file: tr.file,
    messages: tr.messages
      .filter((m) => !m.meta && m.text)
      .map((m) => `${m.type}: ${m.text.slice(0, 80)}`)
  }
  R.lastAssistant = tr && tr.messages.filter((m) => m.type === 'assistant' && m.text).slice(-1)[0]
  log('reply:', R.lastAssistant, 'screen has FALCON reply:', R.screenHasFalconReply)
  P.lock('close')
  P.closeAttach('SIGHUP')
  await Promise.race([P.exited, sleep(5000)])
  R.entryAfter = (await L.listAgents()).filter((e) => e.sessionId === sessionId)
  writeOut(`q7-result-${sessionId.slice(0, 8)}.json`, R)
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
