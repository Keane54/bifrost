// biome-ignore-all lint/suspicious/noControlCharactersInRegex: The regexes match terminal escape sequences.
// M4 Task 1: the worktree flag, the slash command form and the terminal launch.
// Usage:
//   M0_CLAUDE=~/Developer/bifrost/.m0-sandbox/cl.sh M0_OUT="$TMPDIR/bifrost-m4" \
//     ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m4/probe.ts
// Part A starts bifrost-test-wt with "--worktree bifrost-test-wt".
// It records the entry, the branch and the git worktrees. Then it stops and removes the session.
// Part B starts bifrost-test-slash. It types "/rename" and "/context" through an attach PTY.
// B1 and B2 use a bracketed paste. B3 uses typed text. B3 runs only when B1 fails.
// Part C opens an attach script in each installed terminal app with "open -a".
// It looks for the new "claude attach <id>" process and walks to its terminal app.
// It sends SIGHUP only to that process, and only after it checked the exact command line,
// the PID and the start time again. The script never closes a terminal window or tab.
// Each "claude" call goes through lib.ts. Set M0_CLAUDE to cl.sh so that lib.ts uses cl.sh.
// assertTestTarget checks the test session before each input and before each "open -a".
// The script never accepts a trust prompt. TestPty locks the input when a trust prompt shows.
// It writes all results to probe.json in M0_OUT.

import { execFile } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import * as L from '../m0/lib.ts'
import { terminalOf } from '../m0/terminal-of.ts'

const { TestPty, log, sleep, writeOut } = L

const CL_SH = path.join(process.env.HOME ?? '', 'Developer/bifrost/.m0-sandbox/cl.sh')
const PROMPT = 'Reply with the word READY.'
const PS = '\x1b[200~'
const PE = '\x1b[201~'

const WT_SUFFIX = 'wt'
const WT_NAME = `${L.TEST_PREFIX}${WT_SUFFIX}`
const WT_BRANCH = `worktree-${WT_NAME}`
const CLAUDE_DIR = path.join(L.REPO, '.claude')
const WORKTREES_DIR = path.join(CLAUDE_DIR, 'worktrees')
const WT_PATH = path.join(WORKTREES_DIR, WT_NAME)

const SLASH_SUFFIX = 'slash'
const SLASH_NAME = `${L.TEST_PREFIX}${SLASH_SUFFIX}`
const B1_NAME = `${L.TEST_PREFIX}slash2`
const B3_NAME = `${L.TEST_PREFIX}slash3`

// The ruling limits of the plan.
const ENTRY_LIMIT_MS = 60000
const LAUNCH_LIMIT_MS = 10000
// The Mac is under heavy load. The script waits longer and records the real delay.
const ENTRY_WAIT_MS = 180000
const LAUNCH_WAIT_MS = 30000
const NAME_WAIT_MS = 15000

const APPS = [
  { key: 'warp', path: '/Applications/Warp.app' },
  { key: 'ghostty', path: '/Applications/Ghostty.app' },
  { key: 'iterm2', path: '/Applications/iTerm.app' },
  { key: 'terminal', path: '/System/Applications/Utilities/Terminal.app' },
]

// Run a command without a shell. The result never throws.
function run(cmd: string, args: string[], timeout = 30000) {
  return new Promise<{ code: number | null; ms: number; stderr: string; stdout: string }>(
    resolve => {
      const start = Date.now()
      execFile(cmd, args, { encoding: 'utf8', timeout }, (err, stdout, stderr) => {
        const code = err ? (typeof err.code === 'number' ? err.code : null) : 0
        resolve({ code, ms: Date.now() - start, stderr: stderr || '', stdout: stdout || '' })
      })
    },
  )
}

function short(r) {
  return { code: r.code, ms: r.ms, stderr: r.stderr.trim(), stdout: r.stdout.trim() }
}

// Parse "git worktree list --porcelain".
function parseWorktrees(text: string) {
  const out = []
  for (const block of text.split(/\n\s*\n/)) {
    const w = {}
    for (const line of block.split('\n')) {
      const m = /^(\S+)(?: (.*))?$/.exec(line.trim())
      if (m) w[m[1]] = m[2] === undefined ? true : m[2]
    }
    if (w.worktree) out.push(w)
  }
  return out
}

async function gitState() {
  const wl = await run('git', ['-C', L.REPO, 'worktree', 'list', '--porcelain'])
  const br = await run('git', ['-C', L.REPO, 'branch', '--list', 'worktree-bifrost-test-*'])
  return {
    branches: br.stdout
      .split('\n')
      .map(s => s.replace(/^[*+]?\s*/, '').trim())
      .filter(Boolean),
    porcelain: wl.stdout,
    worktrees: parseWorktrees(wl.stdout),
  }
}

function dirState() {
  return {
    claudeDir: fs.existsSync(CLAUDE_DIR),
    worktreePath: fs.existsSync(WT_PATH),
    worktreesDir: fs.existsSync(WORKTREES_DIR),
  }
}

async function entryOf(id: string, all = false) {
  return (await L.listAgents({ all })).find(e => e.id === id) || null
}

// Stop and remove one test session. A stop can remove the name from the entry for a short time.
// Then the check refuses the rm. The function waits and checks again. It never skips the check.
async function stopAndRemove(id: string) {
  const C = { rm: [], stop: null }
  try {
    C.stop = short(await L.stopTest(id))
  } catch (err) {
    C.stop = { error: err.message }
  }
  log(`stop ${id}:`, C.stop)
  for (let i = 0; i < 10; i++) {
    await sleep(2500)
    try {
      const r = short(await L.rmTest(id))
      C.rm.push(r)
      log(`rm ${id}:`, r)
      if (r.code === 0) break
    } catch (err) {
      C.rm.push({ error: err.message })
      log(`rm ${id} refused:`, err.message)
      if (!(await entryOf(id, true))) break
    }
  }
  return C
}

// Part A: the worktree flag.
async function partA(R, ids: string[]) {
  const A = { before: null, dirsBefore: dirState(), error: null, start: null }
  R.partA = A
  try {
    A.before = await gitState()
    const old = (await L.listAgents({ all: true })).filter(e => e.name === WT_NAME)
    if (old.length) throw new L.SafetyError(`refused: ${WT_NAME} exists already`)
    if (A.dirsBefore.worktreePath) throw new L.SafetyError(`refused: ${WT_PATH} exists already`)
    if (A.before.branches.includes(WT_BRANCH)) {
      throw new L.SafetyError(`refused: the branch ${WT_BRANCH} exists already`)
    }

    // Step 1.
    const s = await L.startBg(WT_SUFFIX, PROMPT, ['--worktree', WT_NAME])
    A.start = { code: s.code, id: s.id, ms: s.ms, stderr: s.stderr, stdout: s.stdout }
    A.trustError = /not trusted/i.test(s.stdout + s.stderr)
    if (!s.id) throw new Error(`no short id in the start output (exit ${s.code})`)
    ids.push(s.id)

    // Step 2.
    const w = await L.watchEntry({ id: s.id }, e => typeof e.pid === 'number', {
      interval: 500,
      timeout: ENTRY_WAIT_MS,
    })
    A.watch = { ms: w.ms, ok: w.ok, trace: w.trace.map(t => ({ ms: t.ms, sig: t.sig })) }
    const e = w.entry || (await entryOf(s.id, true))
    A.entry = e
      ? { cwd: e.cwd, id: e.id, name: e.name, pid: e.pid, state: e.state, status: e.status }
      : null
    log('A entry:', A.entry)

    // Step 3.
    if (e?.cwd && fs.existsSync(e.cwd)) {
      A.head = short(await run('git', ['-C', e.cwd, 'rev-parse', '--abbrev-ref', 'HEAD']))
      A.toplevel = short(await run('git', ['-C', e.cwd, 'rev-parse', '--show-toplevel']))
    }
    A.during = await gitState()
    A.dirsDuring = dirState()
    log('A head:', A.head, 'worktrees:', A.during.worktrees.length)

    // Wait for the end of the first turn. Then the stop does not cut a turn.
    if (w.ok) {
      const idle = await L.watchEntry({ id: s.id }, x => x.status === 'idle', {
        interval: 1000,
        timeout: 90000,
      })
      A.idle = { ms: idle.ms, ok: idle.ok }
      const sid = idle.entry?.sessionId || e?.sessionId
      if (sid) {
        const t = L.transcriptMessages(sid)
        A.transcript = t ? { file: t.file, messages: t.messages.slice(-4) } : null
      }
    }
  } catch (err) {
    A.error =
      err instanceof L.SafetyError ? `SafetyError: ${err.message}` : String(err?.stack || err)
    log('A ERROR:', A.error)
  } finally {
    // Step 4.
    if (A.start?.id) {
      A.cleanup = await stopAndRemove(A.start.id)
      await sleep(3000)
    }
    A.after = await gitState()
    A.dirsAfter = dirState()
    A.left = (await L.listAgents({ all: true }))
      .filter(e => e.name === WT_NAME || e.id === A.start?.id)
      .map(e => ({ id: e.id, name: e.name, state: e.state }))
    // Remove only the empty directories that Part A made. rmdirSync refuses a full directory.
    A.removedDirs = []
    for (const [dir, existed] of [
      [WORKTREES_DIR, A.dirsBefore.worktreesDir],
      [CLAUDE_DIR, A.dirsBefore.claudeDir],
    ] as const) {
      if (existed || !fs.existsSync(dir)) continue
      try {
        fs.rmdirSync(dir)
        A.removedDirs.push(dir)
      } catch (err) {
        A.removedDirs.push(`${dir} not removed: ${err.code}`)
      }
    }
    A.dirsFinal = dirState()
    log('A after:', {
      branches: A.after.branches,
      dirs: A.dirsFinal,
      left: A.left,
      removedDirs: A.removedDirs,
      worktrees: A.after.worktrees.map(x => x.worktree),
    })
  }
}

// Read the name of the entry until it is want, or until the time ends.
async function waitName(id: string, want: string, timeout = NAME_WAIT_MS) {
  const start = Date.now()
  const seen = []
  while (Date.now() - start < timeout) {
    const e = await entryOf(id)
    const name = e ? e.name : null
    const ms = Date.now() - start
    if (!seen.length || seen[seen.length - 1].name !== name) seen.push({ ms, name })
    if (name === want) return { changed: true, ms, seen, within5s: ms <= 5000 }
    await sleep(1000)
  }
  return { changed: false, ms: null, seen, within5s: false }
}

// Find the prompt line on the screen: the last line that starts with the prompt mark.
function promptLine(lines: string[]) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (/^\s*[❯>]\s?/.test(lines[i])) return lines[i]
  }
  return null
}

// Write text, wait, then write CR. Each write checks the target first (TestPty.write).
async function sendForm(p, text: string, form: 'paste' | 'typed') {
  const body = form === 'paste' ? `${PS}${text}${PE}` : text
  const gap = form === 'paste' ? 300 : 500
  const t0 = Date.now()
  await p.write(body)
  const t1 = Date.now()
  await sleep(gap)
  await p.write('\r')
  const t2 = Date.now()
  return { checkMs: t1 - t0, form, gapMs: t2 - t1, plannedGapMs: gap, text }
}

function transcriptCount(sessionId: string) {
  const t = L.transcriptMessages(sessionId)
  return t ? t.messages.length : 0
}

// B2: run /context and record the screen and the new transcript messages.
async function contextStep(p, sessionId: string, form: 'paste' | 'typed') {
  const before = transcriptCount(sessionId)
  const mark = p.mark()
  const sent = await sendForm(p, '/context', form)
  const quiet = await p.waitQuiet(1500, 30000)
  await sleep(2000)
  const lines = await p.screenLines()
  const t = L.transcriptMessages(sessionId)
  const added = t ? t.messages.slice(before) : []
  const text = L.stripAnsi(p.since(mark))
  const R = {
    added,
    assistantReplies: added.filter(m => m.type === 'assistant' && !m.meta).length,
    commandTag: added.some(m => /<command-name>\/context<\/command-name>/.test(m.text)),
    contextOutput: /context usage|tokens|free space/i.test(text),
    quiet,
    screen: lines.slice(-30),
    sent,
  }
  log(`B2 ${form}:`, {
    assistantReplies: R.assistantReplies,
    commandTag: R.commandTag,
    contextOutput: R.contextOutput,
  })
  return R
}

// Part B: the slash command form.
async function partB(R, ids: string[]) {
  const B = { error: null, start: null }
  R.partB = B
  let p = null
  try {
    const old = (await L.listAgents({ all: true })).filter(e =>
      String(e.name).startsWith(SLASH_NAME),
    )
    if (old.length) throw new L.SafetyError(`refused: ${SLASH_NAME} entries exist already`)

    // Step 1.
    const s = await L.startBg(SLASH_SUFFIX, PROMPT)
    B.start = { code: s.code, id: s.id, ms: s.ms, stderr: s.stderr, stdout: s.stdout }
    if (!s.id) throw new Error(`no short id in the start output (exit ${s.code})`)
    ids.push(s.id)
    const id = s.id
    const w = await L.watchEntry({ id }, e => typeof e.pid === 'number' && e.status === 'idle', {
      interval: 1000,
      timeout: ENTRY_WAIT_MS,
    })
    B.ready = { ms: w.ms, ok: w.ok, trace: w.trace.map(t => ({ ms: t.ms, sig: t.sig })) }
    if (!w.ok) throw new Error(`the session did not become idle in ${ENTRY_WAIT_MS / 1000} s`)
    if (w.entry.name !== SLASH_NAME) throw new L.SafetyError(`refused: name ${w.entry.name}`)
    const sessionId = w.entry.sessionId
    B.session = { id, pid: w.entry.pid, sessionId }

    // Step 2.
    p = await TestPty.attach({ id })
    B.attachQuiet = await p.waitQuiet(1500, 30000)
    B.promptBefore = promptLine(await p.screenLines())

    // Step 3. B1: the paste form.
    B.b1 = { sent: await sendForm(p, `/rename ${B1_NAME}`, 'paste') }
    B.b1.name = await waitName(id, B1_NAME)
    await p.waitQuiet(1500, 15000)
    B.b1.screen = (await p.screenLines()).slice(-12)
    B.b1.promptAfter = promptLine(await p.screenLines())
    log('B1:', { changed: B.b1.name.changed, ms: B.b1.name.ms, prompt: B.b1.promptAfter })

    // Step 4. B2: /context in the paste form. A failed B1 can start a turn. Wait for its end.
    const idle2 = await L.watchEntry({ id }, e => e.status === 'idle', {
      interval: 1000,
      timeout: 60000,
    })
    B.b2Idle = { ms: idle2.ms, ok: idle2.ok }
    B.b2 = await contextStep(p, sessionId, 'paste')

    // Step 5. B3: the typed form, only when B1 did not change the name.
    if (!B.b1.name.changed) {
      // The B1 text can stay in the prompt. Ctrl+U clears the prompt line.
      const left = promptLine(await p.screenLines())
      if (left && /rename/.test(left)) {
        await p.write('\x15')
        await sleep(500)
        B.b3Clear = { after: promptLine(await p.screenLines()), before: left }
      }
      await L.watchEntry({ id }, e => e.status === 'idle', { interval: 1000, timeout: 60000 })
      B.b3 = { sent: await sendForm(p, `/rename ${B3_NAME}`, 'typed') }
      B.b3.name = await waitName(id, B3_NAME)
      await p.waitQuiet(1500, 15000)
      B.b3.screen = (await p.screenLines()).slice(-12)
      log('B3:', { changed: B.b3.name.changed, ms: B.b3.name.ms })
      B.b3context = await contextStep(p, sessionId, 'typed')
    }
    await p.save('probe-slash')
  } catch (err) {
    B.error =
      err instanceof L.SafetyError ? `SafetyError: ${err.message}` : String(err?.stack || err)
    log('B ERROR:', B.error)
  } finally {
    // Step 6. Close the client. Keep the session for Part C.
    if (p && !p.exitInfo) {
      p.lock('close the Part B client')
      p.closeAttach('SIGHUP')
      B.clientExit = await Promise.race([p.exited, sleep(10000).then(() => null)])
    }
  }
}

// Read the process table: one { pid, ppid, command } for each process.
async function psTable() {
  const r = await run('/bin/ps', ['-axo', 'pid=,ppid=,command='])
  const out = []
  for (const line of r.stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s(.*)$/.exec(line)
    if (m) out.push({ command: m[3].trim(), pid: Number(m[1]), ppid: Number(m[2]) })
  }
  return out
}

// The two exact command lines of the attach client of the test session.
function attachForms(id: string) {
  return {
    claude: `claude attach ${id}`,
    clsh: [`/bin/sh ${CL_SH} attach ${id}`, `sh ${CL_SH} attach ${id}`, `${CL_SH} attach ${id}`],
  }
}

function isAttach(command: string, id: string) {
  const f = attachForms(id)
  return command === f.claude || f.clsh.includes(command)
}

// The start time of a process in ms. ps gives whole seconds.
async function startedAt(pid: number) {
  const r = await run('/bin/ps', ['-o', 'lstart=', '-p', String(pid)])
  const t = Date.parse(r.stdout.trim())
  return Number.isNaN(t) ? null : t
}

// The last parent in the walk whose path has ".app/", and the name of its outermost bundle.
function outermostApp(steps) {
  const apps = steps.filter(s => s.comm.includes('.app/'))
  const top = apps.length ? apps[apps.length - 1] : null
  return top ? { app: /([^/]+)\.app\//.exec(top.comm)[1], appPath: top.comm, pid: top.pid } : null
}

// Send SIGHUP to an attach client that this script made the terminal app start.
// The function checks the exact command line, the PID and the start time just before the signal.
async function hangUp(pid: number, id: string, before: Set<number>, openAt: number) {
  if (before.has(pid)) throw new L.SafetyError(`refused: pid ${pid} ran before the open call`)
  const cmd = (await run('/bin/ps', ['-o', 'command=', '-p', String(pid)])).stdout.trim()
  if (!isAttach(cmd, id)) throw new L.SafetyError(`refused: pid ${pid} runs "${cmd}"`)
  const at = await startedAt(pid)
  if (at === null || at < Math.floor(openAt / 1000) * 1000) {
    throw new L.SafetyError(`refused: pid ${pid} started at ${at}, before the open call`)
  }
  process.kill(pid, 'SIGHUP')
  const sentAt = Date.now()
  log(`sent SIGHUP to the attach client pid ${pid} ("${cmd}")`)
  let endedMs = null
  while (Date.now() - sentAt < 10000) {
    const r = await run('/bin/ps', ['-o', 'command=', '-p', String(pid)])
    if (!r.stdout.trim()) {
      endedMs = Date.now() - sentAt
      break
    }
    await sleep(250)
  }
  return { command: cmd, ended: endedMs !== null, endedMs, sentAt: new Date(sentAt).toISOString() }
}

async function launchApp(app, id: string, file: string) {
  const C = { app: app.key, appPath: app.path, installed: fs.existsSync(app.path) }
  if (!C.installed) {
    C.ruling = 'clipboard'
    log(`C ${app.key}: not installed`)
    return C
  }
  // Step 1.
  fs.writeFileSync(file, `#!/bin/sh\nexec ${CL_SH} attach ${id}\n`, { mode: 0o700 })
  fs.chmodSync(file, 0o700)
  const table = await psTable()
  const before = new Set(table.map(x => x.pid))
  if (table.some(x => isAttach(x.command, id))) {
    throw new L.SafetyError(`refused: an attach client for ${id} runs already`)
  }

  // Step 2.
  const e = await L.assertTestTarget({ id })
  if (e.id !== id) throw new L.SafetyError(`refused: entry ${e.id} is not ${id}`)
  const openAt = Date.now()
  C.openAt = new Date(openAt).toISOString()
  C.open = short(await run('/usr/bin/open', ['-a', app.path, file], 60000))
  log(`C ${app.key}: open exit ${C.open.code} in ${C.open.ms} ms`, C.open.stderr)

  // Step 3.
  C.seen = []
  let found = null
  while (Date.now() - openAt < LAUNCH_WAIT_MS) {
    await sleep(500)
    const now = Date.now() - openAt
    for (const x of await psTable()) {
      if (before.has(x.pid)) continue
      const first = !C.seen.some(s => s.pid === x.pid && s.command === x.command)
      if (first && (isAttach(x.command, id) || x.command.includes('bifrost-test-attach'))) {
        C.seen.push({ command: x.command, ms: now, pid: x.pid, ppid: x.ppid })
      }
      if (x.command === attachForms(id).claude) found = { ...x, ms: now }
    }
    if (found) break
  }
  if (found) {
    C.delayMs = found.ms
    C.pid = found.pid
    const walk = terminalOf(found.pid)
    C.walk = { app: walk.app, appPath: walk.appPath, steps: walk.steps }
    C.outermost = outermostApp(walk.steps)
    C.startedAt = await startedAt(found.pid)
    log(`C ${app.key}: attach pid ${found.pid} at ${found.ms} ms, walk ${walk.app}`)
    // Step 4.
    try {
      C.hangUp = await hangUp(found.pid, id, before, openAt)
    } catch (err) {
      C.hangUp = { error: err.message }
      log(`C ${app.key}: no SIGHUP:`, err.message)
    }
  } else {
    log(`C ${app.key}: no attach client in ${LAUNCH_WAIT_MS / 1000} s`)
  }
  const want = path.basename(app.path, '.app')
  const walkOk = !!C.walk && (C.walk.app === want || C.outermost?.app === want)
  C.ruling = found && found.ms <= LAUNCH_LIMIT_MS && walkOk ? 'command-file' : 'clipboard'
  C.windowNote = `${app.key} opened a window or tab at ${C.openAt}. The script did not close it.`
  return C
}

// Part C: the terminal launch.
async function partC(R) {
  const C = { apps: [], error: null }
  R.partC = C
  const id = R.partB?.session?.id
  if (!id) {
    C.error = 'no Part B session'
    return
  }
  const file = path.join(L.OUT, 'bifrost-test-attach.command')
  C.file = file
  for (const app of APPS) {
    try {
      C.apps.push(await launchApp(app, id, file))
    } catch (err) {
      const msg =
        err instanceof L.SafetyError ? `SafetyError: ${err.message}` : String(err?.stack || err)
      C.apps.push({ app: app.key, error: msg, ruling: 'clipboard' })
      log(`C ${app.key} ERROR:`, msg)
    }
    await sleep(3000)
  }
}

;(async () => {
  const R = {
    error: null,
    finished: null,
    help: null,
    partA: null,
    partB: null,
    partC: null,
    parts: (process.env.M4_PARTS || 'A,B,C').split(','),
    started: new Date().toISOString(),
  }
  const ids = []
  try {
    // Step 3: the full lines of the two flags in the help text.
    const lines = (await L.runClaude(['--help'])).stdout.split('\n')
    const block = (re: RegExp, n: number) => {
      const i = lines.findIndex(l => re.test(l))
      return i < 0 ? [] : lines.slice(i, i + n)
    }
    R.help = {
      permissionMode: block(/^\s+--permission-mode /, 4),
      worktree: block(/^\s+-w, --worktree /, 2),
    }
    if (R.parts.includes('A')) await partA(R, ids)
    if (R.parts.includes('B')) await partB(R, ids)
    if (R.parts.includes('C')) await partC(R)
  } catch (err) {
    R.error =
      err instanceof L.SafetyError ? `SafetyError: ${err.message}` : String(err?.stack || err)
    log('ERROR:', R.error)
  } finally {
    // Part C step 5, and the clean-up of Part B.
    const slashId = R.partB?.start?.id
    if (slashId) R.partB.cleanup = await stopAndRemove(slashId)
    await sleep(2000)
    const all = await L.listAgents({ all: true })
    R.left = all
      .filter(e => String(e.name).startsWith(WT_NAME) || String(e.name).startsWith(SLASH_NAME))
      .concat(all.filter(e => ids.includes(e.id)))
      .map(e => ({ id: e.id, name: e.name, state: e.state }))
    R.finished = new Date().toISOString()
    const file = writeOut('probe.json', R)

    const A = R.partA
    const B = R.partB
    const C = R.partC
    console.log('\n=== m4 probe summary ===')
    if (A) {
      console.log(
        `A: start exit ${A.start?.code} id ${A.start?.id} trust error ${A.trustError}` +
          ` | entry ${A.watch?.ok ? `at ${A.watch.ms} ms` : 'not found'}` +
          ` cwd ${A.entry?.cwd} | HEAD ${A.head?.stdout}`,
      )
      console.log(
        `A after rm: worktrees ${JSON.stringify(A.after?.worktrees.map(w => w.worktree))}` +
          ` branches ${JSON.stringify(A.after?.branches)} left ${JSON.stringify(A.left)}`,
      )
      const ok =
        A.start?.code === 0 &&
        A.watch?.ok &&
        A.watch.ms <= ENTRY_LIMIT_MS &&
        String(A.entry?.cwd).endsWith(`.claude/worktrees/${WT_NAME}`) &&
        A.head?.stdout === WT_BRANCH &&
        !A.after?.worktrees.some(w => w.worktree === WT_PATH) &&
        !A.after?.branches.includes(WT_BRANCH)
      console.log(`A ruling candidate: ${ok ? 'yes' : 'no'} error ${A.error}`)
    }
    if (B) {
      const b3 = B.b3 ? ` | B3 typed name changed ${B.b3.name.changed} at ${B.b3.name.ms} ms` : ''
      console.log(
        `B1 paste name changed ${B.b1?.name.changed} at ${B.b1?.name.ms} ms` +
          ` | B2 paste /context tag ${B.b2?.commandTag} output ${B.b2?.contextOutput}` +
          ` replies ${B.b2?.assistantReplies}${b3}`,
      )
      const slash = B.b1?.name.changed ? 'paste' : B.b3?.name.changed ? 'typed' : 'none'
      console.log(`B ruling candidate: ${slash} error ${B.error}`)
    }
    if (C) {
      for (const a of C.apps) {
        console.log(
          `C ${a.app}: installed ${a.installed !== false} open exit ${a.open?.code}` +
            ` attach ${a.pid ? `pid ${a.pid} at ${a.delayMs} ms` : 'not found'}` +
            ` walk ${a.walk?.app} outermost ${a.outermost?.app}` +
            ` SIGHUP ${JSON.stringify(a.hangUp || null)} -> ${a.ruling}`,
        )
      }
      if (C.error) console.log(`C error: ${C.error}`)
    }
    console.log(`left: ${JSON.stringify(R.left)}`)
    console.log(`error: ${R.error}`)
    console.log(`results: ${file}`)
    const errs = [R.error, A?.error, B?.error, C?.error].filter(Boolean)
    process.exit(!errs.length && R.left.length === 0 ? 0 : 1)
  }
})()
