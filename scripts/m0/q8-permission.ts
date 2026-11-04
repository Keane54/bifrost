// M0 question 8: record the status and state while a session waits for permission.
// Usage: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron scripts/m0/q8-permission.ts <suffix> <prompt> [extra claude args...]
// The script starts "bifrost-test-<suffix>" in the background and polls
// "claude agents --json" every 400 ms for 90 seconds, or until the status stays
// the same for 8 seconds after the first busy.
// Then it attaches without input, saves the screen, and detaches with SIGHUP.
// The script never answers a permission prompt.
import * as L from './lib.ts'
const { TestPty, log, sleep, writeOut } = L

;(async () => {
  const [suffix, prompt, ...extra] = process.argv.slice(2)
  if (!suffix || !prompt) throw new Error('usage: q8-permission.ts <suffix> <prompt> [args...]')
  const R = { suffix, prompt, extra }
  const r = await L.startBg(suffix, prompt, extra)
  R.start = { code: r.code, stdout: r.stdout, stderr: r.stderr, id: r.id }
  if (!r.id) throw new Error('no id')
  const start = Date.now()
  const trace = []
  let sawBusy = false
  let stableSince = Date.now()
  while (Date.now() - start < 90000) {
    const e = (await L.listAgents()).find((x) => x.id === r.id)
    const s = e ? `${e.status}/${e.state}` : 'absent'
    if (!trace.length || trace[trace.length - 1].s !== s) {
      trace.push({ ms: Date.now() - start, s })
      stableSince = Date.now()
      log(`+${Date.now() - start} ms ${s}`)
    }
    if (e && e.status === 'busy') sawBusy = true
    if (sawBusy && e && e.status !== 'busy' && Date.now() - stableSince > 8000) break
    await sleep(400)
  }
  R.trace = trace
  const P = await TestPty.attach({ id: r.id })
  await P.waitQuiet(1500, 20000)
  P.lock('look only')
  const lines = await P.screenLines()
  await P.save(`q8-${suffix}`)
  R.screenTail = lines.filter((l) => l.trim()).slice(-14)
  R.permissionPromptOnScreen = /Do you want to|Allow|permission/i.test(lines.join('\n'))
  P.closeAttach('SIGHUP')
  await Promise.race([P.exited, sleep(5000)])
  R.entryAfter = (await L.listAgents()).find((x) => x.id === r.id) || null
  const tr = L.transcriptMessages(R.entryAfter ? R.entryAfter.sessionId : '')
  R.transcript =
    tr && tr.messages.filter((m) => !m.meta).map((m) => `${m.type}: ${m.text.slice(0, 100)}`)
  writeOut(`q8-${suffix}.json`, R)
  log('result:', { trace: R.trace, prompt: R.permissionPromptOnScreen, tail: R.screenTail })
  process.exit(0)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
