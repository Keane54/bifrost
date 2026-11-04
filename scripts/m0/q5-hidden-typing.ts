// M0 question 5: type into a session through a hidden attach.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/q5-hidden-typing.ts <short id of a bifrost-test- session>
// The script attaches and measures the time to the first output and to ready.
// It sends five inputs:
//   A: text, a 300 ms gap, then Enter.
//   B: two lines in bracketed paste with CR between them, then Enter.
//   C: two lines in bracketed paste with LF between them, then Enter.
//   D: text and Enter in one write.
//   E: two lines with CR between them and no bracketed paste.
// Then it reads the transcript and opens a second attach to look at the conversation.
import * as L from './lib.ts'

const { TestPty, log, sleep, writeOut } = L

;(async () => {
  const id = process.argv[2]
  if (!id) throw new Error('usage: q5-hidden-typing.ts <short id>')
  const R = {}
  const entry = await L.assertTestTarget({ id })
  const before = L.transcriptMessages(entry.sessionId)
  const startCount = before ? before.messages.length : 0

  const t = Date.now()
  const H = await TestPty.attach({ id })
  const ready = await H.waitQuiet(1500, 30000)
  R.hidden = {
    includingSafetyCheckMs: Date.now() - t,
    spawnToFirstOutputMs: H.firstOutputMs,
    spawnToLastOutputMs: ready.readyMs,
    spawnToReadyDetectedMs: Date.now() - H.t0,
  }
  log('hidden attach:', R.hidden)

  const turn = async (label, fn, timeout = 90000) => {
    const m = H.mark()
    await fn()
    const r = await L.waitTurn({ id }, { timeout })
    await H.waitQuiet(1000, 15000, false)
    const lines = await H.screenLines()
    writeOut(`q5-${label}.screen.txt`, lines.join('\n'))
    R[label] = {
      by: r.by,
      bytes: H.since(m).length,
      promptRow: lines.filter(l => l.startsWith('❯')).slice(-1)[0],
      trace: r.trace,
      turn: r.ok,
    }
    log(`input ${label}:`, R[label])
    return r
  }

  await turn('A-plain', () => H.typeLine('Reply with PONG'))
  await turn('B-paste-cr', async () => {
    await H.write('\x1b[200~line one\rline two\x1b[201~')
    await sleep(300)
    await H.write('\r')
  })
  await turn('C-paste-lf', async () => {
    await H.write('\x1b[200~line three\nline four\x1b[201~')
    await sleep(300)
    await H.write('\r')
  })
  const d = await turn('D-one-write', () => H.write('Reply with PING\r'), 15000)
  if (!d.ok) {
    R['D-one-write'].note = 'No turn in 15 s. The script sends Enter again.'
    await turn('D-second-enter', () => H.write('\r'))
  }
  await turn('E-no-paste', () => H.write('solo one\rsolo two'), 30000)
  // E can leave text in the prompt. Submit it, so that the transcript shows it.
  await sleep(1000)
  const eLines = await H.screenLines()
  if (eLines.some(l => /❯\s*solo two/.test(l))) {
    R.E_left_in_prompt = true
    await turn('E-enter', () => H.write('\r'))
  }

  // Read the new messages of the transcript.
  await sleep(1500)
  const after = L.transcriptMessages(entry.sessionId)
  R.transcriptFile = after?.file
  R.newMessages = after
    ? after.messages
        .slice(startCount)
        .filter(m => !m.meta)
        .map(m => ({ text: m.text, type: m.type }))
    : null
  log('new transcript messages:', R.newMessages)

  // Open a second view and look at the conversation.
  const V = await TestPty.attach({ id })
  await V.waitQuiet(1500, 30000)
  await V.save('q5-view')
  R.view = { firstOutputMs: V.firstOutputMs }
  for (const P of [H, V]) {
    P.lock('close')
    P.closeAttach('SIGHUP')
    await Promise.race([P.exited, sleep(5000)])
  }
  R.sessionAfter = (await L.listAgents()).find(x => x.id === id) || null
  writeOut('q5-result.json', R)
  log('saved q5-result.json')
  process.exit(0)
})().catch(e => {
  console.error(e)
  process.exit(1)
})
