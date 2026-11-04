// M0 question 6: find the signal that ends an interactive session cleanly.
// Usage: q6-take-control.cjs [SIGTERM] [SIGHUP] [SIGINT2]
// For each signal the script starts an interactive test session in a PTY,
// "claude --model haiku --name bifrost-test-ext-<signal>", in .m0-sandbox.
// It types "Remember the word FALCON. Reply with OK." and waits for the reply.
// Then it sends the signal to the session PID. SIGINT2 means SIGINT two times.
// The PID comes from the test entry in "claude agents --json" in the same check.
// The script records if the process ends in 5 seconds, the exit code or signal,
// the last screen lines, and the transcript after the end.
// If the process does not end, the next signal goes to the same session.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports, @typescript-eslint/explicit-function-return-type -- CommonJS script for Node. */
const L = require('./lib.cjs')
const { TestPty, log, sleep, writeOut, stripAnsi } = L

const ENV_NOTE = 'cleanEnv(): no CLAUDECODE, CLAUDE_CODE_*, TERM_PROGRAM*, TERM_SESSION_ID, WARP_*'

async function startExt(suffix) {
  const X = TestPty.interactive(suffix)
  const ready = await X.waitQuiet(1500, 60000)
  if (X.trustPrompt) throw new Error('trust prompt shown: stop')
  const name = `bifrost-test-${suffix}`
  const w = await L.watchEntry({ name }, (e) => typeof e.pid === 'number', { timeout: 20000 })
  if (!w.ok) throw new Error(`${name} did not show in claude agents --json`)
  const e = w.entry
  if (e.pid !== X.pty.pid) log(`note: entry pid ${e.pid} is not the PTY pid ${X.pty.pid}`)
  L.registerStarted(e, 'interactive')
  const lines = await X.screenLines()
  writeOut(`q6-${suffix}-ready.screen.txt`, lines.join('\n'))
  const info = {
    name,
    ptyPid: X.pty.pid,
    entry: e,
    firstOutputMs: X.firstOutputMs,
    ready,
    registeredAfterMs: w.ms,
    statuslineShown: /% ctx|healthy/.test(lines.join('\n')),
    bottomLines: lines.slice(-6)
  }
  log(`started ${name}:`, info)
  return { X, info }
}

async function run(signalSpec, current) {
  const res = { signal: signalSpec }
  let X
  let info
  if (current && !current.X.exitInfo) {
    ;({ X, info } = current)
    res.reusedSession = info.name
  } else {
    const suffix = `ext-${signalSpec.toLowerCase()}`
    ;({ X, info } = await startExt(suffix))
    res.session = info
    await X.typeLine('Remember the word FALCON. Reply with OK.')
    res.turn = await L.waitTurn({ pid: info.entry.pid }, { timeout: 90000 })
    await X.waitQuiet(1500, 15000, false)
    res.screenBefore = (await X.screenLines()).filter((l) => l.trim()).slice(-10)
    log('turn:', res.turn.trace)
  }
  const pid = info.entry.pid
  const sigs = signalSpec === 'SIGINT2' ? ['SIGINT', 'SIGINT'] : [signalSpec]
  const mark = X.mark()
  const t = Date.now()
  res.sent = []
  for (let i = 0; i < sigs.length; i++) {
    // Wait up to 1 second between two signals. Stop when the process ended.
    if (i > 0) await Promise.race([X.exited, sleep(1000)])
    if (X.exitInfo) break
    try {
      await L.signalTestPid(pid, sigs[i])
      res.sent.push({ sig: sigs[i], ms: Date.now() - t })
    } catch (err) {
      // The safety check refuses a PID that left the list. That is a correct end.
      if (!(err instanceof L.SafetyError)) throw err
      res.sent.push({ sig: sigs[i], refused: err.message })
      break
    }
  }
  const ex = await Promise.race([X.exited, sleep(5000).then(() => null)])
  res.endedIn5s = !!ex
  res.exit = ex
  res.msToExit = ex ? Date.now() - t : null
  await sleep(300)
  const lines = await X.screenLines()
  res.lastScreenLines = lines.filter((l) => l.trim()).slice(-8)
  res.outputAfterSignal = stripAnsi(X.since(mark)).replace(/\s+/g, ' ').trim().slice(-600)
  res.bufferAfter = X.bufferType()
  writeOut(`q6-${signalSpec}.raw`, X.since(mark))
  writeOut(`q6-${signalSpec}.screen.txt`, lines.join('\n'))
  if (ex) {
    await sleep(1500)
    const still = (await L.listAgents()).filter((e) => e.sessionId === info.entry.sessionId)
    res.entryAfterExit = still
    const tr = L.transcriptMessages(info.entry.sessionId)
    res.transcript = tr && {
      file: tr.file,
      messages: tr.messages.filter((m) => !m.meta).map((m) => `${m.type}: ${m.text.slice(0, 80)}`),
      hasFalcon: tr.messages.some((m) => m.type === 'user' && /FALCON/.test(m.text)),
      hasOk: tr.messages.some((m) => m.type === 'assistant' && /OK/.test(m.text))
    }
  }
  log(`${signalSpec}:`, { endedIn5s: res.endedIn5s, exit: res.exit, last: res.lastScreenLines })
  return { res, current: { X, info } }
}

;(async () => {
  const order = process.argv.slice(2).length
    ? process.argv.slice(2)
    : ['SIGTERM', 'SIGHUP', 'SIGINT2']
  const R = { env: ENV_NOTE, runs: [] }
  let current = null
  for (const s of order) {
    const { res, current: c } = await run(s, current)
    R.runs.push(res)
    current = c
    writeOut(`q6-result-${order.join('-')}.json`, R)
  }
  if (current && !current.X.exitInfo) {
    log(`WARNING: ${current.info.name} still runs after all signals`)
    R.stillRunning = current.info
  }
  writeOut(`q6-result-${order.join('-')}.json`, R)
  log(`saved q6-result-${order.join('-')}.json`)
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
