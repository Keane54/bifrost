// M0 question 10: check which flags "claude --bg" accepts.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/q10-flags.ts [flags] [flags-bad] [wt]   (no argument runs all three steps)
// The script starts these background test sessions in .m0-sandbox:
//   bifrost-test-flags      --permission-mode plan
//   bifrost-test-flags-bad  --permission-mode bogus (to see the error form)
//   bifrost-test-wt         --worktree, after "git init" in .m0-sandbox
// If the worktree start fails, it makes an empty first commit and tries
// bifrost-test-wt2. Each start has the first prompt "Reply with the word READY."
// For each start it records the exit code, stdout, stderr and the entry.
// It attaches without input to read the mode line, then detaches with SIGHUP.
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import * as L from './lib.ts'
const { TestPty, log, sleep, writeOut } = L

const PROMPT = 'Reply with the word READY.'

async function tryStart(suffix, extra) {
  const r = await L.startBg(suffix, PROMPT, extra)
  const res = { suffix, extra, code: r.code, stdout: r.stdout, stderr: r.stderr, id: r.id }
  if (r.id) {
    const w = await L.watchEntry(
      { id: r.id },
      (e) => typeof e.pid === 'number' && e.status && e.status !== 'busy' && e.state !== 'working',
      { timeout: suffix.endsWith('bad') ? 20000 : 90000, interval: 500 }
    )
    res.entry = w.entry
    res.trace = w.trace.map((t) => ({ ms: t.ms, sig: t.sig }))
    if (!w.ok) {
      const all = (await L.listAgents({ all: true })).filter((e) => e.id === r.id)
      res.allEntry = all
      log(`start ${suffix}: no active entry. agents --all:`, all)
      writeOut(`q10-${suffix}.json`, res)
      return res
    }
    const P = await TestPty.attach({ id: r.id })
    await P.waitQuiet(1500, 20000)
    P.lock('look only')
    const lines = await P.screenLines()
    await P.save(`q10-${suffix}`)
    res.footer = lines.filter((l) => l.trim()).slice(-3)
    res.banner = lines.filter((l) => /Claude Code|Haiku|~\//.test(l)).slice(0, 3)
    res.planMode = /plan mode on/i.test(lines.join('\n'))
    P.closeAttach('SIGHUP')
    await Promise.race([P.exited, sleep(5000)])
  }
  writeOut(`q10-${suffix}.json`, res)
  log(`start ${suffix}:`, {
    code: res.code,
    stdout: res.stdout,
    stderr: res.stderr,
    cwd: res.entry && res.entry.cwd,
    footer: res.footer
  })
  return res
}

function git(args) {
  const r = spawnSync('git', args, { cwd: L.SANDBOX, encoding: 'utf8', env: L.cleanEnv() })
  return { args: args.join(' '), code: r.status, stdout: r.stdout, stderr: r.stderr }
}

;(async () => {
  const R = { help: null, runs: [] }
  const help = await L.runClaude(['--help'], { timeout: 20000 })
  R.help = help.stdout.split('\n').filter((l) => /worktree/i.test(l))
  log('help lines with "worktree":', R.help)

  const steps = process.argv.slice(2).length ? process.argv.slice(2) : ['flags', 'flags-bad', 'wt']
  if (steps.includes('flags')) R.runs.push(await tryStart('flags', ['--permission-mode', 'plan']))
  if (steps.includes('flags-bad')) {
    R.runs.push(await tryStart('flags-bad', ['--permission-mode', 'bogus']))
  }
  if (!steps.includes('wt')) {
    writeOut('q10-result.json', R)
    process.exit(0)
  }

  if (!fs.existsSync(path.join(L.SANDBOX, '.git'))) R.gitInit = git(['init'])
  log('git init:', R.gitInit)
  const wt = await tryStart('wt', ['--worktree'])
  R.runs.push(wt)
  if (!wt.id || wt.code !== 0) {
    R.gitCommit = git(['commit', '--allow-empty', '-m', 'init'])
    log('git commit:', R.gitCommit)
    R.runs.push(await tryStart('wt2', ['--worktree']))
  }
  R.worktreeList = git(['worktree', 'list'])
  log('git worktree list:', R.worktreeList.stdout)
  writeOut('q10-result.json', R)
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
