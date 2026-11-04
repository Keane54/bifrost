// M0 questions 3 and 4: two attach clients on one session, and the detach methods.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/q3-two-clients.ts <short id of a bifrost-test- session>
// Client A attaches. Then client B attaches to the same session.
// B types a prompt. The script records what each client shows.
// B ends with SIGHUP. A gets the ← key, then SIGTERM.
// After the ← key the script locks all input to A, because the agent view
// lists every session on this Mac. Client C tests Ctrl+Z.
// After each step the script reads the session entry.
import { spawnSync } from 'node:child_process'
import * as L from './lib.ts'

const { TestPty, log, sleep, writeOut } = L

async function entryOf(id) {
  return (await L.listAgents()).find(x => x.id === id) || null
}

function procState(pid) {
  const r = spawnSync('ps', ['-o', 'stat=,comm=', '-p', String(pid)], {
    encoding: 'utf8',
  })
  return r.stdout.trim() || '(no process)'
}

;(async () => {
  const id = process.argv[2]
  if (!id) throw new Error('usage: q3-two-clients.ts <short id>')
  const R = { steps: [] }
  const step = async (name, extra = {}) => {
    const s = { at: new Date().toISOString(), name, session: await entryOf(id), ...extra }
    R.steps.push(s)
    log(`step ${name}:`, {
      pid: s.session?.pid,
      state: s.session?.state,
      status: s.session?.status,
      ...extra,
    })
  }

  const A = await TestPty.attach({ id })
  const ra = await A.waitQuiet(1500, 30000)
  R.A = { firstOutputMs: A.firstOutputMs, ready: ra }
  await A.save('q3-A-ready')
  await step('A attached')

  const aMark = A.mark()
  const B = await TestPty.attach({ id })
  const rb = await B.waitQuiet(1500, 30000)
  await A.waitQuiet(1000, 10000, false)
  R.B = { firstOutputMs: B.firstOutputMs, ready: rb }
  await A.save('q3-A-after-B')
  await B.save('q3-B-ready')
  await step('B attached', {
    aAlive: !A.exitInfo,
    aBytesAfterB: A.since(aMark).length,
    aExit: A.exitInfo,
  })

  // B types a prompt. Does A show the turn too?
  const aMark2 = A.mark()
  const bMark2 = B.mark()
  await B.typeLine('Reply with TWO')
  R.turn = await L.waitTurn({ id }, { timeout: 90000 })
  await B.waitQuiet(1500, 15000)
  await A.waitQuiet(500, 5000, false)
  const aScreen = await A.screenText()
  const bScreen = await B.screenText()
  await A.save('q3-A-after-turn')
  await B.save('q3-B-after-turn')
  await step('B typed', {
    aAlive: !A.exitInfo,
    aBytes: A.since(aMark2).length,
    aShowsPrompt: /Reply with TWO/.test(aScreen),
    aShowsTwo: /⏺\s*TWO/.test(aScreen),
    bBytes: B.since(bMark2).length,
    bShowsTwo: /⏺\s*TWO/.test(bScreen),
    turn: R.turn.trace,
  })

  // Size conflict: resize B only. Does A get a redraw at the new width?
  const aMark3 = A.mark()
  B.resize(100, 30)
  await B.waitQuiet(1000, 10000, false)
  await A.waitQuiet(500, 5000, false)
  const aRule = Math.max(
    0,
    ...(await A.screenLines()).map(l => (l.match(/─{4,}/) || [''])[0].length),
  )
  await A.save('q3-A-after-B-resize')
  await B.save('q3-B-after-resize')
  await step('B resized to 100x30', { aBytes: A.since(aMark3).length, aWidestRule: aRule })
  B.resize(120, 32)
  await B.waitQuiet(1000, 10000, false)

  // Question 4, method 1: end B with SIGHUP.
  B.lock('close')
  B.closeAttach('SIGHUP')
  const bExit = await Promise.race([B.exited, sleep(5000).then(() => null)])
  await sleep(1000)
  await step('B closed with SIGHUP', { aAlive: !A.exitInfo, bExit })

  // Question 4, method 2: the ← key on an empty prompt in A.
  const left = A.modes().applicationCursorKeysMode ? '\x1bOD' : '\x1b[D'
  const aMark4 = A.mark()
  await A.write(left)
  A.lock('after the left arrow key, the client can show the agent view')
  await A.waitQuiet(1500, 15000, false)
  const aAfterLeft = await A.screenLines()
  writeOut('q3-A-after-left.screen.txt', aAfterLeft.join('\n'))
  writeOut('q3-A-after-left.raw', A.since(aMark4))
  await step('A got the left arrow', {
    aAlive: !A.exitInfo,
    aBytes: A.since(aMark4).length,
    aProc: procState(A.pty.pid),
    aShowsAgentView: /agents?|sessions?/i.test(aAfterLeft.join('\n')),
    aTopLines: aAfterLeft.slice(0, 3).map(l => l.slice(0, 60)),
    key: JSON.stringify(left),
  })

  // Question 4, method 3: end A with SIGTERM.
  A.closeAttach('SIGTERM')
  const aExit = await Promise.race([A.exited, sleep(5000).then(() => null)])
  await sleep(1000)
  await step('A closed with SIGTERM', { aExit })

  // Ctrl+Z in a third client C.
  const C = await TestPty.attach({ id })
  await C.waitQuiet(1500, 30000)
  const cMark = C.mark()
  await C.write('\x1a')
  C.lock('after Ctrl+Z')
  await C.waitQuiet(1500, 10000, false)
  await sleep(500)
  const cAfter = await C.screenLines()
  writeOut('q3-C-after-ctrlz.screen.txt', cAfter.join('\n'))
  await step('C got Ctrl+Z', {
    cAlive: !C.exitInfo,
    cBytes: C.since(cMark).length,
    cExit: C.exitInfo,
    cProc: procState(C.pty.pid),
    cTail: L.stripAnsi(C.since(cMark)).slice(-300),
  })
  if (!C.exitInfo) {
    C.closeAttach('SIGCONT')
    C.closeAttach('SIGTERM')
    const cExit = await Promise.race([C.exited, sleep(5000).then(() => null)])
    await step('C closed with SIGCONT and SIGTERM', { cExit })
  }

  writeOut('q3-result.json', R)
  log('saved q3-result.json')
  process.exit(0)
})().catch(e => {
  console.error(e)
  process.exit(1)
})
