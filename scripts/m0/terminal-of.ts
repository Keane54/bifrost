// Find the terminal app of a process from its parent processes.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/terminal-of.ts <pid> [<pid> ...]
//    or: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/terminal-of.ts --interactive   (all interactive entries of "claude agents --json")
// The script only runs "ps". It sends nothing to any process.
// The terminal app is the first parent whose path contains ".app/".
import { spawnSync } from 'node:child_process'

function ps(pid, fields) {
  const r = spawnSync('ps', ['-o', fields, '-p', String(pid)], { encoding: 'utf8' })
  return r.stdout.replace(/\n$/, '')
}

// Walk up from pid to PID 1. Return one { pid, ppid, comm } for each step.
function chain(pid) {
  const out = []
  let p = Number(pid)
  while (p > 1 && out.length < 64) {
    const line = ps(p, 'ppid=,comm=')
    if (!line.trim()) break
    const m = /^\s*(\d+)\s+(.*)$/.exec(line)
    if (!m) break
    out.push({ pid: p, ppid: Number(m[1]), comm: m[2] })
    p = Number(m[1])
  }
  return out
}

function terminalOf(pid) {
  const steps = chain(pid)
  const app = steps.find((s) => s.comm.includes('.app/'))
  const name = app ? /([^/]+)\.app\//.exec(app.comm)[1] : null
  return { pid: Number(pid), app: name, appPath: app ? app.comm : null, steps }
}

export { chain, terminalOf }

if (import.meta.main) {
  const pids = process.argv.slice(2)
  if (pids[0] === '--interactive') {
    const { listAgents } = await import('./lib.ts')
    const list = await listAgents()
    for (const e of list.filter(x => x.kind === 'interactive')) {
      const t = terminalOf(e.pid)
      console.log(
        JSON.stringify({ pid: e.pid, app: t.app, appPath: t.appPath, depth: t.steps.length })
      )
    }
  } else {
    for (const p of pids) console.log(JSON.stringify(terminalOf(p), null, 1))
  }
}
