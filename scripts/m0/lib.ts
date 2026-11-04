// biome-ignore-all lint/suspicious/noControlCharactersInRegex: The regexes match terminal escape sequences.
// Shared helpers for the M0 experiments.
// The scripts start Claude Code test sessions and drive them through node-pty.
// Every action on a session goes through assertTestTarget first.
// That check reads "claude agents --json" and accepts only one entry
// whose name starts with "bifrost-test-".
// The check refuses bifrost-test-idle. The controller owns that session.
// Run the scripts with Electron as Node, because node-pty uses the Electron ABI:
//   ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/<name>.ts
// Set M0_OUT to a directory for the raw output. The default is a temp directory.

import { execFile } from 'node:child_process'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'

// node-pty and xterm.js load as CommonJS.
const require = createRequire(import.meta.url)
const CLAUDE = process.env.M0_CLAUDE || path.join(os.homedir(), '.local', 'bin', 'claude')
const REPO = path.resolve(import.meta.dirname, '..', '..')
const SANDBOX = path.join(REPO, '.m0-sandbox')
const TEST_PREFIX = 'bifrost-test-'
// The controller owns these sessions. The scripts never touch them.
const RESERVED_NAMES = new Set(['bifrost-test-idle'])
const RESERVED_IDS = new Set(['1db8945b'])
const COLS = 120
const ROWS = 32
const OUT = process.env.M0_OUT || path.join(os.tmpdir(), 'bifrost-m0')
fs.mkdirSync(OUT, { recursive: true })

// These flags can open a session that is not a new test session.
const FORBIDDEN_FLAG =
  /^(-r|--resume|-c|--continue|--session-id|--fork-session|--from-pr|--teleport|--cloud|-n|--name|--model)(=|$)/

const T0 = Date.now()
const sleep = ms => new Promise(r => setTimeout(r, ms))

function log(...parts) {
  const text = parts.map(p => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ')
  const line = `[${((Date.now() - T0) / 1000).toFixed(1)}s] ${text}`
  console.log(line)
  fs.appendFileSync(path.join(OUT, 'm0.log'), `${new Date().toISOString()} ${line}\n`)
}

function writeOut(name, data) {
  const file = path.join(OUT, name)
  fs.writeFileSync(file, typeof data === 'string' ? data : JSON.stringify(data, null, 2))
  return file
}

class SafetyError extends Error {}

// Remove the variables that a parent Claude Code session or terminal sets.
// A child claude must not think that it runs inside another session.
function cleanEnv() {
  const env = {}
  const drop =
    /^(CLAUDECODE|CLAUDE_CODE_|CLAUDE_EFFORT|CLAUDE_PID|ELECTRON_|WARP_|TERM_PROGRAM|TERM_SESSION_ID|FORCE_HYPERLINK|__CFBundleIdentifier)/
  for (const [k, v] of Object.entries(process.env)) if (!drop.test(k)) env[k] = v
  env.TERM = 'xterm-256color'
  env.COLORTERM = 'truecolor'
  return env
}

// Run claude without a terminal. The result never throws.
function runClaude(args, opts = {}) {
  return new Promise(resolve => {
    const start = Date.now()
    execFile(
      CLAUDE,
      args,
      {
        cwd: opts.cwd || SANDBOX,
        encoding: 'utf8',
        env: cleanEnv(),
        maxBuffer: 16 << 20,
        timeout: opts.timeout || 30000,
      },
      (err, stdout, stderr) => {
        resolve({
          args,
          code: err ? (typeof err.code === 'number' ? err.code : null) : 0,
          error: err && typeof err.code !== 'number' ? err.message : undefined,
          ms: Date.now() - start,
          signal: err?.signal || null,
          stderr: stderr || '',
          stdout: stdout || '',
        })
      },
    )
  })
}

// Keep a record of each new combination of kind, status, state and keys.
const seenValues = new Set()
function recordValues(list, all) {
  for (const e of list) {
    const rec = {
      all: !!all,
      keys: Object.keys(e).sort().join(','),
      kind: e.kind,
      state: e.state,
      status: e.status,
    }
    const key = JSON.stringify(rec)
    if (seenValues.has(key)) continue
    seenValues.add(key)
    const name = typeof e.name === 'string' && e.name.startsWith(TEST_PREFIX) ? e.name : '(other)'
    fs.appendFileSync(
      path.join(OUT, 'values.jsonl'),
      `${JSON.stringify({ at: new Date().toISOString(), name, ...rec })}\n`,
    )
  }
}

// Read "claude agents --json". The JSON array starts at the first line with "[".
async function listAgents({ all = false } = {}) {
  const r = await runClaude(all ? ['agents', '--json', '--all'] : ['agents', '--json'], {
    timeout: 20000,
  })
  if (r.code !== 0) throw new Error(`claude agents exited ${r.code}: ${r.stderr.trim()}`)
  const lines = r.stdout.split('\n')
  const i = lines.findIndex(l => l.startsWith('['))
  if (i < 0) throw new Error('claude agents printed no JSON array')
  const list = JSON.parse(lines.slice(i).join('\n'))
  recordValues(list, all)
  return list
}

// The safety check. Use it before each input, key, signal, stop, rm or attach.
// target has exactly one of: id, pid, sessionId, name.
// It returns the one matching entry, or it throws a SafetyError.
async function assertTestTarget(target, { all = false } = {}) {
  const keys = ['id', 'pid', 'sessionId', 'name'].filter(k => target && target[k] !== undefined)
  if (keys.length !== 1) throw new SafetyError(`bad target ${JSON.stringify(target)}`)
  const k = keys[0]
  const list = await listAgents({ all })
  const matches = list.filter(e => e[k] === target[k])
  if (matches.length !== 1) {
    throw new SafetyError(`need 1 entry with ${k}=${target[k]}, found ${matches.length}`)
  }
  const e = matches[0]
  if (typeof e.name !== 'string' || !e.name.startsWith(TEST_PREFIX)) {
    throw new SafetyError(`refused: ${k}=${target[k]} is not a test session`)
  }
  if (RESERVED_NAMES.has(e.name) || RESERVED_IDS.has(e.id)) {
    throw new SafetyError(`refused: ${e.name} belongs to the controller`)
  }
  log(`safety ok: ${k}=${target[k]} -> ${e.name} (id ${e.id || '-'}, pid ${e.pid || '-'})`)
  return e
}

// Keep a list of the sessions that these scripts started.
// Only an entry that passed assertTestTarget goes into the list.
function registerStarted(entry, via) {
  const rec = {
    at: new Date().toISOString(),
    id: entry.id,
    kind: entry.kind,
    name: entry.name,
    pid: entry.pid,
    sessionId: entry.sessionId,
    via,
  }
  fs.appendFileSync(path.join(OUT, 'started.jsonl'), `${JSON.stringify(rec)}\n`)
}

function readStarted() {
  const file = path.join(OUT, 'started.jsonl')
  if (!fs.existsSync(file)) return []
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map(l => JSON.parse(l))
}

// Wait until an entry that matches sel exists and pred(entry) is true.
// Record each change of the visible fields.
async function watchEntry(sel, pred, { timeout = 30000, interval = 500, all = false } = {}) {
  const k = Object.keys(sel)[0]
  const start = Date.now()
  const trace = []
  while (Date.now() - start < timeout) {
    const list = await listAgents({ all })
    const e = list.find(x => x[k] === sel[k])
    const sig = e
      ? JSON.stringify({
          keys: Object.keys(e).join(','),
          pid: e.pid,
          state: e.state,
          status: e.status,
        })
      : 'absent'
    if (!trace.length || trace[trace.length - 1].sig !== sig) {
      trace.push({ entry: e || null, ms: Date.now() - start, sig })
    }
    if (e && pred(e)) return { entry: e, ms: Date.now() - start, ok: true, trace }
    await sleep(interval)
  }
  return { entry: null, ms: Date.now() - start, ok: false, trace }
}

// Wait for one turn: the status goes to busy, then away from busy.
// A short turn can end between two polls, so a regex on the screen
// or a check function can also end the wait.
async function waitTurn(sel, { timeout = 90000, interval = 600, done } = {}) {
  const k = Object.keys(sel)[0]
  const start = Date.now()
  const trace = []
  let sawBusy = false
  let last = null
  while (Date.now() - start < timeout) {
    const list = await listAgents()
    const e = list.find(x => x[k] === sel[k])
    last = e || null
    const s = e ? `${e.status}/${e.state || '-'}` : 'absent'
    if (!trace.length || trace[trace.length - 1].s !== s) trace.push({ ms: Date.now() - start, s })
    if (e && e.status === 'busy') sawBusy = true
    if (e && sawBusy && e.status !== 'busy') {
      return { by: 'status', entry: e, ms: Date.now() - start, ok: true, trace }
    }
    if (e && e.status !== 'busy' && done && (await done())) {
      return { by: 'check', entry: e, ms: Date.now() - start, ok: true, trace }
    }
    await sleep(interval)
  }
  return { by: 'timeout', entry: last, ms: Date.now() - start, ok: false, trace }
}

// Start a background test session in the sandbox.
async function startBg(suffix, prompt, extra = []) {
  const name = TEST_PREFIX + suffix
  if (RESERVED_NAMES.has(name)) throw new SafetyError(`refused: ${name} is reserved`)
  for (const a of extra) {
    if (FORBIDDEN_FLAG.test(a)) throw new SafetyError(`refused flag ${a}`)
  }
  if (typeof prompt === 'string' && prompt.startsWith('-')) {
    throw new SafetyError('refused: the prompt starts with "-"')
  }
  const args = ['--bg', ...extra, '--model', 'haiku', '--name', name]
  if (prompt) args.push(prompt)
  const r = await runClaude(args, { timeout: 60000 })
  const m = /backgrounded · ([0-9a-f]+)/.exec(r.stdout + r.stderr)
  r.id = m ? m[1] : null
  r.name = name
  log(`start ${name}: exit ${r.code} id ${r.id} (${r.ms} ms)`)
  if (r.id) {
    const w = await watchEntry({ id: r.id }, e => typeof e.sessionId === 'string', {
      interval: 300,
      timeout: 15000,
    })
    if (w.entry && w.entry.name === name) registerStarted(w.entry, 'startBg')
    else {
      // A start can fail after the exit code 0. Then the entry is only in --all.
      const failed = (await listAgents({ all: true })).find(e => e.id === r.id)
      if (failed && failed.name === name) registerStarted(failed, 'startBg-all')
      log(`warning: no active entry with name ${name} for id ${r.id}`)
    }
  }
  return r
}

// Resume a test conversation in the background.
// The sessionId must come from a test entry that these scripts started.
// No active entry with a different name may use the same sessionId.
async function resumeBg(sessionId, extra = []) {
  const started = readStarted().filter(s => s.sessionId === sessionId)
  if (!started.length || !started.every(s => s.name.startsWith(TEST_PREFIX))) {
    throw new SafetyError(`refused: ${sessionId} is not a test session that these scripts started`)
  }
  const active = (await listAgents()).filter(e => e.sessionId === sessionId)
  if (active.some(e => !String(e.name).startsWith(TEST_PREFIX))) {
    throw new SafetyError(`refused: an active non-test entry uses ${sessionId}`)
  }
  const file = findTranscript(sessionId)
  if (!file?.includes('m0-sandbox')) {
    throw new SafetyError(`refused: no sandbox transcript for ${sessionId}`)
  }
  for (const a of extra) if (FORBIDDEN_FLAG.test(a)) throw new SafetyError(`refused flag ${a}`)
  log(`safety ok: resume ${sessionId} (started as ${started[0].name})`)
  const r = await runClaude(['--bg', '--resume', sessionId, ...extra], { timeout: 60000 })
  const m = /backgrounded · ([0-9a-f]+)/.exec(r.stdout + r.stderr)
  r.id = m ? m[1] : null
  return r
}

async function stopTest(id) {
  const e = await assertTestTarget({ id }, { all: true })
  return runClaude(['stop', e.id])
}

async function rmTest(id) {
  const e = await assertTestTarget({ id }, { all: true })
  return runClaude(['rm', e.id])
}

async function logsTest(id) {
  const e = await assertTestTarget({ id })
  return runClaude(['logs', e.id])
}

// Send a signal to the process of a test session.
// The PID must come from the test entry in the same check.
async function signalTestPid(pid, sig) {
  const e = await assertTestTarget({ pid })
  if (e.pid !== pid) throw new SafetyError('pid mismatch')
  process.kill(pid, sig)
  log(`sent ${sig} to pid ${pid} (${e.name})`)
  return e
}

// Find the transcript file of a session. This only reads files.
function findTranscript(sessionId) {
  const base = path.join(os.homedir(), '.claude', 'projects')
  for (const d of fs.readdirSync(base)) {
    const p = path.join(base, d, `${sessionId}.jsonl`)
    if (fs.existsSync(p)) return p
  }
  return null
}

// Read the user and assistant text messages of a transcript.
function transcriptMessages(sessionId) {
  const file = findTranscript(sessionId)
  if (!file) return null
  const out = []
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue
    // JSON.parse returns any, so j has the same type.
    let j: ReturnType<typeof JSON.parse>
    try {
      j = JSON.parse(line)
    } catch {
      continue
    }
    if (j.type !== 'user' && j.type !== 'assistant') continue
    const c = j.message?.content
    let text = ''
    if (typeof c === 'string') text = c
    else if (Array.isArray(c)) {
      text = c
        .map(p =>
          p.type === 'text'
            ? p.text
            : p.type === 'tool_use'
              ? `[tool_use ${p.name}]`
              : p.type === 'tool_result'
                ? '[tool_result]'
                : '',
        )
        .filter(Boolean)
        .join(' ')
    }
    out.push({ meta: !!j.isMeta, sessionId: j.sessionId, text, ts: j.timestamp, type: j.type })
  }
  return { file, messages: out }
}

// Remove CSI, OSC, DCS and other escape sequences.
function stripAnsi(s) {
  return s
    .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, '')
    .replace(/\x1bP[^\x1b]*\x1b\\/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\x1b[()][0-9A-Za-z]/g, '')
    .replace(/\x1b[@-_]/g, '')
}

// Count the escape sequences that matter for xterm.js.
function analyseSequences(raw) {
  const count = re => (raw.match(re) || []).length
  const modes = {}
  for (const m of raw.matchAll(/\x1b\[\?([\d;]+)([hl])/g)) {
    for (const n of m[1].split(';')) modes[`?${n}${m[2]}`] = (modes[`?${n}${m[2]}`] || 0) + 1
  }
  const osc = {}
  for (const m of raw.matchAll(/\x1b\](\d+)[;\x07]/g)) osc[m[1]] = (osc[m[1]] || 0) + 1
  const csi = {}
  for (const m of raw.matchAll(/\x1b\[([<=>?]?)[\d;:]*([ -/]*)([@-~])/g)) {
    const k = `${m[1]}${m[2]}${m[3]}`
    csi[k] = (csi[k] || 0) + 1
  }
  return {
    altScreenOff: modes['?1049l'] || 0,
    altScreenOn: modes['?1049h'] || 0,
    bytes: raw.length,
    clearScreen: count(/\x1b\[2J/g),
    clearScrollback: count(/\x1b\[3J/g),
    csiFinals: csi,
    hyperlinks: count(/\x1b\]8;/g),
    kittyKeyboard: { pop: count(/\x1b\[<\d*u/g), push: count(/\x1b\[>\d+u/g) },
    modifyOtherKeys: count(/\x1b\[>4;\d*m/g),
    osc,
    privateModes: modes,
    queries: {
      cursorPos: count(/\x1b\[6n/g),
      DA1: count(/\x1b\[0?c/g),
      DA2: count(/\x1b\[>0?c/g),
      decrqm: count(/\x1b\[\?\d+\$p/g),
      kittyKeyboardQuery: count(/\x1b\[\?u/g),
      oscColourQuery: count(/\x1b\]1[01];\?/g),
      XTVERSION: count(/\x1b\[>0?q/g),
    },
    sgr256: count(/\x1b\[[\d;:]*[34]8[;:]5[;:]\d+/g),
    sgrBasic16: count(/\x1b\[(?:\d+;)*(?:3[0-7]|4[0-7]|9[0-7]|10[0-7])m/g),
    sgrTruecolor: count(/\x1b\[[\d;:]*[34]8[;:]2[;:]+\d+[;:]\d+[;:]\d+/g),
    syncOutput: { begin: modes['?2026h'] || 0, end: modes['?2026l'] || 0 },
    title: count(/\x1b\][02];/g),
  }
}

// A PTY that runs claude, with a headless xterm.js screen.
// The xterm.js replies to terminal queries go back to the PTY, as in the app.
class TestPty {
  // Attach to a test session. The attach uses the exact short id.
  static async attach(target, opts = {}) {
    const e = await assertTestTarget(target)
    if (!e.id) throw new SafetyError(`${e.name} has no short id`)
    const p = new TestPty(['attach', e.id], {
      ...opts,
      check: { id: e.id },
      label: `attach ${e.id}`,
    })
    p.entry = e
    return p
  }

  // Start an interactive test session. It is not a background session.
  static interactive(suffix, extra = [], opts = {}) {
    const name = TEST_PREFIX + suffix
    if (RESERVED_NAMES.has(name)) throw new SafetyError(`refused: ${name} is reserved`)
    for (const a of extra) if (FORBIDDEN_FLAG.test(a)) throw new SafetyError(`refused flag ${a}`)
    const args = ['--model', 'haiku', '--name', name, ...extra]
    return new TestPty(args, { ...opts, check: { name }, label: `interactive ${name}` })
  }

  constructor(args, { label, check, cols = COLS, rows = ROWS }) {
    const pty = require('node-pty')
    const { Terminal } = require('@xterm/xterm')
    this.args = args
    this.label = label
    this.check = check
    this.cols = cols
    this.rows = rows
    this.locked = false
    this.trustPrompt = false
    this.raw = ''
    this.chunks = []
    this.replies = []
    this.firstOutputMs = null
    this.exitInfo = null
    this.term = new Terminal({ allowProposedApi: true, cols, rows, scrollback: 2000 })
    this.t0 = Date.now()
    this.lastDataAt = this.t0
    this.pty = pty.spawn(CLAUDE, args, {
      cols,
      cwd: SANDBOX,
      env: cleanEnv(),
      name: 'xterm-256color',
      rows,
    })
    log(`pty ${label}: spawned pid ${this.pty.pid} args ${JSON.stringify(args)}`)
    this.term.onData(d => {
      this.replies.push({ d, ms: Date.now() - this.t0 })
      if (!this.locked && !this.exitInfo) this.pty.write(d)
    })
    this.pty.onData(d => {
      const now = Date.now()
      if (this.firstOutputMs === null) this.firstOutputMs = now - this.t0
      this.lastDataAt = now
      this.raw += d
      this.chunks.push({ len: d.length, ms: now - this.t0 })
      this.term.write(d)
      if (
        !this.trustPrompt &&
        /trust (this|the files in this) folder|Do you trust/i.test(stripAnsi(d))
      ) {
        this.trustPrompt = true
        this.locked = true
        log(`STOP: ${label} shows a trust prompt. Input is locked.`)
      }
    })
    this.exited = new Promise(resolve => {
      this.pty.onExit(ev => {
        this.exitInfo = { ...ev, ms: Date.now() - this.t0 }
        log(`pty ${label}: exit ${JSON.stringify(this.exitInfo)}`)
        resolve(this.exitInfo)
      })
    })
  }

  // Check the target again just before an input.
  async verify() {
    if (this.locked) throw new SafetyError(`${this.label}: input is locked`)
    if (this.exitInfo) throw new SafetyError(`${this.label}: the process ended`)
    const e = await assertTestTarget(this.check)
    if (this.check.name && e.pid !== this.pty.pid) {
      throw new SafetyError(`${this.label}: entry pid ${e.pid} is not the PTY pid ${this.pty.pid}`)
    }
    return e
  }

  async write(data) {
    await this.verify()
    this.pty.write(data)
  }

  // Type text, wait, then press Enter. Some TUIs read text and Enter in one chunk as a paste.
  async typeLine(text, gapMs = 300) {
    await this.write(text)
    await sleep(gapMs)
    await this.write('\r')
  }

  // Stop all input to this PTY, also the xterm.js replies.
  lock(reason) {
    this.locked = true
    log(`pty ${this.label}: input locked (${reason})`)
  }

  // Send a signal to the attach client of this PTY. Only for attach PTYs.
  // An interactive session process must get its signal through signalTestPid.
  closeAttach(sig) {
    if (this.args[0] !== 'attach') throw new SafetyError('closeAttach is only for attach PTYs')
    this.pty.kill(sig)
    log(`pty ${this.label}: sent ${sig} to the attach client pid ${this.pty.pid}`)
  }

  resize(cols, rows) {
    this.pty.resize(cols, rows)
    this.term.resize(cols, rows)
    this.cols = cols
    this.rows = rows
  }

  mark() {
    return this.raw.length
  }

  since(mark) {
    return this.raw.slice(mark)
  }

  async flush() {
    await new Promise(r => this.term.write('', r))
  }

  // Wait until the output is quiet for quietMs. The quiet time starts at the call
  // or at the last output, whichever is later. Return the time since spawn.
  async waitQuiet(quietMs = 1500, timeout = 30000, needOutput = true) {
    const start = Date.now()
    while (Date.now() - start < timeout) {
      const from = Math.max(this.lastDataAt, start)
      const ok = (!needOutput || this.firstOutputMs !== null) && Date.now() - from >= quietMs
      if (ok || this.exitInfo)
        return { ok: !!ok, readyMs: this.lastDataAt - this.t0, waited: Date.now() - start }
      await sleep(100)
    }
    return { ok: false, readyMs: null, waited: Date.now() - start }
  }

  async screenLines() {
    await this.flush()
    const b = this.term.buffer.active
    const lines = []
    for (let i = 0; i < this.term.rows; i++) {
      const l = b.getLine(b.viewportY + i)
      lines.push(l ? l.translateToString(true) : '')
    }
    return lines
  }

  async screenText() {
    return (await this.screenLines()).join('\n')
  }

  async waitScreen(re, timeout = 30000) {
    const start = Date.now()
    while (Date.now() - start < timeout) {
      if (re.test(await this.screenText())) return { ms: Date.now() - start, ok: true }
      if (this.exitInfo) break
      await sleep(200)
    }
    return { ms: Date.now() - start, ok: false }
  }

  bufferType() {
    return this.term.buffer.active.type
  }

  modes() {
    return this.term.modes
  }

  async save(name) {
    writeOut(`${name}.raw`, this.raw)
    writeOut(`${name}.screen.txt`, await this.screenText())
    writeOut(`${name}.replies.json`, this.replies)
    writeOut(`${name}.chunks.json`, this.chunks)
  }
}

export {
  analyseSequences,
  assertTestTarget,
  CLAUDE,
  COLS,
  cleanEnv,
  findTranscript,
  listAgents,
  log,
  logsTest,
  OUT,
  REPO,
  ROWS,
  readStarted,
  registerStarted,
  resumeBg,
  rmTest,
  runClaude,
  SANDBOX,
  SafetyError,
  signalTestPid,
  sleep,
  startBg,
  stopTest,
  stripAnsi,
  TEST_PREFIX,
  TestPty,
  transcriptMessages,
  waitTurn,
  watchEntry,
  writeOut,
}
