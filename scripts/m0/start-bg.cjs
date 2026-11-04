// Start one background test session and record its first seconds.
// Usage: start-bg.cjs <suffix> <prompt> [extra claude args...]
// The session name is "bifrost-test-<suffix>". The model is haiku.
// The directory is .m0-sandbox. The script prints the exact stdout and stderr.
// Then it polls "claude agents --json" and records each change of the entry,
// until the status is not busy and the state is "done", or until 90 seconds.
'use strict'
/* eslint-disable @typescript-eslint/no-require-imports -- CommonJS script for Node. */
const { startBg, watchEntry, writeOut, log } = require('./lib.cjs')

;(async () => {
  const [suffix, prompt, ...extra] = process.argv.slice(2)
  if (!suffix) {
    console.error('usage: start-bg.cjs <suffix> <prompt> [extra args...]')
    process.exit(2)
  }
  const r = await startBg(suffix, prompt, extra)
  log('stdout:', JSON.stringify(r.stdout))
  log('stderr:', JSON.stringify(r.stderr))
  const result = { start: r, watch: null }
  if (r.id) {
    let sawBusy = false
    const w = await watchEntry(
      { id: r.id },
      (e) => {
        if (e.status === 'busy') sawBusy = true
        return typeof e.pid === 'number' && e.status !== 'busy' && e.state === 'done'
      },
      { timeout: 90000, interval: 400 }
    )
    result.watch = { ...w, sawBusy }
    for (const t of w.trace) log(`+${t.ms} ms ${t.sig}`)
    log(`final: ${JSON.stringify(w.entry)}`)
  }
  const file = writeOut(`start-${suffix}.json`, result)
  log(`saved ${file}`)
})()
