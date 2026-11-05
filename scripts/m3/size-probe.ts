// M3 Task 1: can Bifrost learn the terminal size of a background session
// after a different client resized it?
// Usage:
//   M0_CLAUDE=/Users/dev-user/Developer/bifrost/.m0-sandbox/cl.sh M0_OUT="$TMPDIR/bifrost-m3" \
//     ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m3/size-probe.ts
// The script starts the test session bifrost-test-size. The prompt goes with startBg.
// The script types nothing into the session.
// It also does not send the xterm.js replies of the clients to the session.
// Client A attaches at 120 x 32, client B at 100 x 30 and client C at 80 x 24.
// B resizes 5 times. The script reads the session size with 5 probes:
//   P1: the TTY of the session process: "ps -o tty= -p <pid>", then "stty -f <device> size".
//   P2: a full redraw (ESC [ 2 J) in the output of A after a resize of B.
//   P3: the longest rule and the last row with text on the screen of A.
//   P4: the keys of the session entry in "claude agents --json".
//   P5: the top-level keys of ~/.bifrost/sessions/<sessionId>/status.json.
// assertTestTarget checks the session before each resize and before each TTY read.
// The TTY read runs only the two commands of P1. These commands only read.
// At the end the script closes the clients. Then it stops and removes the test session.
// It writes all results to size-probe.json in M0_OUT.

import { execFile } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import * as L from '../m0/lib.ts'

const { TestPty, log, sleep, writeOut } = L

const SUFFIX = 'size'
const NAME = `${L.TEST_PREFIX}${SUFFIX}`
const RESIZES = [
  [90, 25],
  [140, 40],
  [110, 35],
  [100, 30],
  [120, 32],
]
const POLL_MS = 50
const POLL_LIMIT_MS = 2000
// The ruling limit of the plan.
const RULING_MS = 1000
const CLEAR = '\x1b[2J'
const SIZE_KEY = /col|rows|width|height|winsize|tty|terminal|dimension/i

// Run a command without a shell. The result never throws.
function run(cmd: string, args: string[]) {
  return new Promise<{ code: number | null; stderr: string; stdout: string }>(resolve => {
    execFile(cmd, args, { encoding: 'utf8', timeout: 10000 }, (err, stdout, stderr) => {
      const code = err ? (typeof err.code === 'number' ? err.code : null) : 0
      resolve({ code, stderr: stderr || '', stdout: stdout || '' })
    })
  })
}

// Check that pid is the process of the test session with this short id.
async function checkPid(pid: number, id: string) {
  const start = Date.now()
  const e = await L.assertTestTarget({ pid })
  if (e.id !== id || e.name !== NAME) {
    throw new L.SafetyError(`refused: pid ${pid} is ${e.name} (${e.id}), not ${NAME} (${id})`)
  }
  return { checkMs: Date.now() - start, entry: e }
}

// Read the size of the TTY of a process. Call checkPid immediately before this function.
async function readTty(pid: number) {
  const ps = await run('/bin/ps', ['-o', 'tty=', '-p', String(pid)])
  const tty = ps.stdout.trim()
  if (!/^ttys\d+$/.test(tty)) {
    return { error: `no TTY name: ${JSON.stringify(tty)} ${ps.stderr.trim()}`.trim(), tty }
  }
  const st = await run('/bin/stty', ['-f', `/dev/${tty}`, 'size'])
  const m = /^(\d+) (\d+)$/.exec(st.stdout.trim())
  if (!m) return { error: `stty exit ${st.code}: ${st.stderr.trim()}`, tty }
  return { cols: Number(m[2]), rows: Number(m[1]), tty }
}

function sizeText(r) {
  return r.error ? `error (${r.error})` : `${r.cols} x ${r.rows} (${r.tty})`
}

// Probe P1 with its own safety check.
async function probeP1(pid: number, id: string, label: string) {
  const c = await checkPid(pid, id)
  const r = await readTty(pid)
  log(`P1 ${label}: ${sizeText(r)}`)
  return { at: new Date().toISOString(), checkMs: c.checkMs, label, ...r }
}

// Find keys that can hold a terminal size, at all depths.
function sizeFields(obj, prefix = '') {
  const out = []
  for (const [k, v] of Object.entries(obj || {})) {
    const key = prefix ? `${prefix}.${k}` : k
    if (SIZE_KEY.test(k)) out.push({ key, value: v })
    if (v && typeof v === 'object' && !Array.isArray(v)) out.push(...sizeFields(v, key))
  }
  return out
}

// Find the time of the chunk of A that holds the raw position pos.
// The time is relative to t0 (an epoch time in ms).
function chunkTime(p, firstChunk: number, mark: number, pos: number, t0: number) {
  let at = mark
  for (let i = firstChunk; i < p.chunks.length; i++) {
    const c = p.chunks[i]
    if (pos < at + c.len) return p.t0 + c.ms - t0
    at += c.len
  }
  return null
}

// P3: the longest run of U+2500 and the number of the last row with text (1 is the top row).
async function screenGuess(p) {
  const lines = await p.screenLines()
  let rule = 0
  let lastRow = 0
  lines.forEach((l, i) => {
    for (const m of l.match(/─+/g) || []) rule = Math.max(rule, m.length)
    if (l.trim()) lastRow = i + 1
  })
  return { lastRow, rule, screenCols: p.cols, screenRows: p.rows }
}

async function closeClient(p, label: string) {
  if (p.exitInfo) return p.exitInfo
  p.lock(`close ${label}`)
  p.closeAttach('SIGHUP')
  let ex = await Promise.race([p.exited, sleep(5000).then(() => null)])
  if (!ex) {
    p.closeAttach('SIGTERM')
    ex = await Promise.race([p.exited, sleep(5000).then(() => null)])
  }
  return ex
}

// Attach a client and stop all input from it at once.
// The attach waits in a microtask, so no pty data arrives before the lock.
async function attachLocked(id: string, cols: number, rows: number, label: string) {
  const p = await TestPty.attach({ id }, { cols, rows })
  p.lock(`client ${label}: the script sends no input`)
  return p
}

// Wait until the output of a new client is quiet. Then record its first output time.
async function settle(p) {
  const quiet = await p.waitQuiet(1500, 30000)
  return { firstOutputMs: p.firstOutputMs, quiet }
}

async function resizeStep(A, B, pid: number, id: string, cols: number, rows: number) {
  const aMark = A.mark()
  const aChunk = A.chunks.length
  // This check is for the resize and for the first TTY read.
  const checks = [(await checkPid(pid, id)).checkMs]
  const t0 = Date.now()
  B.resize(cols, rows)
  const reads = []
  let delayMs = null
  await sleep(POLL_MS)
  for (;;) {
    const r = await readTty(pid)
    const ms = Date.now() - t0
    reads.push({ ms, ...r })
    if (r.cols === cols && r.rows === rows) {
      delayMs = ms
      break
    }
    if (ms >= POLL_LIMIT_MS) break
    await sleep(POLL_MS)
    checks.push((await checkPid(pid, id)).checkMs)
  }
  const quiet = await A.waitQuiet(1500, 30000)
  // P1 again after the redraw. The size must stay.
  const after = await probeP1(pid, id, `after the resize to ${cols} x ${rows} and the quiet time`)

  const out = A.since(aMark)
  const clearPos = out.indexOf(CLEAR)
  const p2 = {
    bytes: out.length,
    clear: clearPos >= 0,
    clearMs: clearPos >= 0 ? chunkTime(A, aChunk, aMark, aMark + clearPos, t0) : null,
    clears: out.split(CLEAR).length - 1,
    firstByteMs: out.length ? chunkTime(A, aChunk, aMark, aMark, t0) : null,
  }
  const p3 = await screenGuess(A)
  const entry = (await L.listAgents()).find(e => e.id === id) || null
  const p4 = { keys: entry ? Object.keys(entry).sort() : null, sizeFields: sizeFields(entry) }
  const p1 = {
    afterQuiet: after,
    checkMs: checks,
    delayMs,
    match: delayMs !== null,
    reads,
    stays: after.cols === cols && after.rows === rows,
  }
  log(
    `resize ${cols} x ${rows}: P1 ${delayMs === null ? 'no match' : `match at ${delayMs} ms`}` +
      ` after ${reads.length} reads, stays ${p1.stays} | P2 clear ${p2.clear} at ${p2.clearMs} ms` +
      ` | P3 rule ${p3.rule}, last row ${p3.lastRow} | P4 size keys ${p4.sizeFields.length}`,
  )
  return { cols, p1, p2, p3, p4, quiet, rows }
}

function statusProbe(sessionId: string) {
  if (!/^[0-9a-f-]{36}$/.test(sessionId)) return { error: `bad sessionId ${sessionId}` }
  const file = path.join(os.homedir(), '.bifrost', 'sessions', sessionId, 'status.json')
  if (!fs.existsSync(file)) return { file, result: 'no status file' }
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'))
    return { file, keys: Object.keys(data).sort(), sizeFields: sizeFields(data) }
  } catch (err) {
    return { error: err.message, file }
  }
}

async function cleanup(R, clients, id: string | null) {
  const C = { clients: {}, left: null, leftActive: null, rm: [], stop: null }
  for (const [label, p] of Object.entries(clients)) {
    C.clients[label] = await closeClient(p, label)
  }
  if (id) {
    try {
      const s = await L.stopTest(id)
      C.stop = { code: s.code, stderr: s.stderr.trim(), stdout: s.stdout.trim() }
    } catch (err) {
      C.stop = { error: err.message }
    }
    log('cleanup stop:', C.stop)
    // A stop can remove the name from the entry for a short time. Then the check refuses the rm.
    // Wait and check again. Do not skip the check.
    for (let i = 0; i < 8; i++) {
      await sleep(2500)
      try {
        const r = await L.rmTest(id)
        C.rm.push({ code: r.code, stderr: r.stderr.trim(), stdout: r.stdout.trim() })
        log('cleanup rm:', C.rm[C.rm.length - 1])
        if (r.code === 0) break
      } catch (err) {
        C.rm.push({ error: err.message })
        log('cleanup rm refused:', err.message)
        const still = (await L.listAgents({ all: true })).some(e => e.id === id)
        if (!still) break
      }
    }
  }
  await sleep(1500)
  C.left = (await L.listAgents({ all: true })).filter(e => e.name === NAME || (id && e.id === id))
  C.leftActive = (await L.listAgents()).filter(e => e.name === NAME || (id && e.id === id))
  log(`cleanup: ${C.left.length} entries left in --all, ${C.leftActive.length} active`)
  R.cleanup = C
}

;(async () => {
  const R = {
    clients: {},
    error: null,
    name: NAME,
    p1: [],
    p5: null,
    resizes: [],
    ruling: null,
    started: new Date().toISOString(),
  }
  const clients = {}
  let id = null
  let pid = null
  try {
    // A second entry with this name makes the final check unclear. Refuse it.
    const before = (await L.listAgents({ all: true })).filter(e => e.name === NAME)
    if (before.length) throw new L.SafetyError(`refused: ${NAME} exists already`)

    // Step 1.
    const s = await L.startBg(SUFFIX, 'Reply with the word READY.')
    R.start = { code: s.code, id: s.id, ms: s.ms, stderr: s.stderr, stdout: s.stdout }
    if (!s.id) throw new Error(`no short id in the start output (exit ${s.code})`)
    id = s.id
    const w = await L.watchEntry(
      { id },
      e => typeof e.pid === 'number' && e.status === 'idle' && e.state !== 'working',
      { interval: 500, timeout: 120000 },
    )
    R.ready = { ms: w.ms, ok: w.ok, trace: w.trace.map(t => ({ ms: t.ms, sig: t.sig })) }
    if (!w.ok) throw new Error('the session did not become idle in 120 s')
    if (w.entry.name !== NAME) throw new L.SafetyError(`refused: entry name ${w.entry.name}`)
    pid = w.entry.pid
    const sessionId = w.entry.sessionId
    R.session = { id, pid, sessionId, state: w.entry.state, status: w.entry.status }
    log(`ready: id ${id} pid ${pid} sessionId ${sessionId}`)

    // Step 2.
    R.p1.push(await probeP1(pid, id, 'start, no client'))

    // Step 3. Question a: does a new attach set the session size?
    const A = await attachLocked(id, 120, 32, 'A')
    clients.A = A
    R.clients.A = await settle(A)
    R.p1.push(await probeP1(pid, id, 'after A attached at 120 x 32'))

    // Step 4.
    const B = await attachLocked(id, 100, 30, 'B')
    clients.B = B
    R.clients.B = await settle(B)
    await A.waitQuiet(1000, 10000, false)
    R.p1.push(await probeP1(pid, id, 'after B attached at 100 x 30'))

    // Step 5.
    for (const [cols, rows] of RESIZES) {
      R.resizes.push(await resizeStep(A, B, pid, id, cols, rows))
    }

    // Step 6.
    const aMark = A.mark()
    const C = await attachLocked(id, 80, 24, 'C')
    clients.C = C
    R.clients.C = await settle(C)
    R.p1.push(await probeP1(pid, id, 'after C attached at 80 x 24'))
    await A.waitQuiet(1000, 10000, false)
    R.clients.C.aAfterAttach = {
      bytes: A.since(aMark).length,
      clear: A.since(aMark).includes(CLEAR),
      screen: await screenGuess(A),
    }
    const aMark2 = A.mark()
    R.clients.C.exit = await closeClient(C, 'C')
    await sleep(1000)
    R.p1.push(await probeP1(pid, id, '1 s after C closed with SIGHUP'))
    await A.waitQuiet(1000, 10000, false)
    R.clients.C.aAfterClose = {
      bytes: A.since(aMark2).length,
      clear: A.since(aMark2).includes(CLEAR),
      screen: await screenGuess(A),
    }

    // Step 7.
    R.p5 = statusProbe(sessionId)
    log('P5:', R.p5)

    for (const [label, p] of Object.entries(clients)) {
      R.clients[label].heldReplies = p.replies.length
      await p.save(`size-probe-${label}`)
    }

    const ok = R.resizes.every(
      r => r.p1.match && r.p1.delayMs <= RULING_MS && r.p1.stays && !r.p1.reads.some(x => x.error),
    )
    R.ruling = ok ? 'yes (P1)' : 'no'
  } catch (err) {
    R.error =
      err instanceof L.SafetyError ? `SafetyError: ${err.message}` : String(err?.stack || err)
    log('ERROR:', R.error)
  } finally {
    // Step 8.
    try {
      await cleanup(R, clients, id)
    } catch (err) {
      R.cleanup = { error: String(err?.stack || err) }
      log('cleanup ERROR:', R.cleanup.error)
    }
    R.finished = new Date().toISOString()
    const file = writeOut('size-probe.json', R)

    console.log('\n=== size-probe summary ===')
    for (const p of R.p1) console.log(`P1 ${p.label}: ${sizeText(p)}`)
    for (const r of R.resizes) {
      const p1 = r.p1.match ? `match at ${r.p1.delayMs} ms` : 'no match'
      console.log(
        `resize ${r.cols} x ${r.rows}: P1 ${p1} (${r.p1.reads.length} reads, stays ${r.p1.stays})` +
          ` | P2 clear ${r.p2.clear} at ${r.p2.clearMs} ms | P3 rule ${r.p3.rule}` +
          ` last row ${r.p3.lastRow} | P4 size keys ${JSON.stringify(r.p4.sizeFields)}`,
      )
    }
    console.log(`P5: ${JSON.stringify(R.p5)}`)
    console.log(`ruling candidate: ${R.ruling}`)
    console.log(`error: ${R.error}`)
    const left = R.cleanup?.left
    console.log(`cleanup: ${left ? `${left.length} ${NAME} entries left` : 'unknown'}`)
    console.log(`results: ${file}`)
    const clean = Array.isArray(left) && left.length === 0
    process.exit(!R.error && clean ? 0 : 1)
  }
})()
